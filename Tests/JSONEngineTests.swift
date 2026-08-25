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
