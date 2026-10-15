package daemon

import (
	"regexp"
	"strings"
)

var lowPowerRe = regexp.MustCompile(`(?m)^\s*lowpowermode\s+1\s*$`)

// parsePower reads the texts of `pmset -g batt` and `pmset -g`: on battery,
// and Low Power Mode. Read-only, no host state is changed.
func parsePower(batt, all string) (onBattery, lowPower bool) {
	return strings.Contains(batt, "'Battery Power'"), lowPowerRe.MatchString(all)
}
