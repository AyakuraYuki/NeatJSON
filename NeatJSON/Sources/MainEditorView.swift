import AppKit
import SwiftUI

/// 主界面：左右两块玻璃卡片编辑器 + 玻璃工具栏 + 底部状态栏。
///
/// 卡片等宽、固定 1:1，无分隔条与拖拽。卡片以 regularMaterial 浮在
/// thinMaterial 窗口底色上；文本视图本体不画背景（见 JSONTextView），
/// 让材质透出来。
struct MainEditorView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(PreferenceKey.editorFontSize) private var editorFontSize: Double = 13

    var body: some View {
        HStack(spacing: 16) {
            editorCard(role: .input)
            editorCard(role: .output)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.thinMaterial)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            StatusBarView()
        }
        .toolbar {
            ToolbarSpacer(.fixed, placement: .navigation)
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.clearAll()
                } label: {
                    Label(
                        String(localized: "action.clear", defaultValue: "Clear"),
                        systemImage: "trash"
                    )
                }
                .buttonStyle(.glass)
                .pressFeedback()
                .keyboardShortcut("k", modifiers: .command)
                .help(String(localized: "action.clear.help", defaultValue: "Clear input"))
                .disabled(model.inputText.isEmpty)
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    copyOutput()
                } label: {
                    Label(
                        String(localized: "action.copy", defaultValue: "Copy"),
                        systemImage: "doc.on.doc"
                    )
                }
                .buttonStyle(.glass)
                .pressFeedback()
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .help(String(localized: "action.copy.help", defaultValue: "Copy formatted result"))
                .disabled(model.outputText.isEmpty)
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.presentDiff()
                } label: {
                    Label(
                        String(localized: "action.diff", defaultValue: "Compare"),
                        systemImage: "arrow.left.arrow.right"
                    )
                }
                .buttonStyle(.glassProminent)
                .pressFeedback()
                .keyboardShortcut("d", modifiers: .command)
                .help(String(localized: "action.diff.help", defaultValue: "Compare input and output"))
                .disabled(!model.canShowDiff)
            }
            ToolbarItem(placement: .primaryAction) {
                indentPicker
            }
        }
        .navigationTitle("NeatJSON")
        .sheet(isPresented: Bindable(model).diffPresented) {
            DiffView(
                rawInput: model.diffRawInput,
                formattedOutput: model.diffFormattedOutput,
                indent: model.diffIndent
            )
            .presentationSizing(.fitted)
        }
    }

    // MARK: - 编辑卡片

    private static let cardCornerRadius: CGFloat = 14

    private var cardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Self.cardCornerRadius, style: .continuous)
    }

    private func editorCard(role: JSONEditorView.Role) -> some View {
        editorContent(role: role)
            .background(.regularMaterial, in: cardShape)
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
                onTextChange: { model.inputText = $0 }
            )
            .id("input-editor")
        case .output:
            JSONEditorView(role: .output, text: model.outputText)
                .id("output-editor")
        }
    }

    // MARK: - 缩进选择

    private var indentPicker: some View {
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

    private func copyOutput() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(model.outputText, forType: .string)
    }
}

/// 工具栏按钮按下反馈：`.glass` / `.glassProminent` 按下时视觉变化很弱，
/// 单靠系统样式很难判断是否点中，用这个修饰符叠加缩放 + 透明度动画。
private struct ButtonPressFeedback: ViewModifier {
    @State private var isPressed = false
    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        content
            .scaleEffect(isPressed ? 0.94 : 1)
            .opacity(isPressed ? 0.7 : 1)
            .animation(.easeOut(duration: 0.12), value: isPressed)
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in if isEnabled { isPressed = true } }
                    .onEnded { _ in isPressed = false }
            )
    }
}

private extension View {
    func pressFeedback() -> some View {
        modifier(ButtonPressFeedback())
    }
}
