import AppKit

/// JSON 语法高亮。
///
/// 与旧实现的关键差异（这是大文本键入卡顿的直接原因）：
/// - 旧实现在**主线程**对 `NSTextStorage` 逐 token `addAttribute`，且**没有**
///   `beginEditing()/endEditing()` 包裹 —— 每一次 addAttribute 都会发出编辑
///   通知、触发 layout manager 失效。现在扫描（O(n) 的那部分）全在后台，
///   主线程只在 begin/endEditing 里成批套属性；大文档还会按
///   `applyChunkSize` 分块、块间让出主线程，观感是渐进上色而非卡顿。
/// - 旧分词器用 `NSString.character(at:)` 逐码元读取，每个字符一次 objc
///   派发。现在先取 UTF-16 缓冲区，用 `UnsafeBufferPointer` 扫描。
/// - 只改属性、不替换字符：选中范围与撤销栈都不受影响。
/// - 新增按范围的增量着色，供输入区打字时只重刷编辑点所在的行。
enum JSONSyntaxHighlighter {
    struct Palette: Equatable {
        let base: NSColor
        let key: NSColor
        let string: NSColor
        let number: NSColor
        let literal: NSColor // true/false/null

        /// 浅色模式配色：高饱和、对白底可读。
        ///
        /// base 用固定 sRGB 色而非 NSColor.textColor 这类动态色：
        /// 动态色作为属性存进 NSTextStorage 后要等绘制时才按当时的
        /// appearance 解析，而编辑器处于 vibrant/玻璃材质上下文中，
        /// 固定色可避免解析到意外变体的风险，行为更可预期。
        static let light = Palette(
            base: colorLightText,
            key: NSColor(srgbRed: 0.10, green: 0.36, blue: 0.78, alpha: 1),
            string: NSColor(srgbRed: 0.78, green: 0.17, blue: 0.24, alpha: 1),
            number: NSColor(srgbRed: 0.07, green: 0.42, blue: 0.32, alpha: 1),
            literal: NSColor(srgbRed: 0.52, green: 0.26, blue: 0.72, alpha: 1)
        )

        /// 深色模式配色：提亮的同族色，对深底可读。
        static let dark = Palette(
            base: colorDarkText,
            key: NSColor(srgbRed: 0.42, green: 0.70, blue: 0.98, alpha: 1),
            string: NSColor(srgbRed: 0.98, green: 0.55, blue: 0.58, alpha: 1),
            number: NSColor(srgbRed: 0.40, green: 0.82, blue: 0.64, alpha: 1),
            literal: NSColor(srgbRed: 0.78, green: 0.58, blue: 0.98, alpha: 1)
        )

        /// 依据当前视图外观选择配色（外观判定的回退链见 `NSView.isDarkAppearance`）。
        @MainActor static func current(for textView: NSTextView) -> Palette {
            textView.isDarkAppearance ? .dark : .light
        }

        func color(for kind: TokenKind) -> NSColor {
            switch kind {
            case .key: key
            case .string: string
            case .number: number
            case .literal: literal
            }
        }
    }

    /// 渲染样式（字体 + 配色）。只在主线程使用。
    struct RenderStyle: Equatable {
        let font: NSFont
        let palette: Palette

        var baseAttributes: [NSAttributedString.Key: Any] {
            [.font: font, .foregroundColor: palette.base]
        }
    }

    enum TokenKind: UInt8, Sendable {
        case key
        case string
        case number
        case literal
    }

    /// 一段着色区间（UTF-16 偏移，相对扫描起点）。
    struct TokenSpan: Sendable {
        var location: Int32
        var length: Int32
        var kind: TokenKind
    }

    /// 扫描结果。纯值类型，可安全跨线程传递。
    ///
    /// `spans` 为空有两种情况：文本里确实没有 token，或文本超过
    /// `maxHighlightUnits` 被跳过着色。两者对调用方是同一种处理
    /// （只铺基础样式），因此不额外区分。
    struct ScanResult: Sendable {
        var spans: [TokenSpan]
        /// 扫描时文本的 UTF-16 长度，用于套用前校验文本没变。
        var utf16Length: Int
    }

    /// 超过这么多 UTF-16 码元只铺基础样式，不做 token 着色：
    /// 再大的文本着色收益已远小于成本。
    static let maxHighlightUnits = 3 * 1024 * 1024

