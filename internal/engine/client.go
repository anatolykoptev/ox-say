package engine

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
)

// Client talks to a running child's OpenAI-compatible HTTP API.
type Client struct {
	hc *http.Client
}

// NewClient returns a child API client. The engine has no auth; it is only
// ever reached on loopback. No client timeout: synthesis length is unbounded,
// the request context governs cancellation.
func NewClient() *Client {
	return &Client{hc: &http.Client{}}
}

// RegisterVoice POSTs a voice to /v1/audio/voices. refText is optional; when
// empty the engine clones timbre only (no transcript conditioning).
func (c *Client) RegisterVoice(ctx context.Context, baseURL, name, wavPath, refText string) error {
	wav, err := os.ReadFile(wavPath)
	if err != nil {
		return fmt.Errorf("engine: read voice wav: %w", err)
	}
	body := map[string]any{
		"name":    name,
		"wav_b64": base64.StdEncoding.EncodeToString(wav),
	}
	if refText != "" {
		body["ref_text"] = refText
	}
	raw, err := json.Marshal(body)
	if err != nil {
		return err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, baseURL+"/v1/audio/voices", bytes.NewReader(raw))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	resp, err := c.hc.Do(req)
	if err != nil {
		return fmt.Errorf("engine: register voice %q: %w", name, err)
	}
	defer resp.Body.Close()
	if resp.StatusCode/100 != 2 {
		msg, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
		return fmt.Errorf("engine: register voice %q: %s: %s", name, resp.Status, msg)
	}
	return nil
}

// DeleteVoice removes a voice from the running child.
func (c *Client) DeleteVoice(ctx context.Context, baseURL, name string) error {
	req, err := http.NewRequestWithContext(ctx, http.MethodDelete, baseURL+"/v1/audio/voices/"+name, nil)
	if err != nil {
		return err
	}
	resp, err := c.hc.Do(req)
	if err != nil {
		return fmt.Errorf("engine: delete voice %q: %w", name, err)
	}
	defer resp.Body.Close()
	if resp.StatusCode/100 != 2 {
		msg, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
		return fmt.Errorf("engine: delete voice %q: %s: %s", name, resp.Status, msg)
	}
	return nil
}

// Speech POSTs /v1/audio/speech and returns the live response. Callers own
// resp.Body. The request inherits ctx: a client disconnect must cancel the
// upstream call so a dead request stops burning GPU.
func (c *Client) Speech(ctx context.Context, baseURL string, body []byte) (*http.Response, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, baseURL+"/v1/audio/speech", bytes.NewReader(body))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/json")
	return c.hc.Do(req)
}
