//go:build whosaid

package meeting

// The word-level "who said what" gate (Nemotron Task 6). engine/diar/test_words.py prep builds, per
// AMI meeting, the recognizer's own words (the daemon's piece cutting + /transcribe), the manual
// reference words, and the diarization variants. This test runs every variant through the daemon's
// own ParseDiarization -> Decide -> AssignVoices (voices.go:73-80), aligns hyp to reference by
// Levenshtein, learns the voice->speaker mapping from the matched pairs, and scores attribution.
//
// Metrics (per meeting and variant):
//   - accuracy: matched pairs whose mapped voice equals the reference speaker, over matched pairs,
//     counted only on reference words no other speaker's word overlaps by more than half their
//     duration (AssignVoices is exclusive-timeline by construction; the overlapped rest is reported,
//     not gated)
//   - overlap_acc: the same ratio on the overlapped words
//   - attributed: correct pairs over ALL reference words
//   - asr_match: text-equal pairs over all reference words (what the recognizer got right)
//   - align_cover: matched pairs over all reference words
//
// Gates (the plan's B1/B2): on the 5 held-out meetings, mean g15 accuracy >= mean old AND no
// held-out meeting below old by more than 0.5 points; mean g15 >= mean g00 - 0.3 points. ES2004a is
// the dev meeting: the merge-gap sweep is decided on it (>= 1.0 point over g15 there AND >= 0.3 on
// the held-out mean) and reported here, not applied.
//
// Run: OX_WHOSAID_DIR=~/tmp/ox-say-p1/nemotron-diar/whosaid GOWORK=off go test -tags whosaid \
// ./internal/meeting -run 'TestWhoSaidWhat$' -v

import (
	"encoding/json"
	"fmt"
	"math"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"

	"github.com/anatolykoptev/ox-say/internal/stt"
)

const (
	wsDevMeeting = "mix_ES2004a"
	wsOverlap    = 0.5 // a reference word another speaker's word covers by more than this share of its
	// duration is "overlapped": excluded from the gated accuracy, scored apart
)

var wsVariants = []string{"old", "nemotron", "g00", "g05", "g10", "g15", "g20", "oracle"}

type wsRefWord struct {
	W   string  `json:"w"`
	S   float64 `json:"s"`
	E   float64 `json:"e"`
	Spk string  `json:"spk"`
}

type wsPair struct{ hyp, ref int }

type wsMetrics struct {
	RefWords      int               `json:"ref_words"`
	HypWords      int               `json:"hyp_words"`
	Matched       int               `json:"matched"`
	Ins           int               `json:"ins"`
	Del           int               `json:"del"`
	MatchNonOv    int               `json:"matched_nonoverlap"`
	MatchOv       int               `json:"matched_overlap"`
	OverlappedRef int               `json:"overlapped_ref"`
	ASRMatch      float64           `json:"asr_match"`
	AlignCover    float64           `json:"align_cover"`
	Accuracy      float64           `json:"accuracy"`
	OverlapAcc    float64           `json:"overlap_acc"`
	Attributed    float64           `json:"attributed"`
	Mapping       map[string]string `json:"mapping"`
	Best          []string          `json:"best"`
	Worst         []string          `json:"worst"`
}

// wsNorm normalizes a token for alignment: lowercase, every non-letter/digit dropped (AMI words are
// already lowercase; Parakeet may glue punctuation to a word).
func wsNorm(s string) string {
	return strings.Map(func(r rune) rune {
		if r >= 'a' && r <= 'z' || r >= '0' && r <= '9' || r >= 'A' && r <= 'Z' {
			return r
		}
		return -1
	}, strings.ToLower(s))
}

