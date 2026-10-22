package main

import (
	"context"
	"encoding/json"
	"log/slog"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/example/meeting-bot-platform/services/internal/awsx"
	"github.com/example/meeting-bot-platform/services/internal/domain"
	"github.com/example/meeting-bot-platform/services/internal/kubejobs"
	"github.com/example/meeting-bot-platform/services/internal/telemetry"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/codes"
	"go.opentelemetry.io/otel/trace"
)

func main() {
	logger := slog.New(slog.NewJSONHandler(os.Stdout, nil))
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()
	shutdown, err := telemetry.Init(ctx, "bot-controller")
	if err != nil {
		logger.Error("telemetry initialization failed", "error", err)
		os.Exit(1)
	}
	defer func() { _ = shutdown(context.Background()) }()
	cloud, err := awsx.New(ctx)
	if err != nil {
		logger.Error("AWS client initialization failed", "error", err)
		os.Exit(1)
	}
	kube, err := kubejobs.New()
	if err != nil {
		logger.Error("Kubernetes client initialization failed", "error", err)
		os.Exit(1)
	}
	queue := awsx.RequestQueueURL()
	if queue == "" {
		logger.Error("REQUEST_QUEUE_URL is required")
		os.Exit(1)
	}
	for ctx.Err() == nil {
		messages, err := cloud.Receive(ctx, queue)
		if err != nil {
			if ctx.Err() != nil {
				break
			}
			logger.Error("receive failed", "error", err)
			time.Sleep(2 * time.Second)
			continue
		}
		for _, message := range messages {
			var event domain.Event
			if err := json.Unmarshal([]byte(message.Body), &event); err != nil {
				logger.Error("invalid queue message", "error", err)
				continue
			}
			messageCtx := telemetry.ExtractTrace(ctx, event.TraceContext)
			messageCtx, span := otel.Tracer("bot-controller").Start(messageCtx, "sqs.process", trace.WithSpanKind(trace.SpanKindConsumer), trace.WithAttributes(attribute.String("job.id", event.JobID), attribute.String("messaging.operation", event.Kind)))
			event.TraceContext = telemetry.InjectTrace(messageCtx)
			if err := handle(messageCtx, cloud, kube, event); err != nil {
				span.RecordError(err)
				span.SetStatus(codes.Error, "message handling failed")
				span.End()
				logger.Error("message handling failed", "job_id", event.JobID, "kind", event.Kind, "error", err)
				continue
			}
			span.End()
			if err := cloud.DeleteMessage(ctx, queue, message.Receipt); err != nil {
				logger.Error("queue acknowledgement failed", "job_id", event.JobID, "error", err)
				continue
			}
			logger.Info("message handled", "job_id", event.JobID, "kind", event.Kind)
		}
	}
}

func handle(ctx context.Context, cloud *awsx.Cloud, kube *kubejobs.Client, event domain.Event) error {
	switch event.Kind {
	case "START":
		job, err := cloud.GetJob(ctx, event.JobID)
		if err != nil {
			return err
		}
		if job.CancelRequested || job.Status == domain.CancelRequested || domain.IsTerminal(job.Status) {
			return nil
		}
		if job.Status != domain.Requested && job.Status != domain.Queued && job.Status != domain.Starting {
			return nil
		}
		if job.Status != domain.Starting {
			if err := cloud.UpdateStatus(ctx, event.JobID, domain.Starting, ""); err != nil {
				latest, readErr := cloud.GetJob(ctx, event.JobID)
				if readErr == nil && (latest.CancelRequested || latest.Status == domain.CancelRequested || domain.IsTerminal(latest.Status)) {
					return nil
				}
				if readErr != nil || latest.Status != domain.Starting {
					return err
				}
			}
		}
		if err := kube.CreateMeetingJob(ctx, event); err != nil {
			_ = cloud.UpdateStatus(ctx, event.JobID, domain.Queued, "")
			return err
		}
		return nil
	case "CANCEL":
		if err := kube.DeleteMeetingJob(ctx, event.JobID); err != nil {
			return err
		}
		return cloud.UpdateStatus(ctx, event.JobID, domain.Cancelled, "")
	default:
		return nil
	}
}
