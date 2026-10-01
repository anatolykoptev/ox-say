//go:build linux

package engine

import (
	"os"
	"os/exec"
	"testing"
)

// The Linux start token is /proc/<pid>/stat field 22: a bare tick count.
func TestProcessStartTimeFormat(t *testing.T) {
	tok, err := processStartTime(os.Getpid())
	if err != nil {
		t.Fatal(err)
	}
	if tok == "" {
		t.Fatal("empty start token")
	}
	for _, r := range tok {
		if r < '0' || r > '9' {
			t.Fatalf("start token %q is not a bare tick count", tok)
		}
	}

	// A reaped process has no start time to read.
	c := exec.Command("true")
	if err := c.Run(); err != nil {
		t.Fatal(err)
	}
	if _, err := processStartTime(c.Process.Pid); err == nil {
		t.Fatal("start token read for a reaped process")
	}
}
