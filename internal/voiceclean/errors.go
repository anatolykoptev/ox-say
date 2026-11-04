package voiceclean

import (
	"net/http"
	"strings"
	"unicode/utf8"
)

// Stable error codes. The daemon route and the MCP tool map them to statuses and sentences; nothing matches on Msg.
const (
	CodeInvalidRequest      = "invalid_request"
	CodeNotFound            = "not_found"
	CodeExists              = "exists"
	CodeSameFile            = "same_file"
	CodeForbiddenPath       = "forbidden_path"
	CodeNoAudio             = "no_audio"
	CodeUnsupportedChannels = "unsupported_channels"
	CodeTooLong             = "too_long"
	CodeUnsupportedStreams  = "unsupported_streams"
	CodeDiskSpace           = "disk_space"
	CodeEngineFailed        = "engine_failed"
	CodeLagUnverified       = "lag_unverified"
	CodeUnavailable         = "unavailable"
)

var statusByCode = map[string]int{
	CodeInvalidRequest:      http.StatusBadRequest,
	CodeNotFound:            http.StatusNotFound,
	CodeExists:              http.StatusConflict,
	CodeSameFile:            http.StatusConflict,
	CodeForbiddenPath:       http.StatusForbidden,
	CodeNoAudio:             http.StatusUnprocessableEntity,
	CodeUnsupportedChannels: http.StatusUnprocessableEntity,
	CodeTooLong:             http.StatusUnprocessableEntity,
	CodeUnsupportedStreams:  http.StatusUnprocessableEntity,
	CodeDiskSpace:           http.StatusInsufficientStorage,
	CodeEngineFailed:        http.StatusBadGateway,
	CodeLagUnverified:       http.StatusBadGateway,
	CodeUnavailable:         http.StatusServiceUnavailable,
}

// Error is a refusal or failure of one cleanup run. Code is stable; Msg is one plain sentence for the user and never
// carries the contents of a file; Status is the HTTP status the code maps to.
type Error struct {
	Code   string
	Msg    string
	Status int
}

func (e *Error) Error() string { return e.Code + ": " + e.Msg }

func newErr(code, msg string) *Error {
	st, ok := statusByCode[code]
	if !ok {
		st = http.StatusInternalServerError
	}
	return &Error{Code: code, Msg: msg, Status: st}
}

// stderrKeep bounds the tool output an engine_failed message carries.
const stderrKeep = 512

// tailClip keeps the last n bytes of s (the end of a tool's stderr is where it says why), on a rune boundary and as
// valid UTF-8.
func tailClip(s string, n int) string {
	s = strings.ToValidUTF8(strings.TrimSpace(s), "?")
	if len(s) <= n {
		return s
	}
	s = s[len(s)-n:]
	for len(s) > 0 && !utf8.RuneStart(s[0]) {
		s = s[1:]
	}
	return s
}
