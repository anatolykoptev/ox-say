package voiceclean

import (
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"time"
)

const scratchPrefix = "voice-clean."

// StaleScratchAge is how old a scratch directory must be before the start-up sweep takes it: longer than any run can
// last (the daemon stops a run after 3 hours), so a directory this old is no run's.
const StaleScratchAge = 6 * time.Hour

// SweepStale removes the scratch directories a killed run left in dir (the TMPDIR a run would use): a SIGKILL skips
// the run's own cleanup and ~130 MB of WAVs stay. Only a directory this tool created is touched: a real directory
// (not a link) named voice-clean.<random>, owned by the current user, last modified more than maxAge ago. Each is
// removed by its exact path; nothing is matched by glob and nothing else in dir is looked at. It returns the paths
// removed.
func SweepStale(dir string, maxAge time.Duration) []string {
	return sweepStale(dir, maxAge, time.Now(), os.Getuid())
}

func sweepStale(dir string, maxAge time.Duration, now time.Time, uid int) []string {
	es, err := os.ReadDir(dir)
	if err != nil {
		return nil
	}
	var removed []string
	for _, e := range es {
		name := e.Name()
		if !strings.HasPrefix(name, scratchPrefix) || len(name) == len(scratchPrefix) || !e.IsDir() {
			continue
		}
		p := filepath.Join(dir, name)
		st, err := os.Lstat(p)
		if err != nil || !st.IsDir() {
			continue
		}
		if sys, ok := st.Sys().(*syscall.Stat_t); !ok || int(sys.Uid) != uid {
			continue
		}
		if now.Sub(st.ModTime()) <= maxAge {
			continue
		}
		if os.RemoveAll(p) == nil {
			removed = append(removed, p)
		}
	}
	return removed
}
