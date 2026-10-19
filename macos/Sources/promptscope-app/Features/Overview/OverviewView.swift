import PromptscopeKit
import SwiftUI
import NSShell

struct OverviewView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.sessions.isEmpty && model.isScanning {
            WorkingView(message: "Đang quét session…")
        } else if model.sessions.isEmpty {
            StateView(
                systemImage: Icon.scope,
                title: "Chưa thấy session",
                message: "Promptscope đọc session Grok, Kiro, OMP, Pi và Devin trên máy này."
            ) {
                Button { model.reload() } label: {
                    Label("Quét lại", systemImage: Icon.reload)
                }
                .buttonStyle(.borderedProminent)
            }
        } else {
            content
        }
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.lg) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Prompt đứng của thư viện")
                        .font(.largeTitle.weight(.semibold))
                    Text("System prompt, catalog skill, mô tả MCP, luật và schema tool của Grok, Kiro, OMP, Pi, Devin. Token ghi ~ là byte/4. Số không có ~ là token agent đã ghi.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !model.scanNotes.isEmpty {
                    Text(model.scanNotes.joined(separator: " "))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: Theme.Space.md)], spacing: Theme.Space.md) {
                    Metric(title: "Phiên đang xem", value: "\(model.filtered.count)", caption: "trong \(model.sessions.count) session trên đĩa")
                    Metric(title: "Đã đo", value: "\(model.measured.count)", caption: model.measureLabel.isEmpty ? "khớp cache hoặc vừa đo" : model.measureLabel)
                    Metric(title: "Prompt đứng giữa", value: medianText, caption: "median của các phiên đã đo")
                    Metric(title: "CLI rỗng đã bỏ", value: "\(model.skippedEmptyCLI)", caption: "jsonl 0 byte, không có transcript")
                }

                SectionCard(title: "Theo nguồn", subtitle: "Bấm một dòng để lọc sidebar.") {
                    VStack(spacing: Theme.Space.sm) {
                        ForEach(agentSummary, id: \.source) { row in
                            Button {
                                model.source = row.source
                            } label: {
                                HStack(spacing: Theme.Space.sm) {
                                    Circle().fill(Theme.agent(row.source)).frame(width: 8, height: 8)
                                    Text(row.source.label).frame(width: 72, alignment: .leading)
                                    Text("\(row.count) phiên")
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Text(row.standing)
                                        .monospacedDigit()
                                    Text(row.context)
                                        .foregroundStyle(.secondary)
                                        .frame(width: 64, alignment: .trailing)
                                        .monospacedDigit()
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: Theme.Space.lg) { taxColumns }
                    VStack(alignment: .leading, spacing: Theme.Space.lg) { taxColumns }
                }

                SectionCard(title: "Session nặng nhất", subtitle: "Prompt đứng, không tính transcript.") {
                    if heaviest.isEmpty {
                        Text(model.measureProgress == nil ? "Chưa có số đo." : "Đang đo…")
                            .foregroundStyle(.secondary)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(heaviest, id: \.ref.id) { item in
                                Button {
                                    model.selectedID = item.ref.id
                                } label: {
                                    HStack(spacing: Theme.Space.sm) {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(item.ref.title).lineLimit(1)
                                            Text("\(item.ref.source.label) · \(Paths.short(item.ref.cwd))")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        Text(ByteFormat.bytes(item.bytes))
                                            .monospacedDigit()
                                        Text(ByteFormat.tokens(item.bytes))
                                            .foregroundStyle(.secondary)
                                            .monospacedDigit()
                                            .frame(width: 64, alignment: .trailing)
                                    }
                                    .padding(.vertical, 6)
                                }
                                .buttonStyle(.plain)
                                Divider()
                            }
                        }
                    }
                }
            }
            .padding(Theme.Space.xl)
            .frame(maxWidth: 980, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.thinMaterial)
    }

    private var medianText: String {
        let values = model.measured.map(\.standingBytes).filter { $0 > 0 }.sorted()
        guard !values.isEmpty else { return "—" }
        return ByteFormat.bytes(values[values.count / 2])
    }

    private struct AgentSummary {
        var source: AgentSource
        var count: Int
        var standing: String
        var context: String
    }

    private var agentSummary: [AgentSummary] {
        AgentSource.allCases.map { source in
            let refs = model.sessions.filter { $0.source == source && !(model.hideNoise && $0.isNoise) }
            let standing = refs.compactMap { model.digests[$0.id]?.standingBytes }.filter { $0 > 0 }.sorted()
            let percents = refs.compactMap { ref -> Double? in
                model.digests[ref.id]?.contextPercent ?? ref.contextPercent
            }.sorted()
            let standingText = standing.isEmpty ? "—" : ByteFormat.bytes(standing[standing.count / 2])
            let contextText = percents.isEmpty ? "—" : String(format: "%.0f%%", percents[percents.count / 2])
            return AgentSummary(source: source, count: refs.count, standing: standingText, context: contextText)
        }
    }

    private var heaviest: [(ref: SessionRef, bytes: Int)] {
        model.filtered.compactMap { ref -> (SessionRef, Int)? in
            guard let bytes = model.digests[ref.id]?.standingBytes, bytes > 0 else { return nil }
            return (ref, bytes)
        }
        .sorted { $0.1 > $1.1 }
        .prefix(8)
        .map { (ref: $0.0, bytes: $0.1) }
    }

    @ViewBuilder
    private var taxColumns: some View {
        taxCard(
            title: "Skill nặng trong prompt",
            subtitle: "Tổng byte catalog, mỗi lần một session mang skill đó.",
            rows: Array(model.skillTax.prefix(12)),
            empty: "Chưa có catalog skill. Grok nhét mô tả ngắn của mọi skill vào mỗi session."
        )
        taxCard(
            title: "MCP nặng trong prompt",
            subtitle: "Đoạn mô tả server, không phải schema từng tool.",
            rows: Array(model.mcpTax.prefix(12)),
            empty: "Chưa thấy mô tả MCP trong các phiên đã đo."
        )
    }

    private func taxCard(title: String, subtitle: String, rows: [SkillTax], empty: String) -> some View {
        SectionCard(title: title, subtitle: subtitle) {
            if rows.isEmpty {
                Text(empty).font(.callout).foregroundStyle(.secondary)
            } else {
                VStack(spacing: Theme.Space.sm) {
                    ForEach(rows) { row in
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(row.name).lineLimit(1)
                                Text("\(row.sessions) phiên · \(row.detail)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Text(ByteFormat.bytes(row.bytes))
                                .monospacedDigit()
                        }
                    }
                }
            }
        }
    }
}
