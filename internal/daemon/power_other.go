//go:build !darwin

package daemon

import "context"

// No background-priority or battery model off macOS: the producer runs at
// normal priority and never pauses for power.
func setBackground(int, bool) error { return nil }

func powerState(context.Context) (onBattery, lowPower bool) { return false, false }