// wsAlign is word-level Levenshtein over normalized tokens: matched pairs (identical or substituted)
// plus counts of hyp insertions and reference deletions. Ties resolve match > delete > insert,
// deterministically.
func wsAlign(hyp, ref []string) (pairs []wsPair, ins, del int) {
	n, m := len(hyp), len(ref)
	cost := func(i, j int) int32 {
		if hyp[i-1] == ref[j-1] {
			return 0
		}
		return 1
	}
	dp := make([]int32, (n+1)*(m+1)) // flat: 10k x 10k int32 ~ 400 MB
	at := func(i, j int) *int32 { return &dp[i*(m+1)+j] }
	for i := 1; i <= n; i++ {
		*at(i, 0) = int32(i)
	}
	for j := 1; j <= m; j++ {
		*at(0, j) = int32(j)
	}
	for i := 1; i <= n; i++ {
		for j := 1; j <= m; j++ {
			*at(i, j) = min(*at(i-1, j-1)+cost(i, j), min(*at(i-1, j)+1, *at(i, j-1)+1))
		}
	}
	for i, j := n, m; i > 0 || j > 0; {
		switch {
		case i > 0 && j > 0 && *at(i, j) == *at(i-1, j-1)+cost(i, j):
			pairs = append(pairs, wsPair{i - 1, j - 1})
			i--
			j--
		case i > 0 && *at(i, j) == *at(i-1, j)+1:
			ins++
			i--
		default:
			del++
			j--
		}
	}
	for i, j := 0, len(pairs)-1; i < j; i, j = i+1, j-1 {
		pairs[i], pairs[j] = pairs[j], pairs[i]
	}
	return pairs, ins, del
}

// wsOverlapped flags each reference word another speaker's word covers by more than wsOverlap of its
// duration.
func wsOverlapped(ref []wsRefWord) []bool {
	out := make([]bool, len(ref))
	prefixMax := make([]float64, len(ref)+1)
	for i, w := range ref {
		prefixMax[i+1] = math.Max(prefixMax[i], w.E)
	}
	ov := func(a, b wsRefWord) float64 {
		d := a.E - a.S
		if d <= 0 {
			return 0
		}
		return math.Max(0, math.Min(a.E, b.E)-math.Max(a.S, b.S)) / d
	}
	for i, w := range ref {
		for j := i + 1; j < len(ref) && ref[j].S < w.E; j++ {
			if ref[j].Spk != w.Spk && ov(w, ref[j]) > wsOverlap {
				out[i] = true
			}
		}
		for j := i - 1; j >= 0 && prefixMax[j+1] > w.S; j-- {
			if ref[j].Spk != w.Spk && ov(w, ref[j]) > wsOverlap {
				out[i] = true
			}
		}
	}
	return out
}

// wsMapSpeakers is the best one-to-one voice->speaker mapping over the matched pairs' overlap
// matrix, brute force on the smaller side (AMI has four participants; voice counts stay small).
// The identity map is NOT assumed: nemotron numbers voices by first appearance.
func wsMapSpeakers(matrix map[string]map[string]int, voices, spks []string) map[string]string {
	// Assign each member of the smaller side a distinct member of the larger; when speakers are
	// fewer than voices the assignment runs spk->voice and inverts, leaving extra voices unmapped.
	flip := len(voices) > len(spks)
	small, big := voices, spks
	if flip {
		small, big = spks, voices
	}
	bestScore := -1
	var best map[string]string
	used := make([]bool, len(big))
	cur := make([]string, len(small))
	var walk func(i, score int)
	walk = func(i, score int) {
		if i == len(small) {
			if score > bestScore {
				bestScore = score
				best = map[string]string{}
				for k, v := range cur {
					if flip {
						best[v] = small[k]
					} else {
						best[small[k]] = v
					}
				}
			}
			return
		}
		for j := range big {
			if used[j] {
				continue
			}
			used[j] = true
			cur[i] = big[j]
			v, s := small[i], big[j]
			if flip {
				v, s = s, v
			}
			walk(i+1, score+matrix[v][s])
			used[j] = false
		}
	}
	walk(0, 0)
	return best
}

