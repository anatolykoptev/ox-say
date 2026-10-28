package daemon

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"log/slog"
	"math"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"

	"github.com/anatolykoptev/ox-say/internal/config"
	"github.com/anatolykoptev/ox-say/internal/voices"
)

const (
	defaultDesignTakes = 3
	maxDesignTakes     = 4
	// designSlowCharsPerSec is the slowest Russian pace measured (a sad design
	// line, ~10.7 chars/s, plan §1.6 S3), rounded down.
	designSlowCharsPerSec = 10.0
	// maxDesignText keeps a take inside the reference window (voices.MaxRefSeconds)
	// even at the slowest pace, so a saved take is never trimmed or re-transcribed.
	maxDesignText = int(voices.MaxRefSeconds * designSlowCharsPerSec)
	// The cap is on spoken duration, counted in 1/60 s so the sums stay exact.
	// Every rune costs designUnitsPerChar (6 = the Russian pace above) except the
	// scripts below, which are spoken slower per character. The CJK figures are
	// conservative published speech rates (Mandarin about 4-6 characters/s,
	// Japanese kana and Korean syllable blocks about 6-8/s), NOT measured on
	// VoxCPM2: a too-low figure only refuses a line that would have fit.
	designUnitsPerSec  = 60
	designUnitsPerChar = designUnitsPerSec / int(designSlowCharsPerSec) // 6
	designUnitsHan     = designUnitsPerSec / 4                          // 15: 4 chars/s
	designUnitsSyll    = designUnitsPerSec / 6                          // 10: 6 chars/s
	maxDesignUnits     = int(voices.MaxRefSeconds) * designUnitsPerSec
	// designToolSlack is added to the MCP design budget for the file writes.
	designToolSlack = 30 * time.Second
	// maxNameChars is the longest voice name (voices.ValidateName).
	maxNameChars = 32
	fallbackName = "voice"
	// designSubdir is where design takes live inside the cache dir. A take path
	// a client sends back is confined to it.
	designSubdir = "design"
	// takeStampLayout makes two designs of the same description in one second
	// distinct file names.
	takeStampLayout = "20060102-150405.000"
	takeExt         = ".wav"
	takeMetaExt     = ".json"
	secondsRound    = 100 // durations are reported to 10 ms
	maxDesignBody   = 1 << 20
	// designDirMode and designFileMode keep takes (a person's synthesised
	// voice, and the text spoken) private to the user.
	designDirMode  = 0o700
	designFileMode = 0o600
	// designTakeTTL is how long a take stays after it was made; a take is a
	// preview, and Save copies it into the voice store.
	designTakeTTL = 7 * 24 * time.Hour
)

// DesignInput asks VoxCPM2 for a voice from a description alone.
type DesignInput struct {
	Description string `json:"description" jsonschema:"Describe the speaker: gender, age, pitch, timbre, pace, accent or native language, mood, use (max 300 chars). Example: A clear, pleasant female narrator in her thirties, native Russian speaker, friendly and professional"`
	Text        string `json:"text" jsonschema:"1-2 sentences in the target language, 5-15 s spoken (max 200 chars, fewer for Chinese, Japanese and Korean, so a take stays under the 20 s a saved voice can keep); it is also the saved voice's transcript"`
	Takes       int    `json:"takes,omitempty" jsonschema:"How many candidate takes, 1-4 (default 3)"`
	Seed        *int64 `json:"seed,omitempty" jsonschema:"Seed of the first take; the others use the next seeds. Same seed, same take"`
}

// DesignTake is one rendered candidate.
type DesignTake struct {
	Path          string  `json:"path"`
	Seed          int64   `json:"seed"`
	DurationS     float64 `json:"duration_s"`
	SuggestedName string  `json:"suggested_name"`
	// Warning is set when the take is suspect (runaway/babble) or too long to keep.
	Warning string `json:"warning,omitempty"`
}

// DesignResult lists the takes and how to keep one.
type DesignResult struct {
	Description string       `json:"description"`
	Text        string       `json:"text"`
	Takes       []DesignTake `json:"takes"`
	SaveHint    string       `json:"save_hint"`
}

