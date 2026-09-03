import AppKit
import SwiftUI
import Synchronization

/// diff 独立窗口的内容：读取 AppModel 里的快照。
///
/// 以 `diffRevision` 作为 `DiffView` 的身份：每次 ⌘D 都是新快照，
/// 视图整体重建、内部 @State（折叠展开、精确重算开关）随之归零。
/// 用户从 Window 菜单直接打开窗口而尚无快照时显示空态。
struct DiffWindowView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.diffRevision > 0 {
            DiffView(
                rawInput: model.diffRawInput,
                formattedOutput: model.diffFormattedOutput,
                indent: model.diffIndent
            )
            .id(model.diffRevision)
        } else {
            VStack(spacing: 10) {
                Image(systemName: "arrow.left.arrow.right")
                    .font(.system(size: 28))
                    .foregroundStyle(.tertiary)
                Text(
                    String(
                        localized: "diff.empty",
                        defaultValue: "Nothing to compare yet"
                    )
                )
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                Text(
                    String(
                        localized: "diff.empty.hint",
                        defaultValue: "Enter valid JSON in the main window, then press ⌘D."
                    )
                )
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            }
            .frame(minWidth: 820, minHeight: 520)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.thinMaterial)
        }
    }
}

/// JetBrains 风格 side-by-side diff 视图。
///
/// 结构：SwiftUI 负责外壳（头部、统计胶囊、列标题、进度态），正文两栏
/// 交给 AppKit（`DiffSideBySidePane`）。此前正文是 SwiftUI 的
/// `ScrollView(.vertical)` 内嵌 `ScrollView(.horizontal)`，在 macOS 上
/// 嵌套异轴 ScrollView 的滚轮事件全部被外层吞掉，横向始终滚不动；
/// 且内层 LazyVStack 拿到的是无界高度提案，惰性也名存实亡。
/// 现改为每栏一个原生 `NSScrollView`（不换行 NSTextView），像文本编辑器
/// 一样上下、左右自由滚动：
/// - 行号用 `NSRulerView` 实现，横向滚动时天然钉在左侧不被卷走；
/// - 左右两栏纵向滚动用 clip view 的 bounds 通知互相镜像，零延迟同步；
///   横向滚动互不影响；
/// - 行底色/行内高亮由 `DiffPaneTextView` 自绘：行底色铺满整栏宽度
///   （包括横向滚出的部分），高亮矩形按 layoutManager 的字形位置精确定位；
/// - 文本可选中、可复制、支持 ⌘F 查找。
///
/// 性能要点（对应此前「弹窗要等很久、滚动卡」）：
/// - **所有** 计算都在后台：`init` 不切行也不算 diff，弹窗立刻出现并显示
///   进度态；行内 word 高亮也在后台随 diff 一并算好（`DiffDocument.inline`）；
/// - 统计（+/-）在后台一次算好存进 `DiffDocument`；
/// - 折叠/展开后的可渲染行统一物化成 `DiffRenderRow` 数组，左右两栏
///   从结构上保证行数一致、逐行对齐；
/// - NSTextView 开启非连续布局，只排版可见区域；
/// - 关闭窗口会真正取消后台计算。
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

    @Namespace private var headerGlassNamespace

    /// nil = 正在后台计算
    @State private var document: DiffDocument?
    @State private var limits: DiffEngine.Limits = .balanced
    /// 被用户展开的折叠块（按行下标）。
    @State private var expanded: Set<Int> = []
    /// 左/右两栏的可渲染行（已按 `expanded` 展开），行数恒相等。
    @State private var oldRows: [DiffRenderRow] = []
    @State private var newRows: [DiffRenderRow] = []
    /// 行内容的代次。AppKit 层以它判断是否需要重建文本，
    /// 避免 SwiftUI 每次 body 求值都触发 O(行数) 的数组比较。
    @State private var revision = 0

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
        expanded = []
        oldRows = []
        newRows = []

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
        rebuildRows(with: prepared)
    }

    /// 展开/收起一个折叠块，并同步重建两栏的渲染行。
    /// 左右两栏的折叠条都调用这一个函数，`Set` 的 insert/remove 天然幂等。
    private func toggleExpanded(_ index: Int) {
        if expanded.contains(index) {
            expanded.remove(index)
        } else {
            expanded.insert(index)
        }
        guard let document else { return }
        rebuildRows(with: document)
    }

    private func rebuildRows(with document: DiffDocument) {
        let flat = flatten(document: document, expanded: expanded)
        oldRows = renderRows(document: document, flatRows: flat, expanded: expanded, isOld: true)
        newRows = renderRows(document: document, flatRows: flat, expanded: expanded, isOld: false)
        revision += 1
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
            // 只把两个手写 .glassEffect() 的自定义视图（降级徽章 + 统计
            // 胶囊）用容器组合：Apple 建议多个玻璃视图要用
            // GlassEffectContainer 组合以获得最佳渲染表现，并在它们
            // 出现/消失时协调走形变过渡而不是突然蹦出来。spacing 用 8，
            // 和内部 HStack 的间距一致，避免静止时也非预期地粘在一起。
            //
            // "Exact compare" 留在容器外、维持原样：它用的是系统
            // .buttonStyle(.glass)，是系统自己管理优化过的原生玻璃控件，
            // 不是需要容器帮忙合成/形变的手写玻璃形状。
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    if let document, document.degraded {
                        degradedBadge
                    }
                    if let document {
                        statsCapsule(document)
                    }
                }
            }
            if let document, document.degraded {
                exactCompareButton
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    /// 头部手写玻璃胶囊的公共样板：内边距 + 胶囊玻璃 + 形变过渡身份。
    private func headerCapsule(id: String, @ViewBuilder content: () -> some View) -> some View {
        content()
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .glassEffect(.regular, in: .capsule)
            .glassEffectID(id, in: headerGlassNamespace)
            .glassEffectTransition(.matchedGeometry)
    }

    /// 降级提示徽章（手写玻璃胶囊，进容器）。
    private var degradedBadge: some View {
        headerCapsule(id: "degraded") {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                Text(String(localized: "diff.degraded", defaultValue: "Simplified"))
                    .font(.system(size: 11, weight: .medium))
            }
        }
    }

    /// 精确重算入口（系统玻璃按钮，容器外）。
    private var exactCompareButton: some View {
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

    /// 插入/删除行数统计胶囊（手写玻璃胶囊，进容器）。
    private func statsCapsule(_ document: DiffDocument) -> some View {
        headerCapsule(id: "stats") {
            HStack(spacing: 8) {
                Label("\(document.insertions)", systemImage: "plus")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.green)
                Label("\(document.deletions)", systemImage: "minus")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.red)
            }
        }
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
            .padding(.leading, DiffPaneMetrics.gutterWidth)
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
                DiffSideBySidePane(
                    oldRows: oldRows,
                    newRows: newRows,
                    revision: revision,
                    onToggle: toggleExpanded
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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
}

