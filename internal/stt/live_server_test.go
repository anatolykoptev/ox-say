package stt

import (
	"context"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"
)

// Live captions decode on the resident server and nowhere else. A body goes out as audio/wav, the answer is the
// engine's JSON, and the server's release runs.
func TestTranscribeWAVViaServerPostsTheWAVAndReleases(t *testing.T) {
	var gotType string
	var gotBody []byte
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotType = r.Header.Get("Content-Type")
		gotBody, _ = io.ReadAll(r.Body)
		_, _ = io.WriteString(w, `{"text":"hello there"}`)
	}))
	defer srv.Close()
	var released atomic.Int32
	res, err := TranscribeWAVViaServer(context.Background(), []byte("RIFFwav"), Options{
		Server: func(context.Context) (string, func(), error) { return srv.URL, func() { released.Add(1) }, nil },
	})
	if err != nil || res.Text != "hello there" {
		t.Fatalf("res %+v err %v", res, err)
	}
	if gotType != "audio/wav" || string(gotBody) != "RIFFwav" || released.Load() != 1 {
		t.Fatalf("type %q body %q released %d", gotType, gotBody, released.Load())
	}
}

// What the worker needs to tell apart: the server answering no (a verdict on the audio) from the server not being
// there (no verdict) — and no server at all must not fall back to the per-call CLI, which would load a second model.
// Mutation: internal/stt/stt.go postWAV, return a plain error for the non-200 case -> RED (a refusal reads as outage).
func TestTranscribeWAVViaServerSeparatesRefusalFromOutage(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		http.Error(w, "decode failed", http.StatusInternalServerError)
	}))
	defer srv.Close()
	var rej *ServerRejection
	_, err := TranscribeWAVViaServer(context.Background(), []byte("x"), Options{
		Server: func(context.Context) (string, func(), error) { return srv.URL, func() {}, nil },
	})
	if !errors.As(err, &rej) {
		t.Fatalf("a 500 from the server is %T %v, want *ServerRejection", err, err)
	}

	cooling := errors.New("stt server cooling down")
	_, err = TranscribeWAVViaServer(context.Background(), []byte("x"), Options{
		Server: func(context.Context) (string, func(), error) { return "", nil, cooling },
	})
	if errors.As(err, &rej) || !errors.Is(err, cooling) {
		t.Fatalf("an unavailable server is %v, want the acquire error and not a rejection", err)
	}

	if _, err = TranscribeWAVViaServer(context.Background(), []byte("x"), Options{Bin: "/nonexistent/ox-stt"}); err == nil || errors.As(err, &rej) {
		t.Fatalf("no server: %v, want a plain error and no CLI run", err)
	}
}
