// Package player wraps the platform audio player (afplay on macOS) so the
// daemon and CLI stay portable; tests stub Play.
package player

// Play plays an audio file with the platform player and returns when
// playback finishes (afplay semantics). Stub it in tests.
var Play = platformPlay
