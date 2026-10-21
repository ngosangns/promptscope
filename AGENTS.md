# Project agent memory

## Orientation

Promptscope measures how Grok, Kiro, OMP, Pi, Devin, and DSH sessions spend their prompt.
The analyzer is in-process Swift. `go/` is only the self-updater. There is no daemon.
The window is `promptscope-gpui` in the sibling repo `ns-gpui`. This repo has no UI.

How the Kit and the CLI fit together is described in `ARCHITECTURE.md`.

- `macos/Sources/PromptscopeKit` — models, parsers, library scan. No UI imports. Unit-tested.
- `macos/Sources/promptscope-cli` — `report`, `scan`, and `update` (execs the Go updater).
- `go/cmd/promptscope` — `promptscope update` only. Scan and report stay in Swift.
- `Taskfile.yml` is the entry point: `task test`, `task cli:install`, `task release:build`, `task release:publish`.

## Sharp edges

- A digest stops at the first real user query. Overview skill read counts stay 0 until that session is opened and the full report replaces the digest.
- Token figures labeled `~` are `byte / 4`, not the provider tokenizer. Kiro CLI context % × window is a separate number when the sidecar has it.
- Grok does not inline MCP tool schemas. The MCP measure is the server blurb in the reminder.
- Standing skills, MCP, and rules are last-wins. Transcript bytes sum every copy. The system chat line duplicates `system_prompt.txt`; standing uses the file size.
- Empty Kiro CLI transcripts are skipped. `/tmp` and subagent sessions are hidden by default. Nested OMP/Pi jsonl files are subagents.
- Pi stores the standing prompt in `system.sections`. OMP stores only `system-prompt-digest` plus usage (`input`, `contextPercent`, `contextSnapshot.nonMessageTokens`). Devin CLI stores system steps and `tool_definitions` in the ATIF transcript; `prompt_tokens` on the last agent step is the recorded prompt size.
- DSH stores `session.v4.jsonl`, often `.zstd`, under `~/.dsh/sessions`. Only v4 is read. The standing prompt is the rendered `system/message` plus role-tagged `user/message` rows. `delegationDepth > 0` is a subagent. `inputTokens` on the last assistant message is the recorded prompt size. The catalog has no `SKILL.md` path, so disk size and read count stay empty.
- Trajectory: every analyzer fills `TrajectoryEntry` through the `[TrajectoryEntry].add/close` helpers in `Models.swift` and reads clocks through `Clock.millis` (ISO strings, epoch seconds, epoch ms). Kinds: `user reasoning assistant tool subagent compaction approval retry error job notice`. `failed` marks a failed tool/request/turn, `tokens` is the recorded prompt size at that event. `close` ignores a zero span, so a same-instant call/result shows no duration.
- Where each agent's trajectory comes from: Grok `updates.jsonl` (ACP stream; skipped hook rows before parse; falls back to `chat_history.jsonl`, no clock). Kiro IDE `messages.jsonl` (approvals, subagents, credits; tool rows have no duration, replies show the wait since the last event). Kiro CLI `.jsonl` plus the `.json` sidecar: only the prompt and each turn's end are stamped, so events are interpolated inside the turn and flagged in a note. Pi/OMP: Pi stamps messages with the request start, OMP records `duration`/`ttft`/`completedAt` and `tool_execution_start`; compactions, mode/model changes, guard redirects, and `session_exit` are events. Devin: the agent step stamp is the END of the step, so only the step right after a user message has a clean model latency; background waits come from "No output produced after N seconds". DSH: `step/start`→`assistant/message` is the think time; also retries, job settle, compaction summary, turn end reason.
- Skill names require a path that contains `/skills/` and a real `SKILL.md` segment. `but` is a real GitButler skill, not noise.
- `VERSION` is the release source of truth. `task release:build` tests and writes `dist/`. `task release:publish` and a `v*` tag upload the CLI, the updater, and `SHA256SUMS`. Do not commit `dist/`.
- `promptscope update` is the Go binary next to the versioned CLI (`promptscope-update-X.Y.Z`). It refuses a binary that is not that install, refuses a downgrade, and checks the GitHub asset digest before swapping the symlink. The Swift CLI's `--version` line is `promptscope X.Y.Z`; the release script stamps `releaseVersion` from `VERSION` for that build and restores the source.
