import AppKit
import PromptscopeKit
import SwiftUI

struct SessionDetailView: View {
    @Environment(AppModel.self) private var model
    let report: SessionReport

    var body: some View {
        let ref = report.ref
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(ref.source.label)
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Theme.color(.skills).opacity(0.18), in: Capsule())
                        Text(ref.title)
                            .font(.largeTitle.weight(.semibold))
                            .textSelection(.enabled)
                        Text(metaLine)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        if !ref.cwd.isEmpty {
                            Text(ref.cwd)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 8) {
                        Button("Hiện trong Finder") { model.revealSelected() }
                        Button("Chép phân tích") { model.copyReport() }
                    }
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 12)], spacing: 12) {
                    Metric(
                        title: "Prompt đứng",
                        value: ByteFormat.bytes(report.standingBytes),
                        caption: "\(ByteFormat.tokens(report.standingBytes)) token ước lượng"
                    )
                    Metric(
                        title: "Transcript",
                        value: ByteFormat.bytes(ref.transcriptBytes),
                        caption: "file trên đĩa, gồm cả lịch sử đã compaction"
                    )
                    Metric(
                        title: "Skill trong prompt",
                        value: "\(report.skills.filter { $0.catalogBytes > 0 }.count)",
                        caption: "\(report.skills.filter { $0.readCount > 0 }.count) file SKILL.md được đọc"
                    )
                    Metric(
                        title: contextTitle,
                        value: contextValue,
                        caption: contextCaption
                    )
                }

                if !report.standing.isEmpty {
                    SectionCard(title: "Prompt đứng", subtitle: "Những gì model phải mang trước nội dung hội thoại.") {
                        BudgetBar(slices: report.standing)
                        SliceLegend(slices: report.standing)
                    }
                }

                if !report.transcript.isEmpty {
                    SectionCard(title: "Transcript", subtitle: "Tổng chữ đã lưu trong log, không phải context còn lại sau compaction.") {
                        BudgetBar(slices: report.transcript)
                        SliceLegend(slices: report.transcript)
                    }
                }

                if !report.sections.isEmpty {
                    SectionCard(title: "System prompt", subtitle: "Các thẻ chiếm trọn một dòng trong system_prompt.txt.") {
                        barRows(report.sections.map { ($0.id, $0.name, $0.bytes, $0.preview) }, tint: Theme.color(.system))
                    }
                }

                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 16) { skillAndMcp }
                    VStack(alignment: .leading, spacing: 16) { skillAndMcp }
                }

                if !report.steering.isEmpty {
                    SectionCard(title: "Steering", subtitle: "File Kiro đánh dấu đã đưa vào context. Byte là kích thước file trên đĩa.") {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(report.steering) { doc in
                                HStack {
                                    Text(doc.name).lineLimit(1).truncationMode(.middle)
                                    Spacer()
                                    Text(ByteFormat.bytes(doc.bytes)).monospacedDigit()
                                }
                                .font(.callout)
                            }
                        }
                    }
                }

                if !report.tools.isEmpty {
                    SectionCard(title: "Tool", subtitle: "Định nghĩa là schema gửi kèm. Kết quả là chữ tool trả về.") {
                        toolTable
                    }
                }

                if !report.heavy.isEmpty {
                    SectionCard(title: "Kết quả tool lớn nhất", subtitle: "Tám lần trả về nặng nhất.") {
                        VStack(spacing: 6) {
                            ForEach(report.heavy) { item in
                                HStack {
                                    Text("\(item.rank). \(item.tool)")
                                    Spacer()
                                    Text(ByteFormat.bytes(item.bytes)).monospacedDigit()
                                }
                                .font(.callout)
                            }
                        }
                    }
                }

                if !report.turns.isEmpty {
                    SectionCard(title: "Lượt", subtitle: "Câu user và phần trả lời phía sau, đến lượt kế.") {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(report.turns) { turn in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("\(turn.index). \(turn.preview)")
                                        .lineLimit(2)
                                    Text("user \(ByteFormat.bytes(turn.userBytes)) · sau đó \(ByteFormat.bytes(turn.replyBytes))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .monospacedDigit()
                                }
                            }
                        }
                    }
                }

                if !report.notes.isEmpty {
                    SectionCard(title: "Ghi chú") {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(report.notes, id: \.self) { note in
                                Text(note).font(.callout).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 1040, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.thinMaterial)
    }

    private var metaLine: String {
        var parts: [String] = [report.ref.sessionID]
        if let model = report.ref.model { parts.append(model) }
        if let agent = report.ref.agent { parts.append(agent) }
        if let date = report.ref.updatedAt {
            parts.append(date.formatted(date: .abbreviated, time: .shortened))
        }
        return parts.joined(separator: "  ·  ")
    }

    private var contextTitle: String { "Context ghi nhận" }

    private var contextValue: String {
        if let percent = report.contextPercent {
            return String(format: "%.1f%%", percent)
        }
        return "—"
    }

    private var contextCaption: String {
        if let window = report.contextWindow, let percent = report.contextPercent {
            let used = Int((percent / 100) * Double(window))
            return "\(used) / \(window) token"
        }
        return "Grok không ghi context % vào session"
    }

    @ViewBuilder
    private var skillAndMcp: some View {
        SectionCard(title: "Skill", subtitle: "Catalog là đoạn mô tả trong prompt. Đĩa là SKILL.md. Đọc là số lần tool mở file đó.") {
            if report.skills.isEmpty {
                Text("Không thấy skill.").foregroundStyle(.secondary)
            } else {
                skillTable
            }
        }
        SectionCard(title: "MCP", subtitle: "Byte là mô tả server trong reminder. Schema tool MCP không được nhúng sẵn.") {
            if report.mcp.isEmpty {
                Text("Không thấy MCP trong prompt của session này.").foregroundStyle(.secondary)
            } else {
                mcpTable
            }
        }
    }

    private var skillTable: some View {
        VStack(spacing: 8) {
            ForEach(report.skills.prefix(40)) { skill in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(skill.name).font(.body.weight(.medium))
                        Spacer()
                        Text(skill.catalogBytes > 0 ? ByteFormat.bytes(skill.catalogBytes) : "không catalog")
                            .monospacedDigit()
                    }
                    Text("\(skill.origin) · đĩa \(skill.diskBytes.map(ByteFormat.bytes) ?? "—") · đọc \(skill.readCount)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if !skill.summary.isEmpty {
                        Text(skill.summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
            }
        }
    }

    private var mcpTable: some View {
        VStack(spacing: 8) {
            ForEach(report.mcp) { server in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(server.name).font(.body.weight(.medium))
                        Text(server.status)
                            .font(.caption)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(statusColor(server.status).opacity(0.18), in: Capsule())
                        Spacer()
                        Text(ByteFormat.bytes(server.catalogBytes)).monospacedDigit()
                    }
                    let count = server.toolCount.map { "\($0) tools" } ?? "không rõ số tool"
                    Text(server.tools.isEmpty ? count : "\(count) · \(server.tools.prefix(6).joined(separator: ", "))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    if !server.blurb.isEmpty {
                        Text(server.blurb)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
            }
        }
    }

    private var toolTable: some View {
        VStack(spacing: 6) {
            ForEach(report.tools.prefix(24)) { tool in
                HStack {
                    Text(tool.name).lineLimit(1)
                    Spacer()
                    Text("def \(ByteFormat.bytes(tool.definitionBytes))")
                        .foregroundStyle(.secondary)
                    Text("\(tool.calls)×")
                        .frame(width: 36, alignment: .trailing)
                    Text(ByteFormat.bytes(tool.resultBytes))
                        .frame(width: 72, alignment: .trailing)
                        .monospacedDigit()
                }
                .font(.callout)
            }
        }
    }

    private func barRows(_ rows: [(String, String, Int, String)], tint: Color) -> some View {
        let total = max(rows.reduce(0) { $0 + $1.2 }, 1)
        return VStack(alignment: .leading, spacing: 8) {
            ForEach(rows, id: \.0) { row in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(row.1)
                        Spacer()
                        Text(ByteFormat.bytes(row.2)).monospacedDigit()
                        Text(ByteFormat.percent(row.2, total))
                            .foregroundStyle(.secondary)
                            .frame(width: 44, alignment: .trailing)
                    }
                    .font(.callout)
                    GeometryReader { geo in
                        tint.opacity(0.85)
                            .frame(width: max(2, geo.size.width * CGFloat(row.2) / CGFloat(total)))
                    }
                    .frame(height: 6)
                    .background(tint.opacity(0.12))
                    .clipShape(Capsule())
                    if !row.3.isEmpty {
                        Text(row.3)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
            }
        }
    }

    private func statusColor(_ status: String) -> Color {
        switch status {
        case "connected": Theme.color(.assistant)
        case "auth": Theme.color(.mcp)
        case "failed": Theme.color(.toolResult)
        default: .secondary
        }
    }
}
