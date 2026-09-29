// ox-say is a local text-to-speech daemon for Intel Macs: `ox-say serve`
// owns the tts-server engine child; `say`, `voice` and `status` are thin
// clients of the running daemon.
package main

import (
	"os"

	"github.com/anatolykoptev/ox-say/internal/cli"
)

var version = "dev"

func main() {
	os.Exit(cli.Run(os.Args[1:], os.Stdout, os.Stderr, version))
}
