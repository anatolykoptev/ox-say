//go:build !darwin

package daemon

import (
	"context"
	"errors"
)

// No background-priority or battery model off macOS: the producer runs at
// normal priority and never pauses for power.
func setBackground(int, bool) error { return nil }

// runPmset: there is no pmset here; the reader reports AC power.
func runPmset(context.Context, ...string) ([]byte, error) { return nil, errNoPmset }

var errNoPmset = errors.New("pmset is not available on this OS")
