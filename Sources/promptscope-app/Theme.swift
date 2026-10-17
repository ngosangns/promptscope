import PromptscopeKit
import SwiftUI

enum Theme {
    static func color(_ kind: SliceKind) -> Color {
        switch kind {
        case .system: Color(red: 0.27, green: 0.40, blue: 0.72)
        case .skills: Color(red: 0.12, green: 0.52, blue: 0.46)
        case .mcp: Color(red: 0.78, green: 0.42, blue: 0.18)
        case .rules: Color(red: 0.46, green: 0.36, blue: 0.66)
        case .toolDefs: Color(red: 0.36, green: 0.42, blue: 0.48)
        case .user: Color(red: 0.20, green: 0.45, blue: 0.74)
        case .assistant: Color(red: 0.22, green: 0.52, blue: 0.34)
        case .toolResult: Color(red: 0.70, green: 0.28, blue: 0.26)
        case .reasoning: Color(red: 0.48, green: 0.48, blue: 0.50)
        case .steering: Color(red: 0.55, green: 0.40, blue: 0.22)
        case .other: Color(red: 0.55, green: 0.55, blue: 0.56)
        }
    }
}

struct BudgetBar: View {
    let slices: [Slice]
    var body: some View {
        let visible = slices.filter { $0.bytes > 0 }
        let total = max(visible.reduce(0) { $0 + $1.bytes }, 1)
        GeometryReader { geo in
            HStack(spacing: 0) {
                ForEach(visible) { slice in
                    Theme.color(slice.kind)
                        .frame(width: geo.size.width * CGFloat(slice.bytes) / CGFloat(total))
                }
            }
        }
        .frame(height: 16)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .accessibilityLabel(visible.map { "\($0.kind.label) \(ByteFormat.bytes($0.bytes))" }.joined(separator: ", "))
    }
}

struct SliceLegend: View {
    let slices: [Slice]
    var total: Int { slices.reduce(0) { $0 + $1.bytes } }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(slices.filter { $0.bytes > 0 }) { slice in
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Theme.color(slice.kind))
                        .frame(width: 10, height: 10)
                    Text(slice.kind.label)
                    Spacer(minLength: 8)
                    Text(ByteFormat.bytes(slice.bytes))
                        .monospacedDigit()
                    Text(ByteFormat.percent(slice.bytes, total))
                        .foregroundStyle(.secondary)
                        .frame(width: 44, alignment: .trailing)
                        .monospacedDigit()
                }
                .font(.callout)
            }
        }
    }
}

struct Metric: View {
    var title: String
    var value: String
    var caption: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.weight(.semibold))
                .monospacedDigit()
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct SectionCard<Content: View>: View {
    var title: String
    var subtitle: String = ""
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                if !subtitle.isEmpty {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.quaternary))
    }
}