// wsScore computes the metrics of one (meeting, variant): voices is AssignVoices' answer per hyp
// word ("" when the plan has no voices — it maps as a voice of its own).
func wsScore(hyp []stt.Word, voices []string, ref []wsRefWord) wsMetrics {
	ov := wsOverlapped(ref)
	hypTok := make([]string, len(hyp))
	for i, w := range hyp {
		hypTok[i] = wsNorm(w.W)
	}
	refTok := make([]string, len(ref))
	for i, w := range ref {
		refTok[i] = wsNorm(w.W)
	}
	pairs, ins, del := wsAlign(hypTok, refTok)

	matrix := map[string]map[string]int{}
	voiceSet, spkSet := map[string]bool{}, map[string]bool{}
	matched, matchNonOv, matchOv, textEq := 0, 0, 0, 0
	for _, p := range pairs {
		v := voices[p.hyp]
		s := ref[p.ref].Spk
		if matrix[v] == nil {
			matrix[v] = map[string]int{}
		}
		matrix[v][s]++
		voiceSet[v] = true
		spkSet[s] = true
		matched++
		if ov[p.ref] {
			matchOv++
		} else {
			matchNonOv++
		}
		if hypTok[p.hyp] == refTok[p.ref] {
			textEq++
		}
	}
	voices_ := sortedKeys(voiceSet)
	spks := sortedKeys(spkSet)
	mapping := wsMapSpeakers(matrix, voices_, spks)

	correct, correctNonOv, correctOv := 0, 0, 0
	type cand struct {
		w   string
		p   float64
		idx int
	}
	var bestC, worstC []cand
	for _, p := range pairs {
		got := mapping[voices[p.hyp]]
		ok := got != "" && got == ref[p.ref].Spk
		if ok {
			correct++
			if ov[p.ref] {
				correctOv++
			} else {
				correctNonOv++
			}
			bestC = append(bestC, cand{hyp[p.hyp].W, hyp[p.hyp].P, p.hyp})
		} else {
			worstC = append(worstC, cand{hyp[p.hyp].W, hyp[p.hyp].P, p.hyp})
		}
	}
	byConf := func(cs []cand) []cand {
		sort.SliceStable(cs, func(i, j int) bool {
			if cs[i].p != cs[j].p {
				return cs[i].p > cs[j].p
			}
			return cs[i].idx < cs[j].idx
		})
		return cs
	}
	top := func(cs []cand, n int) []string {
		out := []string{}
		for i, c := range byConf(cs) {
			if i >= n {
				break
			}
			out = append(out, c.w)
		}
		return out
	}
	overlapped := 0
	for _, o := range ov {
		if o {
			overlapped++
		}
	}
	return wsMetrics{
		RefWords: len(ref), HypWords: len(hyp), Matched: matched, Ins: ins, Del: del,
		MatchNonOv: matchNonOv, MatchOv: matchOv, OverlappedRef: overlapped,
		ASRMatch:   ratio(textEq, len(ref)),
		AlignCover: ratio(matched, len(ref)),
		Accuracy:   ratio(correctNonOv, matchNonOv),
		OverlapAcc: ratio(correctOv, matchOv),
		Attributed: ratio(correct, len(ref)),
		Mapping:    mapping,
		Best:       top(bestC, 3), Worst: top(worstC, 3),
	}
}

func sortedKeys(s map[string]bool) []string {
	out := make([]string, 0, len(s))
	for k := range s {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}

func ratio(a, b int) float64 {
	if b == 0 {
		return 0
	}
	return float64(a) / float64(b)
}

func readJSON(t *testing.T, path string, v any) {
	t.Helper()
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read %s: %v", path, err)
	}
	if err := json.Unmarshal(raw, v); err != nil {
		t.Fatalf("parse %s: %v", path, err)
	}
}

// scoreVariant runs one diarization file through the daemon's own three calls.
func scoreVariant(t *testing.T, diarRaw []byte, hyp []stt.Word, ref []wsRefWord) wsMetrics {
	t.Helper()
	d, err := ParseDiarization(diarRaw)
	if err != nil {
		t.Fatalf("ParseDiarization: %v", err)
	}
	plan := Decide(d)
	voices := AssignVoices(hyp, d, plan)
	return wsScore(hyp, voices, ref)
}

