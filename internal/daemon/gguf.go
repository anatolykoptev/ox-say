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
// general.* strings worth reporting, the file's size, and the numeric
// metadata the notes-context fit needs (Nums for scalars, NumLists for the
// per-layer arrays hybrid models write), each keyed by the metadata name
// with its "<arch>." or "general." prefix stripped.
type ggufMeta struct {
	Version      uint32
	Name         string
	Architecture string
	Bytes        int64
	Nums         map[string]int64
	NumLists     map[string][]int64
}

// ggufWantedNums is the metadata a notes-context fit reads: the model's own
// context ceiling and the K/V layout per attention layer. Keyed by the name
// after the architecture prefix.
var ggufWantedNums = map[string]bool{
	"context_length":          true,
	"block_count":             true,
	"attention.head_count_kv": true,
	"attention.key_length":    true,
	"attention.value_length":  true,
}

// ggufQ8Scale is q8_0's storage: 34 bytes per 32 elements (llama.cpp's
// block_q8_0 of half scale + 32 int8). The KV estimate multiplies the
// element count by 34/32.
const ggufQ8Scale = 34

// kvPerToken estimates the model's q8_0 KV bytes per token: the K+V element
// count summed over the attention layers, times 34/32. key_length and
// value_length are the GGUF's per-layer totals (n_embd_k_gqa / n_embd_v_gqa);
// a per-layer array counts the layers that actually attend — a hybrid's
// linear layers carry no KV. 0 when the metadata cannot say: the estimate
// is never guessed, the fit just keeps the ask and lets llama.cpp's fitter
// and the OOM ladder decide.
func (m ggufMeta) kvPerToken() int64 {
	var dims int64
	if kl := m.NumLists["attention.key_length"]; len(kl) > 0 {
		vl := m.NumLists["attention.value_length"]
		for i, k := range kl {
			dims += k
			if i < len(vl) {
				dims += vl[i]
			}
		}
	} else {
		k, v := m.Nums["attention.key_length"], m.Nums["attention.value_length"]
		if k <= 0 || v <= 0 {
			return 0
		}
		layers := m.Nums["block_count"]
		if hl := m.NumLists["attention.head_count_kv"]; len(hl) > 0 {
			layers = 0
			for _, h := range hl {
				if h > 0 {
					layers++
				}
			}
		}
		dims = (k + v) * layers
	}
	return dims * ggufQ8Scale / 32
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
		name := key
		if i := strings.IndexByte(key, '.'); i >= 0 {
			name = key[i+1:]
		}
		if ggufWantedNums[name] {
			if err := m.captureNum(r, name, typ); err != nil {
				return m, err
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

// captureNum reads a whitelisted numeric value into Nums or NumLists; a key
// of the right name but a non-numeric type is skipped like any other.
func (m *ggufMeta) captureNum(r *bufio.Reader, name string, typ uint32) error {
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
		if elemType == ggufTypeFloat32 || elemType == ggufTypeFloat64 {
			return ggufSkip(r, count*uint64(size))
		}
		vals := make([]int64, 0, min(count, uint64(ggufMaxLayerElems)))
		for i := uint64(0); i < count; i++ {
			v, err := ggufReadInt(r, elemType)
			if err != nil {
				return ggufErr(err)
			}
			if i < ggufMaxLayerElems {
				vals = append(vals, v)
			}
		}
		if m.NumLists == nil {
			m.NumLists = map[string][]int64{}
		}
		m.NumLists[name] = vals
		return nil
	}
	size, ok := ggufFixedSize(typ)
	if !ok {
		return fmt.Errorf("%w: value type %d", errGGUFFormat, typ)
	}
	if typ == ggufTypeFloat32 || typ == ggufTypeFloat64 {
		return ggufSkip(r, uint64(size))
	}
	v, err := ggufReadInt(r, typ)
	if err != nil {
		return ggufErr(err)
	}
	if m.Nums == nil {
		m.Nums = map[string]int64{}
	}
	m.Nums[name] = v
	return nil
}

// ggufMaxLayerElems bounds the per-layer arrays kept whole: a model's layer
// count is two digits, the cap sits far above.
const ggufMaxLayerElems = 8192

// ggufReadInt reads one integer scalar of the given wire type.
func ggufReadInt(r *bufio.Reader, typ uint32) (int64, error) {
	b := make([]byte, 8)
	n, _ := ggufFixedSize(typ)
	if _, err := io.ReadFull(r, b[:n]); err != nil {
		return 0, err
	}
	switch typ {
	case ggufTypeUint8, ggufTypeBool:
		return int64(b[0]), nil
	case ggufTypeInt8:
		return int64(int8(b[0])), nil
	case ggufTypeUint16:
		return int64(binary.LittleEndian.Uint16(b)), nil
	case ggufTypeInt16:
		return int64(int16(binary.LittleEndian.Uint16(b))), nil
	case ggufTypeUint32:
		return int64(binary.LittleEndian.Uint32(b)), nil
	case ggufTypeInt32:
		return int64(int32(binary.LittleEndian.Uint32(b))), nil
	case ggufTypeUint64:
		return int64(binary.LittleEndian.Uint64(b)), nil
	case ggufTypeInt64:
		return int64(binary.LittleEndian.Uint64(b)), nil
	}
	return 0, fmt.Errorf("%w: value type %d", errGGUFFormat, typ)
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
