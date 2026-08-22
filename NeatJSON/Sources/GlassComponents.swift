import AppKit
import SwiftUI

/// 玻璃徽章：状态指示用的小型 Liquid Glass 元件。
///
/// 不用 `.interactive()`：那是给"响应触控/指针交互"的可点击控件用的
/// （文档原话，和标准玻璃按钮同款反馈）。这里的徽章始终是纯展示型的
/// 状态指示，从不可点，套上 `.interactive()` 只会让它看起来能点、
/// 点了却没反应，是体验上的不一致。
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

/// 底部状态栏：左输入统计 / 中状态徽章 / 右输出统计。
/// 两侧统计区等宽，徽章因此在窗口正中。
struct StatusBarView: View {
    @Environment(AppModel.self) private var model
    @Namespace private var badgeNamespace

    /// 状态徽章的三种形态。承担 `glassEffectID` 需要的稳定身份值
    /// （API 要求 `Hashable & Sendable`，不能只满足 `Equatable`）。
    private enum BadgeState: Hashable {
        case waiting
        case success
        case error(String)
    }

    private var badgeState: BadgeState {
        if let error = model.lastError {
            .error(error.localizedDescription)
        } else if model.outputText.isEmpty {
            .waiting
        } else {
            .success
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            inputStats
                .frame(maxWidth: .infinity, alignment: .leading)
            // 包一层容器只是为了给 glassEffectID 提供协调上下文——三个
            // 状态始终只有一个在场，不是要组合多个同时存在的玻璃形状。
            // 配合 .matchedGeometry，切换状态时胶囊原地形变、内容交叉
            // 淡出，而不是现在这种硬切换。
            GlassEffectContainer {
                statusBadge
            }
            outputStats
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch badgeState {
        case .error(let message):
            GlassBadge(tint: .red) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.white)
                Text(message)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .glassEffectID(BadgeState.error(message), in: badgeNamespace)
            .glassEffectTransition(.matchedGeometry)
        case .waiting:
            GlassBadge {
                Image(systemName: "circle.dotted")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text(String(localized: "status.waiting", defaultValue: "Waiting for input"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .glassEffectID(BadgeState.waiting, in: badgeNamespace)
            .glassEffectTransition(.matchedGeometry)
        case .success:
            GlassBadge(tint: .green) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.white)
                Text(String(localized: "status.formatted", defaultValue: "Formatted & sorted"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.primary)
            }
            .glassEffectID(BadgeState.success, in: badgeNamespace)
            .glassEffectTransition(.matchedGeometry)
        }
    }

    private var inputStats: some View {
        Text(
            String(
                localized: "status.input.stats",
                defaultValue: "\(model.inputCharacterCount) chars · \(model.inputLineCount) lines"
            )
        )
        .font(.system(size: 10, design: .monospaced))
        .foregroundStyle(.tertiary)
        .contentTransition(.numericText())
    }

    private var outputStats: some View {
        Text(
            String(
                localized: "status.output.stats",
                defaultValue: "\(model.outputLineCount) lines"
            )
        )
        .font(.system(size: 10, design: .monospaced))
        .foregroundStyle(.tertiary)
        .contentTransition(.numericText())
    }
}
