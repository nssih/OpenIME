import XCTest
@testable import OpenIMECore

// MARK: - 上屏策略（对应外部格式的 auto_select / max_code_length）
//
// 码长由谁说了算：用户在设置页手填的优先，没填才用方案自己写的规则。
// 虎码的 schema 写了 auto_select + max_code_length 4，装进来就该满 4 码即上；
// 但用户改了设置必须立即生效，画像不能反过来盖掉用户的选择 —— 这是既有硬规范。
// 画像取不到时（方案还没加载完）退回只看用户设置，与改动前的行为一致。
// auto_clear 不在此列：它是外部格式的清屏旗标，OpenIME 只原样存着（旧 schema.json 兼容），
// 上屏后一律清屏，不给它开行为的口子。

final class AutoCommitPolicyTests: XCTestCase {

    // MARK: - 辅助

    /// 虎码那样的形码方案：满 4 码自动上屏、上屏后清屏
    private func tigerProfile(autoSelect: Bool? = true,
                              maxCodeLength: Int? = 4,
                              autoClear: String? = "max_length") -> SchemeProfile {
        SchemeProfile(id: "tiger", type: .direct, codeSystem: .shape,
                      maxCodeLength: maxCodeLength, autoSelect: autoSelect, autoClear: autoClear)
    }

    /// 运行期的取值口径（与 `IMERuntime.resolvedAutoSelectLength` 保持一致）
    private func resolveAutoSelectLength(profile: SchemeProfile?, userSetting: Int?,
                                         enabled: Bool? = nil) -> Int? {
        if let len = profile?.autoSelectLength(userSetting: userSetting, enabled: enabled) {
            return len
        }
        return enabled == false ? nil : userSetting
    }

    // MARK: - 用户设置优先

    func testUserSettingOverridesSchemeDefault() {
        XCTAssertEqual(tigerProfile().autoSelectLength(userSetting: 2), 2,
                       "用户填了 2 码就 2 码上屏，不管方案写的是 4")
        XCTAssertEqual(tigerProfile().autoSelectLength(userSetting: 6), 6)
    }

    /// 方案自己关了 auto_select，用户想用照样能用
    func testUserSettingWinsEvenWhenSchemeDisablesAutoSelect() {
        XCTAssertEqual(tigerProfile(autoSelect: false).autoSelectLength(userSetting: 3), 3)
        XCTAssertEqual(tigerProfile(autoSelect: false, maxCodeLength: nil).autoSelectLength(userSetting: 3), 3)
    }

    // MARK: - 三态开关（跟随方案 / 开启 / 关闭）

    /// 显式关闭必须真关：方案声明了 auto_select、甚至用户填过码长，都不自动上屏 ——
    /// 否则长串整句流派（词图兜底 + 空格上屏）永远轮不到
    func testUserExplicitOffBeatsSchemeDefault() {
        XCTAssertNil(tigerProfile().autoSelectLength(userSetting: nil, enabled: false))
        XCTAssertNil(tigerProfile().autoSelectLength(userSetting: 3, enabled: false))
        XCTAssertNil(resolveAutoSelectLength(profile: nil, userSetting: 3, enabled: false),
                     "画像取不到时显式关闭同样优先")
    }

    /// nil=跟随方案（与只有码长的旧设置同口径），true=开启（码长仍由用户/方案决定）
    func testTriStateNilFollowsSchemeAndTrueEnables() {
        XCTAssertEqual(tigerProfile().autoSelectLength(userSetting: nil, enabled: nil), 4)
        XCTAssertEqual(tigerProfile().autoSelectLength(userSetting: 3, enabled: nil), 3)
        XCTAssertEqual(tigerProfile().autoSelectLength(userSetting: nil, enabled: true), 4)
        XCTAssertEqual(tigerProfile().autoSelectLength(userSetting: 2, enabled: true), 2)
        XCTAssertNil(tigerProfile(autoSelect: false).autoSelectLength(userSetting: nil, enabled: true),
                     "开启但没码长可用（方案没声明、用户没填）仍不自动上屏")
    }

    // MARK: - 满码即上（整码精确命中且无重码才立即上屏）

