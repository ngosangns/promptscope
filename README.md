# Promptscope

App macOS đo phần nào đang chiếm context của session **Grok** và **Kiro** trên máy này.

Nó đọc log local. Không gửi session đi đâu.

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

Token ghi `~` là `byte / 4`. Đó không phải tokenizer của model. Với Kiro CLI, nếu sidecar có cửa sổ token thì số đó được ghi riêng.

## Chạy

```bash
cd promptscope
swift test
make
open promptscope.app
```

Cài vào `/Applications`:

```bash
make install
```

In một session ra terminal:

```bash
swift run promptscope-cli report grok ~/.grok/sessions/<cwd>/<id>
swift run promptscope-cli report kiro-ide ~/.kiro/sessions/<workspace>/sess_<id>
swift run promptscope-cli report kiro-cli ~/.kiro/sessions/cli/<id>.json
swift run promptscope-cli scan
```

Lần quét đầu đọc prefix của từng session Grok (system prompt, catalog skill, MCP) và cache vào `~/Library/Application Support/Promptscope/digests.json`. Mở một phiên thì đọc full transcript của phiên đó.

Mặc định ẩn session trong `/tmp` và subagent. Bật lại bằng checkbox ở sidebar.
