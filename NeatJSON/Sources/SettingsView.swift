import SwiftUI

/// 设置面板：外观切换 + 快捷键一览。由 `Settings { }` Scene 承载，
/// 系统自动提供菜单入口与 `⌘,` 快捷键。
struct SettingsView: View {
    @AppStorage(PreferenceKey.appearanceMode) private var appearanceMode: AppearanceMode = .system

    var body: some View {
        TabView {
            generalTab.tabItem {
                Label(
                    String(localized: "settings.tab.general", defaultValue: "General"),
                    systemImage: "gearshape"
                )
            }
            shortcutsTab.tabItem {
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
        .font(.system(size: 14))
        .padding(24)
    }

    // MARK: - Shortcuts

    private var shortcutsTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                shortcutSection(
                    title: String(localized: "settings.shortcuts.section.toolbar", defaultValue: "Toolbar"),
                    rows: [
                        (String(localized: "action.clear", defaultValue: "Clear"), "⌘K"),
                        (String(localized: "action.copy", defaultValue: "Copy"), "⌘⇧C"),
                        (String(localized: "action.diff", defaultValue: "Compare"), "⌘D"),
                    ]
                )
                shortcutSection(
                    title: String(localized: "settings.shortcuts.section.editing", defaultValue: "Standard Editing"),
                    rows: [
                        (String(localized: "shortcut.edit.find", defaultValue: "Find"), "⌘F"),
                        (String(localized: "shortcut.edit.find-next", defaultValue: "Find Next"), "⌘G"),
                        (String(localized: "shortcut.edit.find-previous", defaultValue: "Find Previous"), "⌘⇧G"),
                        (String(localized: "shortcut.edit.undo", defaultValue: "Undo"), "⌘Z"),
                        (String(localized: "shortcut.edit.redo", defaultValue: "Redo"), "⌘⇧Z"),
                        (String(localized: "shortcut.edit.cut", defaultValue: "Cut"), "⌘X"),
                        (String(localized: "shortcut.edit.copy", defaultValue: "Copy"), "⌘C"),
                        (String(localized: "shortcut.edit.paste", defaultValue: "Paste"), "⌘V"),
                        (String(localized: "shortcut.edit.select-all", defaultValue: "Select All"), "⌘A"),
                    ]
                )
            }
            .padding(24)
        }
    }

    private func shortcutSection(title: String, rows: [(label: String, keys: String)]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)
            VStack(spacing: 4) {
                ForEach(rows, id: \.label) { row in
                    shortcutRow(label: row.label, keys: row.keys)
                }
            }
        }
    }

    private func shortcutRow(label: String, keys: String) -> some View {
        HStack(spacing: 12) {
            Text(label).font(.system(size: 13))
            Spacer()
            Text(keys)
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }
}
