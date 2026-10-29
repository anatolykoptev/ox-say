package vscript

import (
	"strings"
	"unicode"
)

// MaxStyleChars bounds a style: VoxCPM2 reads it as a parenthesised prefix
// of the text, and a paragraph there is a prompt, not a style.
const MaxStyleChars = 300

// styleDrops are parentheses and their lookalikes: the engine reads the
// first ASCII "(…)" of the text as the tag (audio.cpp session.cpp:99-117);
// the others are dropped so no style reads as a bracketed aside.
const styleDrops = "()（）﹙﹚⁽⁾₍₎"

// CleanStyle makes s one line that cannot close or reopen the engine's tag:
// brackets and every format character (unicode.Cf: zero-width, BOM, bidi
// overrides) are dropped, control characters become spaces, runs of space
// collapse. The single source for the daemon's sanitizeStyle (#143.5).
func CleanStyle(s string) string {
	var b strings.Builder
	for _, r := range s {
		switch {
		case strings.ContainsRune(styleDrops, r), unicode.Is(unicode.Cf, r):
		case unicode.IsControl(r):
			b.WriteRune(' ')
		default:
			b.WriteRune(r)
		}
	}
	return strings.Join(strings.Fields(b.String()), " ")
}

// StartsWithParen reports whether s opens with "(" once leading white space and
// format characters (zero-width spaces, BOM, bidi marks) are skipped: the engine
// would read that "(" as a style tag, and strings.TrimSpace does not see through
// a format character.
func StartsWithParen(s string) bool { return strings.HasPrefix(trimLead(s), "(") }
