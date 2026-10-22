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
	shutdown, err := telemetry.Init(ctx, "delivery-worker")
	if err != nil { logger.Error("telemetry initialization failed", "error", err); os.Exit(1) }
	defer func() { _ = shutdown(context.Background()) }()
	cloud, err := awsx.New(ctx)
	if err != nil { logger.Error("AWS client initialization failed", "error", err); os.Exit(1) }
	queue := awsx.DeliveryQueueURL()
	if queue == "" { logger.Error("DELIVERY_QUEUE_URL is required"); os.Exit(1) }
	for ctx.Err() == nil {
		messages, err := cloud.Receive(ctx, queue)
		if err != nil { if ctx.Err() != nil { break }; logger.Error("receive failed", "error", err); time.Sleep(2*time.Second); continue }
		for _, message := range messages {
			var event domain.DeliveryEvent
			if err := json.Unmarshal([]byte(message.Body), &event); err != nil { logger.Error("invalid delivery message", "error", err); continue }
			messageCtx := telemetry.ExtractTrace(ctx, event.TraceContext)
			messageCtx, span := otel.Tracer("delivery-worker").Start(messageCtx, "sqs.deliver", trace.WithSpanKind(trace.SpanKindConsumer), trace.WithAttributes(attribute.String("job.id", event.JobID)))
			bucket := os.Getenv("DELIVERY_BUCKET")
			if bucket == "" {
				if err := cloud.SetDeliveryStatus(messageCtx, event.JobID, "SKIPPED", "No destination bucket is configured"); err != nil { span.RecordError(err); span.SetStatus(codes.Error, "state update failed"); span.End(); logger.Error("state update failed", "job_id", event.JobID, "error", err); continue }
			} else {
				err := cloud.CopyArtifact(messageCtx, event.ArtifactKey, bucket, os.Getenv("DESTINATION_ROLE_ARN"), os.Getenv("DESTINATION_ACCOUNT_ID"))
				if err != nil { _ = cloud.SetDeliveryStatus(messageCtx, event.JobID, "FAILED", err.Error()); span.RecordError(err); span.SetStatus(codes.Error, "artifact delivery failed"); span.End(); logger.Error("artifact delivery failed", "job_id", event.JobID, "error", err); continue }
				if err := cloud.SetDeliveryStatus(messageCtx, event.JobID, "DELIVERED", ""); err != nil { span.RecordError(err); span.SetStatus(codes.Error, "state update failed"); span.End(); logger.Error("state update failed", "job_id", event.JobID, "error", err); continue }
			}
			if err := cloud.DeleteMessage(messageCtx, queue, message.Receipt); err != nil { span.RecordError(err); span.SetStatus(codes.Error, "queue acknowledgement failed"); span.End(); logger.Error("queue acknowledgement failed", "job_id", event.JobID, "error", err); continue }
			span.End()
			logger.Info("delivery handled", "job_id", event.JobID, "delivery_enabled", bucket != "")
		}
	}
}