    // MARK: - 取文本

    /// 把 storage 的内容批量拷成 UTF-16 缓冲区。
    ///
    /// 走 `getCharacters` 而不是 `ContiguousArray(storage.string.utf16)`：
    /// `NSTextStorage.string` 是懒桥接 NSString 的 String，非连续存储，
    /// 逐码元访问全都要过桥。实测 1.3 MB 文档，批量拷贝 0.5 ms，
    /// 从桥接串建 utf16 数组要 14.6 ms。
    @MainActor
    static func utf16Units(of storage: NSTextStorage) -> ContiguousArray<UInt16> {
        let length = storage.length
        guard length > 0 else { return [] }
        var units = ContiguousArray<UInt16>(repeating: 0, count: length)
        units.withUnsafeMutableBufferPointer { buffer in
            storage.mutableString.getCharacters(
                buffer.baseAddress!,
                range: NSRange(location: 0, length: length)
            )
        }
        return units
    }

    // MARK: - 后台扫描

    /// 分词。**可在任意线程调用**，不触碰任何 UI 对象。
    nonisolated static func scan(units: ContiguousArray<UInt16>) -> ScanResult {
        guard units.count <= maxHighlightUnits else {
            return ScanResult(spans: [], utf16Length: units.count)
        }
        return ScanResult(spans: tokenSpans(units), utf16Length: units.count)
    }

    // MARK: - 主线程套用

    /// 每次让出主线程之间套用多少个 token。
    ///
    /// 实测 1.4 MB / 16.8 万 token 的文档一次性套完要 ~53 ms（会掉帧）；
    /// 按这个粒度切开后每块 ~6 ms，观感上是渐进上色而不是卡顿。
    static let applyChunkSize = 20000

    /// 铺基础样式（等宽字体 + 正文色）。一次 setAttributes，代价与文本长度无关。
    @MainActor
    static func applyBase(to storage: NSTextStorage, style: RenderStyle) {
        let fullRange = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        // 先彻底清掉旧的颜色属性——残留的动态 NSColor（如 textColor）
        // 会在绘制时按错误的外观解析，必须连根拔起再铺固定色。
        storage.removeAttribute(.foregroundColor, range: fullRange)
        storage.setAttributes(style.baseAttributes, range: fullRange)
        storage.endEditing()
    }

    /// 套用一批 token 颜色。
    ///
    /// 只改属性不动字符，所以选中范围与撤销栈都不受影响；整批包在一对
    /// begin/endEditing 里，layout manager 每批只失效一次。
    @MainActor
    static func applySpans(
        _ spans: ArraySlice<TokenSpan>,
        to storage: NSTextStorage,
        palette: Palette
    ) {
        guard !spans.isEmpty else { return }
        let limit = storage.length
        storage.beginEditing()
        for span in spans {
            let location = Int(span.location)
            let length = Int(span.length)
            guard location + length <= limit else { continue }
            storage.addAttribute(
                .foregroundColor,
                value: palette.color(for: span.kind),
                range: NSRange(location: location, length: length)
            )
        }
        storage.endEditing()
    }

    /// 一次性套完（小文档用；大文档走 `applyBase` + 分块 `applySpans`）。
    @MainActor
    static func apply(_ result: ScanResult, to storage: NSTextStorage, style: RenderStyle) {
        guard storage.length == result.utf16Length else { return }
        applyBase(to: storage, style: style)
        applySpans(result.spans[...], to: storage, palette: style.palette)
    }

    /// 只重刷 `range` 这一段（输入区打字时用）。
    ///
    /// `range` 应落在词法安全的边界上（取到行首即可 —— JSON 字符串不允许
    /// 包含裸换行，所以行首一定不在字符串内部）。
    @MainActor
    static func highlight(_ storage: NSTextStorage, range: NSRange, style: RenderStyle) {
        guard range.length > 0, NSMaxRange(range) <= storage.length else { return }
        var units = ContiguousArray<UInt16>(repeating: 0, count: range.length)
        units.withUnsafeMutableBufferPointer { buffer in
            storage.mutableString.getCharacters(buffer.baseAddress!, range: range)
        }
        let spans = tokenSpans(units)
        storage.beginEditing()
        storage.removeAttribute(.foregroundColor, range: range)
        storage.setAttributes(style.baseAttributes, range: range)
        for span in spans {
            storage.addAttribute(
                .foregroundColor,
                value: style.palette.color(for: span.kind),
                range: NSRange(
                    location: range.location + Int(span.location),
                    length: Int(span.length)
                )
            )
        }
        storage.endEditing()
    }

