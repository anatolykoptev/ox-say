package daemon

import "github.com/anatolykoptev/ox-say/internal/meeting"

// aecStatus is the /status "aec" value: the echo canceller's standing on this
// Mac — the setting's effective choice, whether the binary is here, and how
// its last run ended. ox-aec is a one-shot child, not a resident engine: it
// has no supervisor state of its own, so last carries the most recent stage
// outcome the meeting runner recorded.
type aecStatus struct {
	Setting string `json:"setting"` // the meeting_aec choice's effective value: "on" or "off"
	// Bin is "ready" when ox-aec is on this Mac and executable, "missing"
	// otherwise — the condition behind an aec_missing warning.
	Bin  string          `json:"bin"`
	Last *meeting.AECRun `json:"last,omitempty"`
}

func (d *Daemon) aecStatus() aecStatus {
	setting := meeting.AECOff
	if d.Meet.Store.Settings().AECEnabled() {
		setting = meeting.AECOn
	}
	bin := "ready"
	if !meeting.AECBinReady(d.Cfg.AECBin) {
		bin = "missing"
	}
	return aecStatus{Setting: setting, Bin: bin, Last: d.Meet.LastAEC()}
}
