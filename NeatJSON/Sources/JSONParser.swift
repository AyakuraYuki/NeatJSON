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
        case let (l?, c?):
            String(
                localized: "error.at-position",
                defaultValue: "Line \(l), Column \(c): \(message)"
            )
        case let (l?, nil):
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

    public static func parseThrowing(_ text: String) throws -> JSONValue {
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

    /// 解析并按 key 排序（失败返回 nil）。
    public static func parse(_ text: String) -> JSONValue? {
        (try? parseThrowing(text))?.sorted()
    }

    /// 便捷入口：解析、按 key 排序、序列化，一步完成（失败返回 nil）。
    public static func parseAndSerialize(
        _ text: String,
        indent: IndentStyle = .spaces2
    ) -> String? {
        guard let value = parse(text) else { return nil }
        return JSONSerializer.serialize(value, indent: indent)
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

    init(scalars: ContiguousArray<Unicode.Scalar>) {
        self.scalars = scalars
    }

    var isAtEnd: Bool { index >= scalars.count }

    var peek: Unicode.Scalar? { index < scalars.count ? scalars[index] : nil }

    /// 推进一个标量并维护行/列。
    mutating func advance() -> Unicode.Scalar? {
        guard index < scalars.count else { return nil }
        let scalar = scalars[index]
        index += 1
        if scalar == "\n" {
            line += 1
            column = 0
        } else {
            column += 1
        }
        return scalar
    }

    mutating func skipWhitespace() {
        while let s = peek, s == " " || s == "\t" || s == "\n" || s == "\r" {
            _ = advance()
        }
    }

    /// 生成错误；`afterAdvance` 时行列已指向出错标量的下一个位置，需回退一列。
    func error(_ messageKey: String, hasPosition: Bool = true) -> JSONParseError {
        guard hasPosition else {
            return JSONParseError(message: String(localized: String.LocalizationValue(messageKey)))
        }
        return JSONParseError(
            message: String(localized: String.LocalizationValue(messageKey)),
            line: line + 1,
            column: column + 1
        )
    }

    func error(_ messageKey: String, _ args: [CVarArg], hasPosition: Bool = true) -> JSONParseError {
        let format = String(localized: String.LocalizationValue(messageKey))
        let message = String(format: format, locale: Locale.current, arguments: args)
        guard hasPosition else {
            return JSONParseError(message: message)
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
            return .string(try parseString())
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
            return .number(try parseNumber())
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
            guard let actual = advance(), actual == expected else {
                throw error("error.invalid-literal")
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
            if scalar == "\\" || scalar.value < 0x20 { break }
            cursor += 1
        }
        return try parseStringSlow()
    }

    /// 含转义（或非法控制字符）的字符串。`index` 仍指向开引号之后。
    mutating func parseStringSlow() throws -> String {
        var result = String.UnicodeScalarView()
        var lowSurrogate: Unicode.Scalar?

        func appendScalar(_ scalar: Unicode.Scalar) {
            result.append(scalar)
        }

        while true {
            guard let scalar = advance() else {
                throw error("error.unterminated-string")
            }
            if scalar == "\"" {
                if let low = lowSurrogate {
                    _ = low // 孤立低位代理
                    throw JSONParseError(
                        message: String(localized: "error.lone-surrogate"),
                        line: line + 1,
                        column: column + 1
                    )
                }
                return String(result)
            }
            if scalar == "\\" {
                guard let escape = advance() else {
                    throw error("error.unterminated-string")
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
                    let parsed = try parseUnicodeEscape()
                    if case .high(let high) = parsed {
                        if lowSurrogate != nil {
                            // 两个连续高位代理，前者孤立
                            throw JSONParseError(
                                message: String(localized: "error.lone-surrogate"),
                                line: line + 1,
                                column: column + 1
                            )
                        }
                        lowSurrogate = high
                    } else if case .scalar(let scalar) = parsed {
                        if let low = lowSurrogate {
                            // 高+低代理对 → 组合
                            guard let combined = combineSurrogates(high: low, low: scalar) else {
                                throw JSONParseError(
                                    message: String(localized: "error.lone-surrogate"),
                                    line: line + 1,
                                    column: column + 1
                                )
                            }
                            lowSurrogate = nil
                            appendScalar(combined)
                        } else if isLowSurrogate(scalar) {
                            // 孤立低位代理
                            throw JSONParseError(
                                message: String(localized: "error.lone-surrogate"),
                                line: line + 1,
                                column: column + 1
                            )
                        } else {
                            appendScalar(scalar)
                        }
                    }
                default:
                    throw error("error.invalid-escape")
                }
                continue
            }
            // 未转义的原始控制字符（U+0000...U+001F）非法
            if scalar.value < 0x20 {
                throw error("error.control-char")
            }
            if let low = lowSurrogate {
                _ = low
                // 代理对后跟普通字符 —— 前一个高位代理孤立
                throw JSONParseError(
                    message: String(localized: "error.lone-surrogate"),
                    line: line + 1,
                    column: column + 1
                )
            }
            appendScalar(scalar)
        }
    }

    fileprivate enum UnicodeEscape {
        case scalar(Unicode.Scalar)
        case high(Unicode.Scalar) // D800–DBFF
    }

    mutating func parseUnicodeEscape() throws -> UnicodeEscape {
        var value: UInt32 = 0
        for _ in 0..<4 {
            guard let digit = advance() else {
                throw error("error.invalid-unicode-escape")
            }
            guard let nibble = hexValue(digit) else {
                throw error("error.invalid-unicode-escape")
            }
            value = value << 4 | nibble
        }
        guard let scalar = Unicode.Scalar(value) else {
            throw error("error.invalid-unicode-escape")
        }
        if (0xD800...0xDBFF).contains(value) {
            return .high(scalar)
        }
        return .scalar(scalar)
    }

    private func combineSurrogates(high: Unicode.Scalar, low: Unicode.Scalar) -> Unicode.Scalar? {
        guard isLowSurrogate(low) else { return nil }
        let combined = 0x10000 + (high.value - 0xD800) << 10 + (low.value - 0xDC00)
        return Unicode.Scalar(combined)
    }

    private func isLowSurrogate(_ scalar: Unicode.Scalar) -> Bool {
        (0xDC00...0xDFFF).contains(scalar.value)
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
        if peek == "-" { _ = advance() }
        // 整数部分
        guard let first = peek, first == "0" || ("1"..."9").contains(first) else {
            throw error("error.invalid-number")
        }
        _ = advance()
        if first != "0" {
            while let s = peek, "0"..."9" ~= s { _ = advance() }
        }
        // 小数部分
        if peek == "." {
            _ = advance()
            guard let s = peek, "0"..."9" ~= s else {
                throw error("error.invalid-number")
            }
            while let s = peek, "0"..."9" ~= s { _ = advance() }
        }
        // 指数部分
        if peek == "e" || peek == "E" {
            _ = advance()
            if peek == "+" || peek == "-" { _ = advance() }
            guard let s = peek, "0"..."9" ~= s else {
                throw error("error.invalid-number")
            }
            while let s = peek, "0"..."9" ~= s { _ = advance() }
        }
        let lexeme = String(String.UnicodeScalarView(scalars[start..<index]))
        return lexeme
    }
}
