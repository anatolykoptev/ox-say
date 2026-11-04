package voiceclean

import (
	"errors"
	"reflect"
	"testing"
)

func TestParseProbeTakesTheFirstAudioStreamAndIgnoresCoverArt(t *testing.T) {
	raw := `{"streams":[
	 {"index":0,"codec_type":"video","disposition":{"attached_pic":1}},
	 {"index":1,"codec_type":"data"},
	 {"index":2,"codec_type":"audio","sample_rate":"44100","channels":2,"duration":"12.5","disposition":{"attached_pic":0}},
	 {"index":3,"codec_type":"audio","sample_rate":"16000","channels":1,"duration":"99"}],
	 "format":{"duration":"13.0"}}`
	p, err := parseProbe([]byte(raw))
	if err != nil {
		t.Fatal(err)
	}
	if p.AudioIndex != 2 || p.SampleRate != 44100 || p.Channels != 2 || p.Seconds != 12.5 {
		t.Errorf("%+v", p)
	}
	if p.HasVideo {
		t.Error("cover art is not a picture")
	}
	var idx []int
	for _, s := range p.Streams {
		idx = append(idx, s.Index)
	}
	if !reflect.DeepEqual(idx, []int{0, 1, 2, 3}) {
		t.Errorf("streams %v", idx)
	}
	if !p.Streams[0].AttachedPic || p.Streams[1].Type != "data" {
		t.Errorf("stream kinds %+v", p.Streams)
	}
}

func TestParseProbeSeesARealVideoStream(t *testing.T) {
	p, err := parseProbe([]byte(`{"streams":[{"index":0,"codec_type":"video","disposition":{"attached_pic":0}},{"index":1,"codec_type":"audio","sample_rate":"48000","channels":1,"duration":"1"}]}`))
	if err != nil || !p.HasVideo {
		t.Fatalf("%+v %v", p, err)
	}
}

func TestParseProbeFallsBackToTheContainerDuration(t *testing.T) {
	p, err := parseProbe([]byte(`{"streams":[{"index":0,"codec_type":"audio","sample_rate":"48000","channels":1,"duration":"N/A"}],"format":{"duration":"7.25"}}`))
	if err != nil || p.Seconds != 7.25 {
		t.Fatalf("%+v %v", p, err)
	}
	p, _ = parseProbe([]byte(`{"streams":[{"index":0,"codec_type":"audio","sample_rate":"48000","channels":1}]}`))
	if p.Seconds != 0 {
		t.Errorf("unknown length must be 0, got %v", p.Seconds)
	}
}

func TestParseProbeRefusals(t *testing.T) {
	if _, err := parseProbe([]byte(`{"streams":[{"index":0,"codec_type":"video"}]}`)); !errors.Is(err, errNoAudio) {
		t.Errorf("no audio: %v", err)
	}
	if _, err := parseProbe([]byte(`{"streams":[]}`)); !errors.Is(err, errNoAudio) {
		t.Errorf("empty: %v", err)
	}
	if _, err := parseProbe([]byte(`{"streams":[{"index":0,"codec_type":"audio","sample_rate":"0","channels":1}]}`)); err == nil || errors.Is(err, errNoAudio) {
		t.Errorf("zero rate: %v", err)
	}
	if _, err := parseProbe([]byte(`not json`)); err == nil {
		t.Error("garbage")
	}
}

func TestErrorCodesMapToTheDocumentedStatuses(t *testing.T) {
	want := map[string]int{
		CodeInvalidRequest: 400, CodeNotFound: 404, CodeExists: 409, CodeSameFile: 409, CodeForbiddenPath: 403,
		CodeNoAudio: 422, CodeUnsupportedChannels: 422, CodeTooLong: 422, CodeDiskSpace: 507, CodeEngineFailed: 502, CodeUnavailable: 503,
	}
	for code, st := range want {
		if e := newErr(code, "x"); e.Status != st || e.Code != code {
			t.Errorf("%s: %d", code, e.Status)
		}
	}
}

func TestTailClipKeepsTheEndOnARuneBoundary(t *testing.T) {
	long := ""
	for range 400 {
		long += "ж"
	}
	got := tailClip(long, 511) // 511 is odd: the cut falls inside a two-byte rune
	if len(got) > 511 || len(got)%2 != 0 {
		t.Errorf("%d bytes", len(got))
	}
	if tailClip("  short \n", 512) != "short" {
		t.Error("short text must pass through trimmed")
	}
}

func TestParseProbeReadsAudioAndVideoStartTimes(t *testing.T) {
	p, err := parseProbe([]byte(`{"streams":[
	 {"index":0,"codec_type":"video","start_time":"0.040000","disposition":{"attached_pic":0}},
	 {"index":1,"codec_type":"audio","sample_rate":"48000","channels":1,"duration":"2","start_time":"1.477000"}]}`))
	if err != nil || p.AudioStart != 1.477 || p.VideoStart != 0.04 {
		t.Fatalf("%+v %v", p, err)
	}
	p, _ = parseProbe([]byte(`{"streams":[{"index":0,"codec_type":"audio","sample_rate":"48000","channels":1,"duration":"2","start_time":"-0.021"}]}`))
	if p.AudioStart != -0.021 {
		t.Errorf("negative start lost: %v", p.AudioStart)
	}
}
