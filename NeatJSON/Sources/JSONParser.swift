import Foundation

/// JSON 解析错误，附带行/列定位（均从 1 计；列按 Unicode 标量数）。
public struct JSONParseError: Error, Equatable, Sendable {
    public var message: String
    public var line: Int?
    public var column: Int?

    public init(message: String, line: Int? = nil, column: Int? = nil) {
        self.message = message
        self.line = line
        self.column = column
    }

    /// 形如「第 3 行第 5 列：期望 ',' 或 '}'」的本地化描述。
    public var localizedDescription: String {
        switch (line, column) {
        case (let l?, let c?):
            String(
                localized: "error.at-position",
                defaultValue: "Line \(l), Column \(c): \(message)"
            )
        case (let l?, nil):
            String(
                localized: "error.at-line",
                defaultValue: "Line \(l): \(message)"
            )
        default:
            message
        }
    }
}

/// 递归下降 JSON 解析器。
///
/// 独立于 `JSONSerialization`，以获得：数字字面量保真、
/// 带行列号的错误信息、可控的深度上限。
public enum JSONParser {
    /// 递归深度上限，超出即报错而非爆栈。
    public static let maximumDepth = 512

    // MARK: - 入口

    public static func parse(_ text: String) throws -> JSONValue {
        // 直接建标量数组。旧实现写作 `Scanner(text: String(text.unicodeScalars))`，
        // 那样会先把整份文本复制成一个新 String、再复制成数组。
        var scanner = Scanner(scalars: ContiguousArray(text.unicodeScalars))
        let value = try scanner.parseValue(depth: 0)
        scanner.skipWhitespace()
        if !scanner.isAtEnd {
            throw scanner.error("error.trailing-characters")
        }
        return value
    }
}

// MARK: - Scanner

private struct Scanner {
    let scalars: ContiguousArray<Unicode.Scalar>
    var index: Int = 0
    /// 当前标量所在行（0 起），随换行推进。
    var line: Int = 0
    /// 当前标量所在列（0 起）。
    var column: Int = 0
    /// 最近一次换行符在上一行的列（1 起）。advance 吃掉 `\n` 后
    /// line/column 已指向下一行开头，靠它把错误位置回退到上一行末尾。
    var previousLineColumn: Int = 0

    init(scalars: ContiguousArray<Unicode.Scalar>) {
        self.scalars = scalars
    }

    var isAtEnd: Bool {
        index >= scalars.count
    }

    var peek: Unicode.Scalar? {
        index < scalars.count ? scalars[index] : nil
    }

    /// 推进一个标量并维护行/列。
    mutating func advance() -> Unicode.Scalar? {
        guard index < scalars.count else { return nil }
        let scalar = scalars[index]
        index += 1
        if scalar == "\n" {
            previousLineColumn = column + 1
            line += 1
            column = 0
        }
        else {
            column += 1
        }
        return scalar
    }

    mutating func skipWhitespace() {
        while let s = peek, s == " " || s == "\t" || s == "\n" || s == "\r" {
            _ = advance()
        }
    }

    /// 生成错误。行列号约定：`line`/`column` 始终指向**下一个待读标量**。
    ///
    /// - peek 型错误（出错字符还没消费）：直接 `line + 1, column + 1` 即指向它。
    /// - advance 型错误（出错字符刚被 `advance()` 吃掉）：传 `afterAdvance: true`
    ///   回退——普通字符退一列；刚吃掉的是 `\n` 时退到上一行末尾
    ///   （此时 `column == 0`，上一行行号为已自增的 `line`，列取 `previousLineColumn`）。
    func error(
        _ messageKey: String,
        afterAdvance: Bool = false
    ) -> JSONParseError {
        let message = String(localized: String.LocalizationValue(messageKey))
        if afterAdvance {
            if column == 0 {
                // 刚消费的是 \n：出错位置在上一行末尾
                return JSONParseError(message: message, line: line, column: previousLineColumn)
            }
            return JSONParseError(message: message, line: line + 1, column: column)
        }
        return JSONParseError(message: message, line: line + 1, column: column + 1)
    }

    // MARK: - 值

    mutating func parseValue(depth: Int) throws -> JSONValue {
        guard depth <= JSONParser.maximumDepth else {
            throw JSONParseError(
                message: String(
                    localized: "error.too-deep",
                    defaultValue: "Nesting is too deep (over \(JSONParser.maximumDepth) levels)"
                )
            )
        }
        skipWhitespace()
        guard let first = peek else {
            throw error("error.empty-input")
        }
        switch first {
        case "{":
            return try parseObject(depth: depth)
        case "[":
            return try parseArray(depth: depth)
        case "\"":
            return try .string(parseString())
        case "t":
            try parseLiteral("true")
            return .bool(true)
        case "f":
            try parseLiteral("false")
            return .bool(false)
        case "n":
            try parseLiteral("null")
            return .null
        case "-", "0"..."9":
            return try .number(parseNumber())
        default:
            throw error("error.unexpected-char")
        }
    }

