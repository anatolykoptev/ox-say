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
)

// HTTPChat speaks the OpenAI chat-completions protocol — llama-server's, and
// any compatible cloud endpoint's. BaseURL has no trailing slash.
type HTTPChat struct {
	BaseURL string
	// Key returns the bearer token, read per call: the daemon rewrites the
	// local server's key file on every spawn.
	Key    func() (string, error)
	Client *http.Client
}

// ErrTruncated: the model stopped at the token limit, so a structured answer
// is cut off.
var ErrTruncated = errors.New("meeting: the model's answer hit the token limit")

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
		req.Header.Set("Authorization", "Bearer "+key)
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
		return "", fmt.Errorf("meeting: notes model answered %d: %s", resp.StatusCode, strings.TrimSpace(string(data[:min(len(data), 300)])))
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
	if out.Choices[0].FinishReason == "length" && r.Schema != nil {
		return "", ErrTruncated
	}
	return out.Choices[0].Message.Content, nil
}
