import PromptscopeKit
import SwiftUI

struct OverviewView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Prompt đứng của thư viện")
                        .font(.largeTitle.weight(.semibold))
                    Text("Phần luôn chiếm context trước khi cuộc hội thoại bắt đầu: system prompt, catalog skill, mô tả MCP, luật người dùng, schema tool. Token là byte/4.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !model.scanNotes.isEmpty {
                    Text(model.scanNotes.joined(separator: " "))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 12)], spacing: 12) {
                    Metric(title: "Phiên đang xem", value: "\(model.filtered.count)", caption: "trong \(model.sessions.count) session trên đĩa")
                    Metric(title: "Đã đo", value: "\(model.measured.count)", caption: model.measureLabel.isEmpty ? "khớp cache hoặc vừa đo" : model.measureLabel)
                    Metric(title: "Prompt đứng giữa", value: medianText, caption: "median của các phiên đã đo")
                    Metric(title: "CLI rỗng đã bỏ", value: "\(model.skippedEmptyCLI)", caption: "jsonl 0 byte, không có transcript")
                }

                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 16) { taxColumns }
                    VStack(alignment: .leading, spacing: 16) { taxColumns }
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
                                    HStack(spacing: 10) {
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
            .padding(24)
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
                VStack(spacing: 8) {
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
