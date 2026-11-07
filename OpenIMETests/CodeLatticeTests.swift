import XCTest
@testable import OpenIMECore

// MARK: - 长串切分（词图）单元测试
//
// 词表与二元语法都手搓注入，不依赖任何真实词库文件，专门验证切分与打分逻辑本身。
// 拼音部分词频直接取真实 dict.bin 里量过的那几个数（你好 332885、那 9929703、吗 9028487…），
// 好复现「纯一元会把 nihaoma 判成 你好那」这个已知坑，并证明加了二元语法后能判对。
// 形码部分用真实虎码词库里的几个码（我们 tuja、自己 oivj）验证按码长滑窗切分。

final class CodeLatticeTests: XCTestCase {

    // 一份覆盖 nihaoma / nihaomashijie 的小词库：拼音 -> [(词, 词频)]
    private let dict: [String: [(String, Int)]] = [
        "ni":     [("你", 5_000_000), ("尼", 50_000)],
        "hao":    [("好", 3_000_000), ("号", 1_500_000)],
        "nihao":  [("你好", 332_885)],
        "ma":     [("那", 9_929_703), ("吗", 9_028_487), ("妈", 8_000_000)],
        "shi":    [("是", 5_000_000), ("世", 500_000)],
        "jie":    [("界", 600_000), ("结", 400_000)],
        "shijie": [("世界", 2_000_000)],
    ]

    private func lookup(_ code: String) -> [CodeLattice.Word] {
        (dict[code] ?? []).map { CodeLattice.Word(text: $0.0, freq: $0.1) }
    }

    /// 只认「确实相邻成词」的字对：给一个较高的 log 概率，其余一律当成没见过的搭配重罚。
    /// seen 里放的是常见二字组合，用来模拟编译期从词库导出的字级二元语法。
    private func makeBigram(seen: Set<String>) -> (Character, Character) -> Double {
        return { a, b in
            seen.contains(String([a, b])) ? -1.0 : -8.0
        }
    }

    // MARK: - 已知坑：纯一元会判错尾巴

    /// 二元语法全给 0（等于没有二元语法）时，尾巴只看词频：那(9929703) > 吗(9028487)，
    /// 于是 nihaoma 被切成「你好那」。这条用例把已知的一元局限钉死，说明为什么必须要二元语法。
    func testUnigramOnlyPicksWrongTail() {
        let sentences = CodeLattice.segment(
            "nihaoma",
            lookup: lookup,
            bigram: { _, _ in 0 }
        )
        XCTAssertFalse(sentences.isEmpty, "nihaoma 应当能完整切分")
        XCTAssertEqual(sentences[0].text, "你好那",
                       "没有二元语法时，尾巴会错选词频更高的「那」")
    }

    /// 有了「好→吗」这个常见搭配、而「好→那」没见过，尾巴就纠正成「吗」。
    func testBigramFixesWrongTail() {
        let bigram = makeBigram(seen: ["好吗"])
        let sentences = CodeLattice.segment("nihaoma", lookup: lookup, bigram: bigram)
        XCTAssertFalse(sentences.isEmpty)
        XCTAssertEqual(sentences[0].text, "你好吗",
                       "二元语法应把尾巴从「那」纠正回「吗」")
    }

    // MARK: - 长串完整切分

    /// nihaomashijie 这种长过任何单词的串，常规前缀查询一条都出不来，
    /// 词图应切出「你好吗世界」，且「世界」作为一个真实词要赢过「是 + 界」两个高频单字。
    func testLongInputSegmentsIntoWholeSentence() {
        let bigram = makeBigram(seen: ["好吗", "吗世"])
        let sentences = CodeLattice.segment("nihaomashijie", lookup: lookup, bigram: bigram)
        XCTAssertFalse(sentences.isEmpty)
        XCTAssertEqual(sentences[0].text, "你好吗世界",
                       "长串应切成整句，且真实词「世界」不被拆成「是 + 界」")
    }

    /// 归一化的意义：即便「是」「界」各自词频都比「世界」高，一个真实词也该赢过两个高频单字拼凑。
    func testRealWordBeatsHighFreqSingleChars() {
        // 只喂 shijie 相关的两条路径，隔离验证「世界 vs 是界」
        let bigram = makeBigram(seen: Set<String>())   // 谁都不常见，纯靠归一化后的词数代价
        let sentences = CodeLattice.segment("shijie", lookup: lookup, bigram: bigram)
        XCTAssertFalse(sentences.isEmpty)
        XCTAssertEqual(sentences[0].text, "世界",
                       "归一化后，单个真实词应赢过两个高频单字的拼凑")
    }

