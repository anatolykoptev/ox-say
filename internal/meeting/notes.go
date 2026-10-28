package meeting

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"regexp"
	"sort"
	"strings"
	"syscall"
	"time"
	"unicode"
	"unicode/utf8"

	"github.com/anatolykoptev/ox-say/internal/voices"
)

// ChunkChars is the size of one map step's transcript: about 16k characters,
// the size the notes spike measured with -c 16384 (a call of 5k prompt tokens
// leaves the context room for a 3k-token answer).
const ChunkChars = 16000

const (
	// similarAction and similarLine: word overlap at which two items are one.
	similarAction = 0.6
	similarLine   = 0.7
	// summaryBudget caps the partial summaries sent to the merge call.
	summaryBudget = 12000
	maxAnswer     = 3000
)

const (
	// callTimeout bounds one model call. Generous on purpose: a 16k-character
	// chunk is a ~5k-token prompt, and on an Intel CPU llama-server reads the
	// prompt at a few tokens a second and then writes the answer at about one,
	// so a healthy call can take many minutes. The bound only exists so a hung
	// server cannot hold the notes run forever.
	callTimeout = 30 * time.Minute
	// retryDelay is the pause before retrying a call that failed because the
	// server was busy or not up yet (HTTP 503, connection refused).
	retryDelay = 5 * time.Second
)

// ActionItem is one task; Who and When are empty when the transcript names
// neither.
type ActionItem struct {
	Who  string `json:"who"`
	What string `json:"what"`
	When string `json:"when"`
}

// ChunkNotes is what the model returns for one chunk (and, merged, the notes).
type ChunkNotes struct {
	Summary       string       `json:"summary"`
	Decisions     []string     `json:"decisions"`
	ActionItems   []ActionItem `json:"action_items"`
	OpenQuestions []string     `json:"open_questions"`
	Numbers       []string     `json:"numbers"`
}

// Notes are the finished notes. SkippedChunks lists the zero-based chunks the
// model failed on twice; the notes say so instead of looking complete.
type Notes struct {
	ChunkNotes
	SkippedChunks []int `json:"skipped_chunks,omitempty"`
	// Labels is what the far side's voices were called (voice id -> label) in the text the model read, kept with
	// the notes so a rename can be replayed from it exactly once: the substitution is the difference between this
	// map and the new one, and a request applied twice finds nothing left to change. Set by the runner, never by
	// the model.
	Labels map[string]string `json:"labels,omitempty"`
}

// turnPrefix matches the "[m:ss] Name: " a prompt line starts with.
var turnPrefix = regexp.MustCompile(`^\[[0-9:]+\] [^:\n]{1,64}: `)

// Chunk splits text into pieces of at most limit characters, breaking only at
// line ends. A line longer than limit is cut, and every piece after the first
// repeats the line's "[time] Speaker: " prefix so the model never reads an
// unattributed fragment. A limit of zero or less means ChunkChars.
func Chunk(text string, limit int) []string {
	if limit <= 0 {
		limit = ChunkChars
	}
	if strings.TrimSpace(text) == "" {
		return nil
	}
	var out []string
	var cur strings.Builder
	flush := func() {
		if s := strings.TrimRight(cur.String(), "\n"); strings.TrimSpace(s) != "" {
			out = append(out, s)
		}
		cur.Reset()
	}
	for _, line := range strings.Split(strings.TrimRight(text, "\n"), "\n") {
		if runeLen(line) > limit {
			flush()
			out = append(out, cutLine(line, limit)...)
			continue
		}
		if runeLen(cur.String())+runeLen(line)+1 > limit {
			flush()
		}
		cur.WriteString(line)
		cur.WriteByte('\n')
	}
	flush()
	return out
}

