package daemon

import (
	"context"
	"regexp"
	"strings"
)

// pmsetOutput runs `pmset <args>` and returns its text; runPmset is the host's
// reader (power_darwin.go, power_other.go). A var so a test can supply texts.
var pmsetOutput = runPmset

// powerState reads pmset (read-only): on battery, and Low Power Mode. A
// failure reads as "on AC, normal" so a broken pmset never blocks a job.
func powerState(ctx context.Context) (onBattery, lowPower bool) {
	batt, err := pmsetOutput(ctx, "-g", "batt")
	if err != nil {
		return false, false
	}
	all, _ := pmsetOutput(ctx, "-g")
	return parsePower(string(batt), string(all))
}

var lowPowerRe = regexp.MustCompile(`(?m)^\s*lowpowermode\s+1\s*$`)

// parsePower reads the texts of `pmset -g batt` and `pmset -g`: on battery,
// and Low Power Mode. Read-only, no host state is changed.
func parsePower(batt, all string) (onBattery, lowPower bool) {
	return strings.Contains(batt, "'Battery Power'"), lowPowerRe.MatchString(all)
}
