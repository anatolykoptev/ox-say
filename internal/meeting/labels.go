package meeting

import (
	"encoding/json"
	"errors"
	"maps"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"unicode"
	"unicode/utf8"

	"github.com/anatolykoptev/ox-say/internal/vproject"
)

// A rename changes only what the transcript prints for a voice, so the notes already written are corrected by
// substitution instead of being written again by the model (minutes of the heavy slot for a changed name).
// Which words may be substituted is the whole rule:
//   - a numbered label ("Speaker 2") and a name the user gave: wherever it stands as a whole word, in any field;
//   - the generic far-side label ("Other", "Собеседник"): only where an action item's "who" is exactly that label,
//     because as a word it is ordinary text ("Other options were discussed").
//
// A merge, an unmerge and the split change who said what: they queue the notes again (EditSpeakers).

// labelChanges are the substitutions one rename asks for.
type labelChanges struct {
	free     map[string]string // whole words, in any field
	exact    map[string]string // a field that is exactly the label (action item owners)
	labels   map[string]string // what the voices are called after the rename: stored with the notes
	others   []string          // every label and name involved, before and after
	conflict bool              // one old label would have to become two different new ones
}

func (c labelChanges) empty() bool { return len(c.free) == 0 && len(c.exact) == 0 }

// labelMap is what the transcript prints for each far-side voice and for the single far-side label under st, by
// id. It is stored with the notes (Notes.Labels): the substitution a rename needs is the difference between this
// map as the notes were written and as it is now, so the same rename applied twice changes nothing the second time.
func labelMap(m Manifest, st SpeakerState, raw []Turn) map[string]string {
	shown, _ := Present(m, st, raw)
	out := map[string]string{}
	for _, id := range append(voiceIDs(raw), SpeakerThem) {
		if l := shown.Labels.label(labelKey(id, m, st)); l != "" {
			out[id] = l
		}
	}
	return out
}

// changesBetween compares what the notes were written under (stored; nil for notes written before the map was
// kept, then what the state before the edit printed) with what the state after prints for the far side's voices
// and for the single far-side label. m carries the labels; raw the turns (for the voice ids).
func changesBetween(m Manifest, before, after SpeakerState, raw []Turn, stored map[string]string) labelChanges {
	was := stored
	if was == nil {
		was = labelMap(m, before, raw)
	}
	now := labelMap(m, after, raw)
	c := labelChanges{free: map[string]string{}, exact: map[string]string{}, labels: now}
	for _, mp := range []map[string]string{was, now} {
		for _, l := range mp {
			c.others = append(c.others, l)
		}
	}
	for id, old := range was {
		to, ok := now[id]
		if !ok || old == to || old == "" {
			continue
		}
		if prev, dup := c.exact[old]; dup && prev != to {
			c.conflict = true
		}
		c.exact[old] = to
		if id == SpeakerThem && strings.TrimSpace(before.Names[SpeakerThem]) == "" {
			continue // the generic label: exact only
		}
		c.free[old] = to
	}
	return c
}

// extension is what a new label adds to the old one when it is the old one followed by more words ("Ivan" ->
// "Ivan Petrov": " Petrov"). The addition must start at a word edge: "Ivan" -> "Ivanov" is another name, not a
// surname added.
func extension(old, to string) (string, bool) {
	ext, ok := strings.CutPrefix(to, old)
	if !ok || ext == "" {
		return "", false
	}
	if r, _ := utf8.DecodeRuneInString(ext); isWordRune(r) {
		return "", false
	}
	return ext, true
}

// safe reports whether substituting is unambiguous: no label that changes is part of any other label or name
// involved (before or after), so "Anna" -> "Anna Smith" cannot reach "Anna Lee", and "Speaker 1" is not inside the
// name "Speaker 1 (CFO)". The old label may stay inside its own replacement when that only adds words after it (a
// surname): replaceLabels does not extend a name that already has them, so it cannot grow "Ivan Petrov Petrov".
// A label equal to another (a swap) is fine: the pass is simultaneous.
func (c labelChanges) safe() bool {
	if c.conflict {
		return false
	}
	for old := range c.free {
		for _, x := range c.others {
			if x == old || !strings.Contains(x, old) {
				continue
			}
			if _, own := extension(old, c.free[old]); own && x == c.free[old] {
				continue
			}
			return false
		}
	}
	return true
}

// ambiguousIn reports a place in the notes where a whole-word substitution would miss the label or be wrong: the
// old label inside a longer run of letters (a Russian inflection "Ивану", Japanese "田中さん", "Speaker 10"), or the
// numbered label inflected ("Спикера 1"). Those notes are written again by the model instead.
func (c labelChanges) ambiguousIn(n Notes) bool {
	for old := range c.free {
		inflected := inflectedLabel(old)
		for _, s := range notesStrings(n) {
			for from := 0; ; {
				i := strings.Index(s[from:], old)
				if i < 0 {
					break
				}
				i += from
				if !wordEdgeBefore(s, i) || !wordEdgeAfter(s, i+len(old)) {
					return true
				}
				if ext, ok := extension(old, c.free[old]); ok && partialExtension(s[i+len(old):], ext) {
					return true
				}
				from = i + len(old)
			}
			if inflected != nil && inflected.MatchString(s) {
				return true
			}
		}
	}
	return false
}

