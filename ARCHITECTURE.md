# How this repo is built

Promptscope reads local logs and counts bytes. The core is the Swift target `PromptscopeKit`. The CLI is `promptscope-cli` and talks to that same core. The window is `promptscope-gpui` in the sibling repo `ns-gpui`. This repo has no UI.

## Dependency direction

```
promptscope-cli     argv, exit, exec of the Go updater
   │
   ▼
PromptscopeKit      sessions, scan, report, skill, parsers, library scan
```

`promptscope-cli` imports `PromptscopeKit`. The Kit imports neither SwiftUI nor the CLI. Parsers do not live in the CLI. Session listing uses `LibraryScanner` only. The window does not link the Kit. It lists sessions with its own Rust scanner (same directories, noise rules, and `<source>:<session>` ids) and calls the installed CLI for `report <source> <path> --json` and `update`. It does not pass `--section`, `--summary`, `--no-text`, or `--max-bytes`. The default JSON object is unchanged.

`promptscope version` and `promptscope schema` describe the CLI for an agent. `version --json` prints the name, the release version, `schemaVersion` 1 and `commit` (`null` in this Swift build). `schema --json` prints a JSON Schema (draft 2020-12) for each command output. `schemas/v1/*.json` is the canonical copy. `EmbeddedSchemas` in the Kit holds the same bytes. `skills/promptscope/SKILL.md` is the skill source of truth; `EmbeddedSkill` holds the same bytes. `scripts/embed-assets.py` regenerates both. The binary does not use a resource bundle. A failed `--json` command prints `{"error":...}` on stdout and exits with `error.exit` (2 usage, 3 unavailable, 4 protocol, 5 failed, 8 drift). `skill check` drift still prints the check object.

`UpdaterLocator` in the Kit finds `promptscope-update-X.Y.Z` beside the resolved executable. The CLI execs that Go binary. The Go binary downloads the assets `promptscope-vX.Y.Z-darwin-arm64` and `promptscope-update-vX.Y.Z-darwin-arm64`, checks the GitHub digest, then swaps the `~/.local/bin/promptscope` symlink.

Each `*Analyzer.swift` file handles one log format and produces the same result (`Report`). Adding an agent means adding an analyzer and a case in the CLI.

## Scope

In scope: measuring the standing prompt and transcript of Grok, Kiro IDE, Kiro CLI, OMP, Pi, Devin and DSH on this machine. Never sending a session anywhere.

Out of scope: UI in this repo, a command palette, an extension host, a daemon, collaboration, provider tokenizers (the `~` figure is `byte / 4`), and a second parser inside the CLI.

## GitHub

`ci.yml` runs `go vet`, `go test`, and `swift test` on macOS. `release.yml` runs `scripts/release-local.sh --publish` on a `v*` tag (CLI, updater, `SHA256SUMS`).