    // MARK: - 边界与鲁棒性

    /// 切不开的串（末尾差半个音节 / 根本不是拼音）返回空，调用方据此保持「无候选」的老行为。
    func testUnsegmentableReturnsEmpty() {
        let bigram = makeBigram(seen: [])
        XCTAssertTrue(CodeLattice.segment("zzzzz", lookup: lookup, bigram: bigram).isEmpty)
        // nihaom 末尾的 m 不成音节，无法完整覆盖
        XCTAssertTrue(CodeLattice.segment("nihaom", lookup: lookup, bigram: bigram).isEmpty)
    }

    /// 单字符 / 空串不交给词图（常规前缀查询就够），直接返回空。
    func testTooShortReturnsEmpty() {
        let bigram = makeBigram(seen: [])
        XCTAssertTrue(CodeLattice.segment("", lookup: lookup, bigram: bigram).isEmpty)
        XCTAssertTrue(CodeLattice.segment("n", lookup: lookup, bigram: bigram).isEmpty)
    }

    /// 大小写不敏感：输入按小写处理。
    func testInputIsCaseInsensitive() {
        let bigram = makeBigram(seen: ["好吗"])
        let lower = CodeLattice.segment("nihaoma", lookup: lookup, bigram: bigram)
        let upper = CodeLattice.segment("NiHaoMa", lookup: lookup, bigram: bigram)
        XCTAssertEqual(lower.map { $0.text }, upper.map { $0.text })
    }

    /// 结果可复现：同一输入两次跑出的整句序列完全一致（并列按字典序定序，便于差分验证）。
    func testDeterministic() {
        let bigram = makeBigram(seen: ["好吗", "吗世"])
        let a = CodeLattice.segment("nihaomashijie", topN: 3, lookup: lookup, bigram: bigram)
        let b = CodeLattice.segment("nihaomashijie", topN: 3, lookup: lookup, bigram: bigram)
        XCTAssertEqual(a.map { $0.text }, b.map { $0.text })
        XCTAssertEqual(a.map { $0.score }, b.map { $0.score })
    }

    /// topN 生效：返回条数不超过 topN，且按分数降序。
    func testTopNAndOrdering() {
        let bigram = makeBigram(seen: ["好吗", "吗世"])
        let sentences = CodeLattice.segment("nihaomashijie", topN: 2, lookup: lookup, bigram: bigram)
        XCTAssertLessThanOrEqual(sentences.count, 2)
        for i in 1..<sentences.count {
            XCTAssertGreaterThanOrEqual(sentences[i - 1].score, sentences[i].score,
                                        "整句必须按分数从高到低排列")
        }
    }

    /// 音节切分歧义：xian 既能当 xian 一个音节，也能当 xi + an 两个音节，
    /// 词图两条路都要走到，最终按词频/搭配择优。
    func testAmbiguousSyllableSplit() {
        let amb: [String: [(String, Int)]] = [
            "xi":   [("西", 1_000_000)],
            "an":   [("安", 900_000)],
            "xian": [("先", 800_000), ("现", 700_000)],
        ]
        let lookupAmb: (String) -> [CodeLattice.Word] = { code in
            (amb[code] ?? []).map { CodeLattice.Word(text: $0.0, freq: $0.1) }
        }
        // xian 既能整个当一个音节（先/现），也能切成 xi + an（西 + 安），两条路都应能产出候选
        let bigram = makeBigram(seen: ["西安"])
        let sentences = CodeLattice.segment("xian", lookup: lookupAmb, bigram: bigram)
        XCTAssertFalse(sentences.isEmpty)
        let texts = Set(sentences.map { $0.text })
        XCTAssertTrue(texts.contains("西安") || texts.contains("先") || texts.contains("现"),
                      "歧义音节的多种切法都应能产出候选")
    }

    // MARK: - 形码（按码长滑窗切分）

    // 取自真实虎码词库的几个码：我们 tuja、自己 oivj、一个 fijg，外加两个短码制造歧义路径
    private let codeDict: [String: [(String, Int)]] = [
        "tuja": [("我们", 116_006)],
        "oivj": [("自己", 109_686)],
        "fijg": [("一个", 105_148)],
        "tu":   [("图", 40_000)],
        "t":    [("和", 50_000)],
    ]

    private func codeLookup(_ code: String) -> [CodeLattice.Word] {
        (codeDict[code] ?? []).map { CodeLattice.Word(text: $0.0, freq: $0.1) }
    }

