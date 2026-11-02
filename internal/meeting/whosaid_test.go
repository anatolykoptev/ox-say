//go:build whosaid

package meeting

// The word-level "who said what" gate. engine/diar/test_words.py prep builds, per AMI meeting, the
// recognizer's own words (the daemon's piece cutting + /transcribe), the manual reference words, and the
// diarization variants. This test runs every variant through the daemon's own ParseDiarization ->
// Decide -> AssignVoices (voices.go), aligns hyp to reference by Levenshtein, learns the
// voice->speaker mapping from the matched pairs, and scores attribution.
//
// Metrics (per meeting and variant):
//   - accuracy: matched pairs whose mapped voice equals the reference speaker, over matched pairs,
//     counted only on reference words no other speaker's word overlaps by more than half their
//     duration (AssignVoices is exclusive-timeline by construction; the overlapped rest is reported,
//     not gated)
//   - exact_accuracy: the same ratio over the matched pairs whose normalised tokens are EQUAL. A
//     matched pair may be a substitution of unrelated words (6-8 % of pairs), which says nothing
//     about who spoke; this is the figure without that noise. Reported, not gated.
//   - overlap_acc: the accuracy ratio on the overlapped words
//   - attributed: correct pairs over ALL reference words
//   - asr_match: text-equal pairs over all reference words (what the recognizer got right)
//   - align_cover: matched pairs over all reference words
//
// The gate fails (it never skips) on broken inputs: an unset OX_WHOSAID_DIR, a data dir that is not
// exactly the six expected meetings, a g15 file that is not the product's nemotron output, an `old`
// that is not a different diarization from nemotron, or any variant under the accuracy floor.
// Bars on the 5 held-out meetings:
//   - nemotron-over-old: nemotron accuracy strictly above old on every held-out meeting, and
//     mean g15 >= mean old with no meeting more than 0.5 points under it
//   - merge-cost: mean g15 >= mean g00 - 0.3 points
//
// ES2004a is the dev meeting: the merge-gap sweep is decided on it (>= 1.0 point over g15 there AND
// >= 0.3 on the held-out mean) and reported here, not applied. The held-out means without ES2004d
// are reported too: that one meeting carries most of the old-vs-nemotron gap and depends on where
// Decide's 8 % bar falls.
//
// Run (the build tag is the instruction to run it):
//
//	OX_WHOSAID_DIR=/path/to/whosaid GOWORK=off go test -count=1 -tags whosaid ./internal/meeting -run 'TestWhoSaidWhat$' -v

import (
	"encoding/json"
	"fmt"
	"math"
	"os"
	"path/filepath"
	"reflect"
	"sort"
	"strings"
	"testing"

	"github.com/anatolykoptev/ox-say/internal/stt"
)

const (
	wsDevMeeting = "mix_ES2004a"
	wsHeavyGap   = "mix_ES2004d" // carries most of the old-vs-nemotron gap: reported with and without it
	wsFloor      = 0.5           // every variant must attribute more than this on every meeting
	wsOverlap    = 0.5           // a reference word another speaker's word covers by more than this share of its
	// duration is "overlapped": excluded from the gated accuracy, scored apart
)

// wsExpected pins each meeting's size: a truncated hyp.json or ref.json must not pass.
// Matched must stay within 90 % of the expected aligned pairs.
var wsExpected = map[string]struct{ refWords, matched int }{
	"mix_EN2002a": {7516, 5380}, "mix_ES2004a": {2614, 2285}, "mix_ES2004b": {6763, 6055},
	"mix_ES2004c": {6968, 6155}, "mix_ES2004d": {6134, 5218}, "mix_IS1009b": {6091, 5404},
}

// wsMeetings is the exact prepared set; a data dir with fewer (or more) is a broken input, not a smaller gate.
var wsMeetings = []string{"mix_EN2002a", "mix_ES2004a", "mix_ES2004b", "mix_ES2004c", "mix_ES2004d", "mix_IS1009b"}

