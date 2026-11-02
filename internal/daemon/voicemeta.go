package daemon

import (
	"fmt"
	"strings"
	"unicode"
	"unicode/utf8"

	"github.com/anatolykoptev/ox-say/internal/config"
	"github.com/anatolykoptev/ox-say/internal/meeting"
	"github.com/anatolykoptev/ox-say/internal/voices"
	"github.com/anatolykoptev/ox-say/internal/vscript"
)

const (
	// maxVoiceLabelChars bounds a voice's display label (maxLabelChars is
	// the meetings speaker-label cap in this package).
	maxVoiceLabelChars = 60
	// maxStyleChars bounds a voice's default style (vscript.MaxStyleChars).
	maxStyleChars = vscript.MaxStyleChars
	// maxDesignedFromChars bounds the description a designed voice records;
	// it is a label for people and agents, never sent to the engine.
	maxDesignedFromChars = 1000
)

// validateEngine refuses an engine name the router would not recognise.
func validateEngine(name string) error {
	switch name {
	case "", config.TTSModelQwen, config.TTSModelVoxCPM2:
		return nil
	}
	return &requestError{fmt.Sprintf("engine %q: want %s or %s (or empty for the default)", name, config.TTSModelQwen, config.TTSModelVoxCPM2)}
}

func validateStyle(style string) error {
	if utf8.RuneCountInString(style) > maxStyleChars {
		return &requestError{fmt.Sprintf("style is longer than %d characters", maxStyleChars)}
	}
	return nil
}

// normalizeLabel is the only way a voice label reaches the store, from the add
// path and from UpdateVoice alike: it returns the label trimmed of surrounding
// whitespace (a newline included), so the string checked is the string stored.
// Padding is not part of the label, so the length bound applies to the trimmed
// form. A label that is blank once trimmed comes back "" (no label). What stays
// inside the trimmed label may not hold a control character (a tab or an inner
// newline), a line or paragraph separator, or a text-direction control.
func normalizeLabel(label string) (string, error) {
	label = strings.TrimSpace(label)
	if utf8.RuneCountInString(label) > maxVoiceLabelChars {
		return "", &requestError{fmt.Sprintf("label is longer than %d characters", maxVoiceLabelChars)}
	}
	if strings.IndexFunc(label, func(r rune) bool {
		return unicode.IsControl(r) || r == '\u2028' || r == '\u2029'
	}) >= 0 || meeting.HasBidiControl(label) {
		return "", &requestError{"label cannot hold control or line-break characters"}
	}
	return label, nil
}

// validateSource refuses a source other than unset, a recording made for the
// voice, or a clip picked from a file.
func validateSource(source string) error {
	switch source {
	case "", voices.SourceRecorded, voices.SourceFile:
		return nil
	}
	return &requestError{fmt.Sprintf("source %q: want %q, %q or empty", source, voices.SourceRecorded, voices.SourceFile)}
}

// normalizeMeta checks the metadata of a voice being added and returns it in
// the form to store (the label trimmed, see normalizeLabel).
func normalizeMeta(m voices.Meta) (voices.Meta, error) {
	if err := validateEngine(m.Engine); err != nil {
		return m, err
	}
	if err := validateStyle(m.Style); err != nil {
		return m, err
	}
	label, err := normalizeLabel(m.Label)
	if err != nil {
		return m, err
	}
	m.Label = label
	if err := validateSource(m.Source); err != nil {
		return m, err
	}
	if utf8.RuneCountInString(m.DesignedFrom) > maxDesignedFromChars {
		return m, &requestError{fmt.Sprintf("designed_from is longer than %d characters", maxDesignedFromChars)}
	}
	return m, nil
}

// voxRefLimit is the longest reference clip the encoder takes, in seconds. A
// test lowers d.voxRefMax because the store's own cap sits below the window, so
// no real clip could trip the add-path checks.
func (d *Daemon) voxRefLimit() float64 {
	if d.voxRefMax > 0 {
		return d.voxRefMax
	}
	return float64(voxMaxRefSeconds)
}

// checkVoxReference refuses a reference clip the VoxCPM2 encoder cannot take
// (voxMaxRefSeconds): past its window the engine answers HTTP 500. The words
// are for the person who added the voice.
func (d *Daemon) checkVoxReference(seconds float64) error {
	limit := d.voxRefLimit()
	if seconds <= limit {
		return nil
	}
	return &requestError{fmt.Sprintf(
		"this voice's recording is %.0f seconds long, and the studio voice engine can learn from at most %d seconds. Add the voice again from a shorter clip",
		seconds, int(limit))}
}

// UpdateVoice changes a voice's preferred engine, default style and/or display
// label; a nil argument leaves the field as it is, "" clears it. The label is
// stored as normalizeLabel returns it. source is not updatable either: it
// describes the audio. Switching a voice to voxcpm2 re-checks its stored
// recording, which may predate the limit.
// voiceMu orders it against AddVoice, repairs and RemoveVoice.
// designed_from is deliberately not updatable: it records how the voice came
// to be, and a later edit would make it a claim about audio it does not describe.
func (d *Daemon) UpdateVoice(name string, engineName, style, label *string) (*voices.Voice, error) {
	if engineName != nil {
		if err := validateEngine(*engineName); err != nil {
			return nil, err
		}
	}
	if style != nil {
		if err := validateStyle(*style); err != nil {
			return nil, err
		}
	}
	var newLabel string
	if label != nil {
		var err error
		if newLabel, err = normalizeLabel(*label); err != nil {
			return nil, err
		}
	}
	d.voiceMu.Lock()
	defer d.voiceMu.Unlock()
	if engineName != nil && *engineName == config.TTSModelVoxCPM2 {
		if err := d.checkStoredVoxReference(name); err != nil {
			return nil, err
		}
	}
	return d.Store.Update(name, func(v *voices.Voice) {
		if engineName != nil {
			v.Engine = *engineName
		}
		if style != nil {
			v.Style = *style
		}
		if label != nil {
			v.Label = newLabel
		}
	})
}

// checkStoredVoxReference applies checkVoxReference to a stored voice's clip.
func (d *Daemon) checkStoredVoxReference(name string) error {
	if _, err := d.Store.Get(name); err != nil { // validates the name, ErrNotFound for an unknown voice
		return err
	}
	secs, err := voices.WAVSeconds(d.Store.WAVPath(name))
	if err != nil {
		return d.voiceReadError(name, err, false)
	}
	return d.checkVoxReference(secs)
}
