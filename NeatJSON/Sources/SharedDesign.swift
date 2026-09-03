//
//  SharedDesign.swift
//  NeatJSON
//
//  Created by 绫仓优希 on 2026-08-25.
//

import AppKit

let colorLightText = NSColor(srgbRed: 0.13, green: 0.13, blue: 0.14, alpha: 1)
let colorDarkText = NSColor(srgbRed: 0.92, green: 0.92, blue: 0.95, alpha: 1)

/// `@AppStorage` 偏好键。同一个键会在多个视图里各写一遍，
/// 集中定义避免拼写分叉导致设置悄悄失效。
enum PreferenceKey {
    static let appearanceMode = "appearanceMode"
    static let editorFontSize = "editorFontSize"
}

/// 编辑器字号的允许范围。菜单命令（⌘+ / ⌘- / ⌘0）与设置面板共用，
/// 两处不一致会出现「菜单调不动设置里显示的值」这类怪相。
enum EditorFontMetrics {
    static let minimum: Double = 9
    static let maximum: Double = 24
    static let standard: Double = 13
}
