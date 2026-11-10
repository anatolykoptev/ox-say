package daemon

import (
	"bufio"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"os"
	"strings"
	"unicode"
)

// The own-model check's first look at a file: the GGUF header and the
// metadata key/value section, never the tensor data that fills the rest of
// the file. Every count and length is capped so a corrupt or hostile header
// turns into a refusal, not into a multi-GB read or a long scan. The wire
// format is little-endian: u32 magic "GGUF", u32 version, u64 tensor count,
// u64 metadata count, then that many {string key, u32 value type, value}.
// https://github.com/ggml-org/ggml/blob/master/docs/gguf.md

const (
	// Real models carry a few dozen entries plus tokenizer arrays of a few
	// MB; these caps sit far above that and still refuse a made-up header.
	ggufMaxKVEntries  = 4096
	ggufMaxKeyLen     = 256
	ggufMaxStringLen  = 1 << 20
	ggufMaxArrayElems = 1 << 20
	ggufMaxMetaBytes  = 64 << 20
)

// GGUF metadata value types.
const (
	ggufTypeUint8 = iota
	ggufTypeInt8
	ggufTypeUint16
	ggufTypeInt16
	ggufTypeUint32
	ggufTypeInt32
	ggufTypeFloat32
	ggufTypeBool
	ggufTypeString
	ggufTypeArray
	ggufTypeUint64
	ggufTypeInt64
	ggufTypeFloat64
)

// The refusals a parse can end in. They carry no path: they are the words the
// user reads, and the file they dropped is not the daemon's to name.
var (
	errGGUFUnreadable = errors.New("the file cannot be read")
	errGGUFNotModel   = errors.New("the file is not a GGUF model")
	errGGUFTruncated  = errors.New("the file ends inside its GGUF metadata")
	errGGUFFormat     = errors.New("the file's GGUF metadata is malformed")
	errGGUFTooBig     = errors.New("the file's GGUF metadata is unreasonably large")
)

// ggufMeta is what a GGUF file tells the check: the header version, the two
// general.* strings worth reporting, and the file's size.
type ggufMeta struct {
	Version      uint32
	Name         string
	Architecture string
	Bytes        int64
}

// ggufReadMeta reads the header and metadata of the GGUF at path. A file whose
// version is not 2 or 3 reports just its Version: the older layout counts
// differently, and reading them the v2/v3 way would be a second parser.
func ggufReadMeta(path string) (ggufMeta, error) {
	var m ggufMeta
	f, err := os.Open(path)
	if err != nil {
		return m, errGGUFUnreadable
	}
	defer f.Close()
	st, err := f.Stat()
	if err != nil || !st.Mode().IsRegular() {
		return m, errGGUFUnreadable
	}
	m.Bytes = st.Size()

	r := bufio.NewReaderSize(&metaCapReader{r: f, left: ggufMaxMetaBytes}, 32<<10)
	var magic [4]byte
	if _, err := io.ReadFull(r, magic[:]); err != nil {
		return m, ggufErr(err)
	}
	if string(magic[:]) != "GGUF" {
		return m, errGGUFNotModel
	}
	v, err := ggufU32(r)
	if err != nil {
		return m, ggufErr(err)
	}
	m.Version = v
	if v != 2 && v != 3 {
		return m, nil
	}
	if _, err := ggufU64(r); err != nil { // the tensor count: never read
		return m, ggufErr(err)
	}
	kvCount, err := ggufU64(r)
	if err != nil {
		return m, ggufErr(err)
	}
	if kvCount > ggufMaxKVEntries {
		return m, fmt.Errorf("%w: %d metadata entries", errGGUFFormat, kvCount)
	}
	for i := uint64(0); i < kvCount; i++ {
		key, err := ggufString(r, ggufMaxKeyLen)
		if err != nil {
			return m, err
		}
		typ, err := ggufU32(r)
		if err != nil {
			return m, ggufErr(err)
		}
		if typ == ggufTypeString && (key == "general.name" || key == "general.architecture") {
			s, err := ggufString(r, ggufMaxStringLen)
			if err != nil {
				return m, err
			}
			if key == "general.name" {
				m.Name = ggufMetaString(s)
			} else {
				m.Architecture = ggufMetaString(s)
			}
			continue
		}
		if err := ggufSkipValue(r, typ); err != nil {
			return m, err
		}
	}
	return m, nil
}

// ggufMaxMetaRunes bounds the metadata strings the check reports: they are
// the file's own words and bound nothing.
const ggufMaxMetaRunes = 128