// cutLine cuts one overlong line into pieces of at most limit characters, each
// continuation led by the line's own speaker prefix when it has one and the
// prefix leaves room for text.
func cutLine(line string, limit int) []string {
	prefix := turnPrefix.FindString(line)
	if runeLen(prefix) > limit/2 {
		prefix = ""
	}
	r := []rune(line)
	out := []string{string(r[:limit])}
	r = r[limit:]
	room := limit - runeLen(prefix)
	for len(r) > 0 {
		n := min(room, len(r))
		out = append(out, prefix+string(r[:n]))
		r = r[n:]
	}
	return out
}

var unstated = map[string]bool{
	"": true, "not stated": true, "unknown": true, "n/a": true, "none": true, "-": true, "—": true,
	"не указано": true, "не указан": true, "не указана": true, "неизвестно": true,
}

func isUnstated(s string) bool { return unstated[strings.ToLower(strings.TrimSpace(s))] }

// MergeChunks joins the per-chunk notes and removes repeats in code: the same
// task found in two chunks, or twice in one, appears once, with the owner and
// date when either copy had them. Order is first appearance.
//
// Two lines are never merged when they differ in a number or, for decisions,
// questions and tasks, in a proper name: "Pay Bob 500" and "Pay Ann 500" share
// most words and are two facts. Key numbers merge only when identical after
// normalization.
//
// Owners are compared as people, not as strings: "Анатолий", "Anatoliy" and
// "Anatoly" are one person, "Ann" and "Anna" are two, and two different named
// owners never merge, however alike their tasks. Labels is threaded in here
// rather than applied in Compose because the merge is where owners are
// compared: a spelling of the recorder's own name (Labels.Me) becomes that
// label, so MergeChunks is correct for any caller. A named owner is never
// mapped to Labels.Them: a group call has several far-side people.
func MergeChunks(parts []ChunkNotes, l Labels) Notes {
	var n Notes
	var summaries []string
	for _, p := range parts {
		if s := strings.TrimSpace(p.Summary); s != "" {
			summaries = append(summaries, s)
		}
		n.Decisions = append(n.Decisions, p.Decisions...)
		n.ActionItems = append(n.ActionItems, p.ActionItems...)
		n.OpenQuestions = append(n.OpenQuestions, p.OpenQuestions...)
		n.Numbers = append(n.Numbers, p.Numbers...)
	}
	n.Summary = strings.Join(summaries, "\n\n")
	n.Decisions = dedupeLines(n.Decisions, true)
	n.OpenQuestions = dedupeLines(n.OpenQuestions, true)
	n.Numbers = dedupeLines(n.Numbers, false)
	n.ActionItems = dedupeActions(n.ActionItems, l)
	return n
}

// dedupeLines drops repeats. fuzzy off: only lines equal after normalization
// are one. fuzzy on: lines that share most words are one too, unless they
// differ in a number or a proper name.
func dedupeLines(in []string, fuzzy bool) []string {
	var out []string
	for _, s := range in {
		s = strings.TrimSpace(s)
		if s == "" {
			continue
		}
		dup := false
		for _, o := range out {
			if normKey(s) == normKey(o) || (fuzzy && voices.WordOverlap(s, o) >= similarLine && !factsDiffer(s, o)) {
				dup = true
				break
			}
		}
		if !dup {
			out = append(out, s)
		}
	}
	return out
}

func dedupeActions(in []ActionItem, l Labels) []ActionItem {
	var out []ActionItem
	for _, a := range in {
		a.What = strings.TrimSpace(a.What)
		if a.What == "" {
			continue
		}
		a.Who = canonicalOwner(a.Who, l)
		merged := false
		for i, o := range out {
			if !sameTask(a, o) {
				continue
			}
			if len(a.What) > len(o.What) {
				out[i].What = a.What
			}
			if isUnstated(o.Who) {
				out[i].Who = a.Who
			}
			if isUnstated(o.When) {
				out[i].When = a.When
			}
			merged = true
			break
		}
		if !merged {
			out = append(out, a)
		}
	}
	return out
}