// MARK: - 行渲染辅助类型

/// 展开折叠块后的扁平行描述。左右两栏共用同一份数组生成渲染行，
/// 从结构上保证下标永远对齐。
enum FlatRow {
    /// 非折叠行，对应 `document.rows[index]`。
    case row(Int)
    /// 折叠提示条本身（「N 处未更改」）。
    case collapsedHeader(Int)
    /// 折叠块展开后的一行未变更配对。
    case collapsedPair(headerIndex: Int, oldIndex: Int, newIndex: Int)
}

/// 把 `document.rows` 按 `expanded` 展开成的扁平行列表。
func flatten(document: DiffDocument, expanded: Set<Int>) -> [FlatRow] {
    var result: [FlatRow] = []
    result.reserveCapacity(document.rows.count)
    for index in document.rows.indices {
        let row = document.rows[index]
        if case .collapsed(let oldRange, let newRange) = row.kind {
            result.append(.collapsedHeader(index))
            if expanded.contains(index) {
                for offset in 0 ..< oldRange.count {
                    result.append(
                        .collapsedPair(
                            headerIndex: index,
                            oldIndex: oldRange.lowerBound + offset,
                            newIndex: newRange.lowerBound + offset
                        )
                    )
                }
            }
        } else {
            result.append(.row(index))
        }
    }
    return result
}

/// 一侧（old 或 new）一行的全部渲染数据。纯值类型，可跨隔离域传递。
struct DiffRenderRow: Equatable, Sendable {
    var text: String
    var lineNumber: Int? = nil
    var tone: DiffTone
    /// 行内 word 高亮（Character 偏移区间）。
    var highlights: [Range<Int>] = []
    /// 非 nil = 这一行是折叠提示条。
    var collapse: DiffCollapseMarker? = nil
}

struct DiffCollapseMarker: Equatable, Sendable {
    /// `document.rows` 中折叠块的下标，回传给 `onToggle`。
    var index: Int
    var isExpanded: Bool
}

enum DiffTone: Equatable, Sendable {
    case unchanged
    case added
    case removed
    /// 对侧不存在的占位行
    case absent

