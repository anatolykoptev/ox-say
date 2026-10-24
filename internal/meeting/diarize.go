package meeting

import (
	"encoding/json"
	"fmt"
	"math"
	"sort"
	"strings"

	"github.com/anatolykoptev/ox-say/internal/stt"
)

// The product rule for the far side's voices (design: "P0d diarization spike"; plan Task 20, Decision 7).
// The constants come from the FluidAudio spike's 44 channels (11 single-speaker, 12 long single-speaker up to
// 112 minutes, 15 two-speaker, 6 mixes; TestDecideOnTheSpikeChannels pins each): FluidAudio's biggest spurious
// cluster was 5 s, the quietest real speaker of a pair 54.7 s, of a four-person mix 78.7 s and 10 % of the speech.
const (
	// SubstantialSeconds and SubstantialShare: a cluster counts as a person only
	// when it holds at least this much speech AND this share of all diarized speech.
	// 45 s sits between the 5 s spurious cluster and the 54.7 s quiet speaker; nothing else gates a cluster.
	SubstantialSeconds = 45.0
	SubstantialShare   = 0.08
	// AutoVoices: this many substantial clusters or more label the transcript
	// "Speaker 1..N" by themselves. Exactly two keep the single far-side label and
	// offer the split.
	AutoVoices = 3
	// flipSeconds: a word shorter than this between two words of one speaker is
	// that speaker's (the spike's join.py smoothing).
	flipSeconds = 0.5
	// nearSeconds: a word with no overlapping segment takes the nearest segment
	// when it lies within this distance.
	nearSeconds = 1.0
	// DiarizationVersion is the ox-diar JSON schema this package reads.
	DiarizationVersion = 1
)

// Why a meeting has no voices (Manifest.DiarReason). The unavailable ones are found before anything runs
// (Deps.DiarizeReady, or ox-diar's own refusal); the others are what a run did.
const (
	DiarOSTooOld       = "os_too_old"      // macOS older than 15: Apple's BNNS bug can crash the Core ML models there
	DiarCPUUnsupported = "cpu_unsupported" // this CPU is not covered (set only if the Intel smoke of Task 20a failed)
	DiarEngineMissing  = "engine_missing"  // this install has no ox-diar
	DiarModelsMissing  = "models_missing"  // the models were never fetched, or the fetch was cut short
	DiarModelsUnusable = "models_unusable" // the models are all there and will not load (corrupt, or not plannable on this hardware)
	DiarEngineError    = "engine_error"    // ox-diar exited with an error
	DiarBadOutput      = "bad_output"      // ox-diar's answer could not be read
	DiarTimeout        = "timeout"         // ox-diar ran past its limit
)

// DiarUnavailableError is what Deps.Diarize returns when ox-diar itself says this Mac cannot do it, for a reason that
// trying again will not change: it exits 5 on macOS older than 15, and 3 when the models, though marked complete,
// will not load (a corrupt file, or a model Core ML cannot plan for this hardware). The meeting records
// WarnDiarUnavailable, not WarnNoDiarization, so the app offers no "Try Again" that would transcribe the call a
// second time for nothing. Detail is ox-diar's last words, for the log.
type DiarUnavailableError struct{ Reason, Detail string }

func (e *DiarUnavailableError) Error() string {
	if e.Detail == "" {
		return "meeting: diarization unavailable: " + e.Reason
	}
	return "meeting: diarization unavailable: " + e.Reason + ": " + e.Detail
}

// Voice modes of a meeting (Manifest.VoiceMode).
const (
	VoicesAuto  = "auto"  // three or more substantial voices: the transcript names them
	VoicesOffer = "offer" // exactly two: one far-side label, "split by voice" on offer
)

// Diarization is ox-diar's answer for a them.pcm (work/diarization.json): speakers are the clusters that kept a
// segment, ids 0..n-1 by descending speech; segments are the exclusive timeline.
type Diarization struct {
	Version   int            `json:"version"`
	DurationS float64        `json:"duration_s"`
	Speakers  []DiarSpeaker  `json:"speakers"`
	Segments  []DiarSegment  `json:"segments"`
	Timing    map[string]any `json:"timing_s,omitempty"`
}

