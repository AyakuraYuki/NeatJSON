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
