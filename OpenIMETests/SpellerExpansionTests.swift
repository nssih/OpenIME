import XCTest
@testable import OpenIMECore

// MARK: - 拼写展开层（对应外部格式的 speller）
//
// 键盘形态（26 键 / 双拼）之上再叠一层方案自己的规则：
// alphabet 之外的键整串不成立、delimiter 不属于编码、编译期去了空格的词库输入侧也要去空格。
// 不传画像（旧签名）时行为必须逐字节不变 —— 这是零破坏的底线。
//
// 简拼是「第二路」而不是替换：主路给的是精确音节展开，简拼只在侧车存在时才追加。

final class SpellerExpansionTests: XCTestCase {

    // MARK: - 辅助

    private let letters = "abcdefghijklmnopqrstuvwxyz"

    private func shapeProfile(alphabet: String? = nil,
                              delimiter: String? = nil,
                              stripSpaces: Bool = false) -> SchemeProfile {
        SchemeProfile(id: "shape", type: .direct, codeSystem: .shape,
                      alphabet: alphabet, delimiter: delimiter, stripSpacesInCode: stripSpaces)
    }

    private func phoneticProfile(alphabet: String? = nil,
                                 delimiter: String? = nil,
                                 stripSpaces: Bool = false) -> SchemeProfile {
        SchemeProfile(id: "pinyin", type: .syllable, codeSystem: .phonetic,
                      alphabet: alphabet, delimiter: delimiter, stripSpacesInCode: stripSpaces)
    }

    /// 双拼类方案（小鹤双拼）：词库里存的就是双拼码
    private func doubleSyllableProfile(alphabet: String? = nil) -> SchemeProfile {
        SchemeProfile(id: "heEr", type: .doubleSyllable, codeSystem: .phonetic, alphabet: alphabet)
    }

    // MARK: - profile = nil 时行为不变

    func testPinyin26WithoutProfileIsIdentity() {
        let expansion = InputCodeExpander.expansion("nihao", mode: .pinyin26)
        XCTAssertEqual(expansion.codes, ["nihao"])
        XCTAssertEqual(expansion.display, "nihao")
        XCTAssertTrue(expansion.isValid)
        XCTAssertTrue(expansion.abbreviations.isEmpty)
    }

    /// 26 键全拼：原样返回单一编码，保证旧行为不变
    func testExpandCodesPassesPinyin26Through() {
        XCTAssertEqual(InputCodeExpander.expandCodes("nihao", mode: .pinyin26), ["nihao"])
        XCTAssertEqual(InputCodeExpander.expandCodes("n", mode: .pinyin26), ["n"])
    }

    /// 传 nil 画像与完全不传是同一件事
    func testExplicitNilProfileMatchesLegacyCall() {
        for raw in ["nihao", "NiHao", "ni hao", "ｎｉ", "a"] {
            let legacy = InputCodeExpander.expansion(raw, mode: .pinyin26)
            let explicit = InputCodeExpander.expansion(raw, mode: .pinyin26, profile: nil)
            XCTAssertEqual(legacy.codes, explicit.codes, "\(raw) 的行为变了")
            XCTAssertEqual(legacy.display, explicit.display)
        }
    }

    /// 没有画像的方案不过滤任何键、不去任何分隔符：全角与空格原样交给词库
    func testNilProfileDoesNotNormalize() {
        XCTAssertEqual(InputCodeExpander.expansion("ｎｉ", mode: .pinyin26).codes, ["ｎｉ"])
        XCTAssertEqual(InputCodeExpander.expansion("ni hao", mode: .pinyin26).codes, ["ni hao"])
    }

    func testDoublePinyinUnaffectedByShapeProfile() {
        let profile = shapeProfile(alphabet: letters)
        // 双拼的展开由小鹤音节图决定，不该被形码画像影响
        XCTAssertEqual(InputCodeExpander.expansion("nihc", mode: .heEr).codes,
                       InputCodeExpander.expansion("nihc", mode: .heEr, profile: profile).codes)
    }

    /// 双拼码展开走的就是小鹤模块本身，展开层不做第二套解码
    func testExpandCodesRoutesHeErToDoublePinyinTable() {
        XCTAssertEqual(InputCodeExpander.expandCodes("nihc", mode: .heEr),
                       HeErDoublePinyin.shared.expand("nihc"))
    }

    func testEmptyInputAlwaysYieldsEmptyExpansion() {
        for mode in KeyboardMode.allCases {
            let expansion = InputCodeExpander.expansion("", mode: mode)
            XCTAssertTrue(expansion.codes.isEmpty, "\(mode) 的空输入不该有编码")
            XCTAssertTrue(expansion.display.isEmpty)
            XCTAssertFalse(expansion.isValid)
            XCTAssertFalse(expansion.isIdentity)
        }
    }

