import XCTest
@testable import OpenIMECore

final class UserSettingsTests: XCTestCase {

    // MARK: - 默认值

    func testDefaultValues() {
        let s = UserSettings()
        XCTAssertEqual(s.activeSchemeId, "")
        XCTAssertFalse(s.mixInputEnabled)
        XCTAssertTrue(s.mixInputSchemes.isEmpty)
        XCTAssertTrue(s.showAnnotation)
        XCTAssertTrue(s.showPrediction)
        XCTAssertEqual(s.punctuationMode, .chinese)
        XCTAssertEqual(s.candidateBarRows, 1)
    }

    // MARK: - JSON 编解码往返

    func testEncodeDecodeRoundTrip() throws {
        var s = UserSettings()
        s.activeSchemeId = "wubi"
        s.mixInputEnabled = true
        s.showAnnotation = false
        s.showPrediction = false
        s.keyboardAppearance.primaryColor = "#FF0000"
        s.keyboardLayout.spaceBarLabel = "空格"

        let data = try JSONEncoder().encode(s)
        let decoded = try JSONDecoder().decode(UserSettings.self, from: data)

        XCTAssertEqual(decoded.activeSchemeId, "wubi")
        XCTAssertTrue(decoded.mixInputEnabled)
        XCTAssertFalse(decoded.showAnnotation)
        XCTAssertFalse(decoded.showPrediction)
        XCTAssertEqual(decoded.keyboardAppearance.primaryColor, "#FF0000")
        XCTAssertEqual(decoded.keyboardLayout.spaceBarLabel, "空格")
    }

    func testShowPredictionDefaultsToTrue() {
        // showPrediction 未设置时默认 true
        let s = UserSettings()
        XCTAssertTrue(s.showPrediction)
    }

    func testShowPredictionRoundTrip() throws {
        // showPrediction=false 编解码后保持 false
        var s = UserSettings()
        s.showPrediction = false
        let data = try JSONEncoder().encode(s)
        let decoded = try JSONDecoder().decode(UserSettings.self, from: data)
        XCTAssertFalse(decoded.showPrediction)
    }

    // MARK: - 按键声音 / 震动开关

    /// 声音默认开（与主流输入法一致的默认手感）；震动默认关（想开在键盘外观页 / 快捷面板里打开）
    func testKeyFeedbackDefaults() {
        let s = UserSettings()
        XCTAssertTrue(s.keySoundEnabled, "按键声音默认开")
        XCTAssertFalse(s.keyHapticEnabled, "按键震动默认关")
    }

    /// 关掉后能原样 roundtrip（两个开关相互独立）
    func testKeyFeedbackRoundTrip() throws {
        var s = UserSettings()
        s.keySoundEnabled = false
        s.keyHapticEnabled = false
        let decoded = try JSONDecoder().decode(UserSettings.self, from: JSONEncoder().encode(s))
        XCTAssertFalse(decoded.keySoundEnabled)
        XCTAssertFalse(decoded.keyHapticEnabled)
    }

    // MARK: - 顶层容错解码（防止「缺字段 → 整份设置被清零」）

    /// 旧版 settings.json 缺任意顶层字段时，必须逐字段回落默认值，
    /// 且保留已存在的 activeSchemeId 等字段 —— 锁定「每次启动激活方案都变回默认、
    /// 其它设置也丢」这个回归的修复（与嵌套类型的 legacy 解码测试同一范式）。
    func testDecodesLegacyJSONWithMissingTopLevelFields() throws {
        // 模拟旧版本写出的 JSON：只有三个字段，缺 showPrediction / candidateBarRows /
        // mixInputSchemes / punctuationMode / keyboardLayout / keyboardAppearance 等
        let legacy = ##"{"activeSchemeId":"my-scheme","mixInputEnabled":true,"showAnnotation":false}"##
        let decoded = try JSONDecoder().decode(UserSettings.self, from: legacy.data(using: .utf8)!)
        // 已写的字段原样保留 —— 尤其 activeSchemeId 绝不能被清空
        XCTAssertEqual(decoded.activeSchemeId, "my-scheme", "激活方案不能因别的字段缺失被清零")
        XCTAssertTrue(decoded.mixInputEnabled)
        XCTAssertFalse(decoded.showAnnotation)
        // 缺失的字段各自回落默认值
        XCTAssertTrue(decoded.showPrediction, "缺 showPrediction → 默认 true")
        XCTAssertTrue(decoded.keySoundEnabled, "缺 keySoundEnabled → 默认 true")
        XCTAssertFalse(decoded.keyHapticEnabled, "缺 keyHapticEnabled → 默认 false")
        XCTAssertEqual(decoded.candidateBarRows, 1, "缺 candidateBarRows → 默认 1")
        XCTAssertTrue(decoded.mixInputSchemes.isEmpty, "缺 mixInputSchemes → 默认空")
        XCTAssertEqual(decoded.punctuationMode, .chinese, "缺 punctuationMode → 默认中文标点")
        XCTAssertEqual(decoded.keyboardLayout.spaceBarLabel, "聿·输入法", "缺 keyboardLayout → 默认布局")
    }

