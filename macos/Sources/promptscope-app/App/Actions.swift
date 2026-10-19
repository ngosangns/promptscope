import SwiftUI
import NSShell

/// Một lệnh, một tên, một phím, một lời gọi.
/// Menu trong `PromptscopeApp` chỉ gắn các case này, cùng cách Zed tách
/// `actions!` khỏi chỗ vẽ menu.
enum PromptscopeCommand: String {
    case overview
    case reload
    case reveal
    case copyReport
    case toggleNoise

    @MainActor
    func title(_ model: AppModel) -> String {
        switch self {
        case .overview: "Tổng quan"
        case .reload: "Quét lại"
        case .reveal: "Hiện trong Finder"
        case .copyReport: "Chép phân tích"
        case .toggleNoise: model.hideNoise ? "Hiện tạm và subagent" : "Ẩn tạm và subagent"
        }
    }

    var shortcut: KeyEquivalent? {
        switch self {
        case .overview: "1"
        case .reload: "r"
        case .reveal: "o"
        case .copyReport: "c"
        case .toggleNoise: nil
        }
    }

    var modifiers: EventModifiers {
        switch self {
        case .reveal, .copyReport: [.command, .shift]
        default: .command
        }
    }

    @MainActor
    func run(_ model: AppModel) {
        switch self {
        case .overview: model.selectedID = nil
        case .reload: model.reload()
        case .reveal: model.revealSelected()
        case .copyReport: model.copyReport()
        case .toggleNoise: model.hideNoise.toggle()
        }
    }
}
