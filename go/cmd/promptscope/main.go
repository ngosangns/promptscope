// Command promptscope is the self-updater for the installed promptscope CLI.
// Scan and report stay in the Swift binary this command replaces.
package main

import (
	"context"
	"fmt"
	"os"

	"github.com/ngosangns/promptscope/go/internal/updater"
)

// version is stamped at build time: -ldflags "-X main.version=$(cat VERSION)".
// The repo-root VERSION file is the version promptscope update compares with
// GitHub release tags.
var version = "0.0.0-dev"

func main() {
	args := os.Args[1:]
	if len(args) == 0 || args[0] == "--help" || args[0] == "-h" || args[0] == "help" {
		fmt.Println(`promptscope — self-update for the installed CLI

usage: promptscope update [--check] [--json] [--force]

update installs the latest stable GitHub release of the darwin-arm64 CLI.
Scan and report are the same binary after it is installed.`)
		return
	}
	if args[0] == "--version" || args[0] == "-V" || args[0] == "version" {
		fmt.Printf("promptscope %s\n", version)
		return
	}
	if args[0] != "update" {
		fmt.Fprintf(os.Stderr, "promptscope: unknown command %q (see: promptscope --help)\n", args[0])
		os.Exit(2)
	}
	err := updater.Run(context.Background(), updater.Options{
		Args:    args[1:],
		Version: version,
		Stdout:  os.Stdout,
		Stderr:  os.Stderr,
	})
	if err != nil {
		os.Exit(updater.ExitCode(err))
	}
}
