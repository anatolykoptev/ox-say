package daemon

import (
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"

	"github.com/anatolykoptev/ox-say/internal/codevocab"
	"github.com/anatolykoptev/ox-say/internal/glossary"
	"github.com/anatolykoptev/ox-say/internal/stt"
)

// codePacks is the enabled code packs from the daemon settings — the
// code_vocabulary list, normalised to the known ids in canonical order. An
// unset or unreadable setting means no packs; a name that is not a pack is
// ignored rather than failing the read.
func (d *Daemon) codePacks() []string {
	if d.Meet == nil || d.Meet.Store == nil {
		return []string{}
	}
	return codevocab.Enabled(d.Meet.Store.Settings().CodeVocabulary)
}

// packBoostPairs is the enabled packs' contribution to the decoder boost
// list: one term anchor per written form and one alias pair per safe heard
// form. Unsafe heard forms («chords», «Tokyo») never reach the wire — a wire
// alias is a deterministic rewrite on the engine side, which is what the
// unsafe flag exists to prevent.
func (d *Daemon) packBoostPairs() []glossary.Pair {
	return codevocab.BoostPairs(d.codePacks())
}

// packFixPairs is the enabled packs' contribution to the post-pass: every
// safe heard form rewrites to the written form, plus the unsafe heard forms
// that are fused-identifier spoken forms («type error» -> TypeError).
func (d *Daemon) packFixPairs() []glossary.Pair {
	return codevocab.RewritePairs(d.codePacks())
}

// probeSTTCaps is the ox-stt supervisor's Verify hook: once /health answers, read max_terms_header. An engine
// that does not report it (older than this daemon) keeps the legacy 4 KB wire — sending it the large header
// would make it refuse the header and decode with no boost at all. A failed probe is the same as no field; it
// never fails the engine start.
func (d *Daemon) probeSTTCaps(ctx context.Context, baseURL string) error {
	wide := false
	defer func() { d.sttWide.Store(wide) }()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, baseURL+"/health", nil)
	if err != nil {
		return nil
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return nil
	}
	defer func() { _ = resp.Body.Close() }()
	var h struct {
		MaxTermsHeader int `json:"max_terms_header"`
	}
	if resp.StatusCode == http.StatusOK && json.NewDecoder(io.LimitReader(resp.Body, healthBodyLimit)).Decode(&h) == nil {
		wide = h.MaxTermsHeader >= stt.MaxHeaderBytes
	}
	d.log.Info("stt boost wire", slog.Bool("wide", wide), slog.Int("max_terms_header", h.MaxTermsHeader))
	return nil
}

// healthBodyLimit bounds the /health body read; the answer is a few dozen bytes.
const healthBodyLimit = 4 << 10

// boostWireBytes is the JSON budget the current engine gets.
func (d *Daemon) boostWireBytes() int { return stt.Boost{Wide: d.sttWide.Load()}.Budget() }

// boostTermCap is the term-line cap the current engine gets.
func (d *Daemon) boostTermCap() int { return stt.Boost{Wide: d.sttWide.Load()}.TermCap() }
