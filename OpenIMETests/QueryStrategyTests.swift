import XCTest
@testable import OpenIMECore

// MARK: - 检索策略（对应外部格式的 translator + filter）
//
// 同一次击键，音码 / 形码 / 音形码 / 双拼要走完全不同的检索路径。以前这些分支挤在
// `CandidateEngine.query` 的一个 switch 里，加一种码制就得改那个 switch，
// 而「码制」与「存储类型」的差别（快码是音形码、词库却走前缀直查）在那个 switch 里根本表达不出来。
// 这里锁定：分派由画像决定、四策略各自的兜底行为、双拼长串不再是「一律返回空」、
// 以及 filter 层的同词去重与单字优先。

final class QueryStrategyTests: XCTestCase {

    private var tmpDir: URL!
    private var engine: CandidateEngine!

    override func setUp() {
        super.setUp()
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("QueryStrategyTests_\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        engine = CandidateEngine()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmpDir)
        tmpDir = nil
        super.tearDown()
    }

    // MARK: - 辅助

    /// 编译一份词库并包成 InstalledScheme，画像字段全部可控
    @discardableResult
    private func loadScheme(
        id: String = "s",
        type: SchemeType,
        entries: String,
        codeSystem: CodeSystem? = nil,
        maxCodeLength: Int? = nil,
        maxPhraseLength: Int? = nil,
        enableSentence: Bool? = nil,
        initialQuality: Double? = nil,
        wordFrequencyURL: URL? = nil
    ) throws -> InstalledScheme {
        let schemeDir = tmpDir.appendingPathComponent(id, isDirectory: true)
        let dictDir = schemeDir.appendingPathComponent("dictionaries", isDirectory: true)
        try FileManager.default.createDirectory(at: dictDir, withIntermediateDirectories: true)

        let yamlURL = dictDir.appendingPathComponent("main.dict.yaml")
        try ("---\ncolumns:\n  - text\n  - code\n  - weight\n  - annotation\n...\n" + entries)
            .write(to: yamlURL, atomically: true, encoding: .utf8)
        try DictCompiler.compileMultiple(yamlURLs: [yamlURL],
                                        outputURL: schemeDir.appendingPathComponent("dict.bin"),
                                        schemeType: type,
                                        wordFrequencyURL: wordFrequencyURL)

        let manifest = SchemeManifest(id: id, name: id, version: "1.0", author: "", description: "")
        let definition = SchemeDefinition(type: type, maxCodeLength: maxCodeLength,
                                         codeSystem: codeSystem, maxPhraseLength: maxPhraseLength,
                                         enableSentence: enableSentence, initialQuality: initialQuality)
        let scheme = InstalledScheme(id: id, manifest: manifest, definition: definition,
                                     installPath: schemeDir, availableColumns: [])
        try engine.loadScheme(scheme)
        return scheme
    }

    private func candidate(_ text: String, _ code: String, _ freq: Int,
                           isUserWord: Bool = false, userFreq: Int = 0) -> Candidate {
        Candidate(text: text, code: code, annotation: nil, freq: freq,
                  sourceSchemeId: "s", isUserWord: isUserWord, userFreq: userFreq)
    }

    // MARK: - 策略分派

    func testShapeProfileUsesCodeStringStrategy() {
        XCTAssertTrue(QueryStrategies.strategy(for: SchemeProfile(id: "a", type: .direct))
                        is CodeStringStrategy)
        XCTAssertTrue(QueryStrategies.strategy(for: SchemeProfile(id: "a", type: .syllable,
                                                                  codeSystem: .shape))
                        is CodeStringStrategy,
                      "码制说了算：存储类型是音节、行为上是形码，仍走前缀直查")
    }

    func testPhoneticProfileUsesSyllableStrategy() {
        XCTAssertTrue(QueryStrategies.strategy(for: SchemeProfile(id: "a", type: .syllable))
                        is SyllableStrategy)
        XCTAssertTrue(QueryStrategies.strategy(for: SchemeProfile(id: "a", type: .direct,
                                                                  codeSystem: .phonetic))
                        is SyllableStrategy)
    }

    func testPhonoShapeProfileUsesPhonoShapeStrategy() {
        XCTAssertTrue(QueryStrategies.strategy(for: SchemeProfile(id: "a", type: .direct,
                                                                  codeSystem: .phonoShape))
                        is PhonoShapeStrategy)
    }

    /// 双拼的「先展开成全拼」是词库存储方式决定的，压过码制
    func testDoubleSyllableTypeBeatsCodeSystem() {
        for codeSystem in [CodeSystem.shape, .phonetic, .phonoShape] {
            XCTAssertTrue(QueryStrategies.strategy(for: SchemeProfile(id: "a", type: .doubleSyllable,
                                                                     codeSystem: codeSystem))
                            is DoubleSyllableStrategy)
        }
    }

    // MARK: - 形码

    func testShapeSchemeQueriesByPrefix() throws {
        try loadScheme(type: .direct, entries: "我\tt\t2302420\t\n用\tty\t607554\t\n我们\ttuja\t1160\t\n")
        XCTAssertEqual(engine.query(input: "tu", schemeId: "s").map { $0.text }, ["我们"])
        XCTAssertEqual(engine.query(input: "tujaoivj", schemeId: "s").count, 0,
                       "没有 max_code_length 就无从界定单段跨度，长串不切")
    }

    /// 形码不做「去掉末尾一个字符再查」：编码不是音节前缀，回退对它没有意义
    func testShapeSchemeHasNoPartialFallback() throws {
        try loadScheme(type: .direct, entries: "你\twqiy\t800\t\n")
        XCTAssertTrue(engine.query(input: "wqiyz", schemeId: "s").isEmpty)
        XCTAssertEqual(engine.query(input: "wqiy", schemeId: "s").map { $0.text }, ["你"])
    }

    func testShapeLongInputFallsBackToCodeLattice() throws {
        try loadScheme(type: .direct, entries: "我们\ttuja\t1160\t\n自己\toivj\t1096\t\n",
                       maxCodeLength: 4)
        let results = engine.query(input: "tujaoivj", schemeId: "s")
        XCTAssertEqual(results.first?.text, "我们自己")
        XCTAssertEqual(results.first?.code, "tujaoivj")
    }

    /// 形码同样整码精确优先：虎码 lc 的真实场景——低权重的整码偏旁（艹=270）
    /// 不能被高权重的长码词组挤后（原格式 输出即精确在前）
    func testShapeExactCodeBeatsHigherFreqCompletion() throws {
        try loadScheme(type: .direct,
                       entries: "齿\tlc\t10569\n艹\tlc\t270\n词组\tlcab\t5000\n")
        XCTAssertEqual(engine.query(input: "lc", schemeId: "s").map { $0.text },
                       ["齿", "艹", "词组"],
                       "整码条目按词频排在补全之前，即便补全词频更高")
    }

    // MARK: - 音码

    func testSyllableSchemeQueriesByPrefix() throws {
        try loadScheme(type: .syllable, entries: "你好\tnihao\t1000\t\n你们\tnimen\t900\t\n")
        XCTAssertEqual(Set(engine.query(input: "ni", schemeId: "s").map { $0.text }), ["你好", "你们"])
    }

    /// 输入未完成时的中间状态：整串查不到就去掉末尾一个字符再查一次
    func testSyllableSchemeFallsBackToShorterPrefix() throws {
        try loadScheme(type: .syllable, entries: "你\tni\t800\t\n")
        XCTAssertEqual(engine.query(input: "nix", schemeId: "s").map { $0.text }, ["你"],
                       "nix 不是任何编码的前缀，去尾一字符后命中 ni")
        XCTAssertTrue(engine.query(input: "nix", schemeId: "s", allowPartialFallback: false).isEmpty,
                      "双拼的编码由展开器保证合法，调用方可以关掉回退")
    }

    func testSyllableLongInputUsesLattice() throws {
        try loadScheme(type: .syllable,
                       entries: "你好\tnihao\t1000\t\n世界\tshijie\t900\t\n你\tni\t800\t\n好\thao\t700\t\n世\tshi\t600\t\n界\tjie\t500\t\n")
        XCTAssertEqual(engine.query(input: "nihaoshijie", schemeId: "s").first?.text, "你好世界")
    }

    // MARK: - 音形码

    func testPhonoShapeSchemeQueriesByPrefix() throws {
        try loadScheme(type: .direct,
                       entries: "今天\tjafm\t100\n今\tja\t90\n",
                       codeSystem: .phonoShape)
        XCTAssertEqual(engine.query(input: "jafm", schemeId: "s").map { $0.text }, ["今天"])
        XCTAssertEqual(engine.query(input: "ja", schemeId: "s").map { $0.text }, ["今", "今天"],
                       "码表语义：整码精确匹配（今=ja）优先，更长码的补全（今天=jafm）在后；"
                       + "即便补全词频更高也不抢精确条目的位次——与外部格式 table translator 一致")
    }

    /// 音形码落空时走「音节段 + 定长形码段」的混合切分（CodeLattice.segmentMixed）
    func testPhonoShapeLongInputUsesMixedSegmentation() throws {
        try loadScheme(type: .direct,
                       entries: "你\tni\t800\t\n好\thao\t700\t\n世\tshi\t600\t\n界\tjie\t500\t\n",
                       codeSystem: .phonoShape, maxCodeLength: 4)
        let results = engine.query(input: "nihaoshijie", schemeId: "s")
        XCTAssertFalse(results.isEmpty, "音形码长串应由混合切分兜底")
        XCTAssertEqual(results.first?.text, "你好世界")
    }

    func testPhonoShapeWithoutCodeLengthIsNotSegmented() throws {
        try loadScheme(type: .direct,
                       entries: "你\tni\t800\t\n好\thao\t700\t\n",
                       codeSystem: .phonoShape)
        XCTAssertTrue(engine.query(input: "nihaonihao", schemeId: "s").isEmpty)
    }

    /// 超强快码真实场景：码表词库全库 weight 恒为 1，单字母前缀下大量长码
    /// 不能把高频简码挤出候选。「好」= hb，敲 h 后必须能在候选里看到它
    ///（此前被 200 多条 ha* 长码按字母序挤掉）。同词频下码短者优先。
    func testTableCompletionPrefersShorterCodeWhenWeightsTie() throws {
        var entries = "好\thb\t1\n"
        // 60 条 ha 开头的长码，weight 全等于 1，全部按字母序排在 hb 之前
        for i in 0..<60 {
            entries += "长\(i)\tha\(i)\t1\n"
        }
        try loadScheme(type: .direct, entries: entries, codeSystem: .phonoShape)
        let texts = engine.query(input: "h", schemeId: "s").map { $0.text }
        XCTAssertTrue(texts.contains("好"),
                      "同词频下码短者优先：hb 的「好」不能被 ha* 长码挤出 top-N")
        XCTAssertEqual(texts.first, "好",
                       "好 是唯一的 len2 码，同词频下应排在所有 ha* 长码之前")
    }

    /// 形码（非音形码）同样受码短优先保护：全库同权重时简码不被长码按字母序挤出
    func testShapeCompletionPrefersShorterCodeWhenWeightsTie() throws {
        var entries = "好\thb\t1\n"
        for i in 0..<60 {
            entries += "长\(i)\tha\(i)\t1\n"
        }
        try loadScheme(type: .direct, entries: entries, codeSystem: .shape)
        XCTAssertTrue(engine.query(input: "h", schemeId: "s").map { $0.text }.contains("好"),
                      "形码码表同样走 queryTable，简码优先")
    }

    /// 拼音（音码）路径不受码短优先影响：同权重下仍按原有行为，不走 queryTable。
    /// 这里验证音节方案的前缀查询依然按词频排序（高词频的长词在前）。
    func testSyllablePathDoesNotPreferShorterCode() throws {
        try loadScheme(type: .syllable,
                       entries: "你好\tnihao\t1000\t\n你\tni\t900\t\n")
        XCTAssertEqual(engine.query(input: "ni", schemeId: "s").map { $0.text }, ["你好", "你"],
                       "拼音按词频排序，高词频的长词在前（不因码长而反转）")
    }

    // MARK: - 双拼

    /// 主路：进来的已经是全拼（双拼键盘的展开器早就还原过了），行为与以前逐字节一致
    func testDoubleSyllableMainPathTreatsInputAsFullPinyin() throws {
        try loadScheme(type: .doubleSyllable, entries: "你好\tnihao\t1000\t\n")
        XCTAssertEqual(engine.query(input: "nihao", schemeId: "s").map { $0.text }, ["你好"])
    }

    /// 补路：进来的还是双拼码本身（26 键键盘配双拼方案、混打里另一路是双拼）。
    /// 以前这里直接返回空，一个候选都出不来
    func testDoubleSyllableCodeIsExpandedWhenPinyinPathMisses() throws {
        try loadScheme(type: .doubleSyllable, entries: "你好\tnihao\t1000\t\n")
        XCTAssertTrue(HeErDoublePinyin.shared.expand("nihc").contains("nihao"), "前置条件")
        // 关掉部分回退：否则主路把 nihc 去尾一字符成 nih，正好是 nihao 的前缀，测不到双拼展开那一步
        XCTAssertEqual(engine.query(input: "nihc", schemeId: "s", allowPartialFallback: false)
                        .map { $0.text }, ["你好"])
        XCTAssertFalse(engine.query(input: "nihao", schemeId: "s", allowPartialFallback: false).isEmpty,
                       "主路仍然走全拼")
    }

    /// 双拼长串从「返回空」补成「展开后走音节图」
    func testDoubleSyllableLongInputIsSegmented() throws {
        try loadScheme(type: .doubleSyllable,
                       entries: "你好\tnihao\t1000\t\n世界\tshijie\t900\t\n你\tni\t800\t\n好\thao\t700\t\n世\tshi\t600\t\n界\tjie\t500\t\n")
        XCTAssertTrue(HeErDoublePinyin.shared.expand("nihcuijp").contains("nihaoshijie"), "前置条件")
        let results = engine.query(input: "nihcuijp", schemeId: "s")
        XCTAssertFalse(results.isEmpty, "双拼长串以前一律返回空")
        XCTAssertEqual(results.first?.text, "你好世界")
    }

    func testDoubleSyllableUnexpandableInputReturnsEmpty() throws {
        try loadScheme(type: .doubleSyllable, entries: "你好\tnihao\t1000\t\n")
        XCTAssertTrue(engine.query(input: "tttt", schemeId: "s").isEmpty)
    }

    // MARK: - 画像开关生效

    /// enable_sentence 是外部格式 translator 的拼句旗标，OpenIME 的词图是自家兜底算法，
    /// 不被它开关（OpenIME 是主体，外部词库只贡献需要的字段）：
    /// 写 false 的方案长串照样切整句，没写时默认开 —— 两种情况行为一致
    func testEnableSentenceDoesNotGateLattice() throws {
        let entries = "你好\tnihao\t1000\t\n世界\tshijie\t900\t\n你\tni\t800\t\n好\thao\t700\t\n"
        try loadScheme(id: "off", type: .syllable, entries: entries, enableSentence: false)
        XCTAssertFalse(engine.query(input: "nihaoshijie", schemeId: "off").isEmpty,
                       "数据源的拼句旗标管不到 OpenIME 的词图兜底")

        try loadScheme(id: "on", type: .syllable, entries: entries)
        XCTAssertFalse(engine.query(input: "nihaoshijie", schemeId: "on").isEmpty,
                       "没写这个字段时同样开（长串切句是 OpenIME 自己的兜底）")
    }

    /// max_phrase_length：超长的词条不参与整句拼接
    func testMaxPhraseLengthFiltersLatticeWords() throws {
        let entries = "你好\tnihao\t1000\t\n世界\tshijie\t900\t\n"
        try loadScheme(id: "tight", type: .syllable, entries: entries, maxPhraseLength: 1)
        XCTAssertTrue(engine.query(input: "nihaoshijie", schemeId: "tight").isEmpty,
                      "只允许单字参与拼接，而词库里没有单字，就切不出整句")

        try loadScheme(id: "loose", type: .syllable, entries: entries)
        XCTAssertEqual(engine.query(input: "nihaoshijie", schemeId: "loose").first?.text, "你好世界")
    }

    // MARK: - uniquifier（同词去重）

    func testUniquifyKeepsHighestScoringEntry() {
        let result = CandidateScoring.uniquify([
            candidate("你好", "nihao", 500),
            candidate("你好", "niha", 900),
            candidate("世界", "shijie", 100),
        ])
        XCTAssertEqual(result.map { $0.text }, ["你好", "世界"])
        XCTAssertEqual(result[0].code, "niha", "留下排序分最高的那条")
    }

    func testUniquifyKeepsFirstPosition() {
        let result = CandidateScoring.uniquify([
            candidate("世界", "shijie", 100),
            candidate("你好", "nihao", 500),
            candidate("世界", "sji", 900),
        ])
        XCTAssertEqual(result.map { $0.text }, ["世界", "你好"], "位置沿用这个词第一次出现的地方")
        XCTAssertEqual(result[0].code, "sji")
    }

    /// 没有重复时原样返回入参数组，一个候选对象都不新建
    func testUniquifyReturnsSameObjectsWhenNoDuplicates() {
        let input = [candidate("你好", "nihao", 500), candidate("世界", "shijie", 100)]
        let result = CandidateScoring.uniquify(input)
        XCTAssertEqual(result.count, 2)
        XCTAssertTrue(result[0].id == input[0].id)
        XCTAssertTrue(result[1].id == input[1].id)
        XCTAssertTrue(CandidateScoring.uniquify([input[0]]).first?.id == input[0].id)
    }

    func testUniquifyPrefersUserWord() {
        let result = CandidateScoring.uniquify([
            candidate("你好", "nihao", 5000),
            candidate("你好", "nihao", 0, isUserWord: true, userFreq: 3),
        ])
        XCTAssertEqual(result.count, 1)
        XCTAssertTrue(result[0].isUserWord, "用户调过频的词不能被天生高频的词盖回去")
    }

    /// 形码的多码字：同一个字在 t 与 tupg 下各有一条，前缀查询会全部捞上来
    func testEngineDedupesSameWordWithMultipleCodes() throws {
        try loadScheme(type: .direct, entries: "我\tt\t2302420\t\n我\ttupg\t256\t\n用\tty\t607554\t\n")
        let results = engine.query(input: "t", schemeId: "s")
        XCTAssertEqual(results.filter { $0.text == "我" }.count, 1)
        XCTAssertEqual(results.first?.freq, 2302420)
    }

    func testSourceSchemeIdIsStamped() throws {
        try loadScheme(id: "mine", type: .syllable, entries: "你好\tnihao\t1000\t\n")
        XCTAssertTrue(engine.query(input: "nihao", schemeId: "mine")
                        .allSatisfy { $0.sourceSchemeId == "mine" })
    }

    // MARK: - 打分

    func testRankScoreOrdering() {
        XCTAssertEqual(CandidateScoring.rankScore(freq: 100), 100)
        XCTAssertEqual(CandidateScoring.rankScore(freq: 100, initialQuality: 2), 200)
        XCTAssertEqual(CandidateScoring.rankScore(freq: 1000),
                       CandidateScoring.rankScore(candidate("x", "y", 1000)))
        XCTAssertLessThan(CandidateScoring.rankScore(freq: 99_999),
                          CandidateScoring.rankScore(freq: 0, isUserWord: true))
        XCTAssertEqual(CandidateScoring.rankScore(freq: 0, isUserWord: true, userFreq: 5),
                       Double(CandidateScoring.userWordBase + 50))
        XCTAssertEqual(CandidateScoring.rankScore(freq: 100, initialQuality: -1), 0,
                       "负的基础权重按 0 处理，不能把次序反过来")
    }

    func testInitialQualityDoesNotReorderWithinOneScheme() {
        let candidates = [candidate("你", "ni", 800), candidate("尼", "ni", 700)]
        let plain = CandidateScoring.uniquify(candidates, initialQuality: 1)
        let scaled = CandidateScoring.uniquify(candidates, initialQuality: 0.3)
        XCTAssertEqual(plain.map { $0.text }, scaled.map { $0.text },
                       "同一个方案内 initial_quality 是常数，乘完次序一点不变")
    }

    // MARK: - 单字优先

    func testSingleCharFirstPartitionsStably() {
        let result = CandidateScoring.singleCharFirst([
            candidate("你好", "nihao", 1000),
            candidate("你", "ni", 800),
            candidate("世界", "shijie", 900),
            candidate("好", "hao", 700),
        ], enabled: true)
        XCTAssertEqual(result.map { $0.text }, ["你", "好", "你好", "世界"],
                       "单字提到前面，组内仍按原来的排序")
    }

    func testSingleCharFirstDisabledChangesNothing() {
        let input = [candidate("你好", "nihao", 1000), candidate("你", "ni", 800)]
        let result = CandidateScoring.singleCharFirst(input, enabled: false)
        XCTAssertEqual(result.map { $0.text }, ["你好", "你"])
        XCTAssertTrue(result[0].id == input[0].id)
    }

    func testSingleCharFirstIsNoopWhenAllSameLength() {
        let allSingles = [candidate("你", "ni", 800), candidate("好", "hao", 700)]
        XCTAssertEqual(CandidateScoring.singleCharFirst(allSingles, enabled: true).map { $0.text },
                       ["你", "好"])
        let allWords = [candidate("你好", "nihao", 800), candidate("世界", "shijie", 700)]
        XCTAssertEqual(CandidateScoring.singleCharFirst(allWords, enabled: true).map { $0.text },
                       ["你好", "世界"])
    }

    /// 混打候选带着颜色与来源方案，降级成 Candidate 再升回来会丢掉这些信息，所以分区对元素类型泛型
    func testSingleCharFirstGenericOverElement() {
        let result = CandidateScoring.singleCharFirst(["你好", "你", "世界"], enabled: true) { $0 }
        XCTAssertEqual(result, ["你", "你好", "世界"])
    }

    // MARK: - 零词频码表的通用字频叠加

    /// 超强快码真实场景：全库 weight 恒为 1 的形码码表，叠加通用字频后，
    /// 候选按真实字频而非编码字母序排序。四个编码都是 len3（码长短决胜失效），
    /// 字母序最靠后的是「的」(hzz)，但它是语料第一高频字，叠加后应排第一。
    func testZeroFreqTableOrdersByOverlaidCharFrequency() throws {
        try loadScheme(type: .direct,
                       entries: "的\thzz\t1\n是\thaa\t1\n我\thab\t1\n好\thac\t1\n",
                       codeSystem: .shape)
        let texts = engine.query(input: "h", schemeId: "s").map { $0.text }
        XCTAssertEqual(texts, ["的", "是", "我", "好"],
                       "叠加通用字频后按真实字频降序，而非编码字母序（否则是 haa 的「是」会排第一）")
    }

    /// 端到端：零词频码表叠加真实词频后，同前缀下高频词组排在生僻词组之前。
    /// 两个词都是 len4 同前缀码，码短决胜失效；字母序 jaaa < jaab 会让「斤两」靠前，
    /// 但语料里「今天」词频远高于「斤两」，叠加后应把「今天」顶到第一。
    func testZeroFreqTableOrdersPhrasesByRealWordFrequency() throws {
        let corpus = tmpDir.appendingPathComponent("corpus.dict.yaml")
        try "---\nname: c\n...\n今天\tjin tian\t90000\n斤两\tjin liang\t10\n"
            .write(to: corpus, atomically: true, encoding: .utf8)
        try loadScheme(type: .direct,
                       entries: "斤两\tjaaa\t1\n今天\tjaab\t1\n",
                       codeSystem: .shape,
                       wordFrequencyURL: corpus)
        let texts = engine.query(input: "jaa", schemeId: "s").map { $0.text }
        XCTAssertEqual(texts.first, "今天",
                       "叠加真实词频后高频词「今天」排在生僻词「斤两」之前（字母序 jaaa<jaab 会让斤两靠前）")
    }
}
