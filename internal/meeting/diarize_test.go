package meeting

import (
	"strings"
	"testing"

	"github.com/anatolykoptev/ox-say/internal/stt"
)

// diar builds a Diarization whose clusters hold the given seconds of speech;
// each cluster's embedding is a unit vector along its own axis, so cosine
// similarity is 1 to itself and 0 to the others.
func diar(speech ...float64) *Diarization {
	d := &Diarization{Version: DiarizationVersion}
	for i, s := range speech {
		e := make([]float32, len(speech))
		e[i] = 1
		d.Speakers = append(d.Speakers, DiarSpeaker{ID: i, SpeechS: s, Embedding: e})
	}
	return d
}

// The product rule on the sizes FluidAudio v0.17.7 produced in the diarization spike (pinned configuration,
// exclusive seconds per cluster, largest first), one row per channel (read from the spike's out/A/parity0 and
// out/A2/parity0), each with the answer the channel's construction demands: a single person is never split, two
// people are offered, four are named. The truth comes from how the audio was made (a gated headset channel; the sum
// of two of them; the meeting mix), not from this rule.
//
// Two groups, as in the spike's B.5. The FIT set (32 channels: 11 single-speaker, 15 two-speaker, 6 mixes) is what
// 45 s and 8 % were looked at against: its three quietest pairs (54.7, 64.2 and 67.1 s for the second voice) are why
// the number is not 60. The HELD-OUT set (12 long single-speaker channels, 8 to 112 minutes, one of them,
// MTD009PM, a voice the fit set never heard) was not looked at before the number was chosen; it answers "no spurious
// cluster on long audio", the failure the old C++ route had, and every row is `""`. FluidAudio gave one cluster on
// all twelve, so this set says more about the engine than about the rule. Neither set holds real conference audio.
// Mutation: internal/meeting/diarize.go, change `SubstantialSeconds = 45.0` to `60.0` -> RED (the ES2004a pair
// whose second voice speaks 54.7 s reads as one person); to `100.0` -> RED (most pairs and the mixes).
func TestDecideOnTheSpikeChannels(t *testing.T) {
	type channel struct {
		name  string
		speak []float64
		mode  string
	}
	fit := []channel{
		{"one speaker EN2002a.Headset-0", []float64{228.4}, ""},
		{"one speaker EN2002a.Headset-1", []float64{259.2}, ""},
		{"one speaker EN2002a.Headset-2", []float64{516.8, 2.1}, ""},
		{"one speaker EN2002a.Headset-3", []float64{180.4}, ""},
		{"one speaker ES2004a.Headset-0", []float64{61.4}, ""},
		{"one speaker ES2004a.Headset-1", []float64{299.4}, ""},
		{"one speaker ES2004a.Headset-2", []float64{82.4}, ""},
		{"one speaker ES2004a.Headset-3", []float64{156}, ""},
		{"one speaker IS1009b.Headset-0", []float64{392.4}, ""},
		{"one speaker IS1009b.Headset-1", []float64{266.3}, ""},
		{"one speaker IS1009b.Headset-2", []float64{390.7, 4.6}, ""},
		{"two speakers EN2002a_H0H1", []float64{241.3, 239.9}, VoicesOffer},
		{"two speakers EN2002a_H0H2", []float64{531.1, 209.8, 2.1}, VoicesOffer},
		{"two speakers EN2002a_H0H3", []float64{247.5, 163.3}, VoicesOffer},
		{"two speakers EN2002a_H1H2", []float64{548.1, 232.6, 4.2}, VoicesOffer},
		{"two speakers EN2002a_H1H3", []float64{274.6, 155.6}, VoicesOffer},
		{"two speakers EN2002a_H2H3", []float64{534.5, 155.8}, VoicesOffer},
		{"two speakers ES2004a_H0H1", []float64{305.8, 54.7}, VoicesOffer},
		{"two speakers ES2004a_H0H2", []float64{79.4, 64.2}, VoicesOffer},
		{"two speakers ES2004a_H0H3", []float64{150.3, 67.1}, VoicesOffer},
		{"two speakers ES2004a_H1H2", []float64{301.8, 79.3}, VoicesOffer},
		{"two speakers ES2004a_H1H3", []float64{300.5, 155}, VoicesOffer},
		{"two speakers ES2004a_H2H3", []float64{149.2, 88.4}, VoicesOffer},
		{"two speakers IS1009b_H0H1", []float64{391.8, 269.2}, VoicesOffer},
		{"two speakers IS1009b_H0H2", []float64{398.2, 386, 4.3}, VoicesOffer},
		{"two speakers IS1009b_H1H2", []float64{396.2, 264.2}, VoicesOffer},
		{"mix EN2002a", []float64{769.6, 402, 373.4, 329.6}, VoicesAuto},
		{"mix ES2004a", []float64{350.2, 216.1, 120.3, 82.4}, VoicesAuto},
		{"mix ES2004a-opus10", []float64{346.1, 222.5, 120, 78.7}, VoicesAuto},
		{"mix ES2004a-opus24", []float64{349.5, 217.4, 120.3, 80.3}, VoicesAuto},
		{"mix IS1009b", []float64{535.5, 486.5, 442.6, 306.2}, VoicesAuto},
		{"mix rt1033", []float64{1531.4, 751.5, 677.5, 406.5}, VoicesAuto},
	}
	heldOut := []channel{
		{"long FEO072_30", []float64{993.3}, ""},
		{"long FEO072_full", []float64{1612.7}, ""},
		{"long MEE071_c_single", []float64{660}, ""},
		{"long MEE071_full", []float64{1329}, ""},
		{"long MEE073_30", []float64{917.1}, ""},
		{"long MEE073_full", []float64{1614.2}, ""},
		{"long MTD009PM_30", []float64{1582.1}, ""},
		{"long MTD009PM_full", []float64{2796.3}, ""},
		{"long LibriVox smallheer_30", []float64{1659.4}, ""},
		{"long LibriVox smallheer_full", []float64{6383.8}, ""},
		{"long LibriVox wales_30", []float64{1724.8}, ""},
		{"long LibriVox wales_full", []float64{6411.6}, ""},
	}
	for set, cases := range map[string][]channel{"fit": fit, "held out": heldOut} {
		for _, c := range cases {
			p := Decide(diar(c.speak...))
			if p.Mode != c.mode {
				t.Errorf("%s set, %s: %v seconds gave mode %q, want %q", set, c.name, c.speak, p.Mode, c.mode)
			}
		}
	}
}

