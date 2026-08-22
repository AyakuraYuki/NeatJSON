import SwiftUI
import Synchronization

/// JetBrains 风格 side-by-side diff 视图。
///
/// 性能要点（对应此前「弹窗要等很久、滚动卡」）：
/// - **所有** 计算都在后台：`init` 不再切行也不再算 diff（1 MB 输入光切行
///   就能卡住 sheet 的构建），弹窗立刻出现并显示进度态；
/// - 统计（+/-）在后台一次算好存进 `DiffDocument`，不再是每次 `body`
///   求值都要全量 `filter` 两遍的计算属性；
/// - 单个 `LazyVStack`，每行一次性渲染左右两半：视图数量减半、左右天然
///   对齐，且不再有逐行 `Divider()`；
/// - `ForEach(rows.indices)` 而非 `ForEach(Array(rows.enumerated()))`
///   （后者每次 `body` 都重建整个元组数组，左右列各一次）；
/// - 行内 word 高亮按可见行惰性计算并缓存，弹窗耗时与 modified 行数脱钩；
/// - 关闭 sheet 会真正取消后台计算。
///
/// 语义要点：左侧是**按当前缩进重排、但保留原始 key 顺序**的输入，
/// 右侧是排序后的输出。这样差异只反映键顺序与真实内容变化，
/// 而不是「压缩成一行 → 展开成 N 行」的整体替换。
struct DiffView: View {
    /// 原始输入（未经格式化）。
    let rawInput: String
    /// 已格式化并排序的输出。
    let formattedOutput: String
    /// 当前缩进风格，用于规范化左侧。
    let indent: IndentStyle

    @Environment(\.dismiss) private var dismiss

    /// nil = 正在后台计算
    @State private var document: DiffDocument?
    @State private var limits: DiffEngine.Limits = .balanced
    /// 行内高亮缓存。普通 class，不参与 SwiftUI 观察，在 body 里按需填充。
    @State private var inlineCache = InlineCache()
    /// 被用户展开的折叠块（按行下标）。
    @State private var expanded: Set<Int> = []

