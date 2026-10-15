package daemon

import (
	"context"
	"os"
	"path/filepath"
	"testing"

	"github.com/anatolykoptev/ox-say/internal/testutil"
)

const (
	pmsetACBatt = "Now drawing from 'AC Power'\n -InternalBattery-0 (id=4653155)\t100%; charged; 0:00 remaining present: true\n"
	pmsetBatt   = "Now drawing from 'Battery Power'\n -InternalBattery-0 (id=4653155)\t64%; discharging; 4:12 remaining present: true\n"
	pmsetNormal = "System-wide power settings:\nCurrently in use:\n standby              1\n lowpowermode         0\n sleep                1\n"
	pmsetLow    = "System-wide power settings:\nCurrently in use:\n standby              1\n lowpowermode         1\n sleep                1\n"
)

// Mutation: power.go parsePower, drop the 'Battery Power' test -> RED.
// Mutation: power.go lowPowerRe matches "lowpowermode 0" too -> RED.
func TestParsePower(t *testing.T) {
	for _, c := range []struct {
		name, batt, all string
		onBattery, low  bool
	}{
		{"AC", pmsetACBatt, pmsetNormal, false, false},
		{"battery", pmsetBatt, pmsetNormal, true, false},
		{"AC low power", pmsetACBatt, pmsetLow, false, true},
		{"battery low power", pmsetBatt, pmsetLow, true, true},
		{"desktop, no battery line", "Now drawing from 'AC Power'\n", "", false, false},
	} {
		if b, l := parsePower(c.batt, c.all); b != c.onBattery || l != c.low {
			t.Errorf("%s: battery=%v low=%v", c.name, b, l)
		}
	}
}

// The producer works in the background and hands the engine back (D13).
// Mutation: produce.go run, delete p.ports.Background(true) -> RED.
// Mutation: delete p.ports.Background(false) -> RED.
func TestRunWorksInTheBackground(t *testing.T) {
	f := newFakePorts(t)
	p := startedProducer(t, f)
	s, err := p.create(reelInput(t))
	if err != nil {
		t.Fatal(err)
	}
	waitTerminal(t, p, s.ID)
	f.mu.Lock()
	defer f.mu.Unlock()
	if len(f.bg) != 2 || !f.bg[0] || f.bg[1] {
		t.Fatalf("Background calls %v, want [true false]", f.bg)
	}
}

// The Normalize port is the STRICT two-pass path: it fails, and leaves no
// output, on input the soft normalizeLoudness would pass through unchanged
// (#154.6). It goes through the daemon's real port, so swapping the adapter
// for the soft path turns this red.
// Mutation: produce_wire.go strictNormalize, write the input to out and return nil -> RED.
func TestNormalizePortIsStrict(t *testing.T) {
	dir := t.TempDir()
	d := newTestDaemon(t, dir, nil)
	in, out := filepath.Join(dir, "in.wav"), filepath.Join(dir, "out.wav")
	if err := os.WriteFile(in, []byte("not a wav at all"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := d.producePorts().Normalize(context.Background(), in, out, -16, 1); err == nil {
		t.Fatal("garbage input was normalised without an error")
	}
	if _, err := os.Stat(out); !os.IsNotExist(err) {
		t.Fatalf("an output exists after a failed normalisation: %v", err)
	}
	// A silent but valid WAV: the soft path returns it as is; strict refuses.
	if err := os.WriteFile(in, testutil.SilentWAV(1), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := d.producePorts().Normalize(context.Background(), in, out, -16, 1); err == nil {
		t.Fatal("a silent file was normalised without an error")
	}
	if _, err := os.Stat(out); !os.IsNotExist(err) {
		t.Fatalf("an output exists after a failed normalisation: %v", err)
	}
}
