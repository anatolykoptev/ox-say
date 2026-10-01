package cli

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func fileSize(t *testing.T, p string) int64 {
	t.Helper()
	st, err := os.Stat(p)
	if err != nil {
		t.Fatal(err)
	}
	return st.Size()
}

// capLog must leave the next write at the start of the file whether or not
// the descriptor is O_APPEND (launchd's is; a shell `2>log` is not).
func TestCapLog(t *testing.T) {
	for _, tc := range []struct {
		name  string
		flags int
		fill  int
		want  int64 // size after capLog and a 3-byte write
	}{
		{"append over cap", os.O_WRONLY | os.O_CREATE | os.O_APPEND, 2048, 3},
		{"plain over cap", os.O_WRONLY | os.O_CREATE, 2048, 3},
		{"append at cap", os.O_WRONLY | os.O_CREATE | os.O_APPEND, 1024, 1027},
	} {
		t.Run(tc.name, func(t *testing.T) {
			p := filepath.Join(t.TempDir(), "ox-say.log")
			f, err := os.OpenFile(p, tc.flags, 0o644)
			if err != nil {
				t.Fatal(err)
			}
			defer f.Close()
			if _, err := f.Write([]byte(strings.Repeat("x", tc.fill))); err != nil {
				t.Fatal(err)
			}
			if err := capLog(f, 1024); err != nil {
				t.Fatalf("capLog: %v", err)
			}
			if _, err := f.Write([]byte("abc")); err != nil {
				t.Fatal(err)
			}
			if got := fileSize(t, p); got != tc.want {
				t.Fatalf("size = %d, want %d", got, tc.want)
			}
		})
	}
}

func TestCapLogLeavesPipeAlone(t *testing.T) {
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	defer r.Close()
	defer w.Close()
	if err := capLog(w, 0); err != nil {
		t.Fatalf("capLog on a pipe: %v", err)
	}
}

// The serve logger caps the file once at start (a launchd crash loop restarts
// every 10 s) and again on every tick while the daemon runs.
func TestServeLoggerCapsAtStartAndPeriodically(t *testing.T) {
	p := filepath.Join(t.TempDir(), "ox-say.log")
	f, err := os.OpenFile(p, os.O_WRONLY|os.O_CREATE|os.O_APPEND, 0o644)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	big := []byte(strings.Repeat("x", 4096))
	if _, err := f.Write(big); err != nil {
		t.Fatal(err)
	}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	logger := newServeLogger(ctx, f, 1024, 20*time.Millisecond)
	if got := fileSize(t, p); got != 0 {
		t.Fatalf("size after start = %d, want 0 (not capped at start)", got)
	}

	if _, err := f.Write(big); err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(5 * time.Second)
	for fileSize(t, p) > 1024 {
		if time.Now().After(deadline) {
			t.Fatalf("size still %d after 5 s of 20 ms ticks (no periodic cap)", fileSize(t, p))
		}
		time.Sleep(10 * time.Millisecond)
	}

	cancel()
	logger.Info("after cap")
	b, err := os.ReadFile(p)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(string(b), "time=") {
		t.Fatalf("log after cap starts with %q, want a fresh line", firstBytes(b, 20))
	}
}

func firstBytes(b []byte, n int) string {
	if len(b) < n {
		n = len(b)
	}
	return string(b[:n])
}
