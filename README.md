<p align="center"><img src="docs/icon.png" alt="Promptscope" width="128"></p>

# Promptscope

Đo phần nào đang chiếm context của session **Grok**, **Kiro**, **OMP**, **Pi**, **Devin** và **DSH** trên máy này.

Nó đọc log local. Không gửi session đi đâu.

Phần đo nằm trong `macos/Sources/PromptscopeKit`. CLI là `macos/Sources/promptscope-cli`. Cửa sổ là `promptscope-gpui` trong repo anh em `ns-gpui`. Cách các lớp phụ thuộc nhau nằm trong [ARCHITECTURE.md](ARCHITECTURE.md).

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

**DSH** (`~/.dsh/sessions`) ghi một log append-only `session.v4.jsonl`, thường nén `.zstd`. Prompt đứng là `system/message` đã render, cộng các `user/message` phân vai: luật, catalog skill, snapshot runtime. Schema tool nằm trong `request/header` mới nhất. `inputTokens` của lượt assistant cuối là token đầu vào. Chỉ đọc v4. Session không có turn, và session có `delegationDepth` lớn hơn 0, bị bỏ qua hoặc đánh dấu subagent.

Token ghi `~` là `byte / 4`. Đó không phải tokenizer của model. Với Kiro CLI, nếu sidecar có cửa sổ token thì số đó được ghi riêng.

## Tải

Bản darwin-arm64: <https://github.com/ngosangns/promptscope/releases/latest>

`task release:build` chạy test và ghi CLI vào `dist/`. `task release:publish` đăng release đó. Đẩy tag `v*` thì GitHub Actions đóng gói cùng asset.

Lần cài đầu đặt binary vào `~/.local/share/promptscope/bin/promptscope-X.Y.Z` và trỏ `~/.local/bin/promptscope` tới đó. Cạnh nó là `promptscope-update-X.Y.Z`. Sau đó:

```bash
promptscope update --check
promptscope update
```

`promptscope update` chỉ thay symlink do lần cài đó tạo. Nó kiểm digest `sha256` GitHub của cả CLI và updater, chạy `--version` trên bản mới, rồi đổi tên file vào chỗ. Không ghi đè inode đang chạy. Không hạ version, trừ `--force` khi bằng version hiện tại.

## Chạy

Từ thư mục repo:

```bash
task test
task cli:install
```

`task --list` liệt kê mọi lệnh.

In một session ra terminal, từ `macos/`:

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

`task cli:install` đặt CLI release vào `~/.local/share/promptscope/bin/` và trỏ `~/.local/bin/promptscope` tới đó.

Lần quét đầu đọc prefix của từng session Grok (system prompt, catalog skill, MCP) và cache vào `~/Library/Application Support/Promptscope/digests.json`. Mở một phiên thì đọc full transcript của phiên đó.

Mặc định ẩn session trong `/tmp` và subagent.
