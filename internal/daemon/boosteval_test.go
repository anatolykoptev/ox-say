//go:build boosteval

package daemon

import (
	"bufio"
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/anatolykoptev/ox-say/internal/config"
	"github.com/anatolykoptev/ox-say/internal/glossary"
	"github.com/anatolykoptev/ox-say/internal/stt"
)

// TestBoostEval drives the REAL daemon path (Daemon.Transcribe -> sttBoost -> stt.Transcribe -> the resident
// ox-stt server's POST /transcribe with X-Ox-Terms) over the synthetic spike clips, once unboosted and once
// boosted per clip, interleaved so machine drift hits both arms alike. The terms are built by the Go code
// (glossary.BoostTerms + the Russian common-word filter) from a synthetic glossary in a temp home; the
// glossary post-pass runs on every result, as the product runs it. Nothing here touches the installed
// OxSay. Run through engine/stt/eval/stage_b_eval.sh.
//
// Env: BOOST_EVAL_WORK (clips, manifests, lists — the spike's directory), BOOST_EVAL_STT (ox-stt built from
// this tree), BOOST_EVAL_MODEL, BOOST_EVAL_VAD (silero model, optional), BOOST_EVAL_OUT (jsonl results), BOOST_EVAL_ALPHA (default 2).
func TestBoostEval(t *testing.T) {
	work, bin, model, out := os.Getenv("BOOST_EVAL_WORK"), os.Getenv("BOOST_EVAL_STT"), os.Getenv("BOOST_EVAL_MODEL"), os.Getenv("BOOST_EVAL_OUT")
	if work == "" || bin == "" || model == "" || out == "" {
		t.Skip("BOOST_EVAL_WORK/STT/MODEL/OUT not set")
	}
	alpha := 2.0
	if v := os.Getenv("BOOST_EVAL_ALPHA"); v != "" {
		if err := json.Unmarshal([]byte(v), &alpha); err != nil {
			t.Fatal(err)
		}
	}
	dir := t.TempDir()
	d := newTestDaemonSTT(t, dir, func(c *config.Config) {
		c.STTBin, c.STTModel, c.STTBoostAlpha = bin, model, alpha
		// the product's own settings on this Mac: unified memory, so the resident server decodes on the GPU
		c.GPUMemory = "unified"
		c.STTVADModel = os.Getenv("BOOST_EVAL_VAD")
		c.STTTimeout = 120 * time.Second
		c.STTMaxUploadMB = 10
	}, nil, nil)

	f, err := os.Create(out)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	enc := json.NewEncoder(f)

	rows := readTSV(t, filepath.Join(work, "manifest_all.tsv"))
	// the glossary each clip sees: held-out by voice for the RU term clips, the all-observations list otherwise
	group := func(r []string) string {
		if r[1] == "term" && r[2] == "ru" {
			if r[3] == "ru-ruslan" {
				return "A"
			}
			return "B"
		}
		return "U"
	}
	for _, g := range []string{"A", "B", "U"} {
		loadGlossary(t, d, filepath.Join(work, "lists", g+".tsv"), alpha)
		n := 0
		for _, r := range rows {
			if group(r) != g {
				continue
			}
			n++
			wav := filepath.Join(work, "audio", r[0]+".wav")
			arms := []string{"base", "boost"}
			if n%2 == 0 {
				arms = []string{"boost", "base"}
			}
			for _, arm := range arms {
				d.Cfg.STTBoostAlpha = 0
				if arm == "boost" {
					d.Cfg.STTBoostAlpha = alpha
				}
				res, err := d.Transcribe(context.Background(), TranscribeInput{AudioPath: wav})
				if err != nil {
					t.Fatalf("%s %s: %v", r[0], arm, err)
				}
				raw := res.Text
				d.correctResult(res, "eval")
				if err := enc.Encode(map[string]any{"clip": r[0], "group": g, "arm": arm, "raw": raw, "text": res.Text,
					"elapsed_s": res.ElapsedS, "duration_s": res.DurationS}); err != nil {
					t.Fatal(err)
				}
			}
		}
	}
}

func readTSV(t *testing.T, path string) [][]string {
	t.Helper()
	f, err := os.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	var rows [][]string
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 1<<20), 1<<20)
	for sc.Scan() {
		if l := sc.Text(); l != "" {
			rows = append(rows, strings.Split(l, "\t"))
		}
	}
	return rows
}

