import SwiftUI

@main
struct NeatJSONApp: App {
    @State private var appModel = AppModel()
    @AppStorage("appearanceMode") private var appearanceMode: AppearanceMode = .system

    var body: some Scene {
        WindowGroup {
            MainEditorView()
                .environment(appModel)
                .background(WindowAppearanceConfigurator(mode: appearanceMode))
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
                .background(WindowAppearanceConfigurator(mode: appearanceMode))
        }
    }
}
