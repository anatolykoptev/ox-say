package daemon

import (
	"errors"
	"net/http"
	"time"

	"github.com/anatolykoptev/ox-say/internal/meeting"
)

// handleMeetingAudio is GET /v1/meetings/{id}/audio: the meeting's two channels mixed into one mono 16 kHz WAV as
// it is read, nothing written to disk. http.ServeContent answers Range requests, which AVPlayer needs to seek, and
// HEAD. The request is a plain GET: Guard asks of every GET a loopback Host and a Sec-Fetch-Site that is not
// cross-site or same-site (crossSiteRead; http.CrossOriginProtection exempts GET, so Guard does it), and
// AVPlayer sends neither that header, a body nor a custom header.
func (d *Daemon) handleMeetingAudio(w http.ResponseWriter, r *http.Request) {
	m, err := d.Meet.Store.Load(r.PathValue("id"))
	if err != nil {
		d.writeMeetingErr(w, err)
		return
	}
	if m.Status == meeting.StatusRecording {
		writeErr(w, http.StatusConflict, "this meeting is still recording; play it when it is finished")
		return
	}
	if m.AudioDeleted {
		writeErr(w, http.StatusGone, "the audio of this meeting was deleted")
		return
	}
	dir, err := d.Meet.Store.Dir(m.ID)
	if err != nil {
		d.writeMeetingErr(w, err)
		return
	}
	mix, err := meeting.OpenMix(dir)
	if errors.Is(err, meeting.ErrNoAudio) {
		writeErr(w, http.StatusGone, "this meeting has no audio")
		return
	}
	if err != nil {
		d.writeMeetingErr(w, err)
		return
	}
	defer func() { _ = mix.Close() }()
	w.Header().Set("Content-Type", "audio/wav")
	w.Header().Set("Cache-Control", "no-store") // a call's audio is not for a cache
	http.ServeContent(w, r, "", time.Time{}, mix)
}
