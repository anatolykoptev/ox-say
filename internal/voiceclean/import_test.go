package voiceclean

import (
	"os/exec"
	"strings"
	"testing"
)

// Voice cleanup is an offline, user-chosen file tool: it must never be reachable from meetings, dictation or STT. The
// ground truth is `go list` over the whole module, not a hand-kept list of packages.
func TestOnlyTheDaemonImportsThisPackage(t *testing.T) {
	cmd := exec.Command("go", "list", "-f", `{{.ImportPath}} {{join .Imports " "}} {{join .TestImports " "}} {{join .XTestImports " "}}`, "./...")
	cmd.Dir = "../.."
	out, err := cmd.Output()
	if err != nil {
		t.Fatalf("go list: %v", err)
	}
	seen := 0
	for _, line := range strings.Split(strings.TrimSpace(string(out)), "\n") {
		f := strings.Fields(line)
		if len(f) == 0 {
			continue
		}
		seen++
		for _, imp := range f[1:] {
			if strings.HasSuffix(imp, "/internal/voiceclean") && !strings.HasSuffix(f[0], "/internal/daemon") && !strings.HasSuffix(f[0], "/internal/voiceclean") {
				t.Errorf("%s imports voiceclean: cleanup must never reach meetings, dictation or STT", f[0])
			}
		}
	}
	if seen < 5 {
		t.Fatalf("go list saw only %d packages: the check proves nothing", seen)
	}
}
