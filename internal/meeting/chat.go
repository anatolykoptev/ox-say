package meeting

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"
	"unicode/utf8"
)

// HTTPChat speaks the OpenAI chat-completions protocol — llama-server's, and
// any compatible cloud endpoint's. BaseURL has no trailing slash.
//
// The caller must not set Client.Timeout: it caps the whole exchange, and a
// notes call on a slow CPU legitimately runs for many minutes. The Composer
// puts a deadline on every call through the request context instead.
type HTTPChat struct {
	BaseURL string
	// Key returns the bearer token, read per call: the daemon rewrites the
	// local server's key file on every spawn.
	Key    func() (string, error)
	Client *http.Client
}

// ErrTruncated: the model stopped at the token limit, so its answer, structured
// or free text, is cut off.
var ErrTruncated = errors.New("meeting: the model's answer hit the token limit")

// StatusError: the model server answered with a status other than 200. Detail
// is the server's own error type and message, never the raw body: a body can
// echo the prompt, and the prompt is the user's meeting.
type StatusError struct {
	Code   int
	Detail string
}

func (e *StatusError) Error() string {
	if e.Detail == "" {
		return fmt.Sprintf("meeting: notes model answered %d", e.Code)
	}
	return fmt.Sprintf("meeting: notes model answered %d: %s", e.Code, e.Detail)
}

// maxDetail caps the error message kept from the server, in characters.
const maxDetail = 200

// errorDetail reads llama-server's {"error":{"type":..,"message":..}}; any
// other body gives "".
func errorDetail(data []byte) string {
	var e struct {
		Error struct {
			Type    string `json:"type"`
			Message string `json:"message"`
		} `json:"error"`
	}
	if json.Unmarshal(data, &e) != nil {
		return ""
	}
	d := strings.TrimSpace(strings.TrimSpace(e.Error.Type) + " " + strings.Join(strings.Fields(e.Error.Message), " "))
	if utf8.RuneCountInString(d) > maxDetail {
		d = string([]rune(d)[:maxDetail])
	}
	return d
}

type chatBody struct {
	Messages       []chatMessage  `json:"messages"`
	Temperature    float64        `json:"temperature"`
	TopP           float64        `json:"top_p"`
	MaxTokens      int            `json:"max_tokens"`
	CachePrompt    bool           `json:"cache_prompt"`
	ResponseFormat map[string]any `json:"response_format,omitempty"`
	TemplateArgs   map[string]any `json:"chat_template_kwargs"`
}

type chatMessage struct {
	Role    string `json:"role"`
	Content string `json:"content"`
}

// Complete sends one system+user exchange. Thinking is switched off: the
// notes spike measured Qwen3.5 without it (chat_template_kwargs).
func (h HTTPChat) Complete(ctx context.Context, r Request) (string, error) {
	body := chatBody{
		Messages:     []chatMessage{{"system", r.System}, {"user", r.User}},
		Temperature:  0.3,
		TopP:         0.9,
		CachePrompt:  true, // every call shares its system prompt; llama-server reuses the prefix
		MaxTokens:    r.MaxTokens,
		TemplateArgs: map[string]any{"enable_thinking": false},
	}
	if r.Schema != nil {
		body.ResponseFormat = map[string]any{
			"type":        "json_schema",
			"json_schema": map[string]any{"name": "notes", "strict": true, "schema": r.Schema},
		}
	}
	raw, err := json.Marshal(body)
	if err != nil {
		return "", err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, h.BaseURL+"/v1/chat/completions", bytes.NewReader(raw))
	if err != nil {
		return "", err
	}
	req.Header.Set("Content-Type", "application/json")
	if h.Key != nil {
		key, err := h.Key()
		if err != nil {
			return "", err
		}
		req.Header.Set("Authorization", "Bearer "+strings.TrimSpace(key))
	}
	client := h.Client
	if client == nil {
		client = http.DefaultClient
	}
	resp, err := client.Do(req)
	if err != nil {
		return "", err
	}
	defer func() { _ = resp.Body.Close() }()
	data, err := io.ReadAll(io.LimitReader(resp.Body, 8<<20))
	if err != nil {
		return "", err
	}
	if resp.StatusCode != http.StatusOK {
		return "", &StatusError{Code: resp.StatusCode, Detail: errorDetail(data)}
	}
	var out struct {
		Choices []struct {
			Message      chatMessage `json:"message"`
			FinishReason string      `json:"finish_reason"`
		} `json:"choices"`
	}
	if err := json.Unmarshal(data, &out); err != nil || len(out.Choices) == 0 {
		return "", fmt.Errorf("meeting: notes model sent an answer the daemon cannot read")
	}
	if out.Choices[0].FinishReason == "length" {
		return "", ErrTruncated
	}
	return out.Choices[0].Message.Content, nil
}