    /// 单个字段类型损坏只影响它自己，其余字段照常解码（逐字段隔离）
    func testIgnoresCorruptFieldAndKeepsOthers() throws {
        // showPrediction 被写成字符串（类型错），activeSchemeId 正常
        let corrupt = ##"{"activeSchemeId":"scheme-x","showPrediction":"not-a-bool"}"##
        let decoded = try JSONDecoder().decode(UserSettings.self, from: corrupt.data(using: .utf8)!)
        XCTAssertEqual(decoded.activeSchemeId, "scheme-x")
        XCTAssertTrue(decoded.showPrediction, "损坏字段回落默认 true，不连累整体解码")
    }

    // MARK: - KeyboardAppearanceSettings

    func testCandidateBarHeightWithoutAnnotation() {
        var a = KeyboardAppearanceSettings()
        a.candidateFontSize = 18
        a.annotationFontSize = 11
        let h = a.candidateBarHeight(showAnnotation: false)
        XCTAssertEqual(h, 18 * 1.5, accuracy: 0.001)
    }

    func testCandidateBarHeightWithAnnotation() {
        var a = KeyboardAppearanceSettings()
        a.candidateFontSize = 18
        a.annotationFontSize = 11
        let h = a.candidateBarHeight(showAnnotation: true)
        XCTAssertEqual(h, 18 * 1.5 + 11 * 1.5, accuracy: 0.001)
    }

    func testCandidateBarHeightWithAnnotationIsAlwaysGreater() {
        let a = KeyboardAppearanceSettings()
        XCTAssertGreaterThan(
            a.candidateBarHeight(showAnnotation: true),
            a.candidateBarHeight(showAnnotation: false)
        )
    }

    /// 候选加粗默认关闭（保持宋体原始观感），开启后能原样 roundtrip
    func testCandidateFontBoldDefaultsFalseAndRoundTrips() throws {
        XCTAssertFalse(KeyboardAppearanceSettings().candidateFontBold)
        var a = KeyboardAppearanceSettings()
        a.candidateFontBold = true
        let decoded = try JSONDecoder().decode(KeyboardAppearanceSettings.self, from: JSONEncoder().encode(a))
        XCTAssertTrue(decoded.candidateFontBold)
    }

    /// 旧版 settings.json（没 candidateFontBold）必须能解码并回落 false，且不清空其它字段
    /// —— 防止「加个加粗开关 → 整份外观设置被清零」的回归
    func testAppearanceDecodesLegacyJSONWithoutBoldFlag() throws {
        let legacy = ##"{"primaryColor":"#FF0000","candidateFontSize":22,"keySpacing":9}"##
        let decoded = try JSONDecoder().decode(KeyboardAppearanceSettings.self, from: legacy.data(using: .utf8)!)
        XCTAssertFalse(decoded.candidateFontBold)
        XCTAssertEqual(decoded.primaryColor, "#FF0000")
        XCTAssertEqual(decoded.candidateFontSize, 22, accuracy: 0.001)
        XCTAssertEqual(decoded.keySpacing, 9, accuracy: 0.001)
    }

    // MARK: - SchemeUserConfig

    func testSchemeUserConfigDefaults() {
        let cfg = SchemeUserConfig()
        XCTAssertNil(cfg.autoSelectLength)
        XCTAssertNil(cfg.showAnnotation)
    }

