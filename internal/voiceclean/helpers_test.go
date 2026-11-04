package voiceclean

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/binary"
	"fmt"
	"math"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"testing"
)

// requireTools fails when ffmpeg or ffprobe is missing on CI and skips elsewhere: a missing tool on CI must not turn
// the suite green.
func requireTools(t *testing.T) {
	t.Helper()
	for _, tool := range []string{"ffmpeg", "ffprobe"} {
		if _, err := exec.LookPath(tool); err != nil {
			if os.Getenv("CI") != "" {
				t.Fatalf("%s is required on CI: %v", tool, err)
			}
			t.Skipf("%s not on PATH", tool)
		}
	}
}

var encoderCache sync.Map

// requireEncoder is requireTools for one codec.
func requireEncoder(t *testing.T, name string) {
	t.Helper()
	requireTools(t)
	v, ok := encoderCache.Load("list")
	if !ok {
		out, _ := exec.Command("ffmpeg", "-hide_banner", "-encoders").Output()
		v = string(out)
		encoderCache.Store("list", v)
	}
	if !strings.Contains(v.(string), " "+name+" ") {
		if os.Getenv("CI") != "" {
			t.Fatalf("ffmpeg has no %s encoder on CI", name)
		}
		t.Skipf("ffmpeg has no %s encoder", name)
	}
}

func ffrun(t *testing.T, args ...string) {
	t.Helper()
	out, err := exec.Command("ffmpeg", append([]string{"-nostdin", "-v", "error", "-y"}, args...)...).CombinedOutput()
	if err != nil {
		t.Fatalf("ffmpeg %v: %v\n%s", args, err, out)
	}
}

func fprobe(t *testing.T, args ...string) string {
	t.Helper()
	out, err := exec.Command("ffprobe", append([]string{"-v", "error"}, args...)...).Output()
	if err != nil {
		t.Fatalf("ffprobe %v: %v", args, err)
	}
	return strings.TrimSpace(string(out))
}

func tone(freq, rate int, secs float64) []string {
	return []string{"-f", "lavfi", "-i", fmt.Sprintf("sine=frequency=%d:sample_rate=%d:duration=%g", freq, rate, secs)}
}

// makeStereoWav writes two different tones, left and right.
func makeStereoWav(t *testing.T, rate int, secs float64) string {
	t.Helper()
	p := filepath.Join(t.TempDir(), "stereo.wav")
	args := append(tone(440, rate, secs), tone(660, rate, secs)...)
	ffrun(t, append(args, "-filter_complex", "[0:a][1:a]amerge=inputs=2,volume=0.5", "-c:a", "pcm_s16le", p)...)
	return p
}

func makeMonoWav(t *testing.T, rate int, secs float64) string {
	t.Helper()
	p := filepath.Join(t.TempDir(), "mono.wav")
	ffrun(t, append(tone(440, rate, secs), "-af", "volume=0.5", "-c:a", "pcm_s16le", p)...)
	return p
}

// makeMp4 is a clip with every kind of stream and metadata a cleanup must not disturb: picture, two audio tracks, a
// subtitle track, two chapters and a title tag.
func makeMp4(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	srt := filepath.Join(dir, "s.srt")
	meta := filepath.Join(dir, "m.txt")
	must(t, os.WriteFile(srt, []byte("1\n00:00:00,000 --> 00:00:01,500\nhello\n"), 0o600))
	must(t, os.WriteFile(meta, []byte(";FFMETADATA1\ntitle=Fixture title\n[CHAPTER]\nTIMEBASE=1/1000\nSTART=0\nEND=1000\ntitle=one\n[CHAPTER]\nTIMEBASE=1/1000\nSTART=1000\nEND=2000\ntitle=two\n"), 0o600))
	p := filepath.Join(dir, "in.mp4")
	args := []string{"-f", "lavfi", "-i", "testsrc=size=160x120:rate=25:duration=2"}
	args = append(args, tone(440, 48000, 2)...)
	args = append(args, tone(880, 48000, 2)...)
	args = append(args, "-i", srt, "-i", meta,
		"-map", "0:v", "-map", "1:a", "-map", "2:a", "-map", "3:s", "-map_metadata", "4", "-map_chapters", "4",
		"-c:v", "mpeg4", "-c:a", "aac", "-c:s", "mov_text", p)
	ffrun(t, args...)
	return p
}

func must(t *testing.T, err error) {
	t.Helper()
	if err != nil {
		t.Fatal(err)
	}
}

// fakeEngine is a stand-in for ox-clean: it scales its input (gain 1 = identity, 0 = silence). args: in out --models d.
func fakeEngine(t *testing.T, gain string) string {
	t.Helper()
	return writeScript(t, fmt.Sprintf("#!/bin/sh\nexec ffmpeg -nostdin -v error -y -i \"$1\" -af \"volume=%s\" -c:a pcm_f32le \"$2\"\n", gain))
}

func writeScript(t *testing.T, body string) string {
	t.Helper()
	p := filepath.Join(t.TempDir(), "ox-clean")
	must(t, os.WriteFile(p, []byte(body), 0o755))
	return p
}

// opts is a run with its own scratch directory so a test can see what was left behind.
func opts(t *testing.T, in, out string, wet float64, engine string) Options {
	t.Helper()
	scratch := filepath.Join(t.TempDir(), "scratch")
	must(t, os.MkdirAll(scratch, 0o700))
	return Options{In: in, Out: out, Wet: wet, Engine: engine, ModelsDir: "/models", TempDir: scratch}
}