    // MARK: - 分词

    /// 扫描 UTF-16 缓冲区，产出着色区间。纯计算，可在任意线程调用。
    ///
    /// 以整数下标遍历 `UnsafeBufferPointer`，避免 `NSString.character(at:)`
    /// 的逐字符 objc 派发（大文本下差一个数量级）。
    nonisolated static func tokenSpans(_ units: ContiguousArray<UInt16>) -> [TokenSpan] {
        units.withUnsafeBufferPointer { text -> [TokenSpan] in
            var spans: [TokenSpan] = []
            // 经验值：JSON 里大致每 8 个码元一个 token
            spans.reserveCapacity(text.count / 8 + 8)
            let length = text.count
            var i = 0

            func isSpace(_ c: UInt16) -> Bool {
                c == 0x20 || c == 0x09 || c == 0x0a || c == 0x0d
            }
            func append(_ kind: TokenKind, from start: Int, to end: Int) {
                guard end > start else { return }
                spans.append(
                    TokenSpan(
                        location: Int32(start),
                        length: Int32(end - start),
                        kind: kind
                    )
                )
            }

            while i < length {
                let c = text[i]
                switch c {
                case 0x22: // "
                    // 字符串：找到闭合引号（跳过转义）
                    var cursor = i + 1
                    var closed = false
                    while cursor < length {
                        let cc = text[cursor]
                        if cc == 0x5c { // 反斜杠：跳过被转义的下一个码元
                            cursor += 2
                            continue
                        }
                        if cc == 0x22 {
                            cursor += 1
                            closed = true
                            break
                        }
                        cursor += 1
                    }
                    if !closed || cursor > length {
                        cursor = length
                    }
                    // 判定 key：闭合引号之后跳过空白，遇 ':' 则是 key
                    var lookahead = cursor
                    while lookahead < length, isSpace(text[lookahead]) {
                        lookahead += 1
                    }
                    let isKey = lookahead < length && text[lookahead] == 0x3a // ':'
                    append(isKey ? .key : .string, from: i, to: cursor)
                    i = cursor
                case 0x30 ... 0x39, 0x2b, 0x2d, 0x2e: // 0-9 + - .
                    // 数字：连续的数字/符号/指数字符
                    var cursor = i
                    while cursor < length {
                        let cc = text[cursor]
                        if (cc >= 0x30 && cc <= 0x39) || cc == 0x2b || cc == 0x2d
                            || cc == 0x2e || cc == 0x65 || cc == 0x45
                        { // e E
                            cursor += 1
                        } else {
                            break
                        }
                    }
                    append(.number, from: i, to: cursor)
                    i = cursor
                case 0x74, 0x66, 0x6e: // t f n
                    // 字面量：true / false / null
                    var cursor = i
                    while cursor < length, text[cursor] >= 0x61, text[cursor] <= 0x7a {
                        cursor += 1
                    }
                    if matchesLiteral(text, from: i, to: cursor) {
                        append(.literal, from: i, to: cursor)
                    }
                    i = cursor
                default:
                    i += 1
                }
            }
            return spans
        }
    }

    /// 比对 `true` / `false` / `null`，不做字符串分配。
    private nonisolated static func matchesLiteral(
        _ text: UnsafeBufferPointer<UInt16>,
        from start: Int,
        to end: Int
    ) -> Bool {
        switch end - start {
        case 4: // true / null
            equals(text, start, [0x74, 0x72, 0x75, 0x65])
                || equals(text, start, [0x6e, 0x75, 0x6c, 0x6c])
        case 5: // false
            equals(text, start, [0x66, 0x61, 0x6c, 0x73, 0x65])
        default:
            false
        }
    }

    private nonisolated static func equals(
        _ text: UnsafeBufferPointer<UInt16>,
        _ start: Int,
        _ pattern: [UInt16]
    ) -> Bool {
        for (offset, unit) in pattern.enumerated() where text[start + offset] != unit {
            return false
        }
        return true
    }
}
