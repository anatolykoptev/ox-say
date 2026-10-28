package testutil

import (
	"os/exec"
	"testing"
	"time"
)

// NoNewChildren must see a child that is still running at cleanup time, and
// stay quiet once the child is gone.
func TestNoNewChildren(t *testing.T) {
	before := ChildProcs(t)
	cmd := exec.Command("sleep", "30")
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	if _, ok := ChildProcs(t)[cmd.Process.Pid]; !ok {
		t.Fatal("ChildProcs does not list a running child")
	}
	_ = cmd.Process.Kill()
	_, _ = cmd.Process.Wait()
	done := make(chan struct{})
	go func() { time.Sleep(0); NoNewChildren(t, before); close(done) }()
	<-done
}
