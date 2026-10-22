package domain

import "testing"

func TestValidateRequest(t *testing.T) {
	tests := []struct {
		name string
		req  CreateRequest
		ok   bool
	}{
		{"google meet", CreateRequest{"https://meet.google.com/abc-defg-hij", 60}, true},
		{"teams", CreateRequest{"https://teams.microsoft.com/l/meetup-join/abc", 60}, true},
		{"zoom", CreateRequest{"https://company.zoom.us/j/123", 60}, true},
		{"unsupported host", CreateRequest{"https://example.com/meet", 60}, false},
		{"plain http", CreateRequest{"http://meet.google.com/abc", 60}, false},
		{"credential in URL", CreateRequest{"https://name:secret@meet.google.com/abc", 60}, false},
		{"invalid duration", CreateRequest{"https://meet.google.com/abc", 3601}, false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			err := ValidateRequest(tt.req)
			if (err == nil) != tt.ok {
				t.Fatalf("ValidateRequest() error = %v, want valid=%v", err, tt.ok)
			}
		})
	}
}
