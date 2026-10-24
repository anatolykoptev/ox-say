package meeting

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// The request carries what the spike measured: thinking off, the schema as a
// json_schema response format, the bearer key.
// Mutation: internal/meeting/chat.go Complete, delete the TemplateArgs line ->
// RED (Qwen3.5 would think before answering and blow the token budget).
func TestHTTPChatSendsThinkingOffSchemaAndKey(t *testing.T) {
	var got map[string]any
	var auth string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		auth = r.Header.Get("Authorization")
		_ = json.NewDecoder(r.Body).Decode(&got)
		_, _ = w.Write([]byte(`{"choices":[{"message":{"role":"assistant","content":"{\"summary\":\"x\"}"},"finish_reason":"stop"}]}`))
	}))
	defer srv.Close()
	c := HTTPChat{BaseURL: srv.URL, Key: func() (string, error) { return "k1", nil }}
	out, err := c.Complete(context.Background(), Request{System: "s", User: "u", Schema: map[string]any{"type": "object"}, MaxTokens: 100})
	if err != nil || out != `{"summary":"x"}` {
		t.Fatalf("Complete = %q, %v", out, err)
	}
	if auth != "Bearer k1" {
		t.Errorf("Authorization = %q", auth)
	}
	args, _ := got["chat_template_kwargs"].(map[string]any)
	if args["enable_thinking"] != false {
		t.Errorf("chat_template_kwargs = %v, want enable_thinking false", got["chat_template_kwargs"])
	}
	rf, _ := got["response_format"].(map[string]any)
	if rf["type"] != "json_schema" {
		t.Errorf("response_format = %v", got["response_format"])
	}
}

func TestHTTPChatErrors(t *testing.T) {
	status, body := http.StatusServiceUnavailable, "loading"
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(status)
		_, _ = w.Write([]byte(body))
	}))
	defer srv.Close()
	c := HTTPChat{BaseURL: srv.URL}
	if _, err := c.Complete(context.Background(), Request{}); err == nil || !strings.Contains(err.Error(), "503") {
		t.Fatalf("a 503 must be an error naming the status: %v", err)
	}
	status, body = http.StatusOK, `{"choices":[{"message":{"content":"{\"summ"},"finish_reason":"length"}]}`
	if _, err := c.Complete(context.Background(), Request{Schema: map[string]any{}}); err != ErrTruncated {
		t.Fatalf("a structured answer cut at the token limit = %v, want ErrTruncated", err)
	}
}
