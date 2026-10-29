package vscript

import "testing"

// #143.9e: a format character (zero-width space, word joiner, BOM) or white
// space before [style: …] is skipped like it is before "(" elsewhere, so the
// style still opens the paragraph instead of failing with "only allowed at the
// start of a paragraph".
// Mutation: markup.go leadingStyle, trimLead(body[:m[0]]) back to
// strings.TrimSpace(body[:m[0]]) -> RED.
func TestLeadingStyleSkipsFormatCharacters(t *testing.T) {
	zwsp, wj, bom := string(rune(0x200b)), string(rune(0x2060)), string(rune(0xfeff))
	for _, lead := range []string{zwsp, wj, bom, " " + zwsp + " ", ""} {
		cs, err := Parse(lead+"[style: calm and warm] Hello there.", testOpts)
		if err != nil {
			t.Errorf("lead %q: %v", lead, err)
			continue
		}
		if len(cs) != 1 || cs[0].Style != "calm and warm" {
			t.Errorf("lead %q: chunks %+v, want one with Style %q", lead, cs, "calm and warm")
		}
	}
}
