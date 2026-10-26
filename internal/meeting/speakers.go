package meeting

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"unicode"

	"github.com/anatolykoptev/ox-say/internal/vproject"
)

const (
	// DefaultSpeakerWord is the numbered label's word when the app sent none.
	DefaultSpeakerWord = "Speaker"
	// SpeakersVersion is the speakers.json schema.
	SpeakersVersion = 1
	// MaxNameRunes bounds a speaker's name; MaxEdits bounds one request.
	MaxNameRunes = 60
	MaxEdits     = 32
	// joinGap: when voices are merged or folded into one label, consecutive turns
	// of the same speaker closer than this become one paragraph.
	joinGap = 3.0
	// sampleRunes: how much of a voice's longest turn the app shows to tell the voices apart.
	sampleRunes = 120
)

// SpeakerState is speakers.json: what the user decided about the far side's
// voices. Ids are the Turn.Voice values ("them:2"); "them" names the single
// far-side label when the transcript has no voices.
type SpeakerState struct {
	Version int               `json:"version"`
	Names   map[string]string `json:"names,omitempty"` // id -> display name
	Merge   map[string]string `json:"merge,omitempty"` // id -> the id it was folded into
	Split   bool              `json:"split,omitempty"` // the "split by voice" offer was taken
	// NotesStale: the speakers were saved but the notes were not yet written (or queued) under them. It is set by
	// the edit that changes who said what, cleared when notes are written, and makes the same request again queue
	// the notes if the first attempt died between the two.
	NotesStale bool `json:"notes_stale,omitempty"`
}

// LoadSpeakers reads speakers.json; a missing file is the empty state.
func LoadSpeakers(dir string) (SpeakerState, error) {
	raw, err := os.ReadFile(filepath.Join(dir, SpeakersJSON))
	if errors.Is(err, os.ErrNotExist) {
		return SpeakerState{Version: SpeakersVersion}, nil
	}
	if err != nil {
		return SpeakerState{}, err
	}
	var st SpeakerState
	if err := json.Unmarshal(raw, &st); err != nil {
		return SpeakerState{}, fmt.Errorf("meeting: %s: %w", SpeakersJSON, err)
	}
	st.Version = SpeakersVersion
	return st, nil
}

// SaveSpeakers writes speakers.json atomically; an empty state removes the file.
func SaveSpeakers(dir string, st SpeakerState) error {
	path := filepath.Join(dir, SpeakersJSON)
	if len(st.Names) == 0 && len(st.Merge) == 0 && !st.Split && !st.NotesStale {
		if err := os.Remove(path); err != nil && !errors.Is(err, os.ErrNotExist) {
			return err
		}
		return nil
	}
	st.Version = SpeakersVersion
	raw, err := json.MarshalIndent(st, "", " ")
	if err != nil {
		return err
	}
	return vproject.WriteAtomic(path, raw, 0o600)
}

// Voices lists the voice ids of turns in order of first appearance.
func voiceIDs(turns []Turn) []string {
	var ids []string
	seen := map[string]bool{}
	for _, t := range turns {
		if t.Voice != "" && !seen[t.Voice] {
			seen[t.Voice] = true
			ids = append(ids, t.Voice)
		}
	}
	return ids
}

// resolveMerge follows st.Merge to the voice an id was folded into. A loop
// (which Edit never writes) stops at the first repeat.
func (st SpeakerState) resolveMerge(id string) string {
	seen := map[string]bool{}
	for {
		next, ok := st.Merge[id]
		if !ok || seen[id] {
			return id
		}
		seen[id] = true
		id = next
	}
}

// showsVoices reports whether the transcript shows the voices under st.
func showsVoices(m Manifest, st SpeakerState) bool {
	return m.VoiceMode == VoicesAuto || (m.VoiceMode == VoicesOffer && st.Split)
}

