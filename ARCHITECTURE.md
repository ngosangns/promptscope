# Cách repo này được dựng

Promptscope đọc log local và đếm byte. Lõi là target Swift `PromptscopeKit`. CLI là `promptscope-cli` và nói chuyện với cùng lõi đó. Cửa sổ là `promptscope-gpui` trong repo anh em `ns-gpui`. Repo này không có UI.

## Chiều phụ thuộc

```
promptscope-cli     scan và report
   │
   ▼
PromptscopeKit      parser từng agent, quét thư viện, đếm
```

`promptscope-cli` import `PromptscopeKit`. Kit không import SwiftUI và không import CLI. Parser không nằm trong CLI. Cửa sổ gọi CLI đã cài, không link Kit.

`promptscope update` không nằm trong Kit. CLI Swift tìm `promptscope-update-X.Y.Z` cạnh chính nó và exec binary Go đó. Binary Go tải asset `promptscope-vX.Y.Z-darwin-arm64` và `promptscope-update-vX.Y.Z-darwin-arm64`, kiểm digest GitHub, rồi đổi symlink `~/.local/bin/promptscope`.

Mỗi file `*Analyzer.swift` là một định dạng log riêng, cùng một kết quả (`Report`). Thêm một agent là thêm một analyzer và một case trong CLI.

## Phạm vi

Trong phạm vi: đo prompt đứng và transcript của Grok, Kiro IDE, Kiro CLI, OMP, Pi, Devin, DSH trên máy này. Không gửi session đi đâu.

Ngoài phạm vi: UI trong repo này, command palette, extension host, daemon, collaboration, tokenizer của nhà cung cấp (số `~` là `byte / 4`), và một bản parser thứ hai trong CLI.

## GitHub

`ci.yml` chạy `swift test` trên macOS. `release.yml` đóng gói CLI khi có tag `v*`.
