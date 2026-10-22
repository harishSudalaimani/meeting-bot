package kubejobs

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"strings"
	"time"

	"github.com/example/meeting-bot-platform/services/internal/domain"
)

type Client struct { http *http.Client; endpoint string; token string }

func New() (*Client, error) {
	host := os.Getenv("KUBERNETES_SERVICE_HOST")
	port := os.Getenv("KUBERNETES_SERVICE_PORT_HTTPS")
	if port == "" { port = "443" }
	if host == "" { return nil, fmt.Errorf("in-cluster Kubernetes API is unavailable") }
	token, err := os.ReadFile("/var/run/secrets/kubernetes.io/serviceaccount/token")
	if err != nil { return nil, err }
	return &Client{http: &http.Client{Timeout: 30 * time.Second}, endpoint: "https://" + host + ":" + port, token: strings.TrimSpace(string(token))}, nil
}

func (c *Client) CreateMeetingJob(ctx context.Context, event domain.Event) error {
	image := os.Getenv("MEETING_BOT_IMAGE")
	if image == "" { return fmt.Errorf("MEETING_BOT_IMAGE is required") }
	jobName := "meeting-" + strings.ToLower(event.JobID)
	job := map[string]any{
		"apiVersion": "batch/v1", "kind": "Job",
		"metadata": map[string]any{"name": jobName, "namespace": "meeting-bot", "labels": map[string]string{"app.kubernetes.io/name": "meeting-bot", "meeting-bot/job-id": event.JobID}},
		"spec": map[string]any{
			"backoffLimit": 0, "activeDeadlineSeconds": 3700, "ttlSecondsAfterFinished": 180,
			"template": map[string]any{"metadata": map[string]any{"labels": map[string]string{"app.kubernetes.io/name": "meeting-bot", "meeting-bot/job-id": event.JobID}}, "spec": map[string]any{
				"serviceAccountName": "meeting-bot", "restartPolicy": "Never", "terminationGracePeriodSeconds": 30,
				"nodeSelector": map[string]string{"workload": "meeting-bot"},
				"tolerations": []any{map[string]string{"key": "workload", "operator": "Equal", "value": "meeting-bot", "effect": "NoSchedule"}},
				"securityContext": map[string]any{"runAsNonRoot": true, "runAsUser": 10001, "runAsGroup": 10001, "seccompProfile": map[string]string{"type": "RuntimeDefault"}},
				"containers": []any{map[string]any{"name": "meeting-bot", "image": image, "imagePullPolicy": "IfNotPresent", "env": []any{
					map[string]string{"name": "JOB_ID", "value": event.JobID}, map[string]string{"name": "DURATION_SECONDS", "value": fmt.Sprint(event.DurationSeconds)},
				}, "resources": map[string]any{"requests": map[string]string{"cpu": "750m", "memory": "1500Mi"}, "limits": map[string]string{"cpu": "1", "memory": "2Gi"}},
					"securityContext": map[string]any{"allowPrivilegeEscalation": false, "readOnlyRootFilesystem": true, "capabilities": map[string][]string{"drop": {"ALL"}}}, "volumeMounts": []any{map[string]string{"name": "tmp", "mountPath": "/tmp"}}}},
				"volumes": []any{map[string]any{"name": "tmp", "emptyDir": map[string]string{"sizeLimit": "128Mi"}}},
			}},
		},
	}
	// Keep AWS settings explicit so the workload never relies on node credentials.
	container := job["spec"].(map[string]any)["template"].(map[string]any)["spec"].(map[string]any)["containers"].([]any)[0].(map[string]any)
	baseEnv := container["env"].([]any)
	env := []any{baseEnv[0], baseEnv[1],
		map[string]any{"name": "AWS_REGION", "value": os.Getenv("AWS_REGION")},
		map[string]any{"name": "JOBS_TABLE", "value": os.Getenv("JOBS_TABLE")},
		map[string]any{"name": "ARTIFACT_BUCKET", "value": os.Getenv("ARTIFACT_BUCKET")},
		map[string]any{"name": "DELIVERY_QUEUE_URL", "value": os.Getenv("DELIVERY_QUEUE_URL")},
		map[string]any{"name": "OTEL_EXPORTER_OTLP_ENDPOINT", "value": "http://otel-collector.observability.svc.cluster.local:4318"},
		map[string]any{"name": "OTEL_SERVICE_NAME", "value": "meeting-bot-simulator"},
		map[string]any{"name": "TRACEPARENT", "value": event.TraceContext["traceparent"]},
		map[string]any{"name": "TRACESTATE", "value": event.TraceContext["tracestate"]},
	}
	container["env"] = env
	body, err := json.Marshal(job)
	if err != nil { return err }
	return c.request(ctx, http.MethodPost, "/apis/batch/v1/namespaces/meeting-bot/jobs", body, http.StatusCreated, http.StatusConflict)
}

func (c *Client) DeleteMeetingJob(ctx context.Context, jobID string) error {
	name := "meeting-" + strings.ToLower(jobID)
	body := []byte(`{"apiVersion":"v1","kind":"DeleteOptions","propagationPolicy":"Foreground"}`)
	return c.request(ctx, http.MethodDelete, "/apis/batch/v1/namespaces/meeting-bot/jobs/"+name, body, http.StatusOK, http.StatusNotFound)
}

func (c *Client) request(ctx context.Context, method, path string, body []byte, accepted ...int) error {
	req, err := http.NewRequestWithContext(ctx, method, c.endpoint+path, bytes.NewReader(body))
	if err != nil { return err }
	req.Header.Set("Authorization", "Bearer "+c.token)
	req.Header.Set("Content-Type", "application/json")
	resp, err := c.http.Do(req)
	if err != nil { return err }
	defer resp.Body.Close()
	data, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
	for _, code := range accepted { if resp.StatusCode == code { return nil } }
	return fmt.Errorf("Kubernetes API returned %s: %s", resp.Status, strings.TrimSpace(string(data)))
}
