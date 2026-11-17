package stt

import (
	"encoding/base64"
	"encoding/json"
	"math"
	"strings"
)

// Boost is the per-request decoder boost list: the user's glossary terms in ox-stt's term-line format
// ("written<TAB>weight<TAB>spoken<TAB>spoken…", see engine/stt/boost.h) and the strength to push them with.
// It travels with every request — the daemon holds no long-lived connection to ox-stt, which can restart
// between requests — as the body of POST /sessions, the X-Ox-Terms header of POST /transcribe, or stdin of
// the CLI (--terms-stdin, never argv: argv shows in `ps`). The terms are the user's glossary text: they are
// never logged and never written to a file.
type Boost struct {
	Alpha float64  // 0 = off; ox-stt refuses anything above MaxAlpha
	Terms []string // one term line each, most important first
	// Wide is true only when the running ox-stt reported (GET /health max_terms_header) that it accepts the
	// large X-Ox-Terms header. The zero value is the legacy engine: a newer daemon must never send an oversize
	// header to an older ox-stt, which refuses it and decodes with NO boost at all — the glossary's too.
	Wide bool
}

// Wire limits, mirrored by engine/stt/terms_wire.h.
const (
	MaxAlpha       = 100
	MaxHeaderBytes = 16 << 10 // base64url of the JSON, inside the HTTP header limit (engines that report it)
	// LegacyHeaderBytes and LegacyTerms are the limits of an ox-stt that does not report max_terms_header.
	LegacyHeaderBytes = 4 << 10
	LegacyTerms       = 200
	// MaxTerms is the term-line cap of an ox-stt that reports max_terms_header (engine/stt/boost.h kMaxTerms).
	MaxTerms     = 512
	MaxBodyBytes = 16 << 10 // the largest JSON body ox-stt accepts on POST /sessions
	// MaxWireJSON is the JSON budget of BOTH delivery paths: the header's, scaled down by base64's 4/3. The
	// session body carries the same trimmed list as the header, because ox-stt caches one built graph by list
	// text and two different lists would rebuild it on every alternating request.
	MaxWireJSON = MaxHeaderBytes / 4 * 3
	// LegacyWireJSON is the same budget for an engine without the large header.
	LegacyWireJSON = LegacyHeaderBytes / 4 * 3
)

// Budget is the JSON byte budget this request may use: the large one only for an engine known to accept it.
func (b Boost) Budget() int {
	if b.Wide {
		return MaxWireJSON
	}
	return LegacyWireJSON
}

// TermCap is the most term lines this request may carry.
func (b Boost) TermCap() int {
	if b.Wide {
		return MaxTerms
	}
	return LegacyTerms
}

// Active reports whether the request should carry a list at all.
func (b Boost) Active() bool {
	return len(b.Terms) > 0 && b.Alpha > 0 && b.Alpha <= MaxAlpha && !math.IsNaN(b.Alpha)
}

// Fit is how many leading terms fit a JSON budget of maxBytes: the most recent terms win, the tail is dropped.
// All three delivery paths (session body, header, CLI stdin) send the same Fit(Budget()) prefix, so the
// resident server's one-entry graph cache and the per-call CLI see one list.
func (b Boost) Fit(maxBytes int) int {
	a, err := json.Marshal(b.Alpha)
	if err != nil {
		return 0
	}
	size := len(`{"alpha":,"terms":[]}`) + len(a)
	n := 0
	for _, t := range b.Terms {
		if n >= b.TermCap() {
			break
		}
		e, err := json.Marshal(t)
		if err != nil {
			break
		}
		add := len(e)
		if n > 0 {
			add++ // the comma
		}
		if size+add > maxBytes {
			break
		}
		size += add
		n++
	}
	return n
}

// Dropped is how many terms Fit(MaxWireJSON) leaves out of a request.
func (b Boost) Dropped() int {
	if !b.Active() {
		return 0
	}
	return len(b.Terms) - b.Fit(b.Budget())
}

// JSON encodes {"alpha":…,"terms":[…]} within maxBytes by dropping terms from the tail (the least recent
// ones) until it fits. nil when the boost is inactive or not even one term fits.
func (b Boost) JSON(maxBytes int) []byte {
	if !b.Active() {
		return nil
	}
	n := b.Fit(maxBytes)
	if n == 0 {
		return nil
	}
	out, err := json.Marshal(struct {
		Alpha float64  `json:"alpha"`
		Terms []string `json:"terms"`
	}{b.Alpha, b.Terms[:n]})
	if err != nil || len(out) > maxBytes {
		return nil
	}
	return out
}

// Header is the X-Ox-Terms value: base64url (no padding) of the JSON, at most MaxHeaderBytes long.
// "" when there is nothing to send.
func (b Boost) Header() string {
	// base64 inflates by 4/3: the JSON budget is the header budget scaled down, rounded down
	j := b.JSON(b.Budget())
	if j == nil {
		return ""
	}
	return base64.RawURLEncoding.EncodeToString(j)
}

// Stdin is what the CLI reads on --terms-stdin: one term line per line, the same Fit(MaxWireJSON) prefix the
// server paths carry.
func (b Boost) Stdin() string {
	var sb strings.Builder
	for _, t := range b.Terms[:b.Fit(b.Budget())] {
		sb.WriteString(t)
		sb.WriteByte('\n')
	}
	return sb.String()
}