    // MARK: - alphabet：非法键整串不成立

    func testIllegalKeyMakesWholeInputInvalid() {
        let profile = shapeProfile(alphabet: "abcdefghij")
        let expansion = InputCodeExpander.expansion("zi", mode: .pinyin26, profile: profile)
        XCTAssertTrue(expansion.codes.isEmpty, "z 不在本方案的 alphabet 里，整串不成立")
        XCTAssertFalse(expansion.isValid)
        XCTAssertEqual(expansion.display, "zi", "内嵌编码仍显示用户敲的原文")
    }

    func testLegalKeysPassThrough() {
        let profile = shapeProfile(alphabet: letters)
        XCTAssertEqual(InputCodeExpander.expansion("tuja", mode: .pinyin26, profile: profile).codes,
                       ["tuja"])
    }

    /// alphabet 为空（OpenIME 自有包大多不写）表示不过滤
    func testEmptyAlphabetDoesNotFilter() {
        let profile = shapeProfile(alphabet: "")
        XCTAssertNil(profile.alphabetChars)
        XCTAssertEqual(InputCodeExpander.expansion("q1z", mode: .pinyin26, profile: profile).codes, ["q1z"])
    }

    /// 大小写不折叠：编译期没有 lowercase 词库编码，输入侧也不能自作主张
    func testCaseIsNotFolded() {
        let profile = shapeProfile(alphabet: letters + letters.uppercased())
        XCTAssertEqual(InputCodeExpander.normalizedCode("TuJa", profile: profile), "TuJa")
        XCTAssertEqual(InputCodeExpander.expansion("TuJa", mode: .pinyin26, profile: profile).codes, ["TuJa"])
    }

    // MARK: - delimiter 与空格

    func testDelimiterIsRemovedFromCode() {
        let profile = shapeProfile(alphabet: letters + "'", delimiter: "'")
        XCTAssertEqual(InputCodeExpander.normalizedCode("tu'ja", profile: profile), "tuja")
        XCTAssertEqual(InputCodeExpander.expansion("tu'ja", mode: .pinyin26, profile: profile).codes, ["tuja"])
    }

    /// 雾凇的 `ni hao` 编译期去了空格，输入侧必须同样去掉才对得上
    func testSpaceStrippedWhenCompilerStrippedSpaces() {
        let profile = phoneticProfile(alphabet: letters, stripSpaces: true)
        XCTAssertEqual(InputCodeExpander.normalizedCode("ni hao", profile: profile), "nihao")
        XCTAssertTrue(profile.stripSpacesInCode)
    }

    /// 词库编码里留着空格的方案（形码的分段写法），空格当分隔符看
    func testSpaceRemovedWhenDeclaredAsDelimiter() {
        let profile = shapeProfile(alphabet: letters + " ", delimiter: " ")
        XCTAssertEqual(InputCodeExpander.normalizedCode("tu ja", profile: profile), "tuja")
        XCTAssertFalse(profile.stripSpacesInCode)
    }

    /// 既没去空格也没把空格当分隔符，而 alphabet 又不含空格 ⇒ 整串不成立
    func testSpaceIllegalWhenAlphabetExcludesIt() {
        let profile = shapeProfile(alphabet: letters)
        XCTAssertNil(InputCodeExpander.normalizedCode("tu ja", profile: profile))
        XCTAssertTrue(InputCodeExpander.expansion("tu ja", mode: .pinyin26, profile: profile).codes.isEmpty)
    }

    /// 全是分隔符的输入不算编码
    func testDelimiterOnlyInputIsInvalid() {
        let profile = shapeProfile(alphabet: letters + "'", delimiter: "'")
        XCTAssertNil(InputCodeExpander.normalizedCode("'''", profile: profile))
    }

    func testFullWidthIsFolded() {
        let profile = shapeProfile(alphabet: letters)
        XCTAssertEqual(InputCodeExpander.normalizedCode("ｎｉｈａｏ", profile: profile), "nihao")
        XCTAssertEqual(InputCodeExpander.halfWidth("Ａ"), "A")
        XCTAssertEqual(InputCodeExpander.halfWidth("１"), "1")
        XCTAssertEqual(InputCodeExpander.halfWidth("你"), "你", "非全角 ASCII 原样返回")
    }

    func testNormalizedCodeWithoutProfile() {
        XCTAssertNil(InputCodeExpander.normalizedCode("", profile: nil))
        XCTAssertEqual(InputCodeExpander.normalizedCode("abc", profile: nil), "abc")
        XCTAssertEqual(InputCodeExpander.normalizedCode("ｎｉ", profile: nil), "ｎｉ",
                       "没有画像就不做任何归一")
    }

