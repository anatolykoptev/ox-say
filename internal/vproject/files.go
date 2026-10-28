package vproject

import (
	"errors"
	"fmt"
	"log/slog"
	"os"
	"path/filepath"
	"syscall"
	"unicode/utf8"
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

// SyncDir fsyncs dir so renames into it survive a power cut (no error where
// the platform cannot fsync a directory).
func SyncDir(dir string) error { return syncDir(dir) }

// WriteError is a failed write of Path. Error names the full path, for the
// log; anything shown to a caller must use Base(Path) and not Error.
type WriteError struct {
	Path string
	Err  error
}

func (e *WriteError) Error() string { return fmt.Sprintf("write %s: %v", e.Path, e.Err) }
func (e *WriteError) Unwrap() error { return e.Err }

func writeErr(path string, err error) error { return &WriteError{Path: path, Err: err} }

// TempMark marks F1's temp files so a project load can sweep them.
const TempMark = ".tmp-"

// maxNameBytes is the longest file name the supported file systems accept
// (NAME_MAX on APFS, HFS+, ext4); tempRandBytes is room for os.CreateTemp's
// random suffix.
const (
	maxNameBytes  = 255
	tempRandBytes = 20
)

// TempPrefix is the start of the temp names made for the file called base:
// "." + base + TempMark, with base cut (on a rune boundary) so that the
// finished temp name, with CreateTemp's random suffix, still fits a file
// name. A name that fits is cut only so far that its temp fits too.
func TempPrefix(base string) string {
	room := maxNameBytes - len(".") - len(TempMark) - tempRandBytes
	for len(base) > room {
		_, n := utf8.DecodeLastRuneInString(base)
		base = base[:len(base)-n]
	}
	return "." + base + TempMark
}

// TempPattern is the os.CreateTemp pattern of a temp beside the file base.
func TempPattern(base string) string { return TempPrefix(base) + "*" }

// Stage writes data to a temp file beside path (fsynced, chmod mode) and
// returns its name; the caller renames it into place or removes it. Errors
// name path and leave no temp file.
func Stage(path string, data []byte, mode os.FileMode) (tmp string, err error) {
	f, err := os.CreateTemp(filepath.Dir(path), TempPattern(filepath.Base(path)))
	if err != nil {
		return "", writeErr(path, err)
	}
	tmp = f.Name()
	fail := func(err error) (string, error) {
		_ = f.Close()
		_ = os.Remove(tmp)
		return "", writeErr(path, err)
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
		return "", writeErr(path, err)
	}
	return tmp, nil
}

// WriteAtomic stages data and renames it into place; the file is fsynced
// before the rename and the directory after it, so a crash leaves the old
// content or the whole new content, never a zero-length file. The temp file
// is removed on any error; errors name path. A directory fsync that fails after
// the rename is logged, not returned: the content is in place.
func WriteAtomic(path string, data []byte, mode os.FileMode) error {
	tmp, err := Stage(path, data, mode)
	if err != nil {
		return err
	}
	if err := os.Rename(tmp, path); err != nil {
		_ = os.Remove(tmp)
		return writeErr(path, err)
	}
	// The new content is already in place: a directory fsync that fails only
	// weakens the guarantee that the rename survives a power cut. Failing the
	// write would make callers undo state that is on disk, so it is logged.
	if err := syncDir(filepath.Dir(path)); err != nil {
		slog.Warn("vproject: the directory could not be synced after a rename; the file is in place",
			slog.String("file", filepath.Base(path)), slog.Any("error", err))
	}
	return nil
}
