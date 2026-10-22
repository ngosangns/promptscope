---
name: promptscope
description: Measure how local Grok, Kiro, OMP, Pi, Devin, and DSH sessions spend their prompt. Use when the user asks which session is heavy, why context is full, what skills or MCP cost, or to find a session by folder or title.
---

# Promptscope

Read-only measure of local agent sessions. The binary never sends a session anywhere.

Do not edit this installed copy. Edit `skills/promptscope` in the repository, then run `promptscope skill install`. Confirm with `promptscope skill check`.

## When to use

Use this skill when the user asks about prompt size, context fullness, standing prompt, skill cost, or MCP cost for a session on this machine. Do not use it to rewrite a transcript, or to debug an agent that is not Grok, Kiro, OMP, Pi, Devin, or DSH.

`promptscope skill install` is the only mutating command. Run it only when the user asked to install or refresh this skill.

## Privacy

Session logs hold private text. Default to metadata:

- `promptscope sessions list --json` returns titles, paths, and sizes. Titles are user text. The transcript is not included.
- `promptscope report <id> --summary --json` returns byte totals, estimated tokens, context numbers, and the top heavy tool names.
- `promptscope report <id> --no-text --json` keeps the full report shape and nulls free-text fields that can hold transcript, user, or tool content.

Read transcript text only when the user asked to see what was said. That is `promptscope report <id> --json` with no extra flags, or `--section entries`, `--section turns`, or `--section sections` without `--no-text`. Do not paste transcript text into another tool, and do not pass a report that still contains text into a shared channel.

## Recipes

### Which session used the most standing prompt today

```
promptscope sessions list --since 1d --limit 30 --json
promptscope report <id> --summary --json
```

Sort the summaries by `standingBytes`. `<id>` is `source:session` from the list, the same id the window uses.

### Why is session X context so full

```
promptscope sessions list --query "X" --json
promptscope report <id> --summary --json
promptscope report <id> --section standing,skills,mcp,tools --no-text --json
```

`contextPercent` and `promptTokens` are what the log recorded. `estimatedTokens` is `standingBytes / 4`, not the model tokenizer. A high skill or MCP share means the standing prompt is catalog weight. A high transcript means the conversation itself is the cost.

### Compare skill and MCP cost across sessions

```
promptscope sessions list --cwd /absolute/project --json
promptscope report <id> --section skills,mcp --no-text --json
```

Repeat `report` for each id. Compare `catalogBytes`. Names stay. Summaries and blurbs are null under `--no-text`.

### Find a session by folder or title

```
promptscope sessions list --cwd /absolute/project --query "title words" --json
promptscope sessions show <id> --json
```

`--query` matches title, cwd, id, model, and agent. It does not search the transcript. Subagents and `/tmp` sessions stay hidden unless `--include-subagents` or `--include-temporary` is set.

## Commands

| Command | Kind | Prints |
| --- | --- | --- |
| `promptscope sessions list --json` | read | one row per session |
| `promptscope sessions show <id> --json` | read | one row and summary numbers |
| `promptscope scan --json` | read | counts per source |
| `promptscope report <id> --summary --json` | read | totals only |
| `promptscope report <source> <path> --json` | read | full report, the shape the window reads |
| `promptscope skill check --json` | read | installed copy versus this binary |
| `promptscope skill install` | mutates | writes this skill |
| `promptscope schema --json` | read | command list and JSON Schemas |
| `promptscope version --json` | read | name, version, schemaVersion, commit |

`promptscope scan` without `--json` stays plain text. `promptscope report <source> <path> --json` without the new flags stays the object the window parses. The window passes `<source>:<id>` as the source argument and the locator as the path.

## Failure

| Exit | code | Meaning |
| --- | --- | --- |
| 2 | usage | bad command, argument, or flag |
| 3 | unavailable | session or file missing, or the skill directory is missing |
| 4 | protocol | the log is not valid for that source |
| 5 | failed | the operation ran and failed |
| 8 | conflict | `skill check` found drift |

With `--json`, a failure prints one `{"error":{"code","exit","message"}}` object on stdout. `hint` is optional. `promptscope skill check --json` is the exception: drift still prints the check object and exits 8. Without `--json`, errors are `promptscope: …` on stderr.

## Verification

`promptscope schema --json` lists every command. `promptscope skill check` exits 0 when the installed files match the binary and 8 when they do not. Tests in the repository use fixture directories and never read this machine's real session logs.
