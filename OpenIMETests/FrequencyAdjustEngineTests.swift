import XCTest
@testable import OpenIMECore

// MARK: - 拼音动态调频引擎测试
//
// 覆盖三层：
//   1. 纯函数（normalizedKey / liftedFreq）—— 与磁盘、线程无关，边界与退化逐一验证；
//   2. 活表逻辑（record 的抬升 / 竞争衰减 / 归零删除 / 封顶 / count 读 / clear / trim）——
//      record、count 都在调用线程同步读写活表，学习量断言天然确定；
//   3. 持久化（encode / decode 往返 + 容错）—— 走内部可见的纯静态函数，绕开
//      init 的「后台读盘 → main-hop 合并」异步时序，断言稳定不 flaky。
//   4. 落盘触发时序（50 次节流 / 5 秒时间防抖及其互斥收尾）—— 防抖注入可控调度器，
//      武装/顺延/撤销/迟到触发全部手动推进，零 sleep；异步落盘用轮询等待。
//
// 每个用例都用独立的 temporaryDirectory 文件位（tearDown 删除），互不污染。

final class FrequencyAdjustEngineTests: XCTestCase {

    private var fileURL: URL!
    private var engine: FrequencyAdjustEngine!
    /// 标记层用例创建的临时 UserDefaults suite（tearDown 清除，零污染铁律）
    private var markerSuites: [String] = []