// designRecord is the daemon's own note beside each take (<take>.json). The
// saved voice's transcript, description and seed come from here, never from the
// save request, so a client cannot make a voice claim a provenance it lacks.
type designRecord struct {
	Description string `json:"description"`
	Text        string `json:"text"`
	Seed        int64  `json:"seed"`
}

// SaveDesignInput keeps one take under a voice name.
type SaveDesignInput struct {
	Name string `json:"name" jsonschema:"Voice name: ^[a-z0-9][a-z0-9_-]{0,31}$"`
	Take string `json:"take" jsonschema:"The path of a take returned by voice_design"`
	// Replace allows overwriting a voice that already has this name.
	Replace bool `json:"replace,omitempty" jsonschema:"Set true to replace an existing voice of the same name"`
}

// SaveDesignResult is the saved voice.
type SaveDesignResult struct {
	Name               string `json:"name"`
	Engine             string `json:"engine"`
	DesignedFrom       string `json:"designed_from"`
	Seed               int64  `json:"seed"`
	RegisteredToEngine bool   `json:"registered_to_engine"`
	Notice             string `json:"notice,omitempty"`
}

// designSeed draws the random seed base; a variable so a test can inject it.
var designSeed = randomSeed

func (in *DesignInput) validate(seedRange int64) error {
	switch {
	case sanitizeStyle(in.Description) == "":
		return &requestError{"description is required: say who is speaking, e.g. \"a warm young woman, smiling voice\""}
	case utf8.RuneCountInString(in.Description) > maxStyleChars:
		return &requestError{fmt.Sprintf("description is longer than %d characters", maxStyleChars)}
	case strings.TrimSpace(in.Text) == "":
		return &requestError{"text is required: one or two sentences in the voice's language"}
	case designTextTooLong(in.Text):
		return &requestError{fmt.Sprintf("text is longer than %d characters", designTextCap(in.Text))}
	case in.Takes < 0 || in.Takes > maxDesignTakes:
		return &requestError{fmt.Sprintf("takes must be 1..%d", maxDesignTakes)}
	case in.Seed != nil && (*in.Seed < 0 || *in.Seed > seedRange):
		return &requestError{fmt.Sprintf("seed must be 0..%d so every take has a valid seed", seedRange)}
	}
	return nil
}

// designTextUnits is the slowest plausible spoken length of text in 1/60 s.
func designTextUnits(text string) int {
	units := 0
	for _, r := range text {
		switch {
		case unicode.Is(unicode.Han, r):
			units += designUnitsHan
		case unicode.Is(unicode.Hiragana, r), unicode.Is(unicode.Katakana, r), unicode.Is(unicode.Hangul, r), unicode.Is(unicode.Thai, r):
			units += designUnitsSyll
		default:
			units += designUnitsPerChar
		}
	}
	return units
}

func designTextTooLong(text string) bool { return designTextUnits(text) > maxDesignUnits }

// designTextCap is how many characters of text's own script fit the window, for
// the refusal message: 200 for Russian, 80 for Chinese.
func designTextCap(text string) int {
	n, units := utf8.RuneCountInString(text), designTextUnits(text)
	if units == 0 {
		return maxDesignText
	}
	return maxDesignUnits * n / units
}

// designDir is the one directory design takes are written to and read from.
func (d *Daemon) designDir() string { return filepath.Join(d.Cfg.CacheDir, designSubdir) }