// "oracle" is the on-disk name of the exclusive manual timeline (the manual RTTM made exclusive); it is
// not a ceiling: crosstalk keeps the dominant speaker only and Decide may fold a small speaker.
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
	ExactAcc      float64           `json:"exact_accuracy"`
	MatchExactNon int               `json:"matched_exact_nonoverlap"`
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
// plus counts of hyp insertions and reference deletions. Ties resolve match > insert > delete,
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
	matched, matchNonOv, matchOv, textEq, matchExactNon := 0, 0, 0, 0, 0
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
			if !ov[p.ref] {
				matchExactNon++
			}
		}
	}
	voices_ := sortedKeys(voiceSet)
	spks := sortedKeys(spkSet)
	mapping := wsMapSpeakers(matrix, voices_, spks)

	correct, correctNonOv, correctOv, correctExactNon := 0, 0, 0, 0
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
				if hypTok[p.hyp] == refTok[p.ref] {
					correctExactNon++
				}
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
		ExactAcc:   ratio(correctExactNon, matchExactNon), MatchExactNon: matchExactNon,
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
		// The build tag already says "run the gate": a skip here would pass on an unset variable.
		t.Fatal("OX_WHOSAID_DIR unset: point it at the prepared data (engine/diar/test_words.py prep)")
	}
	// A failed run must leave no results behind, stale ones included.
	if err := os.RemoveAll(filepath.Join(dir, "results")); err != nil {
		t.Fatal(err)
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
	if !reflect.DeepEqual(meetings, wsMeetings) {
		t.Fatalf("prepared meetings under %s are %v, want exactly %v", dir, meetings, wsMeetings)
	}
	heldOut := []string{}
	for _, m := range meetings {
		if m != wsDevMeeting {
			heldOut = append(heldOut, m)
		}
	}
	if len(heldOut) != 5 {
		t.Fatalf("%d held-out meetings, want 5", len(heldOut))
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
		raws := map[string][]byte{}
		parsed := map[string]*Diarization{}
		results[mid] = map[string]wsMetrics{}
		for _, v := range wsVariants {
			raw, err := os.ReadFile(filepath.Join(dir, mid, "diar", v+".json"))
			if err != nil {
				t.Fatalf("%s/%s: %v", mid, v, err)
			}
			raws[v] = raw
			if parsed[v], err = ParseDiarization(raw); err != nil {
				t.Fatalf("%s/%s: ParseDiarization: %v", mid, v, err)
			}
			results[mid][v] = scoreVariant(t, raw, hyp.Words, refS.Words)
		}
		// g15 is the product's merge rule: the sweep measures the product only while g15 IS the real
		// ox-diar --engine nemotron output (prep checks it too, but a stale file is reused there).
		if why := wsDiarDiff(parsed["g15"], parsed["nemotron"]); why != "" {
			t.Errorf("%s: g15 is not the nemotron output (%s)", mid, why)
		}
		// `old` and `nemotron` must be two different diarizations, else "nemotron beats old" compares a file with itself.
		if reflect.DeepEqual(parsed["old"].Segments, parsed["nemotron"].Segments) {
			t.Errorf("%s: old and nemotron have identical segments: the comparison is vacuous", mid)
		}
	}
	for _, mid := range meetings {
		want := wsExpected[mid]
		for _, v := range wsVariants {
			m := results[mid][v]
			if m.RefWords != want.refWords {
				t.Errorf("%s/%s: %d reference words, want %d", mid, v, m.RefWords, want.refWords)
			}
			if m.Matched*10 < want.matched*9 {
				t.Errorf("%s/%s: %d matched pairs, under 90%% of the expected %d", mid, v, m.Matched, want.matched)
			}
		}
	}
	// Every variant must attribute a clear majority of words on every meeting: a mapping or voice
	// assignment that is broken scores near zero or at the biggest speaker's share, never above this.
	for _, mid := range meetings {
		for _, v := range wsVariants {
			if acc := results[mid][v].Accuracy; !(acc > wsFloor) {
				t.Errorf("%s/%s: accuracy %.4f is not above the %.1f floor", mid, v, acc, wsFloor)
			}
		}
	}

	mean := func(variant string, ms []string, pick func(wsMetrics) float64) float64 {
		s := 0.0
		for _, m := range ms {
			s += pick(results[m][variant])
		}
		got := s / float64(len(ms))
		if math.IsNaN(got) || math.IsInf(got, 0) {
			t.Fatalf("mean %s over %v is %v", variant, ms, got)
		}
		return got
	}
	acc := func(m wsMetrics) float64 { return m.Accuracy }
	exact := func(m wsMetrics) float64 { return m.ExactAcc }
	withoutHeavy := []string{}
	for _, m := range heldOut {
		if m != wsHeavyGap {
			withoutHeavy = append(withoutHeavy, m)
		}
	}

	// the full table
	t.Logf("%-12s %8s %8s %8s %8s %8s %8s %8s", "meeting", "variant", "acc", "exact", "asr", "ov-acc", "attr", "match")
	for _, mid := range meetings {
		for _, v := range wsVariants {
			m := results[mid][v]
			t.Logf("%-12s %8s %8.3f %8.3f %8.3f %8.3f %8.3f %5d/%-5d best=%v worst=%v map=%v",
				mid, v, m.Accuracy, m.ExactAcc, m.ASRMatch, m.OverlapAcc, m.Attributed, m.Matched, m.RefWords,
				m.Best, m.Worst, m.Mapping)
		}
	}
	for _, v := range []string{"old", "nemotron"} {
		t.Logf("held-out mean %-8s acc %.4f exact %.4f | without %s: acc %.4f exact %.4f", v,
			mean(v, heldOut, acc), mean(v, heldOut, exact), wsHeavyGap,
			mean(v, withoutHeavy, acc), mean(v, withoutHeavy, exact))
	}

	// nemotron-over-old: strictly better on every held-out meeting (not >=: a copy of old would pass).
	for _, m := range heldOut {
		if !(results[m]["nemotron"].Accuracy > results[m]["old"].Accuracy) {
			t.Errorf("nemotron-over-old: %s nemotron %.4f is not above old %.4f",
				m, results[m]["nemotron"].Accuracy, results[m]["old"].Accuracy)
		}
	}
	// g15 at least as good as old, per-meeting and on the held-out mean. Written so NaN fails.
	if got, want := mean("g15", heldOut, acc), mean("old", heldOut, acc); !(got+1e-9 >= want) {
		t.Errorf("nemotron-over-old: held-out mean g15 %.4f < old %.4f", got, want)
	}
	for _, m := range heldOut {
		if !(results[m]["g15"].Accuracy+0.005 >= results[m]["old"].Accuracy) {
			t.Errorf("nemotron-over-old: %s g15 %.4f is %.3f points under old %.4f (>0.5)",
				m, results[m]["g15"].Accuracy, (results[m]["old"].Accuracy-results[m]["g15"].Accuracy)*100, results[m]["old"].Accuracy)
		}
	}
	// merge-cost: the 1.5 s merge must not cost word attribution.
	if got, want := mean("g15", heldOut, acc), mean("g00", heldOut, acc); !(got+1e-9 >= want-0.003) {
		t.Errorf("merge-cost: held-out mean g15 %.4f < g00 %.4f - 0.3 points", got, want)
	}
	// The merge-gap verdict is reported, not applied: the sweep picks on the dev meeting only.
	bestGap, bestAcc := "g15", results[wsDevMeeting]["g15"].Accuracy
	for _, v := range []string{"g00", "g05", "g10", "g20"} {
		if results[wsDevMeeting][v].Accuracy > bestAcc {
			bestGap, bestAcc = v, results[wsDevMeeting][v].Accuracy
		}
	}
	devDelta := results[wsDevMeeting][bestGap].Accuracy - results[wsDevMeeting]["g15"].Accuracy
	heldDelta := mean(bestGap, heldOut, acc) - mean("g15", heldOut, acc)
	verdict := "keep 1.5 s"
	if devDelta >= 0.01 && heldDelta >= 0.003 {
		verdict = fmt.Sprintf("change to %s", bestGap)
	}
	t.Logf("merge-gap verdict: %s (dev %s %+.2f points over g15; held-out mean %+.2f points)",
		verdict, bestGap, devDelta*100, heldDelta*100)

	// Results are written last, and only when every check above passed.
	if !t.Failed() {
		out := filepath.Join(dir, "results")
		if err := os.MkdirAll(out, 0o755); err != nil {
			t.Fatal(err)
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
		means := func(ms []string, pick func(wsMetrics) float64) map[string]float64 {
			o := map[string]float64{}
			for _, v := range wsVariants {
				o[v] = mean(v, ms, pick)
			}
			return o
		}
		summary := map[string]any{
			"meetings": meetings, "dev": wsDevMeeting, "held_out": heldOut, "variants": wsVariants,
			"without_meeting":                   wsHeavyGap,
			"mean_held_out":                     means(heldOut, acc),
			"mean_dev":                          means([]string{wsDevMeeting}, acc),
			"mean_held_out_without_heavy":       means(withoutHeavy, acc),
			"mean_held_out_exact":               means(heldOut, exact),
			"mean_held_out_exact_without_heavy": means(withoutHeavy, exact),
		}
		raw, _ := json.MarshalIndent(summary, "", "  ")
		if err := os.WriteFile(filepath.Join(out, "summary.json"), raw, 0o644); err != nil {
			t.Fatal(err)
		}
	}
}

// wsDiarDiff names the first way a differs from b in segments, speaker ids or per-speaker speech
// seconds ("" when equal): the three things prep compares for g15 against the real nemotron output.
func wsDiarDiff(a, b *Diarization) string {
	if !reflect.DeepEqual(a.Segments, b.Segments) {
		for i := 0; i < len(a.Segments) && i < len(b.Segments); i++ {
			if a.Segments[i] != b.Segments[i] {
				return fmt.Sprintf("segment %d: %+v vs %+v", i, a.Segments[i], b.Segments[i])
			}
		}
		return fmt.Sprintf("segments differ: %d vs %d", len(a.Segments), len(b.Segments))
	}
	if len(a.Speakers) != len(b.Speakers) {
		return fmt.Sprintf("%d vs %d speakers", len(a.Speakers), len(b.Speakers))
	}
	for i := range a.Speakers {
		if a.Speakers[i].ID != b.Speakers[i].ID {
			return fmt.Sprintf("speaker %d id %d vs %d", i, a.Speakers[i].ID, b.Speakers[i].ID)
		}
		if a.Speakers[i].SpeechS != b.Speakers[i].SpeechS {
			return fmt.Sprintf("speaker %d speech_s %v vs %v", i, a.Speakers[i].SpeechS, b.Speakers[i].SpeechS)
		}
	}
	return ""
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

func TestWhoSaidWhatScorerManualTimeline(t *testing.T) {
	// The exclusive manual timeline end to end at fixture size: a ParseDiarization-shaped diarization where
	// every reference word sits in its speaker's segment must score 1.0. Two 60 s speakers keep
	// both clusters substantial (>=45 s and >=8 %), so Decide's Mode is VoicesOffer and
	// AssignVoices runs. No embeddings, as the shipped manual timeline carries none.
	diar := []byte(`{"version":1,"duration_s":120,"speakers":[
		{"id":0,"speech_s":60},
		{"id":1,"speech_s":60}],
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
		t.Fatalf("manual-timeline fixture: got %+v, want accuracy 1.0 over 5 matched pairs", m)
	}
}

func TestWhoSaidWhatScorerExactAccuracy(t *testing.T) {
	// Two matched pairs are substitutions of unrelated words (x for c, y for e): x carries the right
	// voice, y the wrong one. accuracy counts both (5/6); exact_accuracy neither (4/4).
	ref := []wsRefWord{
		refW("a", 0, 1, "A"), refW("b", 1, 2, "A"), refW("c", 2, 3, "B"),
		refW("d", 3, 4, "B"), refW("e", 4, 5, "A"), refW("f", 5, 6, "B"),
	}
	hyp := []stt.Word{
		{W: "a", S: 0, E: 1}, {W: "b", S: 1, E: 2}, {W: "x", S: 2, E: 3},
		{W: "d", S: 3, E: 4}, {W: "y", S: 4, E: 5}, {W: "f", S: 5, E: 6},
	}
	voices := []string{"them:1", "them:1", "them:2", "them:2", "them:2", "them:2"}
	m := wsScore(hyp, voices, ref)
	if m.Matched != 6 || m.MatchExactNon != 4 {
		t.Fatalf("exact fixture: matched %d (want 6), exact pairs %d (want 4)", m.Matched, m.MatchExactNon)
	}
	if got := m.Accuracy; got < 5.0/6-1e-9 || got > 5.0/6+1e-9 {
		t.Fatalf("exact fixture: accuracy %.4f, want 5/6", got)
	}
	if m.ExactAcc != 1.0 {
		t.Fatalf("exact fixture: exact_accuracy %.4f, want 1.0 (the two substitutions are not counted)", m.ExactAcc)
	}
}
