import AppKit

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
