package main

import (
	"context"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/example/meeting-bot-platform/services/internal/api"
	"github.com/example/meeting-bot-platform/services/internal/awsx"
	"github.com/example/meeting-bot-platform/services/internal/telemetry"
	"go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp"
)

func main() {
	logger := slog.New(slog.NewJSONHandler(os.Stdout, nil))
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()
	shutdownTelemetry, err := telemetry.Init(ctx, "bot-api")
	if err != nil { logger.Error("telemetry initialization failed", "error", err); os.Exit(1) }
	defer func() { _ = shutdownTelemetry(context.Background()) }()
	cloud, err := awsx.New(ctx)
	if err != nil { logger.Error("AWS client initialization failed", "error", err); os.Exit(1) }
	token := os.Getenv("API_BEARER_TOKEN")
	if token == "" { logger.Error("API_BEARER_TOKEN is required"); os.Exit(1) }
	handler := otelhttp.NewHandler(api.NewServer(cloud, token, os.Getenv("APP_VERSION"), logger), "http.server")
	server := &http.Server{Addr: ":8443", Handler: handler, ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 15 * time.Second, WriteTimeout: 30 * time.Second, IdleTimeout: 60 * time.Second}
	go func() {
		ticker := time.NewTicker(3 * time.Second)
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done(): return
			case <-ticker.C:
				if err := cloud.DispatchOutbox(ctx); err != nil { logger.Warn("outbox dispatch retry", "error", err) }
			}
		}
	}()
	go func() {
		<-ctx.Done()
		shutdown, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		_ = server.Shutdown(shutdown)
	}()
	logger.Info("API listening", "addr", server.Addr)
	if err := server.ListenAndServeTLS(os.Getenv("TLS_CERT_FILE"), os.Getenv("TLS_KEY_FILE")); err != nil && err != http.ErrServerClosed {
		logger.Error("API server stopped", "error", err)
		os.Exit(1)
	}
}
