package meeting

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
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
	free  map[string]string // whole words, in any field
	exact map[string]string // a field that is exactly the label (action item owners)
}

func (c labelChanges) empty() bool { return len(c.free) == 0 && len(c.exact) == 0 }

// changesBetween compares what two states of the speakers print for the far side's voices and for the single
// far-side label. m carries the labels; raw the turns (for the voice ids).
func changesBetween(m Manifest, before, after SpeakerState, raw []Turn) labelChanges {
	shownBefore, _ := Present(m, before, raw)
	shownAfter, _ := Present(m, after, raw)
	c := labelChanges{free: map[string]string{}, exact: map[string]string{}}
	for _, id := range append(voiceIDs(raw), SpeakerThem) {
		old, now := shownBefore.Labels.label(labelKey(id, m, before)), shownAfter.Labels.label(labelKey(id, m, after))
		if old == now || old == "" || now == "" {
			continue
		}
		c.exact[old] = now
		if id == SpeakerThem && strings.TrimSpace(before.Names[SpeakerThem]) == "" {
			continue // the generic label: exact only
		}
		c.free[old] = now
	}
	return c
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

// rewriteNotes applies c to a meeting's notes.json and renders notes.md again from the result. A meeting without
// notes.json (short notes, or the notes still pending) has nothing to correct.
func rewriteNotes(dir string, shown Manifest, c labelChanges) error {
	raw, err := os.ReadFile(filepath.Join(dir, NotesJSON))
	if errors.Is(err, os.ErrNotExist) || c.empty() {
		return nil
	}
	if err != nil {
		return err
	}
	var n Notes
	if err := json.Unmarshal(raw, &n); err != nil {
		return err
	}
	n = c.apply(n)
	out, err := json.MarshalIndent(n, "", " ")
	if err != nil {
		return err
	}
	if err := vproject.WriteAtomic(filepath.Join(dir, NotesJSON), out, 0o600); err != nil {
		return err
	}
	return vproject.WriteAtomic(filepath.Join(dir, NotesMD), []byte(NotesMarkdown(shown, n, shown.Language)), 0o600)
}
