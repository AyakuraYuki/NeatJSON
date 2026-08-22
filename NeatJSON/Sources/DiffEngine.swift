import Foundation

/// 行级 + 行内 diff 引擎。
///
/// 与旧实现的关键差异（三者都是此前卡顿/OOM 的直接原因）：
/// - **线性空间**：旧实现为每一轮编辑距离 d 保存一份完整 V 数组快照，
///   空间与时间都是 O((n+m)²)——1 万行就要 1.6 GB，且每轮的数组复制
///   本身就够慢。现改用 Myers 论文的分治细化（bisect），只保留两条
///   O(n+m) 的对角线向量。
/// - **整数化比较**：行与词元先 intern 成 `Int32`，热循环里不再做
///   `String ==`。
/// - **patience 锚点**：超出 Myers 预算的大区段，先用「两侧各只出现一次
///   的行」求最长递增子序列当锚点切分，把大区段拆成一堆小 gap。JSON 的
///   `"key": value` 行天然高度唯一，这条路径几乎总能命中。
/// - **可取消 + 可降级**：极端输入退化为整块增删并置 `degraded`，
///   由界面提示并提供「精确对比」入口。
public enum DiffEngine {
    // MARK: - 预算

    /// 计算预算。超出预算的区段走锚点切分或降级，保证界面永远秒级响应。
    public struct Limits: Equatable, Sendable {
        /// 区段面积（`n * m`）不超过此值时直接用 Myers。
        ///
        /// Myers 的实际代价是 O(ND)，面积只是上界的代理。阈值设小一点很关键：
        /// 实测 2000×2000 的**全乱序**区段用 Myers 要 ~90 ms，而 patience
        /// 锚点只要 ~3 ms；小区段则反过来，Myers 更精确且已经足够快。
        public var directMyersArea: Int
        /// 找不到锚点时，仍愿意交给 Myers 的面积上限。
        public var maxMyersArea: Int
        /// 无锚点且超预算时是否退化为整块增删。`false` = 精确模式，硬算。
        public var allowsFallback: Bool
        /// 行内 diff 的词元数上限，超过则整段粗粒度高亮。
        public var maxInlineTokens: Int
        /// 递归深度上限，纯粹的爆栈保护（正常输入远达不到）。
        public var maxDepth: Int

        public init(
            directMyersArea: Int,
            maxMyersArea: Int,
            allowsFallback: Bool,
            maxInlineTokens: Int,
            maxDepth: Int = 3_000
        ) {
            self.directMyersArea = directMyersArea
            self.maxMyersArea = maxMyersArea
            self.allowsFallback = allowsFallback
            self.maxInlineTokens = maxInlineTokens
            self.maxDepth = maxDepth
        }

        /// 默认：秒级响应优先，极端区段降级。
        public static let balanced = Limits(
            directMyersArea: 250_000,
            maxMyersArea: 4_000_000,
            allowsFallback: true,
            maxInlineTokens: 2_000
        )

        /// 精确：全程 Myers、不降级，允许长时间计算（界面提供取消）。
        public static let exact = Limits(
            directMyersArea: .max,
            maxMyersArea: .max,
            allowsFallback: false,
            maxInlineTokens: 200_000
        )
    }

    // MARK: - 行级

    public enum Op: Equatable, Sendable {
        case equal(oldIndex: Int, newIndex: Int) // 0 起
        case delete(oldIndex: Int)
        case insert(newIndex: Int)
    }

    /// 对旧行 `old` 与新行 `new` 计算 diff 操作序列。
    public static func lineDiff(
        _ old: [String],
        _ new: [String],
        limits: Limits = .balanced,
        isCancelled: () -> Bool = { false }
    ) -> [Op] {
        lineDiffDetailed(old, new, limits: limits, isCancelled: isCancelled).ops
    }