    func background(_ palette: DiffPanePalette) -> NSColor? {
        switch self {
        case .unchanged, .absent: nil
        case .added: palette.addedBackground
        case .removed: palette.removedBackground
        }
    }

    func highlight(_ palette: DiffPanePalette) -> NSColor? {
        switch self {
        case .unchanged, .absent: nil
        case .added: palette.addedHighlight
        case .removed: palette.removedHighlight
        }
    }

    func edge(_ palette: DiffPanePalette) -> NSColor? {
        switch self {
        case .unchanged, .absent: nil
        case .added: palette.addedEdge
        case .removed: palette.removedEdge
        }
    }
}

/// 把扁平行物化成一侧的渲染行。行内高亮直接取 `document.inline`
/// （后台已随 diff 一并算好），这里不做任何耗时计算。
func renderRows(
    document: DiffDocument,
    flatRows: [FlatRow],
    expanded: Set<Int>,
    isOld: Bool
) -> [DiffRenderRow] {
    /// 左右配对的未变更行（.equal 与展开后的折叠行共用）。
    func unchangedRow(oldIndex: Int, newIndex: Int) -> DiffRenderRow {
        DiffRenderRow(
            text: isOld ? document.oldLines[oldIndex] : document.newLines[newIndex],
            lineNumber: (isOld ? oldIndex : newIndex) + 1,
            tone: .unchanged
        )
    }

    var result: [DiffRenderRow] = []
    result.reserveCapacity(flatRows.count)
    for flat in flatRows {
        switch flat {
        case .collapsedHeader(let index):
            guard case .collapsed(let oldRange, _) = document.rows[index].kind else { continue }
            let isExpanded = expanded.contains(index)
            let count = oldRange.count
            let label = String(
                localized: "diff.collapsed",
                defaultValue: "\(count) unchanged lines"
            )
            result.append(
                DiffRenderRow(
                    text: (isExpanded ? "▾  " : "▸  ") + label,
                    tone: .unchanged,
                    collapse: DiffCollapseMarker(index: index, isExpanded: isExpanded)
                )
            )
        case .collapsedPair(_, let oldIndex, let newIndex):
            result.append(unchangedRow(oldIndex: oldIndex, newIndex: newIndex))
        case .row(let index):
            switch document.rows[index].kind {
            case .equal(let oldIndex, let newIndex):
                result.append(unchangedRow(oldIndex: oldIndex, newIndex: newIndex))
            case .delete(let oldIndex):
                if isOld {
                    result.append(
                        DiffRenderRow(
                            text: document.oldLines[oldIndex],
                            lineNumber: oldIndex + 1,
                            tone: .removed
                        )
                    )
                } else {
                    // 右侧没有对应行 —— 用占位表示。
                    result.append(DiffRenderRow(text: "", tone: .absent))
                }
            case .insert(let newIndex):
                if isOld {
                    result.append(DiffRenderRow(text: "", tone: .absent))
                } else {
                    result.append(
                        DiffRenderRow(
                            text: document.newLines[newIndex],
                            lineNumber: newIndex + 1,
                            tone: .added
                        )
                    )
                }
            case .modified(let oldIndex, let newIndex):
                let inline = document.inline[index] ?? DiffEngine.InlineRanges()
                result.append(
                    DiffRenderRow(
                        text: isOld ? document.oldLines[oldIndex] : document.newLines[newIndex],
                        lineNumber: (isOld ? oldIndex : newIndex) + 1,
                        tone: isOld ? .removed : .added,
                        highlights: isOld ? inline.oldRanges : inline.newRanges
                    )
                )
            case .collapsed:
                continue
            }
        }
    }
    return result
}

// MARK: - AppKit 正文面板

/// 面板用到的固定度量与字体。
@MainActor
enum DiffPaneMetrics {
    static let gutterWidth: CGFloat = 52
    static let edgeWidth: CGFloat = 2
    static let contentFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    static let lineNumberFont = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
}

/// 面板配色。全部是**具体 sRGB 值**而非动态 NSColor：与编辑器同一套约定 ——
/// 动态色存进 NSTextStorage 后要等绘制时才按当时外观解析，在 Liquid Glass
/// 材质上下文中有落到错误变体的风险；固定色由外观变化回调统一重建。
struct DiffPanePalette {
    let text: NSColor
    let lineNumber: NSColor
    let collapseText: NSColor
    let collapseBackground: NSColor
    let addedBackground: NSColor
    let removedBackground: NSColor
    let addedHighlight: NSColor
    let removedHighlight: NSColor
    let addedEdge: NSColor
    let removedEdge: NSColor

