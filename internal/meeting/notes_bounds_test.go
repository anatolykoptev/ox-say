package meeting

import (
	"fmt"
	"strings"
	"testing"
	"unicode"
	"unicode/utf8"
)

// denseRunes counts the scripts that tokenize at about one token per rune.
// It is the test's own oracle, independent of EstimateTokens, so an
// estimator that underweights CJK still fails the checks below: a prompt of
// D dense runes costs the model at least D tokens.
func denseRunes(s string) int {
	n := 0
	for _, r := range s {
		if unicode.Is(unicode.Han, r) || unicode.Is(unicode.Hiragana, r) ||
			unicode.Is(unicode.Katakana, r) || unicode.Is(unicode.Hangul, r) {
			n++
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
		if got := denseRunes(prompt) + r.MaxTokens; got > ctx {
			t.Errorf("call %d: %d dense runes + %d-token answer = %d > context %d", i, denseRunes(prompt), r.MaxTokens, got, ctx)
		}
		if got := EstimateTokens(prompt) + r.MaxTokens; got > ctx {
			t.Errorf("call %d: ~%d tokens + %d-token answer = %d > context %d", i, EstimateTokens(prompt), r.MaxTokens, got, ctx)
		}
	}
	if utf8.RuneCountInString(f.reqs[0].User) < 1000 {
		t.Errorf("the map prompt holds only %d runes: the fixture did not exercise the bound", utf8.RuneCountInString(f.reqs[0].User))
	}
}

// The estimator weighs the dense scripts at one token per rune and keeps
// the 2.5-runes-per-token density for the rest, rounding up.
// Mutation: internal/meeting/notes.go runeUnits, weigh a dense rune like a
// Latin one (return 2) -> RED.
func TestEstimateTokensWeighsTheDenseScripts(t *testing.T) {
	for _, tc := range []struct {
		s    string
		want int
	}{
		{"", 0},
		{"hello", 2},
		{"word word word", 6}, // 14 runes: ceil(28/5)
		{"项目中", 3},
		{"あいうえお", 5},
		{"한국어", 3},
		{"。、", 2},    // CJK punctuation is dense too
		{"ＦＵＬＬ", 4},  // fullwidth forms
		{"a中", 2},    // 2 + 5 units
		{"ラーメン・", 5}, // the prolonged-sound mark and the middle dot are script-Common
	} {
		if got := EstimateTokens(tc.s); got != tc.want {
			t.Errorf("EstimateTokens(%q) = %d, want %d", tc.s, got, tc.want)
		}
	}
}

// The English path is unchanged: this fixture cuts into the 4 chunks main
// (777c3b9) produced — verified there before this test was written. A token
// bound that cuts an English transcript differently is a regression.
func TestEnglishTranscriptChunksAsBefore(t *testing.T) {
	en := strings.Repeat("[0:01] Me: "+strings.Repeat("word ", 30)+"\n", 300)
	ru := strings.Repeat("[0:05] Я: Мы обсудили план релиза, риски по срокам и распределение задач между командами на квартал.\n", 500)
	for name, tc := range map[string]struct {
		text string
		want int
	}{"english": {en, 4}, "russian": {ru, 4}} {
		if got := len(Chunk(tc.text, ChunkChars)); got != tc.want {
			t.Errorf("%s: %d chunks, want the %d chunks main produces", name, got, tc.want)
		}
	}
}