// DiarSpeaker is one cluster: its id is the index ox-diar numbers segments by.
type DiarSpeaker struct {
	ID        int       `json:"id"`
	SpeechS   float64   `json:"speech_s"`
	Embedding []float32 `json:"embedding,omitempty"`
}

// DiarSegment is one exclusive span of one cluster, in seconds of the channel.
type DiarSegment struct {
	S   float64 `json:"s"`
	E   float64 `json:"e"`
	Spk int     `json:"spk"`
}

// ParseDiarization reads and validates ox-diar's JSON: a known version, every
// speaker id equal to its index, every segment inside the speaker list, with end after start, and the segments
// in order and not overlapping (the exclusive timeline Decide and AssignVoices rely on).
func ParseDiarization(raw []byte) (*Diarization, error) {
	var d Diarization
	if err := json.Unmarshal(raw, &d); err != nil {
		return nil, fmt.Errorf("meeting: diarization: %w", err)
	}
	if d.Version != DiarizationVersion {
		return nil, fmt.Errorf("meeting: diarization version %d, want %d", d.Version, DiarizationVersion)
	}
	for i, sp := range d.Speakers { // Decide and AssignVoices index by speaker id
		if sp.ID != i {
			return nil, fmt.Errorf("meeting: diarization speaker %d has id %d: ids must be dense and equal to their index", i, sp.ID)
		}
	}
	prevEnd := 0.0
	for i, s := range d.Segments { // AssignVoices binary-searches the segments by end: they must not overlap
		if s.Spk < 0 || s.Spk >= len(d.Speakers) || !(s.E > s.S) || s.S < prevEnd {
			return nil, fmt.Errorf("meeting: diarization segment %d overlaps the one before, is out of order or names no speaker", i)
		}
		prevEnd = s.E
	}
	return &d, nil
}

// Plan is the product rule applied to one diarization.
type Plan struct {
	// Mode is VoicesAuto, VoicesOffer or "" (one far-side label, nothing to offer).
	Mode string
	// Group maps a cluster id to its voice group (0..Voices-1): substantial
	// clusters are their own group, every other cluster joins the substantial one
	// whose centroid is nearest (cosine). Empty when Mode is "".
	Group map[int]int
	// Voices is the number of substantial clusters.
	Voices int
}

// Decide applies the rule: count the substantial clusters, assign the rest.
func Decide(d *Diarization) Plan {
	var total float64
	for _, s := range d.Speakers {
		total += s.SpeechS
	}
	var big []int
	for _, s := range d.Speakers {
		if total > 0 && s.SpeechS >= SubstantialSeconds && s.SpeechS/total >= SubstantialShare {
			big = append(big, s.ID)
		}
	}
	p := Plan{Voices: len(big)}
	switch {
	case len(big) >= AutoVoices:
		p.Mode = VoicesAuto
	case len(big) == 2:
		p.Mode = VoicesOffer
	default:
		return Plan{Voices: len(big)}
	}
	byID := map[int]DiarSpeaker{}
	for _, s := range d.Speakers {
		byID[s.ID] = s
	}
	p.Group = map[int]int{}
	for g, id := range big {
		p.Group[id] = g
	}
	for _, s := range d.Speakers {
		if _, ok := p.Group[s.ID]; ok {
			continue
		}
		best, bestSim := 0, math.Inf(-1)
		for g, id := range big {
			if sim := cosine(s.Embedding, byID[id].Embedding); sim > bestSim {
				best, bestSim = g, sim
			}
		}
		p.Group[s.ID] = best
	}
	return p
}

func cosine(a, b []float32) float64 {
	if len(a) == 0 || len(a) != len(b) {
		return 0
	}
	var dot, na, nb float64
	for i := range a {
		dot += float64(a[i]) * float64(b[i])
		na += float64(a[i]) * float64(a[i])
		nb += float64(b[i]) * float64(b[i])
	}
	if na == 0 || nb == 0 {
		return 0
	}
	return dot / math.Sqrt(na*nb)
}

// VoiceID is the Turn.Voice of voice number n (1-based, by first appearance).
func VoiceID(n int) string { return fmt.Sprintf("%s:%d", SpeakerThem, n) }