    /// 同 `lineDiff`，额外返回是否发生过降级。
    public static func lineDiffDetailed(
        _ old: [String],
        _ new: [String],
        limits: Limits = .balanced,
        isCancelled: () -> Bool = { false }
    ) -> (ops: [Op], degraded: Bool) {
        // 行 intern：同一行文本映射到同一个 Int32，后续全是整数比较。
        var table: [String: Int32] = [:]
        table.reserveCapacity(old.count + new.count)
        var next: Int32 = 0
        func intern(_ line: String) -> Int32 {
            if let id = table[line] {
                return id
            }
            let id = next
            table[line] = id
            next += 1
            return id
        }
        let a = old.map(intern)
        let b = new.map(intern)
        // Differ 只活在本函数作用域内，因此可以安全地把非逃逸闭包借给它。
        return withoutActuallyEscaping(isCancelled) { cancel in
            let differ = Differ(a: a, b: b, limits: limits, isCancelled: cancel)
            differ.run()
            return (differ.ops, differ.degraded)
        }
    }

    // MARK: - 行内（word-level）

    /// 行内高亮区间。
    ///
    /// 区间语义是 **Character 偏移**（不是词元索引）：视图层直接按字符
    /// 切片拼 `AttributedString`，不需要再分词一遍、也不需要 O(n) 的
    /// `index(offsetBy:)` 定位。
    public struct InlineRanges: Equatable, Sendable {
        public var oldRanges: [Range<Int>] = []
        public var newRanges: [Range<Int>] = []
        /// 词元数超预算，退化为「中间整段」的粗粒度高亮。
        public var isCoarse: Bool = false
    }

    /// 词元字符区间：连续的字母/数字/下划线为一个词，其余每个标点/空白各为一词。
    ///
    /// 返回 Character 偏移区间，不产生任何字符串分配。
    static func tokenSpans(_ line: String) -> [Range<Int>] {
        var spans: [Range<Int>] = []
        var offset = 0
        var wordStart = -1
        for c in line {
            if c.isLetter || c.isNumber || c == "_" {
                if wordStart < 0 {
                    wordStart = offset
                }
            } else {
                if wordStart >= 0 {
                    spans.append(wordStart ..< offset)
                    wordStart = -1
                }
                spans.append(offset ..< (offset + 1))
            }
            offset += 1
        }
        if wordStart >= 0 {
            spans.append(wordStart ..< offset)
        }
        return spans
    }

    /// 词元切分（字符串形式）。仅测试与调试使用；渲染路径走 `tokenSpans`。
    static func tokenizeForInline(_ line: String) -> [String] {
        let chars = Array(line)
        return tokenSpans(line).map { String(chars[$0]) }
    }

