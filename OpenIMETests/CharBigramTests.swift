import XCTest
@testable import OpenIMECore

// MARK: - 字级二元语法侧车单元测试
//
// 覆盖：缺文件即空表、只有单字词时删侧车、往返后常见搭配分数高于未见搭配、
// 计数按词频排序、corpusLogFreq 等于总频对数、重复构建字节一致（幂等）。

final class CharBigramTests: XCTestCase {

    private var tmpDir: URL!

    override func setUp() {
        super.setUp()
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CharBigramTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmpDir)
        super.tearDown()
    }

    private var sidecarURL: URL { tmpDir.appendingPathComponent("dict.lm.bin") }

    private func build(_ entries: [(text: String, freq: Int)]) throws {
        try CharBigramBuilder.build(from: entries, to: sidecarURL)
    }

    func testAbsentFileIsEmpty() {
        let lm = CharBigram(sidecar: tmpDir.appendingPathComponent("nope.bin"))
        XCTAssertTrue(lm.isEmpty)
        XCTAssertEqual(lm.corpusLogFreq, 16, "空表应退回缺省的归一化常数")
    }

    /// 词库里全是单字词，导不出任何相邻搭配，就不该留一份侧车（回老行为）
    func testSingleCharOnlyRemovesSidecar() throws {
        try build([("你", 5_000_000), ("好", 3_000_000)])
        XCTAssertFalse(FileManager.default.fileExists(atPath: sidecarURL.path),
                       "没有多字词时不应生成侧车")
        XCTAssertTrue(CharBigram(sidecar: sidecarURL).isEmpty)
    }

    /// 空词条同样不生成侧车
    func testEmptyEntriesNoSidecar() throws {
        try build([])
        XCTAssertFalse(FileManager.default.fileExists(atPath: sidecarURL.path))
        XCTAssertTrue(CharBigram(sidecar: sidecarURL).isEmpty)
    }

    /// 往返：常见搭配「好吗」的 log 概率要显著高于没见过的「好那」
    func testCommonPairBeatsUnseen() throws {
        try build([("好吗", 100_000), ("你好", 332_885)])
        let lm = CharBigram(sidecar: sidecarURL)
        XCTAssertFalse(lm.isEmpty)
        let seen = lm.logProb("好", "吗")
        let unseen = lm.logProb("好", "那")
        XCTAssertGreaterThan(seen, unseen, "常见搭配的分数必须高于没见过的搭配")
        XCTAssertGreaterThan(seen, -1.0, "高频搭配的概率应接近 1，log 接近 0")
    }

    /// 同一个前字下，词频更高的后字搭配分数更高
    func testHigherFreqPairScoresHigher() throws {
        try build([("好人", 900_000), ("好菜", 1_000)])
        let lm = CharBigram(sidecar: sidecarURL)
        XCTAssertGreaterThan(lm.logProb("好", "人"), lm.logProb("好", "菜"))
    }

    /// corpusLogFreq = log(总词频 + 1)，交给词图做每词归一化
    func testCorpusLogFreq() throws {
        try build([("好吗", 100_000), ("你好", 332_885)])
        let lm = CharBigram(sidecar: sidecarURL)
        XCTAssertEqual(lm.corpusLogFreq, log(Double(100_000 + 332_885) + 1), accuracy: 1e-9)
    }

    /// 重复构建产出完全一致的字节（排序稳定，便于对账）
    func testIdempotent() throws {
        let entries = [("你好", 332_885), ("好吗", 100_000), ("世界", 2_000_000)]
        try build(entries)
        let first = try Data(contentsOf: sidecarURL)
        try build(entries)
        let second = try Data(contentsOf: sidecarURL)
        XCTAssertEqual(first, second)
    }

    /// 多字词的每一对相邻字都要被统计到（世界 -> 世→界）
    func testAllAdjacentPairsCounted() throws {
        try build([("中华人民共和国", 50_000)])
        let lm = CharBigram(sidecar: sidecarURL)
        // 词内部相邻的几对都应比未见的搭配分高
        XCTAssertGreaterThan(lm.logProb("中", "华"), lm.logProb("中", "X"))
        XCTAssertGreaterThan(lm.logProb("华", "人"), lm.logProb("华", "X"))
        XCTAssertGreaterThan(lm.logProb("人", "民"), lm.logProb("人", "X"))
    }

    /// 模拟旧版本装好的词库：只有 dict.bin、没有侧车，启动对账时应能从已编译词库扫出并补建
    func testBuildFromCompiledBinaryWhenSidecarMissing() throws {
        let dictDir = tmpDir.appendingPathComponent("d", isDirectory: true)
        try FileManager.default.createDirectory(at: dictDir, withIntermediateDirectories: true)
        let yamlURL = tmpDir.appendingPathComponent("main.dict.yaml")
        let yaml = "---\ncolumns:\n  - text\n  - code\n  - weight\n  - annotation\n...\n" +
                   "你好\tnihao\t1000\t\n世界\tshijie\t900\t\n"
        try yaml.write(to: yamlURL, atomically: true, encoding: .utf8)
        let binURL = dictDir.appendingPathComponent("dict.bin")
        try DictCompiler.compileMultiple(yamlURLs: [yamlURL], outputURL: binURL, schemeType: .syllable)

        let lmURL = dictDir.appendingPathComponent("dict.lm.bin")
        XCTAssertTrue(FileManager.default.fileExists(atPath: lmURL.path), "编译期应顺带产出侧车")

        // 删掉侧车，回到「旧版本只有 dict.bin」的状态
        try FileManager.default.removeItem(at: lmURL)
        XCTAssertTrue(try DictCompiler.buildLanguageModelIfNeeded(at: binURL), "侧车缺失时应补建")
        XCTAssertTrue(FileManager.default.fileExists(atPath: lmURL.path))

        // 补建出来的侧车确实可用
        let lm = CharBigram(sidecar: lmURL)
        XCTAssertFalse(lm.isEmpty)
        XCTAssertGreaterThan(lm.logProb("你", "好"), lm.logProb("你", "X"))
        // 侧车已在，再调直接跳过
        XCTAssertFalse(try DictCompiler.buildLanguageModelIfNeeded(at: binURL))
    }

    /// 形码（direct）词库同样产出二元语法侧车：字级搭配看的是切出来的汉字，与编码方式无关，
    /// 长串形码按码长切分时同样靠它给整句打分。
    func testSidecarAlsoBuiltForDirectScheme() throws {
        let dictDir = tmpDir.appendingPathComponent("dir", isDirectory: true)
        try FileManager.default.createDirectory(at: dictDir, withIntermediateDirectories: true)
        let yamlURL = tmpDir.appendingPathComponent("wubi.dict.yaml")
        let yaml = "---\ncolumns:\n  - text\n  - code\n  - weight\n  - annotation\n...\n" +
                   "我们\ttuja\t1160\t\n自己\toivj\t1096\t\n"
        try yaml.write(to: yamlURL, atomically: true, encoding: .utf8)
        let binURL = dictDir.appendingPathComponent("dict.bin")
        try DictCompiler.compileMultiple(yamlURLs: [yamlURL], outputURL: binURL, schemeType: .direct)
        let lmURL = dictDir.appendingPathComponent("dict.lm.bin")
        XCTAssertTrue(FileManager.default.fileExists(atPath: lmURL.path),
                      "形码也应产出字级二元语法侧车")
        let lm = CharBigram(sidecar: lmURL)
        XCTAssertFalse(lm.isEmpty)
        XCTAssertGreaterThan(lm.logProb("我", "们"), lm.logProb("我", "X"))
        // 删掉侧车后，从已编译的形码 dict.bin 也能扫出并补建
        try FileManager.default.removeItem(at: lmURL)
        XCTAssertTrue(try DictCompiler.buildLanguageModelIfNeeded(at: binURL), "形码侧车缺失时应补建")
        XCTAssertFalse(CharBigram(sidecar: lmURL).isEmpty)
    }

    /// 生僻字（扩展 A 区）与偏旁部首拆字注释：编译→查询往返注释不丢、生僻字不坏，
    /// 且新的侧车扫描路径能正确跳过「已填充」的注释列（形码 stem 列常态非空）。
    func testRareCharAndRadicalAnnotationSurviveCompileQueryAndScan() throws {
        let dictDir = tmpDir.appendingPathComponent("rare", isDirectory: true)
        try FileManager.default.createDirectory(at: dictDir, withIntermediateDirectories: true)
        let yamlURL = tmpDir.appendingPathComponent("rare.dict.yaml")
        let rare = "\u{3400}"      // 㐀，CJK 扩展 A 区生僻字，花园明朝字体子集能显示
        let radical = "\u{2F00}"   // ⼀，康熙部首，拆字注释里常见
        // 注释列填拆字部件，模拟形码词库的 stem 列（非空）
        let yaml = "---\ncolumns:\n  - text\n  - code\n  - weight\n  - annotation\n...\n" +
                   "我们\ttuja\t1160\t人+尔\n" +
                   "自己\toivj\t1096\t目+己\n" +
                   "\(rare)\taaaa\t500\t\(radical)部首\n"
        try yaml.write(to: yamlURL, atomically: true, encoding: .utf8)
        let binURL = dictDir.appendingPathComponent("dict.bin")
        try DictCompiler.compileMultiple(yamlURLs: [yamlURL], outputURL: binURL, schemeType: .direct)

        // 编译期就产出侧车（含生僻字词条也不受影响）
        let lmURL = dictDir.appendingPathComponent("dict.lm.bin")
        XCTAssertTrue(FileManager.default.fileExists(atPath: lmURL.path))

        // 查询往返：生僻字文本不坏、拆字注释原样带出
        let reader = try DictReader(binURL: binURL)
        let rareHit = reader.query(prefix: "aaaa", limit: 5).first { $0.text == rare }
        XCTAssertEqual(rareHit?.text, rare, "生僻字应原样往返，不被截断或替换")
        XCTAssertEqual(rareHit?.annotation, "\(radical)部首", "偏旁部首拆字注释应原样带出")
        XCTAssertEqual(reader.query(prefix: "tuja", limit: 5).first { $0.text == "我们" }?.annotation, "人+尔")

        // 删掉侧车，走「已安装词库补建」的扫描路径：注释列已填充，扫描必须正确跳过它才能解析出词频
        try FileManager.default.removeItem(at: lmURL)
        XCTAssertTrue(try DictCompiler.buildLanguageModelIfNeeded(at: binURL),
                      "注释列非空的形码词库也应能扫描补建侧车")
        let lm = CharBigram(sidecar: lmURL)
        XCTAssertFalse(lm.isEmpty)
        // 扫描若错位（把注释当词频 / 把词频当注释），末尾对齐校验就会失败而返 nil；
        // 能建出侧车且真实相邻字搭配分高于未见搭配，说明注释列被正确跳过
        XCTAssertGreaterThan(lm.logProb("我", "们"), lm.logProb("我", "X"),
                             "补建出的二元语法应正确反映词内相邻字")
    }
}
