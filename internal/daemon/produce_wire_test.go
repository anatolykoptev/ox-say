package daemon

import (
	"context"
	"testing"

	"github.com/anatolykoptev/ox-say/internal/config"
)

// The real producePorts wiring: ColdStartSlack follows the voxcpm2 supervisor's
// state, and ConfiguredLanguage is the daemon's OX_SAY_LANG as langHint reads it
// (the fake ports used by the producer tests do not reach this code).
// Mutation: produce_wire.go portFuncs.ColdStartSlack, `return f.coldStart()` ->
// `return 0` -> the not-ready case is RED. Mutation: produce_wire.go
// portFuncs.ConfiguredLanguage, `return f.configuredLang()` -> `return ""` ->
// RED.
func TestProducePortsWire(t *testing.T) {
	d, _, _ := voxFixture(t, func(c *config.Config) { c.Lang = "en" })
	ports := d.producePorts()
	if got := ports.ColdStartSlack(); got != voxStartupTimeout {
		t.Errorf("engine not started: ColdStartSlack = %s, want %s", got, voxStartupTimeout)
	}
	if _, err := d.VoxSup.EnsureReady(context.Background()); err != nil {
		t.Fatal(err)
	}
	if got := ports.ColdStartSlack(); got != 0 {
		t.Errorf("engine ready: ColdStartSlack = %s, want 0", got)
	}
	if got := ports.ConfiguredLanguage(); got != "en" {
		t.Errorf("OX_SAY_LANG=en: ConfiguredLanguage = %q, want en", got)
	}
	d.Cfg.Lang = ""
	if got := ports.ConfiguredLanguage(); got != "" {
		t.Errorf("OX_SAY_LANG unset: ConfiguredLanguage = %q, want empty", got)
	}
}