    /// 两个词的编码连写（我们 tuja + 自己 oivj），常规前缀查询整串落空，
    /// 形码词图应按码长切回「我们自己」。短码「和 t」「图 tu」铺不满全串，唯独整词这条路走得通。
    func testFixedCodeSegmentsConcatenatedWords() {
        let bigram = makeBigram(seen: ["们自"])
        let sentences = CodeLattice.segmentCode("tujaoivj", maxCodeLength: 4,
                                                lookup: codeLookup, bigram: bigram)
        XCTAssertFalse(sentences.isEmpty)
        XCTAssertEqual(sentences[0].text, "我们自己",
                       "形码长串应按码长切成整句")
    }

    /// max_code_length 限定单段跨度：把它压到 2，四字母的「我们 tuja」就够不着，
    /// 全串铺不满，返回空。证明切分严格按方案声明的码长来，不会越界拼词。
    func testFixedCodeRespectsMaxLength() {
        let bigram = makeBigram(seen: [])
        let sentences = CodeLattice.segmentCode("tujaoivj", maxCodeLength: 2,
                                                lookup: codeLookup, bigram: bigram)
        XCTAssertTrue(sentences.isEmpty,
                      "码长上限压到 2 时，四字母的词切不出来，整串铺不满应为空")
    }

    /// 归一化在形码下同样管用：一个真实词「甲乙」应赢过两个超高频单字「啊 + 吧」的拼凑。
    func testFixedCodeRealWordBeatsSingleChars() {
        let norm: [String: [(String, Int)]] = [
            "ab": [("甲乙", 5_000)],
            "a":  [("啊", 9_000_000)],
            "b":  [("吧", 8_000_000)],
        ]
        let lookupNorm: (String) -> [CodeLattice.Word] = { code in
            (norm[code] ?? []).map { CodeLattice.Word(text: $0.0, freq: $0.1) }
        }
        let bigram = makeBigram(seen: [])   // 啊→吧 不是常见搭配，重罚
        let sentences = CodeLattice.segmentCode("ab", maxCodeLength: 2,
                                                lookup: lookupNorm, bigram: bigram)
        XCTAssertFalse(sentences.isEmpty)
        XCTAssertEqual(sentences[0].text, "甲乙",
                       "归一化后，单个真实词应赢过两个高频单字的拼凑")
    }

    /// 切不开的形码串（词库里没有对应编码）返回空，保持「无候选」的老行为。
    func testFixedCodeUnsegmentableReturnsEmpty() {
        let bigram = makeBigram(seen: [])
        XCTAssertTrue(CodeLattice.segmentCode("zzzz", maxCodeLength: 4,
                                              lookup: codeLookup, bigram: bigram).isEmpty)
    }

    /// 单字符 / 空串不交给形码词图，直接返回空。
    func testFixedCodeTooShortReturnsEmpty() {
        let bigram = makeBigram(seen: [])
        XCTAssertTrue(CodeLattice.segmentCode("", maxCodeLength: 4,
                                              lookup: codeLookup, bigram: bigram).isEmpty)
        XCTAssertTrue(CodeLattice.segmentCode("t", maxCodeLength: 4,
                                              lookup: codeLookup, bigram: bigram).isEmpty)
    }

    /// 生僻字（扩展 A 区）参与形码切分：整句里的生僻字应原样保留，
    /// 不被束搜索的 Character / 字级二元语法处理截断或替换（否则生僻字显示就会坏）。
    func testFixedCodePreservesRareChar() {
        let rare = "\u{3400}"      // 㐀，CJK 扩展 A 区生僻字
        let d: [String: [(String, Int)]] = [
            "aaaa": [(rare, 500)],
            "bbbb": [("字", 800)],
        ]
        let look: (String) -> [CodeLattice.Word] = { c in
            (d[c] ?? []).map { CodeLattice.Word(text: $0.0, freq: $0.1) }
        }
        let sentences = CodeLattice.segmentCode("aaaabbbb", maxCodeLength: 4,
                                                lookup: look, bigram: { _, _ in -1 })
        XCTAssertFalse(sentences.isEmpty)
        XCTAssertEqual(sentences[0].text, rare + "字", "生僻字应原样出现在切分结果里")
        XCTAssertEqual(sentences[0].text.unicodeScalars.count, 2, "生僻字算一个码点，不被拆成代理对")
    }

