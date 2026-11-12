package cli

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// The docs send a non-technical reader from the Studio voice guide to the
// produce guide, document the output folder variable, and no longer promise
// a long-form command "coming".
// Mutation: docs/studio-voice.md "Length", restore the interim note
// ("a long-form command ... is coming") -> RED.
func TestReadmeDocumentsProduce(t *testing.T) {
	read := func(name string) string {
		raw, err := os.ReadFile(filepath.Join("..", "..", "docs", name))
		if err != nil {
			t.Fatal(err)
		}
		return string(raw)
	}
	produce := read("produce.md")
	studio := read("studio-voice.md")
	for _, want := range []string{
		"# Long-form voiceover (`produce`)",
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
		if !strings.Contains(produce, want) {
			t.Errorf("docs/produce.md lacks %q", want)
		}
	}
	if !strings.Contains(studio, "(produce.md)") {
		t.Error("docs/studio-voice.md does not link to the produce guide")
	}
	if strings.Contains(studio, "is coming") || strings.Contains(produce, "is coming") {
		t.Error("the docs still promise a long-form command that is coming")
	}
}