// DesignVoice renders in.Takes candidate clips of in.Text in a voice described
// by in.Description, with consecutive seeds from in.Seed (or a random base).
// No voice takes part — not even the configured default — and the description
// is the style tag, sanitised by the adapter. Takes are previews and stay at the
// engine's own level (no loudness normalisation). Keep one with SaveDesignedVoice.
func (d *Daemon) DesignVoice(ctx context.Context, in DesignInput) (*DesignResult, error) {
	// Counted from entry: the design route is not an interactive one, and
	// the MCP tool shares this method — the count lives here so /status
	// sees a design in flight however it arrived.
	d.designing.Add(1)
	defer d.designing.Add(-1)
	if d.slowDesign != nil {
		d.slowDesign()
	}
	takes := in.Takes
	if takes == 0 {
		takes = defaultDesignTakes
	}
	if err := in.validate(maxVoxSeed - int64(takes) + 1); err != nil {
		return nil, err
	}
	in.Takes = takes
	if why := d.voxUnavailable(); why != "" {
		return nil, &unavailableError{why}
	}
	if err := os.MkdirAll(d.designDir(), designDirMode); err != nil {
		return nil, d.diskError("create the takes folder", err)
	}
	// MkdirAll leaves an existing folder as it was: one made by an older
	// version is tightened too.
	if err := os.Chmod(d.designDir(), designDirMode); err != nil {
		d.log.Warn("design: cannot restrict the takes folder", slog.Any("error", err))
	}
	d.pruneOldTakes()
	base := min(designSeed(), maxVoxSeed-int64(takes)+1)
	if in.Seed != nil {
		base = *in.Seed
	}
	stamp := time.Now().Format(takeStampLayout)
	res := &DesignResult{Description: in.Description, Text: in.Text}
	for i := range takes {
		take, err := d.designTake(ctx, in, stamp, base+int64(i))
		if err != nil {
			return nil, err
		}
		take.SuggestedName = suggestVoiceName(in.Description, i+1)
		res.Takes = append(res.Takes, *take)
	}
	lines := make([]string, len(res.Takes))
	for i, t := range res.Takes {
		lines[i] = "ox-say voice save " + t.SuggestedName + " " + shellQuote(t.Path)
	}
	res.SaveHint = "keep a take with one of: " + strings.Join(lines, "  |  ") + "   (MCP: voice_design_save {name, take}; a name already in use needs --replace, or replace: true)"
	return res, nil
}

// designTake renders one take and writes it and its record.
func (d *Daemon) designTake(ctx context.Context, in DesignInput, stamp string, seed int64) (*DesignTake, error) {
	out, err := d.render(ctx, map[string]any{
		fieldModel: config.TTSModelVoxCPM2, fieldInput: in.Text, fieldInstruct: in.Description,
		fieldVoice: "default", fieldSeed: seed,
	})
	if err != nil {
		return nil, err
	}
	stem := filepath.Join(d.designDir(), fmt.Sprintf("%s-%s-%d", stamp, slugify(in.Description), seed))
	if err := writeFileMode(stem+takeExt, out.WAV, false, designFileMode); err != nil {
		return nil, d.diskError("write the take", err)
	}
	rec, err := json.Marshal(designRecord{Description: sanitizeStyle(in.Description), Text: in.Text, Seed: seed})
	if err == nil {
		err = writeFileMode(stem+takeMetaExt, rec, false, designFileMode)
	}
	if err != nil {
		if rerr := os.Remove(stem + takeExt); rerr != nil {
			d.log.Warn("design: cannot remove a take left without its record", slog.String("path", stem+takeExt), slog.Any("error", rerr))
		}
		return nil, d.diskError("write the take's record", err)
	}
	secs := math.Round(wavDuration(out.WAV)*secondsRound) / secondsRound
	if secs > voices.MaxRefSeconds {
		out.addWarning(fmt.Sprintf("this take is %.0f s, too long to keep as a voice (the limit is %.0f s): use a shorter line", secs, voices.MaxRefSeconds))
	}
	return &DesignTake{Path: stem + takeExt, Seed: seed, DurationS: secs, Warning: out.Warning}, nil
}

// pruneOldTakes removes takes (and their records) older than designTakeTTL.
// Only regular .wav and .json files are touched, so a folder the user put in
// there, or a symlink, is left alone. A failure is logged and never fails a
// design.
func (d *Daemon) pruneOldTakes() {
	entries, err := os.ReadDir(d.designDir())
	if err != nil {
		d.log.Warn("design: cannot list the takes folder", slog.Any("error", err))
		return
	}
	cutoff := time.Now().Add(-designTakeTTL)
	for _, e := range entries {
		if ext := filepath.Ext(e.Name()); !e.Type().IsRegular() || (ext != takeExt && ext != takeMetaExt) {
			continue
		}
		if info, err := e.Info(); err != nil || !info.ModTime().Before(cutoff) {
			continue
		}
		if err := os.Remove(filepath.Join(d.designDir(), e.Name())); err != nil {
			d.log.Warn("design: cannot remove an old take", slog.String("file", e.Name()), slog.Any("error", err))
		}
	}
}

