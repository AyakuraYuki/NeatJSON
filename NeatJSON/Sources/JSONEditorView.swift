import AppKit
import SwiftUI

/// NSTextView 包装。
///
/// 左侧（可编辑）与右侧（只读可选 + 语法高亮）共用一个实现，
/// 以 `role` 区分行为差异。
///
/// 着色策略（见 `Coordinator`）：
/// - 外部整体替换（粘贴、清空、格式化结果变化、字号/外观变化）→ 后台扫描 +
///   主线程一次套用；
/// - 输入区打字 → 只重刷编辑点所在的行，代价与文档大小无关。
///   这同时修掉了一个既存 bug：旧实现里 `updateNSView` 的
///   `current != text` 在打字路径上恒为假，输入区**从不**重新着色，
///   新键入的内容会一直保持上一次的颜色。
struct JSONEditorView: NSViewRepresentable {
    enum Role {
        /// 输入区：可编辑，文本变化通过 `onTextChange` 上报。
        case input
        /// 输出区：只读可选，`text` 变化时整体替换并重新着色。
        case output
    }

    let role: Role
    /// 要展示的文本（数据只从上往下流）。
    /// 输入区：仅当外部值 ≠ 内部值时才 setString，防光标跳动；用户键入
    /// 一律经 `onTextChange` 上报，本视图不通过绑定写回。
    /// 输出区：格式化结果。
    let text: String
    var onTextChange: ((String) -> Void)? = nil

    @AppStorage(PreferenceKey.editorFontSize) private var storedFontSize: Double = 13

    var editorFont: NSFont {
        NSFont.monospacedSystemFont(ofSize: storedFontSize, weight: .regular)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = JSONTextView()
        // 关键：makeNSView 阶段 scrollView 还是零尺寸，documentView 赋值时
        // textView 只能拿到 0 宽；之后 SwiftUI 布局把 scrollView 撑大时，
        // 靠 autoresizingMask 让 textView 宽度跟随 clipView，否则宽度永远
        // 是 0——文本虽在、属性也对，但视图 bounds 为空导致完全不绘制。
        textView.autoresizingMask = [.width]
        textView.string = text
        textView.font = editorFont
        textView.isRichText = false
        // 背景由外层玻璃卡片的 material 提供，文本视图自身保持透明，
        // 正文/token 用固定 sRGB 色（见 JSONTextView / JSONSyntaxHighlighter）。
        textView.drawsBackground = false
        // 用 textContainerInset 做卡片内边距（替代旧的 scrollView.contentInsets），
        // 占位提示的位置也按它对齐。
        textView.textContainerInset = NSSize(width: 8, height: 10)
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        // 背景与文字颜色使用固定语义，随深浅模式手动切换：
        // 动态 NSColor 存进 textStorage 后在 Liquid Glass 材质上下文中
        // 可能解析到错误变体（浅色下出近白文字），因此绘制前由
        // JSONTextView.resolveColors() 按当前外观解析成具体色。
        textView.resolveColors()
        // 大文档关键优化：非连续布局只排版可见区域，
        // 滚动/编辑时不再每次全量布局整个文本。
        textView.layoutManager?.allowsNonContiguousLayout = true
        // 图层化：滚动走合成路径，不必每帧重绘整个可见区。
        textView.wantsLayer = true

        // 输入区可编辑，输出区只读；两个区都可选中复制。
        textView.isEditable = role == .input
        textView.isSelectable = true

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.hasVerticalRuler = false
        scrollView.borderType = .noBorder
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.wantsLayer = true
        // 透明：透出卡片的玻璃材质
        scrollView.drawsBackground = false

        let coordinator = context.coordinator
        coordinator.textView = textView
        coordinator.onTextChange = onTextChange
        coordinator.font = editorFont
        textView.delegate = coordinator
        textView.highlightController = coordinator
        // 打字时的增量着色靠 textStorage 的 didProcessEditing 驱动
        textView.textStorage?.delegate = coordinator

        coordinator.noteInitialText(text)

        // 初次着色（两个区都着色，保证基础文字色正确）
        coordinator.refreshAll()
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? JSONTextView else { return }
        let coordinator = context.coordinator
        coordinator.onTextChange = onTextChange

        // 字号变化才重设字体（setFont: 会触发全量布局，每次 SwiftUI
        // 更新都设一遍是大文本卡顿的来源之一）
        let fontChanged = textView.font != editorFont
        if fontChanged {
            textView.font = editorFont
            coordinator.font = editorFont
        }

        if coordinator.appliedText != text {
            // 外部赋值（粘贴、清空、格式化结果变化）
            coordinator.replaceText(text)
            if role == .output {
                scrollToTop(scrollView)
            }
        } else if fontChanged {
            // 文本相同、仅字体变化时才重着色；其余 SwiftUI 更新
            // （状态栏计数等）不再触发全量重着色。
            // 外观切换由 JSONTextView.viewDidChangeEffectiveAppearance 负责。
            coordinator.refreshAll()
        }
    }