// The edges of the rule, which the real channels do not reach: the spike's spurious clusters were at most 5 s and
// its quietest real speaker 54.7 s, so any number between them passes the table; these pin 45 and 8 %.
// Mutation: internal/meeting/diarize.go, change `SubstantialSeconds = 45.0` to `20.0` -> RED (the 44 s cluster
// becomes a voice); change `SubstantialShare = 0.08` to `0.02` -> RED (the 7 % cluster becomes a voice).
func TestDecideBoundaries(t *testing.T) {
	for _, c := range []struct {
		name   string
		speech []float64
		mode   string
		voices int
	}{
		{"45 s and 8 % is a person", []float64{400, 45, 100}, VoicesAuto, 3},
		{"44.9 s is not", []float64{300, 200, 44.9}, VoicesOffer, 2},
		{"a 4 s cluster beside one person", []float64{446, 4}, "", 1},
		{"a long call: 60 s is only 5 %", []float64{1000, 100, 60, 40}, VoicesOffer, 2},
		{"7 % of the speech is not a person", []float64{830, 70, 100}, VoicesOffer, 2},
		{"nobody", nil, "", 0},
	} {
		p := Decide(diar(c.speech...))
		if p.Mode != c.mode || p.Voices != c.voices {
			t.Errorf("%s: mode %q voices %d, want %q %d", c.name, p.Mode, p.Voices, c.mode, c.voices)
		}
	}
}

// A cluster too small to be a person joins the voice whose centroid is nearest.
func TestMinorClustersJoinTheNearestVoice(t *testing.T) {
	d := diar(300, 200, 150, 5)
	d.Speakers[3].Embedding = []float32{0.1, 0.9, 0, 0} // closest to cluster 1
	p := Decide(d)
	if p.Mode != VoicesAuto || p.Group[3] != p.Group[1] {
		t.Fatalf("plan = %+v", p)
	}
}

func seg(s, e float64, spk int) DiarSegment { return DiarSegment{S: s, E: e, Spk: spk} }

