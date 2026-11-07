import XCTest
@testable import OpenIMECore

// MARK: - CandidateEngine 测试
// 需要先编译一份真实的 dict.bin，再加载到 CandidateEngine 中查询

final class CandidateEngineTests: XCTestCase {

    private var tmpDir: URL!
    private var engine: CandidateEngine!

    override func setUp() {
        super.setUp()
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CETest_\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        engine = CandidateEngine()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmpDir)
        super.tearDown()
    }

    // MARK: - 辅助：编译并加载方案

    /// 编译 YAML 并返回可直接加载的 InstalledScheme
    private func makeScheme(
        id: String,
        type: SchemeType,
        entries: String,
        maxCodeLength: Int? = nil,
        codeSystem: CodeSystem? = nil,
        enableSentence: Bool? = nil
    ) throws -> InstalledScheme {
        let dictDir = tmpDir.appendingPathComponent("\(id)/dictionaries", isDirectory: true)
        try FileManager.default.createDirectory(at: dictDir, withIntermediateDirectories: true)

        let yaml = """
---
columns:
  - text
  - code
  - weight
  - annotation
...
\(entries)
"""
        let yamlURL = dictDir.appendingPathComponent("main.dict.yaml")
        try yaml.write(to: yamlURL, atomically: true, encoding: .utf8)

        let binURL = tmpDir.appendingPathComponent("\(id)/dict.bin")
        try DictCompiler.compileMultiple(
            yamlURLs: [yamlURL], outputURL: binURL, schemeType: type)

        let manifest = SchemeManifest(id: id, name: id, version: "1.0", author: "", description: "")
        let definition = SchemeDefinition(type: type, maxCodeLength: maxCodeLength, autoSelect: nil,
                                          alphabet: nil, doublePinyinTable: nil, normalizeCode: nil,
                                          codeSystem: codeSystem, enableSentence: enableSentence)
        let schemeDir = tmpDir.appendingPathComponent(id)
        return InstalledScheme(id: id, manifest: manifest, definition: definition,
                               installPath: schemeDir, availableColumns: ["text","code","weight","annotation"])
    }

    // MARK: - 加载/卸载

    func testQueryBeforeLoadReturnsEmpty() {
        let results = engine.query(input: "nihao", schemeId: "any")
        XCTAssertTrue(results.isEmpty)
    }

    func testUnloadedSchemeReturnsEmpty() throws {
        let scheme = try makeScheme(id: "s1", type: .syllable,
                                     entries: "你好\tnihao\t1000\t\n")
        try engine.loadScheme(scheme)
        engine.unloadScheme(id: "s1")
        XCTAssertTrue(engine.query(input: "nihao", schemeId: "s1").isEmpty)
    }

    // MARK: - 基础查询

    func testExactPrefixReturnsResults() throws {
        let scheme = try makeScheme(id: "s", type: .syllable,
                                     entries: "你好\tnihao\t1000\t\n你们\tnimen\t900\t\n")
        try engine.loadScheme(scheme)
        let results = engine.query(input: "ni", schemeId: "s")
        XCTAssertFalse(results.isEmpty)
        XCTAssertTrue(results.allSatisfy { $0.code.hasPrefix("ni") })
    }

    func testNoMatchReturnsEmpty() throws {
        let scheme = try makeScheme(id: "s", type: .syllable,
                                     entries: "你好\tnihao\t1000\t\n")
        try engine.loadScheme(scheme)
        let results = engine.query(input: "xyz", schemeId: "s")
        XCTAssertTrue(results.isEmpty)
    }

    func testEmptyInputReturnsEmpty() throws {
        let scheme = try makeScheme(id: "s", type: .syllable,
                                     entries: "你好\tnihao\t1000\t\n")
        try engine.loadScheme(scheme)
        XCTAssertTrue(engine.query(input: "", schemeId: "s").isEmpty)
    }

    func testResultsAreSortedByFreqDescending() throws {
        let scheme = try makeScheme(id: "s", type: .syllable,
                                     entries: "你好\tnihao\t500\t\n你候\tnihao\t1000\t\n你坏\tnihao\t800\t\n")
        try engine.loadScheme(scheme)
        let results = engine.query(input: "nihao", schemeId: "s")
        XCTAssertGreaterThanOrEqual(results.count, 2)
        for i in 0..<(results.count - 1) {
            XCTAssertGreaterThanOrEqual(results[i].freq, results[i+1].freq)
        }
    }

    func testResultsRespectLimit() throws {
        var entries = ""
        for i in 0..<20 {
            entries += "词\(i)\tcode\(i)\t\(500 + i)\t\n"
        }
        let scheme = try makeScheme(id: "s", type: .direct, entries: entries)
        try engine.loadScheme(scheme)
        let results = engine.query(input: "code", schemeId: "s", limit: 5)
        XCTAssertLessThanOrEqual(results.count, 5)
    }

    func testAnnotationIsPreserved() throws {
        let scheme = try makeScheme(id: "s", type: .syllable,
                                     entries: "你好\tnihao\t1000\tnǐ hǎo\n")
        try engine.loadScheme(scheme)
        let results = engine.query(input: "nihao", schemeId: "s")
        let match = results.first { $0.text == "你好" }
        XCTAssertEqual(match?.annotation, "nǐ hǎo")
    }

    func testSourceSchemeIdIsSet() throws {
        let scheme = try makeScheme(id: "myscheme", type: .syllable,
                                     entries: "你好\tnihao\t1000\t\n")
        try engine.loadScheme(scheme)
        let results = engine.query(input: "nihao", schemeId: "myscheme")
        XCTAssertTrue(results.allSatisfy { $0.sourceSchemeId == "myscheme" })
    }

    // MARK: - 自定义词（位次调频：第5位起、点选升频封顶第2位、降频回落第5位）

    /// 六条同前缀 "niha" 的形码词条（词频降序 词0…词5），给自定义词提供 ≥5 条的 base，
    /// 才能验证「第5位」这个绝对位次。用形码（.direct）避开 applyFrequency 对 base 的重排干扰。
    private func makeRankScheme() throws {
        var entries = ""
        for i in 0..<6 {
            entries += "词\(i)\tniha\(i)\t\(1000 - i * 100)\t\n"
        }
        let scheme = try makeScheme(id: "r", type: .direct, entries: entries)
        try engine.loadScheme(scheme)
    }

    /// 自定义词绝不占据首选：base 不足 5 条时落末尾（起始位次 idx4 被 min(idx, count) 兜到末位）。
    func testCustomWordDoesNotTakeFirstRank() throws {
        let scheme = try makeScheme(id: "s", type: .syllable,
                                     entries: "你好\tnihao\t1000\t\n")
        try engine.loadScheme(scheme)
        let custom = CustomWord(id: UUID(), text: "自定义", code: "niha", createdAt: Date())
        engine.updateCustomWords([custom])
        let results = engine.query(input: "niha", schemeId: "s")
        XCTAssertEqual(results.first?.text, "你好", "自定义词不再强制置顶")
        XCTAssertEqual(results.last?.text, "自定义", "base 不足 5 条时落末尾")
    }

    /// base ≥5 条时，新自定义词（count 0）从第 5 位起（0-based idx 4）。
    func testCustomWordStartsAtFifthRank() throws {
        try makeRankScheme()
        engine.updateCustomWords([CustomWord(id: UUID(), text: "自定义", code: "niha", createdAt: Date())])
        let results = engine.query(input: "niha", schemeId: "r")
        XCTAssertEqual(results.firstIndex { $0.text == "自定义" }, CandidateEngine.customWordStartRank - 1,
                       "新词落第 5 位（不占首选）")
        XCTAssertEqual(results.first?.text, "词0", "天然首选仍占据第 1 位")
    }

    /// 每主动点选一次上升一位（count 1→第4位、2→第3位、3→第2位），≥3 封顶第 2 位。
    func testCustomWordPromotesOneRankPerPick() throws {
        try makeRankScheme()
        engine.updateCustomWords([CustomWord(id: UUID(), text: "自定义", code: "niha", createdAt: Date())])
        for (count, expectedIdx) in [(0, 4), (1, 3), (2, 2), (3, 1), (4, 1), (9, 1)] {
            engine.frequencyBoost = { _, text in text == "自定义" ? count : 0 }
            let results = engine.query(input: "niha", schemeId: "r")
            let idx = results.firstIndex { $0.text == "自定义" }
            XCTAssertEqual(idx, expectedIdx, "count=\(count) 应在 0-based 位次 \(expectedIdx)")
        }
    }

    /// 降频：改选同码其它候选使计数回落后，自定义词逐位下沉，最低回到起始的第 5 位。
    func testCustomWordDemotesBackToFifth() throws {
        try makeRankScheme()
        engine.updateCustomWords([CustomWord(id: UUID(), text: "自定义", code: "niha", createdAt: Date())])
        engine.frequencyBoost = { _, text in text == "自定义" ? 3 : 0 }
        XCTAssertEqual(engine.query(input: "niha", schemeId: "r").firstIndex { $0.text == "自定义" }, 1,
                       "学满时封顶第 2 位")
        engine.frequencyBoost = { _, _ in 0 }
        XCTAssertEqual(engine.query(input: "niha", schemeId: "r").firstIndex { $0.text == "自定义" },
                       CandidateEngine.customWordStartRank - 1, "计数归零回落第 5 位")
    }

    func testCustomWordDoesNotDuplicate() throws {
        let scheme = try makeScheme(id: "s", type: .syllable,
                                     entries: "你好\tnihao\t1000\t\n")
        try engine.loadScheme(scheme)
        let custom = CustomWord(id: UUID(), text: "你好", code: "nihao", createdAt: Date())
        engine.updateCustomWords([custom])
        let results = engine.query(input: "nihao", schemeId: "s")
        let count = results.filter { $0.text == "你好" }.count
        XCTAssertEqual(count, 1)
    }

    func testCustomWordMatchesByPrefix() throws {
        let scheme = try makeScheme(id: "s", type: .syllable,
                                     entries: "你好\tnihao\t1000\t\n")
        try engine.loadScheme(scheme)
        let custom = CustomWord(id: UUID(), text: "自定义词", code: "nihao123", createdAt: Date())
        engine.updateCustomWords([custom])
        let results = engine.query(input: "ni", schemeId: "s")
        XCTAssertTrue(results.contains { $0.text == "自定义词" })
    }

    func testClearCustomWordsRemovesThem() throws {
        let scheme = try makeScheme(id: "s", type: .syllable,
                                     entries: "你好\tnihao\t1000\t\n")
        try engine.loadScheme(scheme)
        let custom = CustomWord(id: UUID(), text: "自定义", code: "zzz", createdAt: Date())
        engine.updateCustomWords([custom])
        engine.updateCustomWords([])
        let results = engine.query(input: "zzz", schemeId: "s")
        XCTAssertTrue(results.filter { $0.text == "自定义" }.isEmpty)
    }

    /// 自定义词匹配：应被它 code 的每一个前缀命中（等价 `filter { hasPrefix }`），非前缀则不命中。
    func testCustomWordIndexMatchesEveryPrefix() throws {
        let scheme = try makeScheme(id: "p", type: .direct,
                                     entries: "你好\tnihao\t1000\t\n")
        try engine.loadScheme(scheme)
        engine.updateCustomWords([CustomWord(id: UUID(), text: "自定义词", code: "nihao", createdAt: Date())])
        for prefix in ["n", "ni", "nih", "niha", "nihao"] {
            XCTAssertTrue(engine.query(input: prefix, schemeId: "p").contains { $0.text == "自定义词" },
                          "code 的前缀 \(prefix) 应命中自定义词")
        }
        XCTAssertFalse(engine.query(input: "hao", schemeId: "p").contains { $0.text == "自定义词" },
                       "非前缀 hao 不应命中 code=nihao 的自定义词")
    }

    /// 同一 code 前缀命中多条词时，应全部返回，不能只出第一条。
    func testCustomWordIndexReturnsAllWordsInBucket() throws {
        try makeRankScheme()
        engine.updateCustomWords([
            CustomWord(id: UUID(), text: "甲", code: "niha", createdAt: Date()),
            CustomWord(id: UUID(), text: "乙", code: "niha", createdAt: Date()),
        ])
        let results = engine.query(input: "niha", schemeId: "r")
        XCTAssertTrue(results.contains { $0.text == "甲" }, "同前缀桶里的多条自定义词都应命中")
        XCTAssertTrue(results.contains { $0.text == "乙" }, "同前缀桶里的多条自定义词都应命中")
    }

    // MARK: - 长串词图兜底

    /// 长过任何单词的串（没有词库 code 以它为前缀），常规查询落空，词图应切出整句候选。
    func testLatticeComposesLongUnmatchedInput() throws {
        // 故意不收「你好世界」这个整词，让 nihaoshijie 的前缀查询彻底落空，逼出词图兜底
        let scheme = try makeScheme(id: "s", type: .syllable,
                                     entries: "你好\tnihao\t1000\t\n世界\tshijie\t900\t\n" +
                                              "你\tni\t800\t\n好\thao\t700\t\n" +
                                              "世\tshi\t600\t\n界\tjie\t500\t\n")
        try engine.loadScheme(scheme)
        let results = engine.query(input: "nihaoshijie", schemeId: "s")
        XCTAssertFalse(results.isEmpty, "长串本应无候选，词图兜底要能切出整句")
        XCTAssertEqual(results.first?.text, "你好世界")
        XCTAssertEqual(results.first?.code, "nihaoshijie")
        XCTAssertEqual(results.first?.sourceSchemeId, "s")
    }

    /// 短串仍走常规前缀查询，词图一条都不该插手：结果与词库原样一致（freq 是词库的真词频，不是合成值）。
    func testShortInputUnaffectedByLattice() throws {
        let scheme = try makeScheme(id: "s", type: .syllable,
                                     entries: "你好\tnihao\t1000\t\n世界\tshijie\t900\t\n")
        try engine.loadScheme(scheme)
        let results = engine.query(input: "nihao", schemeId: "s")
        XCTAssertEqual(results.first?.text, "你好")
        XCTAssertEqual(results.first?.freq, 1000, "短串命中前缀查询，返回的应是词库真词频")
        XCTAssertEqual(results.first?.code, "nihao")
    }

    /// 形码（direct）长串也走词图兜底，但必须方案声明了 max_code_length 才能界定单段跨度。
    /// 声明了码长（4）时，多个词的编码连写（我们 tuja + 自己 oivj）应切回整句。
    func testDirectSchemeLongInputSegmentsByCodeLength() throws {
        let scheme = try makeScheme(id: "d", type: .direct,
                                     entries: "我们\ttuja\t1160\t\n自己\toivj\t1096\t\n",
                                     maxCodeLength: 4)
        try engine.loadScheme(scheme)
        let results = engine.query(input: "tujaoivj", schemeId: "d")
        XCTAssertFalse(results.isEmpty, "形码长串本应无候选，词图应按码长切回整句")
        XCTAssertEqual(results.first?.text, "我们自己")
        XCTAssertEqual(results.first?.code, "tujaoivj")
    }

    /// 没声明 max_code_length 的形码方案无从界定单段跨度，不切，长串仍然返回空（老行为）。
    func testDirectWithoutCodeLengthNotSegmented() throws {
        let scheme = try makeScheme(id: "d", type: .direct,
                                     entries: "你\twqiy\t800\t\n好\tvbg\t700\t\n")
        try engine.loadScheme(scheme)
        let results = engine.query(input: "wqiyvbgzzzz", schemeId: "d")
        XCTAssertTrue(results.isEmpty, "未声明码长的形码不应触发词图切分")
    }

    /// 外部格式的形码方案普遍写 enable_sentence: false（外部格式的形码靠 auto_select 顶字、不靠拼句），
    /// 但词图是 OpenIME 形码长串唯一的兜底路，不能被这个旗标拦死 ——
    /// 否则虎码连打 vusuyfnp 会一个候选都没有（用户实测踩到的坑，锁定之）。
    func testShapeLatticeNotBlockedByEnableSentenceFalse() throws {
        let scheme = try makeScheme(id: "d", type: .direct,
                                     entries: "这边\tvusu\t5447\t\n上班\tyfnp\t4221\t\n" +
                                              "这\tvu\t2256430\t\n边\tsu\t157617\t\n" +
                                              "上\tyf\t1392471\t\n班\tnp\t43869\t\n",
                                     maxCodeLength: 4, codeSystem: .shape, enableSentence: false)
        try engine.loadScheme(scheme)
        let results = engine.query(input: "vusuyfnp", schemeId: "d")
        XCTAssertFalse(results.isEmpty, "形码长串不受 enable_sentence: false 拦截")
        XCTAssertEqual(results.first?.text, "这边上班")
        XCTAssertEqual(results.first?.code, "vusuyfnp")
    }

    /// enable_sentence 是外部格式 translator 的拼句旗标，OpenIME 的词图是自家兜底算法，
    /// 不被它开关：音码方案写 false 时长串照样切整句（OpenIME 是主体，
    /// 数据源的旗标管不到本 App 的算法；锁定之防回潮）
    func testPhoneticLatticeNotGatedByEnableSentenceFalse() throws {
        let scheme = try makeScheme(id: "s", type: .syllable,
                                     entries: "你好\tnihao\t1000\t\n世界\tshijie\t900\t\n" +
                                              "你\tni\t800\t\n好\thao\t700\t\n" +
                                              "世\tshi\t600\t\n界\tjie\t500\t\n",
                                     enableSentence: false)
        try engine.loadScheme(scheme)
        let results = engine.query(input: "nihaoshijie", schemeId: "s")
        XCTAssertFalse(results.isEmpty, "词图兜底不被外部格式拼句旗标开关")
        XCTAssertEqual(results.first?.text, "你好世界")
    }

    /// 逐条读音查询（小鹤双拼展开出的多条切分）不允许各自跑词图：
    /// 词图是 O(输入长²) 的词库扫描，逐条兜底会把一次击键放大成几十次扫描，
    /// 主线程被拖到像死机 —— 当年九宫逐条切分长串卡死就是这个放大。锁定 allowLattice: false 真能关掉
    func testAllowLatticeFalseDisablesFallback() throws {
        let scheme = try makeScheme(id: "s", type: .syllable,
                                     entries: "你好\tnihao\t1000\t\n世界\tshijie\t900\t\n" +
                                              "你\tni\t800\t\n好\thao\t700\t\n" +
                                              "世\tshi\t600\t\n界\tjie\t500\t\n")
        try engine.loadScheme(scheme)
        XCTAssertTrue(engine.query(input: "nihaoshijie", schemeId: "s",
                                   allowLattice: false).isEmpty,
                      "关掉兜底后长串应落空，由调用方整组落空后统一兜底一次")
        XCTAssertFalse(engine.query(input: "nihaoshijie", schemeId: "s").isEmpty,
                       "默认仍兜底，26 键行为不变")
    }

    /// 切不开的长串（根本不是合法拼音）仍然返回空，与老行为一致。
    func testUnsegmentableLongInputStillEmpty() throws {
        let scheme = try makeScheme(id: "s", type: .syllable,
                                     entries: "你好\tnihao\t1000\t\n")
        try engine.loadScheme(scheme)
        XCTAssertTrue(engine.query(input: "xyzxyzxyz", schemeId: "s").isEmpty)
    }

    /// 超过词图长度上限的串不再切：词图已移到后台串行队列，但超长串仍会白耗后台 CPU，故设上界直接落空。
    /// 64 字（上限内）仍能切出整句，66 字（超上限）则返回空，两者都只由「你/ni」这一个字构成。
    func testLatticeCapsOverlongInput() throws {
        let scheme = try makeScheme(id: "s", type: .syllable,
                                     entries: "你\tni\t800\t\n")
        try engine.loadScheme(scheme)
        let atCap = String(repeating: "ni", count: 32)     // 64 字，正好在上限内
        let overCap = String(repeating: "ni", count: 33)   // 66 字，超过上限
        XCTAssertEqual(atCap.count, 64)
        XCTAssertEqual(overCap.count, 66)
        XCTAssertFalse(engine.query(input: atCap, schemeId: "s").isEmpty,
                       "上限内的长串仍应切出整句候选")
        XCTAssertTrue(engine.query(input: overCap, schemeId: "s").isEmpty,
                      "超过上限的串应落空，避免超长切分在后台白耗 CPU")
    }

    /// 回归：词图每段查词必须走 queryExact（精确命中），不能拿 query(prefix:).filter{code==} 凑。
    /// 构造一个音节「pin」的整码字被 101 个同前缀高词频长词挤出前缀 top-100 的场景：
    /// 旧写法 filter 后「pin」查不到词、词图断边，整句切不出（长拼音「什么都查不到」的根因）；
    /// queryExact 只收精确命中，稳定拿到「拼」，整句才切得出来。
    func testLatticeLookupUsesExactMatchNotPrefixFilter() throws {
        var entries = "拼\tpin\t1\t\n"
        // 101 个同前缀（pin*）高词频长词，把低频整码「拼」挤出 query(prefix:"pin",limit:100) 的堆外
        for i in 0..<101 {
            entries += "词\(i)\tpin\(i)zz\t\(1000 + i)\t\n"
        }
        let scheme = try makeScheme(id: "s", type: .syllable, entries: entries)
        try engine.loadScheme(scheme)
        // 15 字 = 5 个「pin」，前缀查询整串落空 → 逼出词图；词图每段靠 lookup("pin") 拿「拼」
        let input = String(repeating: "pin", count: 5)
        XCTAssertEqual(input.count, 15)
        let results = engine.query(input: input, schemeId: "s")
        XCTAssertFalse(results.isEmpty, "整码字被前缀 top-N 挤出时，queryExact 仍应让词图切出整句")
        XCTAssertEqual(results.first?.text, "拼拼拼拼拼")
    }

    // MARK: - 拼音动态调频（boost 接入候选排序）

    /// 三条同码不同词频的拼音候选，词频降序基线：你好(1000) > 你坏(800) > 你候(500)
    private func makeFrequencyScheme() throws {
        let scheme = try makeScheme(id: "f", type: .syllable,
                                     entries: "你好\tnihao\t1000\t\n你坏\tnihao\t800\t\n你候\tnihao\t500\t\n")
        try engine.loadScheme(scheme)
    }

    func testNoFrequencyBoostPreservesOriginalOrder() throws {
        try makeFrequencyScheme()
        let results = engine.query(input: "nihao", schemeId: "f")
        XCTAssertEqual(results.map { $0.text }, ["你好", "你坏", "你候"])
    }

    func testFrequencyBoostLiftsLowFreqWordToTop() throws {
        try makeFrequencyScheme()
        // 反复选最低频的「你候」达到 promoteCap：相对本批 localMax 抬满，靠 learned 在平分中压过天然顶字
        engine.frequencyBoost = { _, text in
            text == "你候" ? FrequencyAdjustEngine.promoteCap : 0
        }
        let results = engine.query(input: "nihao", schemeId: "f")
        XCTAssertEqual(results.first?.text, "你候", "学满的词应抬到首位")
        XCTAssertEqual(results.last?.text, "你坏", "未学的次热词仍在其后，且抬升不超过 localMax")
    }

    func testFrequencyBoostBelowCapDoesNotOverthrowTop() throws {
        try makeFrequencyScheme()
        // 只学过 1 次：部分抬升（666）仍不足以撼动词库天然高频词 —— 偶发误选不破坏原序
        engine.frequencyBoost = { _, text in text == "你候" ? 1 : 0 }
        let results = engine.query(input: "nihao", schemeId: "f")
        XCTAssertEqual(results.first?.text, "你好")
        XCTAssertEqual(results.last?.text, "你候")
    }

    func testFrequencyBoostIgnoredForShapeScheme() throws {
        // 形码（.direct → codeSystem .shape）一码对字，不参与调频：boost 返回再高也不改序
        let scheme = try makeScheme(id: "sh", type: .direct,
                                     entries: "测试\tabcd\t1000\t\n测验\tabcd\t500\t\n")
        try engine.loadScheme(scheme)
        engine.frequencyBoost = { _, text in text == "测验" ? FrequencyAdjustEngine.promoteCap : 0 }
        let results = engine.query(input: "abcd", schemeId: "sh")
        XCTAssertEqual(results.map { $0.text }, ["测试", "测验"], "形码候选顺序不受调频影响")
    }

    // MARK: - 组句面板：leadingOptions（绑定 reader / profile 的实例路径）
    //
    // 验证与词图同源的查词接线：profile 按码制分派、lookup 走 queryExact（词频降序）。

    /// 音码方案：nihaoma 开头一段列出 ni(你 / 尼) 与 nihao(你好)，词按真词频降序。
    func testLeadingOptionsPhonetic() throws {
        let scheme = try makeScheme(id: "s", type: .syllable,
                                     entries: "你\tni\t800\t\n尼\tni\t50\t\n你好\tnihao\t1000\t\n好\thao\t700\t\n")
        try engine.loadScheme(scheme)
        let options = engine.leadingOptions(input: "nihaoma", schemeId: "s")
        XCTAssertEqual(options.map { $0.end }, [2, 5], "开头一段按终点升序：ni(2) / nihao(5)")
        XCTAssertEqual(options[0].words.map { $0.text }, ["你", "尼"], "queryExact 按词频降序")
        XCTAssertEqual(options[1].words.map { $0.text }, ["你好"])
    }

    /// 形码方案：声明了 max_code_length(4) 才能按码长滑窗，tujaoivj 开头列出 t(和) / tu(图) / tuja(我们)。
    func testLeadingOptionsShape() throws {
        let scheme = try makeScheme(id: "d", type: .direct,
                                     entries: "和\tt\t50\t\n图\ttu\t40\t\n我们\ttuja\t116\t\n",
                                     maxCodeLength: 4)
        try engine.loadScheme(scheme)
        let options = engine.leadingOptions(input: "tujaoivj", schemeId: "d")
        XCTAssertEqual(options.map { $0.end }, [1, 2, 4], "形码按码长滑窗，只列词库里真存在的段")
        XCTAssertEqual(options[2].words.map { $0.text }, ["我们"])
    }

    /// 未声明码长的形码无从界定单段跨度，铺不出选项（与词图切分同一护栏）。
    func testLeadingOptionsShapeWithoutCodeLengthEmpty() throws {
        let scheme = try makeScheme(id: "d", type: .direct,
                                     entries: "和\tt\t50\t\n我们\ttuja\t116\t\n")
        try engine.loadScheme(scheme)
        XCTAssertTrue(engine.leadingOptions(input: "tujaoivj", schemeId: "d").isEmpty)
    }

    /// 退化：未加载方案 / 太短的串 / 铺不出段，都返回空。
    func testLeadingOptionsDegenerate() throws {
        let scheme = try makeScheme(id: "s", type: .syllable, entries: "你好\tnihao\t1000\t\n")
        try engine.loadScheme(scheme)
        XCTAssertTrue(engine.leadingOptions(input: "nihaoma", schemeId: "unloaded").isEmpty, "未加载方案")
        XCTAssertTrue(engine.leadingOptions(input: "n", schemeId: "s").isEmpty, "单字不交给词图")
        XCTAssertTrue(engine.leadingOptions(input: "xyzxyz", schemeId: "s").isEmpty, "铺不出音节段")
    }

    // MARK: - 组句面板展示序：orderedCompositionChoices（纯函数，全局词频降序）
    //
    // 用户需求：组句面板里常用词 / 字排在前、生僻冷门的沉到后。修复点是打破
    // 「终点升序 + 组内词频降序」——旧序会让最短那段（拼音里的单字）的所有生僻字
    // 挤在长跨度的常用多字词之前，故改成不分跨度、只按词频全局降序。

    /// 核心修复：长跨度的常用词（你好 1000）排在短跨度的生僻字（尼 5）之前，
    /// 而不是像旧序那样把所有单字（终点近）一股脑排在多字词之前。
    func testOrderedCompositionChoicesSortsByGlobalFreqDescending() {
        let options: [(end: Int, words: [CodeLattice.Word])] = [
            (end: 2, words: [CodeLattice.Word(text: "你", freq: 100),
                             CodeLattice.Word(text: "尼", freq: 5)]),
            (end: 5, words: [CodeLattice.Word(text: "你好", freq: 1000)]),
        ]
        let result = CandidateEngine.orderedCompositionChoices(options, limit: 200)
        XCTAssertEqual(result.map { $0.text }, ["你好", "你", "尼"], "按词频全局降序，常用词 / 字在前")
        XCTAssertEqual(result.map { $0.spanLen }, [5, 2, 2], "spanLen 沿用该段终点")
    }

    /// 同文本跨组重复时去重，保留词频最高的那条（排序后首现即最高频）。
    func testOrderedCompositionChoicesDedupesKeepingHighestFreq() {
        let options: [(end: Int, words: [CodeLattice.Word])] = [
            (end: 2, words: [CodeLattice.Word(text: "你", freq: 100)]),
            (end: 5, words: [CodeLattice.Word(text: "你", freq: 900),
                             CodeLattice.Word(text: "你好", freq: 500)]),
        ]
        let result = CandidateEngine.orderedCompositionChoices(options, limit: 200)
        XCTAssertEqual(result.map { $0.text }, ["你", "你好"], "同文本只留一条")
        XCTAssertEqual(result[0].spanLen, 5, "去重保留词频最高（900）那条，其 spanLen=5")
    }

    /// limit 截断：只保留词频最高的前 limit 条。
    func testOrderedCompositionChoicesRespectsLimit() {
        let options: [(end: Int, words: [CodeLattice.Word])] = [
            (end: 1, words: [CodeLattice.Word(text: "一", freq: 10),
                             CodeLattice.Word(text: "二", freq: 20),
                             CodeLattice.Word(text: "三", freq: 30)]),
        ]
        let result = CandidateEngine.orderedCompositionChoices(options, limit: 2)
        XCTAssertEqual(result.map { $0.text }, ["三", "二"], "截断保留最高频的前 2 条")
    }

    /// 词频并列时：终点近者（跨度短）在前，再按文本字典序，保证结果可复现。
    func testOrderedCompositionChoicesTieBreakBySpanThenText() {
        let options: [(end: Int, words: [CodeLattice.Word])] = [
            (end: 5, words: [CodeLattice.Word(text: "b", freq: 100)]),
            (end: 2, words: [CodeLattice.Word(text: "a", freq: 100)]),
        ]
        let result = CandidateEngine.orderedCompositionChoices(options, limit: 200)
        XCTAssertEqual(result.map { $0.text }, ["a", "b"], "词频并列时终点近（2<5）者在前")
    }

    /// 退化：options 为空 / limit ≤ 0 都返回空。
    func testOrderedCompositionChoicesDegenerate() {
        XCTAssertTrue(CandidateEngine.orderedCompositionChoices([], limit: 200).isEmpty, "空 options")
        let options: [(end: Int, words: [CodeLattice.Word])] = [
            (end: 2, words: [CodeLattice.Word(text: "你", freq: 100)]),
        ]
        XCTAssertTrue(CandidateEngine.orderedCompositionChoices(options, limit: 0).isEmpty, "limit=0")
    }
}

