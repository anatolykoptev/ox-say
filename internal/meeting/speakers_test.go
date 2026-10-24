package meeting

import (
	"errors"
	"strings"
	"testing"
)

func voiced(speaker, voice string, s, e float64, text string) Turn {
	return Turn{Speaker: speaker, Voice: voice, S: s, E: e, Text: text}
}

var groupTurns = []Turn{
	voiced(SpeakerMe, "", 0, 2, "welcome everyone"),
	voiced(SpeakerThem, "them:1", 3, 6, "thanks for having us"),
	voiced(SpeakerThem, "them:2", 7, 12, "let us start with the budget for the quarter"),
	voiced(SpeakerThem, "them:3", 13, 15, "agreed"),
	voiced(SpeakerThem, "them:1", 16, 17, "and the plan"),
}

func manifest(mode string) Manifest {
	return Manifest{Labels: Labels{Me: "Anatoly", Them: "Other", Speaker: "Speaker"}, VoiceMode: mode, Voices: 3}
}

func render(m Manifest, st SpeakerState, turns []Turn) string {
	shown, display := Present(m, st, turns)
	return TranscriptMarkdown(shown, display)
}

// Voices show as "Speaker 1..N" in order of first appearance; the owner stays Anatoly.
func TestPresentNumbersTheVoices(t *testing.T) {
	out := render(manifest(VoicesAuto), SpeakerState{}, groupTurns)
	for _, want := range []string{"**Anatoly** [0:00]", "**Speaker 1** [0:03]", "**Speaker 2** [0:07]", "**Speaker 3** [0:13]", "**Speaker 1** [0:16]"} {
		if !strings.Contains(out, want) {
			t.Errorf("missing %q in\n%s", want, out)
		}
	}
}

// A name replaces the number; a merged voice takes its target's name, its turns
// join the target's, and the numbers of the voices left close up.
// Mutation: internal/meeting/speakers.go Present, delete the line
// `t.Voice = st.resolveMerge(t.Voice)` -> RED (the merged voice keeps its own turns and label).
func TestPresentNamesAndMerges(t *testing.T) {
	st := SpeakerState{Names: map[string]string{"them:1": "Ivan"}, Merge: map[string]string{"them:3": "them:1"}}
	out := render(manifest(VoicesAuto), st, groupTurns)
	for _, want := range []string{"**Ivan** [0:03]", "**Speaker 2** [0:07]", "**Ivan** [0:13]: agreed and the plan"} {
		if !strings.Contains(out, want) {
			t.Errorf("missing %q in\n%s", want, out)
		}
	}
	if strings.Contains(out, "Speaker 3") {
		t.Errorf("a merged voice is still printed:\n%s", out)
	}
	// voice 2 folded away: voice 3 closes up to "Speaker 2"
	closed := render(manifest(VoicesAuto), SpeakerState{Merge: map[string]string{"them:2": "them:1"}}, groupTurns)
	if !strings.Contains(closed, "**Speaker 2** [0:13]") || strings.Contains(closed, "Speaker 3") {
		t.Errorf("the numbers did not close up:\n%s", closed)
	}
	_, turns := Present(manifest(VoicesAuto), SpeakerState{Merge: map[string]string{"them:2": "them:1"}}, groupTurns[1:3])
	if len(turns) != 1 || turns[0].S != 3 || turns[0].E != 12 || !strings.Contains(turns[0].Text, "thanks for having us let us start") {
		// 6 -> 7 is under joinGap: one paragraph
		t.Errorf("merged turns = %+v", turns)
	}
}

// Two voices keep the single far-side label until the user takes the split; the far side can
// be named either way.
// Mutation: internal/meeting/speakers.go showsVoices, drop `&& st.Split` -> RED (the offer splits by itself).
func TestOfferKeepsOneLabelUntilSplit(t *testing.T) {
	two := []Turn{voiced(SpeakerThem, "them:1", 1, 3, "first voice here"), voiced(SpeakerThem, "them:2", 3.5, 5, "second voice there")}
	m := manifest(VoicesOffer)
	one := render(m, SpeakerState{}, two)
	if strings.Count(one, "**Other**") != 1 || strings.Contains(one, "Speaker") {
		t.Errorf("before the split:\n%s", one)
	}
	named := render(m, SpeakerState{Names: map[string]string{SpeakerThem: "Maria"}}, two)
	if !strings.Contains(named, "**Maria** [0:01]: first voice here second voice there") {
		t.Errorf("a named far side:\n%s", named)
	}
	split := render(m, SpeakerState{Split: true}, two)
	if !strings.Contains(split, "**Speaker 1** [0:01]") || !strings.Contains(split, "**Speaker 2** [0:03]") {
		t.Errorf("after the split:\n%s", split)
	}
}

