package meeting

import (
	"encoding/json"
	"fmt"
	"math"
	"strings"
	"testing"
	"unicode"
	"unicode/utf8"
)

// oracleTokens is the tests' own count of what a string costs the real
// tokenizer, from the worst per-rune rates the calibration measured
// (notes_calibration_data_test.go), rounded up: Han and kana 0.6 (zh 0.53,
// ja 0.57), Hangul 0.5 (ko 0.49), ASCII digits, punctuation and space 1.0
// (digits_only), ASCII letters 0.3, emoji and symbols 2.2 (emoji 2.09),
// anything else 1.4 (Ethiopic 1.37, the worst script measured). It shares no
// code with runeUnits, so an estimator that underweights a class still
// fails the checks below.
func oracleTokens(s string) float64 {
	n := 0.0
	for _, r := range s {
		switch {
		case r < 0x80 && unicode.IsLetter(r):
			n += 0.3
		case r < 0x80:
			n += 1.0
		case unicode.Is(unicode.Han, r) || unicode.Is(unicode.Hiragana, r) || unicode.Is(unicode.Katakana, r) ||
			(r >= 0x3000 && r <= 0x30FF) || (r >= 0xFF00 && r <= 0xFFEF):
			n += 0.6
		case unicode.Is(unicode.Hangul, r):
			n += 0.5
		case r > 0xFFFF || unicode.IsSymbol(r) || r == 0x200D || (r >= 0xFE00 && r <= 0xFE0F):
			n += 2.2
		default:
			n += 1.4
		}
	}
	return n
}

// A Chinese meeting of about 40,000 Han characters: every prompt the
// pipeline builds — each map chunk, the reduce call, the summary merge —
// plus that call's answer cap must fit the context the server is started
// with. The prompts are collected through the real builders (fakeChat sees
// every Request Compose sends).
//
// Mutations, each RED: notes.go runeUnits drops Han from the dense scripts
// (map and reduce prompts overflow); notes_points.go pairBatch loses both
// token bounds, the truncateTokens line cap and the reduceTokenBudget check
// (the reduce prompt overflows). Either bound alone is covered by the other.
func TestCJKMeetingPromptsFitTheContext(t *testing.T) {
	line := "[0:01] 我: 今天我们详细讨论了项目进度质量风险交付时间与人员安排分工情况,明天继续推进后续工作的整体计划与执行步骤。"
	text := strings.Repeat(line+"\n", 850) // ~43k Han runes
	n := len(Chunk(text, ChunkChars))
	if n < 2 {
		t.Fatalf("fixture makes %d chunks, want at least 2", n)
	}
	quote := "今天我们详细讨论了项目进度质量风险交付时间与人员安排分工情况,明天继续推进后续工作的整体计划与执行步骤"
	body := strings.Repeat("关于项目推进的详细计划安排与执行步骤的说明", 12)
	var open []Point
	for i := 0; i < 50; i++ {
		open = append(open, Point{Text: fmt.Sprintf("第%d项议题:%s", i, body), Status: statusOpen})
	}
	var decided []Point
	for i := 0; i < 40; i++ {
		decided = append(decided, Point{Text: fmt.Sprintf("第%d项决定:%s", i, body), Status: statusDecided, Quote: quote})
	}
	// Long partial summaries, so the merge prompt is large too.
	summary := strings.Repeat("本部分讨论了项目进度与风险安排并确定了后续行动。", 100)
	f := &fakeChat{}
	for i := 0; i < n; i++ {
		if i == 0 {
			f.replies = append(f.replies, answerJSON(t, chunkAnswer{Summary: summary, Points: open}))
		} else {
			f.replies = append(f.replies, answerJSON(t, chunkAnswer{Summary: summary, Points: decided}))
		}
	}
	f.replies = append(f.replies, `{"settles":[]}`, "合并的摘要。")
	ctx := NotesContextTokens()
	if _, err := (Composer{Chat: f}).Compose(t.Context(), text, Labels{Me: "我", Them: "对方"}, "zh"); err != nil {
		t.Fatal(err)
	}
	if len(f.reqs) != n+2 {
		t.Fatalf("%d calls, want %d chunks + 1 reduce + 1 merge", len(f.reqs), n)
	}
	for i, r := range f.reqs {
		prompt := r.System + r.User
		if got := oracleTokens(prompt) + float64(r.MaxTokens); got > float64(ctx) {
			t.Errorf("call %d: ~%.0f real tokens + %d-token answer = %.0f > context %d", i, oracleTokens(prompt), r.MaxTokens, got, ctx)
		}
		if got := EstimateTokens(prompt) + r.MaxTokens; got > ctx {
			t.Errorf("call %d: ~%d tokens + %d-token answer = %d > context %d", i, EstimateTokens(prompt), r.MaxTokens, got, ctx)
		}
	}
	if utf8.RuneCountInString(f.reqs[0].User) < 1000 {
		t.Errorf("the map prompt holds only %d runes: the fixture did not exercise the bound", utf8.RuneCountInString(f.reqs[0].User))
	}
}

