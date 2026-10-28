package vproject

import (
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"unicode/utf8"
)

// #154.1: a directory fsync that fails after the rename leaves the content in
// place, so the write succeeds.
// Mutation: files.go WriteAtomic, return the syncDir error again -> RED.
func TestWriteAtomicSurvivesADirSyncFailureAfterTheRename(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, "a.json")
	orig := syncDir
	t.Cleanup(func() { syncDir = orig })
	syncDir = func(string) error { return os.ErrPermission }
	if err := WriteAtomic(p, []byte("new"), 0o600); err != nil {
		t.Fatalf("the content is in place, yet the write failed: %v", err)
	}
	if raw, _ := os.ReadFile(p); string(raw) != "new" {
		t.Errorf("content %q", raw)
	}
}

// #154.4: a name that fits NAME_MAX gets a temp name that fits too.
// Mutation: files.go Stage, CreateTemp pattern back to "."+base+TempMark+"*" -> ENAMETOOLONG -> RED.
func TestStageFitsNameMaxForALongName(t *testing.T) {
	dir := t.TempDir()
	for _, base := range []string{strings.Repeat("a", 250), strings.Repeat("ж", 120)} {
		p := filepath.Join(dir, base)
		if err := WriteAtomic(p, []byte("x"), 0o600); err != nil {
			t.Fatalf("len %d: %v", len(base), err)
		}
		if pre := TempPrefix(base); !utf8.ValidString(pre) || len(pre)+tempRandBytes > maxNameBytes {
			t.Errorf("TempPrefix(%d bytes) = %d bytes (valid utf8 %v)", len(base), len(pre), utf8.ValidString(pre))
		}
	}
}

// #154.10: Clone shares no slice with its source, for every slice field the
// manifest has now or gets later: fill each with one value, clone, change the
// source, and the clone's JSON must not move.
// Mutation: manifest.go Clone, copy Notes by header -> RED.
func TestCloneSharesNoSliceWithTheSource(t *testing.T) {
	m := &Manifest{}
	fill(reflect.ValueOf(m).Elem())
	c := m.Clone()
	before, err := json.Marshal(c)
	if err != nil {
		t.Fatal(err)
	}
	scribble(reflect.ValueOf(m).Elem())
	after, _ := json.Marshal(c)
	if string(before) != string(after) {
		t.Fatalf("the clone changed with its source\n before %s\n after  %s", before, after)
	}
}

// fill gives every slice a one-element value and every string a value.
func fill(v reflect.Value) {
	switch v.Kind() {
	case reflect.Struct:
		for i := 0; i < v.NumField(); i++ {
			if v.Type().Field(i).IsExported() {
				fill(v.Field(i))
			}
		}
	case reflect.Slice:
		v.Set(reflect.MakeSlice(v.Type(), 1, 1))
		fill(v.Index(0))
	case reflect.String:
		v.SetString("orig")
	}
}

// scribble overwrites every string and number reachable through the slices.
func scribble(v reflect.Value) {
	switch v.Kind() {
	case reflect.Struct:
		for i := 0; i < v.NumField(); i++ {
			if v.Type().Field(i).IsExported() {
				scribble(v.Field(i))
			}
		}
	case reflect.Slice:
		for i := 0; i < v.Len(); i++ {
			scribble(v.Index(i))
		}
	case reflect.String:
		v.SetString("changed")
	}
}