// Present is the transcript as the reader sees it: the manifest's labels
// completed with the speakers' names, and the turns with merged voices folded
// together. transcript.json keeps the raw turns; transcript.md, the notes'
// input and the app all go through here, so a rename never needs recognition.
func Present(m Manifest, st SpeakerState, raw []Turn) (Manifest, []Turn) {
	l := m.Labels
	names := map[string]string{}
	if showsVoices(m, st) {
		word := strings.TrimSpace(l.Speaker)
		if word == "" {
			word = DefaultSpeakerWord
		}
		ordinal := 0
		for _, id := range voiceIDs(raw) {
			if _, merged := st.Merge[id]; merged {
				continue
			}
			ordinal++
			names[id] = fmt.Sprintf("%s %d", word, ordinal)
		}
		for id := range st.Merge {
			names[id] = names[st.resolveMerge(id)]
		}
	}
	for id, n := range st.Names {
		if n = strings.TrimSpace(n); n == "" {
			continue
		}
		if _, ok := names[id]; ok || id == SpeakerThem {
			names[id] = n
		}
	}
	for id := range st.Merge { // a merged voice is named by what it was folded into
		if n, ok := st.Names[st.resolveMerge(id)]; ok && strings.TrimSpace(n) != "" {
			names[id] = strings.TrimSpace(n)
		}
	}
	l.Names = names
	m.Labels = l
	out := make([]Turn, 0, len(raw))
	folded := make([]bool, 0, len(raw)) // out[i] holds a turn whose voice was merged or folded away
	for _, t := range raw {
		t.Words = nil
		was := t.Voice
		if t.Speaker == SpeakerThem {
			if showsVoices(m, st) && t.Voice != "" {
				t.Voice = st.resolveMerge(t.Voice)
			} else {
				t.Voice = ""
			}
		}
		changed := t.Speaker == SpeakerThem && t.Voice != was
		// Only turns that voices were folded into one speaker are joined: a meeting without voices keeps its
		// turns exactly as the channels gave them.
		if n := len(out); n > 0 && (changed || folded[n-1]) && out[n-1].Speaker == t.Speaker && out[n-1].Voice == t.Voice && t.S-out[n-1].E < joinGap {
			out[n-1].E = t.E
			out[n-1].Text += " " + t.Text
			folded[n-1] = folded[n-1] || changed
			continue
		}
		out = append(out, t)
		folded = append(folded, changed)
	}
	return m, out
}

// SpeakerView is what the app shows for one voice (or the single far-side label).
type SpeakerView struct {
	ID       string  `json:"id"`                  // "them:2", or "them" for the single label
	Name     string  `json:"name,omitempty"`      // the user's name, "" until set
	Label    string  `json:"label"`               // what the transcript prints now
	SpeechS  float64 `json:"speech_s"`            // seconds of the transcript's turns
	Sample   string  `json:"sample,omitempty"`    // the start of the voice's longest turn
	MergedTo string  `json:"merged_to,omitempty"` // set when the voice was folded into another
}

// SpeakersView is the answer of GET /v1/meetings/{id}/speakers.
type SpeakersView struct {
	// Mode is VoicesAuto, VoicesOffer or "": whether the transcript has voices to
	// show, or has two to offer, or neither.
	Mode string `json:"mode"`
	// Split is true while the offered voices are shown.
	Split    bool          `json:"split"`
	Speakers []SpeakerView `json:"speakers"`
	// NotesQueued is set only on the answer to an edit: true when the notes were queued to be written again by the
	// model (a merge, an unmerge or the split, or a rename whose substitution was not safe), so they are not final
	// yet; false when they are final now (a rename corrected in place, or nothing to change). The client decides
	// from this, never from the kind of edit it sent.
	NotesQueued bool `json:"notes_queued"`
}