    /// 对一对 delete/insert 行计算行内变化区间（Character 偏移）。
    public static func inlineDiff(
        oldLine: String,
        newLine: String,
        limits: Limits = .balanced
    ) -> InlineRanges {
        let oldChars = Array(oldLine)
        let newChars = Array(newLine)
        let oldSpans = tokenSpans(oldLine)
        let newSpans = tokenSpans(newLine)

        func sameToken(_ i: Int, _ j: Int) -> Bool {
            let l = oldSpans[i], r = newSpans[j]
            guard l.count == r.count else { return false }
            var li = l.lowerBound, ri = r.lowerBound
            while li < l.upperBound {
                if oldChars[li] != newChars[ri] {
                    return false
                }
                li += 1
                ri += 1
            }
            return true
        }

        // 公共前后缀词元裁剪：JSON 行通常只有值不同，裁完往往只剩一两个词元。
        var prefix = 0
        let maxPrefix = min(oldSpans.count, newSpans.count)
        while prefix < maxPrefix, sameToken(prefix, prefix) {
            prefix += 1
        }
        var suffix = 0
        let maxSuffix = min(oldSpans.count - prefix, newSpans.count - prefix)
        while suffix < maxSuffix,
              sameToken(oldSpans.count - 1 - suffix, newSpans.count - 1 - suffix)
        {
            suffix += 1
        }

        let oldRange = prefix ..< (oldSpans.count - suffix)
        let newRange = prefix ..< (newSpans.count - suffix)
        if oldRange.isEmpty, newRange.isEmpty {
            return InlineRanges()
        }

        // 超预算：整段粗粒度高亮，避免在单行上跑大规模 diff。
        if oldRange.count > limits.maxInlineTokens || newRange.count > limits.maxInlineTokens {
            var result = InlineRanges()
            result.isCoarse = true
            if !oldRange.isEmpty {
                result.oldRanges = [
                    oldSpans[oldRange.lowerBound].lowerBound
                        ..< oldSpans[oldRange.upperBound - 1].upperBound,
                ]
            }
            if !newRange.isEmpty {
                result.newRanges = [
                    newSpans[newRange.lowerBound].lowerBound
                        ..< newSpans[newRange.upperBound - 1].upperBound,
                ]
            }
            return result
        }

        // 词元 intern → 复用同一套线性空间 diff。
        var table: [String: Int32] = [:]
        table.reserveCapacity(oldRange.count + newRange.count)
        var next: Int32 = 0
        func intern(_ chars: [Character], _ span: Range<Int>) -> Int32 {
            let key = String(chars[span])
            if let id = table[key] {
                return id
            }
            let id = next
            table[key] = id
            next += 1
            return id
        }
        let a = oldRange.map { intern(oldChars, oldSpans[$0]) }
        let b = newRange.map { intern(newChars, newSpans[$0]) }

        let differ = Differ(a: a, b: b, limits: .exact, isCancelled: { false })
        differ.run()

        var oldChanged: [Int] = []
        var newChanged: [Int] = []
        for op in differ.ops {
            switch op {
            case .equal: break
            case .delete(let i): oldChanged.append(prefix + i)
            case .insert(let j): newChanged.append(prefix + j)
            }
        }
        return InlineRanges(
            oldRanges: mergeSpans(indices: oldChanged, spans: oldSpans),
            newRanges: mergeSpans(indices: newChanged, spans: newSpans),
            isCoarse: false
        )
    }

    /// 把升序的词元索引合并成尽量少的字符区间。
    private static func mergeSpans(indices: [Int], spans: [Range<Int>]) -> [Range<Int>] {
        var result: [Range<Int>] = []
        var runStart = -1
        var runEnd = -1
        var previous = -2
        for index in indices {
            if index == previous + 1 {
                runEnd = spans[index].upperBound
            } else {
                if runStart >= 0 {
                    result.append(runStart ..< runEnd)
                }
                runStart = spans[index].lowerBound
                runEnd = spans[index].upperBound
            }
            previous = index
        }
        if runStart >= 0 {
            result.append(runStart ..< runEnd)
        }
        return result
    }

    // MARK: - 视图数据

    /// diff 行（视图直接渲染的单元）。
    ///
    /// `modified` 不再内嵌 `InlineRanges`：行内 diff 由视图层按可见行惰性
    /// 计算并缓存，`Row` 因此只是两个 Int 的小枚举，十万行的 rows 数组
    /// 内存从数十 MB 降到 ~2 MB，且弹窗耗时与 modified 行数量脱钩。
    public struct Row: Equatable, Sendable {
        public enum Kind: Equatable, Sendable {
            case equal(oldIndex: Int, newIndex: Int)
            case delete(oldIndex: Int)
            case insert(newIndex: Int)
            /// delete + insert 成对（同一行号位置，左右同时着色）
            case modified(oldIndex: Int, newIndex: Int)
            /// 折叠掉的未变更块（左右各一段行区间）
            case collapsed(oldRange: Range<Int>, newRange: Range<Int>)
        }

        public var kind: Kind

        public init(kind: Kind) {
            self.kind = kind
        }
    }

    /// diff 结果：行列表 + 预先算好的统计 + 是否降级。
    public struct Result: Sendable {
        public var rows: [Row]
        public var insertions: Int
        public var deletions: Int
        public var degraded: Bool

        public static let empty = Result(rows: [], insertions: 0, deletions: 0, degraded: false)
    }