    func testSchemeUserConfigRoundTrip() throws {
        let cfg = SchemeUserConfig(autoSelectLength: 4, showAnnotation: false)
        let data = try JSONEncoder().encode(cfg)
        let decoded = try JSONDecoder().decode(SchemeUserConfig.self, from: data)
        XCTAssertEqual(decoded.autoSelectLength, 4)
        XCTAssertEqual(decoded.showAnnotation, false)
    }

    // MARK: - MixSchemeConfig

    func testMixSchemeConfigRoundTrip() throws {
        let cfg = MixSchemeConfig(id: "wubi", isEnabled: true, candidateColor: "#FF0000", priority: 2)
        let data = try JSONEncoder().encode(cfg)
        let decoded = try JSONDecoder().decode(MixSchemeConfig.self, from: data)
        XCTAssertEqual(decoded.id, "wubi")
        XCTAssertTrue(decoded.isEnabled)
        XCTAssertEqual(decoded.candidateColor, "#FF0000")
        XCTAssertEqual(decoded.priority, 2)
    }

    // MARK: - KeyboardLayoutSettings

    func testKeyboardLayoutSettingsDefaults() {
        let l = KeyboardLayoutSettings()
        XCTAssertEqual(l.leftBottomKey, .number123)
        XCTAssertEqual(l.spaceBarLabel, "聿·输入法")
        XCTAssertEqual(l.rowSpacingRatio, 0.16, accuracy: 0.001)
        XCTAssertEqual(l.keyboardHeightRatio, 1.32, accuracy: 0.001, "键盘高度系数默认 1.32（滑杆 132%）")
    }

    func testKeyboardHeightRatioRoundTrip() throws {
        var l = KeyboardLayoutSettings()
        l.keyboardHeightRatio = 1.2
        let data = try JSONEncoder().encode(l)
        let decoded = try JSONDecoder().decode(KeyboardLayoutSettings.self, from: data)
        XCTAssertEqual(decoded.keyboardHeightRatio, 1.2, accuracy: 0.001)
    }

    /// 旧版 settings.json（没 keyboardHeightRatio）必须能解码并回落 1.32，
    /// 且不清空其它字段 —— 防止「加个高度系数 → 整份设置被清零」的回归
    func testKeyboardLayoutDecodesLegacyJSONWithoutHeightRatio() throws {
        let legacy = #"{"leftBottomKey":"number123","spaceBarLabel":"空格","rowSpacingRatio":0.2}"#
        let data = legacy.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(KeyboardLayoutSettings.self, from: data)
        XCTAssertEqual(decoded.keyboardHeightRatio, 1.32, accuracy: 0.001)
        XCTAssertEqual(decoded.spaceBarLabel, "空格")
        XCTAssertEqual(decoded.rowSpacingRatio, 0.2, accuracy: 0.001)
    }

    func testKeyboardLayoutSettingsEquatable() {
        var l1 = KeyboardLayoutSettings()
        var l2 = KeyboardLayoutSettings()
        XCTAssertEqual(l1, l2)
        l1.spaceBarLabel = "空格"
        XCTAssertNotEqual(l1, l2)
        l2.spaceBarLabel = "空格"
        XCTAssertEqual(l1, l2)
    }

    /// 空格键实际显示的文字：26 键 / 双拼都从这一处取，留空必须回落到默认文字
    func testSpaceBarDisplayLabelFallsBackWhenEmpty() {
        var l = KeyboardLayoutSettings()
        XCTAssertEqual(l.spaceBarDisplayLabel, "聿·输入法")
        l.spaceBarLabel = ""
        XCTAssertEqual(l.spaceBarDisplayLabel, "聿·输入法", "留空时应回落到默认文字，不能显示空白键")
        l.spaceBarLabel = "空格"
        XCTAssertEqual(l.spaceBarDisplayLabel, "空格")
        l.spaceBarLabel = "␣"
        XCTAssertEqual(l.spaceBarDisplayLabel, "␣")
    }

    /// spaceBarDisplayLabel 必须是只读计算属性：一旦进入编码结果，
    /// 旧版 settings.json（没这个键）就会解码失败并退回默认设置
    func testSpaceBarDisplayLabelIsNotEncoded() throws {
        var l = KeyboardLayoutSettings()
        l.spaceBarLabel = "空格"
        let data = try JSONEncoder().encode(l)
        let json = String(data: data, encoding: .utf8) ?? ""
        XCTAssertFalse(json.contains("spaceBarDisplayLabel"), "计算属性不应参与 Codable")
        let decoded = try JSONDecoder().decode(KeyboardLayoutSettings.self, from: data)
        XCTAssertEqual(decoded.spaceBarDisplayLabel, "空格")
    }