// The estimator's weights by class, in tokens per rune: ASCII letters 0.3,
// digits and ASCII punctuation or space 1.0, Cyrillic and Latin Extended
// 0.4, Arabic-Hebrew-Thai-Indic-Hangul 0.6, Han and kana 0.7, Georgian and
// Armenian 1.0, other scripts 2.0, symbols, emoji and non-BMP 3.0.
func TestEstimateTokensWeighsTheScriptClasses(t *testing.T) {
	for _, tc := range []struct {
		s    string
		want int
	}{
		{"", 0},
		{"hello", 2},  // 5 letters: ceil(1.5)
		{"1234", 4},   // a token a digit
		{"a b", 2},    // 0.3+1.0+0.3 -> 2
		{"项目中", 3},    // 2.1 -> 3
		{"あいうえお", 4},  // 3.5 -> 4
		{"한국어", 2},    // 1.8 -> 2
		{"。、", 2},     // CJK punctuation is Han-class: 1.4 -> 2
		{"ＦＵＬＬ", 3},   // fullwidth forms: 2.8 -> 3
		{"ラーメン・", 4},  // the prolonged-sound mark and the middle dot are script-Common: 3.5 -> 4
		{"Привет", 3}, // 2.4 -> 3
		{"მერე", 4},   // Georgian 1.0 a rune
		{"👍", 3},      // outside the BMP
		{"€", 3},      // a symbol
		{"٣٤", 2},     // Arabic-Indic digits are split like ASCII ones
		{"ሰላም", 6},    // Ethiopic is "any other script": 2.0
	} {
		if got := EstimateTokens(tc.s); got != tc.want {
			t.Errorf("EstimateTokens(%q) = %d, want %d", tc.s, got, tc.want)
		}
	}
}

// The line "[0:01] <speaker>: " every long-line fixture starts with, so the
// continuation pieces carry a prefix to count.
const longLinePrefix = "[0:01] Me: "

// pieceFits fails the test unless every piece of the line is within the
// token budget by the oracle and the rune limit, and the pieces read back as
// the line: the first piece whole, each later one after its repeated prefix.
func pieceFits(t *testing.T, line string, pieces []string) {
	t.Helper()
	budget := float64(chunkTokenBudget())
	var back strings.Builder
	for i, p := range pieces {
		if got := oracleTokens(p); got > budget {
			t.Errorf("piece %d: %d runes, ~%.0f real tokens > the %.0f-token budget", i, utf8.RuneCountInString(p), got, budget)
		}
		if n := utf8.RuneCountInString(p); n > ChunkChars {
			t.Errorf("piece %d: %d runes > ChunkChars", i, n)
		}
		if i > 0 {
			p = strings.TrimPrefix(p, longLinePrefix)
		}
		back.WriteString(p)
	}
	if back.String() != line {
		t.Errorf("the pieces do not read back as the line: %d runes in, %d out", utf8.RuneCountInString(line), utf8.RuneCountInString(back.String()))
	}
}

// A single unbroken line in a dense script, longer than the token budget:
// every piece Chunk returns must fit it, whatever the rune limit says.
//
// Mutations, each RED: notes.go cutLine passes 1<<30 as the units bound of
// both fitRunes calls (the 40000-rune Han line comes back in 16000-rune
// pieces, ~9600 real tokens); Chunk drops `|| units > budget` (the
// mid-size lines below stay one piece).
func TestChunkLongDenseLinesFitTheTokenBudget(t *testing.T) {
	han := strings.Repeat("项目进度质量风险", 8)
	for name, body := range map[string]string{
		"han 12000":                            strings.Repeat(han, 12000/utf8.RuneCountInString(han)),
		"han 40000":                            strings.Repeat(han, 40000/utf8.RuneCountInString(han)),
		"hangul 12000":                         strings.Repeat("한국어회의록을정리했습니다", 12000/13),
		"han between budget and ChunkChars":    strings.Repeat(han, 15500/utf8.RuneCountInString(han)),
		"digits between budget and ChunkChars": strings.Repeat("4500 17082026 ", 12000/14),
		"emoji":                                strings.Repeat("👍🎉🔥", 3000),
	} {
		t.Run(name, func(t *testing.T) {
			line := longLinePrefix + body
			pieceFits(t, line, Chunk(line, ChunkChars))
		})
	}
}

