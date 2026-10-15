package vproject

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"syscall"
)

// syncFile and syncDir are the durability calls of WriteAtomic; vars so a
// test can observe their order against the rename.
var (
	syncFile = func(f *os.File) error { return f.Sync() }
	syncDir  = syncDirectory
)

// syncDirectory fsyncs dir so a rename into it survives a power cut. A
// platform or filesystem that cannot fsync a directory (EINVAL, ENOTSUP) is
// not an error: the rename is as durable as that platform makes it.
func syncDirectory(dir string) error {
	d, err := os.Open(dir)
	if err != nil {
		return err
	}
	err = d.Sync()
	if cerr := d.Close(); err == nil {
		err = cerr
	}
	if errors.Is(err, syscall.EINVAL) || errors.Is(err, syscall.ENOTSUP) {
		return nil
	}
	return err
}

// TempMark marks F1's temp files so a project load can sweep them.
const TempMark = ".tmp-"

// WriteAtomic writes data next to path and renames it into place: the file
// is fsynced before the rename and the directory after it, so a crash leaves
// the old content or the whole new content, never a zero-length file. The
// temp file is removed on any error; errors name path.
func WriteAtomic(path string, data []byte, mode os.FileMode) error {
	f, err := os.CreateTemp(filepath.Dir(path), "."+filepath.Base(path)+TempMark+"*")
	if err != nil {
		return fmt.Errorf("write %s: %w", path, err)
	}
	tmp := f.Name()
	fail := func(err error) error {
		_ = f.Close()
		_ = os.Remove(tmp)
		return fmt.Errorf("write %s: %w", path, err)
	}
	if _, err := f.Write(data); err != nil {
		return fail(err)
	}
	if err := f.Chmod(mode); err != nil {
		return fail(err)
	}
	if err := syncFile(f); err != nil {
		return fail(err)
	}
	if err := f.Close(); err != nil {
		_ = os.Remove(tmp)
		return fmt.Errorf("write %s: %w", path, err)
	}
	if err := os.Rename(tmp, path); err != nil {
		_ = os.Remove(tmp)
		return fmt.Errorf("write %s: %w", path, err)
	}
	if err := syncDir(filepath.Dir(path)); err != nil {
		return fmt.Errorf("write %s: syncing the directory: %w", path, err)
	}
	return nil
}