// diskError logs a filesystem failure with its path and returns the same
// failure in plain words, without the path.
func (d *Daemon) diskError(what string, err error) error {
	d.log.Error("design: filesystem error", slog.String("action", what), slog.Any("error", err))
	return fmt.Errorf("could not %s: the computer refused the file write (details are in the ox-say log)", what)
}

// privateRoots are the folders the daemon owns, longest first: home, cache,
// the voice store, logs, and the user's home. A path under one of them is the
// daemon's own business; the default home sits in "Application Support", so a
// pattern that stops at whitespace would leave the tail of it in the message.
func (d *Daemon) privateRoots() []string {
	roots := []string{d.Cfg.Home, d.Cfg.CacheDir, d.Cfg.EngineLogDir, filepath.Dir(d.Store.WAVPath("x"))}
	if h, err := os.UserHomeDir(); err == nil {
		roots = append(roots, h)
	}
	var out []string
	for _, r := range roots {
		if r = filepath.Clean(r); r != "" && r != "." && r != string(filepath.Separator) {
			out = append(out, r)
		}
	}
	sort.SliceStable(out, func(i, j int) bool { return len(out[i]) > len(out[j]) })
	return out
}

// absPath matches an absolute path inside an error message that is under none
// of the known roots (a stray path from a tool). It stops at whitespace, and an
// API route ("/v1/...") is not a path.
var absPath = regexp.MustCompile(`(^|[\s"'(=])(/[^\s"'():]+)`)

func scrubStrayPath(s string) string {
	return absPath.ReplaceAllStringFunc(s, func(m string) string {
		parts := absPath.FindStringSubmatch(m)
		if strings.HasPrefix(parts[2], "/v1/") {
			return m
		}
		return parts[1] + "[path]"
	})
}

// scrubRoot replaces each occurrence of root, and the path below it (up to
// whitespace, a quote, colon or parenthesis), with "[path]"; the rest of the
// message is kept. A match must be a whole path component at both ends: root
// "/data" is not "/database" and not the tail of "/x/data".
func scrubRoot(s, root string) string {
	var b strings.Builder
	for {
		i := strings.Index(s, root)
		if i < 0 {
			b.WriteString(s)
			return b.String()
		}
		end := i + len(root)
		// A segment character before the match means the root is the tail of a
		// longer name; a "/" before it is an empty segment ("file:///Users").
		boundedBefore := i == 0 || !isPathSegmentRune(lastRune(s[:i]))
		boundedAfter := end >= len(s) || s[end] == '/' || pathStopsAt(s, end)
		if !boundedBefore || !boundedAfter {
			b.WriteString(s[:end])
			s = s[end:]
			continue
		}
		b.WriteString(s[:i])
		b.WriteString("[path]")
		rest := s[end:]
		if strings.HasPrefix(rest, "/") {
			j := 1
			for j < len(rest) && !tailStopsAt(rest, j) {
				_, size := utf8.DecodeRuneInString(rest[j:])
				j += size
			}
			rest = rest[j:]
		}
		s = rest
	}
}

func lastRune(s string) rune {
	r, _ := utf8.DecodeLastRuneInString(s)
	return r
}

// isPathSegmentRune is a character that can be part of a path component in a
// message: letters, digits and a few joiners. Everything else (space, quotes,
// brackets, commas, semicolons, backslash, "/", "=", ":", backtick, "<>") ends
// or precedes a path.
func isPathSegmentRune(r rune) bool {
	return unicode.IsLetter(r) || unicode.IsDigit(r) || strings.ContainsRune("_-.~+@%", r)
}