// A cut never lands inside a grapheme cluster: no piece starts with a
// combining mark, a variation selector or a joiner, and an emoji ZWJ
// sequence stays whole.
//
// Mutation, RED: notes.go cutAt drops `startsCluster(r[m]) ||` from the
// loop condition (the Thai piece starts with the orphan mark U+0E47).
func TestCutNeverStartsWithACombiningMark(t *testing.T) {
	// Thai maitaikhu U+0E47 is a combining mark (Mn): the piece boundary is
	// set so that it falls right before it.
	thai := strings.Repeat("ก", 9) + "็" + strings.Repeat("ก", 9)
	// 👩‍💻 is woman + ZWJ + laptop; cuts of 9 and 10 runes land before the
	// ZWJ and before the laptop.
	emoji := strings.Repeat("a", 8) + "👩‍💻" + strings.Repeat("b", 8)
	vs := strings.Repeat("a", 8) + "❤️" + strings.Repeat("b", 8)
	for name, tc := range map[string]struct {
		line  string
		limit int
	}{
		"thai":               {thai, 9},
		"emoji zwj 9":        {emoji, 9},
		"emoji zwj 10":       {emoji, 10},
		"variation selector": {vs, 9},
	} {
		t.Run(name, func(t *testing.T) {
			pieces := cutLine(tc.line, tc.limit)
			if len(pieces) < 2 {
				t.Fatalf("%d pieces: the fixture did not cut", len(pieces))
			}
			for i, p := range pieces {
				if r, _ := utf8.DecodeRuneInString(p); startsCluster(r) {
					t.Errorf("piece %d %q starts with the cluster extender %U", i, p, r)
				}
				if last, _ := utf8.DecodeLastRuneInString(p); last == 0x200D {
					t.Errorf("piece %d %q ends on a joiner", i, p)
				}
			}
			if strings.Join(pieces, "") != tc.line {
				t.Errorf("the pieces do not read back as the line")
			}
		})
	}
	if got := truncateTokens("ก็ก็ก", 1); strings.ContainsRune(got, 0x0e47) && !strings.HasPrefix(got, "ก็") {
		t.Errorf("truncateTokens left an orphan mark: %q", got)
	}
	if got := truncateRunes("ab́c", 2); got != "a" {
		t.Errorf("truncateRunes(%q, 2) = %q, want the accent kept with its base: %q", "ab́c", got, "a")
	}
	if got := truncateTokens("aa👩‍💻", 1); strings.ContainsRune(got, '‍') || strings.ContainsRune(got, '👩') {
		t.Errorf("truncateTokens split the ZWJ sequence: %q", got)
	}
}

// The reduce prompt is bounded by reduceTokenBudget: 120 points of dense
// text cost more than the budget, so the prompt stops before the last ones
// and keeps the words-only merge for the rest.
//
// Mutation, RED: notes_points.go pairBatch drops the reduceTokenBudget break
// (all 120 lines are sent).
func TestReducePromptStopsAtItsTokenBudget(t *testing.T) {
	body := strings.Repeat("关于项目推进的详细计划安排与执行步骤的说明", 12)
	var open, decided []Point
	for i := 0; i < 60; i++ {
		open = append(open, Point{Text: fmt.Sprintf("第%d项议题:%s", i, body), Status: statusOpen})
		decided = append(decided, Point{Text: fmt.Sprintf("第%d项决定:%s", i, body), Status: statusDecided, Quote: "x"})
	}
	f := &fakeChat{replies: []string{`{"settles":[]}`}}
	parts := []ChunkNotes{{Points: open}, {Points: decided}}
	if _, err := (Composer{Chat: f}).pairPoints(t.Context(), parts); err != nil {
		t.Fatal(err)
	}
	if len(f.reqs) != 1 {
		t.Fatalf("%d reduce calls, want 1", len(f.reqs))
	}
	user := f.reqs[0].User
	lines := strings.Count(user, "\n")
	if lines >= 120 || lines < 50 {
		t.Errorf("%d lines in the reduce prompt, want a prompt cut short of 120 but not near-empty", lines)
	}
	if got := oracleTokens(user); got > float64(reduceTokenBudget()) {
		t.Errorf("the reduce prompt is ~%.0f real tokens > the %d budget", got, reduceTokenBudget())
	}
	if got := EstimateTokens(user); got > reduceTokenBudget() {
		t.Errorf("the reduce prompt estimates %d tokens > the %d budget", got, reduceTokenBudget())
	}
}

