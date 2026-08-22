import SwiftUI

/// 主界面：双栏编辑器 + 玻璃工具栏 + 底部状态栏。
struct MainEditorView: View {
    @Environment(AppModel.self) private var model
    @State private var splitFraction: CGFloat = 0.5
    /// 拖拽开始时的 splitFraction 快照；nil 表示不在拖拽中。
    @State private var dragStartFraction: CGFloat?

    var body: some View {
        GeometryReader { proxy in
            let leftWidth = proxy.size.width * splitFraction
            HStack(spacing: 0) {
                editorPane(
                    role: .input,
                    titleKey: "pane.input.title",
                    width: leftWidth
                )
                Divider()
                    .overlay {
                        // 可拖分隔条
                        Rectangle()
                            .fill(.clear)
                            .frame(width: 10)
                            .contentShape(Rectangle())
                            .gesture(
                                DragGesture(minimumDistance: 1)
                                    .onChanged { value in
                                        // 用 translation（相对拖拽起点的位移），不用
                                        // value.location——后者是相对这条会随 fraction
                                        // 移动的 10pt 热区的局部坐标，与运行中的
                                        // fraction 混算会形成反馈，时序不稳定。
                                        let start = dragStartFraction ?? splitFraction
                                        dragStartFraction = start
                                        let fraction =
                                            start + value.translation.width / proxy.size.width
                                        splitFraction = min(
                                            0.8,
                                            max(0.2, fraction)
                                        )
                                    }
                                    .onEnded { _ in
                                        dragStartFraction = nil
                                    }
                            )
                    }
                    .frame(width: 1)
                editorPane(
                    role: .output,
                    titleKey: "pane.output.title",
                    width: proxy.size.width - leftWidth
                )
            }
        }
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
        }
    }

    // MARK: - 编辑面板

    private func editorPane(role: JSONEditorView.Role, titleKey: LocalizedStringKey, width: CGFloat) -> some View {
        VStack(spacing: 0) {
            paneHeader(titleKey: titleKey, role: role)
            editorContent(role: role)
        }
        .frame(width: max(240, width))
        .clipped()
    }

    private func paneHeader(titleKey: LocalizedStringKey, role: JSONEditorView.Role) -> some View {
        HStack(spacing: 8) {
            Image(systemName: role == .input ? "square.and.pencil" : "checkmark.seal")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            Text(titleKey)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer()
            if role == .input {
                Text("\(model.inputLineCount) · \(model.inputCharacterCount)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .contentTransition(.numericText())
            } else {
                Text("\(model.outputLineCount)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .contentTransition(.numericText())
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    @ViewBuilder
    private func editorContent(role: JSONEditorView.Role) -> some View {
        switch role {
        case .input:
            JSONEditorView(
                role: .input,
                text: Binding(
                    get: { model.inputText },
                    set: { model.inputText = $0 }
                ),
                onTextChange: { newValue in
                    model.inputText = newValue
                }
            )
            .id("input-editor")
        case .output:
            JSONEditorView(
                role: .output,
                text: Binding(
                    get: { model.outputText },
                    set: { _ in }
                )
            )
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
    }

    private func copyOutput() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(model.outputText, forType: .string)
    }
}

import AppKit
