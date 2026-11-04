package voiceclean

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"time"
)

const scratchPrefix = "voice-clean."

// markerName is the file this code puts in every scratch directory it creates and keeps locked (flock) for the whole
// run. The shell script voice-clean makes $TMPDIR/voice-clean.XXXXXX too, and a user may park a voice-clean.notes
// directory there: the marker is what says "this one is ours", and the lock what says "and nobody is using it".
const markerName = ".ox-say-voiceclean"

// claimScratch marks a directory this run just created as ours and locks it for the life of the returned file; the
// run closes the file when it is done (or the process dies, which releases the lock, and the sweep may then take it).
func claimScratch(dir string) (*os.File, error) {
	f, err := os.OpenFile(filepath.Join(dir, markerName), os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o600)
	if err != nil {
		return nil, err
	}
	if err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		_ = f.Close()
		return nil, err
	}
	_, _ = fmt.Fprintf(f, "pid=%d start=%s\n", os.Getpid(), time.Now().UTC().Format(time.RFC3339))
	return f, nil
}

// StaleScratchAge is how old a scratch directory must be before the start-up sweep takes it: longer than any run can
// last (the daemon stops a run after 3 hours), so a directory this old is no run's.
const StaleScratchAge = 6 * time.Hour

// SweepStale removes the scratch directories a killed run left in dir (the TMPDIR a run would use): a SIGKILL skips
// the run's own cleanup and ~130 MB of WAVs stay. Only a directory this code created is touched: a real directory
// (not a link) named voice-clean.<random>, owned by the current user, holding the marker file, whose lock nobody
// holds (a live run, of this process or another, holds it), and last modified more than maxAge ago. Each is
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
		if removeIfUnclaimed(p) {
			removed = append(removed, p)
		}
	}
	return removed
}

// removeIfUnclaimed removes dir when it carries the marker (a regular file, not a link) and the marker's lock is free;
// the lock is held while the directory goes, so a run cannot start using it midway.
func removeIfUnclaimed(dir string) bool {
	m := filepath.Join(dir, markerName)
	if st, err := os.Lstat(m); err != nil || !st.Mode().IsRegular() {
		return false
	}
	f, err := os.OpenFile(m, os.O_RDONLY|syscall.O_NOFOLLOW, 0)
	if err != nil {
		return false
	}
	defer f.Close()
	if syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB) != nil {
		return false
	}
	return os.RemoveAll(dir) == nil
}
