package ruwords

import (
	"bytes"
	"compress/gzip"
	"crypto/sha256"
	"encoding/hex"
	"testing"
)

func TestCommon(t *testing.T) {
	c, err := Load()
	if err != nil {
		t.Fatal(err)
	}
	for _, w := range []string{"кролик", "кролика", "кроликам", "Кролик", "кодекс", "дозор", "дозорного", "сонет", "опус", "клод", "дом", "кролик кролика", "соннет", "кроллик"} {
		if !c.Common(w) {
			t.Errorf("%q must be an ordinary word (any inflection, any case)", w)
		}
	}
	for _, w := range []string{"оксей", "аксей", "хормози", "девин", "гитхаб", "вайлор", "дропбокс", "окс сей", "кролик оксей", "пиллоу", "хаггинг фейс", "OxSay", "krolik", "", "   ", "123"} {
		if c.Common(w) {
			t.Errorf("%q must not be an ordinary word", w)
		}
	}
}

// The vendored data is exactly the pinned dictionary: a silent swap of the word list (and its licence) shows here.
func TestDataPinned(t *testing.T) {
	for name, want := range map[string]struct {
		data []byte
		sum  string
	}{
		"ru.aff":    {aff, "38ce7d4af78e211e9bafe4bf7e3d6a2c420591136cb738ec6648f8fdf6524cd7"},
		"ru.dic.gz": {dicGz, "0182158e0bb9c9a2a928d48f3f192a5c777381a1a29a5394dcb5d70b68516c90"},
	} {
		h := sha256.Sum256(want.data)
		got := hex.EncodeToString(h[:])
		if got != want.sum {
			t.Errorf("%s sha256 = %s, want %s", name, got, want.sum)
		}
		if len(want.data) == 0 {
			t.Errorf("%s is empty", name)
		}
	}
}

func TestDictionaryContentPinned(t *testing.T) {
	zr, err := gzip.NewReader(bytes.NewReader(dicGz))
	if err != nil {
		t.Fatal(err)
	}
	var buf bytes.Buffer
	if _, err := buf.ReadFrom(zr); err != nil {
		t.Fatal(err)
	}
	h := sha256.Sum256(buf.Bytes())
	if got := hex.EncodeToString(h[:]); got != "f6047416a0204adbecf3a451b874ec8a97ee37e2cbc714466ef04d8dbcc0d6fc" {
		t.Fatalf("uncompressed dictionary sha256 = %s", got)
	}
}
