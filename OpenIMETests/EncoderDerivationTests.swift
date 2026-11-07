import XCTest
@testable import OpenIMECore

// MARK: - encoder 自动编码（外部格式的取码公式）
//
// 超强快码的词组连编码都不写，整句诗直接扔进词库，全靠 encoder 从单字码派生。
// 这套派生必须在编译期做完（运行期只管查），且宁可不派生也不能写半截码 ——
// 任一个字缺码、或公式要的位置超出实际码长，都整条放弃并记进报告。

final class EncoderDerivationTests: XCTestCase {

    private var tmpDir: URL!

    override func setUp() {
        super.setUp()
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("EncoderTests_\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmpDir)
        tmpDir = nil
        super.tearDown()
    }

    // MARK: - 辅助

    @discardableResult
    private func write(_ content: String, name: String = "enc.dict.yaml") -> URL {
        let url = tmpDir.appendingPathComponent(name)
        try! content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func outputURL(_ name: String = "out.bin") -> URL {
        tmpDir.appendingPathComponent(name)
    }

    private func entries(_ binURL: URL, code: String) throws -> [Candidate] {
        try DictReader(binURL: binURL).queryExact(code: code)
    }

    private func rule(lengthEqual: Int? = nil,
                      range: (Int, Int)? = nil,
                      formula: String) -> DictEncoder.Rule {
        var rule = DictEncoder.Rule()
        rule.lengthEqual = lengthEqual
        rule.rangeMin = range?.0
        rule.rangeMax = range?.1
        rule.formula = formula
        return rule
    }

    // MARK: - 取码公式语义

    /// 大写字母 = 词里第几个字，小写字母 = 该字编码的第几位
    func testFormulaTwoCharWordTakesFirstTwoOfEach() {
        // 虎码：我们 tuja + 自己 oivj → tuoi
        XCTAssertEqual(CodeFormula.derive(formula: "AaAbBaBb", charCodes: ["tuja", "oivj"]), "tuoi")
    }

    func testFormulaMultiCharWordTakesFirstThreePlusLast() {
        XCTAssertEqual(CodeFormula.derive(formula: "AaBaCaZa",
                                              charCodes: ["abcd", "efgh", "ijkl", "mnop"]), "aeim")
    }

    func testFormulaThreeCharWordTakesFirstTwoPlusLast() {
        XCTAssertEqual(CodeFormula.derive(formula: "AaAbBaCa",
                                              charCodes: ["abcd", "efgh", "ijkl"]), "abei")
    }

    /// z = 该字编码的末位
    func testFormulaLowercaseZIsLastPosition() {
        XCTAssertEqual(CodeFormula.derive(formula: "AaZz", charCodes: ["abc", "xyz"]), "az")
    }

    /// Z = 末字（二字词里就是第二个字）
    func testFormulaUppercaseZIsLastChar() {
        XCTAssertEqual(CodeFormula.derive(formula: "Za", charCodes: ["abc", "xyz"]), "x")
    }

    func testFormulaOutOfRangeReturnsNil() {
        // 公式要第二个字（B），词里只有一个字
        XCTAssertNil(CodeFormula.derive(formula: "AaBb", charCodes: ["abcd"]))
        // 公式要该字的第三位，码只有两位
        XCTAssertNil(CodeFormula.derive(formula: "Ac", charCodes: ["ab"]))
    }

    func testFormulaWithoutLeadingUppercaseReturnsNil() {
        // 小写字母出现在任何大写字母之前：不知道要取哪个字，整条放弃
        XCTAssertNil(CodeFormula.derive(formula: "aAb", charCodes: ["abcd"]))
    }

    func testFormulaEmptyInputsReturnNil() {
        XCTAssertNil(CodeFormula.derive(formula: "", charCodes: ["abcd"]))
        XCTAssertNil(CodeFormula.derive(formula: "Aa", charCodes: []))
    }

    // MARK: - 规则匹配

    func testRuleLengthEqualMatchesExactly() {
        let r = rule(lengthEqual: 2, formula: "AaAb")
        XCTAssertTrue(r.matches(wordLength: 2))
        XCTAssertFalse(r.matches(wordLength: 1))
        XCTAssertFalse(r.matches(wordLength: 3))
    }

    func testRuleLengthInRangeIsInclusive() {
        let r = rule(range: (4, 300), formula: "AaBaCaZa")
        XCTAssertTrue(r.matches(wordLength: 4))
        XCTAssertTrue(r.matches(wordLength: 300))
        XCTAssertFalse(r.matches(wordLength: 3))
        XCTAssertFalse(r.matches(wordLength: 301))
    }

    func testRuleWithoutConditionNeverMatches() {
        XCTAssertFalse(rule(formula: "Aa").matches(wordLength: 2))
    }

    func testFirstMatchingRuleWins() {
        var encoder = DictEncoder()
        encoder.rules = [rule(lengthEqual: 2, formula: "AaAb"),
                         rule(range: (2, 99), formula: "ZzZz")]
        XCTAssertEqual(encoder.rule(forWordLength: 2)?.formula, "AaAb", "按序匹配，第一条命中的生效")
        XCTAssertEqual(encoder.rule(forWordLength: 5)?.formula, "ZzZz")
        XCTAssertNil(DictEncoder().rule(forWordLength: 2))
    }

    func testExcludePatternsArePrecompiled() {
        var encoder = DictEncoder()
        encoder.excludePatterns = ["^[iuv].*$", "[ao]$", "["]   // 第三个是坏正则
        let compiled = encoder.compiledExcludePatterns()
        XCTAssertEqual(compiled.count, 2, "编不出来的正则丢掉，不能让整个编译崩掉")
        XCTAssertTrue(compiled.contains { $0.firstMatch(in: "ipinyin", range: NSRange(location: 0, length: 7)) != nil })
    }

    // MARK: - 头部里的 encoder 块

    func testHeaderParserReadsEncoderBlock() {
        let yaml = """
---
name: cqkm
columns:
  - text
  - code
encoder:
  exclude_patterns:
    - "^[iuv].*$"
    - "[ao]$"
  rules:
    - length_equal: 2
      formula: AaAbBaBb
    - length_equal: 3
      formula: AaBaCaZa
    - length_in_range: [4, 300]
      formula: AaBaCaZa
...
今	jafm
"""
        let header = DictHeaderParser.parse(yaml).header
        let encoder = header.encoder
        XCTAssertNotNil(encoder)
        XCTAssertEqual(encoder?.excludePatterns, ["^[iuv].*$", "[ao]$"], "引号要剥掉")
        XCTAssertEqual(encoder?.rules.count, 3)
        XCTAssertEqual(encoder?.rules[0].lengthEqual, 2)
        XCTAssertEqual(encoder?.rules[0].formula, "AaAbBaBb")
        XCTAssertEqual(encoder?.rules[1].lengthEqual, 3)
        XCTAssertEqual(encoder?.rules[2].rangeMin, 4)
        XCTAssertEqual(encoder?.rules[2].rangeMax, 300)
        XCTAssertEqual(encoder?.rule(forWordLength: 7)?.formula, "AaBaCaZa")
        // 头部行不进词条区，`今\tjafm` 才是词条
        XCTAssertEqual(DictHeaderParser.parse(yaml).dataStartIndex, 17)
    }

    func testHeaderWithoutEncoderHasNoEncoder() {
        XCTAssertNil(DictHeaderParser.parse("---\ncolumns:\n  - text\n  - code\n...\n").header.encoder)
    }

    // MARK: - 编译期派生

    /// 二字词：词组不写码，靠 length_equal: 2 的公式从单字码派生
    func testTwoCharPhraseCodeIsDerived() throws {
        let yaml = """
---
name: cqkm
columns:
  - text
  - code
  - weight
encoder:
  rules:
    - length_equal: 2
      formula: AaAbBaBb
...
今	jafm	100
天	gd	90
今天		80
"""
        let out = outputURL()
        let (_, report) = try DictCompiler.compileMultipleWithReport(
            yamlURLs: [write(yaml)], outputURL: out, schemeType: .direct)
        XCTAssertEqual(report.derivedCodes, 1)
        XCTAssertEqual(report.totalParsed, 3)
        XCTAssertEqual(report.totalSkipped, 0)
        XCTAssertEqual(try entries(out, code: "jagd").map { $0.text }, ["今天"],
                       "今(jafm) 取 ja + 天(gd) 取 gd → jagd")
    }

    /// 长句走 length_in_range，且公式里的 Z 指末字
    func testLongPhraseCodeIsDerivedByRange() throws {
        let yaml = """
---
columns:
  - text
  - code
  - weight
encoder:
  rules:
    - length_equal: 2
      formula: AaAbBaBb
    - length_in_range: [4, 300]
      formula: AaBaCaZa
...
今	jafm	100
天	gd	90
很	tt	80
好	vv	70
今天很好		60
"""
        let out = outputURL()
        let (_, report) = try DictCompiler.compileMultipleWithReport(
            yamlURLs: [write(yaml)], outputURL: out, schemeType: .direct)
        XCTAssertEqual(report.derivedCodes, 1)
        XCTAssertEqual(try entries(out, code: "jgtv").map { $0.text }, ["今天很好"],
                       "首三字各取首码 + 末字首码")
    }

    /// 没有匹配词长的规则就不派生（三字词只有 2 与 [4,300] 两条规则时落空）
    func testWordLengthWithoutRuleIsSkipped() throws {
        let yaml = """
---
columns:
  - text
  - code
  - weight
encoder:
  rules:
    - length_equal: 2
      formula: AaAbBaBb
    - length_in_range: [4, 300]
      formula: AaBaCaZa
...
今	jafm	100
天	gd	90
很	tt	80
今天很		60
"""
        let out = outputURL()
        let (_, report) = try DictCompiler.compileMultipleWithReport(
            yamlURLs: [write(yaml)], outputURL: out, schemeType: .direct)
        XCTAssertEqual(report.derivedCodes, 0)
        XCTAssertEqual(report.totalParsed, 3, "三字词不派生，单字仍在")
        XCTAssertEqual(report.totalSkipped, 1)
        XCTAssertTrue(report.files[0].skippedLines[0].reason.contains("无法自动编码"))
    }

    /// 任一个字在码表里找不到编码就整条放弃，绝不写半截码
    func testMissingCharCodeIsNotDerived() throws {
        let yaml = """
---
columns:
  - text
  - code
  - weight
encoder:
  rules:
    - length_equal: 2
      formula: AaAbBaBb
...
今	jafm	100
天	gd	90
明天		80
"""
        let out = outputURL()
        let (_, report) = try DictCompiler.compileMultipleWithReport(
            yamlURLs: [write(yaml)], outputURL: out, schemeType: .direct)
        XCTAssertEqual(report.derivedCodes, 0)
        XCTAssertEqual(report.totalParsed, 2)
        XCTAssertEqual(report.totalSkipped, 1)
        XCTAssertTrue(report.files[0].skippedLines[0].reason.contains("找不到编码"))
    }

    /// 同一个字有多个码时取词频最高的那个（外部格式语义）
    func testMultiCodeCharUsesHighestFreq() throws {
        let yaml = """
---
columns:
  - text
  - code
  - weight
encoder:
  rules:
    - length_equal: 2
      formula: AaAbBaBb
...
我	t	10
我	tupg	9999
们	oivj	50
我们		40
"""
        let out = outputURL()
        let (_, report) = try DictCompiler.compileMultipleWithReport(
            yamlURLs: [write(yaml)], outputURL: out, schemeType: .direct)
        XCTAssertEqual(report.derivedCodes, 1)
        XCTAssertEqual(try entries(out, code: "tuoi").map { $0.text }, ["我们"],
                       "我 取词频最高的 tupg（tu）而不是简码 t，们 取 oivj 的前两位（oi）")
    }

    // MARK: - exclude_patterns

    /// 快码靠它滤掉 i/u/v 开头的临时拼音与反查码，否则污染主码表
    func testExcludePatternsFilterCodes() throws {
        let yaml = """
---
columns:
  - text
  - code
  - weight
encoder:
  exclude_patterns:
    - "^[iuv].*$"
  rules:
    - length_equal: 2
      formula: AaAbBaBb
...
今	jafm	100
天	gd	90
今天		80
临时拼音	iip	70
反查	vfan	60
正常	abcd	50
"""
        let out = outputURL()
        let (_, report) = try DictCompiler.compileMultipleWithReport(
            yamlURLs: [write(yaml)], outputURL: out, schemeType: .direct)
        XCTAssertEqual(report.excludedCodes, 2)
        XCTAssertEqual(report.totalParsed, 4, "今、天、今天(派生)、正常")
        XCTAssertTrue(try entries(out, code: "iip").isEmpty)
        XCTAssertTrue(try entries(out, code: "vfan").isEmpty)
        XCTAssertEqual(try entries(out, code: "abcd").map { $0.text }, ["正常"])
    }

    /// 派生出来的码同样受 exclude_patterns 约束
    func testExcludePatternsApplyToDerivedCodes() throws {
        let yaml = """
---
columns:
  - text
  - code
  - weight
encoder:
  exclude_patterns:
    - "^i.*$"
  rules:
    - length_equal: 2
      formula: AaAbBaBb
...
甲	iab	100
乙	bc	90
甲乙		80
"""
        let out = outputURL()
        let (_, report) = try DictCompiler.compileMultipleWithReport(
            yamlURLs: [write(yaml)], outputURL: out, schemeType: .direct)
        XCTAssertEqual(report.excludedCodes, 2, "原有码 iab 与派生码 iabc 都被滤掉")
        XCTAssertEqual(report.totalParsed, 1)
        XCTAssertEqual(try entries(out, code: "bc").map { $0.text }, ["乙"])
    }

    /// 没有 encoder 的表里，只写了词没写码的行仍按老规矩记为跳过
    func testBareWordWithoutEncoderIsSkipped() throws {
        let yaml = """
---
columns:
  - text
  - code
  - weight
...
今天		80
你好	nihao	100
"""
        let out = outputURL()
        let (_, report) = try DictCompiler.compileMultipleWithReport(
            yamlURLs: [write(yaml)], outputURL: out, schemeType: .syllable)
        XCTAssertEqual(report.derivedCodes, 0)
        XCTAssertEqual(report.totalParsed, 1)
        XCTAssertEqual(report.totalSkipped, 1)
    }

    /// encoder 派生要跨文件取单字码：单字在被导入的表里，词组在导入方
    func testDerivationUsesCodesFromImportedTables() throws {
        write("""
---
columns:
  - text
  - code
  - weight
...
今	jafm	100
天	gd	90
""", name: "chars.dict.yaml")
        let main = write("""
---
columns:
  - text
  - code
  - weight
import_tables:
  - chars
encoder:
  rules:
    - length_equal: 2
      formula: AaAbBaBb
...
今天		80
""", name: "main.dict.yaml")
        let out = outputURL()
        let (_, report) = try DictCompiler.compileMultipleWithReport(
            yamlURLs: [main], outputURL: out, schemeType: .direct)
        XCTAssertEqual(report.importedTables, ["chars"])
        XCTAssertEqual(report.derivedCodes, 1)
        XCTAssertEqual(try entries(out, code: "jagd").map { $0.text }, ["今天"])
    }
}
