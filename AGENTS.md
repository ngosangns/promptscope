# Project agent memory

## Orientation

Promptscope is a local macOS app that measures how Grok, Kiro, OMP, Pi, and Devin sessions spend their prompt.
The analyzer is in-process Swift. There is no Go module and no daemon.

Layout matches `../synca/macos`:

- `macos/Sources/PromptscopeKit` — models, parsers, library scan. No UI imports. Unit-tested.
- `macos/Sources/promptscope-cli` — `report` and `scan`.
- `macos/Sources/promptscope-app` — `App`, `Design`, `Features`, `Model`.
- `Taskfile.yml` is the entry point: `task app:build`, `task app:test`, `task app:install`, `task dev`, `task app:icon`.

`task app:install` quits a running copy, then `rsync -a --delete`s `macos/promptscope.app` into `/Applications`.
Launch the built bundle with `open macos/promptscope.app`. `task dev` runs the debug binary the way synca does;
`AppDelegate` sets the regular activation policy so that binary gets a window.

## Sharp edges

- A digest stops at the first real user query. Overview skill read counts stay 0 until that session is opened and the full report replaces the digest.
- Token figures labeled `~` are `byte / 4`, not the provider tokenizer. Kiro CLI context % × window is a separate number when the sidecar has it.
- Grok does not inline MCP tool schemas. The MCP measure is the server blurb in the reminder.
- Standing skills, MCP, and rules are last-wins. Transcript bytes sum every copy. The system chat line duplicates `system_prompt.txt`; standing uses the file size.
- Empty Kiro CLI transcripts are skipped. `/tmp` and subagent sessions are hidden by default. Nested OMP/Pi jsonl files are subagents.
- Pi stores the standing prompt in `system.sections`. OMP stores only `system-prompt-digest` plus usage (`input`, `contextPercent`, `contextSnapshot.nonMessageTokens`). Devin CLI stores system steps and `tool_definitions` in the ATIF transcript; `prompt_tokens` on the last agent step is the recorded prompt size.
- The sidebar source list is one row per agent. Do not put them back in a segmented control.
- Skill names require a path that contains `/skills/` and a real `SKILL.md` segment. `but` is a real GitButler skill, not noise.
