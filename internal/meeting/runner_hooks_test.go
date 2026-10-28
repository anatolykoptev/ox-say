package meeting

import "testing"

// setAfterSpeakersRead installs the speakers-read seam for one test and removes it when the test ends.
func setAfterSpeakersRead(t *testing.T, fn func()) {
	t.Helper()
	afterSpeakersRead = fn
	t.Cleanup(func() { afterSpeakersRead = nil })
}