    // MARK: - 内嵌显示码与双拼码合法性

    /// 内嵌编码给用户看的是还原后的拼音，不是键面码
    func testInlineDisplayShowsResolvedPinyin() {
        // 小鹤双拼键盘配全拼词库：内嵌显示还原后的全拼
        XCTAssertEqual(InputCodeExpander.expansion("nihc", mode: .heEr).display, "nihao")
        // 26 键全拼：内嵌码就是输入码本身
        XCTAssertEqual(InputCodeExpander.expansion("nihao", mode: .pinyin26).display, "nihao")
    }

    func testIllegalDoublePinyinCodeIsRejected() {
        // “zhongguo” 不是合法的小鹤双拼码：不应退回全拼查询，
        // 否则双拼键盘会退化成 26 键全拼
        let expansion = InputCodeExpander.expansion("zhongguo", mode: .heEr)
        XCTAssertTrue(expansion.codes.isEmpty, "非法双拼码应当没有展开结果")
        XCTAssertTrue(expansion.display.isEmpty)
        XCTAssertFalse(expansion.isValid)
    }

    func testLegalDoublePinyinCodeIsAccepted() {
        // 小鹤双拼：ni + hao = nihc
        XCTAssertTrue(InputCodeExpander.expansion("nihc", mode: .heEr).isValid)
        // 未打完一个音节（奇数键）也应给出前缀
        XCTAssertTrue(InputCodeExpander.expansion("nih", mode: .heEr).isValid)
    }

    // MARK: - 简拼第二路

    /// 假装一份简拼侧车：键是简拼前缀，值是侧车里的词（ExtrasIndex 没建时根本不构造这个闭包）
    private func sidecar(_ table: [String: [(word: String, freq: Int)]])
        -> (String, Int) -> [(word: String, freq: Int)] {
        { prefix, limit in Array((table[prefix] ?? []).prefix(limit)) }
    }

    /// 记下查询参数的侧车（返回的闭包会逃逸出本次调用，inout 捕获不了，用个小盒子）
    private final class Calls {
        var seen: [(prefix: String, limit: Int)] = []
    }

    private func recordingSidecar(_ box: Calls) -> (String, Int) -> [(word: String, freq: Int)] {
        { prefix, limit in
            box.seen.append((prefix, limit))
            return []
        }
    }

    private let abbrTable = ["zhrmghg": [(word: "中华人民共和国", freq: 100)]]

    /// 侧车命中时简拼作为第二路带出来，主路（精确音节展开）一点不受影响
    func testAbbreviationIsSecondPathNotReplacement() {
        let profile = phoneticProfile(alphabet: letters)
        let expansion = InputCodeExpander.expansion("zhrmghg", mode: .pinyin26,
                                                    profile: profile,
                                                    abbreviations: sidecar(abbrTable))
        XCTAssertEqual(expansion.codes, ["zhrmghg"], "主路仍是精确展开")
        XCTAssertEqual(expansion.abbreviations.map { $0.word }, ["中华人民共和国"])
    }

    /// 简拼只在音码方案上才有意义：形码的短码本来就是正式编码，不是简拼
    func testAbbreviationSkippedForShapeScheme() {
        let profile = shapeProfile(alphabet: letters)
        let expansion = InputCodeExpander.expansion("zhrmghg", mode: .pinyin26,
                                                    profile: profile,
                                                    abbreviations: sidecar(abbrTable))
        XCTAssertTrue(expansion.abbreviations.isEmpty)
        XCTAssertFalse(expansion.codes.isEmpty, "形码的主路照常")
    }

    /// 没有画像也没有简拼：音码与否判不出来，整条路完全跳过
    func testAbbreviationSkippedWithoutProfile() {
        let expansion = InputCodeExpander.expansion("zhrmghg", mode: .pinyin26,
                                                    abbreviations: sidecar(abbrTable))
        XCTAssertTrue(expansion.abbreviations.isEmpty)
        XCTAssertEqual(expansion.codes, ["zhrmghg"])
    }

    /// 没有侧车的方案连查询闭包都不构造，零成本
    func testNoSidecarMeansNoLookup() {
        let profile = phoneticProfile(alphabet: letters)
        let expansion = InputCodeExpander.expansion("zhrmghg", mode: .pinyin26,
                                                    profile: profile, abbreviations: nil)
        XCTAssertTrue(expansion.abbreviations.isEmpty)
    }

    /// 上限由展开层给（简拼只是补位，给多了会把真正想打的词挤到后面）
    func testAbbreviationLimitIsPassedToLookup() {
        let profile = phoneticProfile(alphabet: letters)
        let box = Calls()
        _ = InputCodeExpander.expansion("zh", mode: .pinyin26, profile: profile,
                                        abbreviations: recordingSidecar(box))
        XCTAssertEqual(box.seen.count, 1)
        XCTAssertEqual(box.seen.first?.prefix, "zh")
        XCTAssertEqual(box.seen.first?.limit, InputCodeExpander.abbreviationLimit)
    }