// The merge prompt is bounded by mergeTokenBudget, and a first summary that
// alone overflows is cut, not dropped to an empty prompt.
//
// Mutations, each RED: notes.go mergeSummary drops the mergeTokenBudget term
// (four 2394-rune digit parts go in, the rune bound allowing four); drops the
// `i > 0` break guard (the oversized first part sends an empty user prompt).
func TestMergePromptStopsAtItsTokenBudget(t *testing.T) {
	part := strings.Repeat("4500 17082026 ", 2400/14) // a token a rune: digits and spaces
	var parts []ChunkNotes
	for i := 0; i < 5; i++ {
		parts = append(parts, ChunkNotes{Summary: part})
	}
	f := &fakeChat{replies: []string{"合并的摘要。"}}
	(Composer{Chat: f}).mergeSummary(t.Context(), parts, "fallback", "zh")
	if got := strings.Count(f.reqs[0].User, "--- PART"); got != 3 {
		t.Errorf("%d parts in the merge prompt, want 3: five digit-heavy parts of %d runes cost more than the token budget, and the rune budget alone would allow 4", got, utf8.RuneCountInString(part))
	}
	if got := oracleTokens(f.reqs[0].User); got > float64(mergeTokenBudget()) {
		t.Errorf("the merge prompt is ~%.0f real tokens > the %d budget", got, mergeTokenBudget())
	}

	f = &fakeChat{replies: []string{"ok"}}
	big := ChunkNotes{Summary: strings.Repeat("项", 30000)}
	(Composer{Chat: f}).mergeSummary(t.Context(), []ChunkNotes{big, {Summary: "second"}}, "fallback", "zh")
	user := f.reqs[0].User
	if !strings.HasPrefix(user, "--- PART 1 ---") || utf8.RuneCountInString(user) < 1000 {
		t.Errorf("an oversized first summary sent %d runes %q, want its head", utf8.RuneCountInString(user), user[:min(len(user), 40)])
	}
	if got := EstimateTokens(user); got > mergeTokenBudget() {
		t.Errorf("the cut first summary estimates %d tokens > the %d budget", got, mergeTokenBudget())
	}
}

// Every calibration sample, repeated to ~40k runes, chunks into pieces whose
// real token count (that sample's measured rate, 5% slack) plus the wrapper
// fits chunkPromptTokens, so the prompt plus the answer cap plus the system
// prompt (485 real tokens measured for chunkSystem) fits NotesContextTokens.
// This is the language-independence claim of the estimator, checked per
// script against the real tokenizer's counts.
func TestEveryCalibrationSampleChunksWithinTheContext(t *testing.T) {
	const systemTokens = 485 // chunkSystem, measured with /tokenize
	for _, tc := range tokenCalibration {
		t.Run(tc.name, func(t *testing.T) {
			rate := float64(tc.real) / float64(utf8.RuneCountInString(tc.text))
			text := strings.Repeat(tc.text, 40000/utf8.RuneCountInString(tc.text)+1)
			pieces := Chunk(text, ChunkChars)
			for i, p := range pieces {
				real := math.Ceil(rate * 1.05 * float64(utf8.RuneCountInString(p)))
				if total := real + chunkWrapperTokens + maxAnswer + systemTokens; total > float64(NotesContextTokens()) {
					t.Errorf("piece %d: %d runes ~ %.0f real tokens, +wrapper+answer+system = %.0f > context %d",
						i, utf8.RuneCountInString(p), real, total, NotesContextTokens())
				}
			}
		})
	}
}

// Chunk sizes for English and Russian after the estimator was calibrated:
// English is cut exactly as main cut it (the rune cap lands first, a chunk
// is 15875 runes); Russian still makes 4 chunks but each holds fewer lines,
// because a Cyrillic rune and a space are charged 0.4 and 1.0 tokens and the
// token budget now lands before the rune cap (main: 156 lines of 102 runes
// per chunk, 15911 runes). Real Russian costs 0.24-0.58 tokens a rune, so a
// chatty Russian chunk of 15911 runes could overflow the context; this one
// cannot.
func TestEnglishAndRussianChunkSizes(t *testing.T) {
	en := strings.Repeat("[0:01] Me: "+strings.Repeat("word ", 30)+"\n", 300)
	ru := strings.Repeat("[0:05] Я: Мы обсудили план релиза, риски по срокам и распределение задач между командами на квартал.\n", 500)
	enChunks, ruChunks := Chunk(en, ChunkChars), Chunk(ru, ChunkChars)
	if len(enChunks) != 4 || len(ruChunks) != 4 {
		t.Fatalf("%d english and %d russian chunks, want 4 and 4", len(enChunks), len(ruChunks))
	}
	if got := utf8.RuneCountInString(enChunks[0]); got != 15875 {
		t.Errorf("english chunk = %d runes, want the 15875 main cuts", got)
	}
	if got := utf8.RuneCountInString(ruChunks[0]); got >= 15911 || got < 12000 {
		t.Errorf("russian chunk = %d runes, want under main's 15911 and over 12000", got)
	}
}

