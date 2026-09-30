import AppKit
import Foundation
import Observation

/// 应用状态容器：输入、上一次成功输出、错误、缩进设置。
///
/// 统计量（行数/字符数/是否空白）刻意做成**存储属性**而非计算属性：
/// 它们会被 pane header、状态栏、工具栏的 `disabled(...)` 反复读取，
/// 做成计算属性就等于每次 SwiftUI 更新都要把全文扫四五遍。1.3 MB 文本
/// 下单次渲染约 7 ms（行数 ×2、grapheme 字符数、trimmingCharacters），
/// 而输入若来自 `NSTextView.string` 这种桥接串，代价还要再翻十倍
/// —— 这是大文本键入卡顿的一大来源。文本在
/// `JSONEditorView` 的边界已转成原生连续存储（见 `contiguousText()`）。
@MainActor
@Observable
final class AppModel {
    /// 左侧输入区内容（由编辑器回调写入）。
    var inputText: String = "" {
        didSet { reformat() }
    }

    /// 上一次成功格式化的结果（右侧展示）。失败时保持不变。
    private(set) var outputText: String = ""

    /// 当前错误；nil 表示输入合法（或为空）。
    private(set) var lastError: JSONParseError?

    /// 缩进风格，切换后立即重排。
    var indent: IndentStyle = .spaces2 {
        didSet {
            guard indent != oldValue else { return }
            reformat()
        }
    }

    /// 对象 key 的排序规则，切换后立即重排。
    var keyOrder: JSONKeyOrder = .codepoint {
        didSet {
            guard keyOrder != oldValue else { return }
            reformat()
        }
    }

    /// diff 快照的代次。0 = 尚未生成过快照（diff 窗口显示空态）；
    /// 每次 `presentDiff()` 递增，diff 窗口以它为身份重建内容。
    private(set) var diffRevision = 0

    /// 文件导入/导出面板的呈现状态（由菜单命令置位，面板挂在主窗口上）。
    var importerPresented = false
    var exporterPresented = false

    /// 「跳到错误位置」请求。revision 递增一次，输入编辑器就响应一次。
    struct ErrorJump: Equatable {
        var line: Int
        var column: Int?
        var revision: Int
    }

    private(set) var errorJump: ErrorJump?

    /// diff 内容在弹出时快照，避免编辑期间窗口内数据变动。
    ///
    /// 只存**原始输入**：左侧的规范化（按当前缩进重排、保留原始 key 顺序）
    /// 在 diff 的后台任务里做，不占用每次键入的开销。
    private(set) var diffRawInput: String = ""
    private(set) var diffFormattedOutput: String = ""
    private(set) var diffIndent: IndentStyle = .spaces2

    /// 缓存统计：随输入/输出变化更新一次，渲染路径只读。
    private(set) var inputLineCount: Int = 0
    private(set) var outputLineCount: Int = 0
    private(set) var inputCharacterCount: Int = 0
    /// 输入是否只有空白（含全空）。
    private(set) var isInputBlank: Bool = true

    /// 供测试与预览注入。
    init(
        inputText: String = "",
        indent: IndentStyle = .spaces2,
        keyOrder: JSONKeyOrder = .codepoint
    ) {
        self.indent = indent
        self.keyOrder = keyOrder
        self.inputText = inputText
        // Swift 初始化期属性观察器不触发，这里显式执行首次格式化。
        reformat()
    }

    /// 大文档阈值：超过该字节数走防抖 + 后台计算。
    private static let asyncThreshold = 64 * 1024

    /// 输入快照对应的待执行格式化任务（新输入到来即取消）。
    private var reformatTask: Task<Void, Never>?