func mustRun(t *testing.T, o Options) *Result {
	t.Helper()
	r, err := Run(context.Background(), o)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	return r
}

func wantCode(t *testing.T, err error, code string) {
	t.Helper()
	var e *Error
	if err == nil {
		t.Fatalf("want %s, got success", code)
	}
	if !asError(err, &e) || e.Code != code {
		t.Fatalf("want %s, got %v", code, err)
	}
}

func asError(err error, target **Error) bool {
	e, ok := err.(*Error)
	if ok {
		*target = e
	}
	return ok
}

// decodeF32 returns the interleaved float samples of a file, its channel count and rate.
func decodeF32(t *testing.T, path string) (s []float32, ch, rate int) {
	t.Helper()
	ch, _ = strconv.Atoi(fprobe(t, "-select_streams", "a:0", "-show_entries", "stream=channels", "-of", "csv=p=0", path))
	rate, _ = strconv.Atoi(fprobe(t, "-select_streams", "a:0", "-show_entries", "stream=sample_rate", "-of", "csv=p=0", path))
	out, err := exec.Command("ffmpeg", "-nostdin", "-v", "error", "-i", path, "-map", "0:a:0", "-f", "f32le", "-c:a", "pcm_f32le", "-").Output()
	if err != nil {
		t.Fatalf("decode %s: %v", path, err)
	}
	s = make([]float32, len(out)/4)
	for i := range s {
		s[i] = math.Float32frombits(binary.LittleEndian.Uint32(out[i*4:]))
	}
	return s, ch, rate
}

func rms(s []float32) float64 {
	var sum float64
	for _, v := range s {
		sum += float64(v) * float64(v)
	}
	return math.Sqrt(sum / float64(max(len(s), 1)))
}

// rmsDiffDB is the level in dBFS of the difference between two files' samples.
func rmsDiffDB(t *testing.T, a, b string) float64 {
	t.Helper()
	sa, ca, ra := decodeF32(t, a)
	sb, cb, rb := decodeF32(t, b)
	if ca != cb || ra != rb {
		t.Fatalf("layouts differ: %d ch %d Hz vs %d ch %d Hz", ca, ra, cb, rb)
	}
	if d := len(sa) - len(sb); d > 2*ca || d < -2*ca {
		t.Fatalf("lengths differ by %d samples", d/ca)
	}
	n := min(len(sa), len(sb))
	diff := make([]float32, n)
	for i := range diff {
		diff[i] = sa[i] - sb[i]
	}
	return 20 * math.Log10(rms(diff)+1e-12)
}

func rmsRatio(t *testing.T, a, b string) float64 {
	t.Helper()
	sa, _, _ := decodeF32(t, a)
	sb, _, _ := decodeF32(t, b)
	return rms(sa) / rms(sb)
}

func md5Of(t *testing.T, path string, mapArgs ...string) string {
	t.Helper()
	out, err := exec.Command("ffmpeg", append(append([]string{"-nostdin", "-v", "error", "-i", path}, mapArgs...), "-c", "copy", "-f", "md5", "-")...).Output()
	if err != nil {
		t.Fatalf("md5 %s %v: %v", path, mapArgs, err)
	}
	return strings.TrimSpace(string(out))
}

func streamLayout(t *testing.T, path string) string {
	return fprobe(t, "-show_entries", "stream=index,codec_type,codec_name", "-of", "csv=p=0", path)
}

func tag(t *testing.T, path, name string) string {
	return fprobe(t, "-show_entries", "format_tags="+name, "-of", "csv=p=0", path)
}

func chapters(t *testing.T, path string) string {
	return fprobe(t, "-show_chapters", "-show_entries", "chapter=start_time,end_time:chapter_tags=title", "-of", "csv=p=0", path)
}

func streamNum(t *testing.T, path, sel, field string) float64 {
	t.Helper()
	v, err := strconv.ParseFloat(fprobe(t, "-select_streams", sel, "-show_entries", "stream="+field, "-of", "csv=p=0", path), 64)
	if err != nil {
		t.Fatalf("%s %s of %s: %v", sel, field, path, err)
	}
	return v
}

func startTime(t *testing.T, path, sel string) float64 { return streamNum(t, path, sel, "start_time") }
func duration(t *testing.T, path, sel string) float64  { return streamNum(t, path, sel, "duration") }

func sha(t *testing.T, path string) string {
	t.Helper()
	b, err := os.ReadFile(path)
	must(t, err)
	return fmt.Sprintf("%x", sha256.Sum256(b))
}

// names lists a directory's entries, sorted by the OS.
func names(t *testing.T, dir string) string {
	t.Helper()
	es, err := os.ReadDir(dir)
	must(t, err)
	var b bytes.Buffer
	for _, e := range es {
		b.WriteString(e.Name() + "\n")
	}
	return b.String()
}

// noLeftovers fails when a run left anything in its scratch directory or a part file beside its output.
func noLeftovers(t *testing.T, o Options) {
	t.Helper()
	if n := names(t, o.TempDir); n != "" {
		t.Errorf("scratch directory not empty:\n%s", n)
	}
	for _, e := range mustGlob(t, filepath.Join(filepath.Dir(o.Out), ".voice-clean.*")) {
		t.Errorf("part file left behind: %s", e)
	}
}

func mustGlob(t *testing.T, pattern string) []string {
	t.Helper()
	m, err := filepath.Glob(pattern)
	must(t, err)
	return m
}
