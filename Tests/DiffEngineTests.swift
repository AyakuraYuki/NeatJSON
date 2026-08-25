import XCTest

@testable import NeatJSON

final class DiffEngineTests: XCTestCase {
    func testIdentical() {
        let ops = DiffEngine.lineDiff(["a", "b"], ["a", "b"])
        XCTAssertEqual(ops.count, 2)
        guard case .equal(let o, let n) = ops[0] else {
            return XCTFail("expected equal")
        }
        XCTAssertEqual(o, 0)
        XCTAssertEqual(n, 0)
    }

    func testPureInsert() {
        let ops = DiffEngine.lineDiff(["a"], ["a", "b", "c"])
        let inserts = ops.filter {
            if case .insert = $0 {
                return true
            }
            return false
        }
        XCTAssertEqual(inserts.count, 2)
    }

    func testPureDelete() {
        let ops = DiffEngine.lineDiff(["a", "b", "c"], ["a"])
        let deletes = ops.filter {
            if case .delete = $0 {
                return true
            }
            return false
        }
        XCTAssertEqual(deletes.count, 2)
    }

    func testModify() {
        let ops = DiffEngine.lineDiff(["x: 1"], ["x: 2"])
        XCTAssertEqual(
            ops.filter {
                if case .delete = $0 {
                    return true
                } else {
                    return false
                }
            }.count, 1
        )
        XCTAssertEqual(
            ops.filter {
                if case .insert = $0 {
                    return true
                } else {
                    return false
                }
            }.count, 1
        )
    }

    func testBuildRowsModifiedPairing() {
        let old = ["{", "  \"b\": 1,", "  \"a\": 2", "}"]
        let new = ["{", "  \"a\": 2,", "  \"b\": 1", "}"]
        let ops = DiffEngine.lineDiff(old, new)
        let rows = DiffEngine.rows(from: ops).rows
        // 至少存在一个 modified 行（"b":1 与 "a":2 键值交换）
        let modifiedCount = rows.filter {
            if case .modified = $0.kind {
                return true
            }
            return false
        }.count
        XCTAssertGreaterThanOrEqual(modifiedCount, 1)
    }

    func testInlineDiff() {
        let result = DiffEngine.inlineDiff(
            oldLine: "\"b\": 1,",
            newLine: "\"a\": 2,"
        )
        // 键与值都变了
        XCTAssertFalse(result.oldRanges.isEmpty)
        XCTAssertFalse(result.newRanges.isEmpty)
    }

    func testInlineDiffSharedPrefix() {
        let result = DiffEngine.inlineDiff(
            oldLine: "\"key\": 100",
            newLine: "\"key\": 200"
        )
        // 前缀 "key": 相同，只有数字部分应高亮
        let tokens = DiffEngine.tokenizeForInline("\"key\": 100")
        XCTAssertGreaterThanOrEqual(tokens.count, 5)
        // 高亮区间不应覆盖第一个词元（"key"）
        for range in result.oldRanges {
            XCTAssertGreaterThan(range.lowerBound, 0, "首词元（key）不应被高亮")
        }
    }

    func testTokenize() {
        XCTAssertEqual(
            DiffEngine.tokenizeForInline("\"a\": 12"),
            ["\"", "a", "\"", ":", " ", "12"]
        )
    }

    func testEmptyInputs() {
        XCTAssertEqual(DiffEngine.lineDiff([], []), [])
        let ops = DiffEngine.lineDiff([], ["a"])
        XCTAssertEqual(ops.count, 1)
    }

    func testLargeShuffled() {
        // 前后缀压缩 + Myers 正确性冒烟：乱序后 diff 行数守恒
        let old = (0 ..< 200).map { "line \($0)" }
        let new = old.shuffled()
        let ops = DiffEngine.lineDiff(old, new)
        let equals = ops.filter {
            if case .equal = $0 {
                return true
            } else {
                return false
            }
        }.count
        let deletes = ops.filter {
            if case .delete = $0 {
                return true
            } else {
                return false
            }
        }.count
        let inserts = ops.filter {
            if case .insert = $0 {
                return true
            } else {
                return false
            }
        }.count
        // 守恒：old 的每一行恰好出现一次（equal 或 delete），new 同理
        XCTAssertEqual(equals + deletes, old.count)
        XCTAssertEqual(equals + inserts, new.count)
    }

    // MARK: - 线性空间重写后的回归

    /// 与暴力 LCS 对拍：diff 必须给出最优编辑脚本，且 ops 序列自洽。
    func testOptimalAgainstBruteForceLCS() {
        var generator = SystemRandomNumberGenerator()
        let alphabet = ["a", "b", "c", "d"]
        for _ in 0 ..< 600 {
            let old = (0 ..< Int.random(in: 0 ... 9, using: &generator))
                .map { _ in alphabet.randomElement(using: &generator)! }
            let new = (0 ..< Int.random(in: 0 ... 9, using: &generator))
                .map { _ in alphabet.randomElement(using: &generator)! }
            let ops = DiffEngine.lineDiff(old, new, limits: .exact)
            let equals = assertConsistent(ops, old: old, new: new)
            XCTAssertEqual(
                equals,
                Self.longestCommonSubsequenceLength(old, new),
                "非最优：\(old) -> \(new)"
            )
        }
    }

