package daemon

import (
	"bytes"
	"encoding/binary"
	"errors"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"unicode/utf8"
)

// ggufKV is one test metadata entry; which of the Value fields the writer
// emits is set by Type.
type ggufKV struct {
	Key  string
	Type uint32
	Str  string
	U32  uint32
	Strs []string
	U32s []uint32
}

// writeTestGGUF builds a v2/v3 GGUF file body — header, then the entries —
// and enough trailing bytes to stand in for tensor data.
func writeTestGGUF(t *testing.T, version uint32, kvs []ggufKV) []byte {
	t.Helper()
	var b bytes.Buffer
	b.WriteString("GGUF")
	_ = binary.Write(&b, binary.LittleEndian, version)
	_ = binary.Write(&b, binary.LittleEndian, uint64(0)) // tensor count
	_ = binary.Write(&b, binary.LittleEndian, uint64(len(kvs)))
	for _, kv := range kvs {
		_ = binary.Write(&b, binary.LittleEndian, uint64(len(kv.Key)))
		b.WriteString(kv.Key)
		_ = binary.Write(&b, binary.LittleEndian, kv.Type)
		switch kv.Type {
		case ggufTypeString:
			_ = binary.Write(&b, binary.LittleEndian, uint64(len(kv.Str)))
			b.WriteString(kv.Str)
		case ggufTypeUint32:
			_ = binary.Write(&b, binary.LittleEndian, kv.U32)
		case ggufTypeArray:
			if len(kv.U32s) > 0 {
				_ = binary.Write(&b, binary.LittleEndian, uint32(ggufTypeUint32))
				_ = binary.Write(&b, binary.LittleEndian, uint64(len(kv.U32s)))
				for _, u := range kv.U32s {
					_ = binary.Write(&b, binary.LittleEndian, u)
				}
			} else {
				_ = binary.Write(&b, binary.LittleEndian, uint32(ggufTypeString))
				_ = binary.Write(&b, binary.LittleEndian, uint64(len(kv.Strs)))
				for _, s := range kv.Strs {
					_ = binary.Write(&b, binary.LittleEndian, uint64(len(s)))
					b.WriteString(s)
				}
			}
		default:
			t.Fatalf("writeTestGGUF: unhandled type %d", kv.Type)
		}
	}
	b.Write(make([]byte, 64)) // where the tensors would start
	return b.Bytes()
}

func ggufFile(t *testing.T, body []byte) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "model.gguf")
	if err := os.WriteFile(path, body, 0o644); err != nil {
		t.Fatalf("write gguf: %v", err)
	}
	return path
}

func TestGGUFReadMetaReadsVersionNameAndArchitecture(t *testing.T) {
	path := ggufFile(t, writeTestGGUF(t, 3, []ggufKV{
		{Key: "general.architecture", Type: ggufTypeString, Str: "qwen3"},
		{Key: "general.name", Type: ggufTypeString, Str: "My Model"},
		{Key: "llama.context_length", Type: ggufTypeUint32, U32: 40960},
		{Key: "tokenizer.ggml.tokens", Type: ggufTypeArray, Strs: []string{"a", "b", "c"}},
		{Key: "tokenizer.ggml.scores", Type: ggufTypeArray, U32s: []uint32{1, 2}},
	}))
	m, err := ggufReadMeta(path)
	if err != nil {
		t.Fatalf("read: %v", err)
	}
	if m.Version != 3 || m.Name != "My Model" || m.Architecture != "qwen3" {
		t.Fatalf("meta = %+v", m)
	}
	st, _ := os.Stat(path)
	if m.Bytes != st.Size() {
		t.Fatalf("bytes = %d, want %d", m.Bytes, st.Size())
	}
}

func TestGGUFReadMetaWithoutTheGeneralStrings(t *testing.T) {
	path := ggufFile(t, writeTestGGUF(t, 2, []ggufKV{
		{Key: "llama.context_length", Type: ggufTypeUint32, U32: 40960},
	}))
	m, err := ggufReadMeta(path)
	if err != nil {
		t.Fatalf("read: %v", err)
	}
	if m.Version != 2 || m.Name != "" || m.Architecture != "" {
		t.Fatalf("meta = %+v", m)
	}
}