func TestWhoSaidWhat(t *testing.T) {
	dir := os.Getenv("OX_WHOSAID_DIR")
	if dir == "" {
		t.Skip("OX_WHOSAID_DIR unset (run engine/diar/test_words.py prep first)")
	}
	entries, err := os.ReadDir(dir)
	if err != nil {
		t.Fatalf("read %s: %v", dir, err)
	}
	var meetings []string
	for _, e := range entries {
		if e.IsDir() && strings.HasPrefix(e.Name(), "mix_") {
			if _, err := os.Stat(filepath.Join(dir, e.Name(), "hyp.json")); err == nil {
				meetings = append(meetings, e.Name())
			}
		}
	}
	sort.Strings(meetings)
	if len(meetings) == 0 {
		t.Fatalf("no prepared meetings under %s", dir)
	}

	results := map[string]map[string]wsMetrics{}
	for _, mid := range meetings {
		var hyp struct {
			Words []stt.Word `json:"words"`
		}
		readJSON(t, filepath.Join(dir, mid, "hyp.json"), &hyp)
		var refS struct {
			Words []wsRefWord `json:"words"`
		}
		readJSON(t, filepath.Join(dir, mid, "ref.json"), &refS)
		results[mid] = map[string]wsMetrics{}
		for _, v := range wsVariants {
			raw, err := os.ReadFile(filepath.Join(dir, mid, "diar", v+".json"))
			if err != nil {
				t.Fatalf("%s/%s: %v", mid, v, err)
			}
			results[mid][v] = scoreVariant(t, raw, hyp.Words, refS.Words)
		}
	}

	out := filepath.Join(dir, "results")
	if err := os.MkdirAll(out, 0o755); err != nil {
		t.Fatal(err)
	}
	heldOut := []string{}
	for _, m := range meetings {
		if m != wsDevMeeting {
			heldOut = append(heldOut, m)
		}
	}
	mean := func(variant string, ms []string) float64 {
		s := 0.0
		for _, m := range ms {
			s += results[m][variant].Accuracy
		}
		return s / float64(len(ms))
	}
	for _, mid := range meetings {
		row := map[string]any{"meeting": mid, "held_out": mid != wsDevMeeting}
		for _, v := range wsVariants {
			row[v] = results[mid][v]
		}
		raw, _ := json.MarshalIndent(row, "", "  ")
		if err := os.WriteFile(filepath.Join(out, mid+".json"), raw, 0o644); err != nil {
			t.Fatal(err)
		}
	}
	summary := map[string]any{
		"meetings": meetings, "dev": wsDevMeeting, "held_out": heldOut, "variants": wsVariants,
		"mean_held_out": map[string]float64{},
		"mean_dev":      map[string]float64{},
	}
	for _, v := range wsVariants {
		summary["mean_held_out"].(map[string]float64)[v] = mean(v, heldOut)
		summary["mean_dev"].(map[string]float64)[v] = mean(v, []string{wsDevMeeting})
	}
	raw, _ := json.MarshalIndent(summary, "", "  ")
	if err := os.WriteFile(filepath.Join(out, "summary.json"), raw, 0o644); err != nil {
		t.Fatal(err)
	}

	// the full table
	t.Logf("%-12s %8s %8s %8s %8s %8s %8s", "meeting", "variant", "acc", "asr", "ov-acc", "attr", "match")
	for _, mid := range meetings {
		for _, v := range wsVariants {
			m := results[mid][v]
			t.Logf("%-12s %8s %8.3f %8.3f %8.3f %8.3f %5d/%-5d best=%v worst=%v map=%v",
				mid, v, m.Accuracy, m.ASRMatch, m.OverlapAcc, m.Attributed, m.Matched, m.RefWords,
				m.Best, m.Worst, m.Mapping)
		}
	}

	// B1: g15 at least as good as old, per-meeting and on the held-out mean.
	if got, want := mean("g15", heldOut), mean("old", heldOut); got+1e-9 < want {
		t.Errorf("B1: held-out mean g15 %.4f < old %.4f", got, want)
	}
	for _, m := range heldOut {
		if results[m]["g15"].Accuracy+0.005 < results[m]["old"].Accuracy {
			t.Errorf("B1: %s g15 %.4f is %.3f points under old %.4f (>0.5)",
				m, results[m]["g15"].Accuracy, (results[m]["old"].Accuracy-results[m]["g15"].Accuracy)*100, results[m]["old"].Accuracy)
		}
	}
	// B2: the 1.5 s merge must not cost word attribution.
	if got, want := mean("g15", heldOut), mean("g00", heldOut); got+1e-9 < want-0.003 {
		t.Errorf("B2: held-out mean g15 %.4f < g00 %.4f - 0.3 points", got, want)
	}
	// The merge-gap verdict is reported, not applied: the sweep picks on the dev meeting only.
	bestGap, bestAcc := "g15", results[wsDevMeeting]["g15"].Accuracy
	for _, v := range []string{"g00", "g05", "g10", "g20"} {
		if results[wsDevMeeting][v].Accuracy > bestAcc {
			bestGap, bestAcc = v, results[wsDevMeeting][v].Accuracy
		}
	}
	devDelta := results[wsDevMeeting][bestGap].Accuracy - results[wsDevMeeting]["g15"].Accuracy
	heldDelta := mean(bestGap, heldOut) - mean("g15", heldOut)
	verdict := "keep 1.5 s"
	if devDelta >= 0.01 && heldDelta >= 0.003 {
		verdict = fmt.Sprintf("change to %s", bestGap)
	}
	t.Logf("merge-gap verdict: %s (dev %s %+.2f points over g15; held-out mean %+.2f points)",
		verdict, bestGap, devDelta*100, heldDelta*100)
}