    static func resolve(dark: Bool) -> DiffPanePalette {
        // systemGreen / systemRed 在浅色与深色外观下的具体 sRGB 值。
        let green = dark
            ? NSColor(srgbRed: 0.188, green: 0.820, blue: 0.345, alpha: 1)
            : NSColor(srgbRed: 0.204, green: 0.780, blue: 0.349, alpha: 1)
        let red = dark
            ? NSColor(srgbRed: 1.000, green: 0.271, blue: 0.227, alpha: 1)
            : NSColor(srgbRed: 1.000, green: 0.231, blue: 0.188, alpha: 1)
        // 正文色与编辑器一致（JSONTextView.lightText / darkText）。
        let text = dark ? colorDarkText : colorLightText
        return DiffPanePalette(
            text: text,
            lineNumber: text.withAlphaComponent(0.38),
            collapseText: text.withAlphaComponent(0.55),
            collapseBackground: text.withAlphaComponent(0.06),
            addedBackground: green.withAlphaComponent(0.14),
            removedBackground: red.withAlphaComponent(0.14),
            addedHighlight: green.withAlphaComponent(0.32),
            removedHighlight: red.withAlphaComponent(0.32),
            addedEdge: green.withAlphaComponent(0.8),
            removedEdge: red.withAlphaComponent(0.8)
        )
    }
}

/// 正文两栏（NSViewRepresentable 桥）。
struct DiffSideBySidePane: NSViewRepresentable {
    let oldRows: [DiffRenderRow]
    let newRows: [DiffRenderRow]
    /// 行内容代次：不变则 `updateNSView` 是纯 no-op，
    /// SwiftUI 的无关重渲染（如拖拽调整窗口）不会触碰文本。
    let revision: Int
    let onToggle: (Int) -> Void

    func makeNSView(context: Context) -> DiffPaneContainerView {
        let view = DiffPaneContainerView()
        view.onToggle = onToggle
        view.apply(oldRows: oldRows, newRows: newRows, revision: revision)
        return view
    }

    func updateNSView(_ view: DiffPaneContainerView, context: Context) {
        view.onToggle = onToggle
        view.apply(oldRows: oldRows, newRows: newRows, revision: revision)
    }

    /// 容器没有固有尺寸，必须显式接住 SwiftUI 的尺寸提案：默认实现会在
    /// 理想尺寸探测时把视图压成 ~1pt 高，再被外层 frame 居中，正文直接
    /// 消失。有具体提案就原样采用（铺满可用空间），理想探测则退回最小
    /// 可用尺寸。
    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: DiffPaneContainerView,
        context: Context
    ) -> NSSize? {
        NSSize(width: proposal.width ?? 820, height: proposal.height ?? 440)
    }
}

/// 两栏容器：左右各一个 NSScrollView + 中缝分隔线，负责纵向滚动同步
/// 与外观变化时的整体重建。
final class DiffPaneContainerView: NSView {
    private let leftColumn: DiffPaneColumn
    private let rightColumn: DiffPaneColumn
    private let divider = NSBox()

    var onToggle: ((Int) -> Void)? {
        didSet {
            leftColumn.onToggle = onToggle
            rightColumn.onToggle = onToggle
        }
    }

    private var appliedRevision = -1
    private var oldRows: [DiffRenderRow] = []
    private var newRows: [DiffRenderRow] = []
    /// 镜像滚动时置位，阻断两个 clip view 互相触发的通知回环。
    private var isSyncingScroll = false

