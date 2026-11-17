package daemon

import (
	"context"
	"errors"

	"github.com/modelcontextprotocol/go-sdk/mcp"

	"github.com/anatolykoptev/ox-say/internal/glossary"
)

// The glossary_add tool files a heard → meant pair through d.glossaryAdd, the same call POST /v1/glossary
// makes: the same dictionary verdict, validation, sighting and promotion. Nothing here settles a pair —
// approve, reject, edit and purge stay owner-only over HTTP and have no tool.

// glossaryAddDescription is load-bearing (tested): an agent decides from it whether to file and reads
// from it what the answer means.
const glossaryAddDescription = `File a heard→meant correction for a dictated message: the user's message was dictated ` +
	`by voice (OxSay) and a word in it is clearly a misrecognition of a term you are confident about — a product, ` +
	`project, person, company or code name. heard is the garbled form exactly as it appears in the message, meant ` +
	`the intended spelling, context the sentence of the message that contains the heard form. The sentence itself ` +
	`is never stored, only a hash of it. Do NOT file ordinary typos, guesses, style rewrites, translations, common ` +
	`words, or anything you are not sure the user meant. Filing only proposes a candidate: the pair applies ` +
	`automatically once it has been heard in several different sentences, and the user can review it on the ` +
	`Glossary page. The answer's result is filed (a new candidate), sighting (added to the existing pair; its ` +
	`status comes back: candidate | active | rejected), conflict (the heard form already maps to another term, ` +
	`named) or invalid (the pair was refused; reason says why).`

func (d *Daemon) registerGlossaryTools(srv *mcp.Server) {
	mcp.AddTool(srv, &mcp.Tool{Name: "glossary_add", Description: glossaryAddDescription}, d.toolGlossaryAdd)
}

type glossaryAddIn struct {
	Heard   string `json:"heard" jsonschema:"The garbled form exactly as it appears in the dictated message"`
	Meant   string `json:"meant" jsonschema:"The intended spelling of the term"`
	Context string `json:"context" jsonschema:"The sentence of the message that contains the heard form; only its hash is kept"`
}

// glossaryAddOut is the answer an agent reads. Result is filed (a new candidate), sighting (the pair already
// existed — a new sentence was counted), conflict (the heard form already maps to another term) or invalid
// (the pair was refused). Conflict and invalid are results, not errors: they are the ordinary answers of a
// filing, and a protocol error would only hide the reason. A store failure is a real error.
type glossaryAddOut struct {
	Result string `json:"result"`
	ID     string `json:"id,omitempty"`
	Status string `json:"status,omitempty"` // the pair's status after the filing: candidate | active | rejected
	Seen   int    `json:"seen,omitempty"`
	Reason string `json:"reason,omitempty"` // invalid: why it was refused; conflict: the other term
}

func (d *Daemon) toolGlossaryAdd(_ context.Context, _ *mcp.CallToolRequest, in glossaryAddIn) (*mcp.CallToolResult, glossaryAddOut, error) {
	p, created, err := d.glossaryAdd(in.Heard, in.Meant, in.Context)
	switch {
	case errors.Is(err, glossary.ErrInvalid):
		return nil, glossaryAddOut{Result: "invalid", Reason: d.glossaryMessage(err)}, nil
	case errors.Is(err, glossary.ErrConflict):
		return nil, glossaryAddOut{Result: "conflict", Reason: d.glossaryMessage(err)}, nil
	case err != nil:
		return nil, glossaryAddOut{}, errors.New("glossary filing failed: " + d.glossaryMessage(err))
	}
	result := "sighting"
	if created {
		result = "filed"
	}
	return nil, glossaryAddOut{Result: result, ID: p.ID, Status: string(p.Status), Seen: p.Seen}, nil
}