    /// 一条精确命中 = 无重码，用户没有第二可填，替系统吞下第一名不会选错
    func testFullCodeCommitRequiresExactMatch() {
        XCTAssertTrue(IMERuntime.shouldCommitOnFullCode(buffer: "vusu", firstCandidateCode: "vusu", exactMatchCount: 1, autoLen: 4),
                      "满 4 码、首选整码命中且唯一，立即上屏")
        XCTAssertFalse(IMERuntime.shouldCommitOnFullCode(buffer: "vusu", firstCandidateCode: "vus", exactMatchCount: 1, autoLen: 4),
                       "残码不盲上")
        XCTAssertFalse(IMERuntime.shouldCommitOnFullCode(buffer: "vusu", firstCandidateCode: "vusuy", exactMatchCount: 1, autoLen: 4),
                       "首选只是前缀命中时不盲上，留给顶字兜底或用户自己选")
        XCTAssertFalse(IMERuntime.shouldCommitOnFullCode(buffer: "vus", firstCandidateCode: "vus", exactMatchCount: 1, autoLen: 4),
                       "没满码长不即上")
        XCTAssertFalse(IMERuntime.shouldCommitOnFullCode(buffer: "vusu", firstCandidateCode: nil, exactMatchCount: 1, autoLen: 4))
        XCTAssertFalse(IMERuntime.shouldCommitOnFullCode(buffer: "vusu", firstCandidateCode: "", exactMatchCount: 1, autoLen: 4))
        XCTAssertTrue(IMERuntime.shouldCommitOnFullCode(buffer: "vusuyfnp", firstCandidateCode: "vusuyfnp", exactMatchCount: 1, autoLen: 4),
                      "超过码长的整码长词同样命中")
    }

    /// 用户自填 2 码：二简码连打（这=vu、边=su 逐字即上）
    func testFullCodeCommitWorksWithUserCodeLengthTwo() {
        XCTAssertTrue(IMERuntime.shouldCommitOnFullCode(buffer: "vu", firstCandidateCode: "vu", exactMatchCount: 1, autoLen: 2))
    }

    // MARK: - 重码时必须留下编码（对应外部格式的 auto_select_unique_candidate）

    /// 实测重码率不是边缘情况：超强快码 4 码码位 15.1%（13448/89044）、虎码 32.5%（20032/61598）
    /// 有第二条候选。原版靠选重键兜底，这里没有那两颗键，更不能盲上。
    func testDuplicateCodeKeepsBufferForUserToChoose() {
        XCTAssertFalse(IMERuntime.shouldCommitOnFullCode(buffer: "vusu", firstCandidateCode: "vusu", exactMatchCount: 2, autoLen: 4),
                       "同码两条候选：把选择权留给用户，编码留在栏上")
        XCTAssertFalse(IMERuntime.shouldCommitOnFullCode(buffer: "vusu", firstCandidateCode: "vusu", exactMatchCount: 44, autoLen: 4),
                       "重码再多也一律不上（快码单码实测最大候选数 44）")
        XCTAssertTrue(IMERuntime.shouldCommitOnFullCode(buffer: "vusu", firstCandidateCode: "vusu", exactMatchCount: 1, autoLen: 4),
                      "边界：恰好一条唯一")
    }

    /// 候选列表里混着补全出来的长码候选（打 vusu 会带出 vusu… 的更长词），
    /// 拿 candidates.count 当重码数会把几乎每次满码都误判成重码、连打直接退化。
    /// 判据必须是「整码精确命中这条码的条数」，补全项不计入。
    func testCompletionCandidatesAreNotDuplicateCodes() {
        // 模拟：满码 vusu 唯一精确命中 + 列表里另有 3 条补全长码候选
        let buffer = "vusu"
        let list: [(code: String, text: String)] = [
            ("vusu", "素"), ("vusuy", "素质"), ("vusuf", "速率"), ("vusutt", "理所当然"),
        ]
        let exactMatchCount = list.filter { $0.code == buffer }.count
        XCTAssertEqual(list.count, 4, "候选列表本身确实不止一条")
        XCTAssertEqual(exactMatchCount, 1, "整码精确命中只有一条：这是唯一候选")
        XCTAssertTrue(IMERuntime.shouldCommitOnFullCode(buffer: buffer,
                                                        firstCandidateCode: list.first?.code,
                                                        exactMatchCount: exactMatchCount,
                                                        autoLen: 4),
                      "只有补全项跟随、精确命中唯一，仍应满码即上")
    }

