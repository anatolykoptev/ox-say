package wordlists

import (
	"bytes"
	"compress/gzip"
	"crypto/sha256"
	"encoding/hex"
	"testing"
)

func TestCommonRussian(t *testing.T) {
	c := New()
	for _, w := range []string{"кролик", "кролика", "кроликам", "Кролик", "кодекс", "дозор", "дозорного", "сонет", "опус", "клод", "дом", "кролик кролика", "соннет", "кроллик", "вкратце", "пожалуйста"} {
		if !c.Common(w) {
			t.Errorf("%q must be an ordinary Russian word (any inflection, any case)", w)
		}
	}
	for _, w := range []string{"оксей", "аксей", "хормози", "девин", "гитхаб", "вайлор", "дропбокс", "окс сей", "кролик оксей", "пиллоу", "хаггинг фейс", "", "   ", "123"} {
		if c.Common(w) {
			t.Errorf("%q must not be an ordinary Russian word", w)
		}
	}
	if c.Err() != nil {
		t.Fatal(c.Err())
	}
}

// Written forms are checked too: a Latin meant that is an ordinary English word is not boosted in English speech.
// Mutation: drop the English branch in word() -> RED.
func TestCommonEnglish(t *testing.T) {
	c := New()
	for _, w := range []string{"pillow", "Pillow", "opus", "Sonnet", "haiku", "codex", "brave", "Brave", "pillows", "hugging face", "Hugging Face"} {
		if !c.Common(w) {
			t.Errorf("%q must be an ordinary English word", w)
		}
	}
	for _, w := range []string{"OxSay", "Hormozi", "GitHub", "Devin", "Claude", "vaelor", "kisol", "Glossa", "krolik", "Oxsay Hormozi", "GPT4", "node.js", "оксей Hormozi"} {
		if c.Common(w) {
			t.Errorf("%q must not be an ordinary English word", w)
		}
	}
	if c.Err() != nil {
		t.Fatal(c.Err())
	}
}

// The vendored data is exactly the pinned dictionaries: a silent swap of a word list (and its licence) shows here.
func TestDataPinned(t *testing.T) {
	for name, want := range map[string]struct {
		data []byte
		sum  string
	}{
		"ru.aff":    {ruAff, "38ce7d4af78e211e9bafe4bf7e3d6a2c420591136cb738ec6648f8fdf6524cd7"},
		"ru.dic.gz": {ruDicGz, "0182158e0bb9c9a2a928d48f3f192a5c777381a1a29a5394dcb5d70b68516c90"},
		"en.aff":    {enAff, "8ae1f19d4840d957728ad90555d5a8dff6cc5c046279c95ff0c00fc0a0136c7b"},
		"en.dic.gz": {enDicGz, "6e176d2bdd506d3309d96e8403716f7032fcb163b9a20a1547bf31f52a580ac3"},
	} {
		h := sha256.Sum256(want.data)
		if got := hex.EncodeToString(h[:]); got != want.sum {
			t.Errorf("%s sha256 = %s, want %s", name, got, want.sum)
		}
	}
	for name, want := range map[string]struct {
		gz  []byte
		sum string
	}{
		"ru.dic": {ruDicGz, "f6047416a0204adbecf3a451b874ec8a97ee37e2cbc714466ef04d8dbcc0d6fc"},
		"en.dic": {enDicGz, "f0b1a234bd178bdd01875b2a392a9647f888b8fe879f79c52aae62c2759b3647"},
	} {
		zr, err := gzip.NewReader(bytes.NewReader(want.gz))
		if err != nil {
			t.Fatal(err)
		}
		var buf bytes.Buffer
		if _, err := buf.ReadFrom(zr); err != nil {
			t.Fatal(err)
		}
		h := sha256.Sum256(buf.Bytes())
		if got := hex.EncodeToString(h[:]); got != want.sum {
			t.Errorf("uncompressed %s sha256 = %s, want %s", name, got, want.sum)
		}
	}
}
