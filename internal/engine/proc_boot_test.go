package engine

import (
	"strings"
	"testing"
)

// #73: a Linux start token is boot-relative clock ticks, so two boots can
// produce the same one. The token must carry the boot identity, and stay a
// single whitespace-free pidfile field.
func TestBootScopedTokenDiffersAcrossBoots(t *testing.T) {
	a, err := bootScopedToken("0b8a3f1e-1111-4222-8333-444455556666\n", "12345")
	if err != nil {
		t.Fatal(err)
	}
	b, err := bootScopedToken("9c1d2e3f-aaaa-4bbb-8ccc-ddddeeeeffff\n", "12345")
	if err != nil {
		t.Fatal(err)
	}
	if a == b {
		t.Fatalf("same ticks on two boots gave the same token %q", a)
	}
	if strings.ContainsAny(a, " \t\n") {
		t.Fatalf("token %q is not one pidfile field", a)
	}
	if !strings.HasSuffix(a, "12345") {
		t.Fatalf("token %q lost the tick count", a)
	}
}

func TestBootScopedTokenSameBootIsStable(t *testing.T) {
	a, _ := bootScopedToken("0b8a3f1e-1111-4222-8333-444455556666\n", "77")
	b, _ := bootScopedToken("0b8a3f1e-1111-4222-8333-444455556666", "77")
	if a != b {
		t.Fatalf("trailing newline changed the token: %q vs %q", a, b)
	}
}

// An unreadable boot identity must fail the read (writePidFile then degrades
// to a bare pid and reapOrphan leaves a tokened pidfile alone) rather than
// mint a token that silently lacks it.
func TestBootScopedTokenRejectsEmptyBootID(t *testing.T) {
	for _, id := range []string{"", "\n", "  \n"} {
		if tok, err := bootScopedToken(id, "5"); err == nil {
			t.Fatalf("boot id %q accepted, token %q", id, tok)
		}
	}
	if _, err := bootScopedToken("abc", ""); err == nil {
		t.Fatal("empty tick count accepted")
	}
}
