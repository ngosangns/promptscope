import PromptscopeKit
import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @FocusState private var searchFocused: Bool

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            PaneHeader(title: "Thư viện", systemImage: nil) {
                WordmarkLogo(markSize: 20)
            }
            searchField
            sourceList
            filters
            progressStrip
            sessionList
        }
        .background(.background)
    }

    private var sourceList: some View {
        let counts = model.sourceCounts
        let total = counts.values.reduce(0, +)
        return VStack(spacing: 2) {
            sourceRow(title: "Tất cả", count: total, tint: .secondary, selected: model.source == nil) {
                model.source = nil
            }
            ForEach(AgentSource.allCases) { source in
                sourceRow(
                    title: source.label,
                    count: counts[source] ?? 0,
                    tint: Theme.agent(source),
                    selected: model.source == source
                ) {
                    model.source = source
                    if let selected = model.sessions.first(where: { $0.id == model.selectedID }),
                       selected.source != source {
                        model.selectedID = nil
                    }
                }
            }
        }
        .padding(.horizontal, Theme.Space.sm)
        .padding(.bottom, Theme.Space.sm)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Nguồn")
    }

    private func sourceRow(
        title: String,
        count: Int,
        tint: Color,
        selected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: Theme.Space.sm) {
                Circle()
                    .fill(tint)
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)
                Text(title)
                Spacer(minLength: Theme.Space.sm)
                Text("\(count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
            .padding(.horizontal, Theme.Space.sm)
            .padding(.vertical, 5)
            .background(
                selected ? Color.accentColor.opacity(0.16) : Color.clear,
                in: RoundedRectangle(cornerRadius: Theme.Radius.sm)
            )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var filters: some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Picker("Thư mục", selection: $model.workspace) {
                Text("Mọi thư mục").tag(String?.none)
                ForEach(model.workspaces, id: \.cwd) { item in
                    Text(item.label).tag(Optional(item.cwd))
                }
            }
            .labelsHidden()
            .accessibilityLabel("Thư mục")

            Toggle("Ẩn /tmp và subagent", isOn: $model.hideNoise)
                .font(.caption)
                .toggleStyle(.checkbox)

            Button { model.reload() } label: {
                Label("Quét lại", systemImage: Icon.reload)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(model.isScanning)
        }
        .padding(.horizontal, Theme.Space.md)
        .padding(.vertical, Theme.Space.sm)
    }

    private var searchField: some View {
        @Bindable var model = model
        return HStack(spacing: Theme.Space.xs) {
            Image(systemName: Icon.search)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Tìm phiên, repo, model", text: $model.query)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .accessibilityLabel("Tìm phiên")
            if !model.query.isEmpty {
                Button { model.query = "" } label: {
                    Label("Xóa", systemImage: Icon.close)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .font(.caption)
            }
            Button("Focus Search") { searchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .frame(width: 0, height: 0)
                .opacity(0)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, Theme.Space.sm)
        .padding(.vertical, 6)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: Theme.Radius.sm))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.sm).strokeBorder(.separator))
        .padding(.horizontal, Theme.Space.md)
        .padding(.bottom, Theme.Space.sm)
    }

    private var progressStrip: some View {
        ZStack(alignment: .top) {
            Divider()
            if model.isScanning, model.measureProgress == nil {
                ProgressView()
                    .progressViewStyle(.linear)
                    .accessibilityLabel("Đang quét")
            } else if let progress = model.measureProgress {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .accessibilityLabel(model.measureLabel)
            }
        }
        .frame(height: 3)
    }

    private var sessionList: some View {
        @Bindable var model = model
        return List(selection: $model.selectedID) {
            Section {
                Button {
                    model.selectedID = nil
                } label: {
                    Label("Tổng quan", systemImage: Icon.overview)
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
    }
}

struct SessionRow: View {
    let ref: SessionRef
    let digest: SessionDigest?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Text(ref.title)
                .font(.body)
                .lineLimit(2)
            HStack(spacing: 6) {
                Circle()
                    .fill(Theme.agent(ref.source))
                    .frame(width: 6, height: 6)
                Text(ref.source.label)
                if !ref.cwd.isEmpty {
                    Text(Paths.short(ref.cwd))
                }
                if let model = ref.model {
                    Text(model)
                }
                Spacer(minLength: Theme.Space.xs)
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
        .padding(.vertical, Theme.Space.xs)
    }
}