// pathStopsAt reports whether a path running through s[i-1] stops before
// s[i]: at the end of the text or before a character that cannot be in a
// segment ("/" continues the path). A "." stops it only as a sentence period
// (nothing segment-like after it), so "/data.bak" is not "/data".
func pathStopsAt(s string, i int) bool {
	if i >= len(s) {
		return true
	}
	r, size := utf8.DecodeRuneInString(s[i:])
	if r == '/' {
		return false
	}
	if r == '.' {
		if i+size >= len(s) {
			return true
		}
		n := firstRune(s[i+size:])
		return n != '/' && !isPathSegmentRune(n)
	}
	return !isPathSegmentRune(r)
}

// tailStopsAt reports whether the file-name tail after a root stops before
// rest[i]. A file name may hold nearly any character (# & ! $ { } \\ , ;), so the
// tail ends only where a message ends a path: white space, or a quote, "(" ")"
// ":", a closing bracket, backtick or tag edge that is NOT glued to a letter or
// digit (a delimiter followed at once by more name, as in "a]b.wav" or
// "a(1).wav", is part of the name), and sentence punctuation (. , ; ! ?) that is
// followed by a delimiter or by the end of the text. White space always ends
// the tail: it is how a message goes on after a path.
func tailStopsAt(rest string, i int) bool {
	if i >= len(rest) {
		return true
	}
	r, size := utf8.DecodeRuneInString(rest[i:])
	if tailDelimiter(r) {
		if unicode.IsSpace(r) || i+size >= len(rest) {
			return true
		}
		return !continuesName(rest[i+size:])
	}
	if strings.ContainsRune(".,;!?", r) {
		if i+size >= len(rest) {
			return true
		}
		n, _ := utf8.DecodeRuneInString(rest[i+size:])
		return tailDelimiter(n)
	}
	return false
}

// continuesName reports whether s goes on as part of a file name: a letter,
// digit or "_", or a "." with one of those after it (an extension).
func continuesName(s string) bool {
	n, size := utf8.DecodeRuneInString(s)
	if n == '.' {
		n, _ = utf8.DecodeRuneInString(s[size:])
	}
	return unicode.IsLetter(n) || unicode.IsDigit(n) || n == '_'
}

func tailDelimiter(r rune) bool {
	return unicode.IsSpace(r) || strings.ContainsRune("\"'():]`><", r)
}

func firstRune(s string) rune {
	r, _ := utf8.DecodeRuneInString(s)
	return r
}

// publicError is err as the caller of the design routes and tools may see it:
// the daemon's own folders (and what follows them, spaces included, up to a
// quote, colon or parenthesis) and any other absolute path replaced by
// "[path]", the original in the log. Statuses are unaffected (synthStatus reads
// the typed error, so the wrapped one is kept).
func (d *Daemon) publicError(err error) error {
	if err == nil {
		return nil
	}
	clean := err.Error()
	for _, root := range d.privateRoots() {
		clean = scrubRoot(clean, root)
	}
	clean = scrubStrayPath(clean)
	if clean == err.Error() {
		return err
	}
	d.log.Warn("design: error with a path withheld from the caller", slog.Any("error", err))
	return &scrubbedError{msg: clean, err: err}
}

// scrubbedError carries the caller-safe message and keeps the original for
// errors.As/Is (status mapping).
type scrubbedError struct {
	msg string
	err error
}

func (e *scrubbedError) Error() string { return e.msg }
func (e *scrubbedError) Unwrap() error { return e.err }

// suggestVoiceName turns a description into a valid voice name ending in -n:
// Latin transliteration of the first words, ASCII letters and digits only.
func suggestVoiceName(desc string, n int) string {
	suffix := "-" + strconv.Itoa(n)
	var words []string
	for _, w := range strings.Fields(strings.ToLower(translit.Replace(desc))) {
		if w = strings.Map(asciiAlnum, w); w != "" {
			words = append(words, w)
		}
	}
	name := ""
	for _, w := range words {
		next := w
		if name != "" {
			next = name + "-" + w
		}
		if len(next)+len(suffix) > maxNameChars {
			break
		}
		name = next
	}
	if name == "" {
		name = fallbackName
	}
	return name + suffix
}

func asciiAlnum(r rune) rune {
	if r >= 'a' && r <= 'z' || r >= '0' && r <= '9' {
		return r
	}
	return -1
}