// NotesContextTokens covers the largest prompt budget of any call, its
// answer cap and the overhead, in whole 512-token blocks.
func TestNotesContextTokensCoversTheLargestCall(t *testing.T) {
	ctx := NotesContextTokens()
	if ctx%512 != 0 {
		t.Errorf("context %d is not a multiple of 512", ctx)
	}
	for name, need := range map[string]int{
		"map":    chunkTokenBudget() + chunkWrapperTokens + maxAnswer + notesPromptOverhead,
		"reduce": reduceTokenBudget() + reduceAnswer + notesPromptOverhead,
		"merge":  mergeTokenBudget() + mergeAnswer + notesPromptOverhead,
	} {
		if need > ctx {
			t.Errorf("%s call needs %d > context %d", name, need, ctx)
		}
	}
	if ctx-512 >= max(chunkPromptTokens+maxAnswer, reducePromptTokens+reduceAnswer, mergePromptTokens+mergeAnswer)+notesPromptOverhead {
		t.Errorf("context %d is more than one block above the largest call", ctx)
	}
}

// The reduce call's answer cap covers the longest answer pairSchema allows for a full prompt: maxReducePoints entries
// (one per open line), each naming maxSettleIDs ids of four digits (a meeting of thousands of points). Two counts:
// the estimator and the independent oracle on the compact rendering, and the rate measured on the 9B with the
// daemon's flags (35.4 tokens an entry in its widest layout, 36 rounded up). The schema must carry the two bounds the
// count relies on, or the "longest answer" is not a bound at all.
// Mutation: notes.go reduceAnswer = 600 (the value a real 24 GB run reached exactly) -> RED.
func TestReduceAnswerCoversTheLargestAnswerTheFormatAllows(t *testing.T) {
	const measuredTokensPerEntry = 36 // 9B, forced to maxSettleIDs ids per entry, 40-100 entries: 35.4 at most
	props := pairSchema()["properties"].(map[string]any)["settles"].(map[string]any)
	if got := props["maxItems"]; got != maxReducePoints {
		t.Fatalf("settles maxItems = %v, want maxReducePoints %d: the answer length is unbounded", got, maxReducePoints)
	}
	dec := props["items"].(map[string]any)["properties"].(map[string]any)["decided"].(map[string]any)
	if got := dec["maxItems"]; got != maxSettleIDs {
		t.Fatalf("decided maxItems = %v, want maxSettleIDs %d: the answer length is unbounded", got, maxSettleIDs)
	}
	var claims []settleClaim
	for i := 0; i < maxReducePoints; i++ {
		c := settleClaim{Open: 9000 + i}
		for k := 0; k < maxSettleIDs; k++ {
			c.Decided = append(c.Decided, 9100+k)
		}
		claims = append(claims, c)
	}
	raw, err := json.Marshal(map[string]any{"settles": claims})
	if err != nil {
		t.Fatal(err)
	}
	answer := string(raw)
	t.Logf("longest reduce answer: %d bytes, ~%d estimated tokens, ~%.0f oracle tokens, ~%d measured", len(answer), EstimateTokens(answer), oracleTokens(answer), maxReducePoints*measuredTokensPerEntry)
	if got := EstimateTokens(answer); got > reduceAnswer {
		t.Errorf("the longest reduce answer is ~%d estimated tokens > reduceAnswer %d: the settle step would be cut", got, reduceAnswer)
	}
	if got := oracleTokens(answer); got > float64(reduceAnswer) {
		t.Errorf("the longest reduce answer is ~%.0f oracle tokens > reduceAnswer %d: the settle step would be cut", got, reduceAnswer)
	}
	if got := maxReducePoints * measuredTokensPerEntry; got > reduceAnswer {
		t.Errorf("the longest reduce answer is ~%d tokens at the measured rate > reduceAnswer %d: the settle step would be cut", got, reduceAnswer)
	}
}
