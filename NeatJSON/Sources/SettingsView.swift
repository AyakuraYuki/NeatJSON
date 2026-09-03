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
