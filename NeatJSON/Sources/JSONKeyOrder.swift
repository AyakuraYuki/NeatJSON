import Foundation

/// 对象 key 的排序规则。
///
/// - `alphabetic`：字母数字优先、忽略大小写，其余字符（`/` `_` `-` 等）整组
///   殿后，非 ASCII 再往后。
/// - `codepoint`：Swift 默认的 `String <`，近似码点序（`A` 在 `a` 前）。
///
/// 两者都递归作用于任意嵌套深度的对象，数组元素顺序不受影响。
public enum JSONKeyOrder: String, CaseIterable, Sendable, Identifiable {
    case alphabetic
    case codepoint

    public var id: String {
        rawValue
    }

    /// 设置面板里的短标签：直观给出两种序的差别。
    public var label: String {
        switch self {
        case .alphabetic: "a A b B …"
        case .codepoint: "A Z a z …"
        }
    }
}

public extension JSONKeyOrder {
    /// key 的严格弱序谓词，直接喂给 `sorted(by:)`。
    ///
    /// 比较规则（逐标量比权重，前缀短者在前）：
    ///
    /// | 字符 | 组 | 组内序号 |
    /// |---|---|---|
    /// | `a`–`z` / `A`–`Z` | 0 | 小写化后的码点（`a` 与 `A` 同权） |
    /// | `0`–`9` | 0 | 码点（`0x30`–`0x39` 本就在 `a`（`0x61`）之前） |
    /// | 其他 ASCII（`/` `_` `-` `!` …） | 1 | 码点 |
    /// | 非 ASCII | 2 | 码点 |
    ///
    /// 由此得到的性质：
    /// - **大小写不参与主序**：`AYRT02` 与 `ayrt02` 权重全等。`aiport02` →
    ///   `ALI01` → `auto` → `AYRT02` 这种「大小写交错却严格有序」的排布就是
    ///   这个性质的结果，按大小写分块的规则做不到。
    /// - **分隔符殿后**：`Customer` 排在 `C_CSDN` 之前，因为第三位 `u`（组 0）
    ///   先于 `_`（组 1）——所以 `C_CSDN`、`C_MIANBI` 一族整块落在 `Customer`
    ///   之后，不会插进 `CAIH_…` 中间。
    /// - 数字与字母同组按码点，于是 `… z Z 0 1 … 9`；非 ASCII 最后，
    ///   组内码点序：`9 < ! < é < 中 < α`。
    /// - 前缀短者在前（`"a" < "ab"`），完全相等返回 `false`。
    /// - 权重序列全等时（`"abc"` 对 `"ABC"`、`"ab"` 对 `"aB"`），退回原始字节
    ///   比较，即大写在前。这条兜底必须有，否则严格弱序退化出等价类，
    ///   `sorted(by:)` 的结果就取决于输入顺序。
    ///
    /// 实现走 UTF-8 逐字节，ASCII 全程不分配、不解码标量；
    /// 只有碰到 ≥ 0x80 的字节才解码（键里出现非 ASCII 时）。
    func areInIncreasingOrder(_ lhs: String, _ rhs: String) -> Bool {
        switch self {
        case .codepoint:
            // 默认序有标准库的 SIMD 化比较，不要去手写字节循环。
            return lhs < rhs
        case .alphabetic:
            return Self.alphabeticLess(lhs, rhs)
        }
    }

    private static func alphabeticLess(_ lhs: String, _ rhs: String) -> Bool {
        var left = lhs.utf8.makeIterator()
        var right = rhs.utf8.makeIterator()

        // 第一遍：按权重逐字符比较。绝大多数 key 在前几个字节就分出胜负。
        while true {
            switch (left.next(), right.next()) {
            case (nil, nil):
                // 权重序列完全相同、长度也相同：只可能是「仅大小写不同」，
                // 退回原始字节比较，即大写在前。
                return lhs < rhs
            case (nil, _):
                // 一侧走完。同样不能直接判短的小——须先确认权重是否真的打平：
                // 若已分出胜负，上面那个 `return` 早就返回了；能走到这里说明
                // 到 lhs 结束为止权重全部相等，短的在前。
                return true
            case (_, nil):
                return false
            case let (leftByte?, rightByte?):
                let leftWeight = weight(startingAt: leftByte, from: &left)
                let rightWeight = weight(startingAt: rightByte, from: &right)
                if leftWeight != rightWeight {
                    return leftWeight < rightWeight
                }
            }
        }
    }

    /// 读出一颗字符并给出权重。ASCII 走单字节快速路径（绝大多数 key 只走这条）；
    /// 非 ASCII 才解码标量。
    @inline(__always)
    private static func weight(
        startingAt first: UInt8,
        from iterator: inout String.UTF8View.Iterator
    ) -> UInt32 {
        if first < 0x80 {
            return asciiWeight(first)
        }
        guard let scalar = decodeScalar(startingAt: first, from: &iterator) else {
            // 串被截断（合法 UTF-8 下不会发生）：落到「其他」组，保证仍是全序。
            return (2 << 16) | UInt32(first)
        }
        // 非 ASCII 一律最后一组，组内按标量值——不做 Unicode 大小写折叠，
        // 「忽略大小写」只覆盖 ASCII，行为最好预测。
        return (2 << 16) | (scalar & 0xFFFF)
    }

    /// ASCII 字节的两级权重 `(组, 组内序号)`，打包成一个 `UInt32` 直接比较。
    ///
    /// 高 16 位 = 组（0 = 字母数字、1 = 其他 ASCII、2 = 非 ASCII），
    /// 低 16 位 = 组内序号：
    /// - 字母：折叠成小写码点（`A` 与 `a` 同为 `0x61`，大小写因此不参与主序）
    /// - 数字：码点本身
    /// - 其他：码点本身
    ///
    /// 字母与数字同组且都按码点，是因为 `'0'`–`'9'`（0x30–0x39）本就小于
    /// `'a'`（0x61）——不必为「数字排在字母后」另建一档。
    @inline(__always)
    private static func asciiWeight(_ byte: UInt8) -> UInt32 {
        switch byte {
        case 0x41 ... 0x5A: // A-Z -> 折叠成小写，与 a-z 同权
            UInt32(byte | 0x20)
        case 0x61 ... 0x7A: // a-z
            UInt32(byte)
        case 0x30 ... 0x39: // 0-9
            UInt32(byte)
        default:
            (1 << 16) | UInt32(byte)
        }
    }

    /// 从已读出的首字节起解码一颗 UTF-8 标量。
    ///
    /// 输入恒为合法 UTF-8（`String` 的不变量），因此续字节数由首字节前缀决定；
    /// 迭代器提前耗尽只可能是调用方给的字节数与串不符，此时返回 `nil`。
    private static func decodeScalar(
        startingAt first: UInt8,
        from iterator: inout String.UTF8View.Iterator
    ) -> UInt32? {
        if first < 0x80 {
            return UInt32(first)
        }
        let continuationCount = first >= 0xF0 ? 3 : (first >= 0xE0 ? 2 : 1)
        var value = UInt32(first & (0x7F >> continuationCount))
        for _ in 0 ..< continuationCount {
            guard let byte = iterator.next() else { return nil }
            value = (value << 6) | UInt32(byte & 0x3F)
        }
        return value
    }
}
