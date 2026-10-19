import PromptscopeKit
import SwiftUI
import NSShell

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
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
        .accessibilityLabel(visible.map { "\($0.kind.label) \(ByteFormat.bytes($0.bytes))" }.joined(separator: ", "))
    }
}

struct SliceLegend: View {
    let slices: [Slice]
    var total: Int { slices.reduce(0) { $0 + $1.bytes } }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            ForEach(slices.filter { $0.bytes > 0 }) { slice in
                HStack(spacing: Theme.Space.sm) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Theme.color(slice.kind))
                        .frame(width: 10, height: 10)
                    Text(slice.kind.label)
                    Spacer(minLength: Theme.Space.sm)
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
        .padding(Theme.Space.md)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: Theme.Radius.md))
    }
}

struct SectionCard<Content: View>: View {
    var title: String
    var subtitle: String = ""
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Space.lg)
        .background(.background, in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                .strokeBorder(.separator)
        )
    }
}