    /// 一步得到可渲染结果。
    /// - Parameter collapseContext: 非 nil 时把长的未变更段折叠，只在变更点
    ///   两侧各保留这么多行上下文。
    public static func diff(
        old: [String],
        new: [String],
        limits: Limits = .balanced,
        collapseContext: Int? = nil,
        isCancelled: () -> Bool = { false }
    ) -> Result {
        let (ops, degraded) = lineDiffDetailed(
            old, new, limits: limits, isCancelled: isCancelled
        )
        if isCancelled() {
            return .empty
        }
        var result = rows(from: ops, collapseContext: collapseContext)
        result.degraded = degraded
        return result
    }

    /// 把行级 ops 组装为带配对（modified）的行列表。
    /// delete 块与紧随的 insert 块按位置 zip 成 modified 行。
    public static func rows(from ops: [Op], collapseContext: Int? = nil) -> Result {
        var rows: [Row] = []
        rows.reserveCapacity(ops.count)
        var insertions = 0
        var deletions = 0
        var i = 0
        while i < ops.count {
            switch ops[i] {
            case .equal(let oi, let ni):
                rows.append(Row(kind: .equal(oldIndex: oi, newIndex: ni)))
                i += 1
            case .delete:
                // 收集连续 delete
                var deletes: [Int] = []
                while i < ops.count, case .delete(let oi) = ops[i] {
                    deletes.append(oi)
                    i += 1
                }
                // 收集紧随的连续 insert
                var inserts: [Int] = []
                while i < ops.count, case .insert(let ni) = ops[i] {
                    inserts.append(ni)
                    i += 1
                }
                let pairs = min(deletes.count, inserts.count)
                for p in 0 ..< pairs {
                    rows.append(
                        Row(kind: .modified(oldIndex: deletes[p], newIndex: inserts[p]))
                    )
                }
                insertions += pairs
                deletions += pairs
                if deletes.count > pairs {
                    for oi in deletes[pairs...] {
                        rows.append(Row(kind: .delete(oldIndex: oi)))
                    }
                    deletions += deletes.count - pairs
                }
                if inserts.count > pairs {
                    for ni in inserts[pairs...] {
                        rows.append(Row(kind: .insert(newIndex: ni)))
                    }
                    insertions += inserts.count - pairs
                }
            case .insert:
                // 孤立 insert 块（无前导 delete）
                while i < ops.count, case .insert(let ni) = ops[i] {
                    rows.append(Row(kind: .insert(newIndex: ni)))
                    insertions += 1
                    i += 1
                }
            }
        }
        if let context = collapseContext {
            rows = collapseEqualRuns(rows, context: context)
        }
        return Result(
            rows: rows,
            insertions: insertions,
            deletions: deletions,
            degraded: false
        )
    }

    /// 兼容入口（保留旧签名）。`old`/`new` 已不再需要——行内 diff 改为惰性计算。
    public static func buildRows(
        old _: [String],
        new _: [String],
        ops: [Op],
        collapseContext: Int? = nil
    ) -> [Row] {
        rows(from: ops, collapseContext: collapseContext).rows
    }

    /// 把过长的未变更段折叠成一行占位。典型 diff 里未变更行占绝大多数，
    /// 这一步能把渲染行数降一到两个数量级。
    private static func collapseEqualRuns(_ rows: [Row], context: Int) -> [Row] {
        var output: [Row] = []
        output.reserveCapacity(rows.count)
        var i = 0
        while i < rows.count {
            guard case .equal = rows[i].kind else {
                output.append(rows[i])
                i += 1
                continue
            }
            var runEnd = i
            while runEnd < rows.count, case .equal = rows[runEnd].kind {
                runEnd += 1
            }
            let run = i ..< runEnd
            // 文件头/尾的未变更段只需一侧上下文
            let leading = i == 0 ? 0 : context
            let trailing = runEnd == rows.count ? 0 : context
            // 折叠段至少要吃掉 2 行才值得
            if run.count >= leading + trailing + 2 {
                for k in i ..< (i + leading) {
                    output.append(rows[k])
                }
                let hiddenStart = i + leading
                let hiddenEnd = runEnd - trailing
                if let old = equalRange(rows, hiddenStart ..< hiddenEnd, useOld: true),
                   let new = equalRange(rows, hiddenStart ..< hiddenEnd, useOld: false)
                {
                    output.append(Row(kind: .collapsed(oldRange: old, newRange: new)))
                }
                for k in (runEnd - trailing) ..< runEnd {
                    output.append(rows[k])
                }
            } else {
                for k in run {
                    output.append(rows[k])
                }
            }
            i = runEnd
        }
        return output
    }