    // MARK: - ThemeMode / LeftBottomKeyType RawValue

    func testThemeModeRawValues() {
        XCTAssertEqual(ThemeMode.light.rawValue, "light")
        XCTAssertEqual(ThemeMode.dark.rawValue, "dark")
        XCTAssertEqual(ThemeMode.followSystem.rawValue, "followSystem")
    }

    func testLeftBottomKeyTypeRawValues() {
        XCTAssertEqual(LeftBottomKeyType.nextKeyboard.rawValue, "nextKeyboard")
        XCTAssertEqual(LeftBottomKeyType.number123.rawValue, "number123")
    }
}

// MARK: - 自定义词表纯函数（学习长句的去重 + 最新置顶 + 无上限）
//
// IMERuntime.learnPhrase 的去重 + 置顶逻辑抽成 CustomWordStore.dedupPrepend 纯函数，
// 这里只测不碰磁盘的数组变换（共享容器单例难以脱污测，故靠纯函数锁定）。
final class CustomWordStoreTests: XCTestCase {

    /// 新词插到 0 位（最新置顶），旧词依次后移。
    func testPrependsNewWordToFront() {
        let base = [CustomWord(text: "旧", code: "old")]
        let result = CustomWordStore.dedupPrepend(base, code: "nihao", text: "你好")
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].text, "你好", "新词在最前")
        XCTAssertEqual(result[0].code, "nihao")
        XCTAssertEqual(result[1].text, "旧")
    }

    /// 同 (code, text) 已存在：先删旧再插到 0 位，不产生第二条（去重）。
    func testDeduplicatesSameCodeAndText() {
        let base = [
            CustomWord(text: "其他", code: "other"),
            CustomWord(text: "你好", code: "nihao"),
        ]
        let result = CustomWordStore.dedupPrepend(base, code: "nihao", text: "你好")
        XCTAssertEqual(result.count, 2, "重复的 code+text 不产生第二条")
        XCTAssertEqual(result[0].text, "你好", "去重后最新那条置顶")
        XCTAssertEqual(result.filter { $0.code == "nihao" && $0.text == "你好" }.count, 1)
    }

    /// 去重键是 code+text 两者：同码不同词 / 同词不同码都不算重复，各自共存。
    func testDedupKeyIsCodePlusText() {
        var result = CustomWordStore.dedupPrepend([], code: "nihao", text: "你好")
        result = CustomWordStore.dedupPrepend(result, code: "nihao", text: "拟好")  // 同码不同词
        result = CustomWordStore.dedupPrepend(result, code: "nihaoa", text: "你好") // 同词不同码
        XCTAssertEqual(result.count, 3, "code 或 text 任一不同就不算重复")
    }

    /// 无上限：大批量插入不裁剪（长句全存磁盘、不设任何条数上限）。
    func testNoUpperLimitTrims() {
        var result: [CustomWord] = []
        for i in 0..<5000 {
            result = CustomWordStore.dedupPrepend(result, code: "c\(i)", text: "词\(i)")
        }
        XCTAssertEqual(result.count, 5000, "大批量不裁剪")
        XCTAssertEqual(result[0].text, "词4999", "最后插入的在最前")
    }

    /// 纯函数：不改入参（原数组保持不变）。
    func testDoesNotMutateInput() {
        let base = [CustomWord(text: "旧", code: "old")]
        _ = CustomWordStore.dedupPrepend(base, code: "nihao", text: "你好")
        XCTAssertEqual(base.count, 1, "入参不被修改")
        XCTAssertEqual(base[0].text, "旧")
    }

    /// 注入固定时间：新词 createdAt 取注入值（便于排序断言）。
    func testUsesInjectedCreatedAt() {
        let now = Date(timeIntervalSince1970: 1_000)
        let result = CustomWordStore.dedupPrepend([], code: "nihao", text: "你好", now: now)
        XCTAssertEqual(result[0].createdAt, now)
    }
}