// sameTask: a and o are one task. Never when their numbers or names differ,
// when both state a different date, or when two different named people own
// them ("Bob sends the deck", "Ann sends the deck" are two tasks); otherwise a
// similarAction word overlap is enough.
func sameTask(a, o ActionItem) bool {
	if factsDiffer(a.What, o.What) || !sameOwner(a.Who, o.Who) {
		return false
	}
	if !isUnstated(a.When) && !isUnstated(o.When) && normKey(a.When) != normKey(o.When) {
		return false
	}
	return voices.WordOverlap(a.What, o.What) >= similarAction
}

// sameOwner: two owners agree when either is unstated or they are the same
// person, one name spelled two ways.
func sameOwner(a, b string) bool {
	return isUnstated(a) || isUnstated(b) || foldName(a) == foldName(b)
}

// canonicalOwner returns the speaker label when who is a spelling of the
// recorder's own name (Labels.Me), and who unchanged otherwise. A call can have
// many people on the far side, so a named owner is never mapped to Labels.Them:
// every real name the model extracted stays.
func canonicalOwner(who string, l Labels) string {
	who = strings.TrimSpace(who)
	if me := strings.TrimSpace(l.Me); !isUnstated(who) && me != "" && foldName(who) == foldName(me) {
		return me
	}
	return who
}

var cyrillic = map[rune]string{
	'а': "a", 'б': "b", 'в': "v", 'г': "g", 'д': "d", 'е': "e", 'ё': "e", 'ж': "zh", 'з': "z",
	'и': "i", 'й': "y", 'к': "k", 'л': "l", 'м': "m", 'н': "n", 'о': "o", 'п': "p", 'р': "r",
	'с': "s", 'т': "t", 'у': "u", 'ф': "f", 'х': "kh", 'ц': "ts", 'ч': "ch", 'ш': "sh",
	'щ': "sch", 'ы': "y", 'э': "e", 'ю': "yu", 'я': "ya",
}

var diacritics = strings.NewReplacer(
	"á", "a", "à", "a", "â", "a", "ä", "a", "ã", "a", "å", "a",
	"é", "e", "è", "e", "ê", "e", "ë", "e", "í", "i", "ì", "i", "î", "i", "ï", "i",
	"ó", "o", "ò", "o", "ô", "o", "ö", "o", "õ", "o", "ú", "u", "ù", "u", "û", "u", "ü", "u",
	"ý", "y", "ñ", "n", "ç", "c", "ß", "ss",
)

// foldName reduces a person's name to a key that is the same for its spellings:
// lower case, Cyrillic written in Latin letters, accents removed, and the
// common Russian ending -ий/-iy/-ij/-ii written -y ("Анатолий", "Anatoliy",
// "Anatoly"). Exact equality of keys, never similarity: "Ann" and "Anna" are
// two people.
func foldName(s string) string {
	var b strings.Builder
	for _, r := range diacritics.Replace(strings.ToLower(s)) {
		switch {
		case cyrillic[r] != "":
			b.WriteString(cyrillic[r])
		case unicode.IsLetter(r) || unicode.IsDigit(r):
			b.WriteRune(r)
		}
	}
	k := b.String()
	for _, end := range []string{"iy", "ij", "ii"} {
		if strings.HasSuffix(k, end) && len(k) > len(end) {
			return strings.TrimSuffix(k, end) + "y"
		}
	}
	return k
}

// factsDiffer: a and b disagree on a number or a proper name, so a word
// overlap between them must not make them one line.
func factsDiffer(a, b string) bool {
	return numbersOf(a) != numbersOf(b) || namesMissing(a, b) || namesMissing(b, a)
}

var numberRun = regexp.MustCompile(`\d+(?:[.,]\d+)*`)

// numbersOf is the sorted list of numbers in s, as one comparable string.
func numbersOf(s string) string {
	nums := numberRun.FindAllString(s, -1)
	sort.Strings(nums)
	return strings.Join(nums, " ")
}

