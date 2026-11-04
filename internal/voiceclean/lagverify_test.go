package voiceclean

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
)

// isPartProbe reports whether a Runner call is the lag check's ffprobe of the part file.
func isPartProbe(bin string, args []string) bool {
	return strings.Contains(bin, "ffprobe") && len(args) > 0 && strings.HasSuffix(args[len(args)-1], ".part")
}

// leftovers lists the part files beside out.
func leftovers(t *testing.T, out string) []string {
	t.Helper()
	ents, err := os.ReadDir(filepath.Dir(out))
	must(t, err)
	var left []string
	for _, e := range ents {
		if strings.HasSuffix(e.Name(), ".part") {
			left = append(left, e.Name())
		}
	}
	return left
}

// refused runs a video clean with the given Runner wrapper and skew and asserts lag_unverified with nothing published.
func refused(t *testing.T, skew float64, wrap func(real Runner) Runner) {
	t.Helper()
	requireTools(t)
	requireEncoder(t, "mpeg4")
	requireEncoder(t, "aac")
	in := makeOffsetClip(t, "mp4", "mpeg4", "aac", 0, 1.5)
	o := opts(t, in, filepath.Join(t.TempDir(), "o.mp4"), 0.85, fakeEngine(t, "1"))
	o.offsetSkew = skew
	if wrap != nil {
		o.Run = wrap(execRunner)
	}
	r, err := Run(context.Background(), o)
	wantCode(t, err, CodeLagUnverified)
	if r != nil {
		t.Errorf("a refused run returned a Result: %+v", r)
	}
	if e := err.(*Error); e.Status != 502 {
		t.Errorf("status = %d, want 502", e.Status)
	}
	if _, serr := os.Stat(o.Out); !os.IsNotExist(serr) {
		t.Errorf("Out exists after a refusal (stat err %v)", serr)
	}
	if left := leftovers(t, o.Out); len(left) != 0 {
		t.Errorf("part files left behind: %v", left)
	}
}

func TestLagBeyondTheCeilingIsRefused(t *testing.T) {
	t.Parallel()
	refused(t, 5, nil)
}

func TestACorrectionThatDoesNotLandIsRefused(t *testing.T) {
	t.Parallel()
	refused(t, -0.04, func(real Runner) Runner {
		var mu sync.Mutex
		var first string
		return func(ctx context.Context, bin string, args []string) ([]byte, error) {
			if strings.Contains(bin, "ffmpeg") && len(args) > 0 && strings.HasSuffix(args[len(args)-1], ".part") {
				for i := range args {
					if args[i] != "-itsoffset" {
						continue
					}
					mu.Lock()
					if first == "" {
						first = args[i+1]
					} else {
						// the second mux (the correction) is made to ask for the same offset again, so it cannot land
						args = append([]string(nil), args...)
						args[i+1] = first
					}
					mu.Unlock()
				}
			}
			return real(ctx, bin, args)
		}
	})
}

func TestAProbeFailureOnTheOutputIsRefused(t *testing.T) {
	t.Parallel()
	refused(t, 0, func(real Runner) Runner {
		return func(ctx context.Context, bin string, args []string) ([]byte, error) {
			if isPartProbe(bin, args) {
				return nil, os.ErrInvalid
			}
			return real(ctx, bin, args)
		}
	})
}

func TestAnOutputWithNoVideoIsRefused(t *testing.T) {
	t.Parallel()
	refused(t, 0, func(real Runner) Runner {
		return func(ctx context.Context, bin string, args []string) ([]byte, error) {
			raw, err := real(ctx, bin, args)
			if err != nil || !isPartProbe(bin, args) {
				return raw, err
			}
			var doc map[string]any
			must(t, json.Unmarshal(raw, &doc))
			var keep []any
			for _, s := range doc["streams"].([]any) {
				if s.(map[string]any)["codec_type"] != "video" {
					keep = append(keep, s)
				}
			}
			doc["streams"] = keep
			return json.Marshal(doc)
		}
	})
}

func TestACorrectedRunReportsTheMeasuredLag(t *testing.T) {
	requireTools(t)
	requireEncoder(t, "mpeg4")
	requireEncoder(t, "aac")
	t.Parallel()
	in := makeOffsetClip(t, "mp4", "mpeg4", "aac", 0, 1.5)
	o := opts(t, in, filepath.Join(t.TempDir(), "o.mp4"), 0.85, fakeEngine(t, "1"))
	o.offsetSkew = -0.04 // the first mux is 40 ms off, so the correction runs
	r := mustRun(t, o)
	lagIn := startTime(t, in, "a:0") - startTime(t, in, "v:0")
	lagOut := startTime(t, o.Out, "a:0") - startTime(t, o.Out, "v:0")
	if d := (lagOut - lagIn) * 1000; d-r.LagMs > 0.01 || r.LagMs-d > 0.01 {
		t.Errorf("Result.LagMs = %.4f ms, but the published file differs from the input by %.4f ms", r.LagMs, d)
	}
	if r.LagMs > 1.0+1e-6 || r.LagMs < -1.0-1e-6 {
		t.Errorf("Result.LagMs = %.4f ms, outside the 1 ms tolerance", r.LagMs)
	}
}

func TestANormalRunIsUnchangedAndWithinTolerance(t *testing.T) {
	requireTools(t)
	requireEncoder(t, "mpeg4")
	requireEncoder(t, "aac")
	t.Parallel()
	in := makeOffsetClip(t, "mp4", "mpeg4", "aac", 0, 1.5)
	o := opts(t, in, filepath.Join(t.TempDir(), "o.mp4"), 0.85, fakeEngine(t, "1"))
	r := mustRun(t, o)
	if !r.Video || r.LagMs > 1.0+1e-6 || r.LagMs < -1.0-1e-6 {
		t.Errorf("Video=%v LagMs=%.4f", r.Video, r.LagMs)
	}
	if left := leftovers(t, o.Out); len(left) != 0 {
		t.Errorf("part files left behind: %v", left)
	}
}

// A gap of exactly the tolerance, as a float that rounding left a hair above it, is not a reason to mux again.
func TestLagWithinTakesTheToleranceInclusively(t *testing.T) {
	for _, d := range []float64{0, 0.001, -0.001, 0.001 + 1e-12, -(0.001 + 1e-12)} {
		if !lagWithin(d) {
			t.Errorf("lagWithin(%v) = false, want true", d)
		}
	}
	for _, d := range []float64{0.0011, -0.0011, 0.002} {
		if lagWithin(d) {
			t.Errorf("lagWithin(%v) = true, want false", d)
		}
	}
}
