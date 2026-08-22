import SwiftUI

@main
struct NeatJSONApp: App {
    @State private var appModel = AppModel()
    @AppStorage("appearanceMode") private var appearanceMode: AppearanceMode = .system

    var body: some Scene {
        WindowGroup {
            MainEditorView()
                .environment(appModel)
                .preferredColorScheme(appearanceMode.colorScheme)
        }
        .windowStyle(.automatic)
        .windowToolbarStyle(.unified)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1080, height: 680)
        .commands {
            CommandGroup(replacing: .newItem) {} // 单窗口工具，去掉 New 菜单
            CommandMenu(String(localized: "toolbar.menu.json", defaultValue: "JSON")) {
                Button(String(localized: "action.reformat", defaultValue: "Reformat")) {
                    NotificationCenter.default.post(name: .reformatRequested, object: nil)
                }
                .keyboardShortcut("r", modifiers: .command)

                Button(String(localized: "action.sort-keys", defaultValue: "Sort Keys")) {
                    NotificationCenter.default.post(name: .reformatRequested, object: nil)
                }
                .keyboardShortcut("k", modifiers: [.command, .shift])
                .disabled(true)
            }
        }

        Settings {
            SettingsView()
                .preferredColorScheme(appearanceMode.colorScheme)
        }
    }
}

extension Notification.Name {
    static let reformatRequested = Notification.Name("reformatRequested")
}
