import AppKit
import SwiftUI
import NSShell

@main
struct PromptscopeApp: App {
    @State private var model = AppModel()
    @NSApplicationDelegateAdaptor(ShellAppDelegate.self) private var delegate

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

struct AppCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(after: .sidebar) {
            command(.overview)
            command(.reload)
            command(.reveal)
            command(.copyReport)
            Divider()
            command(.toggleNoise)
        }
    }

    @ViewBuilder
    private func command(_ id: PromptscopeCommand) -> some View {
        if let shortcut = id.shortcut {
            Button(id.title(model)) { id.run(model) }
                .keyboardShortcut(shortcut, modifiers: id.modifiers)
        } else {
            Button(id.title(model)) { id.run(model) }
        }
    }
}
