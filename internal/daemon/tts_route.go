package daemon

import (
	"errors"
	"net/http"

	"github.com/anatolykoptev/ox-say/internal/voices"
)

// requestError is a caller mistake (HTTP 400).
type requestError struct{ msg string }

func (e *requestError) Error() string { return e.msg }

// unavailableError is an engine this host cannot run (HTTP 501).
type unavailableError struct{ msg string }

func (e *unavailableError) Error() string { return e.msg }

// synthStatus maps a synthesis/voice error to its HTTP status.
func synthStatus(err error) int {
	var re *requestError
	var ue *unavailableError
	var ie *voices.InputError
	switch {
	case errors.As(err, &re), errors.As(err, &ie):
		return http.StatusBadRequest
	case errors.Is(err, voices.ErrNotFound):
		return http.StatusNotFound
	case errors.As(err, &ue):
		return http.StatusNotImplemented
	default:
		return http.StatusInternalServerError
	}
}
