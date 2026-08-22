import AppKit
import SwiftUI

/// 把所在窗口的外观切到指定模式。
///
/// 刻意走 AppKit（`NSWindow.appearance`）而不是 `.preferredColorScheme`：
/// Scene 级 colorScheme 覆盖在切换瞬间会重建整棵 SwiftUI 视图树，
/// 与窗口外观翻转竞争——实测（macOS 26）卡片材质冻结在旧外观、
/// 设置页 Form 内容整块消失，直到下一次交互才重绘。直接设置窗口
/// appearance 只翻转外观、不重建视图树，材质与动态颜色随
/// `viewDidChangeEffectiveAppearance` 通知可靠更新。
struct WindowAppearanceConfigurator: NSViewRepresentable {
    let mode: AppearanceMode

    func makeNSView(context: Context) -> AnchorView {
        AnchorView()
    }

    func updateNSView(_ nsView: AnchorView, context: Context) {
        nsView.mode = mode
    }

    /// 不绘制、不接收事件的锚点视图，只负责把模式写到窗口上。
    final class AnchorView: NSView {
        var mode: AppearanceMode = .system {
            didSet {
                guard mode != oldValue else { return }
                apply()
            }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        private func apply() {
            // nil 表示跟随系统
            window?.appearance = mode.nsAppearance
        }
    }
}

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
            (tint.map { Glass.regular.tint($0) } ?? .regular).interactive(),
            in: .capsule
        )
    }
}

/// 底部状态栏：左输入统计 / 中状态徽章 / 右输出统计。
/// 两侧统计区等宽，徽章因此在窗口正中。
struct StatusBarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 12) {
            inputStats
                .frame(maxWidth: .infinity, alignment: .leading)
            statusBadge
            outputStats
                .frame(maxWidth: .infinity, alignment: .trailing)
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
