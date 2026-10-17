import PromptscopeKit
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView()
        } detail: {
            if model.selectedID == nil {
                OverviewView()
            } else if let report = model.report {
                SessionDetailView(report: report)
            } else {
                ProgressView("Đang đọc session")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationSplitViewStyle(.balanced)
        .onChange(of: model.selectedID) { _, _ in
            model.loadSelected()
        }
    }
}

struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                TextField("Tìm phiên, repo, model", text: $model.query)
                    .textFieldStyle(.roundedBorder)
                Picker("Nguồn", selection: $model.source) {
                    ForEach(SourceFilter.allCases) { filter in
                        Text(filter.label).tag(filter)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Picker("Thư mục", selection: $model.workspace) {
                    Text("Mọi thư mục").tag(String?.none)
                    ForEach(model.workspaces, id: \.cwd) { item in
                        Text(item.label).tag(Optional(item.cwd))
                    }
                }
                .labelsHidden()
                Toggle("Ẩn /tmp và subagent", isOn: $model.hideNoise)
                    .font(.caption)
                    .toggleStyle(.checkbox)
            }
            .padding(10)

            List(selection: $model.selectedID) {
                Section {
                    Button {
                        model.selectedID = nil
                    } label: {
                        Label("Tổng quan", systemImage: "chart.bar.xaxis")
                    }
                    .buttonStyle(.plain)
                }
                Section("\(model.filtered.count) phiên") {
                    ForEach(model.filtered) { ref in
                        SessionRow(ref: ref, digest: model.digests[ref.id])
                            .tag(ref.id)
                    }
                }
            }
            .listStyle(.sidebar)

            if model.isScanning {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView()
                    Text(model.measureLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(10)
            } else if let progress = model.measureProgress {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: progress)
                    Text(model.measureLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(10)
            } else {
                Text(footer)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
        }
        .navigationTitle("Promptscope")
        .toolbar {
            Button("Quét lại", systemImage: "arrow.clockwise") { model.reload() }
        }
    }

    private var footer: String {
        var parts = ["\(model.sessions.count) trên đĩa"]
        if model.skippedEmptyCLI > 0 {
            parts.append("bỏ \(model.skippedEmptyCLI) CLI rỗng")
        }
        return parts.joined(separator: " · ")
    }
}

struct SessionRow: View {
    let ref: SessionRef
    let digest: SessionDigest?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(ref.title)
                .font(.body)
                .lineLimit(2)
            HStack(spacing: 6) {
                Text(ref.source.label)
                if !ref.cwd.isEmpty {
                    Text(Paths.short(ref.cwd))
                }
                if let model = ref.model {
                    Text(model)
                }
                Spacer(minLength: 4)
                if let date = ref.updatedAt {
                    Text(date, format: .dateTime.month(.abbreviated).day().hour().minute())
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            if let digest, digest.standingBytes > 0 {
                BudgetBar(slices: digest.standing)
                    .frame(height: 6)
                Text("\(ByteFormat.bytes(digest.standingBytes)) đứng · \(ByteFormat.tokens(digest.standingBytes))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            } else if let percent = ref.contextPercent ?? digest?.contextPercent {
                Text(String(format: "context %.0f%%", percent))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .padding(.vertical, 4)
    }
}