func TestGGUFReadMetaReportsAnUnsupportedVersion(t *testing.T) {
	path := ggufFile(t, writeTestGGUF(t, 4, nil))
	m, err := ggufReadMeta(path)
	if err != nil {
		t.Fatalf("read: %v", err)
	}
	if m.Version != 4 {
		t.Fatalf("version = %d", m.Version)
	}
}

// The parse reads through every declared entry — a valid head does not cut
// it short once the two general.* strings are in: a malformed tail, an
// unknown value type included, is refused. Mutation: gguf.go ggufReadMeta,
// restore the early `if m.Name != "" && m.Architecture != "" { return m,
// nil }` -> both rows RED (the tail is never reached).
func TestGGUFReadMetaReadsThroughTheDeclaredEntries(t *testing.T) {
	head := writeTestGGUF(t, 3, []ggufKV{
		{Key: "general.architecture", Type: ggufTypeString, Str: "qwen3"},
		{Key: "general.name", Type: ggufTypeString, Str: "Mine"},
	})
	// The header sits before the writer's 64-byte tensor stand-in; the
	// declared count is rewritten for the third, broken entry.
	withTail := func(entry []byte, tail bool) []byte {
		body := append([]byte(nil), head[:len(head)-64]...)
		binary.LittleEndian.PutUint64(body[16:24], 3)
		body = append(body, entry...)
		if tail {
			body = append(body, make([]byte, 64)...)
		}
		return body
	}
	t.Run("an unknown value type after the head", func(t *testing.T) {
		var e bytes.Buffer
		_ = binary.Write(&e, binary.LittleEndian, uint64(1))
		e.WriteString("x")
		_ = binary.Write(&e, binary.LittleEndian, uint32(99))
		_, err := ggufReadMeta(ggufFile(t, withTail(e.Bytes(), true)))
		if !errors.Is(err, errGGUFFormat) {
			t.Fatalf("err = %v, want the malformed tail refused", err)
		}
	})
	t.Run("the file ends inside the tail", func(t *testing.T) {
		var e bytes.Buffer
		_ = binary.Write(&e, binary.LittleEndian, uint64(1))
		e.WriteString("x")
		// No type word follows: the file ends inside the third entry.
		_, err := ggufReadMeta(ggufFile(t, withTail(e.Bytes(), false)))
		if !errors.Is(err, errGGUFTruncated) {
			t.Fatalf("err = %v, want the truncated tail refused", err)
		}
	})
}

// The two general.* strings are the file's own words — bounded and cleaned
// before they ride out in the validate answer: no control characters, at
// most ggufMaxMetaRunes runes. Mutation: ggufReadMeta, drop the
// ggufMetaString calls -> the raw values come back -> RED.
func TestGGUFReadMetaCleansTheReportedStrings(t *testing.T) {
	path := ggufFile(t, writeTestGGUF(t, 3, []ggufKV{
		{Key: "general.architecture", Type: ggufTypeString, Str: "qwen\x003\x07"},
		{Key: "general.name", Type: ggufTypeString, Str: "Mine\n" + strings.Repeat("y", 200)},
	}))
	m, err := ggufReadMeta(path)
	if err != nil {
		t.Fatalf("read: %v", err)
	}
	if m.Architecture != "qwen3" {
		t.Fatalf("architecture = %q, want the control bytes stripped", m.Architecture)
	}
	if strings.ContainsAny(m.Name, "\n\x00") {
		t.Fatalf("name carries a control character: %q", m.Name)
	}
	if n := utf8.RuneCountInString(m.Name); n != 128 {
		t.Fatalf("name = %d runes, want the 128 cap", n)
	}
}

