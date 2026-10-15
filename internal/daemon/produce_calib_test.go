//go:build calib

package daemon

import (
	"bufio"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/anatolykoptev/ox-say/internal/pcm"
	"github.com/anatolykoptev/ox-say/internal/voices"
)

func TestCalibrateGatesOnOwnerLabels(t *testing.T) {
	dir := os.Getenv("OXSAY_CALIB_DIR")
	if dir == "" {
		t.Skip("OXSAY_CALIB_DIR not set")
	}
	f, err := os.Open(filepath.Join(dir, "labels.tsv"))
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	var good, bad, goodFail, badMiss int
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		name, label, _ := strings.Cut(sc.Text(), "\t")
		raw, err := os.ReadFile(filepath.Join(dir, name+".wav"))
		if err != nil {
			t.Fatal(err)
		}
		clip, err := pcm.Decode(raw)
		if err != nil {
			t.Fatal(err)
		}
		text, _ := os.ReadFile(filepath.Join(dir, name+".txt"))
		hj, _ := os.ReadFile(filepath.Join(dir, name+".heard.json"))
		var heard []voices.Word
		if err := json.Unmarshal(hj, &heard); err != nil {
			t.Fatal(err)
		}
		fails, _, _ := gateTake(string(text), clip, heard)
		switch label {
		case "good":
			good++
			if len(fails) > 0 {
				goodFail++
				t.Logf("false fail %s: %v", name, fails)
			}
		case "bad":
			bad++
			if len(fails) == 0 {
				badMiss++
			}
		}
	}
	t.Logf("owner-good %d, false-fail %d; owner-bad %d, missed %d", good, goodFail, bad, badMiss)
	if good < 30 || float64(goodFail)/float64(good) > 0.05 {
		t.Fatalf("false-fail rate %d/%d over 5 %%", goodFail, good)
	}
}
