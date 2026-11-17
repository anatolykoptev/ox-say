package daemon

import (
	"crypto/rand"
	"crypto/subtle"
	"encoding/hex"
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"
	"os"
	"path/filepath"
	"strings"

	"github.com/anatolykoptev/ox-say/internal/glossary"
	"github.com/anatolykoptev/ox-say/internal/stt"
	"github.com/anatolykoptev/ox-say/internal/vproject"
)

// OwnerTokenFile is the file under $OX_SAY_HOME holding the bearer the
// owner-only glossary routes require: 32 random bytes, hex, created once at
// mode 0600. The CLI reads it to send with the person's approval; an agent
// on the API cannot mint one — the route only compares, it never issues.
const OwnerTokenFile = "owner.token"

func (d *Daemon) initGlossary() {
	d.Glossary = glossary.NewStore(d.Cfg.Home)
	d.activePairs = d.Glossary.Active
	d.ownerToken = ownerToken(d.Cfg.Home, d.log)
	// derive the boost list once now, off the request path, so the first dictation after a start is boosted
	d.sttBoost()
}

// ownerToken loads $home/owner.token, generating it on first start. A file
// is accepted only as the daemon writes it — 64 lowercase hex chars, one
// trailing newline allowed, and a mode with no group/other bits. A valid
// token at a wider mode is tightened and kept; anything else is replaced
// atomically. A token that cannot be read or written leaves "" — the owner
// routes then deny every call: a daemon that cannot prove the owner
// answers 403, never 200.
func ownerToken(home string, log *slog.Logger) string {
	path := filepath.Join(home, OwnerTokenFile)
	if raw, err := os.ReadFile(path); err == nil {
		tok := strings.TrimSuffix(string(raw), "\n")
		if !validOwnerToken(tok) {
			log.Warn("glossary: the owner token file is not valid; a new one is generated")
			return writeOwnerToken(home, path, log)
		}
		if st, err := os.Stat(path); err != nil || st.Mode().Perm()&0o077 != 0 {
			if err := os.Chmod(path, 0o600); err != nil {
				log.Warn("glossary: the owner token mode could not be tightened; a new one is generated", slog.Any("error", err))
				return writeOwnerToken(home, path, log)
			}
		}
		return tok
	}
	return writeOwnerToken(home, path, log)
}

// validOwnerToken reports whether tok is a bearer the daemon would have
// written: exactly 64 lowercase hex characters.
func validOwnerToken(tok string) bool {
	if len(tok) != 64 {
		return false
	}
	for i := 0; i < len(tok); i++ {
		if c := tok[i]; (c < '0' || c > '9') && (c < 'a' || c > 'f') {
			return false
		}
	}
	return true
}

// writeOwnerToken stores a fresh bearer atomically at mode 0600. Any
// failure returns "": empty fails closed in ownerOK.
func writeOwnerToken(home, path string, log *slog.Logger) string {
	var b [32]byte
	if _, err := rand.Read(b[:]); err != nil {
		log.Warn("glossary: the owner token could not be generated; approve and reject stay closed", slog.Any("error", err))
		return ""
	}
	tok := hex.EncodeToString(b[:])
	if err := os.MkdirAll(home, 0o700); err != nil {
		log.Warn("glossary: the owner token could not be written; approve and reject stay closed", slog.Any("error", err))
		return ""
	}
	if err := vproject.WriteAtomic(path, []byte(tok+"\n"), 0o600); err != nil {
		log.Warn("glossary: the owner token could not be written; approve and reject stay closed", slog.Any("error", err))
		return ""
	}
	return tok
}

// glossaryRoutes registers the glossary. None is interactive: filing a pair
// must not make the voiceover producer yield. Reject keeps a tombstone so
// agents cannot file a pair back; edit and purge (a hard delete, no
// tombstone) are owner-only like approve and reject.
func (d *Daemon) glossaryRoutes(mux *http.ServeMux) {
	mux.HandleFunc("GET /v1/glossary", d.handleGlossaryList)
	mux.HandleFunc("POST /v1/glossary", d.handleGlossaryAdd)
	mux.HandleFunc("POST /v1/glossary/{id}/approve", d.handleGlossaryStatus(true))
	mux.HandleFunc("POST /v1/glossary/{id}/reject", d.handleGlossaryStatus(false))
	mux.HandleFunc("POST /v1/glossary/{id}/edit", d.handleGlossaryEdit)
	mux.HandleFunc("DELETE /v1/glossary/{id}", d.handleGlossaryPurge)
}

// glossaryMessage is a store error's text for a caller: a corrupt or unreadable
// glossary.json names its full path in the error, so the daemon home (and the
// file) is scrubbed with the producer's publicMessage; the detail is logged.
func (d *Daemon) glossaryMessage(err error) string {
	if glossaryStatus(err) == http.StatusInternalServerError {
		d.log.Warn("glossary: request failed", slog.Any("error", err))
	}
	return publicMessage(err, d.Cfg.Home)
}