// translit is the plain Russian-to-Latin map used for suggested voice names.
var translit = strings.NewReplacer(
	"а", "a", "б", "b", "в", "v", "г", "g", "д", "d", "е", "e", "ё", "e", "ж", "zh", "з", "z", "и", "i", "й", "y",
	"к", "k", "л", "l", "м", "m", "н", "n", "о", "o", "п", "p", "р", "r", "с", "s", "т", "t", "у", "u", "ф", "f",
	"х", "kh", "ц", "ts", "ч", "ch", "ш", "sh", "щ", "shch", "ъ", "", "ы", "y", "ь", "", "э", "e", "ю", "yu", "я", "ya",
	"А", "a", "Б", "b", "В", "v", "Г", "g", "Д", "d", "Е", "e", "Ё", "e", "Ж", "zh", "З", "z", "И", "i", "Й", "y",
	"К", "k", "Л", "l", "М", "m", "Н", "n", "О", "o", "П", "p", "Р", "r", "С", "s", "Т", "t", "У", "u", "Ф", "f",
	"Х", "kh", "Ц", "ts", "Ч", "ch", "Ш", "sh", "Щ", "shch", "Ъ", "", "Ы", "y", "Ь", "", "Э", "e", "Ю", "yu", "Я", "ya",
)

// shellQuote single-quotes s so the printed command pastes into a shell as is.
func shellQuote(s string) string { return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'" }

// designToolTimeout is the MCP budget of voice_design: a cold engine start plus
// the longest allowed text for every take, each at the plausibility budget
// (lengthBudget), plus slack.
func designToolTimeout() time.Duration {
	perTake := time.Duration(lengthBudget(strings.Repeat("я", maxDesignText)) * float64(time.Second))
	return voxStartupTimeout + maxDesignTakes*perTake + designToolSlack
}

// errNotATake is the refusal for any path that is not a take this daemon made.
func errNotATake(why string) error {
	return &requestError{"that is not a take made by voice design (" + why + "): pass a path returned by voice design"}
}

// resolveTake confines a client-supplied path to the design dir and returns the
// real path of the take and its record. Every component is resolved first, so
// "..", a symlinked file and a symlinked directory all end up outside the
// prefix check; the take and the record themselves must not be symlinks.
func (d *Daemon) resolveTake(path string) (take string, rec designRecord, err error) {
	switch {
	case path == "" || !filepath.IsAbs(path):
		return "", rec, errNotATake("the path must be absolute")
	case !strings.EqualFold(filepath.Ext(path), takeExt):
		return "", rec, errNotATake("it is not a .wav file")
	}
	root, err := filepath.EvalSymlinks(d.designDir())
	if err != nil {
		return "", rec, errNotATake("no takes have been made yet")
	}
	resolved, err := filepath.EvalSymlinks(path)
	if err != nil {
		return "", rec, errNotATake("no such file")
	}
	if rel, rerr := filepath.Rel(root, resolved); rerr != nil || rel == ".." || strings.HasPrefix(rel, ".."+string(filepath.Separator)) || filepath.IsAbs(rel) {
		return "", rec, errNotATake("it is outside the takes folder")
	}
	recPath := strings.TrimSuffix(resolved, filepath.Ext(resolved)) + takeMetaExt
	for _, p := range []string{resolved, recPath} {
		if st, serr := os.Lstat(p); serr != nil || !st.Mode().IsRegular() {
			return "", rec, errNotATake("it is not one of the daemon's own files")
		}
	}
	raw, err := readCapped(recPath, maxDesignBody)
	if err != nil || json.Unmarshal(raw, &rec) != nil || strings.TrimSpace(rec.Text) == "" {
		return "", rec, errNotATake("its record is missing")
	}
	return resolved, rec, nil
}

// readCapped reads a small file, refusing one larger than limit.
func readCapped(path string, limit int64) ([]byte, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer func() { _ = f.Close() }()
	b, err := io.ReadAll(io.LimitReader(f, limit+1))
	if err != nil {
		return nil, err
	}
	if int64(len(b)) > limit {
		return nil, fs.ErrInvalid
	}
	return b, nil
}

// SaveDesignedVoice keeps a design take as a named voxcpm2 voice: the take is
// the reference, its text the transcript, and the description and seed come
// from the daemon's record of the take. The ordinary add path then enforces the
// reference window (a take past it is refused in plain words, nothing stored).
func (d *Daemon) SaveDesignedVoice(ctx context.Context, in SaveDesignInput) (*voices.Voice, bool, error) {
	if strings.TrimSpace(in.Take) == "" {
		return nil, false, &requestError{"take is required: the path of a take returned by voice design"}
	}
	take, rec, err := d.resolveTake(in.Take)
	if err != nil {
		return nil, false, err
	}
	// A clip past the window would be cut and re-transcribed by the store (its
	// ref_text replaced by speech-to-text output): a design take is refused instead.
	if secs, serr := voices.WAVSeconds(take); serr != nil {
		return nil, false, errNotATake("it cannot be read as audio")
	} else if secs > voices.MaxRefSeconds {
		return nil, false, &requestError{fmt.Sprintf("this take is %.0f s, too long to keep as a voice (the limit is %.0f s): use a shorter line", secs, voices.MaxRefSeconds)}
	}
	// An early answer, before the up-to-60 s Prepare. It is not the decision:
	// addVoice repeats it under voiceMu in the same step as the write, which
	// is what makes two concurrent saves of one name safe. A voice that cannot
	// be read is not "absent": saving over it would replace it unseen.
	if _, gerr := d.Store.Get(in.Name); !in.Replace {
		if gerr == nil {
			return nil, false, errVoiceExists(in.Name)
		}
		if !errors.Is(gerr, voices.ErrNotFound) {
			return nil, false, d.voiceReadError(in.Name, gerr, true)
		}
	}
	seed := rec.Seed
	// fresh: a replaced voice keeps nothing of the old one (its style
	// included), in the same commit as the new audio.
	return d.addVoice(ctx, in.Name, take, rec.Text, voices.Meta{
		Engine: config.TTSModelVoxCPM2, DesignedFrom: rec.Description, Seed: &seed,
	}, addOpts{createOnly: !in.Replace, fresh: true})
}

// errVoiceExists is the 409 for a save onto a taken name.
func errVoiceExists(name string) error {
	return &conflictError{fmt.Sprintf("a voice named %q already exists; choose another name, or pass replace (--replace on the command line)", name)}
}

func (d *Daemon) handleDesignVoice(w http.ResponseWriter, r *http.Request) {
	var in DesignInput
	if err := json.NewDecoder(io.LimitReader(r.Body, maxDesignBody)).Decode(&in); err != nil {
		writeErr(w, http.StatusBadRequest, "invalid JSON body")
		return
	}
	res, err := d.DesignVoice(r.Context(), in)
	if err != nil {
		writeErr(w, synthStatus(err), d.publicError(err).Error())
		return
	}
	writeJSON(w, http.StatusOK, res)
}

func (d *Daemon) handleSaveDesign(w http.ResponseWriter, r *http.Request) {
	// Only name, take and replace are read: any other field a client sends is ignored.
	var in SaveDesignInput
	if err := json.NewDecoder(io.LimitReader(r.Body, maxDesignBody)).Decode(&in); err != nil {
		writeErr(w, http.StatusBadRequest, "invalid JSON body")
		return
	}
	res, err := d.saveDesignResult(r.Context(), in)
	if err != nil {
		writeErr(w, synthStatus(err), d.publicError(err).Error())
		return
	}
	writeJSON(w, http.StatusOK, res)
}

// saveDesignResult is SaveDesignedVoice shaped for the HTTP and MCP answers.
func (d *Daemon) saveDesignResult(ctx context.Context, in SaveDesignInput) (*SaveDesignResult, error) {
	v, registered, err := d.SaveDesignedVoice(ctx, in)
	if err != nil {
		return nil, err
	}
	if v.Seed == nil {
		return nil, errors.New("saved voice has no seed")
	}
	return &SaveDesignResult{
		Name: v.Name, Engine: v.Engine, DesignedFrom: v.DesignedFrom, Seed: *v.Seed,
		RegisteredToEngine: registered, Notice: v.Notice,
	}, nil
}
