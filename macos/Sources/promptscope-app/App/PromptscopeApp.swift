import AppKit
import SwiftUI

@main
struct PromptscopeApp: App {
    @State private var model = AppModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("Promptscope", id: "main") {
            RootView()
                .environment(model)
                .task { model.start() }
                .frame(minWidth: 1080, minHeight: 640)
        }
        .defaultSize(width: 1280, height: 820)
        .commands { AppCommands(model: model) }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct AppCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(after: .sidebar) {
            Button("Tổng quan") { model.selectedID = nil }
                .keyboardShortcut("1", modifiers: .command)
            Button("Quét lại") { model.reload() }
                .keyboardShortcut("r")
            Button("Hiện trong Finder") { model.revealSelected() }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            Button("Chép phân tích") { model.copyReport() }
                .keyboardShortcut("c", modifiers: [.command, .shift])
            Divider()
            Button(model.hideNoise ? "Hiện tạm và subagent" : "Ẩn tạm và subagent") {
                model.hideNoise.toggle()
            }
        }
    }
}