// View lists the far side's speakers under st: the voices when they show, else
// the single far-side label.
func View(m Manifest, st SpeakerState, raw []Turn) SpeakersView {
	shown, turns := Present(m, st, raw)
	v := SpeakersView{Mode: m.VoiceMode, Split: st.Split && m.VoiceMode == VoicesOffer}
	if showsVoices(m, st) {
		for _, id := range voiceIDs(raw) {
			sv := SpeakerView{ID: id, Name: strings.TrimSpace(st.Names[id]), Label: shown.Labels.Names[id]}
			if to, ok := st.Merge[id]; ok {
				sv.MergedTo = st.resolveMerge(to)
			}
			sv.SpeechS, sv.Sample = voiceStats(raw, id)
			v.Speakers = append(v.Speakers, sv)
		}
		return v
	}
	if m.VoiceMode == VoicesOffer || hasThem(turns) {
		sv := SpeakerView{ID: SpeakerThem, Name: strings.TrimSpace(st.Names[SpeakerThem]), Label: shown.Labels.label(SpeakerThem)}
		sv.SpeechS, sv.Sample = voiceStats(raw, "")
		v.Speakers = append(v.Speakers, sv)
	}
	return v
}

func hasThem(turns []Turn) bool {
	for _, t := range turns {
		if t.Speaker == SpeakerThem {
			return true
		}
	}
	return false
}

// voiceStats sums the speech of one voice ("" = the whole far side) and takes
// the start of its longest turn.
func voiceStats(raw []Turn, id string) (speech float64, sample string) {
	var longest float64
	for _, t := range raw {
		if t.Speaker != SpeakerThem || (id != "" && t.Voice != id) {
			continue
		}
		d := t.E - t.S
		speech += d
		if d > longest {
			longest, sample = d, t.Text
		}
	}
	if r := []rune(sample); len(r) > sampleRunes {
		sample = string(r[:sampleRunes]) + "…"
	}
	return speech, sample
}

// Edit is one request to change the speakers: names to set (an empty name
// clears it), voices to fold into another or take back, and the split offer.
type Edit struct {
	Rename  map[string]string `json:"rename,omitempty"`
	Merge   map[string]string `json:"merge,omitempty"`
	Unmerge []string          `json:"unmerge,omitempty"`
	Split   *bool             `json:"split,omitempty"`
}

// ErrSpeakers marks a request the speakers cannot take; the message is for the user.
var ErrSpeakers = errors.New("meeting: speakers")

func speakersErr(format string, a ...any) error {
	return fmt.Errorf("%w: %s", ErrSpeakers, fmt.Sprintf(format, a...))
}

// Apply returns st changed by e, or an error when e names an unknown voice, a
// voice folded into itself or into a voice that is itself folded away (so
// there are no chains and no loops), a name that is empty of letters or has
// control characters, or more than MaxEdits entries. Voices can be merged only
// where the transcript shows them (auto, or offer after the split).
func (st SpeakerState) Apply(m Manifest, raw []Turn, e Edit) (SpeakerState, error) {
	if len(e.Rename)+len(e.Merge)+len(e.Unmerge) > MaxEdits {
		return st, speakersErr("at most %d changes at once", MaxEdits)
	}
	next := SpeakerState{Version: SpeakersVersion, Split: st.Split, NotesStale: st.NotesStale, Names: map[string]string{}, Merge: map[string]string{}}
	for k, v := range st.Names {
		next.Names[k] = v
	}
	for k, v := range st.Merge {
		next.Merge[k] = v
	}
	if e.Split != nil {
		if m.VoiceMode != VoicesOffer {
			return st, speakersErr("this meeting has no voices to split")
		}
		next.Split = *e.Split
		if !next.Split {
			next.Merge = map[string]string{}
		}
	}
	known := map[string]bool{SpeakerThem: true}
	for _, id := range voiceIDs(raw) {
		known[id] = true
	}
	for id, name := range e.Rename {
		if !known[id] {
			return st, speakersErr("no speaker %q", id)
		}
		if !showsVoices(m, next) && id != SpeakerThem {
			return st, speakersErr("the voices are not shown; name the far side as %q", SpeakerThem)
		}
		name = strings.TrimSpace(name)
		if err := checkName(name); err != nil {
			return st, err
		}
		if name == "" {
			delete(next.Names, id)
		} else {
			next.Names[id] = name
		}
	}
	for _, id := range e.Unmerge {
		delete(next.Merge, id)
	}
	ids := make([]string, 0, len(e.Merge))
	for id := range e.Merge {
		ids = append(ids, id)
	}
	sort.Strings(ids)
	for _, id := range ids {
		into := e.Merge[id]
		if !showsVoices(m, next) {
			return st, speakersErr("the voices are not shown; there is nothing to merge")
		}
		if !known[id] || !known[into] || id == SpeakerThem || into == SpeakerThem {
			return st, speakersErr("cannot merge %q into %q", id, into)
		}
		if id == into || next.resolveMerge(into) == id {
			return st, speakersErr("%q cannot be merged into itself", id)
		}
		if _, gone := next.Merge[into]; gone {
			return st, speakersErr("%q is already merged into another speaker", into)
		}
		for from, to := range next.Merge { // whatever was folded into id follows it
			if to == id {
				next.Merge[from] = into
			}
		}
		next.Merge[id] = into
		delete(next.Names, id)
	}
	if len(next.Names) == 0 {
		next.Names = nil
	}
	if len(next.Merge) == 0 {
		next.Merge = nil
	}
	if err := checkDistinct(m, raw, next, e.Rename); err != nil {
		return st, err
	}
	return next, nil
}