// loadGlossary replaces the temp glossary with the list's pairs (heard -> written, all active) and derives
// the boost list synchronously.
func loadGlossary(t *testing.T, d *Daemon, list string, alpha float64) {
	t.Helper()
	d.Cfg.STTBoostAlpha = alpha
	if err := os.Remove(filepath.Join(d.Cfg.Home, glossary.FileName)); err != nil && !os.IsNotExist(err) {
		t.Fatal(err)
	}
	for _, r := range readTSV(t, list) {
		for _, heard := range r[1:] {
			p, err := d.Glossary.Add(heard, r[0], "")
			if err != nil {
				continue // a heard form two terms share is the first one's
			}
			if _, err := d.Glossary.Approve(p.ID); err != nil {
				t.Fatal(err)
			}
		}
	}
	d.invalidateGlossary()
	d.refreshBoost()
	if b := d.sttBoost(); len(b.Terms) == 0 {
		t.Fatalf("no boost terms derived from %s", list)
	}
	t.Logf("%s: %d boost terms: %q", filepath.Base(list), len(d.sttBoost().Terms), d.sttBoost().Terms)
}

// TestCivicEval transcribes civic-eval windows (seg.wav under BOOST_CIVIC_DIR/<id>/) through the same daemon
// path, once unboosted and once per term set in BOOST_CIVIC_TERMS (a JSON file {"<id>": {"<set>": ["Name", ...]}}):
// the set's names are injected as plain term lines (written form only: English speech, no heard form exists for
// a roster). Writes <id>@<set>/ox.json in the shape civic_eval.py reads. Run through civic_stage_b.sh.
func TestCivicEval(t *testing.T) {
	root, bin, model, termsFile := os.Getenv("BOOST_CIVIC_DIR"), os.Getenv("BOOST_EVAL_STT"), os.Getenv("BOOST_EVAL_MODEL"), os.Getenv("BOOST_CIVIC_TERMS")
	if root == "" || bin == "" || model == "" || termsFile == "" {
		t.Skip("BOOST_CIVIC_DIR/TERMS, BOOST_EVAL_STT/MODEL not set")
	}
	raw, err := os.ReadFile(termsFile)
	if err != nil {
		t.Fatal(err)
	}
	var sets map[string]map[string][]string
	if err := json.Unmarshal(raw, &sets); err != nil {
		t.Fatal(err)
	}
	alpha := 2.0
	d := newTestDaemonSTT(t, t.TempDir(), func(c *config.Config) {
		c.STTBin, c.STTModel, c.STTBoostAlpha = bin, model, alpha
		c.GPUMemory = "unified"
		c.STTTimeout = 600 * time.Second
		c.STTMaxUploadMB = 10
	}, nil, nil)
	_, gen := d.glossaryPairsGen()
	write := func(id, set string, res *stt.Result) {
		dir := filepath.Join(root, id+"@"+set)
		if err := os.MkdirAll(dir, 0o755); err != nil {
			t.Fatal(err)
		}
		b, err := json.Marshal(res)
		if err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(dir, "ox.json"), b, 0o644); err != nil {
			t.Fatal(err)
		}
		tm, _ := json.Marshal(map[string]any{"daemon_elapsed_s": res.ElapsedS, "audio_s": res.DurationS, "engine": res.Engine})
		_ = os.WriteFile(filepath.Join(dir, "timing.json"), tm, 0o644)
	}
	for id, bySet := range sets {
		seg := filepath.Join(root, id, "seg.wav")
		d.Cfg.STTBoostAlpha = 0
		res, err := d.Transcribe(context.Background(), TranscribeInput{AudioPath: seg, Language: "en"})
		if err != nil {
			t.Fatalf("%s base: %v", id, err)
		}
		write(id, "base", res)
		for set, names := range bySet {
			lines := make([]string, len(names))
			for i, n := range names {
				lines[i] = n + "\t1"
			}
			d.tbMu.Lock()
			d.tbSeenGen, d.tbCurKey, d.tbKeyOK = gen, "civic", true
			d.tbHave, d.tbKey, d.tbTerms = true, "civic", lines
			d.tbMu.Unlock()
			d.Cfg.STTBoostAlpha = alpha
			res, err := d.Transcribe(context.Background(), TranscribeInput{AudioPath: seg, Language: "en"})
			if err != nil {
				t.Fatalf("%s %s: %v", id, set, err)
			}
			write(id, set, res)
			t.Logf("%s %s: %d terms, decoded %.1fs of audio in %.1fs", id, set, len(names), res.DurationS, res.ElapsedS)
		}
	}
}