    mutating func parseObject(depth: Int) throws -> JSONValue {
        _ = advance() // consume '{'
        var members: [(String, JSONValue)] = []
        skipWhitespace()
        if peek == "}" {
            _ = advance()
            return .object(members)
        }
        while true {
            skipWhitespace()
            guard peek == "\"" else {
                throw error("error.expect-object-key")
            }
            let key = try parseString()
            // 记录 key 结束位置：若缺冒号，错误应指向 key 而不是被
            // skipWhitespace 吞掉换行后的下一个 token。
            let (keyLine, keyColumn) = (line, column)
            skipWhitespace()
            guard peek == ":" else {
                throw JSONParseError(
                    message: String(localized: String.LocalizationValue("error.expect-colon")),
                    line: keyLine + 1,
                    column: keyColumn + 1
                )
            }
            _ = advance()
            let value = try parseValue(depth: depth + 1)
            members.append((key, value))
            skipWhitespace()
            if peek == "," {
                _ = advance()
                // 尾随逗号：`{"a":1,}` —— 若紧跟 '}' 则报缺值错误
                skipWhitespace()
                if peek == "}" {
                    throw error("error.expect-value")
                }
                continue
            }
            if peek == "}" {
                _ = advance()
                return .object(members)
            }
            throw error("error.expect-comma-or-brace")
        }
    }

    mutating func parseArray(depth: Int) throws -> JSONValue {
        _ = advance() // consume '['
        var items: [JSONValue] = []
        skipWhitespace()
        if peek == "]" {
            _ = advance()
            return .array(items)
        }
        while true {
            let value = try parseValue(depth: depth + 1)
            items.append(value)
            skipWhitespace()
            if peek == "," {
                _ = advance()
                skipWhitespace()
                if peek == "]" {
                    throw error("error.expect-value")
                }
                continue
            }
            if peek == "]" {
                _ = advance()
                return .array(items)
            }
            throw error("error.expect-comma-or-bracket")
        }
    }

    // MARK: - 字面量

    mutating func parseLiteral(_ literal: String) throws {
        for expected in literal.unicodeScalars {
            guard let actual = advance() else {
                // 输入中途结束：位置指向「应该有字符」的地方
                throw error("error.invalid-literal")
            }
            guard actual == expected else {
                throw error("error.invalid-literal", afterAdvance: true)
            }
        }
    }

    // MARK: - 字符串

    mutating func parseString() throws -> String {
        _ = advance() // consume '"'
        // 快速路径：不含转义与控制字符时直接切片，避免逐标量 append。
        // JSON 字符串里不允许裸换行（控制字符会在慢速路径报错），所以
        // 这段区间内 line 不变、column 只是线性推进。
        var cursor = index
        while cursor < scalars.count {
            let scalar = scalars[cursor]
            if scalar == "\"" {
                let lexeme = String(String.UnicodeScalarView(scalars[index ..< cursor]))
                column += cursor - index + 1
                index = cursor + 1
                return lexeme
            }
            if scalar == "\\" || scalar.value < 0x20 {
                break
            }
            cursor += 1
        }
        return try parseStringSlow()
    }

