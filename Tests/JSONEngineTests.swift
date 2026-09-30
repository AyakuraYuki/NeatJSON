import XCTest

@testable import NeatJSON

final class JSONEngineTests: XCTestCase {
    // MARK: - 基础解析与序列化

    func testSimpleObject() throws {
        let value = try JSONParser.parse(#"{"b": 1, "a": 2}"#)
        let output = JSONSerializer.serialize(value)
        XCTAssertEqual(
            output,
            """
            {
              "a": 2,
              "b": 1
            }

            """
        )
    }

    func testNestedSorting() throws {
        let input = """
        {"z": {"b": 2, "a": 1}, "a": [3, 1, {"y": true, "x": false}]}
        """
        let output = try JSONSerializer.serialize(JSONParser.parse(input))
        XCTAssertEqual(
            output,
            """
            {
              "a": [
                3,
                1,
                {
                  "x": false,
                  "y": true
                }
              ],
              "z": {
                "a": 1,
                "b": 2
              }
            }

            """
        )
    }

    func testArrayOrderPreserved() throws {
        // 数组元素顺序不能变，但其中的对象键要排序
        let output = try JSONSerializer.serialize(
            JSONParser.parse(#"[{"b":1,"a":2}, {"z":0,"y":9}]"#)
        )
        XCTAssertTrue(output.contains("\"a\": 2"))
        XCTAssertTrue(output.contains("\"b\": 1"))
        XCTAssertTrue(output.contains("\"y\": 9"))
        XCTAssertTrue(output.contains("\"z\": 0"))
        // 数组内对象顺序不变：a/b 块在 y/z 块之前
        let aRange = output.range(of: "\"a\": 2")
        let yRange = output.range(of: "\"y\": 9")
        XCTAssertNotNil(aRange)
        XCTAssertNotNil(yRange)
        XCTAssertLessThan(aRange!.lowerBound, yRange!.lowerBound)
    }

    // MARK: - 数字保真

    func testNumberFidelity() throws {
        let cases = [
            "1.0": "1.0",
            "123456789012345678901234567890": "123456789012345678901234567890",
            "1e999": "1e999",
            "-0.5e-3": "-0.5e-3",
            "0": "0",
            "-12": "-12",
        ]
        for (input, expected) in cases {
            let output = try JSONSerializer.serialize(
                JSONParser.parse(input),
                trailingNewline: false
            )
            XCTAssertEqual(output, expected, "input: \(input)")
        }
    }

    func testInvalidNumbers() {
        XCTAssertThrowsError(try JSONParser.parse("01"))
        XCTAssertThrowsError(try JSONParser.parse("1."))
        XCTAssertThrowsError(try JSONParser.parse("1e"))
        XCTAssertThrowsError(try JSONParser.parse("-"))
        XCTAssertThrowsError(try JSONParser.parse("+1"))
    }

    // MARK: - 转义

    func testStringEscapes() throws {
        // 字面 emoji（非转义）原样解析
        let parsed = try JSONParser.parse(#""😀""#)
        XCTAssertEqual(parsed, .string("😀"))

        // 序列化时非 ASCII 原样输出、控制字符转义
        let serialized = JSONSerializer.serialize(
            .string("a\nb\u{01}中文😀"),
            trailingNewline: false
        )
        XCTAssertEqual(serialized, "\"a\\nb\\u0001中文😀\"")
    }

    /// \uXXXX 高+低代理对组合为单个非 BMP 字符。
    ///
    /// 历史 bug：parseUnicodeEscape 直接用 Unicode.Scalar(value) 构造，
    /// 而代理区码点（D800–DFFF）不是合法标量（init 返回 nil），导致
    /// 合法的代理对被误报成 invalid-unicode-escape，组合路径不可达。
    func testSurrogatePairEscape() throws {
        // 典型 emoji（必须以转义形式书写，才会走代理对组合路径）
        XCTAssertEqual(try JSONParser.parse(#""\ud83d\ude00""#), .string("😀"))
        // 边界：最小 / 最大代理对
        XCTAssertEqual(try JSONParser.parse(#""\ud800\udc00""#), .string("\u{10000}"))
        XCTAssertEqual(try JSONParser.parse(#""\udbff\udfff""#), .string("\u{10FFFF}"))
        // 与普通字符混排
        XCTAssertEqual(try JSONParser.parse(#""a\ud83d\ude00b""#), .string("a😀b"))
        // 连续两个代理对
        XCTAssertEqual(try JSONParser.parse(#""\ud83d\ude00\ud83d\ude00""#), .string("😀😀"))
    }

    func testLoneSurrogateRejected() {
        // 必须抛 lone-surrogate 而不是别的错误（比如 invalid-unicode-escape），
        // 否则即便抛错也说明走错了路径。
        let loneMessage = String(localized: "error.lone-surrogate")
        let cases = [
            "\"\\ud83d\"", // 孤立高位（后随闭引号）
            "\"\\ude00\"", // 孤立低位
            "\"\\ud83d\\ud83d\"", // 高+高
            "\"\\ud83da\"", // 高位后随普通字符
            "\"\\ud83d\\n\"", // 高位后随非 \u 转义
            "\"\\ud83d\\u0041\"", // 高位后随非代理 \u 转义
        ]
        for input in cases {
            XCTAssertThrowsError(try JSONParser.parse(input), "input: \(input)") { error in
                XCTAssertEqual(
                    (error as? JSONParseError)?.message,
                    loneMessage,
                    "input: \(input) 应报 lone-surrogate"
                )
            }
        }
    }

    func testControlCharacterRejected() {
        XCTAssertThrowsError(try JSONParser.parse("\"a\u{01}b\""))
    }

    // MARK: - 错误定位

    func testErrorLineColumn() {
        let input = "{\n  \"a\": 1,\n  \"b\"\n}"
        XCTAssertThrowsError(try JSONParser.parse(input)) { error in
            let parseError = error as? JSONParseError
            XCTAssertNotNil(parseError)
            XCTAssertEqual(parseError?.line, 3)
            XCTAssertEqual(parseError?.column, 6)
        }
    }

    /// advance 型错误（出错字符刚被消费）：位置应指向出错字符本身——
    /// 普通字符不偏列；出错字符是 \n 时指向上一行末尾，而不是下一行开头。
    func testErrorPositionAfterAdvance() {
        let cases: [(input: String, line: Int, column: Int)] = [
            ("\"a\u{01}b\"", 1, 3), // 控制字符在第 3 列
            ("\"a\\qb\"", 1, 4), // 非法转义字符 q 在第 4 列
            ("trux", 1, 4), // 非法字面量，x 在第 4 列
            ("\"\\u12g4\"", 1, 6), // 非法十六进制位 g 在第 6 列
            ("\"a\nb\"", 1, 3), // 裸换行在第 1 行第 3 列
            ("\"a\\\nb\"", 1, 4), // 非法转义是换行符，在第 1 行第 4 列
        ]
        for (input, line, column) in cases {
            XCTAssertThrowsError(try JSONParser.parse(input), "input: \(input)") { error in
                let parseError = error as? JSONParseError
                XCTAssertEqual(parseError?.line, line, "input: \(input)")
                XCTAssertEqual(parseError?.column, column, "input: \(input)")
            }
        }
    }

    func testDepthLimit() {
        let depth = 600
        let input = String(repeating: "[", count: depth) + String(repeating: "]", count: depth)
        XCTAssertThrowsError(try JSONParser.parse(input)) { error in
            XCTAssertEqual((error as? JSONParseError)?.message.isEmpty, false)
        }
    }

    /// 钉住深度上限的边界。
    ///
    /// 空的最内层 `[]` 不会再往下调 `parseValue`，所以 k 层括号实际只递归到
    /// depth k-1：k = maximumDepth + 1 仍应通过，再多一层才触发上限。
    func testDepthLimitBoundary() throws {
        func nested(_ k: Int) -> String {
            String(repeating: "[", count: k) + String(repeating: "]", count: k)
        }
        let limit = JSONParser.maximumDepth
        XCTAssertNoThrow(
            try JSONParser.parse(nested(limit + 1)),
            "恰好到上限应当通过"
        )
        XCTAssertThrowsError(try JSONParser.parse(nested(limit + 2))) { error in
            let message = (error as? JSONParseError)?.message
            // 其余解析错误的 message 都是不含数字的静态串（行列号是在
            // localizedDescription 里才拼上的），所以「带上限数字」足以区分。
            XCTAssertEqual(
                message?.contains("\(limit)"),
                true,
                "应当是深度超限错误（消息里带上限），而不是别的解析错误"
            )
        }
    }

    func testTrailingGarbageRejected() {
        XCTAssertThrowsError(try JSONParser.parse("{} extra"))
    }

    // MARK: - 本地化资源完整性

    /// 解析器能抛出的每个 key 都必须在两份 .strings 里有条目。
    ///
    /// `String(localized:defaultValue:)` 在 key 缺失时静默回退到 defaultValue，
    /// 既不报编译错也不报运行时错 —— 症状只是「中文界面里蹦出一句英文」。
    /// `error.too-deep` 就这样漏过一次，这个用例专门盯这类遗漏。
    func testParserErrorKeysAreLocalized() throws {
        let keys = [
            "error.at-position",
            "error.at-line",
            "error.empty-input",
            "error.trailing-characters",
            "error.unexpected-char",
            "error.expect-object-key",
            "error.expect-colon",
            "error.expect-value",
            "error.expect-comma-or-brace",
            "error.expect-comma-or-bracket",
            "error.unterminated-string",
            "error.invalid-escape",
            "error.invalid-unicode-escape",
            "error.lone-surrogate",
            "error.control-char",
            "error.invalid-literal",
            "error.invalid-number",
            "error.too-deep",
        ]
        for localization in ["en", "zh-Hans"] {
            let table = try Self.stringsTable(localization: localization)
            for key in keys {
                XCTAssertNotNil(table[key], "\(localization) 缺少 \(key)")
            }
        }
    }

    /// 两份表的 key 集合必须一致，否则某个语言会静默回退。
    /// 无需维护清单，新增 key 时自动生效。
    func testLocalizationTablesHaveIdenticalKeys() throws {
        let en = try Set(Self.stringsTable(localization: "en").keys)
        let zh = try Set(Self.stringsTable(localization: "zh-Hans").keys)
        XCTAssertEqual(en.symmetricDifference(zh), [], "en 与 zh-Hans 的 key 不一致")
    }

    /// 带 `Int` 插值的条目必须写 `%lld`，不能写 `%d`。
    ///
    /// `String.LocalizationValue` 把 `Int` 插值记录成 64 位，`.strings` 里写
    /// `%d` 会在取参时截成 32 位（实测 5_000_000_000 渲染成 705_032_704）。
    /// 行号列号平时远小于 2^31，所以写错了也看不出来。
    ///
    /// 这里静态审计两份表，而不是去看渲染结果：渲染只会命中当前 locale 对应
    /// 的那一份，另一份写错了照样漏过去。本项目所有整数插值都是 `Int`，
    /// 因此「不出现 %d」就是完整的判据。
    func testNoTruncatingIntegerFormatSpecifiers() throws {
        for localization in ["en", "zh-Hans"] {
            for (key, value) in try Self.stringsTable(localization: localization) {
                // `%lld` 里的 d 不构成 `%d` 子串，直接找字面量即可。
                XCTAssertFalse(
                    value.contains("%d") || value.contains("%i"),
                    "\(localization) 的 \(key) 用了会截断的 %d/%i：\(value)"
                )
            }
        }
    }

    /// 端到端兜底：当前 locale 下渲染行号不应被截断。
    func testErrorPositionRendersFullWidthLineNumber() {
        let line = 5_000_000_000
        let described = JSONParseError(message: "x", line: line, column: 7)
            .localizedDescription
        // 渲染结果带千位分隔符（分隔符随 locale 变），剔掉非数字再比对，
        // 避免把断言绑死在某个 locale 的分组习惯上。
        let digits = described
            .components(separatedBy: CharacterSet.decimalDigits.inverted)
            .joined()
        XCTAssertTrue(
            digits.contains("\(line)"),
            "行号被截断（%d 而非 %lld）：\(described)"
        )
    }

    /// 从 app bundle 里读某个语言的 Localizable.strings。
    ///
    /// 用 `Bundle.main` 而非测试 bundle：单元测试宿主是 NeatJSON.app，
    /// 而 `String(localized:)` 默认查的也正是 `Bundle.main`，两者一致。
    private static func stringsTable(localization: String) throws -> [String: String] {
        let url = try XCTUnwrap(
            Bundle.main.url(
                forResource: "Localizable",
                withExtension: "strings",
                subdirectory: nil,
                localization: localization
            ),
            "找不到 \(localization) 的 Localizable.strings"
        )
        return try XCTUnwrap(
            NSDictionary(contentsOf: url) as? [String: String],
            "\(localization) 的 Localizable.strings 解析失败"
        )
    }

    func testEmptyObjectAndArray() throws {
        let output = try JSONSerializer.serialize(
            JSONParser.parse(#"{"a": [], "b": {}}"#),
            trailingNewline: false
        )
        XCTAssertEqual(output, "{\n  \"a\": [],\n  \"b\": {}\n}")
    }

    // MARK: - 缩进

    func testIndentStyles() throws {
        let value = try JSONParser.parse(#"{"a": [1]}"#)
        XCTAssertEqual(
            JSONSerializer.serialize(value, indent: .spaces4, trailingNewline: false),
            "{\n    \"a\": [\n        1\n    ]\n}"
        )
        XCTAssertEqual(
            JSONSerializer.serialize(value, indent: .tab, trailingNewline: false),
            "{\n\t\"a\": [\n\t\t1\n\t]\n}"
        )
    }

    func testSortKeyOrder() throws {
        // 字典序：大写字母在小写之前（Unicode 码点序）
        let output = try JSONSerializer.serialize(
            JSONParser.parse(#"{"b": 1, "A": 2, "a": 3}"#),
            trailingNewline: false
        )
        let aIdx = output.range(of: "\"A\"")!.lowerBound
        let aLowerIdx = output.range(of: "\"a\"")!.lowerBound
        let bIdx = output.range(of: "\"b\"")!.lowerBound
        XCTAssertLessThan(aIdx, aLowerIdx)
        XCTAssertLessThan(aLowerIdx, bIdx)
    }

    // MARK: - key 排序规则

    /// alphabetic：字母数字忽略大小写优先，分隔符整组殿后。
    func testAlphabeticKeyOrder() throws {
        let output = try JSONSerializer.serialize(
            JSONParser.parse(#"{"B":1,"a":2,"A":3,"b":4,"0":5,"9":6,"z":7,"Z":8}"#),
            keyOrder: .alphabetic,
            trailingNewline: false
        )
        let ordered = try keyNames(in: output)
        // 字母数字同组按码点：数字（0x30–0x39）先于字母（0x61+）。
        // 大小写不参与主序，同字母的两种写法权重相等，由兜底规则定序（大写在前）。
        XCTAssertEqual(ordered, ["0", "9", "A", "a", "B", "b", "Z", "z"])
    }

    /// 大小写不参与主序：同字母的两种写法权重相等，但必须有确定先后
    /// （否则严格弱序出等价类，排序结果取决于输入顺序）。
    ///
    /// 兜底规则是原始字节比较，即大写在前。
    func testAlphabeticIgnoresCaseButStaysTotal() throws {
        let value = try JSONParser.parse(#"{"ayrt02":1,"AYRT02":2,"Ayrt02":3}"#)
        let names = try keyNames(
            in: JSONSerializer.serialize(value, keyOrder: .alphabetic, trailingNewline: false)
        )
        XCTAssertEqual(names.count, 3, "三个 key 一个都不能丢")
        XCTAssertEqual(names, ["AYRT02", "Ayrt02", "ayrt02"], "大写在前")

        // 严格弱序：任意两个不同的 key，恰有一个方向成立。
        let order = JSONKeyOrder.alphabetic
        for lhs in names {
            for rhs in names where lhs != rhs {
                XCTAssertNotEqual(
                    order.areInIncreasingOrder(lhs, rhs),
                    order.areInIncreasingOrder(rhs, lhs),
                    "\(lhs) 与 \(rhs) 的先后不唯一"
                )
            }
        }
    }

    /// 分隔符整组殿后：`Customer` 排在 `C_CSDN` 之前（第三位 u 对 _）。
    func testAlphabeticPutsSeparatorsAfterAlphanumerics() throws {
        let output = try JSONSerializer.serialize(
            JSONParser.parse(#"{"C_CSDN":1,"Customer":2,"caih_dev":3,"CAIH":4}"#),
            keyOrder: .alphabetic,
            trailingNewline: false
        )
        XCTAssertEqual(try keyNames(in: output), ["CAIH", "caih_dev", "Customer", "C_CSDN"])
    }

    /// 非 ASCII 一律落在最后一组，组内按码点序。
    func testAlphabeticKeyOrderPutsNonASCIILast() throws {
        let output = try JSONSerializer.serialize(
            JSONParser.parse(#"{"中":1,"9":2,"é":3,"z":4,"!":5}"#),
            keyOrder: .alphabetic,
            trailingNewline: false
        )
        // 数字（组 0）与字母 z 同组，0x30 < 0x7A；! 是其他 ASCII（组 1）殿后；
        // 非 ASCII（组 2）最后，组内码点序：é U+00E9 < 中 U+4E2D。
        XCTAssertEqual(try keyNames(in: output), ["9", "z", "!", "é", "中"])
    }

    /// 前缀较短的 key 排在前面，空 key 排最前。
    func testAlphabeticKeyOrderPrefixes() throws {
        let output = try JSONSerializer.serialize(
            JSONParser.parse(#"{"ab":1,"":2,"a":3,"aB":4,"Aa":5}"#),
            keyOrder: .alphabetic,
            trailingNewline: false
        )
        // 逐位看：空串最先；"a" 是其余全部的前缀；剩下的第一位都是 a，
        // 第二位 a < b，故 Aa 一族先于 aB/ab。aB 与 ab 权重全等，
        // 由兜底规则定序：B(0x42) < b(0x62)，所以 aB 在前。
        XCTAssertEqual(try keyNames(in: output), ["", "a", "Aa", "aB", "ab"])
    }

    /// alphabetic 与 codepoint 覆盖同一份 key 集合，只有顺序不同。
    func testBothKeyOrdersCoverSameKeys() throws {
        let value = try JSONParser.parse(#"{"b":1,"A":2,"a":3,"0":4,"中":5,"Z":6}"#)
        for order in JSONKeyOrder.allCases {
            let names = try keyNames(
                in: JSONSerializer.serialize(value, keyOrder: order, trailingNewline: false)
            )
            XCTAssertEqual(names.sorted(), ["0", "A", "Z", "a", "b", "中"], "\(order) 丢了 key")
        }
    }

    /// codepoint 仍是旧行为：大写在小写之前；不传参数时也用它。
    func testCodepointKeyOrderIsDefault() throws {
        let value = try JSONParser.parse(#"{"b":1,"a":2,"A":3}"#)
        XCTAssertEqual(
            try keyNames(in: JSONSerializer.serialize(value, trailingNewline: false)),
            ["A", "a", "b"],
            "默认参数必须保持码点序"
        )
        XCTAssertEqual(
            try keyNames(
                in: JSONSerializer.serialize(
                    value, keyOrder: .codepoint, trailingNewline: false
                )
            ),
            ["A", "a", "b"]
        )
    }

    /// 嵌套与数组内的对象同样按规则递归排序。
    func testAlphabeticKeyOrderAppliesRecursively() throws {
        let output = try JSONSerializer.serialize(
            JSONParser.parse(#"{"z":[{"b":1,"A":2}],"a":{"B":1,"c":2}}"#),
            keyOrder: .alphabetic,
            trailingNewline: false
        )
        XCTAssertEqual(
            output,
            """
            {
              "a": {
                "B": 1,
                "c": 2
              },
              "z": [
                {
                  "A": 2,
                  "b": 1
                }
              ]
            }
            """
        )
    }

    /// 参照实现 `sorted(order:)` 必须与序列化器逐字节一致。
    func testSortedReferenceMatchesSerializer() throws {
        let input = #"{"Z":1,"a":[{"B_":2,"0x":3}],"中":{"é":4,"A":5}}"#
        let value = try JSONParser.parse(input)
        for order in JSONKeyOrder.allCases {
            XCTAssertEqual(
                JSONSerializer.serialize(value.sorted(order: order), keyOrder: order),
                JSONSerializer.serialize(value, keyOrder: order),
                "\(order) 下参照实现与序列化器不一致"
            )
        }
    }

    /// 与「逐标量按权重比较」的朴素实现对拍，覆盖大量 key 组合。
    func testAlphabeticOrderMatchesNaiveScalarComparator() {
        // 独立于实现重写一遍规则：组 0 = 字母（折叠大小写）与数字、组 1 = 其他
        // ASCII、组 2 = 非 ASCII，组内按值；权重全等时退回原始字符串比较。
        func weight(_ scalar: Unicode.Scalar) -> UInt32 {
            if scalar.value < 0x80 {
                if (0x41 ... 0x5A).contains(scalar.value) { return UInt32(scalar.value | 0x20) }
                if (0x61 ... 0x7A).contains(scalar.value) { return UInt32(scalar.value) }
                if (0x30 ... 0x39).contains(scalar.value) { return UInt32(scalar.value) }
                return 0x1_0000 | scalar.value
            }
            return 0x2_0000 | scalar.value
        }
        func naive(_ lhs: String, _ rhs: String) -> Bool {
            let left = lhs.unicodeScalars.map(weight)
            let right = rhs.unicodeScalars.map(weight)
            for (a, b) in zip(left, right) where a != b {
                return a < b
            }
            if left.count != right.count { return left.count < right.count }
            return lhs < rhs // 权重全等：仅大小写不同，退回原始比较
        }

        let alphabet: [Unicode.Scalar] = [
            "a", "z", "A", "Z", "0", "9", "_", " ", "!", "~", "é", "中", "α", "Ж", "🙂",
        ]
        var pool: [String] = [""]
        for length in 1 ... 3 {
            pool += alphabet.map(String.init).flatMap { scalar in
                length == 1 ? [scalar] : alphabet.map { String($0) + scalar }
            }
        }
        pool = Array(pool.prefix(2000))

        for lhs in pool {
            for rhs in pool {
                XCTAssertEqual(
                    JSONKeyOrder.alphabetic.areInIncreasingOrder(lhs, rhs),
                    naive(lhs, rhs),
                    "比较器与朴素实现在 \(lhs.debugDescription) / \(rhs.debugDescription) 上分叉"
                )
            }
        }
    }

    /// 排序规则对输出长度与内容没有影响，只有顺序变化。
    func testKeyOrderDoesNotChangeContent() throws {
        let value = try JSONParser.parse(#"{"b":[1,{"q":0,"p":1}],"a":"x","中":"y"}"#)

        func normalized(_ text: String) -> [String] {
            text.split(separator: "\n")
                .map { line -> String in
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    return trimmed.hasSuffix(",") ? String(trimmed.dropLast()) : trimmed
                }
                .sorted()
        }

        let codepoint = normalized(JSONSerializer.serialize(value, keyOrder: .codepoint))
        let alphabetic = normalized(JSONSerializer.serialize(value, keyOrder: .alphabetic))
        XCTAssertEqual(codepoint, alphabetic)
    }

/// 真实业务数据的整串 key 顺序回归。
///
/// 输入故意逆序给出，期望顺序写死——这条用例同时验证「字母数字优先 +
/// 忽略大小写 + 分隔符殿后」三条规则联合作用的结果，是这套排序规则的
/// 端到端契约。任何一条规则的改动都会在这里立刻暴露。
func testRealWorldKeyOrderRegression() throws {
    let input = #"""
{
    "通信分组": 0,
    "算法备案": 0,
    "ZT02/Claude": 0,
    "ZSYY01/GLM": 0,
    "ZF02/Gemini": 0,
    "ZF01": 0,
    "YQ02/GPT": 0,
    "YQ02/Gemini": 0,
    "YQ02/Claude": 0,
    "YQ01/Seedance": 0,
    "XLX01/Kimi": 0,
    "XLX01/GLM53": 0,
    "XLX01/GLM": 0,
    "WY01/kimi": 0,
    "WY01/glm": 0,
    "WW01/GLM": 0,
    "WW01/Free": 0,
    "WS02/Gpt": 0,
    "WS02/Gemini": 0,
    "WS02/Claude": 0,
    "WS01/Qwen": 0,
    "WS01/Kimi": 0,
    "WS01/Glm/DeepSeek/Qwen": 0,
    "WS01/Glm": 0,
    "WS01/Embedding": 0,
    "WS01/Anthropic/DeepSeek": 0,
    "vip": 0,
    "VE01/Seedream": 0,
    "VE01/Seed": 0,
    "VE01/Kimi": 0,
    "VE01/DS": 0,
    "TX01/TokenHub/Qwen": 0,
    "TX01/TokenHub/MiniMax01": 0,
    "TX01/TokenHub/Kimi": 0,
    "TX01/TokenHub/Hy": 0,
    "TX01/TokenHub/Glm": 0,
    "TX01/TokenHub/Deepseek02": 0,
    "TX01/TokenHub/Deepseek01": 0,
    "TH01/Kimi": 0,
    "t2": 0,
    "t1": 0,
    "SZZW01": 0,
    "SZTY02/gpt": 0,
    "SZTY02/gemini": 0,
    "svip": 0,
    "ST01/Zhipu": 0,
    "SJS01/Seedance02": 0,
    "SJS01/Seedance01": 0,
    "shanghai_1": 0,
    "QDBS02/Meta": 0,
    "QDBS02/GPT": 0,
    "QDBS02/Gork": 0,
    "QDBS02/Gemini": 0,
    "QDBS02/Bench": 0,
    "QDBS01/Qwen": 0,
    "Primalai01/Kimi/09s": 0,
    "Primalai01/Kimi/09": 0,
    "Primalai01/Kimi": 0,
    "OXO01/Kimi": 0,
    "OXO01/GLM": 0,
    "OPENAI02/gpt-Image": 0,
    "nexusvoid01/kimi": 0,
    "neutoken01/kimi": 0,
    "NA02/xAI": 0,
    "NA02/Vertex/sp": 0,
    "NA02/OpenAI": 0,
    "NA02/Azure/sp": 0,
    "NA02/Azure": 0,
    "NA02/AWS/sp": 0,
    "NA02/AWS": 0,
    "NA02/AIStudio/sp2": 0,
    "NA01/VolcEngine": 0,
    "NA01/Open-Source-Group2": 0,
    "NA01/Open-Source-Group1": 0,
    "NA01/Aliyun": 0,
    "LSWH01/kimi": 0,
    "LSWH01/glm": 0,
    "KQ01/kimi": 0,
    "KQ01/glm": 0,
    "KQ01/deepseek": 0,
    "JIX01/Kimi": 0,
    "JIX01/GLM": 0,
    "JIX01/Bench": 0,
    "JD01/Kimi": 0,
    "JD01/GLM": 0,
    "invite_external_customer_global": 0,
    "HWZL01/Seedance25": 0,
    "HWZL01/Seedance": 0,
    "HWZL01/Qwen": 0,
    "GZLJ01/kimi": 0,
    "GZLJ01/GLM": 0,
    "GJ01/Qwen": 0,
    "draft": 0,
    "default": 0,
    "C_ZHIYUAN": 0,
    "C_YIDONG": 0,
    "C_NEXDATA": 0,
    "C_MIANBI": 0,
    "C_CSDN": 0,
    "Customer": 0,
    "CAIH_EPBIZ": 0,
    "caih_dev_yuliao": 0,
    "caih_dev_sale": 0,
    "CAIH_AI_SZ": 0,
    "burncloud/kimi": 0,
    "BJTH01/Seedance": 0,
    "BJTH01/Kimi": 0,
    "BJTH01/GLM": 0,
    "baseline-benchmark": 0,
    "B2YJ02/Seedance": 0,
    "B2YJ02/Gpt/Claude/Gemini": 0,
    "B2YJ01/Kimi": 0,
    "B1JZ02/ZK04": 0,
    "B1JZ01/Seedance": 0,
    "b1": 0,
    "AYRT02/Fable": 0,
    "AYRT02/Codex": 0,
    "AYRT02/Claude": 0,
    "auto": 0,
    "ALI01/Qwen": 0,
    "ALI01/Glm": 0,
    "ALI01": 0,
    "aiport02/gemini": 0
}
"""#

    let output = JSONSerializer.serialize(
        try JSONParser.parse(input),
        keyOrder: .alphabetic,
        trailingNewline: false
    )
    XCTAssertEqual(
        try keyNames(in: output).joined(separator: "\n"),
        "aiport02/gemini\nALI01\nALI01/Glm\nALI01/Qwen\nauto\nAYRT02/Claude\nAYRT02/Codex\nAYRT02/Fable\nb1\nB1JZ01/Seedance\nB1JZ02/ZK04\nB2YJ01/Kimi\nB2YJ02/Gpt/Claude/Gemini\nB2YJ02/Seedance\nbaseline-benchmark\nBJTH01/GLM\nBJTH01/Kimi\nBJTH01/Seedance\nburncloud/kimi\nCAIH_AI_SZ\ncaih_dev_sale\ncaih_dev_yuliao\nCAIH_EPBIZ\nCustomer\nC_CSDN\nC_MIANBI\nC_NEXDATA\nC_YIDONG\nC_ZHIYUAN\ndefault\ndraft\nGJ01/Qwen\nGZLJ01/GLM\nGZLJ01/kimi\nHWZL01/Qwen\nHWZL01/Seedance\nHWZL01/Seedance25\ninvite_external_customer_global\nJD01/GLM\nJD01/Kimi\nJIX01/Bench\nJIX01/GLM\nJIX01/Kimi\nKQ01/deepseek\nKQ01/glm\nKQ01/kimi\nLSWH01/glm\nLSWH01/kimi\nNA01/Aliyun\nNA01/Open-Source-Group1\nNA01/Open-Source-Group2\nNA01/VolcEngine\nNA02/AIStudio/sp2\nNA02/AWS\nNA02/AWS/sp\nNA02/Azure\nNA02/Azure/sp\nNA02/OpenAI\nNA02/Vertex/sp\nNA02/xAI\nneutoken01/kimi\nnexusvoid01/kimi\nOPENAI02/gpt-Image\nOXO01/GLM\nOXO01/Kimi\nPrimalai01/Kimi\nPrimalai01/Kimi/09\nPrimalai01/Kimi/09s\nQDBS01/Qwen\nQDBS02/Bench\nQDBS02/Gemini\nQDBS02/Gork\nQDBS02/GPT\nQDBS02/Meta\nshanghai_1\nSJS01/Seedance01\nSJS01/Seedance02\nST01/Zhipu\nsvip\nSZTY02/gemini\nSZTY02/gpt\nSZZW01\nt1\nt2\nTH01/Kimi\nTX01/TokenHub/Deepseek01\nTX01/TokenHub/Deepseek02\nTX01/TokenHub/Glm\nTX01/TokenHub/Hy\nTX01/TokenHub/Kimi\nTX01/TokenHub/MiniMax01\nTX01/TokenHub/Qwen\nVE01/DS\nVE01/Kimi\nVE01/Seed\nVE01/Seedream\nvip\nWS01/Anthropic/DeepSeek\nWS01/Embedding\nWS01/Glm\nWS01/Glm/DeepSeek/Qwen\nWS01/Kimi\nWS01/Qwen\nWS02/Claude\nWS02/Gemini\nWS02/Gpt\nWW01/Free\nWW01/GLM\nWY01/glm\nWY01/kimi\nXLX01/GLM\nXLX01/GLM53\nXLX01/Kimi\nYQ01/Seedance\nYQ02/Claude\nYQ02/Gemini\nYQ02/GPT\nZF01\nZF02/Gemini\nZSYY01/GLM\nZT02/Claude\n算法备案\n通信分组"
    )
}
    /// 从输出里按出现顺序取出顶层键名。
    ///
    /// 用 `JSONParser` 解析回值对象再读 key——手写扫描要去处理嵌套、
    /// 字符串内的 `{`/`:`/`,`，任何一处疏漏都会让测试假通过。
    /// 注意解析器保留插入序，这个顺序就是序列化器写出的顺序。
    private func keyNames(in output: String) throws -> [String] {
        guard case let .object(members) = try JSONParser.parse(output) else {
            XCTFail("输出不是对象")
            return []
        }
        return members.map(\.0)
    }

    // MARK: - 不排序序列化（diff 左侧规范化依赖它）

    func testSerializeKeepsOriginalOrderWhenNotSorting() throws {
        let value = try JSONParser.parse(#"{"b": 1, "a": 2, "c": {"z": 1, "y": 2}}"#)
        let output = JSONSerializer.serialize(
            value,
            sortKeys: false,
            trailingNewline: false
        )
        XCTAssertEqual(
            output,
            """
            {
              "b": 1,
              "a": 2,
              "c": {
                "z": 1,
                "y": 2
              }
            }
            """
        )
    }

    /// 排序与不排序只应改变顺序，不改变内容。
    ///
    /// 比较前要去掉行尾逗号：键换位会连带改变哪一行是「最后一个成员」，
    /// 因此逗号位置本来就会变（这也是 diff 里键移动会顺带显示逗号变化的原因）。
    func testSerializeSortedAndUnsortedAgreeOnContent() throws {
        let value = try JSONParser.parse(#"{"b": [1, {"q": 0, "p": 1}], "a": "x"}"#)

        func normalized(_ text: String) -> [String] {
            text.split(separator: "\n")
                .map { line -> String in
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    return trimmed.hasSuffix(",") ? String(trimmed.dropLast()) : trimmed
                }
                .sorted()
        }

        XCTAssertEqual(
            normalized(JSONSerializer.serialize(value, sortKeys: true)),
            normalized(JSONSerializer.serialize(value, sortKeys: false)),
            "两种顺序下的内容应一致，只有顺序不同"
        )
    }

    // MARK: - diff 语义：左侧按当前缩进规范化、保留原 key 顺序

    func testDiffDocumentIsIdenticalWhenInputAlreadySorted() {
        let input = """
        {
          "a": 1,
          "b": 2
        }
        """
        let output = JSONSerializer.serialize(try! JSONParser.parse(input))
        let document = DiffDocument.prepare(
            rawInput: input,
            formattedOutput: output,
            indent: .spaces2,
            limits: .balanced,
            isCancelled: { false }
        )
        XCTAssertTrue(document.isIdentical, "已排序的输入不应有差异")
    }

    /// 压缩成一行的输入也会先被展开，因此差异只反映键顺序而不是整体替换。
    func testDiffDocumentNormalizesMinifiedInput() {
        let input = #"{"b":1,"a":2}"#
        let output = JSONSerializer.serialize(try! JSONParser.parse(input))
        let document = DiffDocument.prepare(
            rawInput: input,
            formattedOutput: output,
            indent: .spaces2,
            limits: .balanced,
            isCancelled: { false }
        )
        // 左侧已展开成多行，而不是原始的单行
        XCTAssertGreaterThan(document.oldLines.count, 3)
        XCTAssertEqual(document.oldLines.count, document.newLines.count)
        XCTAssertFalse(document.isIdentical)
        // 只有两行 key 换了位置，大括号等结构行保持 equal
        XCTAssertLessThanOrEqual(document.insertions, 2)
        XCTAssertLessThanOrEqual(document.deletions, 2)
    }

    func testDiffDocumentRespectsIndentStyle() {
        let input = #"{"b":1,"a":2}"#
        let output = JSONSerializer.serialize(
            try! JSONParser.parse(input),
            indent: .tab
        )
        let document = DiffDocument.prepare(
            rawInput: input,
            formattedOutput: output,
            indent: .tab,
            limits: .balanced,
            isCancelled: { false }
        )
        XCTAssertTrue(
            document.oldLines.contains { $0.hasPrefix("\t") },
            "左侧应使用与输出相同的缩进"
        )
    }

    func testDiffDocumentFallsBackForInvalidInput() {
        let document = DiffDocument.prepare(
            rawInput: "{ not json",
            formattedOutput: "{}\n",
            indent: .spaces2,
            limits: .balanced,
            isCancelled: { false }
        )
        XCTAssertEqual(document.oldLines, ["{ not json"])
    }

    // MARK: - 输出末尾不留空行

    @MainActor
    func testFormattedOutputHasNoTrailingBlankLine() {
        let model = AppModel(inputText: #"{"b":1,"a":2}"#)
        XCTAssertFalse(model.outputText.hasSuffix("\n"), "输出末尾不应带换行")
        XCTAssertTrue(model.outputText.hasSuffix("}"))
        XCTAssertEqual(model.outputLineCount, 4) // { / "a" / "b" / }
    }

    /// 两侧是否带尾随换行属于书写习惯，不该在 diff 里显示成一行增删。
    func testDiffIgnoresTrailingNewlineDifference() {
        let input = #"{"a":1,"b":2}"#
        let value = try! JSONParser.parse(input)
        let withNewline = JSONSerializer.serialize(value, trailingNewline: true)
        let withoutNewline = JSONSerializer.serialize(value, trailingNewline: false)
        for output in [withNewline, withoutNewline] {
            let document = DiffDocument.prepare(
                rawInput: input,
                formattedOutput: output,
                indent: .spaces2,
                limits: .balanced,
                isCancelled: { false }
            )
            XCTAssertTrue(document.isIdentical)
            XCTAssertEqual(document.oldLines.count, document.newLines.count)
            XCTAssertEqual(document.oldLines.last, "}")
        }
    }

    /// 完全无差异时，正文是一整块可展开的「未变更」，而不是空列表。
    func testIdenticalDocumentIsOneCollapsedBlock() {
        let input = """
        {
          "a": 1,
          "b": 2,
          "c": 3,
          "d": 4,
          "e": 5,
          "f": 6,
          "g": 7,
          "h": 8,
          "i": 9,
          "j": 10
        }
        """
        let output = JSONSerializer.serialize(
            try! JSONParser.parse(input),
            trailingNewline: false
        )
        let document = DiffDocument.prepare(
            rawInput: input,
            formattedOutput: output,
            indent: .spaces2,
            limits: .balanced,
            isCancelled: { false }
        )
        XCTAssertTrue(document.isIdentical)
        XCTAssertEqual(document.rows.count, 1, "应折叠成一整块")
        guard case .collapsed(let oldRange, let newRange) = document.rows[0].kind else {
            return XCTFail("期望是 collapsed 行")
        }
        XCTAssertEqual(oldRange.count, document.oldLines.count, "折叠块应覆盖全部行")
        XCTAssertEqual(newRange.count, document.newLines.count)
    }
}