    init() {
        // 纵向滚动条只留右栏一根（JetBrains 同款）：左栏没有滚动条
        // 也照常接收滚轮/触控板事件，同步逻辑会把它带上。
        leftColumn = DiffPaneColumn(showsVerticalScroller: false)
        rightColumn = DiffPaneColumn(showsVerticalScroller: true)
        super.init(frame: .zero)
        wantsLayer = true

        divider.boxType = .separator

        for view in [leftColumn.view, divider, rightColumn.view] {
            addSubview(view)
        }

        // 纵向同步：监听两个 clip view 的 bounds 变化互相镜像。
        // 选择器式观察者在 dealloc 时由 NotificationCenter 自动解除。
        for clipView in [leftColumn.scrollView.contentView, rightColumn.scrollView.contentView] {
            clipView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(clipViewBoundsDidChange(_:)),
                name: NSView.boundsDidChangeNotification,
                object: clipView
            )
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func apply(oldRows: [DiffRenderRow], newRows: [DiffRenderRow], revision: Int) {
        guard revision != appliedRevision else { return }
        appliedRevision = revision
        self.oldRows = oldRows
        self.newRows = newRows
        rebuildContent()
    }

    /// 按当前外观解析配色并重建两栏文本。
    private func rebuildContent() {
        let palette = DiffPanePalette.resolve(dark: isDarkAppearance)
        leftColumn.apply(rows: oldRows, palette: palette)
        rightColumn.apply(rows: newRows, palette: palette)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        rebuildContent()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        rebuildContent()
    }

    /// 手动排布两栏与中缝。刻意不用 Auto Layout：SwiftUI 宿主直接
    /// setFrame 驱动本视图，实测子视图约束在容器 resize 后只重解了
    /// 宽度、高度停在初值上（引擎没有随 frame 变化重跑），手动布局
    /// 则完全确定。
    override func layout() {
        super.layout()
        let height = bounds.height
        let columnWidth = max(0, (bounds.width - 1) / 2)
        leftColumn.view.frame = NSRect(x: 0, y: 0, width: columnWidth, height: height)
        divider.frame = NSRect(x: columnWidth, y: 0, width: 1, height: height)
        rightColumn.view.frame = NSRect(
            x: columnWidth + 1,
            y: 0,
            width: max(0, bounds.width - columnWidth - 1),
            height: height
        )
        // 保证短内容时 textView 至少铺满视口，行底色才能画满整栏。
        leftColumn.updateMinimumContentSize()
        rightColumn.updateMinimumContentSize()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    @objc private func clipViewBoundsDidChange(_ notification: Notification) {
        guard !isSyncingScroll,
              let changed = notification.object as? NSClipView
        else { return }
        let leftClip = leftColumn.scrollView.contentView
        let other = changed === leftClip ? rightColumn.scrollView.contentView : leftClip
        if other.bounds.origin.y != changed.bounds.origin.y {
            isSyncingScroll = true
            var origin = other.bounds.origin
            origin.y = changed.bounds.origin.y
            other.setBoundsOrigin(origin)
            (other.superview as? NSScrollView)?.reflectScrolledClipView(other)
            isSyncingScroll = false
        }
        leftColumn.gutter.needsDisplay = true
        rightColumn.gutter.needsDisplay = true
    }
}

/// 一栏：固定 52pt 的自绘行号列 + 不换行 NSTextView 的 NSScrollView
/// （原生双向滚动、可选中复制）。行号列在滚动视图**外面**，
/// 横向滚动天然碰不到它；纵向位置按 textView 的真实行矩形换算。
/// （不用 NSRulerView：这版 SDK 里它的排布不给内容让位，正文会
/// 顶进标尺下面和行号重叠。）
@MainActor
final class DiffPaneColumn {
    let view = DiffColumnView()
    let scrollView = NSScrollView()
    let textView: DiffPaneTextView
    let gutter: DiffGutterView
    /// TextKit 1 经典陷阱：NSLayoutManager 对 NSTextStorage 是弱引用，
    /// 必须有人强持有 storage，否则会被提前释放。
    private let storage: NSTextStorage

    var onToggle: ((Int) -> Void)? {
        get { textView.onToggleCollapse }
        set { textView.onToggleCollapse = newValue }
    }

    init(showsVerticalScroller: Bool) {
        // 显式搭 TextKit 1 栈：行底色/高亮自绘、非连续布局都依赖
        // NSLayoutManager 的字形几何接口。
        let huge = CGFloat.greatestFiniteMagnitude
        storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        layoutManager.allowsNonContiguousLayout = true
        let container = NSTextContainer(size: NSSize(width: huge, height: huge))
        container.widthTracksTextView = false
        container.heightTracksTextView = false
        container.lineFragmentPadding = 6
        storage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(container)

        textView = DiffPaneTextView(frame: .zero, textContainer: container)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        // 背景由 sheet 的玻璃材质提供；行底色/高亮由 draw(_:) 自绘。
        textView.drawsBackground = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        // 不换行 + 双向可伸展：超长行交给横向滚动，与编辑器一致。
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.minSize = .zero
        textView.maxSize = NSSize(width: huge, height: huge)
        textView.textContainerInset = .zero
        textView.font = DiffPaneMetrics.contentFont
        textView.wantsLayer = true

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = showsVerticalScroller
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        // 保持 automaticallyAdjustsContentInsets 为默认 true：现代 AppKit
        // 的 NSRulerView 浮在 clip view 上方，靠自动 contentInsets.left
        // 给内容让位；关掉它内容会顶进标尺下面、和行号重叠。
        scrollView.wantsLayer = true

        gutter = DiffGutterView()
        gutter.textView = textView

        view.gutter = gutter
        view.scrollView = scrollView
        view.addSubview(gutter)
        view.addSubview(scrollView)
    }

    func apply(rows: [DiffRenderRow], palette: DiffPanePalette) {
        textView.apply(rows: rows, palette: palette)
        gutter.needsDisplay = true
    }

    /// textView 至少和视口一样大：内容比视口短/窄时行底色也能铺满。
    /// （双向 resizable 的 NSTextView 会自动收缩到 max(内容尺寸, minSize)。）
    func updateMinimumContentSize() {
        let size = scrollView.contentSize
        guard textView.minSize != size else { return }
        textView.minSize = size
        var frameSize = textView.frame.size
        frameSize.width = max(frameSize.width, size.width)
        frameSize.height = max(frameSize.height, size.height)
        if frameSize != textView.frame.size {
            textView.setFrameSize(frameSize)
        }
    }
}

/// 只读、不换行的 diff 文本视图：
/// - 行底色（增/删/折叠条）自绘并铺满整栏宽度，包括横向滚出的部分；
/// - 行内 word 高亮按 layoutManager 的字形矩形精确绘制；
/// - 点击折叠条任意位置展开/收起（整行都是点击区，不只是文字）。
final class DiffPaneTextView: NSTextView {
    private(set) var rowData: [DiffRenderRow] = []
    /// 每行首字符的 UTF-16 偏移，升序；末行为空行时最后一项等于文本总长。
    private var rowStarts: [Int] = []
    /// 每行的行内高亮（绝对 UTF-16 区间），与 `rowData` 等长。
    private var rowHighlights: [[NSRange]] = []
    private(set) var palette = DiffPanePalette.resolve(dark: false)
    var onToggleCollapse: ((Int) -> Void)?

    // MARK: 内容

    func apply(rows: [DiffRenderRow], palette: DiffPanePalette) {
        self.palette = palette
        rowData = rows
        rowStarts.removeAll(keepingCapacity: true)
        rowHighlights.removeAll(keepingCapacity: true)
        rowStarts.reserveCapacity(rows.count)
        rowHighlights.reserveCapacity(rows.count)

        let baseAttributes: [NSAttributedString.Key: Any] = [
            .font: DiffPaneMetrics.contentFont,
            .foregroundColor: palette.text,
        ]
        let collapseAttributes: [NSAttributedString.Key: Any] = [
            .font: DiffPaneMetrics.contentFont,
            .foregroundColor: palette.collapseText,
        ]
        let newline = NSAttributedString(string: "\n", attributes: baseAttributes)

        let result = NSMutableAttributedString()
        result.beginEditing()
        var offset = 0
        for (index, row) in rows.enumerated() {
            if index > 0 {
                result.append(newline)
                offset += 1
            }
            rowStarts.append(offset)
            let piece = NSAttributedString(
                string: row.text,
                attributes: row.collapse == nil ? baseAttributes : collapseAttributes
            )
            result.append(piece)

            // Character 偏移 → 绝对 UTF-16 区间（行内可能有代理对字符）。
            var absolute: [NSRange] = []
            if !row.highlights.isEmpty {
                var utf16Prefix = [0]
                utf16Prefix.reserveCapacity(row.text.count + 1)
                var running = 0
                for character in row.text {
                    running += character.utf16.count
                    utf16Prefix.append(running)
                }
                for range in row.highlights {
                    let lower = min(max(range.lowerBound, 0), utf16Prefix.count - 1)
                    let upper = min(max(range.upperBound, lower), utf16Prefix.count - 1)
                    let length = utf16Prefix[upper] - utf16Prefix[lower]
                    if length > 0 {
                        absolute.append(
                            NSRange(location: offset + utf16Prefix[lower], length: length)
                        )
                    }
                }
            }
            rowHighlights.append(absolute)
            offset += piece.length
        }
        result.endEditing()
        textStorage?.setAttributedString(result)
        needsDisplay = true
    }

    // MARK: 行几何

    /// 第 `row` 行的 line fragment 矩形（textView 坐标）。
    /// 依赖 layoutManager 的真实布局而不是「行高 × 下标」的算术假设，
    /// 行号列与行底色因此和字形永远严格对齐。
    func rowRect(_ row: Int) -> NSRect {
        guard row >= 0, row < rowStarts.count,
              let layoutManager, let textStorage
        else { return .zero }
        let origin = textContainerOrigin
        let start = rowStarts[row]
        if start >= textStorage.length {
            // 末行为空行（文本以换行结束）：对应 extra line fragment。
            return layoutManager.extraLineFragmentRect.offsetBy(dx: origin.x, dy: origin.y)
        }
        let glyphIndex = layoutManager.glyphIndexForCharacter(at: start)
        return layoutManager
            .lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
            .offsetBy(dx: origin.x, dy: origin.y)
    }

    /// 与 `rect`（textView 坐标）相交的行范围。
    func visibleRows(in rect: NSRect) -> ClosedRange<Int>? {
        guard !rowStarts.isEmpty,
              let layoutManager, let textContainer, let textStorage
        else { return nil }
        let origin = textContainerOrigin
        let containerRect = rect.offsetBy(dx: -origin.x, dy: -origin.y)
        let glyphRange = layoutManager.glyphRange(forBoundingRect: containerRect, in: textContainer)
        let charRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        var first = rowIndex(forCharacterOffset: charRange.location)
        var last = rowIndex(forCharacterOffset: max(charRange.location, NSMaxRange(charRange) - 1))
        // 末行为空行时不含任何字形，glyphRange 覆盖不到，按 extra fragment 补上。
        if let lastStart = rowStarts.last, lastStart >= textStorage.length {
            let extra = layoutManager.extraLineFragmentRect.offsetBy(dx: origin.x, dy: origin.y)
            if extra.height > 0, rect.intersects(extra) {
                last = rowStarts.count - 1
            }
        }
        first = max(0, min(first, rowStarts.count - 1))
        last = max(first, min(last, rowStarts.count - 1))
        return first ... last
    }

    /// `rowStarts` 中最后一个 ≤ offset 的下标（二分）。
    private func rowIndex(forCharacterOffset offset: Int) -> Int {
        var low = 0
        var high = rowStarts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if rowStarts[mid] <= offset {
                low = mid
            } else {
                high = mid - 1
            }
        }
        return low
    }

    /// 命中测试：点（textView 坐标）落在哪一行的竖直范围内。
    func row(at point: NSPoint) -> Int? {
        guard !rowStarts.isEmpty, let layoutManager, let textContainer else { return nil }
        let origin = textContainerOrigin
        let containerPoint = NSPoint(x: point.x - origin.x, y: point.y - origin.y)
        let glyphIndex = layoutManager.glyphIndex(for: containerPoint, in: textContainer)
        let charIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
        let row = rowIndex(forCharacterOffset: charIndex)
        let rect = rowRect(row)
        guard point.y >= rect.minY, point.y < rect.maxY else { return nil }
        return row
    }

    // MARK: 绘制

    override func draw(_ dirtyRect: NSRect) {
        drawRowDecorations(in: dirtyRect)
        super.draw(dirtyRect)
    }

    private func drawRowDecorations(in rect: NSRect) {
        guard let rows = visibleRows(in: rect),
              let layoutManager, let textContainer
        else { return }
        let origin = textContainerOrigin
        for row in rows {
            guard row < rowData.count, row < rowHighlights.count else { break }
            let data = rowData[row]
            let fragment = rowRect(row)
            guard fragment.height > 0 else { continue }
            // 行底色铺满整栏宽度（textView 至少和视口一样宽，见
            // updateMinimumContentSize），横向滚出的部分同样有底色。
            var fullWidth = fragment
            fullWidth.origin.x = 0
            fullWidth.size.width = bounds.width
            if data.collapse != nil {
                palette.collapseBackground.setFill()
                fullWidth.fill()
            } else if let background = data.tone.background(palette) {
                background.setFill()
                fullWidth.fill()
            }
            let highlights = rowHighlights[row]
            if !highlights.isEmpty, let color = data.tone.highlight(palette) {
                color.setFill()
                for range in highlights {
                    let glyphRange = layoutManager.glyphRange(
                        forCharacterRange: range, actualCharacterRange: nil
                    )
                    layoutManager
                        .boundingRect(forGlyphRange: glyphRange, in: textContainer)
                        .offsetBy(dx: origin.x, dy: origin.y)
                        .fill()
                }
            }
        }
    }

    // MARK: 交互

    /// 窗口坐标点若落在折叠条上则触发展开/收起。
    /// 内容区与行号列的 mouseDown 共用这一处命中逻辑。
    func handleCollapseClick(windowPoint: NSPoint) -> Bool {
        let point = convert(windowPoint, from: nil)
        guard let row = row(at: point), let collapse = rowData[row].collapse else { return false }
        onToggleCollapse?(collapse.index)
        return true
    }

    override func mouseDown(with event: NSEvent) {
        if handleCollapseClick(windowPoint: event.locationInWindow) {
            return
        }
        super.mouseDown(with: event)
    }
}

/// 一栏的根视图：行号列固定 52pt 在左，滚动视图占余下宽度。
final class DiffColumnView: NSView {
    weak var gutter: DiffGutterView?
    weak var scrollView: NSScrollView?