// namesMissing: s has a capitalized word whose lower-case form t does not have
// at all. Case is read this way (not "capitalized in both") so a sentence-start
// "Use" matches "use" and "Bob" does not match "Ann".
func namesMissing(s, t string) bool {
	have := map[string]bool{}
	for _, w := range tokens(t) {
		have[strings.ToLower(w)] = true
	}
	for _, w := range tokens(s) {
		r, _ := utf8.DecodeRuneInString(w)
		if utf8.RuneCountInString(w) >= 2 && unicode.IsUpper(r) && !have[strings.ToLower(w)] {
			return true
		}
	}
	return false
}

func tokens(s string) []string {
	return strings.FieldsFunc(s, func(r rune) bool { return !unicode.IsLetter(r) && !unicode.IsDigit(r) })
}

// normKey is s lower-cased with punctuation and spacing removed.
func normKey(s string) string {
	return strings.ToLower(strings.Join(tokens(s), " "))
}

// Chat is the language model, behind the one call the notes need. Schema nil
// asks for free text.
type Chat interface {
	Complete(ctx context.Context, r Request) (string, error)
}

// Request is one chat call.
type Request struct {
	System, User string
	Schema       map[string]any
	MaxTokens    int
}

// ErrNoNotes: the model failed on every chunk.
var ErrNoNotes = errors.New("meeting: the notes model failed on every part of the transcript")

// chunkSchema is the answer shape of a map step; llama-server turns it into a
// grammar, so the reply is always parseable JSON of this shape.
func chunkSchema() map[string]any {
	str := map[string]any{"type": "string"}
	list := map[string]any{"type": "array", "items": str}
	return map[string]any{
		"type": "object",
		"properties": map[string]any{
			"summary":   str,
			"decisions": list,
			"action_items": map[string]any{"type": "array", "items": map[string]any{
				"type":                 "object",
				"properties":           map[string]any{"who": str, "what": str, "when": str},
				"required":             []string{"who", "what", "when"},
				"additionalProperties": false,
			}},
			"open_questions": list,
			"numbers":        list,
		},
		"required":             []string{"summary", "decisions", "action_items", "open_questions", "numbers"},
		"additionalProperties": false,
	}
}

// languageNames maps a notes language code (the Manifest.Language the headings
// use) to the name the prompts give the model. Adding a language is a row here
// and a row in headings.
//
// The codes are the ones voices.Language returns. Only en and ru have a
// headings row; the others get English headings over notes the model writes in
// the named language.
var languageNames = map[string]string{
	"en": "English", "ru": "Russian", "uk": "Ukrainian", "de": "German", "fr": "French",
	"es": "Spanish", "it": "Italian", "pt": "Portuguese", "nl": "Dutch", "pl": "Polish",
	"sv": "Swedish", "da": "Danish", "cs": "Czech", "sk": "Slovak", "ro": "Romanian",
}

// languageRule names the output language. A small model told only "the same
// language as the transcript" drifts into English for part of the fields; a
// code outside the table keeps that older wording.
func languageRule(lang string) string {
	const keep = "Never translate quotes, names or numbers. "
	if name, ok := languageNames[lang]; ok {
		return "Write every field in " + name + ". " + keep
	}
	return "Write every field in the same language as the transcript. " + keep
}

func chunkSystem(l Labels, lang string) string {
	return "You write meeting notes from one part of a transcript. " + languageRule(lang) +
		"Use ONLY facts stated in the transcript; never invent names, numbers, dates or owners. " +
		fmt.Sprintf("The speakers are %q (the person who recorded the call) and %s; in \"who\" use these names, or a name said in the transcript. ", l.Me, otherPeople(l)) +
		"If the owner or the date of an action item is not stated, leave that field an empty string. " +
		"Attribute each action to the person who said they will do it; do not swap who did what. " +
		"Do not repeat the owner's name inside \"what\". " +
		"summary: 2-4 sentences. decisions: what was agreed. " +
		"action_items: every task someone took on or was asked to do, one entry per task; a task someone committed to with an owner belongs here, not only in decisions. " +
		"open_questions: questions left unanswered. numbers: key numbers, amounts and dates with what they refer to. Skip small talk. " +
		"Use empty lists when a part has nothing for a field."
}

