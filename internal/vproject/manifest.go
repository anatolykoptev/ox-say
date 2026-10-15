// Package vproject is the on-disk format of a long-form voiceover project:
// the manifest, take keys, atomic file writes. Leaf package: stdlib only.
package vproject

import "regexp"

// TakeRef is one take of a chunk as the manifest lists it. Seed is the seed
// the engine was asked for: every reader takes it from here, never from
// base seed + attempt (the sum wraps into the engine's 32-bit range).
type TakeRef struct {
	Key       string   `json:"key"`
	Seed      int64    `json:"seed"`
	Attempt   int      `json:"attempt"`
	Cfg       float64  `json:"cfg_value"`
	DurationS float64  `json:"duration_s"`
	WER       float64  `json:"wer"`
	Passed    bool     `json:"passed"`
	Reasons   []string `json:"reasons,omitempty"`
}

var keyRe = regexp.MustCompile(`^[0-9a-f]{24}$`)

// ValidKey reports a take key as the producer writes it (24 hex).
func ValidKey(k string) bool { return keyRe.MatchString(k) }
