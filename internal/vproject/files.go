package vproject

import (
	"fmt"
	"os"
	"path/filepath"
)

// TempMark marks F1's temp files so a project load can sweep them.
const TempMark = ".tmp-"

// WriteAtomic writes data next to path and renames it into place; the temp
// file is removed on any error.
func WriteAtomic(path string, data []byte, mode os.FileMode) error {
	f, err := os.CreateTemp(filepath.Dir(path), "."+filepath.Base(path)+TempMark+"*")
	if err != nil {
		return err
	}
	tmp := f.Name()
	fail := func(err error) error { _ = f.Close(); _ = os.Remove(tmp); return err }
	if _, err := f.Write(data); err != nil {
		return fail(fmt.Errorf("write %s: %w", filepath.Base(path), err))
	}
	if err := f.Chmod(mode); err != nil {
		return fail(err)
	}
	if err := f.Close(); err != nil {
		_ = os.Remove(tmp)
		return err
	}
	if err := os.Rename(tmp, path); err != nil {
		_ = os.Remove(tmp)
		return err
	}
	return nil
}