    private static func equalRange(
        _ rows: [Row],
        _ slice: Range<Int>,
        useOld: Bool
    ) -> Range<Int>? {
        guard
            case .equal(let firstOld, let firstNew) = rows[slice.lowerBound].kind,
            case .equal(let lastOld, let lastNew) = rows[slice.upperBound - 1].kind
        else { return nil }
        return useOld ? firstOld ..< (lastOld + 1) : firstNew ..< (lastNew + 1)
    }
}

// MARK: - 核心 differ

/// 在整数序列上工作的 diff 核心：线性空间 Myers + patience 锚点切分。
private final class Differ {
    private let a: [Int32]
    private let b: [Int32]
    private let limits: DiffEngine.Limits
    private let isCancelled: () -> Bool

    var ops: [DiffEngine.Op] = []
    var degraded = false

    /// bisect 用的两条对角线向量。顶层按最大规模分配一次，递归中复用。
    private var forward: [Int]
    private var backward: [Int]
    /// 取消检查是有成本的（闭包调用），按步数节流。
    private var steps = 0
    private var cancelled = false

    init(
        a: [Int32],
        b: [Int32],
        limits: DiffEngine.Limits,
        isCancelled: @escaping () -> Bool
    ) {
        self.a = a
        self.b = b
        self.limits = limits
        self.isCancelled = isCancelled
        let capacity = a.count + b.count + 4
        forward = [Int](repeating: -1, count: capacity)
        backward = [Int](repeating: -1, count: capacity)
    }

    func run() {
        ops.reserveCapacity(a.count + b.count)
        // 全等快速路径（整数数组直接比）
        if a == b {
            for i in 0 ..< a.count {
                ops.append(.equal(oldIndex: i, newIndex: i))
            }
            return
        }
        region(aLo: 0, aHi: a.count, bLo: 0, bHi: b.count, depth: 0)
    }

    private func checkCancelled() -> Bool {
        if cancelled {
            return true
        }
        steps += 1
        if steps & 0x3FF == 0, isCancelled() {
            cancelled = true
        }
        return cancelled
    }

    // MARK: 区段处理

    /// 先剥公共前后缀，再交给 `core`。
    private func region(aLo: Int, aHi: Int, bLo: Int, bHi: Int, depth: Int) {
        if checkCancelled() {
            return
        }
        var aLo = aLo, aHi = aHi, bLo = bLo, bHi = bHi

        while aLo < aHi, bLo < bHi, a[aLo] == b[bLo] {
            ops.append(.equal(oldIndex: aLo, newIndex: bLo))
            aLo += 1
            bLo += 1
        }
        var suffix = 0
        while aLo < aHi, bLo < bHi, a[aHi - 1] == b[bHi - 1] {
            suffix += 1
            aHi -= 1
            bHi -= 1
        }

        core(aLo: aLo, aHi: aHi, bLo: bLo, bHi: bHi, depth: depth)

        for k in 0 ..< suffix {
            ops.append(.equal(oldIndex: aHi + k, newIndex: bHi + k))
        }
    }

