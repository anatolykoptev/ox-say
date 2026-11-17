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
// context ceiling and what llama.cpp derives the KV cache's shape from (its
// layer count, which layers attend, their KV head count and per-head K/V
// widths). Keyed by the name after the architecture prefix.
var ggufWantedNums = map[string]bool{
	"context_length":          true,
	"block_count":             true,
	"embedding_length":        true,
	"nextn_predict_layers":    true,
	"full_attention_interval": true,
	"attention.head_count":    true,
	"attention.head_count_kv": true,
	"attention.key_length":    true,
	"attention.value_length":  true,
}

// q8_0 stores 34 bytes per 32 elements (llama.cpp's block_q8_0: a half scale
// plus 32 int8). The KV estimate multiplies the element count by 34/32.
const (
	ggufQ8BlockBytes = 34
	ggufQ8BlockElems = 32
	// ggufMaxKVDim bounds each factor of the KV estimate: no real model has a
	// head count or a per-head width near it, and a made-up header cannot
	// overflow the product.
	ggufMaxKVDim = 1 << 20
	// ggufQwen35FullAttnInterval is the default llama.cpp's qwen35 loader
	// uses when the file carries no full_attention_interval.
	ggufQwen35FullAttnInterval = 4
)

// kvPerToken is the model's q8_0 KV bytes per token, the way llama.cpp sizes
// its cache: for each layer that keeps KV, KV heads x (key_length +
// value_length) elements — GGUF's key/value lengths are PER HEAD — times
// 34/32. Which layers keep KV follows llama.cpp: the trunk (block_count minus
// nextn_predict_layers; the MTP layer is not in the main context); of those a
// hybrid's full_attention_interval marks every interval-th layer as attention
// (src/models/qwen35.cpp: is_recr = (il+1) % interval != 0), a per-layer
// head_count_kv array keeps the layers with a nonzero entry, and a plain
// model keeps all of them. 0 when the metadata cannot say: the estimate is
// never guessed, the fit just keeps the ask and lets llama.cpp's fitter and
// the OOM ladder decide.
func (m ggufMeta) kvPerToken() int64 {
	trunk := m.Nums["block_count"] - m.Nums["nextn_predict_layers"]
	if trunk <= 0 || trunk > ggufMaxLayerElems {
		return 0
	}
	interval := m.Nums["full_attention_interval"]
	if interval <= 0 && (m.Architecture == "qwen35" || m.Architecture == "qwen35moe") {
		interval = ggufQwen35FullAttnInterval
	}
	kvHeads := m.NumLists["attention.head_count_kv"]
	_, kvScalar := m.Nums["attention.head_count_kv"]
	var elems int64
	for il := int64(0); il < trunk; il++ {
		heads := m.layerNum("attention.head_count_kv", il)
		if len(kvHeads) == 0 && !kvScalar {
			heads = m.layerNum("attention.head_count", il) // no GQA key: one KV head per head
		}
		attends := true
		switch {
		case interval > 0:
			attends = (il+1)%interval == 0 // the others are linear-attention layers: recurrent state, no KV
		case len(kvHeads) > 0:
			attends = heads > 0 // a per-layer array's zero marks a layer without KV
		}
		if !attends {
			continue
		}
		k, v := m.layerKV(il)
		if heads <= 0 || k <= 0 || v <= 0 || heads > ggufMaxKVDim || k > ggufMaxKVDim || v > ggufMaxKVDim {
			return 0
		}
		elems += heads * (k + v)
	}
	return elems * ggufQ8BlockBytes / ggufQ8BlockElems
}

// layerNum is a metadata number for layer il: the array's entry when the file
// wrote a per-layer array, else the scalar; 0 when it carries neither.
func (m ggufMeta) layerNum(name string, il int64) int64 {
	if arr := m.NumLists[name]; len(arr) > 0 {
		if il < int64(len(arr)) {
			return arr[il]
		}
		return 0
	}
	return m.Nums[name]
}

// layerKV is the per-head key and value widths of layer il: the file's
// key_length/value_length, else llama.cpp's own fallback of embedding_length
// divided by the head count.
func (m ggufMeta) layerKV(il int64) (k, v int64) {
	k, v = m.layerNum("attention.key_length", il), m.layerNum("attention.value_length", il)
	if k > 0 && v > 0 {
		return k, v
	}
	if heads := m.layerNum("attention.head_count", il); heads > 0 {
		d := m.Nums["embedding_length"] / heads
		if k <= 0 {
			k = d
		}
		if v <= 0 {
			v = d
		}
	}
	return k, v
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
	kvCount, err := m.readHeader(r)
	if err != nil || kvCount == 0 {
		return m, err
	}
	for i := uint64(0); i < kvCount; i++ {
		if err := m.readEntry(r); err != nil {
			return m, err
		}
	}
	return m, nil
}

// readHeader reads the magic, the version and the counts, and returns how many
// metadata entries follow (0 for a version this reader does not parse).
func (m *ggufMeta) readHeader(r *bufio.Reader) (uint64, error) {
	var magic [4]byte
	if _, err := io.ReadFull(r, magic[:]); err != nil {
		return 0, ggufErr(err)
	}
	if string(magic[:]) != "GGUF" {
		return 0, errGGUFNotModel
	}
	v, err := ggufU32(r)
	if err != nil {
		return 0, ggufErr(err)
	}
	m.Version = v
	if v != 2 && v != 3 {
		return 0, nil
	}
	if _, err := ggufU64(r); err != nil { // the tensor count: never read
		return 0, ggufErr(err)
	}
	kvCount, err := ggufU64(r)
	if err != nil {
		return 0, ggufErr(err)
	}
	if kvCount > ggufMaxKVEntries {
		return 0, fmt.Errorf("%w: %d metadata entries", errGGUFFormat, kvCount)
	}
	return kvCount, nil
}

// readEntry reads one metadata entry: the general strings and the wanted
// numbers are kept, anything else is skipped.
func (m *ggufMeta) readEntry(r *bufio.Reader) error {
	key, err := ggufString(r, ggufMaxKeyLen)
	if err != nil {
		return err
	}
	typ, err := ggufU32(r)
	if err != nil {
		return ggufErr(err)
	}
	if typ == ggufTypeString && (key == "general.name" || key == "general.architecture") {
		s, err := ggufString(r, ggufMaxStringLen)
		if err != nil {
			return err
		}
		if key == "general.name" {
			m.Name = ggufMetaString(s)
		} else {
			m.Architecture = ggufMetaString(s)
		}
		return nil
	}
	name := key
	if i := strings.IndexByte(key, '.'); i >= 0 {
		name = key[i+1:]
	}
	if ggufWantedNums[name] {
		return m.captureNum(r, name, typ)
	}
	return ggufSkipValue(r, typ)
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