// otherPeople describes the other people on the call to the model: one label for
// everyone when the transcript has no voices, else each voice by name, as
// separate people.
func otherPeople(l Labels) string {
	var names []string
	seen := map[string]bool{}
	ids := make([]string, 0, len(l.Names))
	for id := range l.Names {
		if VoiceNumber(id) > 0 {
			ids = append(ids, id)
		}
	}
	sort.Slice(ids, func(i, j int) bool { return VoiceNumber(ids[i]) < VoiceNumber(ids[j]) })
	for _, id := range ids {
		if n := strings.TrimSpace(l.Names[id]); n != "" && !seen[n] {
			seen[n] = true
			names = append(names, fmt.Sprintf("%q", n))
		}
	}
	if len(names) < 2 {
		return fmt.Sprintf("%q (everyone else on the call)", l.label(SpeakerThem))
	}
	return strings.Join(names, ", ") + " (the other people on the call, each a separate person)"
}

func mergeSystem(lang string) string {
	return "You merge partial meeting summaries into one summary of 3-5 lines. " + languageRule(lang) +
		"Use ONLY facts present in them; never invent names, numbers, dates or owners. Output the summary text only."
}

// EngineDownError is a model call that failed because the notes engine could
// not be started, not because of the transcript. Another chunk would only
// start it again, so Compose stops and returns it for the meeting to record.
// Retryable marks a start that may well succeed a second time (a health
// timeout on a cold load, a crashed child): Compose allows exactly one more
// start per run for those, and none for the rest (a verify refusal repeats).
type EngineDownError struct {
	Err       error
	Retryable bool
}

func (e *EngineDownError) Error() string { return e.Err.Error() }
func (e *EngineDownError) Unwrap() error { return e.Err }

// Composer runs the map-reduce. Before, when set, runs ahead of every model
// call: the daemon passes the dictation yield so notes never starve a user who
// is dictating.
type Composer struct {
	Chat   Chat
	Before func(ctx context.Context) error
	Log    *slog.Logger
	// CallTimeout bounds one model call; zero means the callTimeout constant.
	CallTimeout time.Duration
	// RetryDelay is the pause before retrying a busy or unreachable server;
	// zero means the retryDelay constant.
	RetryDelay time.Duration
}

func (c Composer) callTimeout() time.Duration {
	if c.CallTimeout > 0 {
		return c.CallTimeout
	}
	return callTimeout
}

func (c Composer) retryDelay() time.Duration {
	if c.RetryDelay > 0 {
		return c.RetryDelay
	}
	return retryDelay
}

// call is one model call under its own deadline, so a hung server cannot hold
// the notes run forever. Before runs outside it: waiting for a dictation to
// finish is not the model being slow.
func (c Composer) call(ctx context.Context, r Request) (string, error) {
	ctx, cancel := context.WithTimeout(ctx, c.callTimeout())
	defer cancel()
	return c.Chat.Complete(ctx, r)
}

// Compose writes the notes for the transcript text: one structured call per
// chunk, a dedupe in code, and one short call to merge the summaries. lang is
// the meeting's notes language, the same code NotesMarkdown takes.
func (c Composer) Compose(ctx context.Context, transcript string, l Labels, lang string) (Notes, error) {
	chunks := Chunk(transcript, ChunkChars)
	var parts []ChunkNotes
	var skipped []int
	restarts := 1 // extra engine starts this run may spend on a retryable failure
	for i, ch := range chunks {
		got, err := c.chunk(ctx, l, lang, i, len(chunks), ch, &restarts)
		if err != nil {
			if ctx.Err() != nil {
				return Notes{}, ctx.Err()
			}
			var down *EngineDownError
			if errors.As(err, &down) {
				return Notes{}, err
			}
			c.logf("notes: chunk failed", slog.Int("chunk", i), slog.Any("error", err))
			skipped = append(skipped, i)
			continue
		}
		parts = append(parts, got)
	}
	if len(parts) == 0 {
		return Notes{}, ErrNoNotes
	}
	n := MergeChunks(parts, l)
	n.SkippedChunks = skipped
	if len(parts) > 1 {
		n.Summary = c.mergeSummary(ctx, parts, n.Summary, lang)
	}
	return n, nil
}

