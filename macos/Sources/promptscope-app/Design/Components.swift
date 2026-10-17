import PromptscopeKit
import SwiftUI

/// Heading bar at the top of a column.
struct PaneHeader<Trailing: View>: View {
    let title: String
    var subtitle: String?
    var systemImage: String?
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: Theme.Space.sm) {
            if let systemImage {
                Image(systemName: systemImage)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            Text(title).font(.headline)
            if let subtitle {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer(minLength: 0)
            trailing()
        }
        .padding(.horizontal, Theme.Space.lg)
        .frame(height: 40)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isHeader)
    }
}

extension PaneHeader where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil, systemImage: String? = nil) {
        self.init(title: title, subtitle: subtitle, systemImage: systemImage) { EmptyView() }
    }
}

/// Capsule tag.
struct Tag: View {
    let text: String
    var tint: Color = .secondary
    var systemImage: String?

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage { Image(systemName: systemImage).imageScale(.small) }
            Text(text).lineLimit(1)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .background(tint.opacity(0.14), in: Capsule())
    }
}

/// Centered placeholder for empty or idle panes.
struct StateView<Actions: View>: View {
    let systemImage: String
    let title: String
    var message: String?
    var tint: Color = .secondary
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        VStack(spacing: Theme.Space.md) {
            Image(systemName: systemImage)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(title).font(.headline)
            if let message {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            actions()
        }
        .padding(Theme.Space.xl)
        .frame(maxWidth: 420)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }
}

extension StateView where Actions == EmptyView {
    init(systemImage: String, title: String, message: String? = nil, tint: Color = .secondary) {
        self.init(systemImage: systemImage, title: title, message: message, tint: tint) { EmptyView() }
    }
}

/// Indeterminate working state.
struct WorkingView: View {
    let message: String

    var body: some View {
        VStack(spacing: Theme.Space.md) {
            ProgressView().controlSize(.large)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(message)
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
