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

    /// 三种状态只差底色、图标、图标颜色、文字四个点，先在 switch 里
    /// 取齐这四项，徽章结构与玻璃特效样板只写一遍。
    /// 错误且带位置信息时整个徽章是一个按钮：点击把输入区光标带到出错处
    /// （反馈靠近操作点，错误描述里的行列号因此可以直接「走过去」）。
    @ViewBuilder
    private var statusBadge: some View {
        if case .error = badgeState, model.canJumpToError {
            Button {
                model.requestErrorJump()
            } label: {
                badgeBody
            }
            .buttonStyle(.plain)
            .help(String(localized: "status.error.jump.help", defaultValue: "Jump to error location"))
        } else {
            badgeBody
        }
    }

    private var badgeBody: some View {
        let state = badgeState
        let tint: Color?
        let icon: String
        let iconStyle: AnyShapeStyle
        let text: String
        let textStyle: AnyShapeStyle
        switch state {
        case .error(let message):
            (tint, icon) = (.red, "exclamationmark.triangle.fill")
            iconStyle = AnyShapeStyle(.white)
            text = message
            textStyle = AnyShapeStyle(.primary)
        case .waiting:
            (tint, icon) = (nil, "circle.dotted")
            iconStyle = AnyShapeStyle(.secondary)
            text = String(localized: "status.waiting", defaultValue: "Waiting for input")
            textStyle = AnyShapeStyle(.secondary)
        case .success:
            (tint, icon) = (.green, "checkmark.circle.fill")
            iconStyle = AnyShapeStyle(.white)
            text = String(localized: "status.formatted", defaultValue: "Formatted & sorted")
            textStyle = AnyShapeStyle(.primary)
        }
        return GlassBadge(tint: tint) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(iconStyle)
            Text(text)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(textStyle)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .glassEffectID(state, in: badgeNamespace)
        .glassEffectTransition(.matchedGeometry)
    }

    private var inputStats: some View {
        statText(
            String(
                localized: "status.input.stats",
                defaultValue: "\(model.inputCharacterCount) chars · \(model.inputLineCount) lines"
            )
        )
    }

    private var outputStats: some View {
        statText(
            String(
                localized: "status.output.stats",
                defaultValue: "\(model.outputLineCount) lines"
            )
        )
    }

    /// 两侧统计文本的公共样式。
    private func statText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(.tertiary)
            .contentTransition(.numericText())
    }
}