    /// 格式化管线：成功才更新 `outputText`，失败只记录错误。
    ///
    /// 小文档同步执行（保持键入即时反馈）；大文档防抖 250ms 并放到
    /// 后台线程解析/序列化，避免每次键入都在主线程跑全量管线。
    func reformat() {
        let text = inputText
        let indent = indent
        let keyOrder = keyOrder

        reformatTask?.cancel()
        reformatTask = nil

        // 这两项都是常数因子极小的单遍 UTF-8 扫描，同步算保证计数即时。
        isInputBlank = Self.isBlank(text)
        inputLineCount = Self.lineCount(of: text)

        if isInputBlank {
            // 空输入：立即清空输出、不报错。
            inputCharacterCount = text.count // 只有空白，长度可忽略
            outputText = ""
            outputLineCount = 0
            lastError = nil
            return
        }

        if text.utf8.count <= Self.asyncThreshold {
            inputCharacterCount = text.count
            applyFormatResult(
                Self.computeFormat(text: text, indent: indent, keyOrder: keyOrder)
            )
            return
        }

        reformatTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            // 字符数是 grapheme 计数（1 MB 要十几毫秒），和解析一起丢后台。
            let outcome = await Task.detached(priority: .userInitiated) {
                (
                    characters: text.count,
                    result: Self.computeFormat(
                        text: text, indent: indent, keyOrder: keyOrder
                    )
                )
            }.value
            guard !Task.isCancelled, let self else { return }
            self.inputCharacterCount = outcome.characters
            self.applyFormatResult(outcome.result)
        }
    }

    /// 解析 + 排序 + 序列化的纯计算部分（可安全地在任意线程执行）。
    private nonisolated static func computeFormat(
        text: String,
        indent: IndentStyle,
        keyOrder: JSONKeyOrder
    ) -> Result<String, JSONParseError> {
        do {
            let value = try JSONParser.parse(text)
            // 不补尾随换行：编辑器里那会多出一个空行，复制出去也多一个换行。
            return .success(
                JSONSerializer.serialize(
                    value,
                    indent: indent,
                    keyOrder: keyOrder,
                    trailingNewline: false
                )
            )
        } catch let error as JSONParseError {
            return .failure(error)
        } catch {
            return .failure(JSONParseError(
                message: error.localizedDescription,
                line: nil,
                column: nil
            ))
        }
    }

    private func applyFormatResult(_ result: Result<String, JSONParseError>) {
        switch result {
        case .success(let output):
            outputText = output
            outputLineCount = Self.lineCount(of: output)
            lastError = nil
        case .failure(let error):
            lastError = error
        }
    }

    /// 是否可打开 diff：输入非空、有成功输出、且当前无错误。
    var canShowDiff: Bool {
        !isInputBlank && !outputText.isEmpty && lastError == nil
    }

    /// 弹出 diff 前快照两侧内容与缩进。
    func presentDiff() {
        guard canShowDiff else { return }
        diffRawInput = inputText
        diffFormattedOutput = outputText
        diffIndent = indent
        diffRevision += 1
    }

    func clearAll() {
        inputText = ""
    }

    /// 把格式化结果写入系统剪贴板。
    func copyOutput() {
        guard !outputText.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(outputText, forType: .string)
    }

    /// 当前错误是否带可跳转的位置信息。
    var canJumpToError: Bool {
        lastError?.line != nil
    }

    /// 请求把输入编辑器的光标移动到当前错误的位置。
    func requestErrorJump() {
        guard let error = lastError, let line = error.line else { return }
        errorJump = ErrorJump(
            line: line,
            column: error.column,
            revision: (errorJump?.revision ?? 0) + 1
        )
    }

    // MARK: - 单遍扫描工具

    /// 数换行。
    ///
    /// 走 UTF-8 视图是安全的：多字节序列的续字节恒 ≥ 0x80，不会误判成 0x0A。
    /// 优先在连续存储上跑紧凑循环（1.3 MB 文本 0.5 ms，走 `utf8` 序列迭代
    /// 是 2.0 ms）；拿不到连续缓冲区时退回通用迭代。
    ///
    /// 真正的提速来自调用次数：旧实现是计算属性，pane header 与状态栏每次
    /// 渲染都要各扫一遍全文；现在只在输入/输出变化时算一次。
    private static func lineCount(of text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        if let counted = text.utf8.withContiguousStorageIfAvailable({ buffer -> Int in
            var count = 1
            for byte in buffer where byte == 0x0A {
                count += 1
            }
            return count
        }) {
            return counted
        }
        var count = 1
        for byte in text.utf8 where byte == 0x0A {
            count += 1
        }
        return count
    }

    /// 是否只含空白。遇到第一个非空白字节立刻返回，不做任何分配。
    ///
    /// 替掉的是旧 `canShowDiff` 里的 `trimmingCharacters(in:).isEmpty`
    /// （1.3 MB 文本约 40 µs，且要过一次 CharacterSet 与 NSString 桥）。
    /// 这里通常在头几个字节就返回，实测低于 1 µs。
    private static func isBlank(_ text: String) -> Bool {
        for byte in text.utf8 where byte != 0x20 && byte != 0x09
            && byte != 0x0A && byte != 0x0D
        {
            return false
        }
        return true
    }
}
