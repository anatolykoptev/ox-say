package meeting

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// The error names the status and the server's own error fields, never the raw
// body: a body can echo the prompt, which is the user's meeting.
// Mutation: internal/meeting/chat.go Complete, put string(data) into the
// StatusError Detail -> RED.
func TestHTTPChatErrorsNeverCarryTheRawBody(t *testing.T) {
	const marker = "PRIVATE-MEETING-WORDS"
	body := `{"prompt":"` + marker + `","error":{"type":"exceed_context_size_error","message":"the request exceeds the available context size"},"echo":"` + marker + `"}`
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusBadRequest)
		_, _ = w.Write([]byte(body))
	}))
	defer srv.Close()
	_, err := HTTPChat{BaseURL: srv.URL}.Complete(context.Background(), Request{})
	var se *StatusError
	if !errors.As(err, &se) || se.Code != 400 {
		t.Fatalf("err = %v, want a StatusError 400", err)
	}
	if strings.Contains(err.Error(), marker) {
		t.Fatalf("the error carries the response body: %v", err)
	}
	for _, want := range []string{"400", "exceed_context_size_error", "exceeds the available context size"} {
		if !strings.Contains(err.Error(), want) {
			t.Errorf("error %q lacks %q", err, want)
		}
	}
	// A body that is not llama-server's error shape adds nothing.
	srv3 := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
		_, _ = w.Write([]byte("plain text echoing " + marker))
	}))
	defer srv3.Close()
	if _, err = (HTTPChat{BaseURL: srv3.URL}).Complete(context.Background(), Request{}); err == nil || strings.Contains(err.Error(), marker) || !strings.Contains(err.Error(), "500") {
		t.Fatalf("err = %v, want the status only", err)
	}
	// A message is cut by rune, not by byte.
	srv2 := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusBadRequest)
		_, _ = w.Write([]byte(`{"error":{"message":"` + strings.Repeat("ж", 500) + `"}}`))
	}))
	defer srv2.Close()
	_, err = HTTPChat{BaseURL: srv2.URL}.Complete(context.Background(), Request{})
	if err == nil || !strings.HasSuffix(err.Error(), strings.Repeat("ж", maxDetail)) || strings.Contains(err.Error(), strings.Repeat("ж", maxDetail+1)) {
		t.Fatalf("the message must be cut at %d characters, whole: %v", maxDetail, err)
	}
}

func TestHTTPChatFreeTextCutAtTheTokenLimitIsTruncated(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte(`{"choices":[{"message":{"content":"half a summ"},"finish_reason":"length"}]}`))
	}))
	defer srv.Close()
	if _, err := (HTTPChat{BaseURL: srv.URL}).Complete(context.Background(), Request{}); !errors.Is(err, ErrTruncated) {
		t.Fatalf("a free-text answer cut at the token limit = %v, want ErrTruncated", err)
	}
}

func TestHTTPChatTrimsTheKeyAndKeepsPromptCaching(t *testing.T) {
	var auth string
	var got map[string]any
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		auth = r.Header.Get("Authorization")
		_ = json.NewDecoder(r.Body).Decode(&got)
		_, _ = w.Write([]byte(`{"choices":[{"message":{"content":"ok"},"finish_reason":"stop"}]}`))
	}))
	defer srv.Close()
	c := HTTPChat{BaseURL: srv.URL, Key: func() (string, error) { return "k1\n", nil }}
	if _, err := c.Complete(context.Background(), Request{}); err != nil {
		t.Fatal(err)
	}
	if auth != "Bearer k1" {
		t.Errorf("Authorization = %q, want the key without its newline", auth)
	}
	if got["cache_prompt"] != true {
		t.Errorf("cache_prompt = %v, want true", got["cache_prompt"])
	}
}