    /// 侧车一条都没命中时不产生简拼候选
    func testAbbreviationWithoutHitsIsEmpty() {
        let profile = phoneticProfile(alphabet: letters)
        let expansion = InputCodeExpander.expansion("nihao", mode: .pinyin26,
                                                    profile: profile,
                                                    abbreviations: sidecar(abbrTable))
        XCTAssertTrue(expansion.abbreviations.isEmpty)
    }

    // MARK: - 恒等直通（isIdentity）
    //
    // 双拼类方案配小鹤双拼键盘时，键面码就是词库码：还原成全拼反而对不上码表，
    // 这个组合以前永远空候选。26 键本来就是恒等映射，两条路共用同一个判定。

    func testPinyin26IsAlwaysIdentity() {
        let profiles: [SchemeProfile?] = [nil, shapeProfile(), phoneticProfile(), doubleSyllableProfile()]
        for profile in profiles {
            XCTAssertTrue(InputCodeExpander.expansion("nihao", mode: .pinyin26, profile: profile).isIdentity,
                          "26 键在任何方案下都是恒等直通")
        }
    }

    func testHeErWithDoubleSyllableProfileIsIdentity() {
        let expansion = InputCodeExpander.expansion("uijn", mode: .heEr,
                                                    profile: doubleSyllableProfile(alphabet: letters))
        XCTAssertTrue(expansion.isIdentity)
        XCTAssertEqual(expansion.codes, ["uijn"], "双拼码原样交给词库，不查小鹤表还原")
        XCTAssertEqual(expansion.display, "uijn", "内嵌编码显示用户敲的原文")
        XCTAssertEqual(expansion.codes.count, 1, "恒等直通只有一条码")
    }

    /// 恒等直通仍然叠方案自己的 speller 规则：非法键整串不成立
    func testHeErIdentityStillHonoursAlphabet() {
        let expansion = InputCodeExpander.expansion("zi", mode: .heEr,
                                                    profile: doubleSyllableProfile(alphabet: "abcdefghij"))
        XCTAssertTrue(expansion.codes.isEmpty)
        XCTAssertFalse(expansion.isValid)
        XCTAssertFalse(expansion.isIdentity, "不成立的输入不能算恒等直通")
    }

    /// 简拼第二路在恒等直通下照旧追加（双拼方案也是音码，短码当简拼看同样成立）
    func testHeErIdentityStillAppendsAbbreviations() {
        let box = Calls()
        let expansion = InputCodeExpander.expansion("zhrmghg", mode: .heEr,
                                                    profile: doubleSyllableProfile(alphabet: letters),
                                                    abbreviations: recordingSidecar(box))
        XCTAssertTrue(expansion.isIdentity)
        XCTAssertEqual(box.seen.first?.prefix, "zhrmghg")
        XCTAssertEqual(box.seen.first?.limit, InputCodeExpander.abbreviationLimit)
    }

    /// 回归锁定：全拼方案配小鹤双拼键盘的路径逐字节不变（仍还原成全拼、不是恒等）
    func testHeErWithFullPinyinProfileStillRestoresFullPinyin() {
        let expansion = InputCodeExpander.expansion("nihc", mode: .heEr,
                                                    profile: phoneticProfile(alphabet: letters))
        XCTAssertFalse(expansion.isIdentity)
        XCTAssertEqual(expansion.codes, ["nihao"], "全拼词库存的是全拼，双拼码必须先还原")
    }

    /// 展开层与运行期 / 键盘侧共用同一份判定，两处不会走差
    func testIsIdentityDecodingMatrix() {
        let profiles: [SchemeProfile?] = [nil, shapeProfile(), phoneticProfile(), doubleSyllableProfile()]
        for profile in profiles {
            XCTAssertTrue(InputCodeExpander.isIdentityDecoding(mode: .pinyin26, profile: profile))
        }
        XCTAssertTrue(InputCodeExpander.isIdentityDecoding(mode: .heEr, profile: doubleSyllableProfile()))
        XCTAssertFalse(InputCodeExpander.isIdentityDecoding(mode: .heEr, profile: phoneticProfile()))
        XCTAssertFalse(InputCodeExpander.isIdentityDecoding(mode: .heEr, profile: shapeProfile()))
        XCTAssertFalse(InputCodeExpander.isIdentityDecoding(mode: .heEr, profile: nil),
                       "画像缺失时不假定双拼，按还原全拼处理")
    }
}
