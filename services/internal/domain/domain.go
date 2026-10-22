package domain

import (
	"errors"
	"fmt"
	"net/url"
	"strings"
	"time"
)

const (
	Requested       = "REQUESTED"
	Queued          = "QUEUED"
	Starting        = "STARTING"
	Joining         = "JOINING"
	Recording       = "RECORDING"
	Uploading       = "UPLOADING"
	Completed       = "COMPLETED"
	Failed          = "FAILED"
	CancelRequested = "CANCEL_REQUESTED"
	Cancelled       = "CANCELLED"
)

var ErrInvalidMeetingURL = errors.New("meetingUrl must be an HTTPS URL for a supported meeting provider")
var ErrIdempotencyConflict = errors.New("Idempotency-Key was already used with a different request")
var ErrArtifactNotReady = errors.New("artifact is not ready")

type CreateRequest struct {
	MeetingURL      string `json:"meetingUrl"`
	DurationSeconds int    `json:"durationSeconds"`
}

type Job struct {
	ID              string    `json:"jobId" dynamodbav:"jobId"`
	Status          string    `json:"status" dynamodbav:"status"`
	MeetingURL      string    `json:"-" dynamodbav:"meetingUrl"`
	DurationSeconds int       `json:"durationSeconds" dynamodbav:"durationSeconds"`
	ArtifactKey     string    `json:"artifactKey,omitempty" dynamodbav:"artifactKey,omitempty"`
	DeliveryStatus  string    `json:"deliveryStatus,omitempty" dynamodbav:"deliveryStatus,omitempty"`
	Error           string    `json:"error,omitempty" dynamodbav:"error,omitempty"`
	CreatedAt       time.Time `json:"createdAt" dynamodbav:"createdAt"`
	UpdatedAt       time.Time `json:"updatedAt" dynamodbav:"updatedAt"`
	CancelRequested bool      `json:"cancelRequested,omitempty" dynamodbav:"cancelRequested,omitempty"`
}

type Event struct {
	Kind            string            `json:"kind"`
	JobID           string            `json:"jobId"`
	DurationSeconds int               `json:"durationSeconds,omitempty"`
	TraceContext    map[string]string `json:"traceContext,omitempty"`
}

type DeliveryEvent struct {
	JobID        string            `json:"jobId"`
	ArtifactKey  string            `json:"artifactKey"`
	TraceContext map[string]string `json:"traceContext,omitempty"`
}

func ValidateRequest(req CreateRequest) error {
	if req.DurationSeconds < 10 || req.DurationSeconds > 3600 {
		return fmt.Errorf("durationSeconds must be between 10 and 3600")
	}
	u, err := url.ParseRequestURI(req.MeetingURL)
	if err != nil || u.Scheme != "https" || u.Hostname() == "" || u.User != nil {
		return ErrInvalidMeetingURL
	}
	host := strings.ToLower(u.Hostname())
	allowed := hostIsOrSubdomain(host, "meet.google.com") ||
		hostIsOrSubdomain(host, "teams.microsoft.com") ||
		hostIsOrSubdomain(host, "zoom.us") || hostIsOrSubdomain(host, "zoom.com")
	if !allowed {
		return ErrInvalidMeetingURL
	}
	return nil
}

func hostIsOrSubdomain(host, domain string) bool {
	return host == domain || strings.HasSuffix(host, "."+domain)
}

func IsTerminal(status string) bool {
	return status == Completed || status == Failed || status == Cancelled
}