// inlineSpace is the whitespace a name's words may be separated by: a line break is a sentence or paragraph
// boundary of the notes, not the space of a name.
func inlineSpace(r rune) bool { return r == ' ' || r == '\t' || r == '\u00a0' || r == '\u202f' }

// matchExtension reports whether s starts with ext, taking any run of spaces, tabs and no-break spaces in s (also
// none: "Ivan(CFO)" holds " (CFO)") for a run of whitespace in ext, and how many bytes of s that is. A line break
// does not match: "Ivan\nPetrov" is two paragraphs, and joining them would lose the break. fold ignores case.
func matchExtension(s, ext string, fold bool) (int, bool) {
	n := 0
	for _, er := range ext {
		if unicode.IsSpace(er) {
			for n < len(s) {
				r, w := utf8.DecodeRuneInString(s[n:])
				if !inlineSpace(r) {
					break
				}
				n += w
			}
			continue
		}
		if n >= len(s) {
			return 0, false
		}
		r, w := utf8.DecodeRuneInString(s[n:])
		if r != er && !(fold && strings.EqualFold(string(r), string(er))) {
			return 0, false
		}
		n += w
	}
	return n, true
}

// looseExtension is matchExtension across any whitespace, line breaks included, ignoring case: whether the text
// holds the extra words of the name at all.
func looseExtension(s, ext string) bool {
	n := 0
	for _, er := range ext {
		if unicode.IsSpace(er) {
			for n < len(s) {
				r, w := utf8.DecodeRuneInString(s[n:])
				if !unicode.IsSpace(r) {
					break
				}
				n += w
			}
			continue
		}
		if n >= len(s) {
			return false
		}
		r, w := utf8.DecodeRuneInString(s[n:])
		if r != er && !strings.EqualFold(string(r), string(er)) {
			return false
		}
		n += w
	}
	return true
}

// truncatedExtension reports text that holds the first words of ext and stops at a word edge inside it: "Ivan Pet"
// or "Ivan Petrov" for " Petrov Jr". The name would be written after them as "Ivan Petrov Pet".
func truncatedExtension(rest, ext string) bool {
	n, end, word := 0, 0, false
	for _, er := range ext {
		if unicode.IsSpace(er) {
			for n < len(rest) {
				r, w := utf8.DecodeRuneInString(rest[n:])
				if !unicode.IsSpace(r) {
					break
				}
				n += w
			}
			continue
		}
		if n < len(rest) {
			r, w := utf8.DecodeRuneInString(rest[n:])
			if r == er || strings.EqualFold(string(r), string(er)) {
				word = word || isWordRune(r)
				n += w
				end = n
				continue
			}
		}
		return word && wordEdgeAfter(rest, end)
	}
	return false
}

// partialExtension reports text that starts like the extra words of a new name (ext, " Petrov") without being them
// at a word edge: "Ivan Petrovich" or "Ivan petrov" after "Ivan", words cut short ("Ivan Pet"), or the words with
// a line break between them ("Ivan\nPetrov"). Substituting there would write "Ivan Petrov Petrovich", "Ivan
// Petrov Pet" or lose the break, so replaceLabels leaves it and the notes are written again. Text that holds the
// words exactly (across spaces and tabs), or does not start like them, is not partial.
func partialExtension(rest, ext string) bool {
	if !looseExtension(rest, ext) {
		return truncatedExtension(rest, ext)
	}
	n, exact := matchExtension(rest, ext, false)
	return !exact || !wordEdgeAfter(rest, n)
}

// inflectedLabel matches a numbered label whose word is inflected ("Спикера 1" for "Спикер 1"), or nil for a label
// that is not "<word> <number>".
func inflectedLabel(label string) *regexp.Regexp {
	word, num, ok := strings.Cut(label, " ")
	if !ok || num == "" || strings.Trim(num, "0123456789") != "" {
		return nil
	}
	return regexp.MustCompile(`(?:^|[^\p{L}\p{N}])` + regexp.QuoteMeta(word) + `\p{L}+ ` + num + `(?:$|[^\p{L}\p{N}])`)
}

// notesStrings lists every string of the notes the substitution reads.
func notesStrings(n Notes) []string {
	out := []string{n.Summary}
	out = append(out, n.Decisions...)
	out = append(out, n.OpenQuestions...)
	out = append(out, n.Numbers...)
	for _, a := range n.ActionItems {
		out = append(out, a.Who, a.What, a.When)
	}
	return out
}

// labelKey is the id Labels.label is asked for: a voice by its id while the voices show, else the far side.
func labelKey(id string, m Manifest, st SpeakerState) string {
	if id != SpeakerThem && !showsVoices(m, st) {
		return SpeakerThem
	}
	return id
}