    // MARK: - 画像兜底

    func testSchemeDefaultUsedWhenUserSettingMissing() {
        XCTAssertEqual(tigerProfile().autoSelectLength(userSetting: nil), 4,
                       "虎码满 4 码即上，装进来就生效，不用用户手填")
    }

    func testNoAutoSelectMeansNoAutoCommit() {
        XCTAssertNil(tigerProfile(autoSelect: nil).autoSelectLength(userSetting: nil))
        XCTAssertNil(tigerProfile(autoSelect: false).autoSelectLength(userSetting: nil))
    }

    func testAutoSelectWithoutCodeLengthMeansNoAutoCommit() {
        XCTAssertNil(tigerProfile(maxCodeLength: nil).autoSelectLength(userSetting: nil))
        XCTAssertNil(tigerProfile(maxCodeLength: 0).autoSelectLength(userSetting: nil))
    }

    /// 音码方案不写 auto_select（编码长度由音节数决定，顶字上屏是形码的招牌）
    func testPhoneticSchemeDoesNotAutoCommitByDefault() {
        let pinyin = SchemeProfile(id: "pinyin", type: .syllable)
        XCTAssertNil(pinyin.autoSelectLength(userSetting: nil))
        XCTAssertEqual(pinyin.autoSelectLength(userSetting: 5), 5, "但用户可以自己开")
    }

    // MARK: - 零 / 负值当作没填

    func testNonPositiveUserSettingIsTreatedAsUnset() {
        XCTAssertEqual(tigerProfile().autoSelectLength(userSetting: 0), 4, "0 是「没填」，不是「不上屏」")
        XCTAssertEqual(tigerProfile().autoSelectLength(userSetting: -1), 4)
        XCTAssertNil(tigerProfile(autoSelect: false).autoSelectLength(userSetting: 0))
    }

    // MARK: - 画像取不到时的退化

    func testMissingProfileFallsBackToUserSettingOnly() {
        XCTAssertEqual(resolveAutoSelectLength(profile: nil, userSetting: 3), 3)
        XCTAssertNil(resolveAutoSelectLength(profile: nil, userSetting: nil),
                     "方案还没加载完时不自动上屏，与改动前一致")
        XCTAssertEqual(resolveAutoSelectLength(profile: tigerProfile(), userSetting: nil), 4)
        XCTAssertEqual(resolveAutoSelectLength(profile: tigerProfile(), userSetting: 2), 2)
    }