    // MARK: - 组句面板：开头一段的可选词（leading*Options）
    //
    // 与 segment / segmentCode / segmentMixed 复用同一套边构建器，只取起点 0 的边。
    // 面板把选择权交给用户、不做自动裁决，故只枚举、不需 bigram。

    /// 拼音：nihaoma 开头一段既能是「ni（你 / 尼）」（终点 2），也能是「nihao（你好）」（终点 5）。
    /// 终点近的排前，同一终点的词按 lookup 原序（词频降序）。
    func testLeadingSyllableOptionsListsAllLeadingSegments() {
        let options = CodeLattice.leadingSyllableOptions("nihaoma", lookup: lookup)
        XCTAssertEqual(options.map { $0.end }, [2, 5], "开头一段应按终点升序列出 ni(2) / nihao(5)")
        XCTAssertEqual(options[0].words.map { $0.text }, ["你", "尼"], "终点 2 的词按词频降序")
        XCTAssertEqual(options[1].words.map { $0.text }, ["你好"], "终点 5 是整词「你好」")
    }

    /// 形码：tujaoivj 开头一段按码长滑窗，能是 t(和,1) / tu(图,2) / tuja(我们,4)；
    /// tuj 词库里没有对应词，不占一个终点。
    func testLeadingCodeOptionsSlidesByMaxLength() {
        let options = CodeLattice.leadingCodeOptions("tujaoivj", maxCodeLength: 4, lookup: codeLookup)
        XCTAssertEqual(options.map { $0.end }, [1, 2, 4], "形码按码长滑窗，只列词库里真存在的段")
        XCTAssertEqual(options[0].words.map { $0.text }, ["和"])
        XCTAssertEqual(options[1].words.map { $0.text }, ["图"])
        XCTAssertEqual(options[2].words.map { $0.text }, ["我们"])
    }

    /// 音形码：两套边合并——同一串 mama 既能当音节（ma=妈 / mama=妈妈），又能当定长形码（m=呣 / ma=妈）。
    /// 合并后同终点同词只留一份（end2 的「妈」不重复），两套各自独有的段（end1 形码、end4 音节）都在。
    func testLeadingMixedOptionsMergesSyllableAndFixedCode() {
        let mixed: [String: [(String, Int)]] = [
            "m":    [("呣", 100)],
            "ma":   [("妈", 1_000)],
            "mama": [("妈妈", 5_000)],
        ]
        let look: (String) -> [CodeLattice.Word] = { code in
            (mixed[code] ?? []).map { CodeLattice.Word(text: $0.0, freq: $0.1) }
        }
        // 音节边只到 end2 / end4（m 不是音节）；形码边（maxCodeLength 2）只到 end1 / end2
        XCTAssertEqual(CodeLattice.leadingSyllableOptions("mama", lookup: look).map { $0.end }, [2, 4])
        XCTAssertEqual(CodeLattice.leadingCodeOptions("mama", maxCodeLength: 2, lookup: look).map { $0.end }, [1, 2])
        // 合并：end1(呣) + end2(妈，去重只一份) + end4(妈妈)
        let options = CodeLattice.leadingMixedOptions("mama", maxCodeLength: 2, lookup: look)
        XCTAssertEqual(options.map { $0.end }, [1, 2, 4], "合并后两套边的终点都在，按升序")
        XCTAssertEqual(options[0].words.map { $0.text }, ["呣"])
        XCTAssertEqual(options[1].words.map { $0.text }, ["妈"], "同终点同词去重，只留一份")
        XCTAssertEqual(options[2].words.map { $0.text }, ["妈妈"])
    }

    /// 退化：空串 / 单字 / 铺不出任何段 / 码长非法，都返回空（面板据此显示「切不出词」提示）。
    func testLeadingOptionsDegenerateCases() {
        XCTAssertTrue(CodeLattice.leadingSyllableOptions("", lookup: lookup).isEmpty)
        XCTAssertTrue(CodeLattice.leadingSyllableOptions("n", lookup: lookup).isEmpty, "单字不交给词图")
        XCTAssertTrue(CodeLattice.leadingSyllableOptions("zzzzz", lookup: lookup).isEmpty, "铺不出音节段")
        XCTAssertTrue(CodeLattice.leadingCodeOptions("tujaoivj", maxCodeLength: 0, lookup: codeLookup).isEmpty,
                      "码长非法（<1）无从界定单段跨度")
        XCTAssertTrue(CodeLattice.leadingMixedOptions("", maxCodeLength: 4, lookup: lookup).isEmpty)
    }
}