// errEmptyNotes: the model returned valid JSON with nothing in it. The system
// prompt asks for a summary of every part, so an all-empty answer is a failed
// one, not a quiet part.
var errEmptyNotes = errors.New("meeting: the notes model returned empty notes")

func (n ChunkNotes) empty() bool {
	return strings.TrimSpace(n.Summary) == "" && len(n.Decisions) == 0 && len(n.ActionItems) == 0 &&
		len(n.OpenQuestions) == 0 && len(n.Numbers) == 0
}

// retryable: the server was busy or not up yet, so a retry should wait a
// moment. A parse failure or an empty answer retries at once.
func retryable(err error) bool {
	var se *StatusError
	return errors.Is(err, syscall.ECONNREFUSED) || (errors.As(err, &se) && se.Code == http.StatusServiceUnavailable)
}

func (c Composer) chunk(ctx context.Context, l Labels, lang string, i, total int, text string, restarts *int) (ChunkNotes, error) {
	req := Request{
		System:    chunkSystem(l, lang),
		User:      fmt.Sprintf("This is part %d of %d of a meeting transcript. Write the notes for this part only.\n\nTRANSCRIPT PART:\n%s", i+1, total, text),
		Schema:    chunkSchema(),
		MaxTokens: maxAnswer,
	}
	var lastErr error
	for attempt := 0; attempt < 2; attempt++ {
		if attempt > 0 && retryable(lastErr) {
			select {
			case <-time.After(c.retryDelay()):
			case <-ctx.Done():
				return ChunkNotes{}, ctx.Err()
			}
		}
		if c.Before != nil {
			if err := c.Before(ctx); err != nil {
				return ChunkNotes{}, err
			}
		}
		raw, err := c.call(ctx, req)
		if err == nil {
			var out ChunkNotes
			if err = json.Unmarshal([]byte(raw), &out); err == nil {
				if !out.empty() {
					return out, nil
				}
				err = errEmptyNotes
			}
		}
		if ctx.Err() != nil {
			return ChunkNotes{}, ctx.Err()
		}
		if errors.Is(err, context.DeadlineExceeded) {
			// The call used its whole deadline; a second one would too.
			return ChunkNotes{}, err
		}
		var down *EngineDownError
		if errors.As(err, &down) {
			if !down.Retryable || attempt > 0 || *restarts <= 0 {
				return ChunkNotes{}, err
			}
			*restarts-- // the run's one extra start
		}
		lastErr = err
	}
	return ChunkNotes{}, lastErr
}

// mergeSummary asks the model for one short summary of the partial ones; on
// any failure (an error, a cut-off answer, an empty or oversized one) the
// partial summaries stand as they are.
func (c Composer) mergeSummary(ctx context.Context, parts []ChunkNotes, fallback, lang string) string {
	var b strings.Builder
	for i, p := range parts {
		s := strings.TrimSpace(p.Summary)
		if runeLen(b.String())+runeLen(s) > summaryBudget {
			break
		}
		fmt.Fprintf(&b, "--- PART %d ---\n%s\n\n", i+1, s)
	}
	if c.Before != nil && c.Before(ctx) != nil {
		return fallback
	}
	out, err := c.call(ctx, Request{System: mergeSystem(lang), User: b.String(), MaxTokens: 800})
	out = strings.TrimSpace(out)
	if err != nil || out == "" || runeLen(out) > 2000 {
		return fallback
	}
	return out
}

func (c Composer) logf(msg string, args ...any) {
	if c.Log != nil {
		c.Log.Warn(msg, args...)
	}
}

// runeLen is utf8.RuneCountInString: chunk sizes count characters, the way the
// notes spike measured them, so Cyrillic is not charged twice.
func runeLen(s string) int { return utf8.RuneCountInString(s) }