    private let rowHeight: CGFloat = 20
    private let gutterWidth: CGFloat = 52
    /// 变更点两侧保留的上下文行数，其余未变更行折叠。
    private static let collapseContext = 3

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            columnTitles
            Divider()
            content
        }
        .background(.thinMaterial)
        .frame(minWidth: 820, minHeight: 520)
        .task(id: limits) { await load() }
    }

    // MARK: - 加载

    private func load() async {
        document = nil
        inlineCache.reset()
        expanded = []

        let raw = rawInput
        let output = formattedOutput
        let style = indent
        let budget = limits
        let flag = CancellationFlag()

        let prepared = await withTaskCancellationHandler {
            await Task.detached(priority: .userInitiated) {
                DiffDocument.prepare(
                    rawInput: raw,
                    formattedOutput: output,
                    indent: style,
                    limits: budget,
                    isCancelled: { flag.isCancelled }
                )
            }.value
        } onCancel: {
            flag.cancel()
        }

        guard !Task.isCancelled else { return }
        document = prepared
    }

    // MARK: - 头部

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(String(localized: "diff.title", defaultValue: "Differences"))
                    .font(.headline)
                Text(
                    String(
                        localized: "diff.note.normalized",
                        defaultValue: "Input is reformatted with the current indentation; the diff shows key order and content changes only."
                    )
                )
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            }
            Spacer()
            if let document {
                if document.degraded {
                    degradedControls
                }
                HStack(spacing: 8) {
                    Label("\(document.insertions)", systemImage: "plus")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.green)
                    Label("\(document.deletions)", systemImage: "minus")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.red)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .glassEffect(.regular, in: .capsule)
            }
            Button {
                dismiss()
            } label: {
                Label(
                    String(localized: "action.close", defaultValue: "Close"),
                    systemImage: "xmark"
                )
            }
            .buttonStyle(.glass)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    /// 降级提示 + 精确重算入口。
    @ViewBuilder
    private var degradedControls: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
                .foregroundStyle(.orange)
            Text(String(localized: "diff.degraded", defaultValue: "Simplified"))
                .font(.system(size: 11, weight: .medium))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .glassEffect(.regular, in: .capsule)

        Button {
            limits = .exact
        } label: {
            Text(String(localized: "diff.exact", defaultValue: "Exact compare"))
        }
        .buttonStyle(.glass)
        .help(
            String(
                localized: "diff.exact.help",
                defaultValue: "Recompute without simplification. May take a while; closing this window cancels it."
            )
        )
    }

    private var columnTitles: some View {
        HStack(spacing: 0) {
            columnTitle(
                String(localized: "diff.left.title", defaultValue: "Input (normalized)")
            )
            columnTitle(
                String(localized: "diff.right.title", defaultValue: "Output (keys sorted)")
            )
        }
        .background(.bar)
    }

    private func columnTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.leading, gutterWidth)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 内容

    @ViewBuilder
    private var content: some View {
        if let document {
            VStack(spacing: 0) {
                // 完全没有差异时，正文仍然是一整块可展开的「未变更」，
                // 这里只加一条说明条，而不是用空态把内容藏起来。
                if document.isIdentical {
                    identicalBanner
                    Divider()
                }
                ScrollView(.vertical) {
                    LazyVStack(spacing: 0) {
                        ForEach(document.rows.indices, id: \.self) { index in
                            rowView(at: index, document: document)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .textSelection(.enabled)
                // 中缝：一条视口高度的线，而不是每行一个 Divider
                .overlay(alignment: .center) {
                    Rectangle()
                        .fill(.separator)
                        .frame(width: 1)
                        .allowsHitTesting(false)
                }
            }
        } else {
            placeholder(
                text: String(localized: "diff.computing", defaultValue: "Computing differences…")
            )
        }
    }

    private var identicalBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "equal.circle")
                .font(.system(size: 11))
            Text(
                String(
                    localized: "diff.identical",
                    defaultValue: "No differences — key order already matches."
                )
            )
            .font(.system(size: 11))
            Spacer(minLength: 0)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    /// 计算中的进度态。
    private func placeholder(text: String) -> some View {
        VStack(spacing: 10) {
            Spacer()
            ProgressView().controlSize(.large)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - 行

    @ViewBuilder
    private func rowView(at index: Int, document: DiffDocument) -> some View {
        let row = document.rows[index]
        if case .collapsed(let oldRange, let newRange) = row.kind {
            let isExpanded = expanded.contains(index)
            // 标记行常驻：折叠时点它展开，展开时点它收起
            collapsedRow(index: index, count: oldRange.count, isExpanded: isExpanded)
            if isExpanded {
                ForEach(0 ..< oldRange.count, id: \.self) { offset in
                    pairRow(
                        oldIndex: oldRange.lowerBound + offset,
                        newIndex: newRange.lowerBound + offset,
                        document: document
                    )
                }
            }
        } else {
            HStack(spacing: 0) {
                side(row, index: index, document: document, isOld: true)
                side(row, index: index, document: document, isOld: false)
            }
        }
    }

    /// 展开后的未变更行（左右同内容）。
    private func pairRow(oldIndex: Int, newIndex: Int, document: DiffDocument) -> some View {
        HStack(spacing: 0) {
            lineCell(
                text: document.oldLines[oldIndex],
                lineNumber: oldIndex + 1,
                tone: .unchanged,
                highlights: []
            )
            lineCell(
                text: document.newLines[newIndex],
                lineNumber: newIndex + 1,
                tone: .unchanged,
                highlights: []
            )
        }
    }

    private func collapsedRow(index: Int, count: Int, isExpanded: Bool) -> some View {
        Button {
            if isExpanded {
                expanded.remove(index)
            } else {
                expanded.insert(index)
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isExpanded ? "chevron.up.circle" : "chevron.down.circle")
                    .font(.system(size: 10))
                Text(
                    String(
                        localized: "diff.collapsed",
                        defaultValue: "\(count) unchanged lines"
                    )
                )
                .font(.system(size: 10, design: .monospaced))
                Spacer(minLength: 0)
            }
            .foregroundStyle(.secondary)
            .padding(.leading, gutterWidth)
            .frame(height: rowHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.08))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(
            isExpanded
                ? String(localized: "diff.collapse.hint", defaultValue: "Click to collapse")
                : String(localized: "diff.expand.hint", defaultValue: "Click to expand")
        )
    }

    @ViewBuilder
    private func side(
        _ row: DiffEngine.Row,
        index: Int,
        document: DiffDocument,
        isOld: Bool
    ) -> some View {
        switch row.kind {
        case .equal(let oldIndex, let newIndex):
            lineCell(
                text: isOld ? document.oldLines[oldIndex] : document.newLines[newIndex],
                lineNumber: (isOld ? oldIndex : newIndex) + 1,
                tone: .unchanged,
                highlights: []
            )
        case .delete(let oldIndex):
            // 右侧没有对应行 —— 旧实现在两侧都画了删除行，这里修正为占位。
            if isOld {
                lineCell(
                    text: document.oldLines[oldIndex],
                    lineNumber: oldIndex + 1,
                    tone: .removed,
                    highlights: []
                )
            } else {
                lineCell(text: "", lineNumber: nil, tone: .absent, highlights: [])
            }
        case .insert(let newIndex):
            if isOld {
                lineCell(text: "", lineNumber: nil, tone: .absent, highlights: [])
            } else {
                lineCell(
                    text: document.newLines[newIndex],
                    lineNumber: newIndex + 1,
                    tone: .added,
                    highlights: []
                )
            }
        case .modified(let oldIndex, let newIndex):
            let inline = inlineCache.ranges(
                row: index,
                oldLine: document.oldLines[oldIndex],
                newLine: document.newLines[newIndex],
                limits: limits
            )
            lineCell(
                text: isOld ? document.oldLines[oldIndex] : document.newLines[newIndex],
                lineNumber: (isOld ? oldIndex : newIndex) + 1,
                tone: isOld ? .removed : .added,
                highlights: isOld ? inline.oldRanges : inline.newRanges
            )
        case .collapsed:
            EmptyView()
        }
    }

    // MARK: - 单元格

    private enum Tone {
        case unchanged
        case added
        case removed
        /// 对侧不存在的占位行
        case absent

        var background: Color {
            switch self {
            case .unchanged, .absent: .clear
            case .added: Color.green.opacity(0.14)
            case .removed: Color.red.opacity(0.14)
            }
        }

        var edge: Color? {
            switch self {
            case .unchanged, .absent: nil
            case .added: Color.green.opacity(0.8)
            case .removed: Color.red.opacity(0.8)
            }
        }

        var highlight: Color {
            switch self {
            case .added: Color.green.opacity(0.32)
            case .removed: Color.red.opacity(0.32)
            case .unchanged, .absent: .clear
            }
        }
    }

    private func lineCell(
        text: String,
        lineNumber: Int?,
        tone: Tone,
        highlights: [Range<Int>]
    ) -> some View {
        HStack(spacing: 0) {
            Text(lineNumber.map(String.init) ?? "")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: gutterWidth - 8, alignment: .trailing)
                .padding(.trailing, 8)
            Group {
                if highlights.isEmpty {
                    Text(text.isEmpty ? " " : text)
                        .foregroundStyle(.primary)
                } else {
                    Text(attributed(text, highlights: highlights, tone: tone))
                }
            }
            .font(.system(size: 12, design: .monospaced))
            .lineLimit(1)
            .padding(.trailing, 12)
            Spacer(minLength: 0)
        }
        .frame(height: rowHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tone.background)
        .overlay(alignment: .leading) {
            if let edge = tone.edge {
                Rectangle().fill(edge).frame(width: 2)
            }
        }
    }

    /// 按字符区间切片拼接。旧实现对每个区间做两次 `index(offsetBy:)`，
    /// 那是 O(行长) 的定位；这里整行只走一遍。
    private func attributed(
        _ text: String,
        highlights: [Range<Int>],
        tone: Tone
    ) -> AttributedString {
        let chars = Array(text)
        var result = AttributedString()
        var cursor = 0
        for range in highlights {
            let lower = min(max(range.lowerBound, cursor), chars.count)
            let upper = min(max(range.upperBound, lower), chars.count)
            if cursor < lower {
                result += AttributedString(String(chars[cursor ..< lower]))
            }
            if lower < upper {
                var piece = AttributedString(String(chars[lower ..< upper]))
                piece.backgroundColor = tone.highlight
                result += piece
            }
            cursor = upper
        }
        if cursor < chars.count {
            result += AttributedString(String(chars[cursor ..< chars.count]))
        }
        return result
    }
}

// MARK: - 数据

/// 后台一次算好的可渲染 diff 数据。
struct DiffDocument: Sendable {
    var oldLines: [String]
    var newLines: [String]
    var rows: [DiffEngine.Row]
    var insertions: Int
    var deletions: Int
    var degraded: Bool

    var isIdentical: Bool { insertions == 0 && deletions == 0 }

    /// 规范化 + 切行 + diff，整套都可在后台线程执行。
    static func prepare(
        rawInput: String,
        formattedOutput: String,
        indent: IndentStyle,
        limits: DiffEngine.Limits,
        isCancelled: () -> Bool
    ) -> DiffDocument {
        // 左侧：按当前缩进重排，但保留原始 key 顺序。
        // 解析失败时退回原文（调用方已保证输入合法，这里只是防御）。
        let normalized: String
        if let value = try? JSONParser.parseThrowing(rawInput) {
            normalized = JSONSerializer.serialize(value, indent: indent, sortKeys: false)
        } else {
            normalized = rawInput
        }

        let oldLines = splitLines(normalized)
        let newLines = splitLines(formattedOutput)
        guard !isCancelled() else {
            return DiffDocument(
                oldLines: oldLines,
                newLines: newLines,
                rows: [],
                insertions: 0,
                deletions: 0,
                degraded: false
            )
        }

        let result = DiffEngine.diff(
            old: oldLines,
            new: newLines,
            limits: limits,
            collapseContext: 3,
            isCancelled: isCancelled
        )
        return DiffDocument(
            oldLines: oldLines,
            newLines: newLines,
            rows: result.rows,
            insertions: result.insertions,
            deletions: result.deletions,
            degraded: result.degraded
        )
    }

    /// 按 `\n` 切行。比 `components(separatedBy: .newlines)` 快得多
    /// （后者要走 CharacterSet 匹配），并兼容 CRLF。
    ///
    /// 末尾单个换行会被归一化掉：两侧是否带尾随换行属于书写习惯差异，
    /// 不该在 diff 里显示成一行增删。
    private static func splitLines(_ text: String) -> [String] {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map {
            $0.hasSuffix("\r") ? String($0.dropLast()) : String($0)
        }
        if lines.count > 1, lines[lines.count - 1].isEmpty {
            lines.removeLast()
        }
        return lines
    }
}

/// 行内高亮缓存。
///
/// 刻意用普通 class（非 `@Observable`）：在 `body` 里按需填充不会触发
/// SwiftUI 失效，只是纯记忆化。滚动时同一行反复渲染不必重算。
@MainActor
final class InlineCache {
    private var storage: [Int: DiffEngine.InlineRanges] = [:]

    func reset() {
        storage.removeAll(keepingCapacity: true)
    }

    func ranges(
        row: Int,
        oldLine: String,
        newLine: String,
        limits: DiffEngine.Limits
    ) -> DiffEngine.InlineRanges {
        if let cached = storage[row] { return cached }
        let computed = DiffEngine.inlineDiff(
            oldLine: oldLine,
            newLine: newLine,
            limits: limits
        )
        storage[row] = computed
        return computed
    }
}

/// 跨隔离域的取消标志。
///
/// `Task.detached` 不会随父任务取消，因此关闭 sheet 时用它通知 diff
/// 主循环提前退出（否则超大输入下后台会一直算到底）。
final class CancellationFlag: Sendable {
    private let flag = Atomic<Bool>(false)

    var isCancelled: Bool { flag.load(ordering: .relaxed) }

    func cancel() { flag.store(true, ordering: .relaxed) }
}
