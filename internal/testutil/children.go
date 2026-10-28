package testutil

import (
	"os"
	"os/exec"
	"sort"
	"strconv"
	"strings"
	"testing"
	"time"
)

// ChildProcs lists the live direct children of this test process as
// pid → command line. The listing's own ps process is left out.
func ChildProcs(t testing.TB) map[int]string {
	t.Helper()
	cmd := exec.Command("ps", "-A", "-o", "pid=,ppid=,command=")
	out, err := cmd.Output()
	if err != nil {
		t.Fatalf("list processes: %v", err)
	}
	self := os.Getpid()
	kids := map[int]string{}
	for _, line := range strings.Split(string(out), "\n") {
		f := strings.Fields(line)
		if len(f) < 3 {
			continue
		}
		pid, err1 := strconv.Atoi(f[0])
		ppid, err2 := strconv.Atoi(f[1])
		if err1 != nil || err2 != nil || ppid != self || pid == cmd.Process.Pid {
			continue
		}
		kids[pid] = strings.Join(f[2:], " ")
	}
	return kids
}

// NoNewChildren fails t when a child that was not in before is still alive
// after a short grace. Call it from a t.Cleanup registered BEFORE the one
// that shuts the thing down: cleanups run last-in first-out, so it then
// runs after the shutdown and sees what the shutdown left behind. Leaked
// children are killed so they cannot pile up across the package run.
func NoNewChildren(t testing.TB, before map[int]string) {
	t.Helper()
	var left map[int]string
	for deadline := time.Now().Add(5 * time.Second); ; {
		left = map[int]string{}
		for pid, cmd := range ChildProcs(t) {
			if _, old := before[pid]; !old {
				left[pid] = cmd
			}
		}
		if len(left) == 0 {
			return
		}
		if time.Now().After(deadline) {
			break
		}
		time.Sleep(50 * time.Millisecond)
	}
	pids := make([]int, 0, len(left))
	for pid := range left {
		pids = append(pids, pid)
	}
	sort.Ints(pids)
	for _, pid := range pids {
		t.Errorf("child process %d outlived the test: %s", pid, left[pid])
		if p, err := os.FindProcess(pid); err == nil {
			_ = p.Kill()
		}
	}
}