// checkDistinct refuses a name that reads as another far-side speaker: it is compared, as the transcript will
// print it, with the label of every other voice (its default "Speaker 2" or the name given to it). Voices merged
// into one share a label on purpose and are one speaker here.
func checkDistinct(m Manifest, raw []Turn, next SpeakerState, rename map[string]string) error {
	if len(rename) == 0 {
		return nil
	}
	shown, _ := Present(m, next, raw)
	ids := []string{SpeakerThem}
	if showsVoices(m, next) {
		ids = ids[:0]
		for _, id := range voiceIDs(raw) {
			if _, merged := next.Merge[id]; !merged {
				ids = append(ids, id)
			}
		}
	}
	for id, name := range rename {
		name = strings.TrimSpace(name)
		if name == "" {
			continue
		}
		self := next.resolveMerge(id)
		for _, other := range ids {
			if other != self && strings.EqualFold(shown.Labels.label(labelKey(other, m, next)), name) {
				return speakersErr("another speaker is already called %q", name)
			}
		}
	}
	return nil
}

// isBidiControl is a bidi embedding, override or isolate (U+202A-202E, U+2066-2069): it reorders the text around it.
func isBidiControl(r rune) bool {
	return (r >= 0x202A && r <= 0x202E) || (r >= 0x2066 && r <= 0x2069)
}

// HasBidiControl reports whether s holds one; the names a caller chooses must not.
func HasBidiControl(s string) bool { return strings.IndexFunc(s, isBidiControl) >= 0 }

func checkName(name string) error {
	if len([]rune(name)) > MaxNameRunes {
		return speakersErr("a name has at most %d characters", MaxNameRunes)
	}
	for _, r := range name {
		if unicode.IsControl(r) || r == ' ' || r == ' ' || isBidiControl(r) {
			return speakersErr("a name cannot hold control characters")
		}
	}
	if name != "" && strings.IndexFunc(name, func(r rune) bool { return unicode.IsLetter(r) || unicode.IsDigit(r) }) < 0 {
		return speakersErr("a name needs a letter or a digit")
	}
	return nil
}

// VoiceNumber is n of "them:n", or 0.
func VoiceNumber(id string) int {
	rest, ok := strings.CutPrefix(id, SpeakerThem+":")
	if !ok {
		return 0
	}
	n, err := strconv.Atoi(rest)
	if err != nil || n < 1 {
		return 0
	}
	return n
}
