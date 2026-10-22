package api

import (
	"context"
	"crypto/subtle"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"strings"

	"github.com/example/meeting-bot-platform/services/internal/domain"
)

type Backend interface {
	CreateJob(context.Context, domain.CreateRequest, string) (domain.Job, bool, error)
	GetJob(context.Context, string) (domain.Job, error)
	CancelJob(context.Context, string) (domain.Job, error)
	GetArtifactURL(context.Context, string) (string, error)
	DispatchOutbox(context.Context) error
}

type Server struct {
	backend Backend
	token   string
	log     *slog.Logger
}

func NewServer(backend Backend, token string, logger *slog.Logger) http.Handler {
	s := &Server{backend: backend, token: token, log: logger}
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(http.StatusNoContent) })
	mux.Handle("POST /bots", s.auth(http.HandlerFunc(s.create)))
	mux.Handle("GET /bots/{id}", s.auth(http.HandlerFunc(s.get)))
	mux.Handle("GET /bots/{id}/artifact", s.auth(http.HandlerFunc(s.artifact)))
	mux.Handle("POST /bots/{id}/cancel", s.auth(http.HandlerFunc(s.cancel)))
	return mux
}

func (s *Server) auth(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		parts := strings.SplitN(r.Header.Get("Authorization"), " ", 2)
		if s.token == "" || len(parts) != 2 || !strings.EqualFold(parts[0], "Bearer") || subtle.ConstantTimeCompare([]byte(parts[1]), []byte(s.token)) != 1 {
			writeError(w, http.StatusUnauthorized, "unauthorized")
			return
		}
		next.ServeHTTP(w, r)
	})
}

func (s *Server) create(w http.ResponseWriter, r *http.Request) {
	r.Body = http.MaxBytesReader(w, r.Body, 1<<20)
	decoder := json.NewDecoder(r.Body)
	decoder.DisallowUnknownFields()
	var req domain.CreateRequest
	if err := decoder.Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid JSON request")
		return
	}
	if err := decoder.Decode(&struct{}{}); !errors.Is(err, io.EOF) {
		writeError(w, http.StatusBadRequest, "request must contain one JSON object")
		return
	}
	if err := domain.ValidateRequest(req); err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	key := strings.TrimSpace(r.Header.Get("Idempotency-Key"))
	if len(key) > 128 {
		writeError(w, http.StatusBadRequest, "Idempotency-Key must be at most 128 characters")
		return
	}
	job, duplicate, err := s.backend.CreateJob(r.Context(), req, key)
	if err != nil {
		if errors.Is(err, domain.ErrIdempotencyConflict) {
			writeError(w, http.StatusConflict, err.Error())
			return
		}
		s.log.Error("failed to create bot job", "error", err)
		writeError(w, http.StatusInternalServerError, "could not create job")
		return
	}
	if err := s.backend.DispatchOutbox(r.Context()); err != nil {
		// The durable outbox will retry. The job was committed, so return its ID.
		s.log.Warn("outbox dispatch delayed", "job_id", job.ID, "error", err)
	}
	status := http.StatusAccepted
	if duplicate { status = http.StatusOK }
	w.Header().Set("Location", "/bots/"+job.ID)
	writeJSON(w, status, job)
}

func (s *Server) get(w http.ResponseWriter, r *http.Request) {
	job, err := s.backend.GetJob(r.Context(), r.PathValue("id"))
	if err != nil {
		if err.Error() == "job not found" { writeError(w, http.StatusNotFound, "job not found"); return }
		s.log.Error("failed to read bot job", "error", err)
		writeError(w, http.StatusInternalServerError, "could not read job")
		return
	}
	writeJSON(w, http.StatusOK, job)
}

func (s *Server) artifact(w http.ResponseWriter, r *http.Request) {
	url, err := s.backend.GetArtifactURL(r.Context(), r.PathValue("id"))
	if err != nil {
		if errors.Is(err, domain.ErrArtifactNotReady) {
			writeError(w, http.StatusConflict, err.Error())
			return
		}
		if err.Error() == "job not found" {
			writeError(w, http.StatusNotFound, "job not found")
			return
		}
		s.log.Error("failed to create artifact download URL", "error", err)
		writeError(w, http.StatusInternalServerError, "could not retrieve artifact")
		return
	}
	http.Redirect(w, r, url, http.StatusTemporaryRedirect)
}

func (s *Server) cancel(w http.ResponseWriter, r *http.Request) {
	job, err := s.backend.CancelJob(r.Context(), r.PathValue("id"))
	if err != nil {
		if err.Error() == "job not found" { writeError(w, http.StatusNotFound, "job not found"); return }
		s.log.Error("failed to cancel bot job", "error", err)
		writeError(w, http.StatusConflict, "job could not be cancelled")
		return
	}
	if err := s.backend.DispatchOutbox(r.Context()); err != nil { s.log.Warn("cancel dispatch delayed", "job_id", job.ID, "error", err) }
	writeJSON(w, http.StatusAccepted, job)
}

func writeJSON(w http.ResponseWriter, status int, value any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(value)
}

func writeError(w http.ResponseWriter, status int, message string) {
	writeJSON(w, status, map[string]string{"error": message})
}
