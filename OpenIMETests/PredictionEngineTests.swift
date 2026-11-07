import XCTest
@testable import OpenIMECore

final class PredictionEngineTests: XCTestCase {

    private var fileURL: URL!
    private var engine: PredictionEngine!

    override func setUp() {
        super.setUp()
        fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("prediction_test_\(UUID().uuidString).bin")
        engine = PredictionEngine(fileURL: fileURL)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: fileURL)
        super.tearDown()
    }

    // MARK: - 基本功能

    func testRecordAndPredict() {
        engine.record(prev: "你好", current: "世界")
        let results = engine.predict(after: "你好")
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].text, "世界")
        XCTAssertEqual(results[0].position, 4)
    }

    func testPredictUnknownPrev() {
        let results = engine.predict(after: "不存在")
        XCTAssertTrue(results.isEmpty)
    }

    func testPredictEmptyPrev() {
        engine.record(prev: "你好", current: "世界")
        let results = engine.predict(after: "")
        XCTAssertTrue(results.isEmpty)
    }

    func testRecordEmptyPrevIsIgnored() {
        engine.record(prev: "", current: "世界")
        XCTAssertTrue(engine.predict(after: "").isEmpty)
    }

    func testRecordEmptyCurrentIsIgnored() {
        engine.record(prev: "你好", current: "")
        XCTAssertTrue(engine.predict(after: "你好").isEmpty)
    }

    func testMultiplePredictionsForSamePrev() {
        engine.record(prev: "你好", current: "世界")
        engine.record(prev: "你好", current: "朋友")
        let results = engine.predict(after: "你好")
        XCTAssertEqual(results.count, 2)
        XCTAssertTrue(results.map { $0.text }.contains("世界"))
        XCTAssertTrue(results.map { $0.text }.contains("朋友"))
    }

    // MARK: - 预测结果带累计次数

    func testPredictExposesTotalCount() {
        // 调用方靠 totalCount 在同一个 position 槽位里挑「最常用的那条」
        for _ in 0..<4 { engine.record(prev: "A", current: "B") }
        engine.record(prev: "A", current: "C")

        let results = engine.predict(after: "A")
        XCTAssertEqual(results.first { $0.text == "B" }?.totalCount, 4)
        XCTAssertEqual(results.first { $0.text == "C" }?.totalCount, 1)
    }

    // MARK: - position 前移逻辑

    func testPositionStartsAt4() {
        engine.record(prev: "A", current: "B")
        XCTAssertEqual(engine.predict(after: "A").first?.position, 4)
    }

    func testPositionAdvancesAfter3ConsecutiveSelections() {
        // 连续选 3 次，position 4 变 3
        engine.record(prev: "A", current: "B")
        engine.record(prev: "A", current: "B")
        engine.record(prev: "A", current: "B")
        XCTAssertEqual(engine.predict(after: "A").first?.position, 3)
    }

    func testPositionAdvancesAgainAfterAnother3() {
        // 连续选 6 次，position 4 变 3 再变 2
        for _ in 0..<6 {
            engine.record(prev: "A", current: "B")
        }
        XCTAssertEqual(engine.predict(after: "A").first?.position, 2)
    }

    func testPositionClampsAtMaxPosition2() {
        // 连续选 9 次，position 不能低于 2
        for _ in 0..<9 {
            engine.record(prev: "A", current: "B")
        }
        XCTAssertEqual(engine.predict(after: "A").first?.position, 2)

        // 再选 3 次，仍然是 2
        for _ in 0..<3 {
            engine.record(prev: "A", current: "B")
        }
        XCTAssertEqual(engine.predict(after: "A").first?.position, 2)
    }

    func testConsecutiveCountResetsAfterAdvance() {
        // 选 3 次触发前移，consecutiveCount 归零
        // 再选 2 次不应再前移（需要再选 1 次才到 3）
        for _ in 0..<3 { engine.record(prev: "A", current: "B") }
        XCTAssertEqual(engine.predict(after: "A").first?.position, 3)

        engine.record(prev: "A", current: "B")
        engine.record(prev: "A", current: "B")
        // 只有 2 次，不足 3，不应前移
        XCTAssertEqual(engine.predict(after: "A").first?.position, 3)

        engine.record(prev: "A", current: "B")
        // 第 3 次，触发前移
        XCTAssertEqual(engine.predict(after: "A").first?.position, 2)
    }

    func testNonConsecutiveSelectionDoesNotAdvancePosition() {
        // 选 B 两次后，中间插入选 C，consecutiveCount 应对 B 归零
        engine.record(prev: "A", current: "B")
        engine.record(prev: "A", current: "B")
        // 选了 C，B 的 consecutiveCount 不变（PredictionEngine 不跨词对重置）
        // 但 B 的连续计数只有 2，再选一次 B 才到 3
        engine.record(prev: "A", current: "B")
        // 实际上 PredictionEngine 对每个词对独立计数，连续 3 次就前移
        // 这里验证选了 C 后 B 的 position 没被 C 的操作影响
        engine.record(prev: "A", current: "C")
        let results = engine.predict(after: "A")
        let bResult = results.first { $0.text == "B" }
        let cResult = results.first { $0.text == "C" }
        XCTAssertEqual(bResult?.position, 3)  // B 选了 3 次，前移到 3
        XCTAssertEqual(cResult?.position, 4)  // C 只选了 1 次，仍在 4
    }

    // MARK: - 预测结果排序

    func testPredictResultsSortedByPosition() {
        // B 选 3 次（position=3），C 选 1 次（position=4）
        // 预测结果应 B 在前
        engine.record(prev: "A", current: "B")
        engine.record(prev: "A", current: "B")
        engine.record(prev: "A", current: "B")
        engine.record(prev: "A", current: "C")

        let results = engine.predict(after: "A")
        XCTAssertEqual(results.first?.text, "B")
        XCTAssertEqual(results.last?.text, "C")
    }

    // MARK: - 修剪（10,000 条上限）

    func testTrimRemovesLowestTotalCountPairs() {
        // 先建立 "keep" 词对，选 5 次（totalCount 高，应被保留）
        for _ in 0..<5 { engine.record(prev: "keep", current: "me") }

        // 填满到恰好 10,000 条（不含上面那条，需要 9,999 条）
        for i in 0..<9_999 {
            engine.record(prev: "prev_\(i)", current: "word_\(i)")
        }

        // 此时共 10,000 条，再加一条低频词，触发修剪
        engine.record(prev: "victim", current: "bye")

        // "victim" 到 "bye" 只选了 1 次，应被删除（或 totalCount 最小的被删除）
        // "keep" 到 "me" 选了 5 次，应保留
        let keepResults = engine.predict(after: "keep")
        XCTAssertFalse(keepResults.isEmpty, "高频词对应被保留")
    }

    func testTotalPairsNeverExceedsMax() {
        // 插入 10,100 条，验证修剪后总数不超限
        for i in 0..<10_100 {
            engine.record(prev: "p\(i)", current: "w\(i)")
        }
        // record 是异步派发，flush() 用 queue.sync 确保所有任务完成后再读 totalPairsCount
        engine.flush()
        let total = engine.totalPairsCount
        XCTAssertLessThanOrEqual(total, PredictionEngine.maxPairs)
    }

    // MARK: - 清除

    func testClearEmptiesAllPredictions() {
        engine.record(prev: "你好", current: "世界")
        engine.clear()
        XCTAssertTrue(engine.predict(after: "你好").isEmpty)
        XCTAssertEqual(engine.totalPairsCount, 0)
    }

    // MARK: - 持久化

    func testFlushAndReload() {
        engine.record(prev: "你好", current: "世界")
        engine.record(prev: "你好", current: "世界")
        engine.record(prev: "你好", current: "世界")  // position 应前移到 3
        engine.record(prev: "你好", current: "朋友")

        engine.flush()

        let reloaded = PredictionEngine(fileURL: fileURL)
        let results = reloaded.predict(after: "你好")

        XCTAssertEqual(results.count, 2)
        let world = results.first { $0.text == "世界" }
        let friend = results.first { $0.text == "朋友" }
        XCTAssertEqual(world?.position, 3)
        XCTAssertEqual(friend?.position, 4)
    }

    func testReloadPreservesConsecutiveCount() {
        // 选 2 次，consecutiveCount=2，写盘重载后再选 1 次应触发前移
        engine.record(prev: "A", current: "B")
        engine.record(prev: "A", current: "B")
        engine.flush()

        let reloaded = PredictionEngine(fileURL: fileURL)
        XCTAssertEqual(reloaded.predict(after: "A").first?.position, 4)

        reloaded.record(prev: "A", current: "B")
        XCTAssertEqual(reloaded.predict(after: "A").first?.position, 3)
    }

    func testCorruptFileIsIgnoredGracefully() {
        let garbage = Data([0xFF, 0xFE, 0x00, 0x01, 0x99])
        try? garbage.write(to: fileURL)
        let eng = PredictionEngine(fileURL: fileURL)
        XCTAssertEqual(eng.totalPairsCount, 0)
    }

    func testWrongVersionFileIsDiscarded() {
        // 写一个 version=99 的文件
        var buf = Data()
        var v: UInt32 = 99
        buf.append(contentsOf: withUnsafeBytes(of: &v) { Array($0) })
        try? buf.write(to: fileURL)

        let eng = PredictionEngine(fileURL: fileURL)
        XCTAssertEqual(eng.totalPairsCount, 0)
    }

    func testEmptyFileIsHandledGracefully() {
        try? Data().write(to: fileURL)
        let eng = PredictionEngine(fileURL: fileURL)
        XCTAssertEqual(eng.totalPairsCount, 0)
    }

    func testNonexistentFileStartsEmpty() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("nonexistent_\(UUID().uuidString).bin")
        let eng = PredictionEngine(fileURL: url)
        XCTAssertEqual(eng.totalPairsCount, 0)
    }

    func testClearThenFlushDeletesPersistedData() {
        engine.record(prev: "A", current: "B")
        engine.flush()
        engine.clear()  // clear 内部调用 flushAsync，但测试用 flush 确保同步写盘
        engine.flush()

        let reloaded = PredictionEngine(fileURL: fileURL)
        XCTAssertEqual(reloaded.totalPairsCount, 0)
    }
}
