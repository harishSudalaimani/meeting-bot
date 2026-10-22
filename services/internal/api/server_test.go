package api

import (
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/example/meeting-bot-platform/services/internal/domain"
)

type fakeBackend struct {
	job       domain.Job
	creates   int
	createErr error
}

func (f *fakeBackend) CreateJob(_ context.Context, req domain.CreateRequest, _ string) (domain.Job, bool, error) {
	if f.createErr != nil {
		return domain.Job{}, false, f.createErr
	}
	f.creates++
	f.job = domain.Job{ID: "job-1", Status: domain.Requested, MeetingURL: req.MeetingURL, DurationSeconds: req.DurationSeconds, CreatedAt: time.Now(), UpdatedAt: time.Now()}
	return f.job, f.creates > 1, nil
}
func (f *fakeBackend) GetJob(context.Context, string) (domain.Job, error)    { return f.job, nil }
func (f *fakeBackend) CancelJob(context.Context, string) (domain.Job, error) { return f.job, nil }
func (f *fakeBackend) GetArtifactURL(context.Context, string) (string, error) {
	return "https://s3.example.test/signed", nil
}
func (f *fakeBackend) DispatchOutbox(context.Context) error { return nil }

func TestVersionReportsRunningImageTagWithoutAuthentication(t *testing.T) {
	server := NewServer(&fakeBackend{}, "test-token", "git-test123", slog.New(slog.NewTextHandler(io.Discard, nil)))
	request := httptest.NewRequest(http.MethodGet, "/version", nil)
	response := httptest.NewRecorder()
	server.ServeHTTP(response, request)

	if response.Code != http.StatusOK {
		t.Fatalf("version status=%d body=%s", response.Code, response.Body.String())
	}
	var body map[string]string
	if err := json.NewDecoder(response.Body).Decode(&body); err != nil {
		t.Fatalf("decode version response: %v", err)
	}
	if body["version"] != "git-test123" {
		t.Fatalf("version=%q, want git-test123", body["version"])
	}
}

func TestCreateRequiresAuthAndAcceptsValidRequest(t *testing.T) {
	backend := &fakeBackend{}
	server := NewServer(backend, "test-token", "git-test", slog.New(slog.NewTextHandler(io.Discard, nil)))
	unauthorized := httptest.NewRequest(http.MethodPost, "/bots", strings.NewReader(`{"meetingUrl":"https://meet.google.com/abc-defg-hij","durationSeconds":60}`))
	response := httptest.NewRecorder()
	server.ServeHTTP(response, unauthorized)
	if response.Code != http.StatusUnauthorized {
		t.Fatalf("unauthorized status=%d", response.Code)
	}

	request := httptest.NewRequest(http.MethodPost, "/bots", strings.NewReader(`{"meetingUrl":"https://meet.google.com/abc-defg-hij","durationSeconds":60}`))
	request.Header.Set("Authorization", "Bearer test-token")
	request.Header.Set("Idempotency-Key", "request-1")
	response = httptest.NewRecorder()
	server.ServeHTTP(response, request)
	if response.Code != http.StatusAccepted {
		t.Fatalf("create status=%d body=%s", response.Code, response.Body.String())
	}
	if backend.creates != 1 {
		t.Fatalf("backend creates=%d", backend.creates)
	}
}

func TestCreateRejectsInvalidURL(t *testing.T) {
	server := NewServer(&fakeBackend{}, "test-token", "git-test", slog.New(slog.NewTextHandler(io.Discard, nil)))
	request := httptest.NewRequest(http.MethodPost, "/bots", strings.NewReader(`{"meetingUrl":"https://example.invalid/meeting","durationSeconds":60}`))
	request.Header.Set("Authorization", "Bearer test-token")
	response := httptest.NewRecorder()
	server.ServeHTTP(response, request)
	if response.Code != http.StatusBadRequest {
		t.Fatalf("status=%d body=%s", response.Code, response.Body.String())
	}
}

func TestCreateRejectsIdempotencyKeyReuseWithDifferentBody(t *testing.T) {
	backend := &fakeBackend{createErr: domain.ErrIdempotencyConflict}
	server := NewServer(backend, "test-token", "git-test", slog.New(slog.NewTextHandler(io.Discard, nil)))
	request := httptest.NewRequest(http.MethodPost, "/bots", strings.NewReader(`{"meetingUrl":"https://meet.google.com/abc-defg-hij","durationSeconds":60}`))
	request.Header.Set("Authorization", "Bearer test-token")
	request.Header.Set("Idempotency-Key", "same-key")
	response := httptest.NewRecorder()
	server.ServeHTTP(response, request)
	if response.Code != http.StatusConflict {
		t.Fatalf("status=%d body=%s", response.Code, response.Body.String())
	}
}

func TestArtifactRedirectRequiresAuthentication(t *testing.T) {
	server := NewServer(&fakeBackend{job: domain.Job{ID: "job-1", Status: domain.Completed}}, "test-token", "git-test", slog.New(slog.NewTextHandler(io.Discard, nil)))
	request := httptest.NewRequest(http.MethodGet, "/bots/job-1/artifact", nil)
	response := httptest.NewRecorder()
	server.ServeHTTP(response, request)
	if response.Code != http.StatusUnauthorized {
		t.Fatalf("unauthorized status=%d", response.Code)
	}
	request = httptest.NewRequest(http.MethodGet, "/bots/job-1/artifact", nil)
	request.Header.Set("Authorization", "Bearer test-token")
	response = httptest.NewRecorder()
	server.ServeHTTP(response, request)
	if response.Code != http.StatusTemporaryRedirect {
		t.Fatalf("artifact status=%d body=%s", response.Code, response.Body.String())
	}
	if got := response.Header().Get("Location"); got != "https://s3.example.test/signed" {
		t.Fatalf("redirect location=%q", got)
	}
}