    /// 旧 settings.json 没有 autoSelectEnabled 键：解出来就是 nil（跟随方案），行为与改动前一致；
    /// 新字段为 nil 时不写盘，写出来的 JSON 与旧版本一模一样
    func testAutoSelectEnabledIsOptionalAndOmittedWhenNil() throws {
        let legacy = try JSONDecoder().decode(SchemeUserConfig.self,
                                              from: Data("{\"autoSelectLength\":4}".utf8))
        XCTAssertNil(legacy.autoSelectEnabled)
        XCTAssertEqual(legacy.autoSelectLength, 4)

        var settings = UserSettings()
        settings.schemeConfigs["tiger"] = SchemeUserConfig(autoSelectLength: 4)
        var text = String(data: try JSONEncoder().encode(settings), encoding: .utf8)!
        XCTAssertFalse(text.contains("autoSelectEnabled"), "nil 不写盘，老版本 App 读回来也不受影响")

        settings.schemeConfigs["tiger"]?.autoSelectEnabled = false
        let decoded = try JSONDecoder().decode(
            UserSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(decoded.schemeConfigs["tiger"]?.autoSelectEnabled, false)
    }

    // MARK: - auto_clear：只存不用

    /// 外部格式的 auto_clear 原样存进画像（旧 schema.json 读回来不丢字段），
    /// 但它不当行为开关：OpenIME 没有「留码续打」的状态机，上屏后一律清屏，
    /// 所以画像不再提供清屏判定 —— 写 manual 的方案也不会因此留住编码
    func testAutoClearIsStoredVerbatimButGatesNothing() {
        XCTAssertNil(tigerProfile(autoClear: nil).autoClear)
        XCTAssertEqual(tigerProfile(autoClear: "max_length").autoClear, "max_length")
        XCTAssertEqual(tigerProfile(autoClear: "manual").autoClear, "manual",
                       "原样保留，连大小写都不改")
        XCTAssertEqual(tigerProfile(autoClear: "MANUAL").autoClear, "MANUAL")
    }

    // MARK: - 从外部 schema 一路到画像

    /// 端到端：虎码的 *.schema.yaml → SchemaParser → 推断 → OpenIME 的扁平 schema.yaml
    /// → YAMLSchemaParser → SchemeDefinition → SchemeProfile → 满 4 码自动上屏
    func testTigerSchemaEndToEndYieldsFourCodeAutoCommit() throws {
        let externalYAML = """
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
        let schema = SchemaParser.parse(externalYAML)
        let result = CodeSystemInference.infer(schema: schema, codes: ["tuja", "oivj", "jafm", "gd"])
        XCTAssertEqual(result.codeSystem, .shape)

        let flat = CodeSystemInference.schemaYAML(result: result, schema: schema)
        let definition = try YAMLSchemaParser.parse(flat)
        XCTAssertEqual(definition.type, .direct)
        XCTAssertEqual(definition.codeSystem, .shape)
        XCTAssertEqual(definition.maxCodeLength, 4)
        XCTAssertEqual(definition.autoSelect, true)
        XCTAssertEqual(definition.autoClear, "max_length")
        XCTAssertEqual(definition.delimiter, " ;", "带空格的值要能原样读回来")
        XCTAssertEqual(definition.initialQuality, 1.2)

        let manifest = SchemeManifest(id: "tiger", name: "虎码", version: "1.0", author: "", description: "")
        let scheme = InstalledScheme(id: "tiger", manifest: manifest, definition: definition,
                                     installPath: URL(fileURLWithPath: "/tmp/tiger"))
        let profile = SchemeProfile(scheme: scheme)
        XCTAssertEqual(profile.autoSelectLength(userSetting: nil), 4)
        XCTAssertEqual(profile.autoClear, "max_length", "原样存着，不参与行为")
        XCTAssertEqual(profile.autoSelectLength(userSetting: 2), 2, "用户设置仍然优先")
    }

    /// 雾凇拼音那样的 schema 不该凭空得到顶字上屏
    func testPinyinSchemaDoesNotGainAutoCommit() throws {
        let externalYAML = """
        schema:
          schema_id: ice_pinyin
        speller:
          alphabet: zyxwvutsrqponmlkjihgfedcba
          delimiter: " '"
        translator:
          dictionary: ice_pinyin
          enable_sentence: true
          max_phrase_length: 5
        """
        let schema = SchemaParser.parse(externalYAML)
        let result = CodeSystemInference.infer(schema: schema, codes: ["ni hao", "shi jie", "wo men"])
        let definition = try YAMLSchemaParser.parse(
            CodeSystemInference.schemaYAML(result: result, schema: schema))
        let profile = SchemeProfile(scheme: InstalledScheme(
            id: "ice_pinyin",
            manifest: SchemeManifest(id: "ice_pinyin", name: "雾凇", version: "1.0", author: "", description: ""),
            definition: definition,
            installPath: URL(fileURLWithPath: "/tmp/ice_pinyin")))
        XCTAssertNil(profile.autoSelectLength(userSetting: nil))
        XCTAssertEqual(profile.codeSystem, .phonetic)
        XCTAssertTrue(profile.enableSentence)
        XCTAssertEqual(profile.maxPhraseLength, 5)
        XCTAssertTrue(profile.stripSpacesInCode, "雾凇的 `ni hao` 输入侧也要去空格")
    }

    // MARK: - 用户设置的向后兼容

    /// 旧 settings.json 里没有 singleCharFirst，解码必须照旧成功
    /// （loadSettings 解码失败会直接返回一份全新的 UserSettings，用户设置全丢）。
    /// 新字段全 Optional 就是为了这个：编码时省略键，写出来的 JSON 与旧版本一模一样
    func testOldSettingsJSONStillDecodes() throws {
        var legacy = UserSettings()
        legacy.activeSchemeId = "tiger"
        legacy.schemeConfigs["tiger"] = SchemeUserConfig(autoSelectLength: 4, showAnnotation: false)
        let json = try JSONEncoder().encode(legacy)
        let text = String(data: json, encoding: .utf8)!
        XCTAssertFalse(text.contains("singleCharFirst"), "这就是旧版本写出的那份 JSON")

        let settings = try JSONDecoder().decode(UserSettings.self, from: json)
        XCTAssertEqual(settings.activeSchemeId, "tiger")
        XCTAssertEqual(settings.schemeConfigs["tiger"]?.autoSelectLength, 4)
        XCTAssertEqual(settings.schemeConfigs["tiger"]?.showAnnotation, false)
        XCTAssertNil(settings.schemeConfigs["tiger"]?.singleCharFirst, "没写就是没开")
    }

    /// SchemeUserConfig 三个字段全 Optional，空对象也能解
    func testSchemeUserConfigDecodesFromEmptyJSON() throws {
        let config = try JSONDecoder().decode(SchemeUserConfig.self, from: Data("{}".utf8))
        XCTAssertNil(config.autoSelectLength)
        XCTAssertNil(config.showAnnotation)
        XCTAssertNil(config.singleCharFirst)
    }

    func testSingleCharFirstDefaultsToNil() {
        XCTAssertNil(SchemeUserConfig().autoSelectLength)
        XCTAssertNil(SchemeUserConfig().showAnnotation)
        XCTAssertNil(SchemeUserConfig().singleCharFirst)
        XCTAssertFalse(SchemeUserConfig().singleCharFirst == true, "nil 不等于开，运行期只在 true 时重排")
    }

    func testSchemeUserConfigRoundTripsThroughJSON() throws {
        let config = SchemeUserConfig(autoSelectLength: 3, showAnnotation: true, singleCharFirst: true)
        var settings = UserSettings()
        settings.schemeConfigs["tiger"] = config
        let decoded = try JSONDecoder().decode(
            UserSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(decoded.schemeConfigs["tiger"]?.autoSelectLength, 3)
        XCTAssertEqual(decoded.schemeConfigs["tiger"]?.singleCharFirst, true)
    }

    /// nil 字段不写进 settings.json：合成 Codable 对 Optional 省略键，老版本的 App 读回来也不受影响
    func testNilSingleCharFirstIsOmittedFromJSON() throws {
        var settings = UserSettings()
        settings.schemeConfigs["tiger"] = SchemeUserConfig(autoSelectLength: 4)
        let text = String(data: try JSONEncoder().encode(settings), encoding: .utf8)!
        XCTAssertTrue(text.contains("autoSelectLength"))
        XCTAssertFalse(text.contains("singleCharFirst"))
    }

    // MARK: - 组合自洽：混打 / 反查串 × 满码即上
    //
    // 这两个搭配是不符合逻辑就会出 bug 的典型：满码即上本是为形码顶字连打设计的，
    // 但混打模式与「i+拼音」反查串下，输入串根本不是主方案整码，若照样满码顶字，
    // 会把反查首选（如 ichu 的「出」）错误顶上屏，把用户的连续输入拦腰截断。

    func testReversePinyinInputSuppressesFullCodeCommit() {
        // 反查串激活：即使用户/方案给出 4 码，也必须豁免（nil），不自动上屏
        XCTAssertNil(IMERuntime.effectiveAutoCommitLength(mixActive: false, reverseActive: true, resolved: 4),
                     "i+拼音反查串不该满码即上，否则反查被截断")
    }

    func testMixInputSuppressesFullCodeCommit() {
        XCTAssertNil(IMERuntime.effectiveAutoCommitLength(mixActive: true, reverseActive: false, resolved: 4),
                     "混打模式下输入串不是主方案整码，不该满码即上")
    }

    func testBothMixAndReverseStillSuppressed() {
        XCTAssertNil(IMERuntime.effectiveAutoCommitLength(mixActive: true, reverseActive: true, resolved: 4))
        XCTAssertNil(IMERuntime.effectiveAutoCommitLength(mixActive: true, reverseActive: true, resolved: nil))
    }

    func testPlainInputPassesResolvedLengthThrough() {
        // 两者都不激活：用户设置/方案规则解析出的码长原样放行（nil 也原样透传）
        XCTAssertEqual(IMERuntime.effectiveAutoCommitLength(mixActive: false, reverseActive: false, resolved: 4), 4)
        XCTAssertEqual(IMERuntime.effectiveAutoCommitLength(mixActive: false, reverseActive: false, resolved: 2), 2)
        XCTAssertNil(IMERuntime.effectiveAutoCommitLength(mixActive: false, reverseActive: false, resolved: nil),
                     "没解析出码长时本就不自动上屏")
    }

    // MARK: - 默认方案选择（首装 / 回落）
    //
    // defaultSchemeId 决定「activeSchemeId 为空时激活哪个方案」。内置三套按 id 字母序是
    // oime-cqkm（超强快码，形码）< oime-ice-pinyin（雾凇拼音）< oime-tiger（虎码），
    // 若直接取第一个，新用户首装就落在形码上 —— 必须优先雾凇拼音。

    private func scheme(id: String) -> InstalledScheme {
        InstalledScheme(
            id: id,
            manifest: SchemeManifest(id: id, name: id, version: "1.0", author: "", description: ""),
            definition: SchemeDefinition(type: .syllable),
            installPath: URL(fileURLWithPath: "/tmp/\(id)"))
    }

    func testDefaultSchemePrefersIcePinyinOverAlphabeticalFirst() {
        let schemes = [scheme(id: "oime-cqkm"), scheme(id: "oime-ice-pinyin"), scheme(id: "oime-tiger")]
        XCTAssertEqual(IMERuntime.defaultSchemeId(in: schemes), "oime-ice-pinyin",
                       "首装默认必须是雾凇拼音，而不是字母序第一个的形码超强快码")
    }

    func testDefaultSchemeFallsBackToFirstWhenIcePinyinAbsent() {
        // 用户删了雾凇拼音：回落到列表第一个
        let schemes = [scheme(id: "oime-cqkm"), scheme(id: "oime-tiger")]
        XCTAssertEqual(IMERuntime.defaultSchemeId(in: schemes), "oime-cqkm")
    }

    func testDefaultSchemeEmptyWhenNoSchemes() {
        XCTAssertEqual(IMERuntime.defaultSchemeId(in: []), "", "一个方案都没装时返回空，交给上层跳过激活")
    }

    // MARK: - 方案列表稳定顺序（内置规范序在前，用户导入追加到末尾）
    //
    // reconciledSchemeOrder 是「方案管理页列表次序」的唯一逻辑源：以持久化顺序为基准对账，
    // 剔除已卸载、把新出现的追加到末尾。首次安装内置三套按规范序（雾凇拼音→虎码→超强快码）落位。

    /// 首次安装（无持久化顺序）：内置三套按规范序落位，而非字母序把形码超强快码排到最前
    func testFirstLaunchSeedsCanonicalBundledOrder() {
        // installedSchemeIds() 是字母序：oime-cqkm < oime-ice-pinyin < oime-tiger
        let installed = ["oime-cqkm", "oime-ice-pinyin", "oime-tiger"]
        XCTAssertEqual(IMERuntime.reconciledSchemeOrder(installed: installed, persisted: []),
                       ["oime-ice-pinyin", "oime-tiger", "oime-cqkm"],
                       "首装规范序：雾凇拼音 → 虎码 → 超强快码")
    }

    /// 用户导入的新方案追加到末尾，不因 id 字母序靠前而插到内置前面
    func testImportedSchemeAppendsToEnd() {
        let persisted = ["oime-ice-pinyin", "oime-tiger", "oime-cqkm"]
        // 新导入一个 id 字母序最靠前的方案，也必须排在末尾
        let installed = (persisted + ["aaa-custom"]).sorted()
        XCTAssertEqual(IMERuntime.reconciledSchemeOrder(installed: installed, persisted: persisted),
                       ["oime-ice-pinyin", "oime-tiger", "oime-cqkm", "aaa-custom"],
                       "新导入只能出现在最后位置")
    }

    /// 卸载某方案：从顺序里剔除（位置记忆一并忘掉），其余相对次序不变
    func testUninstalledSchemeIsPrunedFromOrder() {
        let persisted = ["oime-ice-pinyin", "oime-tiger", "oime-cqkm"]
        let installed = ["oime-ice-pinyin", "oime-cqkm"]   // 虎码被删
        XCTAssertEqual(IMERuntime.reconciledSchemeOrder(installed: installed, persisted: persisted),
                       ["oime-ice-pinyin", "oime-cqkm"])
    }

    /// 删掉后重新导入：因为位置记忆已被清除，必然又落到末尾（而非回到原来的中间位置）
    func testReimportedSchemeGoesToEndNotOldSlot() {
        // 删除虎码后落盘的顺序（已不含 tiger）
        let afterDelete = ["oime-ice-pinyin", "oime-cqkm"]
        // 重新导入虎码：installed 又出现 tiger
        let installed = ["oime-cqkm", "oime-ice-pinyin", "oime-tiger"]
        XCTAssertEqual(IMERuntime.reconciledSchemeOrder(installed: installed, persisted: afterDelete),
                       ["oime-ice-pinyin", "oime-cqkm", "oime-tiger"],
                       "重导入的虎码排到末尾，不复活到原规范序中间")
    }

    /// 持久化顺序里含已不存在的陈旧 id（如手动删包）：对账时安全剔除，不残留幽灵
    func testStalePersistedIdsAreDropped() {
        let persisted = ["ghost-scheme", "oime-ice-pinyin", "oime-tiger"]
        let installed = ["oime-ice-pinyin", "oime-tiger"]
        XCTAssertEqual(IMERuntime.reconciledSchemeOrder(installed: installed, persisted: persisted),
                       ["oime-ice-pinyin", "oime-tiger"])
    }

    /// 一批同时新增多个用户方案：非内置的按 id 字母序稳定兜底，结果确定不随机
    func testMultipleNewUserSchemesAreDeterministic() {
        let persisted = ["oime-ice-pinyin"]
        let installed = ["oime-ice-pinyin", "zeta-scheme", "beta-scheme"]
        XCTAssertEqual(IMERuntime.reconciledSchemeOrder(installed: installed, persisted: persisted),
                       ["oime-ice-pinyin", "beta-scheme", "zeta-scheme"],
                       "同批新增按字母序稳定排列")
    }

    // MARK: - 「此刻读不到」不等于「已被卸载」（方案被顶成拼音的根因）
    //
    // 现场：用户用着形码方案，「突然一卡，方案自己变成拼音了」，而方案好端端在盘上。
    // 成因是内置方案升级 / 编译纪元重编都会先删掉 dict.bin 再写回，后台扫描那一趟正好落在
    // 删与写之间就会读不到它。只要让这个方案从方案表里缺席，下一步 purgeOrphanSettings 就
    // 判它「已卸载」、把用户的激活选择改成默认拼音。两道关口各有一个纯函数，这里逐条锁死：
    //   reloadedSchemeList —— 缺席但盘上还在 → 保留旧记录
    //   purgedActiveSchemeId —— 没有判定依据 → 绝不改用户的选择

    /// 瞬时读不到（packages/ 清单里还在）：旧记录必须留住，否则用户正在用的方案就凭空消失了
    func testTransientlyUnreadableSchemeIsKeptInList() {
        let previous = [scheme(id: "oime-ice-pinyin"), scheme(id: "oime-tiger"), scheme(id: "oime-cqkm")]
        // 这一趟只读到两个：虎码正处在「已删未写」的窗口里
        let loaded = [scheme(id: "oime-ice-pinyin"), scheme(id: "oime-cqkm")]
        let declared = Set(["oime-ice-pinyin", "oime-tiger", "oime-cqkm"])

        let kept = IMERuntime.reloadedSchemeList(loaded: loaded, previous: previous, declaredIds: declared)
        XCTAssertEqual(Set(kept.map { $0.id }), declared, "盘上还在的方案一个都不能少")
        XCTAssertEqual(kept.filter { $0.id == "oime-tiger" }.count, 1, "保留一份即可，不该重复")
    }

    /// 真被卸载（清单里已没有）：这才允许从方案表里消失
    func testUninstalledSchemeIsDroppedFromList() {
        let previous = [scheme(id: "oime-ice-pinyin"), scheme(id: "oime-tiger")]
        let loaded = [scheme(id: "oime-ice-pinyin")]
        let declared = Set(["oime-ice-pinyin"])   // 卸载路径先删目录，清单里已经没有虎码

        XCTAssertEqual(IMERuntime.reloadedSchemeList(loaded: loaded, previous: previous,
                                                     declaredIds: declared).map { $0.id },
                       ["oime-ice-pinyin"], "确证卸载才剔除")
    }

    /// 整趟都读失败（loaded 为空）：不能把方案表塌成空的，否则下一步必然改动用户选择
    func testTotalLoadFailureKeepsPreviousList() {
        let previous = [scheme(id: "oime-tiger")]
        let declared = Set(["oime-tiger"])

        XCTAssertEqual(IMERuntime.reloadedSchemeList(loaded: [], previous: previous,
                                                     declaredIds: declared).map { $0.id },
                       ["oime-tiger"], "一次全失败不该让方案表清空")
        XCTAssertTrue(IMERuntime.reloadedSchemeList(loaded: [], previous: [],
                                                    declaredIds: []).isEmpty, "首装前本来就什么都没有")
    }

    /// 端到端串起来：瞬时读不到 → 方案表留住 → 激活选择不变（这就是用户报的那一卡）
    func testTransientFailureDoesNotHijackActiveScheme() {
        let previous = [scheme(id: "oime-ice-pinyin"), scheme(id: "oime-tiger")]
        let declared = Set(["oime-ice-pinyin", "oime-tiger"])
        let kept = IMERuntime.reloadedSchemeList(
            loaded: [scheme(id: "oime-ice-pinyin")], previous: previous, declaredIds: declared)

        let validIds = Set(kept.map { $0.id })
        XCTAssertEqual(
            IMERuntime.purgedActiveSchemeId(active: "oime-tiger", validIds: validIds,
                                            onDiskIds: declared,
                                            fallback: IMERuntime.defaultSchemeId(in: kept)),
            "oime-tiger", "用着形码时突然一卡，方案绝不能被顶成拼音")
    }

    /// 确证卸载才回落：清单里真没有它了，回落到默认方案（雾凇拼音）才是对的行为
    func testConfirmedUninstallFallsBackToDefaultScheme() {
        let validIds: Set<String> = ["oime-ice-pinyin", "oime-cqkm"]
        XCTAssertEqual(
            IMERuntime.purgedActiveSchemeId(active: "oime-tiger", validIds: validIds,
                                            onDiskIds: validIds,
                                            fallback: "oime-ice-pinyin"),
            "oime-ice-pinyin")
    }

    /// 第二道判据：不在本次 validIds 里、但 packages/ 目录里还在 —— 依旧不动用户选择
    func testSchemeStillOnDiskIsNotTreatedAsUninstalled() {
        XCTAssertEqual(
            IMERuntime.purgedActiveSchemeId(active: "oime-tiger", validIds: ["oime-ice-pinyin"],
                                            onDiskIds: ["oime-ice-pinyin", "oime-tiger"],
                                            fallback: "oime-ice-pinyin"),
            "oime-tiger", "加载链路抖动不该改用户的激活选择")
    }

    /// 一个方案都没加载到（首装前的空表 / 整趟失败）：没有判定依据，原样留着
    func testEmptyValidIdsNeverClearActiveScheme() {
        XCTAssertEqual(IMERuntime.purgedActiveSchemeId(active: "oime-tiger", validIds: [],
                                                       onDiskIds: [], fallback: ""),
                       "oime-tiger", "绝不能把用户的激活选择清成空（与 reconcileKeyboardMode 同口径）")
    }

    /// 用户本来就还没选过方案：保持为空，首装默认由 loadInstalledSchemes 单独定
    func testEmptyActiveSchemeIsLeftAlone() {
        XCTAssertEqual(IMERuntime.purgedActiveSchemeId(active: "", validIds: ["oime-ice-pinyin"],
                                                       onDiskIds: [], fallback: "oime-ice-pinyin"),
                       "", "空选择交给首装兜底，这里不越权填默认方案")
    }
}