    override func layout() {
        super.layout()
        let gutterWidth = DiffPaneMetrics.gutterWidth
        gutter?.frame = NSRect(x: 0, y: 0, width: gutterWidth, height: bounds.height)
        scrollView?.frame = NSRect(
            x: gutterWidth,
            y: 0,
            width: max(0, bounds.width - gutterWidth),
            height: bounds.height
        )
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }
}

/// 行号列。在滚动视图外面，横向滚动天然碰不到它；行号、增/删底色与
/// 2pt 色条都画在这里，内容横向滚动时保持可见 —— 这正是此前 SwiftUI
/// 版要靠「行号列不进横向 ScrollView」手工模拟的行为。
/// 每行的竖直位置按 textView 的真实行矩形经 convert(_:from:) 换算，
/// 纵向滚动时由 clip view 的 bounds 通知触发重绘。
final class DiffGutterView: NSView {
    weak var textView: DiffPaneTextView?

    /// 内容是随滚动整帧变化的，直接按行重画。
    override var isFlipped: Bool {
        true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let textView else { return }
        let palette = textView.palette
        guard let rows = textView.visibleRows(in: textView.visibleRect) else { return }
        let numberAttributes: [NSAttributedString.Key: Any] = [
            .font: DiffPaneMetrics.lineNumberFont,
            .foregroundColor: palette.lineNumber,
        ]
        for row in rows {
            guard row < textView.rowData.count else { break }
            let data = textView.rowData[row]
            let fragment = textView.rowRect(row)
            guard fragment.height > 0 else { continue }
            var rowRect = convert(fragment, from: textView)
            rowRect.origin.x = 0
            rowRect.size.width = bounds.width

            if data.collapse != nil {
                palette.collapseBackground.setFill()
                rowRect.fill()
            } else if let background = data.tone.background(palette) {
                background.setFill()
                rowRect.fill()
            }
            if let edge = data.tone.edge(palette) {
                edge.setFill()
                NSRect(
                    x: 0,
                    y: rowRect.minY,
                    width: DiffPaneMetrics.edgeWidth,
                    height: rowRect.height
                ).fill()
            }
            if let number = data.lineNumber {
                let text = String(number) as NSString
                let size = text.size(withAttributes: numberAttributes)
                text.draw(
                    in: NSRect(
                        x: bounds.width - 8 - size.width,
                        y: rowRect.midY - size.height / 2,
                        width: size.width,
                        height: size.height
                    ),
                    withAttributes: numberAttributes
                )
            }
        }
    }

