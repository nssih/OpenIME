import XCTest
@testable import OpenIMECore

// MARK: - 方案画像与码制推断
//
// 画像是后续所有智能化的依据：展开层、检索层、上屏层都只看画像，不再各自猜。
// 两件事要锁定：
//   1. 推断得准 —— 雾凇拼音拖进来要得到音节检索（以前一律硬编 direct，装是装进来了却查不到），
//      虎码要得到形码定长逻辑；
//   2. 旧包安全 —— schema.json 里没有新字段时，画像回落到 SchemeType 映射，行为一点不变。

final class SchemeProfileTests: XCTestCase {

    private var tmpDir: URL!

    override func setUp() {
        super.setUp()
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SchemeProfileTests_\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmpDir)
        tmpDir = nil
        super.tearDown()
    }

    // MARK: - 辅助

    /// 在 tmpDir 下（可带子路径）写一份词库文件
    @discardableResult
    private func writeDict(_ content: String, name: String) -> URL {
        let url = tmpDir.appendingPathComponent(name)
        try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try! content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// 写一张有 count 条编码的词库表，编码是 `前缀0`、`前缀1`…（好数每张表各抽了多少条）
    @discardableResult
    private func writeCodeTable(prefix: String, count: Int, name: String) -> URL {
        var body = "---\ncolumns:\n  - text\n  - code\n  - weight\n...\n"
        for index in 0..<count { body += "字\(index)\t\(prefix)\(index)\t100\n" }
        return writeDict(body, name: name)
    }

    private func tigerSchema() -> ImportedSchema {
        var schema = ImportedSchema()
        schema.schemaId = "tiger"
        schema.alphabet = "abcdefghijklmnopqrstuvwxyz"
        schema.delimiter = " ;"
        schema.maxCodeLength = 4
        schema.autoSelect = true
        schema.autoClear = "max_length"
        schema.dictionary = "tiger"
        return schema
    }

    private func pinyinSchema() -> ImportedSchema {
        var schema = ImportedSchema()
        schema.schemaId = "ice_pinyin"
        schema.alphabet = "zyxwvutsrqponmlkjihgfedcba"
        schema.delimiter = " '"
        schema.initials = ["b", "p", "m", "f", "d", "t", "n", "l"]
        schema.finals = ["a", "o", "e", "i", "u", "v"]
        schema.algebra = ["abbrev/^([a-z]).+$/", "derive/^([zcs])h/$1/"]
        schema.dictionary = "ice_pinyin"
        schema.maxPhraseLength = 5
        schema.enableSentence = true
        return schema
    }

    private let pinyinCodes = ["ni hao", "shi jie", "zhong guo", "wo men", "ren min"]
    private let tigerCodes = ["tuja", "oivj", "jafm", "gd", "tupg"]

    private func installedScheme(id: String = "s", definition: SchemeDefinition) -> InstalledScheme {
        let manifest = SchemeManifest(id: id, name: id, version: "1.0", author: "", description: "")
        return InstalledScheme(id: id, manifest: manifest, definition: definition,
                               installPath: URL(fileURLWithPath: "/tmp/\(id)"))
    }

    // MARK: - 旧包回落（零破坏）

    func testFallbackForOldPackagesWithoutCodeSystem() {
        for (type, expected): (SchemeType, CodeSystem) in [
            (.syllable, .phonetic),
            (.doubleSyllable, .phonetic),
            (.direct, .shape),
        ] {
            let profile = SchemeProfile(scheme: installedScheme(definition: SchemeDefinition(type: type)))
            XCTAssertEqual(profile.codeSystem, expected, "\(type) 的旧包应回落到 \(expected)")
            XCTAssertEqual(SchemeProfile.fallbackCodeSystem(for: type), expected)
        }
    }

    /// 旧 schema.json 里没有新增的键，解码必须照旧成功（新字段全 Optional，不 bump binaryVersion）
    func testOldSchemaJSONStillDecodes() throws {
        let json = #"{"type":"direct","max_code_length":4,"auto_select":true,"alphabet":"abcdef"}"#
        let definition = try JSONDecoder().decode(SchemeDefinition.self, from: Data(json.utf8))
        XCTAssertEqual(definition.type, .direct)
        XCTAssertEqual(definition.maxCodeLength, 4)
        XCTAssertEqual(definition.autoSelect, true)
        XCTAssertNil(definition.codeSystem)
        XCTAssertNil(definition.delimiter)
        XCTAssertNil(definition.autoClear)
        XCTAssertNil(definition.maxPhraseLength)
        XCTAssertNil(definition.enableSentence)
        XCTAssertNil(definition.initialQuality)
    }

    /// nil 字段不写进 JSON：合成 Codable 对 Optional 省略键，安装目录里的 schema.json 保持干净
    func testNilFieldsAreOmittedWhenEncoding() throws {
        let definition = SchemeDefinition(type: .syllable)
        let text = String(data: try JSONEncoder().encode(definition), encoding: .utf8)!
        XCTAssertFalse(text.contains("code_system"))
        XCTAssertFalse(text.contains("enable_sentence"))
        XCTAssertFalse(text.contains("initial_quality"))
    }

    func testNewFieldsRoundTripThroughJSON() throws {
        let definition = SchemeDefinition(type: .direct, maxCodeLength: 5, codeSystem: .phonoShape,
                                          delimiter: "'", autoClear: "unique", maxPhraseLength: 4,
                                          enableSentence: false, initialQuality: 0.8)
        let decoded = try JSONDecoder().decode(
            SchemeDefinition.self, from: JSONEncoder().encode(definition))
        XCTAssertEqual(decoded.codeSystem, .phonoShape)
        XCTAssertEqual(decoded.delimiter, "'")
        XCTAssertEqual(decoded.autoClear, "unique")
        XCTAssertEqual(decoded.maxPhraseLength, 4)
        XCTAssertEqual(decoded.enableSentence, false)
        XCTAssertEqual(decoded.initialQuality, 0.8)
    }

    // MARK: - 画像默认值

    func testProfileDefaultsWhenFieldsMissing() {
        let profile = SchemeProfile(scheme: installedScheme(definition: SchemeDefinition(type: .direct)))
        XCTAssertTrue(profile.enableSentence, "长串切句是 OpenIME 自己的兜底，不该因为旧包没写就关掉")
        XCTAssertEqual(profile.initialQuality, 1.0)
        XCTAssertTrue(profile.doublePinyinTable.isEmpty)
        XCTAssertFalse(profile.stripSpacesInCode)
        XCTAssertNil(profile.alphabetChars)
    }

    func testExplicitEnableSentenceFalseIsRespected() {
        let off = SchemeProfile(scheme: installedScheme(
            definition: SchemeDefinition(type: .syllable, enableSentence: false)))
        XCTAssertFalse(off.enableSentence)
        let on = SchemeProfile(scheme: installedScheme(
            definition: SchemeDefinition(type: .syllable, enableSentence: true)))
        XCTAssertTrue(on.enableSentence)
    }

    func testProfileReadsEveryDefinitionField() {
        let definition = SchemeDefinition(type: .direct, maxCodeLength: 4, autoSelect: true,
                                          alphabet: "abcd", normalizeCode: "strip_spaces",
                                          codeSystem: .phonoShape, delimiter: " ;",
                                          autoClear: "manual", maxPhraseLength: 6,
                                          initialQuality: 1.5)
        let profile = SchemeProfile(scheme: installedScheme(id: "x", definition: definition))
        XCTAssertEqual(profile.id, "x")
        XCTAssertEqual(profile.codeSystem, .phonoShape)
        XCTAssertTrue(profile.isPhonoShape)
        XCTAssertTrue(profile.isPhonetic, "音形码也有音码成分，简拼第二路对它同样有意义")
        XCTAssertFalse(profile.isShape)
        XCTAssertEqual(profile.alphabetChars, Set("abcd"))
        XCTAssertEqual(profile.delimiter, " ;")
        XCTAssertEqual(profile.maxCodeLength, 4)
        XCTAssertEqual(profile.maxPhraseLength, 6)
        XCTAssertEqual(profile.initialQuality, 1.5)
        XCTAssertTrue(profile.stripSpacesInCode)
        XCTAssertEqual(profile.autoClear, "manual", "外部格式的旗标原样存着，但 OpenIME 不拿它当行为开关")
    }

    func testDirectConstructorFallsBackToo() {
        XCTAssertEqual(SchemeProfile(id: "a", type: .syllable).codeSystem, .phonetic)
        XCTAssertEqual(SchemeProfile(id: "a", type: .direct).codeSystem, .shape)
        XCTAssertEqual(SchemeProfile(id: "a", type: .direct, codeSystem: .phonoShape).codeSystem, .phonoShape)
    }

    // MARK: - 反查引导符（i + 拼音 路由的数据源）

    /// 三态：schema 声明了就用声明的；音形码没声明回落约定俗成的 "i"；其余码制永不反查。
    /// 引导符来自数据而非引擎里对某个方案名的硬编码，符合 Rime「路由写在 schema」的精髓。
    func testEffectiveReverseLookupGuide() {
        // 1) 声明优先：即便码制不是音形码，声明了也照用（可换可关，全凭数据）
        let declared = SchemeProfile(id: "a", type: .direct, codeSystem: .shape,
                                     reverseLookupGuide: "u")
        XCTAssertEqual(declared.effectiveReverseLookupGuide, "u")
        // 2) 音形码缺省回落 "i"（超强快码历史约定，老安装 / 第三方包无字段仍工作）
        let phonoShape = SchemeProfile(id: "b", type: .direct, codeSystem: .phonoShape)
        XCTAssertEqual(phonoShape.effectiveReverseLookupGuide, "i")
        // 3) 非音形码且没声明 → nil：纯形码的 i 可能是合法码元、音码根本不需要反查
        XCTAssertNil(SchemeProfile(id: "c", type: .direct, codeSystem: .shape).effectiveReverseLookupGuide)
        XCTAssertNil(SchemeProfile(id: "d", type: .syllable).effectiveReverseLookupGuide)
        // 空串视为没声明，音形码仍走回落
        XCTAssertEqual(SchemeProfile(id: "e", type: .direct, codeSystem: .phonoShape,
                                     reverseLookupGuide: "").effectiveReverseLookupGuide, "i")
    }

    /// 引导符要能从安装好的方案（schema.json → SchemeDefinition）一路读到画像上
    func testProfileCarriesReverseLookupGuideFromDefinition() {
        let profile = SchemeProfile(scheme: installedScheme(
            definition: SchemeDefinition(type: .direct, codeSystem: .phonoShape,
                                         reverseLookupGuide: "i")))
        XCTAssertEqual(profile.reverseLookupGuide, "i")
        XCTAssertEqual(profile.effectiveReverseLookupGuide, "i")
    }

    // MARK: - 码制推断：三级证据

    /// 雾凇拼音的 cn_dicts/*.dict.yaml 拖进来，从此得到音节检索（以前硬编 direct）
    func testIceCodesInferredAsPhonetic() {
        let result = CodeSystemInference.infer(schema: pinyinSchema(), codes: pinyinCodes)
        XCTAssertEqual(result.codeSystem, .phonetic)
        XCTAssertEqual(result.type, .syllable)
        XCTAssertTrue(result.stripSpaces, "雾凇的 `ni hao` 编译期要去掉空格")
        XCTAssertGreaterThanOrEqual(result.phoneticRatio, 0.9)
        XCTAssertEqual(result.sampleCount, pinyinCodes.count)
        XCTAssertFalse(result.basis.isEmpty, "推断理由要写进安装日志，用户看得懂")
    }

    /// 虎码：定长顶字上屏 + 编码是字根序列 ⇒ 形码
    func testTigerCodesInferredAsShape() {
        let result = CodeSystemInference.infer(schema: tigerSchema(), codes: tigerCodes)
        XCTAssertEqual(result.codeSystem, .shape)
        XCTAssertEqual(result.type, .direct)
        XCTAssertFalse(result.stripSpaces)
    }

    /// 码表统计是地面真相：schema 与码表打架时以码表为准
    func testCodeTableBeatsSchemaEvidence() {
        var schema = tigerSchema()
        schema.maxCodeLength = 4
        let result = CodeSystemInference.infer(schema: schema, codes: pinyinCodes)
        XCTAssertEqual(result.codeSystem, .phonetic, "编码本身是音节，就按音码检索")
        XCTAssertTrue(result.basis.contains("schema 有"))
    }

    /// 超强快码：自动推断落在形码上 —— 编码只有 4%~5% 像音节、schema 里也没有声母韵母表。
    /// 音形码要靠作者显式声明 `code_system: phono_shape`，或者音码与形码证据并存才判得出来，
    /// 这是有意保守：direct 前缀直查对任何码表都成立，最坏只是查得笨一点，不会查不到
    func testCqkmCodesInferredAsShapeByDefault() {
        var schema = ImportedSchema()
        schema.schemaId = "cqkm"
        schema.maxCodeLength = 5
        schema.enableEncoder = true
        let result = CodeSystemInference.infer(schema: schema,
                                              codes: ["jafm", "gd", "oivj", "tuja", "abcd"])
        XCTAssertEqual(result.codeSystem, .shape)
        XCTAssertEqual(result.type, .direct)
    }

    /// 作者写明了码制就不再猜
    func testExplicitCodeSystemWins() {
        let result = CodeSystemInference.infer(explicitCodeSystem: "phono_shape", codes: tigerCodes)
        XCTAssertEqual(result.codeSystem, .phonoShape)
        XCTAssertEqual(result.type, .direct, "音形码的编码不是纯音节，只能前缀直查")
        XCTAssertTrue(result.basis.contains("写明了 code_system"))
    }

    func testExplicitCodeSystemOverridesStorageType() {
        // 包里同时写了 type 与 code_system：type 决定怎么查，code_system 决定输入逻辑
        let result = CodeSystemInference.infer(explicitType: "direct",
                                              explicitCodeSystem: "phono_shape",
                                              codes: tigerCodes)
        XCTAssertEqual(result.type, .direct)
        XCTAssertEqual(result.codeSystem, .phonoShape)
    }

    func testExplicitTypeSyllableWins() {
        let result = CodeSystemInference.infer(explicitType: "syllable", codes: tigerCodes)
        XCTAssertEqual(result.type, .syllable)
        XCTAssertEqual(result.codeSystem, .phonetic)
    }

    func testExplicitTypeDoubleSyllableWins() {
        let result = CodeSystemInference.infer(explicitType: "double_syllable", codes: ["ni", "hao"])
        XCTAssertEqual(result.type, .doubleSyllable)
        XCTAssertEqual(result.codeSystem, .phonetic)
    }

    /// 音码与形码特征并存、而编码又不是纯音节 ⇒ 音形码
    func testBothEvidencesYieldPhonoShape() {
        var schema = pinyinSchema()
        schema.maxCodeLength = 4
        schema.enableSentence = false
        let result = CodeSystemInference.infer(schema: schema, codes: ["bx", "py", "mz", "td"])
        XCTAssertEqual(result.codeSystem, .phonoShape)
        XCTAssertEqual(result.type, .direct)
    }

    /// 开了整句的 max_code_length 不算形码招牌（音码方案的编码长度由音节数决定，不会写死上限）
    func testMaxCodeLengthWithSentenceIsNotShapeEvidence() {
        var schema = ImportedSchema()
        schema.maxCodeLength = 4
        schema.enableSentence = true
        let result = CodeSystemInference.infer(schema: schema, codes: ["bx", "py", "mz"])
        XCTAssertEqual(result.codeSystem, .shape, "没有音码证据、有样本 ⇒ 仍按字根序列保守处理")
        XCTAssertFalse(result.basis.contains("max_code_length"))
    }

    /// 双拼的码长上限是 2，落在 3...6 之外，不会被误判成形码
    func testDoublePinyinCodeLengthIsNotShapeEvidence() {
        var schema = ImportedSchema()
        schema.maxCodeLength = 2
        let result = CodeSystemInference.infer(schema: schema, codes: ["bx", "py"])
        XCTAssertFalse(result.basis.contains("max_code_length"))
    }

    func testNoCodesFallsBackToShape() {
        let result = CodeSystemInference.infer(codes: [])
        XCTAssertEqual(result.codeSystem, .shape)
        XCTAssertEqual(result.type, .direct)
        XCTAssertEqual(result.sampleCount, 0)
        XCTAssertTrue(result.basis.contains("保守"))
    }

    func testAlgebraAloneIsPhoneticEvidence() {
        var schema = ImportedSchema()
        schema.algebra = ["xform/([aeiou])ng/$1n/"]
        let result = CodeSystemInference.infer(schema: schema, codes: ["bx", "py"])
        XCTAssertEqual(result.codeSystem, .phonetic)
        XCTAssertTrue(CodeSystemInference.hasSyllableAlgebra(schema.algebra))
        XCTAssertFalse(CodeSystemInference.hasSyllableAlgebra(["xform/aa/bb/", "erase/^xx$/"]))
    }

    func testStorageTypeMapping() {
        XCTAssertEqual(CodeSystemInference.storageType(for: .phonetic), .syllable)
        XCTAssertEqual(CodeSystemInference.storageType(for: .shape), .direct)
        XCTAssertEqual(CodeSystemInference.storageType(for: .phonoShape), .direct)
        XCTAssertEqual(CodeSystemInference.schemeType(named: "double_syllable"), .doubleSyllable)
        XCTAssertNil(CodeSystemInference.schemeType(named: "nonsense"))
    }

    func testSyllableSequenceRecognition() {
        XCTAssertTrue(CodeSystemInference.isSyllableSequence("nihao"))
        XCTAssertTrue(CodeSystemInference.isSyllableSequence("nihaomashijie"))
        XCTAssertFalse(CodeSystemInference.isSyllableSequence("tuja"))
        XCTAssertFalse(CodeSystemInference.isSyllableSequence(""))
    }

    // MARK: - 抽样与 schema.yaml 生成

    func testSampleCodesReadsDeclaredCodeColumn() {
        let content = "---\ncolumns:\n  - text\n  - code\n  - weight\n...\n你\tni\t100\n# 注释\n好\thao\t90\n"
        XCTAssertEqual(CodeSystemInference.sampleCodes(inContent: content), ["ni", "hao"])
    }

    func testSampleCodesWithoutColumnsAssumesThreeColumnLayout() {
        let content = "---\nname: x\n---\n你\tni\t100\n"
        XCTAssertEqual(CodeSystemInference.sampleCodes(inContent: content), ["ni"])
    }

    func testSampleCodesReturnsEmptyWhenNoCodeColumn() {
        let content = "---\ncolumns:\n  - text\n  - weight\n...\n人工智能\t99999\n"
        XCTAssertTrue(CodeSystemInference.sampleCodes(inContent: content).isEmpty)
    }

    /// 抽样额度按文件平分，不让第一张表吃光：雾凇的 cn_dicts/8105 是单字表，
    /// 编码里一个空格都没有，而 cn_dicts/base 的多字词条才是 `ni hao` 这种写法。
    /// 只看第一张表就判不出「要不要去空格」，编出来的词库输入侧对不上
    func testSampleCodesSpreadsQuotaAcrossFiles() {
        let first = writeCodeTable(prefix: "a", count: 200, name: "first.dict.yaml")
        let second = writeCodeTable(prefix: "b", count: 200, name: "second.dict.yaml")
        let sample = CodeSystemInference.sampleCodes(fromFiles: [first, second], limit: 100)
        XCTAssertEqual(sample.count, 100)
        // limit / 2 = 50 低于每张表的下限 64，所以第一张拿 64、剩下的给第二张
        XCTAssertEqual(sample.filter { $0.hasPrefix("a") }.count, 64)
        XCTAssertEqual(sample.filter { $0.hasPrefix("b") }.count, 36)
        XCTAssertEqual(sample.last, "b35", "第二张表的编码确实被抽到了")
    }

    /// 壳文件自己不装词：抽样要先顺着 import_tables 展开，否则只看到那几条大写编码
    func testSampleCodesFollowsImportTables() {
        writeCodeTable(prefix: "ni hao", count: 5, name: "cn_dicts/base.dict.yaml")
        let shell = writeDict("---\ncolumns:\n  - text\n  - code\n  - weight\n" +
                              "import_tables:\n  - cn_dicts/base\n...\nA\tA\t100\nM1\tM1\t90\n",
                              name: "ice.dict.yaml")
        // 只抽壳文件：两条编码里 `M1` 不是音节，统计上就看不出这是拼音方案
        let shellOnly = CodeSystemInference.sampleCodes(fromFiles: [shell])
        XCTAssertEqual(shellOnly, ["A", "M1"])
        XCTAssertFalse(shellOnly.contains("ni hao0"))

        let expanded = DictCompiler.expandImportTables([shell], resourceRoot: tmpDir).urls
        XCTAssertEqual(expanded.count, 2)
        let sample = CodeSystemInference.sampleCodes(fromFiles: expanded)
        XCTAssertTrue(sample.contains("ni hao0"), "被导入表的编码才是推断该看的样本")
        XCTAssertFalse(CodeSystemInference.infer(schema: nil, codes: shellOnly).stripSpaces,
                       "只抽壳文件判不出要去空格，编出来的词库输入侧对不上")
        XCTAssertTrue(CodeSystemInference.infer(schema: nil, codes: sample).stripSpaces)
    }

    /// 推断结果与外部 schema 里读到的输入规则要能落成 OpenIME 自己的扁平 schema.yaml
    func testSchemaYAMLContainsInferredAndParsedFields() {
        let result = CodeSystemInference.infer(schema: tigerSchema(), codes: tigerCodes)
        let yaml = CodeSystemInference.schemaYAML(result: result, schema: tigerSchema())
        XCTAssertTrue(yaml.contains("type: direct"))
        XCTAssertTrue(yaml.contains("code_system: shape"))
        XCTAssertTrue(yaml.contains("max_code_length: 4"))
        XCTAssertTrue(yaml.contains("auto_select: true"))
        XCTAssertTrue(yaml.contains(#"auto_clear: "max_length""#))
        XCTAssertFalse(yaml.contains("normalize_code"), "虎码的编码不含空格")
        XCTAssertFalse(yaml.contains("enable_sentence"), "schema 没写就不写")
    }

    func testSchemaYAMLWritesStripSpacesForSpacedCodes() {
        let result = CodeSystemInference.infer(schema: pinyinSchema(), codes: pinyinCodes)
        let yaml = CodeSystemInference.schemaYAML(result: result, schema: pinyinSchema())
        XCTAssertTrue(yaml.contains("type: syllable"))
        XCTAssertTrue(yaml.contains("normalize_code: strip_spaces"))
        XCTAssertTrue(yaml.contains(#"delimiter: " '""#), "值里有空格要加引号")
        XCTAssertTrue(yaml.contains("max_phrase_length: 5"))
        XCTAssertFalse(yaml.contains("enable_sentence"),
                       "外部格式的拼句旗标不写进 OpenIME 扁平 schema：词图是自家算法，不被数据源旗标开关")
    }

    // MARK: - SchemaParser：嵌套读取

    func testParserReadsNestedImportedSchema() {
        let yaml = """
        schema:
          schema_id: tiger
          name: 虎码
        speller:
          alphabet: "abcdefghijklmnopqrstuvwxyz"
          delimiter: " ;"
          max_code_length: 4
          auto_select: true
          auto_clear: max_length
        translator:
          dictionary: tiger
          initial_quality: 1.2
        """
        let schema = SchemaParser.parse(yaml)
        XCTAssertEqual(schema.schemaId, "tiger")
        XCTAssertEqual(schema.name, "虎码")
        XCTAssertEqual(schema.alphabet, "abcdefghijklmnopqrstuvwxyz")
        XCTAssertEqual(schema.delimiter, " ;")
        XCTAssertEqual(schema.maxCodeLength, 4)
        XCTAssertEqual(schema.autoSelect, true)
        XCTAssertEqual(schema.autoClear, "max_length")
        XCTAssertEqual(schema.dictionary, "tiger")
        XCTAssertEqual(schema.initialQuality, 1.2)
    }

    func testParserReadsListsAndBooleans() {
        let yaml = """
        speller:
          initials:
            - b
            - p
          finals:
            - a
            - o
          algebra:
            - "abbrev/^([a-z]).+$/"
        translator:
          enable_sentence: false
          max_phrase_length: 5
          enable_encoder: true
        """
        let schema = SchemaParser.parse(yaml)
        XCTAssertEqual(schema.initials, ["b", "p"])
        XCTAssertEqual(schema.finals, ["a", "o"])
        XCTAssertEqual(schema.algebra, ["abbrev/^([a-z]).+$/"], "引号要剥掉、# 不能被当注释")
        XCTAssertEqual(schema.enableSentence, false)
        XCTAssertEqual(schema.maxPhraseLength, 5)
        XCTAssertEqual(schema.enableEncoder, true)
    }

    /// 未知字段与 `__include` / 锚点一律忽略，读不懂也不失败
    func testParserIgnoresUnknownKeysAndIncludes() {
        let yaml = """
        schema:
          schema_id: x
          __include: other:/
        speller:
          alphabet: abc
          some_future_key:
            nested: 1
        engine:
          - translator
        """
        let schema = SchemaParser.parse(yaml)
        XCTAssertEqual(schema.schemaId, "x")
        XCTAssertEqual(schema.alphabet, "abc")
        XCTAssertNil(schema.maxCodeLength)
    }

    func testParserOnGarbageDoesNotThrow() {
        XCTAssertTrue(SchemaParser.parse("").schemaId == nil)
        XCTAssertTrue(SchemaParser.parse(":::\n\t- - -").alphabet == nil)
    }
}
