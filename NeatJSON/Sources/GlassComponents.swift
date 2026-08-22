import SwiftUI

/// 玻璃徽章：状态指示用的小型 Liquid Glass 元件。
struct GlassBadge<Content: View>: View {
    var tint: Color? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(spacing: 6) {
            content()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .glassEffect(
            tint.map { Glass.regular.tint($0) } ?? .regular,
            in: .capsule
        )
    }
}

/// 底部状态栏：成功/失败/空 三态玻璃徽章 + 统计。
struct StatusBarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 12) {
            statusBadge
            Spacer()
            statsLabel
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    @ViewBuilder
    private var statusBadge: some View {
        if let error = model.lastError {
            GlassBadge(tint: .red) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.white)
                Text(error.localizedDescription)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        } else if model.outputText.isEmpty {
            GlassBadge {
                Image(systemName: "circle.dotted")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text(String(localized: "status.waiting", defaultValue: "Waiting for input"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        } else {
            GlassBadge(tint: .green) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.white)
                Text(String(localized: "status.formatted", defaultValue: "Formatted & sorted"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.primary)
            }
        }
    }

    private var statsLabel: some View {
        Text(
            String(
                localized: "status.stats",
                defaultValue: "\(model.inputLineCount) in · \(model.outputLineCount) out"
            )
        )
        .font(.system(size: 10, design: .monospaced))
        .foregroundStyle(.tertiary)
        .contentTransition(.numericText())
    }
}