    /// 2 万行乱序。旧实现在这里要为每一轮编辑距离保存一份 V 快照
    /// （约 1.6 GB）而 OOM；现在应当很快完成且内存是 O(n+m)。
    func testHugeShuffledDiffCompletes() {
        let old = (0 ..< 20_000).map { "  \"key\($0)\": \($0)," }
        let new = old.shuffled()
        let ops = DiffEngine.lineDiff(old, new)
        _ = assertConsistent(ops, old: old, new: new)
    }

    /// 最坏形态：压缩成一行 vs 展开成两万行。
    func testSingleLineAgainstManyLines() {
        let new = (0 ..< 20_000).map { "  \"key\($0)\": \($0)," }
        let ops = DiffEngine.lineDiff(["{\"key0\":0}"], new)
        _ = assertConsistent(ops, old: ["{\"key0\":0}"], new: new)
    }

    /// 词元数超预算时退化为整段粗粒度高亮，而不是在单行上跑大规模 diff。
    func testInlineDiffFallsBackToCoarseRanges() {
        let old = (0 ..< 2_500).map { "a\($0)" }.joined(separator: ",")
        let new = (0 ..< 2_500).map { "b\($0)" }.joined(separator: ",")
        let result = DiffEngine.inlineDiff(oldLine: old, newLine: new)
        XCTAssertTrue(result.isCoarse)
        XCTAssertEqual(result.oldRanges.count, 1)
        XCTAssertEqual(result.newRanges.count, 1)
        XCTAssertLessThanOrEqual(result.oldRanges[0].upperBound, old.count)
        XCTAssertLessThanOrEqual(result.newRanges[0].upperBound, new.count)
    }

    /// 行内区间是字符偏移，可直接用于切片。
    func testInlineRangesAreCharacterOffsets() {
        let old = "\"key\": 100"
        let new = "\"key\": 200"
        let result = DiffEngine.inlineDiff(oldLine: old, newLine: new)
        let chars = Array(old)
        let highlighted = result.oldRanges.map { String(chars[$0]) }.joined()
        XCTAssertEqual(highlighted, "100")
    }

    /// 取消标志生效后应立即返回，不把大输入算到底。
    func testCancellationStopsWork() {
        let old = (0 ..< 20_000).map { "line \($0)" }
        let new = old.shuffled()
        let ops = DiffEngine.lineDiff(old, new, limits: .exact, isCancelled: { true })
        XCTAssertTrue(ops.isEmpty)
    }

    /// 长未变更段被折叠成占位行，渲染行数大幅下降。
    func testCollapsesLongUnchangedRuns() {
        let old = (0 ..< 100).map { "line \($0)" }
        var new = old
        new[50] = "line 50 changed"
        let result = DiffEngine.diff(old: old, new: new, collapseContext: 3)
        XCTAssertLessThan(result.rows.count, 20)
        XCTAssertEqual(result.insertions, 1)
        XCTAssertEqual(result.deletions, 1)
        let collapsed = result.rows.filter {
            if case .collapsed = $0.kind {
                return true
            }
            return false
        }
        XCTAssertEqual(collapsed.count, 2, "变更点前后各应有一个折叠块")
        // 折叠块覆盖的行数 + 显示出来的行数 = 原始行数
        var covered = 0
        for row in result.rows {
            switch row.kind {
            case .collapsed(let oldRange, _): covered += oldRange.count
            case .equal, .delete, .modified: covered += 1
            case .insert: break
            }
        }
        XCTAssertEqual(covered, old.count)
    }

    /// 不传 collapseContext 时不折叠。
    func testNoCollapseByDefault() {
        let old = (0 ..< 50).map { "line \($0)" }
        let rows = DiffEngine.rows(from: DiffEngine.lineDiff(old, old)).rows
        XCTAssertEqual(rows.count, 50)
    }

    // MARK: - 辅助

    /// 校验 ops 序列自洽（顺序、覆盖、守恒），返回 equal 的数量。
    @discardableResult
    private func assertConsistent(
        _ ops: [DiffEngine.Op],
        old: [String],
        new: [String]
    ) -> Int {
        var expectedOld = 0
        var expectedNew = 0
        var equals = 0
        for op in ops {
            switch op {
            case .equal(let o, let n):
                XCTAssertEqual(o, expectedOld)
                XCTAssertEqual(n, expectedNew)
                XCTAssertEqual(old[o], new[n], "equal 指向的行内容不同")
                expectedOld += 1
                expectedNew += 1
                equals += 1
            case .delete(let o):
                XCTAssertEqual(o, expectedOld)
                expectedOld += 1
            case .insert(let n):
                XCTAssertEqual(n, expectedNew)
                expectedNew += 1
            }
        }
        XCTAssertEqual(expectedOld, old.count, "未覆盖全部旧行")
        XCTAssertEqual(expectedNew, new.count, "未覆盖全部新行")
        return equals
    }

    private static func longestCommonSubsequenceLength(
        _ a: [String],
        _ b: [String]
    ) -> Int {
        var table = [[Int]](
            repeating: [Int](repeating: 0, count: b.count + 1),
            count: a.count + 1
        )
        for i in stride(from: 1, through: a.count, by: 1) {
            for j in stride(from: 1, through: b.count, by: 1) {
                table[i][j] = a[i - 1] == b[j - 1]
                    ? table[i - 1][j - 1] + 1
                    : max(table[i - 1][j], table[i][j - 1])
            }
        }
        return table[a.count][b.count]
    }
}
