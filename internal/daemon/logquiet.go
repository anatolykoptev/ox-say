package daemon

import (
	"context"
	"log/slog"
	"net/http"
)

// QuietSessionChunks wraps h so the access-log line of a successful session
// audio chunk is dropped. Dictation posts a chunk every 0.5 s, which made
// these lines most of the daemon log; a failed chunk still logs, as does every
// other request.
func QuietSessionChunks(h slog.Handler) slog.Handler { return quietChunks{h} }

type quietChunks struct{ slog.Handler }

func (q quietChunks) Handle(ctx context.Context, r slog.Record) error {
	if r.Message == "request" && okChunkRecord(r) {
		return nil
	}
	return q.Handler.Handle(ctx, r)
}

func (q quietChunks) WithAttrs(as []slog.Attr) slog.Handler {
	return quietChunks{q.Handler.WithAttrs(as)}
}

func (q quietChunks) WithGroup(name string) slog.Handler {
	return quietChunks{q.Handler.WithGroup(name)}
}

// okChunkRecord reports whether r is go-mcpserver's access-log record for a
// 200 on POST /v1/audio/transcriptions/sessions/<id>/audio.
func okChunkRecord(r slog.Record) bool {
	var method, path string
	status := int64(0)
	r.Attrs(func(a slog.Attr) bool {
		switch a.Key {
		case "method":
			method = a.Value.String()
		case "path":
			path = a.Value.String()
		case "status":
			if a.Value.Kind() == slog.KindInt64 {
				status = a.Value.Int64()
			}
		}
		return true
	})
	return method == http.MethodPost && status == http.StatusOK && sttSessionAudioPath(path)
}
