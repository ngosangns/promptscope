<p align="center"><img src="docs/icon.png" alt="Promptscope" width="128"></p>

# Promptscope

App macOS đo phần nào đang chiếm context của session **Grok** và **Kiro** trên máy này.

Nó đọc log local. Không gửi session đi đâu.

Phần đo nằm trong `macos/Sources/PromptscopeKit` (không import UI). App SwiftUI ở `macos/Sources/promptscope-app`, tách `App`, `Design`, `Features`, `Model` giống [synca](../synca/macos) và [hearth](../hearth/apps/macos-swiftui).

## Promptscope đo gì

**Prompt đứng** là phần model phải mang trước nội dung hội thoại:

| Thành phần | Grok lấy từ |
| --- | --- |
| System prompt | `system_prompt.txt`, tách theo thẻ chiếm trọn một dòng |
| Skill | đoạn catalog trong `chat_history.jsonl` (`skills are available`), cộng kích thước `SKILL.md` trên đĩa và số lần tool đọc file đó |
| MCP | đoạn mô tả server trong system reminder, trạng thái từ `events.jsonl` |
| Luật và user info | message `<user_rules>` / `<user_info>` |
| Định nghĩa tool | `tool_definitions.json` |

Schema từng tool MCP **không** nằm trong prompt. Grok nạp chúng qua `search_tool`. Số MCP ở đây là đoạn mô tả server.

**Transcript** là tổng chữ trong log (user, assistant, kết quả tool, reasoning đã lưu). Compaction có thể làm context thực tế nhỏ hơn file.

**Kiro IDE** không ghi system prompt đầy đủ. App đo file steering, các `SKILL.md` agent đã đọc, kết quả tool, và `contextUsage`.

**Kiro CLI** không lưu system prompt. App đọc `context %` và cửa sổ token trong sidecar JSON, rồi tách prompt / assistant / tool trong `.jsonl`. Session CLI có transcript rỗng bị bỏ qua.

**Pi** (`~/.pi/agent/sessions`) ghi prompt đứng trong message `system.sections`: preamble, rules, project context, catalog skill, MCP, và schema `toolsAdded`.

**OMP** (`~/.omp/agent/sessions`) dùng cùng định dạng JSONL nhưng không lưu nội dung system prompt, chỉ một `system-prompt-digest`. App lấy token đầu vào và `context %` từ usage của lượt assistant cuối, rồi đếm `SKILL.md` đã đọc. File jsonl nằm trong thư mục kèm theo là subagent.

**Devin CLI** (`~/.local/share/devin/cli/transcripts`) ghi system step: identity, catalog MCP, `<available_skills>`, luật, và `tool_definitions`. `prompt_tokens` của lượt agent cuối là token đầu vào.

Token ghi `~` là `byte / 4`. Đó không phải tokenizer của model. Với Kiro CLI, nếu sidecar có cửa sổ token thì số đó được ghi riêng.

## Chạy

Từ thư mục repo:

```bash
task app:test
task app:build
open macos/promptscope.app
```

`task dev` chạy bản debug. `task app:install` tắt bản đang mở rồi chép vào `/Applications`. `task --list` liệt kê mọi lệnh.

In một session ra terminal, từ `macos/`:

```bash
swift run promptscope-cli report grok ~/.grok/sessions/<cwd>/<id>
swift run promptscope-cli report kiro-ide ~/.kiro/sessions/<workspace>/sess_<id>
swift run promptscope-cli report kiro-cli ~/.kiro/sessions/cli/<id>.json
swift run promptscope-cli report omp ~/.omp/agent/sessions/<cwd>/<id>.jsonl
swift run promptscope-cli report pi ~/.pi/agent/sessions/<cwd>/<id>.jsonl
swift run promptscope-cli report devin ~/.local/share/devin/cli/transcripts/<id>.json
swift run promptscope-cli scan
```

`task cli:install` chép CLI release vào `~/.local/bin/promptscope`.

Lần quét đầu đọc prefix của từng session Grok (system prompt, catalog skill, MCP) và cache vào `~/Library/Application Support/Promptscope/digests.json`. Mở một phiên thì đọc full transcript của phiên đó.

Mặc định ẩn session trong `/tmp` và subagent. Bật lại bằng checkbox ở sidebar.