    private func scrollToTop(_ scrollView: NSScrollView) {
        scrollView.contentView.scroll(.zero)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onTextChange: onTextChange, font: editorFont)
    }

    /// 兼 text view delegate、text storage delegate 与着色控制器。
    ///
    /// `NSTextStorageDelegate` 在 SDK 里没有 `@MainActor` 标注（NSTextStorage
    /// 本身允许脱离主线程使用），因此这里用 `@preconcurrency` 声明一致性：
    /// 我们的 text storage 只会被主线程上的 text view 编辑，回调必然在主线程，
    /// 由运行时断言兜底。
    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate, @preconcurrency NSTextStorageDelegate {
        var onTextChange: ((String) -> Void)?
        var font: NSFont
        weak var textView: JSONTextView?
        /// 最近一次「已同步到 text view」的文本（原生连续存储）。
        ///
        /// `updateNSView` 用它和 SwiftUI 传下来的值比较，而不是拿
        /// `textView.string` 比 —— 后者是桥接串，每次渲染都比一遍大文本很贵；
        /// 而这里两侧通常就是同一个字符串实例，`==` 会走存储相同的快路径。
        private(set) var appliedText: String = ""

        /// 异步扫描的代次：任何一次文本变化都会 +1，在途的旧结果因此作废。
        private var generation = 0
        private var pendingScan: Task<Void, Never>?
        /// 正在做外部整体替换 —— 期间不要触发增量着色。
        private var isReplacing = false
        /// 待重刷的范围（多次连续编辑合并成一个）。
        private var pendingRange: NSRange?
        private var flushScheduled = false
        /// 分块上色被中途打断过，文档尾部还没上色，需要补一次完整的。
        private var needsFullRefresh = false
        private var deferredRefresh: Task<Void, Never>?

        /// 小于这么多 UTF-16 码元就直接同步扫描：避免小文档闪一下无色。
        private static let syncScanUnits = 128 * 1024
        /// 增量着色时向编辑点前后各搜索多远来找行边界。
        private static let boundarySearchWindow = 8 * 1024

        init(onTextChange: ((String) -> Void)?, font: NSFont) {
            self.onTextChange = onTextChange
            self.font = font
        }

        // MARK: 着色

        private var style: JSONSyntaxHighlighter.RenderStyle? {
            guard let textView else { return nil }
            return JSONSyntaxHighlighter.RenderStyle(
                font: font,
                palette: .current(for: textView)
            )
        }

        /// 全量重着色。大文档在后台扫描，主线程只做一次属性套用。
        func refreshAll() {
            guard let textView, let storage = textView.textStorage, let style else { return }
            generation += 1
            let token = generation
            pendingScan?.cancel()
            pendingScan = nil
            deferredRefresh?.cancel()
            deferredRefresh = nil
            // 这一趟就是完整的一遍；只有被打断时才会重新置位
            needsFullRefresh = false

            // 批量拷出 UTF-16（0.5 ms 级），后台只吃这份纯值缓冲区
            let units = JSONSyntaxHighlighter.utf16Units(of: storage)
            if units.count <= Self.syncScanUnits {
                JSONSyntaxHighlighter.apply(
                    JSONSyntaxHighlighter.scan(units: units),
                    to: storage,
                    style: style
                )
                return
            }
            pendingScan = Task { [weak self] in
                let result = await Task.detached(priority: .userInitiated) {
                    JSONSyntaxHighlighter.scan(units: units)
                }.value
                guard !Task.isCancelled, let self, self.generation == token,
                      let storage = self.textView?.textStorage, let style = self.style,
                      storage.length == result.utf16Length
                else { return }
                JSONSyntaxHighlighter.applyBase(to: storage, style: style)
                // 分块套用，块间让出主线程：大文档不会因为一次套 十几万 个属性掉帧
                var index = 0
                while index < result.spans.count {
                    let end = min(index + JSONSyntaxHighlighter.applyChunkSize, result.spans.count)
                    JSONSyntaxHighlighter.applySpans(
                        result.spans[index ..< end],
                        to: storage,
                        palette: style.palette
                    )
                    index = end
                    guard index < result.spans.count else { break }
                    await Task.yield()
                    // 让出期间文本可能已被改写，这一代结果作废。
                    // 此时尾部还没上色，标记一下等打字停下来补一遍完整的。
                    guard !Task.isCancelled, self.generation == token,
                          storage.length == result.utf16Length
                    else {
                        self.needsFullRefresh = true
                        return
                    }
                }
            }
        }

        /// 外部整体替换文本，随后整体重着色。
        func replaceText(_ newText: String) {
            guard let textView else { return }
            isReplacing = true
            textView.string = newText
            isReplacing = false
            appliedText = newText
            pendingRange = nil
            refreshAll()
        }

        /// 供 makeNSView 记录初始内容。
        func noteInitialText(_ text: String) {
            appliedText = text
        }

        /// 外观（深浅色）变化后重解析配色并全量重着色。
        func appearanceDidChange() {
            refreshAll()
        }

        // MARK: NSTextStorageDelegate —— 增量着色

        func textStorage(
            _ textStorage: NSTextStorage,
            didProcessEditing editedMask: NSTextStorageEditActions,
            range editedRange: NSRange,
            changeInLength delta: Int
        ) {
            // 只关心字符变化：我们自己套属性时会带 .editedAttributes 再进来一次，
            // 这个 guard 同时起到防重入的作用。
            guard editedMask.contains(.editedCharacters), !isReplacing else { return }
            // 让在途的全量扫描结果作废（它对应的是旧文本）
            generation += 1

            let target = rehighlightRange(for: editedRange, in: textStorage)
            pendingRange = pendingRange.map { NSUnionRange($0, target) } ?? target
            guard !flushScheduled else { return }
            flushScheduled = true
            // 不在 didProcessEditing 内部直接改属性：延到下一个主线程回合，
            // 避开 NSTextStorage 的属性修正重入，并把连续输入合并成一次。
            Task { @MainActor [weak self] in
                self?.flushPendingHighlight()
            }
        }

        private func flushPendingHighlight() {
            flushScheduled = false
            guard let range = pendingRange, let storage = textView?.textStorage, let style
            else {
                pendingRange = nil
                return
            }
            pendingRange = nil
            let clamped = NSIntersectionRange(
                range,
                NSRange(location: 0, length: storage.length)
            )
            if clamped.length > 0 {
                JSONSyntaxHighlighter.highlight(storage, range: clamped, style: style)
            }
            if needsFullRefresh {
                scheduleDeferredFullRefresh()
            }
        }

        /// 打字停下来之后补一遍完整着色。
        ///
        /// 连续输入期间只走增量路径（每次 0.2 ms 级），完整的那一遍推到
        /// 手停下来再做，避免边打字边反复启动又中断全量上色。
        private func scheduleDeferredFullRefresh() {
            deferredRefresh?.cancel()
            deferredRefresh = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled, let self, self.needsFullRefresh else { return }
                self.refreshAll()
            }
        }

        /// 把编辑范围扩展到词法安全的边界。
        ///
        /// JSON 字符串不允许包含裸换行，所以行首一定不在字符串内部，是安全的
        /// 分词起点。搜索被限制在编辑点前后各一个窗口内 —— 这样即便整份文档
        /// 是压缩成一行的巨型 JSON，单次键入的代价也是常数级（代价是极少数
        /// 情况下窗口边界处着色可能不准，任何一次整体替换都会自愈）。
        private func rehighlightRange(for edited: NSRange, in storage: NSTextStorage) -> NSRange {
            let text = storage.mutableString
            let length = text.length
            let start = min(max(edited.location, 0), length)
            let end = min(max(NSMaxRange(edited), start), length)

            let searchLower = max(0, start - Self.boundarySearchWindow)
            let searchUpper = min(length, end + Self.boundarySearchWindow)

            var lower = searchLower
            if start > searchLower {
                let before = text.range(
                    of: "\n",
                    options: .backwards,
                    range: NSRange(location: searchLower, length: start - searchLower)
                )
                if before.location != NSNotFound {
                    lower = NSMaxRange(before)
                }
            }

            var upper = searchUpper
            if searchUpper > end {
                let after = text.range(
                    of: "\n",
                    range: NSRange(location: end, length: searchUpper - end)
                )
                if after.location != NSNotFound {
                    upper = NSMaxRange(after)
                }
            }

            return NSRange(location: lower, length: max(0, upper - lower))
        }

        // MARK: NSTextViewDelegate

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            // 关键：转成原生连续存储再往上传。textView.string 是懒桥接的
            // NSString，之后每一次统计/解析/diff 都要过桥（实测 1.3 MB
            // 文档光数一遍换行就要 28 ms，原生只要 0.7 ms）。
            let text = textView.contiguousText()
            appliedText = text
            onTextChange?(text)
        }
    }
}