// apply returns n with the substitutions made in every string of it.
func (c labelChanges) apply(n Notes) Notes {
	free := func(s string) string { return replaceLabels(s, c.free) }
	n.Summary = free(n.Summary)
	n.Decisions = mapStrings(n.Decisions, free)
	n.OpenQuestions = mapStrings(n.OpenQuestions, free)
	n.Numbers = mapStrings(n.Numbers, free)
	items := make([]ActionItem, len(n.ActionItems))
	for i, a := range n.ActionItems {
		if to, ok := c.exact[strings.TrimSpace(a.Who)]; ok {
			a.Who = to
		} else {
			a.Who = free(a.Who)
		}
		a.What, a.When = free(a.What), free(a.When)
		items[i] = a
	}
	n.ActionItems = items
	return n
}

func mapStrings(in []string, f func(string) string) []string {
	if in == nil {
		return nil
	}
	out := make([]string, len(in))
	for i, s := range in {
		out[i] = f(s)
	}
	return out
}

// replaceLabels replaces each key of m that stands as a whole word (not inside a longer run of letters or digits:
// "Speaker 1" is not in "Speaker 10") in one pass, the longest key first, so two names can swap.
func replaceLabels(s string, m map[string]string) string {
	if len(m) == 0 || s == "" {
		return s
	}
	keys := make([]string, 0, len(m))
	for k := range m {
		if k != "" {
			keys = append(keys, k)
		}
	}
	sort.Slice(keys, func(i, j int) bool {
		if len(keys[i]) != len(keys[j]) {
			return len(keys[i]) > len(keys[j])
		}
		return keys[i] < keys[j]
	})
	var b strings.Builder
	for i := 0; i < len(s); {
		hit := ""
		if wordEdgeBefore(s, i) {
			for _, k := range keys {
				if strings.HasPrefix(s[i:], k) && wordEdgeAfter(s, i+len(k)) {
					hit = k
					break
				}
			}
		}
		if hit != "" {
			b.WriteString(m[hit])
			i += len(hit)
			// The new name is the old one and more words ("Ivan" -> "Ivan Petrov"): where the text already has
			// them, they are the name and are not written twice.
			if ext, ok := extension(hit, m[hit]); ok {
				if n, found := matchExtension(s[i:], ext, false); found && wordEdgeAfter(s, i+n) {
					i += n
				}
			}
			continue
		}
		_, n := utf8.DecodeRuneInString(s[i:])
		b.WriteString(s[i : i+n])
		i += n
	}
	return b.String()
}

func isWordRune(r rune) bool { return unicode.IsLetter(r) || unicode.IsDigit(r) }

func wordEdgeBefore(s string, i int) bool {
	if i == 0 {
		return true
	}
	r, _ := utf8.DecodeLastRuneInString(s[:i])
	return !isWordRune(r)
}

func wordEdgeAfter(s string, i int) bool {
	if i >= len(s) {
		return true
	}
	r, _ := utf8.DecodeRuneInString(s[i:])
	return !isWordRune(r)
}

// rewriteNotes corrects a meeting's notes.json for a rename and renders notes.md again from the result. A
// meeting without notes.json (short notes, or the notes still pending) has nothing to correct. needsModel is true
// when the substitution would not be unambiguous (see labelChanges.safe and ambiguousIn): nothing was written and
// the caller queues the notes to be written again.
func rewriteNotes(dir string, shown, m Manifest, before, after SpeakerState, turns []Turn) (needsModel bool, err error) {
	raw, err := os.ReadFile(filepath.Join(dir, NotesJSON))
	if errors.Is(err, os.ErrNotExist) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	var n Notes
	if err := json.Unmarshal(raw, &n); err != nil {
		return false, err
	}
	c := changesBetween(m, before, after, turns, n.Labels)
	if c.empty() {
		return false, nil
	}
	if !c.safe() || c.ambiguousIn(n) {
		return true, nil
	}
	n = c.apply(n)
	n.Labels = c.labels
	out, err := json.MarshalIndent(n, "", " ")
	if err != nil {
		return false, err
	}
	if err := vproject.WriteAtomic(filepath.Join(dir, NotesJSON), out, 0o600); err != nil {
		return false, err
	}
	return false, vproject.WriteAtomic(filepath.Join(dir, NotesMD), []byte(NotesMarkdown(shown, n, shown.Language)), 0o600)
}

// clearNotesStale drops the "notes are to be written under these speakers" marker once they have been: when
// written (the notes just saved) holds the labels they were written under, the marker goes only if those are the
// labels now, because the speakers may have been edited while the model ran (the edit saved them and its request to
// queue the notes was refused). Notes without labels (the too-short text) depend on no speaker.
// The caller holds the meeting's speakers lock: this reads speakers.json and saves it whole.
func (r *Runner) clearNotesStale(dir string, m Manifest, written *Notes) error {
	st, err := LoadSpeakers(dir)
	if err != nil || !st.NotesStale {
		return nil // an unreadable speakers.json is dropVoiceState's business
	}
	if afterSpeakersRead != nil {
		afterSpeakersRead()
	}
	if written != nil {
		turns, err := readTurns(dir)
		if err != nil || !maps.Equal(labelMap(m, st, turns), written.Labels) {
			return nil // written under other speakers: the mark stays, a repeat of the edit queues the notes again
		}
	}
	st.NotesStale = false
	return SaveSpeakers(dir, st)
}
