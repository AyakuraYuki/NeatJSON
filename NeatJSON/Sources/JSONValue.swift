import Foundation

/// JSON 值模型。
///
/// `number` 保存原始字面量（lexeme）而非 `Double`：`1.0` 不被折成 `1`、
/// 大整数不溢出、`1e999` 不会变成 `infinity` 再序列化失败。
public enum JSONValue: Sendable {
    /// 对象。解析后保留插入序，序列化前统一按 key 排序。
    case object([(String, JSONValue)])
    /// 数组。元素顺序保持不变（其中的对象仍会被递归排序）。
    case array([JSONValue])
    case string(String)
    /// 原始数字字面量，如 `"1.0"`、`"-2e+10"`。
    case number(String)
    case bool(Bool)
    case null
}

extension JSONValue: Equatable {
    public static func == (lhs: JSONValue, rhs: JSONValue) -> Bool {
        switch (lhs, rhs) {
        case let (.object(a), .object(b)):
            a.count == b.count && zip(a, b).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
        case let (.array(a), .array(b)):
            a == b
        case let (.string(a), .string(b)):
            a == b
        case let (.number(a), .number(b)):
            a == b
        case let (.bool(a), .bool(b)):
            a == b
        case (.null, .null):
            true
        default:
            false
        }
    }
}

extension JSONValue: CustomStringConvertible {
    public var description: String {
        JSONSerializer.serialize(self, trailingNewline: false)
    }
}

public extension JSONValue {
    /// 按 key 字典序（Unicode 标量逐码点）升序排列所有对象，
    /// 递归应用于任意嵌套深度（含数组内的对象元素）。
    func sorted() -> JSONValue {
        switch self {
        case .object(let members):
            .object(
                members
                    .map { ($0.0, $0.1.sorted()) }
                    .sorted { $0.0 < $1.0 }
            )
        case .array(let items):
            .array(items.map { $0.sorted() })
        case .string, .number, .bool, .null:
            self
        }
    }
}
