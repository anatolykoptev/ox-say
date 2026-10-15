package cli

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// The README sends a non-technical reader from the Studio voice section to the
// produce guide, documents the output folder variable, and no longer promises
// a long-form command "coming".
// Mutation: README.md Studio voice "Length", restore the interim note
// ("a long-form command ... is coming") -> RED.
func TestReadmeDocumentsProduce(t *testing.T) {
	raw, err := os.ReadFile(filepath.Join("..", "..", "README.md"))
	if err != nil {
		t.Fatal(err)
	}
	readme := string(raw)
	for _, want := range []string{
		"## Long-form voiceover (`produce`)",
		"(#long-form-voiceover-produce)",
		"OX_SAY_PRODUCE_OUT_DIR",
		"[pause 0.8s]",
		"[style:",
		"--pick",
		"--allow-battery",
		"ox-say produce resume",
		"| `POST /v1/produce` |",
		"`produce_edit`",
		"Picking is final",
		"Loudness target",
		"`--no-wait` returns at once",
		"Estimates, not measured",
	} {
		if !strings.Contains(readme, want) {
			t.Errorf("README lacks %q", want)
		}
	}
	if strings.Contains(readme, "is coming") {
		t.Error("README still promises a long-form command that is coming")
	}
}
