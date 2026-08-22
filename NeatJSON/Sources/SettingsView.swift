import AppKit
import SwiftUI

/// 外观模式：日间 / 夜间 / 跟随系统。
///
/// `rawValue` 直接落地进 `@AppStorage`；`nsAppearance` 为 nil 表示跟随系统。
/// 外观通过 `WindowAppearanceConfigurator` 以 `NSWindow.appearance` 应用
/// （不用 Scene 级 `.preferredColorScheme`，原因见该类型的注释）；窗口
/// 外观变化会级联触发 `JSONTextView.viewDidChangeEffectiveAppearance`
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

/// 设置面板：外观切换 + 快捷键一览。由 `Settings { }` Scene 承载，
/// 系统自动提供菜单入口与 `⌘,` 快捷键。
struct SettingsView: View {
    @AppStorage("appearanceMode") private var appearanceMode: AppearanceMode = .system

    var body: some View {
        TabView {
            generalTab
                .tabItem {
                    Label(
                        String(localized: "settings.tab.general", defaultValue: "General"),
                        systemImage: "gearshape"
                    )
                }
            shortcutsTab
                .tabItem {
                    Label(
                        String(localized: "settings.tab.shortcuts", defaultValue: "Shortcuts"),
                        systemImage: "keyboard"
                    )
                }
        }
        .frame(width: 460, height: 360)
    }

    // MARK: - General

    private var generalTab: some View {
        Form {
            Picker(
                String(localized: "settings.appearance.title", defaultValue: "Appearance"),
                selection: $appearanceMode
            ) {
                ForEach(AppearanceMode.allCases) { mode in
                    Label(mode.label, systemImage: mode.icon).tag(mode)
                }
            }
            .pickerStyle(.segmented)
        }
        .padding(24)
    }

    // MARK: - Shortcuts

    private var shortcutsTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                shortcutSection(
                    title: String(
                        localized: "settings.shortcuts.section.toolbar",
                        defaultValue: "Toolbar"
                    ),
                    rows: [
                        (String(localized: "action.clear", defaultValue: "Clear"), "⌘K"),
                        (String(localized: "action.copy", defaultValue: "Copy"), "⌘⇧C"),
                        (String(localized: "action.diff", defaultValue: "Compare"), "⌘D"),
                    ]
                )
                shortcutSection(
                    title: String(
                        localized: "settings.shortcuts.section.editing",
                        defaultValue: "Standard Editing"
                    ),
                    rows: [
                        (String(localized: "shortcut.edit.find", defaultValue: "Find"), "⌘F"),
                        (
                            String(localized: "shortcut.edit.find-next", defaultValue: "Find Next"),
                            "⌘G"
                        ),
                        (
                            String(
                                localized: "shortcut.edit.find-previous",
                                defaultValue: "Find Previous"
                            ),
                            "⌘⇧G"
                        ),
                        (String(localized: "shortcut.edit.undo", defaultValue: "Undo"), "⌘Z"),
                        (String(localized: "shortcut.edit.redo", defaultValue: "Redo"), "⌘⇧Z"),
                        (String(localized: "shortcut.edit.cut", defaultValue: "Cut"), "⌘X"),
                        (String(localized: "shortcut.edit.copy", defaultValue: "Copy"), "⌘C"),
                        (String(localized: "shortcut.edit.paste", defaultValue: "Paste"), "⌘V"),
                        (
                            String(localized: "shortcut.edit.select-all", defaultValue: "Select All"),
                            "⌘A"
                        ),
                    ]
                )
            }
            .padding(24)
        }
    }

    private func shortcutSection(title: String, rows: [(label: String, keys: String)]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            VStack(spacing: 4) {
                ForEach(rows, id: \.label) { row in
                    shortcutRow(label: row.label, keys: row.keys)
                }
            }
        }
    }

    private func shortcutRow(label: String, keys: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 12))
            Spacer()
            GlassBadge {
                Text(keys)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
            }
        }
    }
}
