package daemon

import (
	"fmt"
	"unicode/utf8"

	"github.com/anatolykoptev/ox-say/internal/config"
	"github.com/anatolykoptev/ox-say/internal/voices"
)

const (
	// maxStyleChars bounds a voice's default style: VoxCPM2 reads it as a
	// parenthesised prefix of the text, and a paragraph there is a prompt, not
	// a style.
	maxStyleChars = 300
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

// validateMeta checks the metadata of a voice being added.
func validateMeta(m voices.Meta) error {
	if err := validateEngine(m.Engine); err != nil {
		return err
	}
	if err := validateStyle(m.Style); err != nil {
		return err
	}
	if utf8.RuneCountInString(m.DesignedFrom) > maxDesignedFromChars {
		return &requestError{fmt.Sprintf("designed_from is longer than %d characters", maxDesignedFromChars)}
	}
	return nil
}

// checkVoxReference refuses a reference clip the VoxCPM2 encoder cannot take
// (voxMaxRefSeconds): past its window the engine answers HTTP 500. The words
// are for the person who added the voice.
func checkVoxReference(seconds float64) error {
	if seconds <= voxMaxRefSeconds {
		return nil
	}
	return &requestError{fmt.Sprintf(
		"this voice's recording is %.0f seconds long, and the studio voice engine can learn from at most %d seconds. Add the voice again from a shorter clip",
		seconds, voxMaxRefSeconds)}
}

// UpdateVoice changes a voice's preferred engine and/or default style; a nil
// argument leaves the field as it is, "" clears it. Switching a voice to
// voxcpm2 re-checks its stored recording, which may predate the limit.
// voiceMu orders it against AddVoice, repairs and RemoveVoice.
// designed_from is deliberately not updatable: it records how the voice came
// to be, and a later edit would make it a claim about audio it does not describe.
func (d *Daemon) UpdateVoice(name string, engineName, style *string) (*voices.Voice, error) {
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
	})
}

// checkStoredVoxReference applies checkVoxReference to a stored voice's clip.
func (d *Daemon) checkStoredVoxReference(name string) error {
	if _, err := d.Store.Get(name); err != nil { // validates the name, ErrNotFound for an unknown voice
		return err
	}
	secs, err := voices.WAVSeconds(d.Store.WAVPath(name))
	if err != nil {
		return fmt.Errorf("voice %s: cannot read its recording: %w", name, err)
	}
	return checkVoxReference(secs)
}
