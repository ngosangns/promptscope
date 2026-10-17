import PromptscopeKit
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            NavigationSplitView {
                SidebarView()
                    .navigationSplitViewColumnWidth(min: 280, ideal: 320, max: 440)
            } detail: {
                detail
            }
            .navigationSplitViewStyle(.balanced)
            StatusBar()
        }
        .onChange(of: model.selectedID) { _, _ in
            model.loadSelected()
        }
    }

    @ViewBuilder
    private var detail: some View {
        if model.selectedID == nil {
            OverviewView()
        } else if let report = model.report {
            SessionDetailView(report: report)
        } else {
            WorkingView(message: "Đang đọc session")
        }
    }
}

struct StatusBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: Theme.Space.sm) {
            if model.isScanning || model.measureProgress != nil {
                ProgressView().controlSize(.small)
                Text(model.measureLabel.isEmpty ? "Đang quét session…" : model.measureLabel)
                    .lineLimit(1)
            } else {
                Image(systemName: Icon.scope)
                    .foregroundStyle(Theme.brandA)
                    .imageScale(.small)
                Text(footer)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, Theme.Space.lg)
        .frame(height: 28)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private var footer: String {
        var parts = ["\(model.sessions.count) trên đĩa", "\(model.filtered.count) đang xem"]
        if model.skippedEmptyCLI > 0 {
            parts.append("bỏ \(model.skippedEmptyCLI) CLI rỗng")
        }
        return parts.joined(separator: " · ")
    }
}
