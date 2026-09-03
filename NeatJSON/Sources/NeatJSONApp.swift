import SwiftUI

@main
struct NeatJSONApp: App {
    @State private var appModel = AppModel()
    @AppStorage(PreferenceKey.appearanceMode) private var appearanceMode: AppearanceMode = .system

    var body: some Scene {
        // 单窗口工具用 Window 而非 WindowGroup：系统不再提供 New Window /
        // 窗口 tab 相关菜单项，无需再手动清空 .newItem。
        Window("NeatJSON", id: "main") {
            MainEditorView()
                .environment(appModel)
                // 只需挂在主窗口上：AppearanceController.apply 内部会
                // 遍历 NSApp.windows，设置窗口当时若打开着会一起重绘；
                // 若还没打开，它被打开的那一刻就已经继承了全局值。
                .task { AppearanceController.apply(appearanceMode) }
                .onChange(of: appearanceMode) { _, newValue in
                    AppearanceController.apply(newValue)
                }
        }
        .windowStyle(.automatic)
        .windowToolbarStyle(.unified)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1080, height: 680)
        .commands {
            AppCommands(model: appModel)
        }

        // Diff 用独立窗口而非 sheet：数据密集、可能看很久，独立窗口可
        // 自由缩放/全屏，也不会把主窗口锁死；关闭窗口即取消后台计算
        // （视图消失时 .task 自动取消）。
        Window(
            String(localized: "diff.window.title", defaultValue: "Differences"),
            id: "diff"
        ) {
            DiffWindowView()
                .environment(appModel)
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 960, height: 600)

        Settings {
            SettingsView()
        }
    }
}

/// 菜单栏命令。工具栏按钮只是快捷入口，动作与快捷键的正式归属都在
/// 这里：菜单是 macOS 上功能与快捷键的官方「发现渠道」，还能被
/// Help 菜单的搜索索引到。
private struct AppCommands: Commands {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow
    @AppStorage(PreferenceKey.editorFontSize)
    private var editorFontSize: Double = EditorFontMetrics.standard

    var body: some Commands {
        // File：打开 / 导出（面板本体挂在主窗口视图上，这里只置位）。
        CommandGroup(replacing: .newItem) {
            Button(String(localized: "menu.file.open", defaultValue: "Open JSON File…")) {
                model.importerPresented = true
            }
            .keyboardShortcut("o")

            Button(String(localized: "menu.file.export", defaultValue: "Export Formatted JSON…")) {
                model.exporterPresented = true
            }
            .keyboardShortcut("s")
            .disabled(model.outputText.isEmpty)
        }

        // Edit：剪贴板动作之后。
        CommandGroup(after: .pasteboard) {
            Divider()

            Button(String(localized: "menu.edit.copy-formatted", defaultValue: "Copy Formatted Result")) {
                model.copyOutput()
            }
            .keyboardShortcut("c", modifiers: [.command, .shift])
            .disabled(model.outputText.isEmpty)

            Button(String(localized: "menu.edit.clear", defaultValue: "Clear Input")) {
                model.clearAll()
            }
            .keyboardShortcut("k")
            .disabled(model.inputText.isEmpty)
        }

        // View：diff 与文字大小。
        CommandGroup(before: .toolbar) {
            Button(String(localized: "menu.view.compare", defaultValue: "Compare Input & Output")) {
                model.presentDiff()
                openWindow(id: "diff")
            }
            .keyboardShortcut("d")
            .disabled(!model.canShowDiff)

            Divider()

            Button(String(localized: "menu.view.text-bigger", defaultValue: "Increase Text Size")) {
                editorFontSize = min(EditorFontMetrics.maximum, editorFontSize + 1)
            }
            .keyboardShortcut("+")
            .disabled(editorFontSize >= EditorFontMetrics.maximum)

            Button(String(localized: "menu.view.text-smaller", defaultValue: "Decrease Text Size")) {
                editorFontSize = max(EditorFontMetrics.minimum, editorFontSize - 1)
            }
            .keyboardShortcut("-")
            .disabled(editorFontSize <= EditorFontMetrics.minimum)

            Button(String(localized: "menu.view.text-default", defaultValue: "Default Text Size")) {
                editorFontSize = EditorFontMetrics.standard
            }
            .keyboardShortcut("0")
            .disabled(editorFontSize == EditorFontMetrics.standard)

            Divider()
        }
    }
}