func glossaryStatus(err error) int {
	switch {
	case errors.Is(err, glossary.ErrInvalid):
		return http.StatusBadRequest
	case errors.Is(err, glossary.ErrConflict):
		return http.StatusConflict
	case errors.Is(err, glossary.ErrNotFound):
		return http.StatusNotFound
	}
	return http.StatusInternalServerError
}

func (d *Daemon) handleGlossaryList(w http.ResponseWriter, r *http.Request) {
	pairs, err := d.Glossary.List()
	if err != nil {
		writeErr(w, glossaryStatus(err), d.glossaryMessage(err))
		return
	}
	if pairs == nil {
		pairs = []glossary.Pair{}
	}
	writeJSON(w, http.StatusOK, map[string]any{"pairs": pairs})
}

// glossaryAdd files a heard → meant pair for an agent: the dictionary verdict
// on the heard form, the store's validation and sighting, and the drop of the
// pair cache so the next dictation sees the new state. POST /v1/glossary and
// the glossary_add tool share it; the bool reports whether the pair is new.
func (d *Daemon) glossaryAdd(heard, meant, context string) (glossary.Pair, bool, error) {
	p, created, err := d.Glossary.AddChecked(heard, meant, context, d.heardIsVetted(heard))
	if err != nil {
		return glossary.Pair{}, false, err
	}
	d.invalidateGlossary()
	d.log.Info("glossary pair filed", slog.String("id", p.ID), slog.String("status", string(p.Status)), slog.Int("seen", p.Seen))
	return p, created, nil
}

func (d *Daemon) handleGlossaryAdd(w http.ResponseWriter, r *http.Request) {
	var in struct {
		Heard   string `json:"heard"`
		Meant   string `json:"meant"`
		Context string `json:"context"`
	}
	if err := decodeStrict(r, &in); err != nil {
		writeErr(w, http.StatusBadRequest, err.Error())
		return
	}
	p, _, err := d.glossaryAdd(in.Heard, in.Meant, in.Context)
	if err != nil {
		writeErr(w, glossaryStatus(err), d.glossaryMessage(err))
		return
	}
	writeJSON(w, http.StatusOK, p)
}

// ownerOK reports whether the request carries the owner bearer. Approve and
// reject settle a pair, and edit and purge rewrite or remove one — the owner's
// call, made at a terminal through `ox-say vocab` or in the app; an agent
// files candidates, it never settles them.
func (d *Daemon) ownerOK(r *http.Request) bool {
	tok, ok := strings.CutPrefix(r.Header.Get("Authorization"), "Bearer ")
	return ok && d.ownerToken != "" && subtle.ConstantTimeCompare([]byte(tok), []byte(d.ownerToken)) == 1
}

func (d *Daemon) handleGlossaryStatus(approve bool) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if !d.ownerOK(r) {
			writeErr(w, http.StatusForbidden, "approving or rejecting a pair is owner-only — run `ox-say vocab` at a terminal")
			return
		}
		set := d.Glossary.Reject
		if approve {
			set = d.Glossary.Approve
		}
		p, err := set(r.PathValue("id"))
		if err != nil {
			writeErr(w, glossaryStatus(err), d.glossaryMessage(err))
			return
		}
		d.invalidateGlossary()
		d.log.Info("glossary pair set", slog.String("id", p.ID), slog.String("status", string(p.Status)))
		writeJSON(w, http.StatusOK, p)
	}
}

func (d *Daemon) handleGlossaryEdit(w http.ResponseWriter, r *http.Request) {
	if !d.ownerOK(r) {
		writeErr(w, http.StatusForbidden, "editing a pair is owner-only — run `ox-say vocab edit` at a terminal")
		return
	}
	var in struct {
		Meant string `json:"meant"`
	}
	if err := decodeStrict(r, &in); err != nil {
		writeErr(w, http.StatusBadRequest, err.Error())
		return
	}
	p, err := d.Glossary.Edit(r.PathValue("id"), in.Meant)
	if err != nil {
		writeErr(w, glossaryStatus(err), d.glossaryMessage(err))
		return
	}
	d.invalidateGlossary()
	d.log.Info("glossary pair edited", slog.String("id", p.ID), slog.String("status", string(p.Status)))
	writeJSON(w, http.StatusOK, p)
}

