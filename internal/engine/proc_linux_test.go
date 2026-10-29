//go:build linux

package engine

import (
	"os"
	"os/exec"
	"strings"
	"testing"
)

// The Linux start token is "<boot id>-<ticks>": /proc/<pid>/stat field 22 is
// boot-relative, so the boot id is part of it (#73).
func TestProcessStartTimeFormat(t *testing.T) {
	tok, err := processStartTime(os.Getpid())
	if err != nil {
		t.Fatal(err)
	}
	if tok == "" {
		t.Fatal("empty start token")
	}
	boot, err := os.ReadFile("/proc/sys/kernel/random/boot_id")
	if err != nil {
		t.Skipf("no boot id on this kernel: %v", err)
	}
	prefix := strings.TrimSpace(string(boot)) + "-"
	if !strings.HasPrefix(tok, prefix) {
		t.Fatalf("start token %q does not carry the boot id %q", tok, prefix)
	}
	for _, r := range strings.TrimPrefix(tok, prefix) {
		if r < '0' || r > '9' {
			t.Fatalf("start token %q: tick count is not numeric", tok)
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

// A missing boot id fails the read instead of minting a token without it.
func TestProcessStartTimeNeedsBootID(t *testing.T) {
	old := bootIDPath
	bootIDPath = t.TempDir() + "/absent"
	defer func() { bootIDPath = old }()
	if tok, err := processStartTime(os.Getpid()); err == nil {
		t.Fatalf("token %q minted without a boot id", tok)
	}
}
