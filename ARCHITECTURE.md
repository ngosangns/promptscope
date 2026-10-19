# Cách app này được dựng

Promptscope dựng theo cùng một cách với [Zed](https://github.com/zed-industries/zed): một lõi không có UI, một cửa sổ chỉ ghép các panel, và một binary CLI thứ hai nói chuyện với cùng lõi đó. Zed viết editor bằng Rust và GPUI vì web view không giữ được ngân sách khung hình. Promptscope đọc log local và đếm byte. Lõi là target Swift `PromptscopeKit`. Cửa sổ là SwiftUI. GPUI là GPL-3.0 và không phải dependency.

Đây là app gần Zed nhất trong ba app: CLI và cửa sổ cùng link một library, đúng vai `crates/project` được cả `crates/zed` và `crates/cli` dùng. Không có daemon.

## Chiều phụ thuộc

```
promptscope-app      crates/zed           menu, action, session nào đang mở
   │  Design         crates/ui + theme    token, màu từng lát cắt
   ▼
PromptscopeKit      crates/project       parser từng agent, quét thư viện, đếm
   ▲
promptscope-cli     crates/cli           scan và report. Không có SwiftUI.
```

`promptscope-app` và `promptscope-cli` được import `PromptscopeKit`. Chỉ app import `NSShell`. `PromptscopeKit` không import SwiftUI và không import hai target kia. View gọi `AppModel`. `AppModel` gọi Kit. Parser không nằm trong view.

`NSShell` là package private [ns-shell](https://github.com/ngosangns/ns-shell), để cạnh repo này. Nó giữ token, component, toast, confirm và các lớp cửa sổ dùng chung với hearth và synca. Màu từng agent và từng lát cắt vẫn là extension của `Theme` trong app này.

Mỗi file `*Analyzer.swift` là một ngôn ngữ theo nghĩa `crates/languages`: cùng một kết quả (`Report`), một định dạng log riêng. Thêm một agent là thêm một analyzer và một case trong CLI, không sửa shell.

## Cửa sổ

Zed gọi gốc của cửa sổ là `Workspace`, với dock trái, pane giữa, dock phải, thanh trạng thái, lớp toast và lớp modal. Promptscope dùng đúng các vai đó, trừ hai lớp chưa có việc:

| Zed | Cửa sổ này |
| --- | --- |
| Dock trái, `ProjectPanel` | `SidebarView` — một dòng mỗi agent, rồi danh sách session |
| `Pane` giữa | `OverviewView` khi chưa chọn, `SessionDetailView` khi đã chọn |
| Dock phải / dưới | không có. Log không phải một panel thứ hai. |
| `StatusBar` | số session trên đĩa, số đang xem, tiến độ quét |
| `toast_layer`, `modal_layer` | chưa có. Chưa có hành động phá dữ liệu nên chưa có confirm. |

`PromptscopeApp` sở hữu `AppModel`. Quét đĩa và đọc transcript chạy trong `Task`, tương đương foreground executor của GPUI: main actor không đọc cả thư mục session đồng bộ. `PromptscopeCommand` là danh sách action. Menu chỉ gắn phím.

## Phạm vi

Trong phạm vi: đo prompt đứng và transcript của Grok, Kiro IDE, Kiro CLI, OMP, Pi, Devin trên máy này. Không gửi session đi đâu.

Ngoài phạm vi: GPUI, command palette, extension host, daemon, collaboration, tokenizer của nhà cung cấp (số `~` là `byte / 4`), và một bản parser thứ hai trong CLI. CLI gọi Kit.

## GitHub

`ci.yml` chạy `swift test` trên macOS. `release.yml` đóng gói `.app` và CLI khi có tag `v*`. Một workflow cho test và một workflow cho phát hành là đủ. Zed tách hàng chục workflow vì họ có collab server, extension registry và nhiều hệ điều hành. Promptscope không có những thứ đó.