    private func core(aLo: Int, aHi: Int, bLo: Int, bHi: Int, depth: Int) {
        if checkCancelled() {
            return
        }
        let n = aHi - aLo
        let m = bHi - bLo
        if n == 0 {
            for j in bLo ..< bHi {
                ops.append(.insert(newIndex: j))
            }
            return
        }
        if m == 0 {
            for i in aLo ..< aHi {
                ops.append(.delete(oldIndex: i))
            }
            return
        }
        if depth >= limits.maxDepth {
            replaceWholeRegion(aLo: aLo, aHi: aHi, bLo: bLo, bHi: bHi)
            return
        }
        // 小区段直接 Myers：精确且必然很快
        if withinArea(limits.directMyersArea, n: n, m: m) {
            myers(aLo: aLo, aHi: aHi, bLo: bLo, bHi: bHi, depth: depth)
            return
        }
        // 大区段：先用 patience 锚点切成一堆小 gap
        let anchors = patienceAnchors(aLo: aLo, aHi: aHi, bLo: bLo, bHi: bHi)
        if !anchors.isEmpty {
            var prevA = aLo
            var prevB = bLo
            for (ia, ib) in anchors {
                region(aLo: prevA, aHi: ia, bLo: prevB, bHi: ib, depth: depth + 1)
                if checkCancelled() {
                    return
                }
                ops.append(.equal(oldIndex: ia, newIndex: ib))
                prevA = ia + 1
                prevB = ib + 1
            }
            region(aLo: prevA, aHi: aHi, bLo: prevB, bHi: bHi, depth: depth + 1)
            return
        }
        // 无锚点可用（区段内的行大量重复）：面积还能接受就硬算
        if withinArea(limits.maxMyersArea, n: n, m: m) {
            myers(aLo: aLo, aHi: aHi, bLo: bLo, bHi: bHi, depth: depth)
            return
        }
        if limits.allowsFallback {
            replaceWholeRegion(aLo: aLo, aHi: aHi, bLo: bLo, bHi: bHi)
            degraded = true
            return
        }
        myers(aLo: aLo, aHi: aHi, bLo: bLo, bHi: bHi, depth: depth)
    }

    private func replaceWholeRegion(aLo: Int, aHi: Int, bLo: Int, bHi: Int) {
        for i in aLo ..< aHi {
            ops.append(.delete(oldIndex: i))
        }
        for j in bLo ..< bHi {
            ops.append(.insert(newIndex: j))
        }
    }

    /// `n * m <= area`，用除法比较避免乘法溢出。
    private func withinArea(_ area: Int, n: Int, m: Int) -> Bool {
        area == .max || n <= area / max(m, 1)
    }

    // MARK: 线性空间 Myers

    private func myers(aLo: Int, aHi: Int, bLo: Int, bHi: Int, depth: Int) {
        let (x, y) = bisect(aLo: aLo, aHi: aHi, bLo: bLo, bHi: bHi)
        if checkCancelled() {
            return
        }
        // 分割点必须让两侧都真正变小，否则退化处理（防御性：避免无限递归）
        if (x == aLo && y == bLo) || (x == aHi && y == bHi) {
            replaceWholeRegion(aLo: aLo, aHi: aHi, bLo: bLo, bHi: bHi)
            return
        }
        region(aLo: aLo, aHi: x, bLo: bLo, bHi: y, depth: depth + 1)
        region(aLo: x, aHi: aHi, bLo: y, bHi: bHi, depth: depth + 1)
    }