func TestEditRules(t *testing.T) {
	m := manifest(VoicesAuto)
	ok := func(e Edit) SpeakerState {
		t.Helper()
		st, err := SpeakerState{}.Apply(m, groupTurns, e)
		if err != nil {
			t.Fatalf("%+v: %v", e, err)
		}
		return st
	}
	bad := func(what string, st SpeakerState, e Edit) {
		t.Helper()
		if _, err := st.Apply(m, groupTurns, e); !errors.Is(err, ErrSpeakers) {
			t.Errorf("%s: err = %v", what, err)
		}
	}
	if st := ok(Edit{Rename: map[string]string{"them:2": "  Olga  "}}); st.Names["them:2"] != "Olga" {
		t.Errorf("names = %v", st.Names)
	}
	if st := ok(Edit{Rename: map[string]string{"them:2": "Olga"}}); len(ok(Edit{Rename: map[string]string{"them:2": ""}}).Names) != 0 || st.Names == nil {
		t.Error("an empty name must clear")
	}
	bad("unknown voice", SpeakerState{}, Edit{Rename: map[string]string{"them:9": "X"}})
	bad("control character", SpeakerState{}, Edit{Rename: map[string]string{"them:1": "A\u202eB"}})
	bad("no letter", SpeakerState{}, Edit{Rename: map[string]string{"them:1": "--"}})
	bad("too long", SpeakerState{}, Edit{Rename: map[string]string{"them:1": strings.Repeat("a", MaxNameRunes+1)}})
	bad("into itself", SpeakerState{}, Edit{Merge: map[string]string{"them:1": "them:1"}})
	bad("the owner", SpeakerState{}, Edit{Merge: map[string]string{"them:1": SpeakerMe}})
	st := ok(Edit{Merge: map[string]string{"them:3": "them:2"}})
	bad("into a merged voice", st, Edit{Merge: map[string]string{"them:1": "them:3"}})
	bad("a loop", st, Edit{Merge: map[string]string{"them:2": "them:3"}})
	// folding a voice that others were folded into carries them along; unmerge gives it back
	st = ok(Edit{Merge: map[string]string{"them:3": "them:2"}})
	if again, err := st.Apply(m, groupTurns, Edit{Merge: map[string]string{"them:2": "them:1"}}); err != nil || again.Merge["them:3"] != "them:1" {
		t.Errorf("chain: %+v %v", again, err)
	}
	if back, _ := st.Apply(m, groupTurns, Edit{Unmerge: []string{"them:3"}}); len(back.Merge) != 0 {
		t.Errorf("unmerge: %+v", back)
	}
	// the offer: no voices to rename before the split, and nothing to split in a meeting without them
	offer := manifest(VoicesOffer)
	if _, err := (SpeakerState{}).Apply(offer, groupTurns, Edit{Rename: map[string]string{"them:1": "X"}}); !errors.Is(err, ErrSpeakers) {
		t.Errorf("renaming a hidden voice: %v", err)
	}
	yes := true
	if st, err := (SpeakerState{}).Apply(offer, groupTurns, Edit{Split: &yes, Rename: map[string]string{"them:1": "X"}}); err != nil || !st.Split || st.Names["them:1"] != "X" {
		t.Errorf("split with a rename: %+v %v", st, err)
	}
	if _, err := (SpeakerState{}).Apply(manifest(""), groupTurns, Edit{Split: &yes}); !errors.Is(err, ErrSpeakers) {
		t.Errorf("split without voices: %v", err)
	}
}

func TestViewListsWhatTheTranscriptShows(t *testing.T) {
	v := View(manifest(VoicesAuto), SpeakerState{Names: map[string]string{"them:2": "Olga"}, Merge: map[string]string{"them:3": "them:1"}}, groupTurns)
	if v.Mode != VoicesAuto || len(v.Speakers) != 3 {
		t.Fatalf("view = %+v", v)
	}
	if v.Speakers[1].Label != "Olga" || v.Speakers[2].MergedTo != "them:1" || v.Speakers[0].SpeechS != 4 || !strings.HasPrefix(v.Speakers[1].Sample, "let us start") {
		t.Errorf("speakers = %+v", v.Speakers)
	}
	one := View(manifest(VoicesOffer), SpeakerState{}, groupTurns[1:3])
	if len(one.Speakers) != 1 || one.Speakers[0].ID != SpeakerThem || one.Speakers[0].Label != "Other" || one.Split {
		t.Errorf("offer view = %+v", one)
	}
}

func TestSpeakersFileRoundTrips(t *testing.T) {
	dir := t.TempDir()
	if st, err := LoadSpeakers(dir); err != nil || st.Names != nil {
		t.Fatalf("empty: %+v %v", st, err)
	}
	want := SpeakerState{Names: map[string]string{"them:1": "Ivan"}, Merge: map[string]string{"them:3": "them:1"}, Split: true}
	if err := SaveSpeakers(dir, want); err != nil {
		t.Fatal(err)
	}
	got, err := LoadSpeakers(dir)
	if err != nil || got.Names["them:1"] != "Ivan" || got.Merge["them:3"] != "them:1" || !got.Split {
		t.Fatalf("round trip: %+v %v", got, err)
	}
	if err := SaveSpeakers(dir, SpeakerState{}); err != nil {
		t.Fatal(err)
	}
	if st, _ := LoadSpeakers(dir); st.Names != nil || st.Split {
		t.Errorf("an empty state must remove the file: %+v", st)
	}
}

func TestNotesNameTheVoices(t *testing.T) {
	m, _ := Present(manifest(VoicesAuto), SpeakerState{Names: map[string]string{"them:1": "Ivan"}}, groupTurns)
	got := chunkSystem(m.Labels, "en")
	if !strings.Contains(got, `"Ivan", "Speaker 2", "Speaker 3" (the other people on the call, each a separate person)`) {
		t.Errorf("prompt = %s", got)
	}
	single := chunkSystem(Labels{Me: "A", Them: "B"}, "en")
	if !strings.Contains(single, `and "B" (everyone else on the call)`) {
		t.Errorf("single = %s", single)
	}
}