/// 自定义 NSTextView：透明背景（玻璃卡片透出材质）+ 按外观固定的插入点颜色，
/// 并在外观变化时通知着色控制器。
final class JSONTextView: NSTextView {
    /// 外观变化后需要它来重着色（弱引用，controller 由 SwiftUI 持有）。
    weak var highlightController: JSONEditorView.Coordinator?

    /// 把插入点颜色解析为当前外观下的具体色。
    ///
    /// 背景不在此设置：文本视图保持透明，由卡片材质提供底色（见
    /// MainEditorView.editorCard）。正文色由 `JSONSyntaxHighlighter`
    /// 随 token 着色铺固定 sRGB 值——动态 NSColor 存进 NSTextStorage 后
    /// 要等绘制时才按当时外观解析，在玻璃材质上下文中有落到错误变体的
    /// 风险，固定色保证深浅模式下行为可预期。
    func resolveColors() {
        insertionPointColor = isDarkAppearance ? colorDarkText : colorLightText
    }

    /// 取出内容，并保证是**原生连续存储**的 Swift String。
    ///
    /// `NSTextView.string` 给的是懒桥接 NSString 的 String：非连续存储，
    /// 之后每一次逐字符/逐字节访问都要过桥。实测 1.3 MB 文档：
    /// - 直接拿它数一遍换行 28 ms，转成原生后 0.7 ms；
    /// - 解析器入口 `Array(unicodeScalars)` 从 27 ms 降到 7 ms。
    ///
    /// 转换本身走「批量取 UTF-8 字节 + 解码」这条最快的路：1.7 ms。
    /// （对比：`makeContiguousUTF8()` 31 ms，经 UTF-16 中转 54 ms。）
    func contiguousText() -> String {
        guard let storage = textStorage else { return string }
        let source = storage.mutableString
        let range = NSRange(location: 0, length: source.length)
        guard range.length > 0 else { return "" }

        let capacity = source.maximumLengthOfBytes(using: String.Encoding.utf8.rawValue)
        var bytes = [UInt8](repeating: 0, count: capacity)
        var used = 0
        let converted = bytes.withUnsafeMutableBufferPointer { buffer -> Bool in
            source.getBytes(
                buffer.baseAddress!,
                maxLength: capacity,
                usedLength: &used,
                encoding: String.Encoding.utf8.rawValue,
                options: [],
                range: range,
                remaining: nil
            )
        }
        guard converted else {
            // 极少数情况（如存在未配对代理项）转不出 UTF-8，退回通用做法
            var fallback = string
            fallback.makeContiguousUTF8()
            return fallback
        }
        return String(decoding: bytes[0 ..< used], as: UTF8.self)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // 挂上 window 后外观才可信：重解析插入点颜色并重着色
        resolveColors()
        highlightController?.appearanceDidChange()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        // 系统深浅色切换后，固定色属性不会自动重算，
        // 需要重新解析颜色并对全文重着色。
        resolveColors()
        highlightController?.appearanceDidChange()
    }
}