    override func setUp() {
        super.setUp()
        fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("frequency_test_\(UUID().uuidString).json")
        engine = FrequencyAdjustEngine(fileURL: fileURL)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: fileURL)
        for suite in markerSuites {
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        }
        markerSuites = []
        engine = nil
        super.tearDown()
    }

    /// 独立临时 suite 的标记 defaults：模拟「另一个进程也能读写同一份 App Group 标记」
    private func makeMarker() -> UserDefaults {
        let suite = "frequency_marker_\(UUID().uuidString)"
        markerSuites.append(suite)
        return UserDefaults(suiteName: suite)!
    }

    // MARK: - 编码归一化（normalizedKey）

    func testNormalizedKeyLowercasesAndStripsSeparators() {
        XCTAssertEqual(FrequencyCodec.normalizedKey("NIHAO"), "nihao")
        XCTAssertEqual(FrequencyCodec.normalizedKey("ni hao"), "nihao")
        XCTAssertEqual(FrequencyCodec.normalizedKey("ni'hao"), "nihao")
        XCTAssertEqual(FrequencyCodec.normalizedKey(" Ni Hao ' "), "nihao")
    }

    func testNormalizedKeyIsIdempotent() {
        let once = FrequencyCodec.normalizedKey("Nǐ Hao")
        XCTAssertEqual(FrequencyCodec.normalizedKey(once), once)
    }

    // MARK: - 抬升曲线（liftedFreq）

    func testLiftedFreqNoLearningReturnsBase() {
        // count=0：没学过，词频原样
        XCTAssertEqual(FrequencyAdjustEngine.liftedFreq(base: 500, count: 0, localMax: 1000), 500)
    }

    func testLiftedFreqWhenBaseIsLocalMaxReturnsBase() {
        // localMax <= base：本词已是本批最热，无抬升空间（避免凭空造出高于天然顶的权重）
        XCTAssertEqual(FrequencyAdjustEngine.liftedFreq(base: 1000, count: 3, localMax: 1000), 1000)
        XCTAssertEqual(FrequencyAdjustEngine.liftedFreq(base: 1200, count: 3, localMax: 1000), 1200)
    }

    func testLiftedFreqSaturatesAtLocalMax() {
        // 达到 promoteCap 即追平本批最高词频（靠 learned tie-break 登顶，但绝不超过）
        XCTAssertEqual(
            FrequencyAdjustEngine.liftedFreq(base: 500, count: FrequencyAdjustEngine.promoteCap, localMax: 1000),
            1000)
        // 超过 promoteCap 也不再抬升
        XCTAssertEqual(
            FrequencyAdjustEngine.liftedFreq(base: 500, count: FrequencyAdjustEngine.promoteCap * 5, localMax: 1000),
            1000)
    }

    func testLiftedFreqMonotonicIncreasing() {
        // 学习次数越多抬得越高（0 < 1 < 2 < 3 档）
        let a = FrequencyAdjustEngine.liftedFreq(base: 0, count: 1, localMax: 900)
        let b = FrequencyAdjustEngine.liftedFreq(base: 0, count: 2, localMax: 900)
        let c = FrequencyAdjustEngine.liftedFreq(base: 0, count: 3, localMax: 900)
        XCTAssertLessThan(a, b)
        XCTAssertLessThan(b, c)
    }

    func testLiftedFreqNeverExceedsLocalMax() {
        // 有界性：任意 count 都不会超过 localMax
        for count in 0...200 {
            XCTAssertLessThanOrEqual(
                FrequencyAdjustEngine.liftedFreq(base: 1, count: count, localMax: 1_000_000),
                1_000_000)
        }
    }

    // MARK: - 记录与读取（record / count）

    func testRecordThenCountReflectsSelections() {
        XCTAssertEqual(engine.count(code: "nihao", text: "你好"), 0)
        engine.record(code: "nihao", text: "你好")
        XCTAssertEqual(engine.count(code: "nihao", text: "你好"), 1)
        engine.record(code: "nihao", text: "你好")
        XCTAssertEqual(engine.count(code: "nihao", text: "你好"), 2)
    }

    func testRecordNormalizesCodeAcrossForms() {
        // 26 键全拼 / 带分隔 / 大写都归一到同一个键，学习量共享
        engine.record(code: "ni hao", text: "你好")
        XCTAssertEqual(engine.count(code: "NIHAO", text: "你好"), 1)
        engine.record(code: "ni'hao", text: "你好")
        XCTAssertEqual(engine.count(code: "nihao", text: "你好"), 2)
    }

    func testEmptyCodeOrTextIsIgnored() {
        engine.record(code: "", text: "你好")
        engine.record(code: "nihao", text: "")
        XCTAssertTrue(engine.isEmpty)
    }

    func testCompetitorDecaysAndIsRemovedAtZero() {
        // 同码竞争者各 -1，归零即删（可回退：换选别的词，旧词抬升逐步掉回）
        engine.record(code: "nihao", text: "你好")   // 你好 = 1
        XCTAssertEqual(engine.count(code: "nihao", text: "你好"), 1)
        engine.record(code: "nihao", text: "你妈")   // 你好 -1 → 0 删除；你妈 = 1
        XCTAssertEqual(engine.count(code: "nihao", text: "你好"), 0)
        XCTAssertEqual(engine.count(code: "nihao", text: "你妈"), 1)
    }

    func testCompetitorDecayIsGradualNotImmediate() {
        // 你好 攒到 3，改选一次你妈只把你好降到 2，仍需连续改选才回落到底
        for _ in 0..<3 { engine.record(code: "nihao", text: "你好") }
        XCTAssertEqual(engine.count(code: "nihao", text: "你好"), 3)
        engine.record(code: "nihao", text: "你妈")
        XCTAssertEqual(engine.count(code: "nihao", text: "你好"), 2)
        XCTAssertEqual(engine.count(code: "nihao", text: "你妈"), 1)
    }

    func testCountGrowsPastPromoteCapButLiftSaturates() {
        // 次数不再封顶（maxCount 已删除）：lifted 曲线在 promoteCap 处饱和，
        // 后续只参与 trim 排序，不再影响候选位置。
        let target = FrequencyAdjustEngine.promoteCap * 4
        for _ in 0..<target {
            engine.record(code: "nihao", text: "你好")
        }
        XCTAssertGreaterThan(engine.count(code: "nihao", text: "你好"), FrequencyAdjustEngine.promoteCap)
        // 饱和验证：超过 promoteCap 后 lifted 仍等于 localMax，不会因计数变化而再变
        let lifted = FrequencyAdjustEngine.liftedFreq(
            base: 500,
            count: engine.count(code: "nihao", text: "你好"),
            localMax: 1000)
        XCTAssertEqual(lifted, 1000)
    }

    func testDifferentCodesAreIndependent() {
        engine.record(code: "nihao", text: "你好")
        engine.record(code: "shijie", text: "世界")
        XCTAssertEqual(engine.count(code: "nihao", text: "你好"), 1)
        XCTAssertEqual(engine.count(code: "shijie", text: "世界"), 1)
        XCTAssertEqual(engine.count(code: "nihao", text: "世界"), 0)
    }

    // MARK: - 清除（clear）

    func testClearEmptiesEverything() {
        engine.record(code: "nihao", text: "你好")
        engine.record(code: "shijie", text: "世界")
        engine.clear()
        XCTAssertTrue(engine.isEmpty)
        XCTAssertEqual(engine.count(code: "nihao", text: "你好"), 0)
    }

    func testClearThenFlushPersistsEmpty() {
        engine.record(code: "nihao", text: "你好")
        engine.flush()          // 先落一份非空盘
        engine.clear()
        engine.flush()          // 清空后同步落盘
        let reloaded = FrequencyAdjustEngine.decode(contentsOf: fileURL)
        XCTAssertTrue(reloaded.isEmpty)
    }

    // MARK: - 修剪（trimIfNeeded，maxEntries 边界）

    func testTrimKeepsEntriesWithinMax() {
        // 小上限注入，避免在生产内存派生的 maxEntries（可上到几万）上灌万条；
        // 验证 trim 将总条目回拉到实例属性 maxEntries 内，高频项保留、低频项优先剪掉。
        let smallCap = 100
        let testEngine = FrequencyAdjustEngine(fileURL: fileURL, maxEntries: smallCap)
        let over = smallCap + 50
        for i in 0..<over {
            testEngine.record(code: "code_\(i)", text: "词_\(i)")
        }
        XCTAssertLessThanOrEqual(testEngine.totalEntries, smallCap)
    }

    func testTrimFavorsLowCountEntriesForRemoval() {
        // 同一码下高频项（多次选）应优先保留，低频项（刚选一次）先被剪
        let smallCap = 20
        let testEngine = FrequencyAdjustEngine(fileURL: fileURL, maxEntries: smallCap)
        // 先让 hotWord 累到 promoteCap 次，然后灌入大量新词触发 trim
        for _ in 0..<FrequencyAdjustEngine.promoteCap {
            testEngine.record(code: "shared", text: "热热")
        }
        for i in 0..<(smallCap + 40) {
            testEngine.record(code: "code_\(i)", text: "冷词_\(i)")
        }
        XCTAssertLessThanOrEqual(testEngine.totalEntries, smallCap)
        XCTAssertGreaterThan(testEngine.count(code: "shared", text: "热热"), 0,
                             "高频项不应被 trim 误杀")
    }

    // MARK: - 容量上限派生（回溯数据源的纯函数面）

    func testMaxEntriesDerivedScalesWithBudgetBase() {
        // 24 MB 预算→5000 条、60 MB→12500 条：随设备内存线性自适应
        XCTAssertEqual(FrequencyAdjustEngine.maxEntries(fromBudgetBase: 24_000_000), 5_000)
        XCTAssertEqual(FrequencyAdjustEngine.maxEntries(fromBudgetBase: 60_000_000), 12_500)
    }

    func testMaxEntriesFloorWhenBudgetTinyOrZero() {
        // 预算极小/为零时兜底到 promoteCap：至少走完一轮衰减，不至于归零
        XCTAssertEqual(FrequencyAdjustEngine.maxEntries(fromBudgetBase: 0),
                       FrequencyAdjustEngine.promoteCap)
        XCTAssertEqual(FrequencyAdjustEngine.maxEntries(fromBudgetBase: 96 * 2),
                       FrequencyAdjustEngine.promoteCap)
    }

    func testProductionMaxEntriesNeverCollapses() {
        // 隐患一回归护栏：无 jetsam 限制环境 os_proc_available_memory() 返回 0 时
        // 须回退物理内存套同比例，绝不允许踩到 promoteCap 地面让学习表形同虚设
        XCTAssertGreaterThan(engine.maxEntries, FrequencyAdjustEngine.promoteCap,
                             "测试宿主上无论 syscall 返回值如何，派生都必须落在正常量级")
    }

    // MARK: - 读盘快照超容：合并完立即修剪（容量不变式无超容窗口）

    func testLoadedSnapshotBeyondCapIsTrimmedAtMerge() {
        let smallCap = 20
        var seeded: [String: [String: Int]] = [:]
        for i in 0..<(smallCap * 3) { seeded["code_\(i)"] = ["词_\(i)": 1] }
        FrequencyAdjustEngine.encode(seeded, to: fileURL)
        let testEngine = FrequencyAdjustEngine(fileURL: fileURL, maxEntries: smallCap)
        // 等后台读盘 → main-hop 合并+修剪落地（trim 在同一个主线程块里，条目一出现就已合规）
        let applied = expectation(description: "applyLoaded")
        func poll() {
            if testEngine.totalEntries > 0 { applied.fulfill() }
            else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { poll() } }
        }
        poll()
        wait(for: [applied], timeout: 5)
        XCTAssertEqual(testEngine.totalEntries, smallCap,
                       "盘上超容快照合并后必须当场修剪到上限，不留超容窗口")
    }

    // MARK: - 持久化：encode / decode 往返 + 容错

    func testEncodeDecodeRoundTrip() throws {
        let table: [String: [String: Int]] = [
            "nihao": ["你好": 3, "你妈": 1],
            "shijie": ["世界": 5],
        ]
        FrequencyAdjustEngine.encode(table, to: fileURL)
        let decoded = FrequencyAdjustEngine.decode(contentsOf: fileURL)
        XCTAssertEqual(decoded, table)
    }

    func testDecodeMissingFileReturnsEmpty() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("nonexistent_\(UUID().uuidString).json")
        XCTAssertTrue(FrequencyAdjustEngine.decode(contentsOf: url).isEmpty)
    }

    func testDecodeCorruptFileReturnsEmpty() throws {
        try Data([0xFF, 0xFE, 0x00, 0x01, 0x99]).write(to: fileURL)
        XCTAssertTrue(FrequencyAdjustEngine.decode(contentsOf: fileURL).isEmpty)
    }

    func testDecodeWrongShapeReturnsEmpty() throws {
        // 顶层结构不是 [String:[String:Int]]（这里给成数组）：解不出当空表，绝不因损坏文件拖累打字
        try "[1,2,3]".data(using: .utf8)!.write(to: fileURL)
        XCTAssertTrue(FrequencyAdjustEngine.decode(contentsOf: fileURL).isEmpty)
    }

    // MARK: - flush（同步落盘）确实写出文件

    func testFlushWritesFileSynchronously() {
        engine.record(code: "nihao", text: "你好")
        engine.record(code: "nihao", text: "你好")
        engine.flush()   // ioQueue.sync，返回时盘上必已有完整快照
        let decoded = FrequencyAdjustEngine.decode(contentsOf: fileURL)
        XCTAssertEqual(decoded["nihao"]?["你好"], 2)
    }

    // MARK: - 跨进程清除双层防护（广播 + 标记，防「清完被存活进程复活」）

    func testClearWritesMarkerForOtherProcesses() {
        let marker = makeMarker()
        let testEngine = FrequencyAdjustEngine(fileURL: fileURL, clearMarker: marker)
        testEngine.record(code: "nihao", text: "你好")
        testEngine.clear()
        XCTAssertGreaterThan(marker.double(forKey: FrequencyAdjustEngine.clearMarkerKey), 0,
                             "主动清除必须留下跨进程标记")
        XCTAssertTrue(testEngine.isEmpty)
    }

    func testExternalClearMarkerDiscardsStaleTableBeforeNextRecord() {
        let marker = makeMarker()
        let stale = FrequencyAdjustEngine(fileURL: fileURL, maxEntries: 50, clearMarker: marker)
        stale.record(code: "nihao", text: "你好")
        XCTAssertEqual(stale.count(code: "nihao", text: "你好"), 1)
        // 模拟「另一进程完成了清除」：标记被推高
        marker.set(Date().timeIntervalSince1970 + 1, forKey: FrequencyAdjustEngine.clearMarkerKey)
        // 下一次 record 先同步：旧词被丢弃，只留新选
        stale.record(code: "shijie", text: "世界")
        XCTAssertEqual(stale.count(code: "nihao", text: "你好"), 0)
        XCTAssertEqual(stale.count(code: "shijie", text: "世界"), 1)
        // 落盘只写新数据 —— 被清数据不会随迟到 flush 复活到盘上
        stale.flush()
        let persisted = FrequencyAdjustEngine.decode(contentsOf: fileURL)
        XCTAssertNil(persisted[FrequencyCodec.normalizedKey("nihao")]?["你好"])
    }

    func testApplyExternalClearDiscardsTableWithoutTouchingMarker() {
        let marker = makeMarker()
        marker.set(Date().timeIntervalSince1970, forKey: FrequencyAdjustEngine.clearMarkerKey)
        let stamp = marker.double(forKey: FrequencyAdjustEngine.clearMarkerKey)
        let receiver = FrequencyAdjustEngine(fileURL: fileURL, clearMarker: marker)
        receiver.record(code: "nihao", text: "你好")
        // 广播响应路径：只弃表，不推标记（推了会与发起方形成回声式重复清除）
        receiver.applyExternalClear()
        XCTAssertTrue(receiver.isEmpty)
        XCTAssertEqual(marker.double(forKey: FrequencyAdjustEngine.clearMarkerKey), stamp,
                       "响应方不得改写清除标记")
        // 弃表后照常可学：新选词不丢掉
        receiver.record(code: "nihao", text: "你好")
        XCTAssertEqual(receiver.count(code: "nihao", text: "你好"), 1)
    }

    func testInitAlignsKnownStampSoOldMarkerDoesNotWipeFreshTable() {
        let marker = makeMarker()
        // 盘上已有历史清除戳：新进程 init 先对齐，不应启动即误判「有外部清除」
        marker.set(Date().timeIntervalSince1970 - 3600, forKey: FrequencyAdjustEngine.clearMarkerKey)
        let testEngine = FrequencyAdjustEngine(fileURL: fileURL, clearMarker: marker)
        testEngine.record(code: "nihao", text: "你好")
        testEngine.record(code: "shijie", text: "世界")
        XCTAssertEqual(testEngine.count(code: "nihao", text: "你好"), 1)
        XCTAssertEqual(testEngine.count(code: "shijie", text: "世界"), 1)
    }

    // MARK: - 时间防抖（尾量兜底，与 50 次节流、生命周期补写互斥不双写）

    /// 可控防抖器：记录武装/撤销次数与最近一次延时，测试手动触发，断言全同步确定
    private final class DebounceProbe {
        private(set) var schedules = 0
        private(set) var cancels = 0
        private(set) var lastDelay: TimeInterval = -1
        private var pendingID: Int?
        private var nextID = 0
        private var fires: [Int: () -> Void] = [:]
        private var lastFire: (() -> Void)?

        var hasPending: Bool { pendingID != nil }

        func makeScheduler() -> FrequencyAdjustEngine.DebounceScheduler {
            { [weak self] delay, fire in
                guard let self else { return {} }
                self.schedules += 1
                self.lastDelay = delay
                self.nextID += 1
                let id = self.nextID
                self.pendingID = id
                self.fires[id] = fire
                self.lastFire = fire
                return { [weak self] in
                    guard let self, self.pendingID == id else { return }
                    self.cancels += 1
                    self.pendingID = nil
                    self.fires[id] = nil
                }
            }
        }

        /// 触发当前仍挂起的那次（正常到点）
        func firePending() {
            guard let id = pendingID, let f = fires[id] else { return }
            pendingID = nil
            fires[id] = nil
            f()
        }

        /// 绕过撤销检查直接调引擎 fire 入口，模拟「撤销不彻底的迟到回调」，验证引擎侧再核
        func fireLatest() { lastFire?() }
    }

    /// 轮询等后台串行队列的异步落盘完成（与 applyLoaded 用例同一 runloop-poll 手法），返回最后一次快照
    private func waitForPersist(containing predicate: ([String: [String: Int]]) -> Bool) -> [String: [String: Int]] {
        var decoded: [String: [String: Int]] = [:]
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            decoded = FrequencyAdjustEngine.decode(contentsOf: fileURL)
            if predicate(decoded) { return decoded }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        return decoded
    }

    private func makeDebouncedEngine(_ probe: DebounceProbe) -> FrequencyAdjustEngine {
        FrequencyAdjustEngine(fileURL: fileURL, debounce: probe.makeScheduler())
    }

    func testIdleNeverArmsDebounce() {
        // 用户场景铁律：键盘一直开着但没打字 —— 不得有任何计时器存在
        let probe = DebounceProbe()
        let testEngine = makeDebouncedEngine(probe)
        // 给 init 的后台读盘走完（main-hop 不碰防抖）
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        XCTAssertEqual(probe.schedules, 0, "没有选词就不得武装任何防抖")
        XCTAssertFalse(probe.hasPending)
        XCTAssertTrue(testEngine.isEmpty)
    }

    func testRecordArmsDebounceWithWindowConstant() {
        let probe = DebounceProbe()
        let testEngine = makeDebouncedEngine(probe)
        testEngine.record(code: "nihao", text: "你好")
        XCTAssertEqual(probe.schedules, 1)
        XCTAssertEqual(probe.lastDelay, FrequencyAdjustEngine.persistDebounceSeconds,
                       "防抖延时必须取行为常量单源，不许各写一份")
    }

    func testDebounceRefiresPostpone() {
        // trailing 语义：每次选词撤销旧的重新武装，触发永远计「最后一次选词后 5 秒」
        let probe = DebounceProbe()
        let testEngine = makeDebouncedEngine(probe)
        testEngine.record(code: "nihao", text: "你好")
        testEngine.record(code: "nihao", text: "你好")
        testEngine.record(code: "nihao", text: "你好")
        XCTAssertEqual(probe.schedules, 3)
        XCTAssertEqual(probe.cancels, 2, "每次重新武装必须撤销上一次，最多只有一个挂起")
        XCTAssertTrue(probe.hasPending)
        probe.firePending()
        let persisted = waitForPersist { $0["nihao"]?["你好"] == 3 }
        XCTAssertEqual(persisted["nihao"]?["你好"], 3, "防抖到点必须把尾量落盘")
    }

    func testEmptyCodeOrTextNeverArmsDebounce() {
        // guard 分支退化输入：不进活表也不武装防抖（与 testEmptyCodeOrTextIsIgnored 同源边界）
        let probe = DebounceProbe()
        let testEngine = makeDebouncedEngine(probe)
        testEngine.record(code: "", text: "你好")
        testEngine.record(code: "nihao", text: "")
        XCTAssertEqual(probe.schedules, 0)
    }

    func testCommitIntervalPersistCancelsDebounce() {
        // 两个落盘触发器的互斥：满 50 次节流接手后，挂起防抖必须被撤销且不双写
        let probe = DebounceProbe()
        let testEngine = makeDebouncedEngine(probe)
        for i in 0..<FrequencyAdjustEngine.commitInterval {
            testEngine.record(code: "code_\(i)", text: "词_\(i)")
        }
        // 前 49 次各武装一次并互相顺延撤销；第 50 次走节流落盘，不再武装、只撤销挂起
        XCTAssertEqual(probe.schedules, FrequencyAdjustEngine.commitInterval - 1)
        XCTAssertEqual(probe.cancels, FrequencyAdjustEngine.commitInterval - 1)
        XCTAssertFalse(probe.hasPending, "节流落盘后不得残留挂起防抖（防双写）")
        let persisted = waitForPersist { $0.count == FrequencyAdjustEngine.commitInterval }
        XCTAssertEqual(persisted.count, FrequencyAdjustEngine.commitInterval)
    }

    func testFlushAsyncCancelsDebounce() {
        // 键盘收起补写（viewWillDisappear 路径）之后，防抖必须无事可做
        let probe = DebounceProbe()
        let testEngine = makeDebouncedEngine(probe)
        testEngine.record(code: "nihao", text: "你好")
        testEngine.record(code: "nihao", text: "你好")
        testEngine.flushAsync()
        XCTAssertFalse(probe.hasPending)
        let persisted = waitForPersist { $0["nihao"]?["你好"] == 2 }
        XCTAssertEqual(persisted["nihao"]?["你好"], 2)
    }

    func testLateDebounceFireDoesNotRewriteAfterFlush() {
        // 迟到的防抖回调（模拟撤销不彻底的引用）：未落盘计数已归零 → 引擎侧再核拦截，不得再写盘
        let probe = DebounceProbe()
        let testEngine = makeDebouncedEngine(probe)
        testEngine.record(code: "nihao", text: "你好")
        testEngine.flush()            // 同步落盘，计数归零、防抖已撤销
        try? FileManager.default.removeItem(at: fileURL)
        probe.fireLatest()            // 绕过撤销检查强制触发旧的 fire 入口
        // 给误写的异步落盘充分时间落地（真写了文件必已被创建），再断言盘面仍不存在
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.3))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path),
                       "已落过盘的内容不得被迟到防抖再写一遍")
    }

    func testClearDiscardsPendingDebounce() {
        // 主动清除：弃表 + 落空盘都不得被挂起防抖插队重复写
        let probe = DebounceProbe()
        let testEngine = makeDebouncedEngine(probe)
        testEngine.record(code: "nihao", text: "你好")
        testEngine.record(code: "nihao", text: "你好")
        testEngine.clear()
        XCTAssertFalse(probe.hasPending)
        XCTAssertTrue(testEngine.isEmpty)
        let persisted = waitForPersist { $0.isEmpty && FileManager.default.fileExists(atPath: fileURL.path) }
        XCTAssertTrue(persisted.isEmpty, "清除后盘上应是空表")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path),
                      "空表必须是真写过盘，不能拿「文件不存在」假通过")
    }

    func testExternalClearDiscardsPendingDebounceWithoutEchoWrite() {
        // 响应外部清除（广播路径）：只弃表；挂起防抖被撤销，更不得回声落盘
        let probe = DebounceProbe()
        let marker = makeMarker()
        let testEngine = FrequencyAdjustEngine(fileURL: fileURL,
                                               clearMarker: marker,
                                               debounce: probe.makeScheduler())
        testEngine.record(code: "nihao", text: "你好")
        testEngine.record(code: "nihao", text: "你好")
        XCTAssertTrue(probe.hasPending)
        testEngine.applyExternalClear()
        XCTAssertFalse(probe.hasPending, "弃表后必须撤销挂起防抖，防迟到回写旧数据")
        XCTAssertTrue(testEngine.isEmpty)
    }
}
