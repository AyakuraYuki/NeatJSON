import Foundation

/// 序列化缩进风格。
public enum IndentStyle: String, CaseIterable, Sendable, Identifiable {
    case spaces2
    case spaces4
    case tab

    public var id: String {
        rawValue
    }

    public var label: String {
        switch self {
        case .spaces2: "2"
        case .spaces4: "4"
        case .tab: "Tab"
        }
    }

    var unit: String {
        switch self {
        case .spaces2: "  "
        case .spaces4: "    "
        case .tab: "\t"
        }
    }
}

/// JSON 序列化器：pretty-print、递归按 key 排序、数字字面量原样输出。
public enum JSONSerializer {
    /// - Parameters:
    ///   - value: 解析得到的值。
    ///   - indent: 缩进风格。
    ///   - sortKeys: 是否按键排序（默认开）。
    ///   - keyOrder: key 排序规则（默认码点序，与旧行为一致）。
    ///   - trailingNewline: 末尾是否补换行（编辑器展示用，默认 true）。
    public static func serialize(
        _ value: JSONValue,
        indent: IndentStyle = .spaces2,
        sortKeys: Bool = true,
        keyOrder: JSONKeyOrder = .codepoint,
        trailingNewline: Bool = true
    ) -> String {
        // 注意：不再先 `value.sorted()` 复制整棵树，而是在写每个对象时就地
        // 排序它自己的成员——输出完全一致，但省掉一整棵树的重建。
        var writer = Writer(indent: indent, sortKeys: sortKeys, keyOrder: keyOrder)
        writer.writeValue(value, depth: 0)
        if trailingNewline {
            writer.out.append("\n")
        }
        return writer.out
    }

    private struct Writer {
        let indent: IndentStyle
        let sortKeys: Bool
        let keyOrder: JSONKeyOrder
        var out: String = ""
        /// 按深度缓存的缩进串。旧实现每写一行都 `String(repeating:)`，
        /// 十万行就是十万次字符串分配。
        private var pads: [String] = [""]

        init(indent: IndentStyle, sortKeys: Bool, keyOrder: JSONKeyOrder) {
            self.indent = indent
            self.sortKeys = sortKeys
            self.keyOrder = keyOrder
            out.reserveCapacity(4096)
        }

        private mutating func pad(_ depth: Int) -> String {
            while pads.count <= depth {
                pads.append(pads[pads.count - 1] + indent.unit)
            }
            return pads[depth]
        }

        mutating func writeValue(_ value: JSONValue, depth: Int) {
            switch value {
            case .object(let members):
                writeObject(members, depth: depth)
            case .array(let items):
                writeArray(items, depth: depth)
            case .string(let string):
                writeString(string)
            case .number(let lexeme):
                out += lexeme
            case .bool(let bool):
                out += bool ? "true" : "false"
            case .null:
                out += "null"
            }
        }

        mutating func writeObject(_ members: [(String, JSONValue)], depth: Int) {
            if members.isEmpty {
                out += "{}"
                return
            }
            // 比较器无分配、绝大多数 key 在前几个字节就分出胜负；
            // 码点序分支直接走标准库比较，不比旧的 `$0.0 < $1.0` 慢。
            let ordered = sortKeys
                ? members.sorted { keyOrder.areInIncreasingOrder($0.0, $1.0) }
                : members
            out += "{\n"
            let inner = pad(depth + 1)
            let last = ordered.count - 1
            for (offset, member) in ordered.enumerated() {
                out += inner
                writeString(member.0)
                out += ": "
                writeValue(member.1, depth: depth + 1)
                if offset < last {
                    out += ","
                }
                out += "\n"
            }
            let outer = pad(depth)
            out += outer
            out += "}"
        }

        mutating func writeArray(_ items: [JSONValue], depth: Int) {
            if items.isEmpty {
                out += "[]"
                return
            }
            out += "[\n"
            let inner = pad(depth + 1)
            let last = items.count - 1
            for (offset, item) in items.enumerated() {
                out += inner
                writeValue(item, depth: depth + 1)
                if offset < last {
                    out += ","
                }
                out += "\n"
            }
            let outer = pad(depth)
            out += outer
            out += "]"
        }

        mutating func writeString(_ string: String) {
            out += "\""
            // 快速路径：绝大多数 key/值都不含需要转义的字符，整串追加即可，
            // 不必逐标量走 switch。
            if Writer.needsEscaping(string) {
                for scalar in string.unicodeScalars {
                    switch scalar {
                    case "\"": out += "\\\""
                    case "\\": out += "\\\\"
                    case "\n": out += "\\n"
                    case "\r": out += "\\r"
                    case "\t": out += "\\t"
                    case "\u{08}": out += "\\b"
                    case "\u{0C}": out += "\\f"
                    default:
                        if scalar.value < 0x20 {
                            out += String(format: "\\u%04x", scalar.value)
                        } else {
                            out.unicodeScalars.append(scalar)
                        }
                    }
                }
            } else {
                out += string
            }
            out += "\""
        }

        /// 是否含需要转义的字符。
        ///
        /// 走 UTF-8 视图：多字节序列的续字节恒 ≥ 0x80，所以 `< 0x20`、
        /// `"`、`\` 这三类判断按字节做是精确的，且不需要解码。
        private static func needsEscaping(_ string: String) -> Bool {
            for byte in string.utf8 where byte < 0x20 || byte == 0x22 || byte == 0x5c {
                return true
            }
            return false
        }
    }
}