// --- scorer unit tests: the hand-computed cases the gate's RED evidence stands on ---

func refW(w string, s, e float64, spk string) wsRefWord { return wsRefWord{W: w, S: s, E: e, Spk: spk} }

func TestWhoSaidWhatScorerSynthetic(t *testing.T) {
	// 10 aligned words, two speakers alternating; the hyp words carry the voice of the WRONG
	// number on purpose (learned map is a swap, identity fails) and words 7/8 are flipped:
	// 8 of 10 matched pairs map to the right speaker.
	ref := []wsRefWord{
		refW("a", 0, 1, "A"), refW("b", 1, 2, "B"), refW("c", 2, 3, "A"), refW("d", 3, 4, "B"),
		refW("e", 4, 5, "A"), refW("f", 5, 6, "B"), refW("g", 6, 7, "A"), refW("h", 7, 8, "B"),
		refW("i", 8, 9, "A"), refW("j", 9, 10, "B"),
	}
	hyp := []stt.Word{
		{W: "a", S: 0, E: 1, P: 0.9}, {W: "b", S: 1, E: 2, P: 0.9}, {W: "c", S: 2, E: 3, P: 0.9},
		{W: "d", S: 3, E: 4, P: 0.9}, {W: "e", S: 4, E: 5, P: 0.9}, {W: "f", S: 5, E: 6, P: 0.9},
		{W: "g", S: 6, E: 7, P: 0.9}, {W: "h", S: 7, E: 8, P: 0.9}, {W: "i", S: 8, E: 9, P: 0.9},
		{W: "j", S: 9, E: 10, P: 0.9},
	}
	// them:2 speaks like A, them:1 like B; words 6..9 (0-based) deliberately swapped.
	voices := []string{"them:2", "them:1", "them:2", "them:1", "them:2", "them:1",
		"them:1", "them:2", "them:2", "them:1"}
	m := wsScore(hyp, voices, ref)
	if m.Matched != 10 || m.Accuracy != 0.8 || m.Attributed != 0.8 || m.ASRMatch != 1.0 {
		t.Fatalf("synthetic scorer: got %+v, want accuracy 0.8 over 10 matched pairs", m)
	}
	if m.Mapping["them:2"] != "A" || m.Mapping["them:1"] != "B" {
		t.Fatalf("learned mapping %v, want them:2->A them:1->B", m.Mapping)
	}
	// RED evidence (the gate's mapping mutation): an identity map scores this fixture 0/10, not
	// 8/10 — the learned swap is what the 0.8 stands on.
}

func TestWhoSaidWhatScorerOracle(t *testing.T) {
	// The oracle path end to end at fixture size: a ParseDiarization-shaped diarization where
	// every reference word sits in its speaker's segment must score 1.0. Two 60 s speakers keep
	// both clusters substantial (>=45 s and >=8 %), so Decide's Mode is VoicesOffer and
	// AssignVoices runs.
	diar := []byte(`{"version":1,"duration_s":120,"speakers":[
		{"id":0,"speech_s":60,"embedding":[1,0,0,0,0,0,0,0]},
		{"id":1,"speech_s":60,"embedding":[0,1,0,0,0,0,0,0]}],
		"segments":[{"s":0,"e":60,"spk":0},{"s":60,"e":120,"spk":1}]}`)
	ref := []wsRefWord{
		refW("hello", 1, 1.4, "A"), refW("world", 2, 2.5, "A"),
		refW("how", 61, 61.3, "B"), refW("are", 62, 62.2, "B"), refW("you", 63, 63.4, "B"),
	}
	hyp := []stt.Word{
		{W: "hello", S: 1, E: 1.4, P: 0.9}, {W: "world", S: 2, E: 2.5, P: 0.9},
		{W: "how", S: 61, E: 61.3, P: 0.9}, {W: "are", S: 62, E: 62.2, P: 0.9}, {W: "you", S: 63, E: 63.4, P: 0.9},
	}
	m := scoreVariant(t, diar, hyp, ref)
	if m.Accuracy != 1.0 || m.Attributed != 1.0 || m.Matched != 5 {
		t.Fatalf("oracle fixture: got %+v, want accuracy 1.0 over 5 matched pairs", m)
	}
}
