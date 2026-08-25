import AppKit

/// 外观模式：日间 / 夜间 / 跟随系统。
///
/// `rawValue` 直接落地进 `@AppStorage`；`nsAppearance` 为 nil 表示跟随系统。
/// 外观通过 `AppearanceController.apply` 以 `NSApplication.appearance` 应用
/// （不用 Scene 级 `.preferredColorScheme`，原因见该类型的注释）；外观
/// 变化会级联触发 `JSONTextView.viewDidChangeEffectiveAppearance`
/// （见 JSONEditorView.swift），编辑器配色随之切换。
enum AppearanceMode: String, CaseIterable, Identifiable, Sendable {
    case system
    case light
    case dark

    var id: String {
        rawValue
    }

    /// 窗口外观；nil 表示跟随系统。
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }

    var label: String {
        switch self {
        case .system: String(localized: "settings.appearance.system", defaultValue: "System")
        case .light: String(localized: "settings.appearance.light", defaultValue: "Light")
        case .dark: String(localized: "settings.appearance.dark", defaultValue: "Dark")
        }
    }

    var icon: String {
        switch self {
        case .system: "circle.lefthalf.filled"
        case .light: "sun.max.fill"
        case .dark: "moon.fill"
        }
    }
}

/// 把外观切换应用到整个 App，并主动顶掉 macOS 26 上 Liquid Glass
/// 合成层不会跟着外观翻转自动重绘的已知缺陷。
///
/// 刻意走 `NSApplication.appearance`（app 级）而不是逐个窗口设置
/// `NSWindow.appearance`：这是 AppKit 从 Mojave 起就有的、专门用来
/// 做「应用内深浅色覆盖，独立于系统设置」的标准入口，一次赋值会
/// 级联到本 App 拥有的**所有**窗口——包括当时还没创建的设置窗口，
/// 它一旦被打开就直接继承这个全局值，不需要再单独给它挂一份配置。
/// 逐窗口设置则是几套各自为政的开关，某个窗口当时不在场就会漏掉。
///
/// 光设置 `NSApp.appearance` 在这版系统上不够：Liquid Glass 的私有
/// 合成图层不保证跟着标准的「外观已变化」通知链条一起重绘，会冻结
/// 在旧外观、或者干脆消失，直到下一次不相关的重绘才「自愈」。这里
/// 额外对每个已打开的窗口显式补一次通知 + 强制布局 + 同步重绘，
/// 把这次自愈提前到当前这一帧内完成。
///
/// 不要在这里重新引入 `.preferredColorScheme`：Scene 级 colorScheme
/// 覆盖会在切换瞬间重建整棵 SwiftUI 视图树，与窗口外观翻转竞争
/// （实测卡片材质冻结在旧外观、设置页 Form 内容整块消失）。
@MainActor
enum AppearanceController {
    static func apply(_ mode: AppearanceMode) {
        // 1. 唯一、全局的开关。
        NSApp.appearance = mode.nsAppearance

        // 2. 兜底：对每个已打开的窗口显式补一次通知 + 强制布局 + 同步
        //    重绘，而不是等下一次不相关的重绘「顺便」把它救回来。
        for window in NSApp.windows {
            guard let contentView = window.contentView else { continue }
            contentView.viewDidChangeEffectiveAppearance()
            contentView.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
        }
    }
}

extension NSView {
    /// 当前是否深色外观。
    ///
    /// makeNSView 阶段视图尚未挂到 window，`effectiveAppearance` 可能给出
    /// 与最终显示环境相反的结果（实测误选 dark 配色后，淡色 token 全部
    /// 铺在浅色背景上）。因此优先取 window 的外观，其次回退到应用外观，
    /// 两者都没有时才用视图自身的值。
    var isDarkAppearance: Bool {
        let appearance = window?.effectiveAppearance
            ?? NSApp?.effectiveAppearance
            ?? effectiveAppearance
        return appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }
}
