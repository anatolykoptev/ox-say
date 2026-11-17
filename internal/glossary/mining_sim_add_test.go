package glossary

import (
	"strings"

	"github.com/anatolykoptev/ox-say/internal/wordlists"
)

// simChecker answers what the daemon's handler asks the dictionary when an agent files a pair.
var simChecker = wordlists.New()

// simAdd files a pair the way the daemon does: a single-word heard form that is not ordinary words is vetted.
func simAdd(s *Store, heard, meant, ctx string) (Pair, error) {
	p, _, err := s.AddChecked(heard, meant, ctx, len(strings.Fields(heard)) == 1 && !simChecker.Common(heard))
	return p, err
}