// Word to voice: the largest overlap, the nearest segment within a second, the
// previous word's voice beyond that, and a short word between two words of one
// voice joins them. Voices are numbered by first appearance, not by cluster id.
// Mutations in internal/meeting/diarize.go AssignVoices:
//   - delete the `flipSeconds` block -> RED (the 0.3 s word "B" stays Speaker 2)
//   - in voiceOfWord change `if dist < nearD` to `if false` -> RED (the word in the gap loses its voice)
func TestAssignVoices(t *testing.T) {
	d := diar(300, 200, 150)
	d.Segments = []DiarSegment{seg(0, 5, 2), seg(5.2, 10, 0), seg(10, 12, 2), seg(13, 15, 0), seg(30, 40, 1)}
	p := Decide(d)
	ws := []stt.Word{
		{W: "a", S: 0.5, E: 0.9},   // cluster 2: first voice to appear -> them:1
		{W: "b", S: 4.9, E: 5.4},   // overlaps 2 by 0.1 and 0 by 0.2 -> cluster 0 -> them:2
		{W: "c", S: 6.0, E: 6.4},   // cluster 0
		{W: "x", S: 10.2, E: 10.8}, // a 0.6 s word inside cluster 2's span: long enough to keep its voice
		{W: "y", S: 12.4, E: 12.8}, // 0.4 s past the end of cluster 2: the nearest, within a second
		{W: "z", S: 20, E: 20.4},   // more than a second from any segment: the previous word's voice
		{W: "q", S: 31, E: 31.5},   // cluster 1: third voice
	}
	got := AssignVoices(ws, d, p)
	want := []string{"them:1", "them:2", "them:2", "them:1", "them:2", "them:2", "them:3"}
	for i := range want {
		if got[i] != want[i] {
			t.Errorf("word %q: voice %q, want %q (all: %v)", ws[i].W, got[i], want[i], got)
		}
	}
}

func TestFlipSmoothing(t *testing.T) {
	d := diar(300, 200, 150)
	d.Segments = []DiarSegment{seg(0, 2, 0), seg(2, 2.3, 1), seg(2.3, 6, 0), seg(6, 8, 2)}
	p := Decide(d)
	ws := []stt.Word{{W: "a", S: 0.5, E: 1}, {W: "B", S: 2.0, E: 2.3}, {W: "c", S: 3, E: 3.5}, {W: "d", S: 7, E: 7.4}}
	got := AssignVoices(ws, d, p)
	if got[1] != got[0] || got[1] != got[2] {
		t.Fatalf("a 0.3 s word between two words of one voice kept its own voice: %v", got)
	}
	ws[1].E = 3.0 // 1 s long: a real change of voice stays
	d.Segments[1] = seg(2, 3, 1)
	d.Segments[2] = seg(3, 6, 0)
	if got = AssignVoices(ws, d, p); got[1] == got[0] {
		t.Fatalf("a long word was folded into its neighbours: %v", got)
	}
}

func TestAssignVoicesWithoutAPlanLabelsNothing(t *testing.T) {
	d := diar(446, 43)
	for _, v := range AssignVoices([]stt.Word{{W: "a", S: 1, E: 2}}, d, Decide(d)) {
		if v != "" {
			t.Fatalf("voice %q for a meeting with one speaker", v)
		}
	}
}

// DropEcho must see whole channel turns: SplitByVoice runs after it.
func TestSplitByVoiceKeepsTheOrderAndTheText(t *testing.T) {
	them := []stt.Word{{W: "hello", S: 1, E: 1.4}, {W: "there", S: 1.5, E: 1.9}, {W: "hi", S: 2.2, E: 2.4}, {W: "ok", S: 2.5, E: 2.8}}
	me := []stt.Word{{W: "yes", S: 4, E: 4.3}}
	turns := MergeTurns(me, them)
	if len(turns) != 2 {
		t.Fatalf("channel turns = %+v", turns)
	}
	v := map[[2]float64]string{{1, 1.4}: "them:1", {1.5, 1.9}: "them:1", {2.2, 2.4}: "them:2", {2.5, 2.8}: "them:2"}
	out := SplitByVoice(turns, v)
	if len(out) != 3 || out[0].Voice != "them:1" || out[0].Text != "hello there" || out[1].Voice != "them:2" || out[1].Text != "hi ok" || out[2].Speaker != SpeakerMe {
		t.Fatalf("split = %+v", out)
	}
	if out[0].E != 1.9 || out[1].S != 2.2 {
		t.Fatalf("turn times = %+v", out)
	}
}

func TestParseDiarizationRefusesWhatItCannotUse(t *testing.T) {
	good := `{"version":1,"duration_s":10,"speakers":[{"id":0,"speech_s":5}],"segments":[{"s":0,"e":2,"spk":0},{"s":3,"e":4,"spk":0}]}`
	if _, err := ParseDiarization([]byte(good)); err != nil {
		t.Fatal(err)
	}
	for name, bad := range map[string]string{
		"version":   strings.Replace(good, `"version":1`, `"version":2`, 1),
		"speaker":   strings.Replace(good, `"spk":0},{`, `"spk":3},{`, 1),
		"order":     strings.Replace(good, `"s":3,"e":4`, `"s":-1,"e":4`, 1),
		"empty seg": strings.Replace(good, `"e":2`, `"e":0`, 1),
		"json":      `{`,
	} {
		if _, err := ParseDiarization([]byte(bad)); err == nil {
			t.Errorf("%s: accepted", name)
		}
	}
}
