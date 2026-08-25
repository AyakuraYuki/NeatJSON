import SwiftUI

@main
struct NeatJSONApp: App {
    @State private var appModel = AppModel()
    @AppStorage(PreferenceKey.appearanceMode) private var appearanceMode: AppearanceMode = .system

    var body: some Scene {
        WindowGroup {
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
            CommandGroup(replacing: .newItem) {} // 单窗口工具，去掉 New 菜单
            // 输入每次变更都会自动重排（AppModel.inputText.didSet），
            // 输出恒为排序结果，因此不提供手动 Reformat / Sort Keys 菜单。
        }

        Settings {
            SettingsView()
        }
    }
}
