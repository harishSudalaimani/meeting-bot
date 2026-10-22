package main

import (
	"context"
	"fmt"
	"log/slog"
	"os"
	"os/signal"
	"strconv"
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
	shutdown, err := telemetry.Init(ctx, "meeting-bot-simulator")
	if err != nil { logger.Error("telemetry initialization failed", "error", err); os.Exit(1) }
	defer func() { _ = shutdown(context.Background()) }()
	ctx = telemetry.ExtractTrace(ctx, map[string]string{"traceparent": os.Getenv("TRACEPARENT"), "tracestate": os.Getenv("TRACESTATE")})
	jobID := os.Getenv("JOB_ID")
	if jobID == "" { logger.Error("JOB_ID is required"); os.Exit(1) }
	ctx, span := otel.Tracer("meeting-bot-simulator").Start(ctx, "meeting.simulate", trace.WithAttributes(attribute.String("job.id", jobID)))
	defer span.End()
	duration, err := strconv.Atoi(os.Getenv("DURATION_SECONDS"))
	if err != nil || duration < 10 || duration > 3600 { logger.Error("DURATION_SECONDS must be between 10 and 3600"); os.Exit(1) }
	cloud, err := awsx.New(ctx)
	if err != nil { logger.Error("AWS client initialization failed", "error", err); os.Exit(1) }
	started := time.Now().UTC()
	if err := cloud.UpdateStatus(ctx, jobID, domain.Joining, ""); err != nil { logger.Error("state update failed", "job_id", jobID, "error", err); os.Exit(1) }
	logger.Info("simulated meeting join", "job_id", jobID)
	joinTime := time.Duration(duration/10) * time.Second
	if joinTime < time.Second { joinTime = time.Second }
	if !sleep(ctx, joinTime) { span.SetStatus(codes.Error, "cancelled during simulated join"); fail(cloud, logger, jobID, "cancelled during simulated join"); return }
	if err := cloud.UpdateStatus(ctx, jobID, domain.Recording, ""); err != nil { fail(cloud, logger, jobID, err.Error()); return }
	logger.Info("simulated recording", "job_id", jobID, "duration_seconds", duration)
	if !sleep(ctx, time.Duration(duration)*time.Second-joinTime) { span.SetStatus(codes.Error, "cancelled during simulated recording"); fail(cloud, logger, jobID, "cancelled during simulated recording"); return }
	if err := cloud.UpdateStatus(ctx, jobID, domain.Uploading, ""); err != nil { fail(cloud, logger, jobID, err.Error()); return }
	body := fmt.Sprintf("meeting-bot demo artifact\njob_id=%s\nstarted_at=%s\nfinished_at=%s\nsimulated_duration_seconds=%d\nno real meeting service was contacted\n", jobID, started.Format(time.RFC3339), time.Now().UTC().Format(time.RFC3339), duration)
	key, err := cloud.UploadArtifact(ctx, jobID, body)
	if err != nil { span.RecordError(err); span.SetStatus(codes.Error, "artifact upload failed"); fail(cloud, logger, jobID, err.Error()); return }
	if err := cloud.SetArtifactKey(ctx, jobID, key); err != nil { fail(cloud, logger, jobID, err.Error()); return }
	if err := cloud.EnqueueDelivery(ctx, jobID, key); err != nil { fail(cloud, logger, jobID, err.Error()); return }
	if err := cloud.UpdateStatus(ctx, jobID, domain.Completed, ""); err != nil { fail(cloud, logger, jobID, err.Error()); return }
	logger.Info("meeting simulation completed", "job_id", jobID, "artifact_key", key)
}

func sleep(ctx context.Context, duration time.Duration) bool {
	timer := time.NewTimer(duration)
	defer timer.Stop()
	select { case <-ctx.Done(): return false; case <-timer.C: return true }
}

func fail(cloud *awsx.Cloud, logger *slog.Logger, jobID, message string) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	_ = cloud.UpdateStatus(ctx, jobID, domain.Failed, message)
	logger.Error("meeting simulation failed", "job_id", jobID, "error", message)
}