    /// 双向搜索求分割点：返回 (x, y)，使 a[aLo..<x]/b[bLo..<y] 与
    /// a[x..<aHi]/b[y..<bHi] 可以各自独立求解。
    ///
    /// 只用 `forward`/`backward` 两条 O(n+m) 向量，空间与编辑距离无关。
    private func bisect(aLo: Int, aHi: Int, bLo: Int, bHi: Int) -> (Int, Int) {
        let n = aHi - aLo
        let m = bHi - bLo
        let maxD = (n + m + 1) / 2
        let offset = maxD
        let length = 2 * maxD + 2
        for i in 0 ..< length {
            forward[i] = -1
            backward[i] = -1
        }
        forward[offset + 1] = 0
        backward[offset + 1] = 0
        let delta = n - m
        // delta 为奇数时前向搜索先与后向相遇，反之后向先相遇。
        let checkForward = delta % 2 != 0
        var fStart = 0, fEnd = 0, rStart = 0, rEnd = 0

        var d = 0
        while d < maxD {
            if checkCancelled() {
                return (aHi, bLo)
            }

            // 前向
            var k = -d + fStart
            while k <= d - fEnd {
                let ko = offset + k
                var x: Int
                if k == -d || (k != d && forward[ko - 1] < forward[ko + 1]) {
                    x = forward[ko + 1]
                } else {
                    x = forward[ko - 1] + 1
                }
                var y = x - k
                while x < n, y < m, a[aLo + x] == b[bLo + y] {
                    x += 1
                    y += 1
                }
                forward[ko] = x
                if x > n {
                    fEnd += 2
                } else if y > m {
                    fStart += 2
                } else if checkForward {
                    let ro = offset + delta - k
                    if ro >= 0, ro < length, backward[ro] != -1 {
                        if x >= n - backward[ro] {
                            return (aLo + x, bLo + y)
                        }
                    }
                }
                k += 2
            }

            // 后向（在反转后的序列上做同样的前向搜索）
            var kr = -d + rStart
            while kr <= d - rEnd {
                let ko = offset + kr
                var x: Int
                if kr == -d || (kr != d && backward[ko - 1] < backward[ko + 1]) {
                    x = backward[ko + 1]
                } else {
                    x = backward[ko - 1] + 1
                }
                var y = x - kr
                while x < n, y < m, a[aLo + n - x - 1] == b[bLo + m - y - 1] {
                    x += 1
                    y += 1
                }
                backward[ko] = x
                if x > n {
                    rEnd += 2
                } else if y > m {
                    rStart += 2
                } else if !checkForward {
                    let fo = offset + delta - kr
                    if fo >= 0, fo < length, forward[fo] != -1 {
                        let fx = forward[fo]
                        let fy = offset + fx - fo
                        if fx >= n - x {
                            return (aLo + fx, bLo + fy)
                        }
                    }
                }
                kr += 2
            }
            d += 1
        }
        // 完全无公共部分：整块替换（左半全删、右半全增）
        return (aHi, bLo)
    }

    // MARK: patience 锚点

    /// 取两侧各只出现一次的行作为候选，再求 B 序上的最长递增子序列。
    private func patienceAnchors(aLo: Int, aHi: Int, bLo: Int, bHi: Int) -> [(Int, Int)] {
        var aCount: [Int32: Int32] = [:]
        aCount.reserveCapacity(aHi - aLo)
        for i in aLo ..< aHi {
            aCount[a[i], default: 0] += 1
        }

        var bInfo: [Int32: (count: Int32, index: Int32)] = [:]
        bInfo.reserveCapacity(bHi - bLo)
        for j in bLo ..< bHi {
            if let existing = bInfo[b[j]] {
                bInfo[b[j]] = (existing.count + 1, existing.index)
            } else {
                bInfo[b[j]] = (1, Int32(j))
            }
        }

        var pairs: [(Int, Int)] = []
        for i in aLo ..< aHi {
            let id = a[i]
            guard aCount[id] == 1, let info = bInfo[id], info.count == 1 else { continue }
            pairs.append((i, Int(info.index)))
        }
        // pairs 已按 A 序升序（外层按 i 递增遍历）
        return Differ.longestIncreasing(pairs)
    }

    /// patience sorting 求最长严格递增子序列（按 pair 的第二个分量）。
    private static func longestIncreasing(_ pairs: [(Int, Int)]) -> [(Int, Int)] {
        guard !pairs.isEmpty else { return [] }
        var tails: [Int] = [] // tails[l] = pairs 下标，其 B 值是长度 l+1 的最小尾
        var previous = [Int](repeating: -1, count: pairs.count)
        for i in 0 ..< pairs.count {
            let value = pairs[i].1
            var lo = 0, hi = tails.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if pairs[tails[mid]].1 < value {
                    lo = mid + 1
                } else {
                    hi = mid
                }
            }
            previous[i] = lo > 0 ? tails[lo - 1] : -1
            if lo == tails.count {
                tails.append(i)
            } else {
                tails[lo] = i
            }
        }
        var result: [(Int, Int)] = []
        result.reserveCapacity(tails.count)
        var cursor = tails[tails.count - 1]
        while cursor >= 0 {
            result.append(pairs[cursor])
            cursor = previous[cursor]
        }
        return result.reversed()
    }
}