    /// 含转义（或非法控制字符）的字符串。`index` 仍指向开引号之后。
    mutating func parseStringSlow() throws -> String {
        var result = String.UnicodeScalarView()
        /// 已读到、正等待低位代理来组合的高位代理码点。
        /// 代理区码点不是合法 Unicode.Scalar，只能以 UInt32 暂存。
        var pendingHighSurrogate: UInt32?

        func appendScalar(_ scalar: Unicode.Scalar) {
            result.append(scalar)
        }

        while true {
            guard let scalar = advance() else {
                throw error("error.unterminated-string")
            }
            if scalar == "\"" {
                // 字符串结束还挂着高位代理 —— 孤立
                guard pendingHighSurrogate == nil else {
                    throw error("error.lone-surrogate", afterAdvance: true)
                }
                return String(result)
            }
            if scalar == "\\" {
                guard let escape = advance() else {
                    throw error("error.unterminated-string")
                }
                // 高位代理之后只允许紧跟 \u 形式的低位代理；
                // 接其他任何转义，高位代理孤立。
                if escape != "u", pendingHighSurrogate != nil {
                    throw error("error.lone-surrogate", afterAdvance: true)
                }
                switch escape {
                case "\"": appendScalar("\"")
                case "\\": appendScalar("\\")
                case "/": appendScalar("/")
                case "b": appendScalar("\u{08}")
                case "f": appendScalar("\u{0C}")
                case "n": appendScalar("\n")
                case "r": appendScalar("\r")
                case "t": appendScalar("\t")
                case "u":
                    switch try parseUnicodeEscape() {
                    case .surrogate(let codePoint) where codePoint <= 0xDBFF:
                        // 高位代理：暂存，等低位代理来组合
                        guard pendingHighSurrogate == nil else {
                            // 两个连续高位代理，前者孤立
                            throw error("error.lone-surrogate", afterAdvance: true)
                        }
                        pendingHighSurrogate = codePoint
                    case .surrogate(let codePoint):
                        // 低位代理：必须紧跟在高位代理之后
                        guard let high = pendingHighSurrogate else {
                            throw error("error.lone-surrogate", afterAdvance: true)
                        }
                        pendingHighSurrogate = nil
                        appendScalar(combineSurrogates(high: high, low: codePoint))
                    case .scalar(let scalar):
                        // 高位代理后接了普通标量 —— 高位孤立
                        guard pendingHighSurrogate == nil else {
                            throw error("error.lone-surrogate", afterAdvance: true)
                        }
                        appendScalar(scalar)
                    }
                default:
                    throw error("error.invalid-escape", afterAdvance: true)
                }
                continue
            }
            // 未转义的原始控制字符（U+0000...U+001F）非法
            if scalar.value < 0x20 {
                throw error("error.control-char", afterAdvance: true)
            }
            // 高位代理后紧跟非转义字符 —— 高位孤立
            guard pendingHighSurrogate == nil else {
                throw error("error.lone-surrogate", afterAdvance: true)
            }
            appendScalar(scalar)
        }
    }

    fileprivate enum UnicodeEscape {
        case scalar(Unicode.Scalar)
        /// 代理区码点（D800–DFFF）的原始值。代理码点不是合法
        /// Unicode.Scalar（其 init 返回 nil），只能按数值承载；
        /// 高/低位判定与组合由调用方完成。
        case surrogate(UInt32)
    }

    mutating func parseUnicodeEscape() throws -> UnicodeEscape {
        var value: UInt32 = 0
        for _ in 0 ..< 4 {
            guard let digit = advance() else {
                throw error("error.invalid-unicode-escape")
            }
            guard let nibble = hexValue(digit) else {
                throw error("error.invalid-unicode-escape", afterAdvance: true)
            }
            value = value << 4 | nibble
        }
        // 先按数值拦截代理区：Unicode.Scalar.init 对代理码点返回 nil，
        // 不拦截会把合法的代理对（如 😀）误报成非法转义。
        if (0xD800...0xDFFF).contains(value) {
            return .surrogate(value)
        }
        guard let scalar = Unicode.Scalar(value) else {
            throw error("error.invalid-unicode-escape", afterAdvance: true)
        }
        return .scalar(scalar)
    }

    /// 组合代理对。调用点已保证 high ∈ D800–DBFF、low ∈ DC00–DFFF，
    /// 结果必落在 0x10000–0x10FFFF（合法标量），故可强制解包。
    private func combineSurrogates(high: UInt32, low: UInt32) -> Unicode.Scalar {
        Unicode.Scalar(0x10000 + (high - 0xD800) << 10 + (low - 0xDC00))!
    }

    private func hexValue(_ scalar: Unicode.Scalar) -> UInt32? {
        switch scalar {
        case "0"..."9": return scalar.value - Unicode.Scalar("0").value
        case "a"..."f": return scalar.value - Unicode.Scalar("a").value + 10
        case "A"..."F": return scalar.value - Unicode.Scalar("A").value + 10
        default: return nil
        }
    }

    // MARK: - 数字

    mutating func parseNumber() throws -> String {
        let start = index
        if peek == "-" {
            _ = advance()
        }
        // 整数部分
        guard let first = peek, first == "0" || ("1"..."9").contains(first) else {
            throw error("error.invalid-number")
        }
        _ = advance()
        if first != "0" {
            while let s = peek, "0"..."9" ~= s {
                _ = advance()
            }
        }
        // 小数部分
        if peek == "." {
            _ = advance()
            guard let s = peek, "0"..."9" ~= s else {
                throw error("error.invalid-number")
            }
            while let s = peek, "0"..."9" ~= s {
                _ = advance()
            }
        }
        // 指数部分
        if peek == "e" || peek == "E" {
            _ = advance()
            if peek == "+" || peek == "-" {
                _ = advance()
            }
            guard let s = peek, "0"..."9" ~= s else {
                throw error("error.invalid-number")
            }
            while let s = peek, "0"..."9" ~= s {
                _ = advance()
            }
        }
        return String(String.UnicodeScalarView(scalars[start ..< index]))
    }
}
