package voiceclean

import (
	"reflect"
	"testing"
)

func TestMixFilterIsTheScriptsString(t *testing.T) {
	want := "[1:a]aresample=44100,apad[e];[0:a]aresample=44100[o];[o][e]amix=inputs=2:weights='0.1500 0.8500':normalize=0:duration=first[m]"
	if got := MixFilter(44100, 0.85); got != want {
		t.Fatalf("got %s", got)
	}
	if got := MixFilter(48000, 1); got != "[1:a]aresample=48000,apad[e];[0:a]aresample=48000[o];[o][e]amix=inputs=2:weights='0.0000 1.0000':normalize=0:duration=first[m]" {
		t.Errorf("wet 1: %s", got)
	}
	if got := MixFilter(48000, 0); got != "[1:a]aresample=48000,apad[e];[0:a]aresample=48000[o];[o][e]amix=inputs=2:weights='1.0000 0.0000':normalize=0:duration=first[m]" {
		t.Errorf("wet 0: %s", got)
	}
}

func TestMidMergeFilterIsTheScriptsString(t *testing.T) {
	want := "[0:a][1:a][2:a]amerge=inputs=3,pan=stereo|c0=c0+c3-c2|c1=c1+c3-c2[o]"
	if got := MidMergeFilter(); got != want {
		t.Fatalf("got %s", got)
	}
}

func TestVideoMuxByExtensionIsTheScripts(t *testing.T) {
	cases := map[string]struct {
		format string
		audio  []string
	}{
		"webm": {"webm", []string{"-c:a:0", "libopus", "-b:a:0", "160k"}},
		"mkv":  {"matroska", []string{"-c:a:0", "aac", "-b:a:0", "256k"}},
		"mp4":  {"mp4", []string{"-c:a:0", "aac", "-b:a:0", "256k"}},
		"m4v":  {"mp4", []string{"-c:a:0", "aac", "-b:a:0", "256k"}},
		"mov":  {"mov", []string{"-c:a:0", "aac", "-b:a:0", "256k"}},
	}
	for ext, want := range cases {
		f, a := videoMux(ext)
		if f != want.format || !reflect.DeepEqual(a, want.audio) {
			t.Errorf("%s: %s %v", ext, f, a)
		}
	}
}

func TestAudioMuxByExtensionIsTheScripts(t *testing.T) {
	cases := map[string][]string{
		"wav":  {"-c:a", "pcm_f32le", "-f", "wav"},
		"flac": {"-c:a", "flac", "-f", "flac"},
		"mp3":  {"-c:a", "libmp3lame", "-q:a", "0", "-f", "mp3"},
		"m4a":  {"-c:a", "aac", "-b:a", "256k", "-f", "ipod"},
		"mp4":  {"-c:a", "aac", "-b:a", "256k", "-f", "ipod"},
	}
	for ext, want := range cases {
		got, ok := audioMuxArgs(ext)
		if !ok || !reflect.DeepEqual(got, want) {
			t.Errorf("%s: %v %v", ext, got, ok)
		}
	}
	if _, ok := audioMuxArgs("ogg"); ok {
		t.Error("ogg must be refused")
	}
}