func TestGGUFReadMetaRefusesNonGGUFAndTruncated(t *testing.T) {
	if _, err := ggufReadMeta(ggufFile(t, []byte("not a gguf at all"))); !errors.Is(err, errGGUFNotModel) {
		t.Fatalf("not-a-gguf err = %v", err)
	}
	// Magic and version, then the file ends inside the counts.
	body := append([]byte("GGUF"), 3, 0, 0, 0)
	if _, err := ggufReadMeta(ggufFile(t, body)); !errors.Is(err, errGGUFTruncated) {
		t.Fatalf("truncated err = %v", err)
	}
	if _, err := ggufReadMeta(filepath.Join(t.TempDir(), "missing.gguf")); !errors.Is(err, errGGUFUnreadable) {
		t.Fatalf("missing err = %v", err)
	}
}

// F6 — the malformed file a user can drop: a made-up metadata count, a string
// that runs past the end of the file. The refusal must be clean and bounded;
// dropping the count cap is the named mutation: the all-present 4097-entry
// file then parses to the end and this test reads a different verdict.
func TestGGUFReadMetaRefusesAMalformedFile(t *testing.T) {
	t.Run("kv count over the cap with every entry present", func(t *testing.T) {
		kvs := make([]ggufKV, ggufMaxKVEntries+1)
		for i := range kvs {
			kvs[i] = ggufKV{Key: "k" + strconv.Itoa(i), Type: ggufTypeUint32, U32: uint32(i)}
		}
		_, err := ggufReadMeta(ggufFile(t, writeTestGGUF(t, 3, kvs)))
		if !errors.Is(err, errGGUFFormat) {
			t.Fatalf("err = %v", err)
		}
	})
	t.Run("string length declared beyond the file", func(t *testing.T) {
		var b bytes.Buffer
		b.WriteString("GGUF")
		_ = binary.Write(&b, binary.LittleEndian, uint32(3))
		_ = binary.Write(&b, binary.LittleEndian, uint64(0))
		_ = binary.Write(&b, binary.LittleEndian, uint64(1))
		key := "general.name"
		_ = binary.Write(&b, binary.LittleEndian, uint64(len(key)))
		b.WriteString(key)
		_ = binary.Write(&b, binary.LittleEndian, uint32(ggufTypeString))
		_ = binary.Write(&b, binary.LittleEndian, uint64(ggufMaxStringLen)+1) // over the cap, no bytes follow
		_, err := ggufReadMeta(ggufFile(t, b.Bytes()))
		if !errors.Is(err, errGGUFFormat) {
			t.Fatalf("err = %v", err)
		}
	})
	t.Run("string length inside the cap but past the file end", func(t *testing.T) {
		var b bytes.Buffer
		b.WriteString("GGUF")
		_ = binary.Write(&b, binary.LittleEndian, uint32(3))
		_ = binary.Write(&b, binary.LittleEndian, uint64(0))
		_ = binary.Write(&b, binary.LittleEndian, uint64(1))
		key := "general.name"
		_ = binary.Write(&b, binary.LittleEndian, uint64(len(key)))
		b.WriteString(key)
		_ = binary.Write(&b, binary.LittleEndian, uint32(ggufTypeString))
		_ = binary.Write(&b, binary.LittleEndian, uint64(1024))
		b.WriteString("short")
		_, err := ggufReadMeta(ggufFile(t, b.Bytes()))
		if !errors.Is(err, errGGUFTruncated) {
			t.Fatalf("err = %v", err)
		}
	})
	t.Run("array element count over the cap", func(t *testing.T) {
		var b bytes.Buffer
		b.WriteString("GGUF")
		_ = binary.Write(&b, binary.LittleEndian, uint32(3))
		_ = binary.Write(&b, binary.LittleEndian, uint64(0))
		_ = binary.Write(&b, binary.LittleEndian, uint64(1))
		key := "x"
		_ = binary.Write(&b, binary.LittleEndian, uint64(len(key)))
		b.WriteString(key)
		_ = binary.Write(&b, binary.LittleEndian, uint32(ggufTypeArray))
		_ = binary.Write(&b, binary.LittleEndian, uint32(ggufTypeUint32))
		_ = binary.Write(&b, binary.LittleEndian, uint64(ggufMaxArrayElems)+1)
		_, err := ggufReadMeta(ggufFile(t, b.Bytes()))
		if !errors.Is(err, errGGUFFormat) {
			t.Fatalf("err = %v", err)
		}
	})
}
