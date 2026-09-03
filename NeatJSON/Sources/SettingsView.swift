import SwiftUI

/// 设置面板：外观切换 + 编辑器字号。由 `Settings { }` Scene 承载，
/// 系统自动提供菜单入口与 `⌘,` 快捷键。
///
/// 此前这里还有一页手写的「快捷键一览」—— 那是快捷键没有进菜单栏时
/// 的补偿品。现在所有动作与快捷键都由菜单栏正式承载（见
/// NeatJSONApp.AppCommands），菜单本身就是发现渠道，该页随之移除。
struct SettingsView: View {
    @AppStorage(PreferenceKey.appearanceMode) private var appearanceMode: AppearanceMode = .system
    @AppStorage(PreferenceKey.editorFontSize) private var editorFontSize: Double = EditorFontMetrics.standard

    var body: some View {
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

            Stepper(
                String(
                    localized: "settings.font-size.title",
                    defaultValue: "Editor text size: \(Int(editorFontSize)) pt"
                ),
                value: $editorFontSize,
                in: EditorFontMetrics.minimum ... EditorFontMetrics.maximum,
                step: 1
            )
        }
        .font(.system(size: 14))
        .padding(24)
        .frame(width: 460)
    }
}

/// 应用内帮助窗口：一段用法概述 + 快捷键一览 + 小技巧。
/// 由 Help ▸ NeatJSON 帮助（⌘?）打开（见 NeatJSONApp.AppCommands）。
///
/// 快捷键行的文字直接复用菜单项的本地化 key —— 帮助里的叫法和
/// 菜单栏永远一致，也少维护一份文案。
struct HelpView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(
                String(
                    localized: "help.overview",
                    defaultValue: "Type or paste JSON on the left — it is formatted and key-sorted automatically. Pick the indent style in the toolbar; the result on the right is ready to copy."
                )
            )
            .font(.system(size: 13))
            .fixedSize(horizontal: false, vertical: true)

            section(
                title: String(localized: "help.section.file", defaultValue: "File"),
                rows: [
                    (String(localized: "menu.file.open", defaultValue: "Open JSON File…"), "⌘O"),
                    (String(localized: "menu.file.export", defaultValue: "Export Formatted JSON…"), "⌘S"),
                ]
            )
            section(
                title: String(localized: "help.section.edit", defaultValue: "Edit"),
                rows: [
                    (String(localized: "menu.edit.copy-formatted", defaultValue: "Copy Formatted Result"), "⌘⇧C"),
                    (String(localized: "menu.edit.clear", defaultValue: "Clear Input"), "⌘K"),
                    (String(localized: "help.row.find", defaultValue: "Find in Editor"), "⌘F"),
                ]
            )
            section(
                title: String(localized: "help.section.view", defaultValue: "View"),
                rows: [
                    (String(localized: "menu.view.compare", defaultValue: "Compare Input & Output"), "⌘D"),
                    (String(localized: "menu.view.text-bigger", defaultValue: "Increase Text Size"), "⌘+"),
                    (String(localized: "menu.view.text-smaller", defaultValue: "Decrease Text Size"), "⌘−"),
                    (String(localized: "menu.view.text-default", defaultValue: "Default Text Size"), "⌘0"),
                ]
            )

            VStack(alignment: .leading, spacing: 6) {
                Text(String(localized: "help.section.tips", defaultValue: "Tips"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                tip(String(
                    localized: "help.tip.drop",
                    defaultValue: "Drop a .json file onto the input pane to load its contents."
                ))
                tip(String(
                    localized: "help.tip.error-jump",
                    defaultValue: "When the input is invalid, click the error badge in the status bar to jump to the problem."
                ))
                tip(String(
                    localized: "help.tip.undo",
                    defaultValue: "Clear and file loading can be undone with ⌘Z."
                ))
            }
        }
        .padding(24)
        .frame(width: 480)
    }

    private func section(title: String, rows: [(label: String, keys: String)]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
            VStack(spacing: 4) {
                ForEach(rows, id: \.label) { row in
                    HStack(spacing: 12) {
                        Text(row.label).font(.system(size: 13))
                        Spacer()
                        Text(row.keys)
                            .font(.system(size: 13, weight: .medium, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func tip(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "lightbulb")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