// MARK: - MixInputEngine 测试

final class MixInputEngineTests: XCTestCase {

    private var tmpDir: URL!
    private var candidateEngine: CandidateEngine!
    private var mixEngine: MixInputEngine!

    override func setUp() {
        super.setUp()
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MixTest_\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        candidateEngine = CandidateEngine()
        mixEngine = MixInputEngine(candidateEngine: candidateEngine)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmpDir)
        super.tearDown()
    }

    private func makeScheme(id: String, type: SchemeType, entries: String) throws -> InstalledScheme {
        let dictDir = tmpDir.appendingPathComponent("\(id)/dictionaries", isDirectory: true)
        try FileManager.default.createDirectory(at: dictDir, withIntermediateDirectories: true)
        let yaml = "---\ncolumns:\n  - text\n  - code\n  - weight\n  - annotation\n...\n\(entries)"
        let yamlURL = dictDir.appendingPathComponent("main.dict.yaml")
        try yaml.write(to: yamlURL, atomically: true, encoding: .utf8)
        let binURL = tmpDir.appendingPathComponent("\(id)/dict.bin")
        try DictCompiler.compileMultiple(yamlURLs: [yamlURL], outputURL: binURL, schemeType: type)
        let manifest = SchemeManifest(id: id, name: id, version: "1.0", author: "", description: "")
        let definition = SchemeDefinition(type: type, maxCodeLength: nil, autoSelect: nil,
                                          alphabet: nil, doublePinyinTable: nil, normalizeCode: nil)
        return InstalledScheme(id: id, manifest: manifest, definition: definition,
                               installPath: tmpDir.appendingPathComponent(id), availableColumns: [])
    }

    // MARK: - 基础混打

    func testPrimarySchemeResultsAppearFirst() throws {
        let s1 = try makeScheme(id: "primary", type: .syllable, entries: "你好\tnihao\t1000\t\n")
        let s2 = try makeScheme(id: "secondary", type: .syllable, entries: "泥耗\tnihao\t900\t\n")
        try candidateEngine.loadScheme(s1)
        try candidateEngine.loadScheme(s2)

        let config = MixSchemeConfig(id: "secondary", isEnabled: true, candidateColor: "#FF0000", priority: 1)
        let results = mixEngine.query(input: "nihao", primarySchemeId: "primary", mixConfigs: [config])

        XCTAssertFalse(results.isEmpty)
        XCTAssertEqual(results.first?.text, "你好")
        XCTAssertNil(results.first?.colorHex)
    }

    func testSecondarySchemeHasColorHex() throws {
        let s1 = try makeScheme(id: "p", type: .syllable, entries: "你好\tnihao\t1000\t\n")
        let s2 = try makeScheme(id: "m", type: .syllable, entries: "泥耗\tnihao\t900\t\n")
        try candidateEngine.loadScheme(s1)
        try candidateEngine.loadScheme(s2)

        let config = MixSchemeConfig(id: "m", isEnabled: true, candidateColor: "#FF0000", priority: 1)
        let results = mixEngine.query(input: "nihao", primarySchemeId: "p", mixConfigs: [config])

        let secondary = results.first { $0.colorHex != nil }
        XCTAssertEqual(secondary?.colorHex, "#FF0000")
    }

    func testDeduplicationAcrossSchemes() throws {
        // 两个方案都有「你好」，结果只出现一次
        let s1 = try makeScheme(id: "p", type: .syllable, entries: "你好\tnihao\t1000\t\n")
        let s2 = try makeScheme(id: "m", type: .syllable, entries: "你好\tnihao\t900\t\n泥耗\tnihao\t800\t\n")
        try candidateEngine.loadScheme(s1)
        try candidateEngine.loadScheme(s2)

        let config = MixSchemeConfig(id: "m", isEnabled: true, candidateColor: "#FF0000", priority: 1)
        let results = mixEngine.query(input: "nihao", primarySchemeId: "p", mixConfigs: [config])

        let count = results.filter { $0.text == "你好" }.count
        XCTAssertEqual(count, 1)
    }

    func testDisabledSecondarySchemeIsExcluded() throws {
        let s1 = try makeScheme(id: "p", type: .syllable, entries: "你好\tnihao\t1000\t\n")
        let s2 = try makeScheme(id: "m", type: .syllable, entries: "泥耗\tnihao\t900\t\n")
        try candidateEngine.loadScheme(s1)
        try candidateEngine.loadScheme(s2)

        let config = MixSchemeConfig(id: "m", isEnabled: false, candidateColor: "#FF0000", priority: 1)
        let results = mixEngine.query(input: "nihao", primarySchemeId: "p", mixConfigs: [config])

        XCTAssertFalse(results.contains { $0.text == "泥耗" })
    }

    /// 双拼逐条读音查询会传 allowLattice: false：混打里每个方案都要跟着关，
    /// 否则词图扫描仍会被放大几十倍
    func testAllowLatticeFalsePropagatesToEveryScheme() throws {
        let entries = "你\tni\t800\t\n好\thao\t700\t\n世\tshi\t600\t\n界\tjie\t500\t\n"
        let s1 = try makeScheme(id: "p", type: .syllable, entries: entries)
        let s2 = try makeScheme(id: "m", type: .syllable, entries: entries)
        try candidateEngine.loadScheme(s1)
        try candidateEngine.loadScheme(s2)
        let config = MixSchemeConfig(id: "m", isEnabled: true, candidateColor: "#FF0000", priority: 1)
        XCTAssertFalse(mixEngine.query(input: "nihaoshijie", primarySchemeId: "p",
                                       mixConfigs: [config]).isEmpty,
                       "默认仍兜底")
        XCTAssertTrue(mixEngine.query(input: "nihaoshijie", primarySchemeId: "p",
                                      mixConfigs: [config], allowLattice: false).isEmpty,
                      "关掉后每个方案都不兜底")
    }

    func testEmptyMixConfigsOnlyReturnsPrimary() throws {
        let s1 = try makeScheme(id: "p", type: .syllable, entries: "你好\tnihao\t1000\t\n")
        try candidateEngine.loadScheme(s1)
        let results = mixEngine.query(input: "nihao", primarySchemeId: "p", mixConfigs: [])
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.text, "你好")
    }

    func testSecondarySchemesSortedByPriority() throws {
        let s1 = try makeScheme(id: "p", type: .syllable, entries: "A\taa\t1000\t\n")
        let s2 = try makeScheme(id: "m1", type: .syllable, entries: "B\taa\t900\t\n")
        let s3 = try makeScheme(id: "m2", type: .syllable, entries: "C\taa\t800\t\n")
        try candidateEngine.loadScheme(s1)
        try candidateEngine.loadScheme(s2)
        try candidateEngine.loadScheme(s3)

        // m2 priority=0 比 m1 priority=1 高
        let configs = [
            MixSchemeConfig(id: "m1", isEnabled: true, candidateColor: "#FF0000", priority: 1),
            MixSchemeConfig(id: "m2", isEnabled: true, candidateColor: "#00FF00", priority: 0),
        ]
        let results = mixEngine.query(input: "aa", primarySchemeId: "p", mixConfigs: configs)
        let texts = results.map { $0.text }
        let idxA = texts.firstIndex(of: "A")!
        let idxC = texts.firstIndex(of: "C")!
        let idxB = texts.firstIndex(of: "B")!
        XCTAssertLessThan(idxA, idxC)
        XCTAssertLessThan(idxC, idxB)
    }

    func testQueryWithNoLoadedSchemesReturnsEmpty() {
        let config = MixSchemeConfig(id: "m", isEnabled: true, candidateColor: "#FF0000", priority: 0)
        let results = mixEngine.query(input: "nihao", primarySchemeId: "p", mixConfigs: [config])
        XCTAssertTrue(results.isEmpty)
    }

    /// 音码参与方案守门：主方案是形码时用户敲的是形码串（虎码 lc），
    /// 而音码检索自带「去尾一字符再查」的部分回退，lc 会被退化成 l，
    /// 把 l 开头的一整批与本次输入不相及的拼音候选混进来。
    /// 串不是合法拼音前缀就不查音码参与方案；合法拼音前缀（如 ni）照常参与。
    func testPhoneticParticipantGatedOnNonPinyinInput() throws {
        let shape = try makeScheme(id: "tiger", type: .direct, entries: "齿\tlc\t1000\t\n")
        let pinyin = try makeScheme(id: "pinyin", type: .syllable,
                                    entries: "了\tle\t900\t\n乐\tle\t800\t\n你\tni\t700\t\n")
        try candidateEngine.loadScheme(shape)
        try candidateEngine.loadScheme(pinyin)
        let config = MixSchemeConfig(id: "pinyin", isEnabled: true, candidateColor: "#FF0000", priority: 1)

        // lc 不是合法拼音前缀：没有守门时部分回退（lc→l）会捞出「了/乐」
        let results = mixEngine.query(input: "lc", primarySchemeId: "tiger", mixConfigs: [config])
        XCTAssertTrue(results.contains { $0.text == "齿" }, "主方案形码候选照常")
        XCTAssertFalse(results.contains { $0.text == "了" },
                       "音码参与方案对非法拼音串不应出候选")

        // 合法拼音前缀不受影响：ni 时音码参与方案照常出候选
        let ok = mixEngine.query(input: "ni", primarySchemeId: "tiger", mixConfigs: [config])
        XCTAssertTrue(ok.contains { $0.text == "你" }, "合法拼音前缀时音码参与方案照常查询")
    }
}