// AssignVoices gives each of the far side's words a voice, "them:<n>" with n
// counted from 1 in order of first appearance, or "" for a plan without voices.
//  1. the segment overlapping the word the most (segments are exclusive, so this
//     is usually the only one); a word between segments takes the nearest one
//     within nearSeconds; a word farther than that takes the previous word's
//     voice, or the next word's at the start;
//  2. a word shorter than flipSeconds between two words of one voice joins it
//     (one pass in word order, each decision seeing the earlier ones).
func AssignVoices(words []stt.Word, d *Diarization, p Plan) []string {
	out := make([]string, len(words))
	if p.Mode == "" || len(words) == 0 {
		return out
	}
	group := make([]int, len(words))
	for i, w := range words {
		group[i] = voiceOfWord(w, d, p)
	}
	for i := range group { // a word no segment explains: its neighbour's voice
		if group[i] >= 0 {
			continue
		}
		if i > 0 && group[i-1] >= 0 {
			group[i] = group[i-1]
		}
	}
	for i := len(group) - 1; i >= 0; i-- {
		if group[i] < 0 && i+1 < len(group) {
			group[i] = group[i+1]
		}
	}
	for i := 1; i+1 < len(group); i++ {
		if group[i-1] >= 0 && group[i-1] == group[i+1] && group[i] != group[i-1] && words[i].E-words[i].S < flipSeconds {
			group[i] = group[i-1]
		}
	}
	number := map[int]int{} // group -> 1-based order of first appearance
	for i, g := range group {
		if g < 0 {
			continue
		}
		if _, ok := number[g]; !ok {
			number[g] = len(number) + 1
		}
		out[i] = VoiceID(number[g])
	}
	return out
}

// voiceOfWord returns the voice group of one word, or -1.
func voiceOfWord(w stt.Word, d *Diarization, p Plan) int {
	segs := d.Segments
	i := sort.Search(len(segs), func(i int) bool { return segs[i].E > w.S })
	overlap := map[int]float64{}
	for ; i < len(segs) && segs[i].S < w.E; i++ {
		overlap[p.Group[segs[i].Spk]] += math.Min(segs[i].E, w.E) - math.Max(segs[i].S, w.S)
	}
	best, bestV := -1, 0.0
	for g, v := range overlap { // the largest overlap; a tie goes to the lower group
		if v > bestV || (v == bestV && best >= 0 && g < best) {
			best, bestV = g, v
		}
	}
	if best >= 0 {
		return best
	}
	mid := (w.S + w.E) / 2
	j := sort.Search(len(segs), func(i int) bool { return segs[i].S > mid })
	near, nearD := -1, nearSeconds
	for _, k := range []int{j - 2, j - 1, j, j + 1} {
		if k < 0 || k >= len(segs) {
			continue
		}
		dist := math.Min(math.Abs(segs[k].S-mid), math.Abs(segs[k].E-mid))
		if dist < nearD {
			near, nearD = p.Group[segs[k].Spk], dist
		}
	}
	return near
}

// SplitByVoice cuts every far-side turn where its voice changes. voice maps a
// word, by its (start, end), to its voice. The turns keep their order; "me"
// turns pass through untouched. Run it after DropEcho: that gate measures whole
// channel turns, and adjacent voice turns would double-count its overlap.
func SplitByVoice(turns []Turn, voice map[[2]float64]string) []Turn {
	out := make([]Turn, 0, len(turns))
	for _, t := range turns {
		if t.Speaker != SpeakerThem || len(t.Words) == 0 {
			out = append(out, t)
			continue
		}
		start := 0
		flush := func(end int) {
			ws := t.Words[start:end]
			text := make([]string, len(ws))
			for i, w := range ws {
				text[i] = strings.TrimSpace(w.W)
			}
			out = append(out, Turn{Speaker: SpeakerThem, Voice: voice[[2]float64{ws[0].S, ws[0].E}], S: ws[0].S, E: ws[len(ws)-1].E,
				Text: strings.Join(text, " "), Words: ws})
		}
		for i := 1; i < len(t.Words); i++ {
			if voice[[2]float64{t.Words[i].S, t.Words[i].E}] != voice[[2]float64{t.Words[start].S, t.Words[start].E}] {
				flush(i)
				start = i
			}
		}
		flush(len(t.Words))
	}
	sort.SliceStable(out, func(i, j int) bool { return out[i].S < out[j].S })
	return out
}
