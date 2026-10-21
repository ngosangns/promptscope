<p align="center"><img src="docs/icon.png" alt="Promptscope" width="128"></p>

# Promptscope

Measures what takes up the context of your **Grok**, **Kiro**, **OMP**, **Pi**, **Devin** and **DSH** sessions on this machine.

It reads local logs. It never sends a session anywhere.

The measuring code lives in `macos/Sources/PromptscopeKit`. The CLI is `macos/Sources/promptscope-cli`. The window is `promptscope-gpui` in the sibling repo `ns-gpui`. How the layers depend on each other is described in [ARCHITECTURE.md](ARCHITECTURE.md).

## What Promptscope measures

The **standing prompt** is what the model must carry before any conversation content:

| Component | Where Grok gets it |
| --- | --- |
| System prompt | `system_prompt.txt`, split on tags that take a whole line |
| Skills | the catalog block in `chat_history.jsonl` (`skills are available`), plus the size of `SKILL.md` on disk and how many times a tool read that file |
| MCP | the server description block in the system reminder, status from `events.jsonl` |
| Rules and user info | the `<user_rules>` / `<user_info>` messages |
| Tool definitions | `tool_definitions.json` |

Individual MCP tool schemas are **not** part of the prompt. Grok loads them through `search_tool`. The MCP figure here is the server description block.

The **transcript** is the total text in the log (user, assistant, tool results, saved reasoning). Compaction can make the real context smaller than the file.

**Kiro IDE** does not record the full system prompt. The app measures steering files, the `SKILL.md` files the agent read, tool results, and `contextUsage`.

**Kiro CLI** does not store the system prompt. The app reads `context %` and the token window from the sidecar JSON, then splits prompt / assistant / tool in the `.jsonl`. CLI sessions with an empty transcript are skipped.

**Pi** (`~/.pi/agent/sessions`) records the standing prompt in the `system.sections` message: preamble, rules, project context, skill catalog, MCP, and the `toolsAdded` schema.

**OMP** (`~/.omp/agent/sessions`) uses the same JSONL format but does not store the system prompt text, only a `system-prompt-digest`. The app takes input tokens and `context %` from the usage of the last assistant turn, then counts the `SKILL.md` files that were read. A jsonl file inside the accompanying directory is a subagent.

**Devin CLI** (`~/.local/share/devin/cli/transcripts`) records system steps: identity, MCP catalog, `<available_skills>`, rules, and `tool_definitions`. `prompt_tokens` of the last agent turn is the input token count.

**DSH** (`~/.dsh/sessions`) writes one append-only log, `session.v4.jsonl`, usually compressed as `.zstd`. The standing prompt is the rendered `system/message` plus the role-tagged `user/message` rows: rules, skill catalog, runtime snapshot. The tool schema is in the latest `request/header`. `inputTokens` of the last assistant turn is the input token count. Only v4 is read. Sessions with no turns are skipped, and sessions with `delegationDepth` greater than 0 are skipped or marked as subagents.

Tokens marked `~` are `byte / 4`. That is not the model's tokenizer. For Kiro CLI, if the sidecar has a token window, that number is reported separately.

## Download

darwin-arm64 build: <https://github.com/ngosangns/promptscope/releases/latest>

`task release:build` runs the tests and writes the CLI to `dist/`. `task release:publish` publishes that release. Pushing a `v*` tag makes GitHub Actions package the same assets.

The first install puts the binary at `~/.local/share/promptscope/bin/promptscope-X.Y.Z` and points `~/.local/bin/promptscope` at it. Next to it sits `promptscope-update-X.Y.Z`. After that:

```bash
promptscope update --check
promptscope update
```

`promptscope update` only replaces a symlink created by that install. It checks the GitHub `sha256` digest of both the CLI and the updater, runs `--version` on the new build, then renames the file into place. It never overwrites a running inode. It never downgrades, except `--force` when the version is equal to the current one.

## Run

From the repo directory:

```bash
task test
task cli:install
```

`task --list` lists every command.

To print one session to the terminal, from `macos/`:

```bash
swift run promptscope-cli report grok ~/.grok/sessions/<cwd>/<id>
swift run promptscope-cli report kiro-ide ~/.kiro/sessions/<workspace>/sess_<id>
swift run promptscope-cli report kiro-cli ~/.kiro/sessions/cli/<id>.json
swift run promptscope-cli report omp ~/.omp/agent/sessions/<cwd>/<id>.jsonl
swift run promptscope-cli report pi ~/.pi/agent/sessions/<cwd>/<id>.jsonl
swift run promptscope-cli report devin ~/.local/share/devin/cli/transcripts/<id>.json
swift run promptscope-cli report dsh ~/.dsh/sessions/<cwd>/<id>/session.v4.jsonl.zstd
swift run promptscope-cli scan
```

`task cli:install` puts the release CLI in `~/.local/share/promptscope/bin/` and points `~/.local/bin/promptscope` at it.

The first scan reads the prefix of every Grok session (system prompt, skill catalog, MCP) and caches it in `~/Library/Application Support/Promptscope/digests.json`. Opening a session reads its full transcript.

Sessions under `/tmp` and subagents are hidden by default.