    /// 行号列里点击折叠条同样可以展开/收起，与内容区行为一致。
    override func mouseDown(with event: NSEvent) {
        if textView?.handleCollapseClick(windowPoint: event.locationInWindow) == true {
            return
        }
        super.mouseDown(with: event)
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
    /// 行内 word 高亮（键 = `rows` 下标，仅 modified 行有值）。
    /// 随 diff 一并在后台算好；被取消时可能不完整，缺失按无高亮处理。
    var inline: [Int: DiffEngine.InlineRanges] = [:]

    var isIdentical: Bool {
        insertions == 0 && deletions == 0
    }

    /// 规范化 + 切行 + diff + 行内高亮，整套都可在后台线程执行。
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
        if let value = try? JSONParser.parse(rawInput) {
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

        // 行内高亮也在这里算掉：modified 行数天然有限（都是真实差异），
        // 且 inlineDiff 自带词元预算，单行代价有界。
        var inline: [Int: DiffEngine.InlineRanges] = [:]
        for (index, row) in result.rows.enumerated() {
            guard case .modified(let oldIndex, let newIndex) = row.kind else { continue }
            if isCancelled() {
                break
            }
            inline[index] = DiffEngine.inlineDiff(
                oldLine: oldLines[oldIndex],
                newLine: newLines[newIndex],
                limits: limits
            )
        }

        return DiffDocument(
            oldLines: oldLines,
            newLines: newLines,
            rows: result.rows,
            insertions: result.insertions,
            deletions: result.deletions,
            degraded: result.degraded,
            inline: inline
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

/// 跨隔离域的取消标志。
///
/// `Task.detached` 不会随父任务取消，因此关闭 sheet 时用它通知 diff
/// 主循环提前退出（否则超大输入下后台会一直算到底）。
final class CancellationFlag: Sendable {
    private let flag = Atomic<Bool>(false)

    var isCancelled: Bool {
        flag.load(ordering: .relaxed)
    }

    func cancel() {
        flag.store(true, ordering: .relaxed)
    }
}