func (d *Daemon) handleGlossaryPurge(w http.ResponseWriter, r *http.Request) {
	if !d.ownerOK(r) {
		writeErr(w, http.StatusForbidden, "deleting a pair is owner-only — run `ox-say vocab purge` at a terminal")
		return
	}
	id := r.PathValue("id")
	if err := d.Glossary.Purge(id); err != nil {
		writeErr(w, glossaryStatus(err), d.glossaryMessage(err))
		return
	}
	d.invalidateGlossary()
	d.log.Info("glossary pair purged", slog.String("id", id))
	writeJSON(w, http.StatusOK, map[string]any{"purged": id})
}

// glKey identifies one state of glossary.json: its mtime and size, or its
// absence — a stat is all an unchanged file costs the per-chunk path.
type glKey struct {
	mtime int64
	size  int64
	exist bool
}

func (d *Daemon) glossaryFileKey() glKey {
	st, err := os.Stat(filepath.Join(d.Cfg.Home, glossary.FileName))
	if err != nil {
		return glKey{}
	}
	return glKey{mtime: st.ModTime().UnixNano(), size: st.Size(), exist: true}
}

// invalidateGlossary drops the pair cache after the daemon's own write: a
// same-size rewrite under one mtime tick keeps the file's key, so the next
// glossaryPairs must reload rather than trust stat.
func (d *Daemon) invalidateGlossary() {
	d.glMu.Lock()
	d.glSet = false
	d.glMu.Unlock()
}

// glossaryPairs loads the active pairs, cached by the file's mtime+size.
// Any problem means no corrections and one Warn per distinct file state,
// never a failed recognition.
func (d *Daemon) glossaryPairs() []glossary.Pair {
	pairs, _ := d.glossaryPairsGen()
	return pairs
}

// glossaryPairsGen is glossaryPairs plus a generation that moves on every
// reload from disk — the key of whatever is derived from the pairs (the
// decoder boost list), safe against a same-size rewrite under one mtime tick.
func (d *Daemon) glossaryPairsGen() ([]glossary.Pair, uint64) {
	if d.Glossary == nil {
		return nil, 0
	}
	k := d.glossaryFileKey()
	d.glMu.Lock()
	defer d.glMu.Unlock()
	if d.glSet && k == d.glKey {
		return d.glPairs, d.glGen
	}
	pairs, err := d.activePairs()
	if err != nil {
		if k != d.glWarned {
			d.glWarned = k
			d.log.Warn("glossary: not applied", slog.Any("error", err))
		}
		pairs = nil
	}
	d.glSet, d.glKey, d.glPairs = true, k, pairs
	d.glGen++
	return pairs, d.glGen
}

// corrector loads the pairs once and returns a text fixer for one job (a
// meeting's turns, a response's lines): a pair filed mid-job waits for the next.
func (d *Daemon) corrector() func(string) string {
	pairs := d.glossaryPairs()
	return func(s string) string {
		out, _ := glossary.Apply(s, pairs)
		return out
	}
}

// correctResult applies the active pairs to a recognised result in place.
func (d *Daemon) correctResult(res *stt.Result, route string) {
	if n := glossary.ApplyResult(res, d.glossaryPairs()); n > 0 {
		d.log.Info("glossary applied", slog.String("route", route), slog.Int("replacements", n))
	}
}

// correctSessionBody applies the active pairs to a streaming session
// response: its "text" and each segment's "text". Every other field is kept;
// the "words" array is left as the recogniser gave it (the app reads only
// "text"). A pair whose words an /audio chunk boundary splits is corrected
// only in the final "text" of /finish — the per-chunk and finish "segments"
// texts are rewritten one response at a time and never stitched. The body
// passes through unchanged, byte for byte, when nothing was replaced or it
// does not parse.
func (d *Daemon) correctSessionBody(body []byte) []byte {
	pairs := d.glossaryPairs()
	if len(pairs) == 0 {
		return body
	}
	var top map[string]json.RawMessage
	if json.Unmarshal(body, &top) != nil {
		return body
	}
	n := 0
	fix := func(raw json.RawMessage) json.RawMessage {
		var s string
		if json.Unmarshal(raw, &s) != nil {
			return raw
		}
		out, k := glossary.Apply(s, pairs)
		if k == 0 {
			return raw
		}
		b, err := json.Marshal(out)
		if err != nil {
			return raw
		}
		n += k
		return b
	}
	if raw, ok := top["text"]; ok {
		top["text"] = fix(raw)
	}
	if raw, ok := top["segments"]; ok {
		var segs []map[string]json.RawMessage
		if json.Unmarshal(raw, &segs) == nil {
			for _, s := range segs {
				if t, ok := s["text"]; ok {
					s["text"] = fix(t)
				}
			}
			if b, err := json.Marshal(segs); err == nil {
				top["segments"] = b
			}
		}
	}
	if n == 0 {
		return body
	}
	out, err := json.Marshal(top)
	if err != nil {
		return body
	}
	d.log.Info("glossary applied", slog.String("route", "session"), slog.Int("replacements", n))
	return out
}
