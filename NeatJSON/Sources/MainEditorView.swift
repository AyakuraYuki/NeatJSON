import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 主界面：左右两块玻璃卡片编辑器 + 玻璃工具栏 + 底部状态栏。
///
/// 卡片等宽、固定 1:1，无分隔条与拖拽。卡片以 regularMaterial 浮在
/// thinMaterial 窗口底色上；文本视图本体不画背景（见 JSONTextView），
/// 让材质透出来。
///
/// 工具栏按钮只是快捷入口：动作与快捷键的正式归属在菜单栏
/// （见 NeatJSONApp.AppCommands），这里不再重复挂 keyboardShortcut。
struct MainEditorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @AppStorage(PreferenceKey.editorFontSize) private var editorFontSize: Double = EditorFontMetrics.standard
    @AppStorage(PreferenceKey.keyOrder) private var storedKeyOrder: JSONKeyOrder = .codepoint

    /// 文件导入读取失败时的提示。
    @State private var importFailed = false

    var body: some View {
        HStack(spacing: 16) {
            editorCard(role: .input)
            editorCard(role: .output)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            LinearGradient(
                colors: [.gray.opacity(0.10), .clear],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .navigationTitle("NeatJSON")
        .syncingEditorPreferences(
            keyOrder: storedKeyOrder,
            into: model
        )
        .toolbar {
            ToolbarSpacer(.flexible)

            ToolbarItemGroup {
                Button {
                    model.copyOutput()
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .help(String(localized: "action.copy.help", defaultValue: "Copy formatted result"))
                .disabled(model.outputText.isEmpty)

                Button {
                    presentDiffWindow()
                } label: {
                    Image(systemName: "arrow.left.arrow.right")
                }
                .help(String(localized: "action.diff.help", defaultValue: "Compare input and output"))
                .disabled(!model.canShowDiff)

                Button {
                    model.clearAll()
                } label: {
                    Image(systemName: "trash")
                }
                .help(String(localized: "action.clear.help", defaultValue: "Clear input"))
                .disabled(model.inputText.isEmpty)
            }

            ToolbarSpacer(.fixed)

            ToolbarItem {
                Picker(
                    String(localized: "picker.indent", defaultValue: "Indent"),
                    selection: Bindable(model).indent
                ) {
                    ForEach(IndentStyle.allCases) { style in
                        Text(style.label).tag(style)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 130)
                // 不再额外套 .glassEffect()：分段 Picker 放进工具栏时本身已经是
                // 系统原生渲染的 Liquid Glass 外观，再叠一层是重复的玻璃层，
                // 属于 Apple 文档明确提醒过的「过多玻璃效果」反模式。
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { StatusBarView() }
        .fileImporter(
            isPresented: Bindable(model).importerPresented,
            allowedContentTypes: [.json, .plainText]
        ) { result in
            handleImport(result)
        }
        .fileExporter(
            isPresented: Bindable(model).exporterPresented,
            document: JSONExportDocument(text: model.outputText),
            contentType: .json,
            defaultFilename: String(
                localized: "export.default-filename", defaultValue: "Formatted"
            )
        ) { _ in }
        .alert(
            String(localized: "import.failed", defaultValue: "Could not read the file."),
            isPresented: $importFailed
        ) {}
    }

    // MARK: - 编辑卡片

    private static let cardCornerRadius: CGFloat = 14

    private var cardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Self.cardCornerRadius, style: .continuous)
    }

    private func editorCard(role: JSONEditorView.Role) -> some View {
        editorContent(role: role)
            .background(.thickMaterial, in: cardShape)
            .clipShape(cardShape)
            .overlay(cardShape.strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
            .overlay(alignment: .topLeading) {
                placeholder(for: role)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 空文本时的占位提示。位置与正文首字符对齐：
    /// textContainerInset.width(8) + lineFragmentPadding(5) = 13。
    @ViewBuilder
    private func placeholder(for role: JSONEditorView.Role) -> some View {
        let isEmpty = role == .input ? model.inputText.isEmpty : model.outputText.isEmpty
        if isEmpty {
            Text(
                role == .input
                    ? String(localized: "pane.input.placeholder", defaultValue: "Type or paste JSON…")
                    : String(localized: "pane.output.placeholder", defaultValue: "Formatted result")
            )
            .font(.system(size: editorFontSize, design: .monospaced))
            .foregroundStyle(.tertiary)
            .padding(.leading, 13)
            .padding(.top, 10)
            .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private func editorContent(role: JSONEditorView.Role) -> some View {
        switch role {
        case .input:
            JSONEditorView(
                role: .input,
                text: model.inputText,
                onTextChange: { model.inputText = $0 },
                errorJump: model.errorJump
            )
            .id("input-editor")
        case .output:
            JSONEditorView(role: .output, text: model.outputText)
                .id("output-editor")
        }
    }

    // MARK: - 动作

    private func presentDiffWindow() {
        model.presentDiff()
        openWindow(id: "diff")
    }

    private func handleImport(_ result: Result<URL, Error>) {
        guard case .success(let url) = result else { return }
        let accessing = url.startAccessingSecurityScopedResource()
        defer {
            if accessing {
                url.stopAccessingSecurityScopedResource()
            }
        }
        if let text = try? String(contentsOf: url, encoding: .utf8) {
            model.inputText = text
        } else {
            importFailed = true
        }
    }
}

/// 把持久化的编辑器偏好灌进 `AppModel`。
///
/// 偏好存在 `UserDefaults`（`@AppStorage`），管线参数活在 `AppModel` 里，
/// 中间需要一次显式同步：设置面板在独立窗口改值，主窗口不会收到视图级
/// 通知，只有 `UserDefaults` 的 KVO 通知——`@AppStorage` 正是靠它更新的，
/// 所以这里监听同一个 `@AppStorage` 属性即可覆盖「设置里改」与
/// 「跨会话启动」两条路径。
///
/// 仅在值真的变化时才写回，避免每次视图重建都触发一次全量重排；
/// `reformat()` 本身也会取消上一次任务，重复调用不会堆积。
private struct EditorPreferenceSync: ViewModifier {
    let keyOrder: JSONKeyOrder
    let model: AppModel

    func body(content: Content) -> some View {
        content
            .onAppear { model.keyOrder = keyOrder }
            .onChange(of: keyOrder) { _, newValue in
                model.keyOrder = newValue
            }
    }
}

private extension View {
    func syncingEditorPreferences(
        keyOrder: JSONKeyOrder,
        into model: AppModel
    ) -> some View {
        modifier(EditorPreferenceSync(keyOrder: keyOrder, model: model))
    }
}

/// `fileExporter` 需要的最小 FileDocument 包装：导出格式化结果。
struct JSONExportDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.json]

    var text: String

    init(text: String) {
        self.text = text
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        text = String(decoding: data, as: UTF8.self)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}
