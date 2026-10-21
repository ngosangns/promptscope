# How this repo is built

Promptscope reads local logs and counts bytes. The core is the Swift target `PromptscopeKit`. The CLI is `promptscope-cli` and talks to that same core. The window is `promptscope-gpui` in the sibling repo `ns-gpui`. This repo has no UI.

## Dependency direction

```
promptscope-cli     scan and report
   │
   ▼
PromptscopeKit      per-agent parsers, library scan, counting
```

`promptscope-cli` imports `PromptscopeKit`. The Kit imports neither SwiftUI nor the CLI. Parsers do not live in the CLI. The window calls the installed CLI and does not link the Kit.

`promptscope update` is not in the Kit. The Swift CLI looks for `promptscope-update-X.Y.Z` next to itself and execs that Go binary. The Go binary downloads the assets `promptscope-vX.Y.Z-darwin-arm64` and `promptscope-update-vX.Y.Z-darwin-arm64`, checks the GitHub digest, then swaps the `~/.local/bin/promptscope` symlink.

Each `*Analyzer.swift` file handles one log format and produces the same result (`Report`). Adding an agent means adding an analyzer and a case in the CLI.

## Scope

In scope: measuring the standing prompt and transcript of Grok, Kiro IDE, Kiro CLI, OMP, Pi, Devin and DSH on this machine. Never sending a session anywhere.

Out of scope: UI in this repo, a command palette, an extension host, a daemon, collaboration, provider tokenizers (the `~` figure is `byte / 4`), and a second parser inside the CLI.

## GitHub

`ci.yml` runs `swift test` on macOS. `release.yml` packages the CLI on a `v*` tag.