// ggufMetaString makes a metadata string safe to report: control characters
// are stripped and it is capped at ggufMaxMetaRunes runes.
func ggufMetaString(s string) string {
	s = strings.Map(func(r rune) rune {
		if unicode.IsControl(r) {
			return -1
		}
		return r
	}, s)
	if rs := []rune(s); len(rs) > ggufMaxMetaRunes {
		s = string(rs[:ggufMaxMetaRunes])
	}
	return s
}

// metaCapReader fails reads past the metadata budget instead of reporting a
// plain EOF, so "the header is too big" does not read as "the file ended".
type metaCapReader struct {
	r    io.Reader
	left int64
}

func (c *metaCapReader) Read(p []byte) (int, error) {
	if c.left <= 0 {
		return 0, errGGUFTooBig
	}
	if int64(len(p)) > c.left {
		p = p[:c.left]
	}
	n, err := c.r.Read(p)
	c.left -= int64(n)
	return n, err
}

// ggufErr maps a stream error onto the refusal words: the cap keeps its own
// verdict, everything else is a file that ended too soon.
func ggufErr(err error) error {
	if errors.Is(err, errGGUFTooBig) {
		return errGGUFTooBig
	}
	return errGGUFTruncated
}

func ggufU32(r *bufio.Reader) (uint32, error) {
	var b [4]byte
	if _, err := io.ReadFull(r, b[:]); err != nil {
		return 0, err
	}
	return binary.LittleEndian.Uint32(b[:]), nil
}

func ggufU64(r *bufio.Reader) (uint64, error) {
	var b [8]byte
	if _, err := io.ReadFull(r, b[:]); err != nil {
		return 0, err
	}
	return binary.LittleEndian.Uint64(b[:]), nil
}

// ggufString reads one GGUF string, refusing a declared length over max
// before a byte of it is touched.
func ggufString(r *bufio.Reader, max uint64) (string, error) {
	n, err := ggufU64(r)
	if err != nil {
		return "", err
	}
	if n > max {
		return "", fmt.Errorf("%w: a string of %d bytes", errGGUFFormat, n)
	}
	var sb strings.Builder
	sb.Grow(int(n))
	if _, err := io.CopyN(&sb, r, int64(n)); err != nil {
		return "", ggufErr(err)
	}
	return sb.String(), nil
}

// ggufSkipValue consumes one metadata value of the given wire type.
func ggufSkipValue(r *bufio.Reader, typ uint32) error {
	if typ == ggufTypeString {
		_, err := ggufString(r, ggufMaxStringLen)
		return err
	}
	if typ == ggufTypeArray {
		elemType, err := ggufU32(r)
		if err != nil {
			return ggufErr(err)
		}
		count, err := ggufU64(r)
		if err != nil {
			return ggufErr(err)
		}
		if count > ggufMaxArrayElems {
			return fmt.Errorf("%w: an array of %d elements", errGGUFFormat, count)
		}
		if elemType == ggufTypeString {
			for i := uint64(0); i < count; i++ {
				if _, err := ggufString(r, ggufMaxStringLen); err != nil {
					return err
				}
			}
			return nil
		}
		size, ok := ggufFixedSize(elemType)
		if !ok {
			return fmt.Errorf("%w: array element type %d", errGGUFFormat, elemType)
		}
		return ggufSkip(r, count*uint64(size))
	}
	size, ok := ggufFixedSize(typ)
	if !ok {
		return fmt.Errorf("%w: value type %d", errGGUFFormat, typ)
	}
	return ggufSkip(r, uint64(size))
}

// ggufFixedSize is the byte width of a fixed-size value type; strings and
// arrays carry their own lengths and report false.
func ggufFixedSize(typ uint32) (int, bool) {
	switch typ {
	case ggufTypeUint8, ggufTypeInt8, ggufTypeBool:
		return 1, true
	case ggufTypeUint16, ggufTypeInt16:
		return 2, true
	case ggufTypeUint32, ggufTypeInt32, ggufTypeFloat32:
		return 4, true
	case ggufTypeUint64, ggufTypeInt64, ggufTypeFloat64:
		return 8, true
	}
	return 0, false
}

func ggufSkip(r *bufio.Reader, n uint64) error {
	for n > 0 {
		step := n
		if step > 1<<20 {
			step = 1 << 20
		}
		got, err := r.Discard(int(step))
		n -= uint64(got)
		if err != nil {
			return ggufErr(err)
		}
	}
	return nil
}
