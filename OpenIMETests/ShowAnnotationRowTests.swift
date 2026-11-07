import XCTest
@testable import OpenIMECore

final class ShowAnnotationRowTests: XCTestCase {

    // MARK: - 辅助

    private func makeScheme(id: String, hasAnnotation: Bool) -> InstalledScheme {
        makeScheme(id: id, hasAnnotation: hasAnnotation, type: .direct, codeSystem: .shape)
    }

    /// 全拼方案（音节存储 + 音码）：唯一合法的混打参与方
    private func pinyinScheme(id: String, hasAnnotation: Bool) -> InstalledScheme {
        makeScheme(id: id, hasAnnotation: hasAnnotation, type: .syllable, codeSystem: .phonetic)
    }

    private func makeScheme(id: String, hasAnnotation: Bool,
                            type: SchemeType, codeSystem: CodeSystem) -> InstalledScheme {
        let manifest = SchemeManifest(id: id, name: id, version: "1.0", author: "", description: "")
        let definition = SchemeDefinition(type: type, codeSystem: codeSystem)
        let columns = hasAnnotation ? ["text", "code", "weight", "annotation"] : ["text", "code", "weight"]
        return InstalledScheme(
            id: id,
            manifest: manifest,
            definition: definition,
            installPath: URL(fileURLWithPath: "/tmp/\(id)"),
            availableColumns: columns
        )
    }

    private func compute(settings: UserSettings, schemes: [InstalledScheme]) -> Bool {
        IMERuntime.computeShowAnnotationRow(settings: settings, installedSchemes: schemes)
    }

    // MARK: - 全局开关关闭

    func testGlobalSwitchOff_alwaysFalse() {
        var s = UserSettings()
        s.showAnnotation = false
        s.activeSchemeId = "a"
        let schemes = [makeScheme(id: "a", hasAnnotation: true)]
        XCTAssertFalse(compute(settings: s, schemes: schemes))
    }

    func testGlobalSwitchOff_mixMode_alwaysFalse() {
        var s = UserSettings()
        s.showAnnotation = false
        s.activeSchemeId = "a"
        s.mixInputEnabled = true
        s.mixInputSchemes = [MixSchemeConfig(id: "a", isEnabled: true, candidateColor: "#000000", priority: 0),
                             MixSchemeConfig(id: "b", isEnabled: true, candidateColor: "#FF0000", priority: 1)]
        let schemes = [makeScheme(id: "a", hasAnnotation: true),
                       makeScheme(id: "b", hasAnnotation: true)]
        XCTAssertFalse(compute(settings: s, schemes: schemes))
    }

    // MARK: - 单方案模式

    func testSingleScheme_hasAnnotation_true() {
        var s = UserSettings()
        s.showAnnotation = true
        s.activeSchemeId = "tiger"
        let schemes = [makeScheme(id: "tiger", hasAnnotation: true)]
        XCTAssertTrue(compute(settings: s, schemes: schemes))
    }

    func testSingleScheme_noAnnotation_false() {
        var s = UserSettings()
        s.showAnnotation = true
        s.activeSchemeId = "pinyin"
        let schemes = [pinyinScheme(id: "pinyin", hasAnnotation: false)]
        XCTAssertFalse(compute(settings: s, schemes: schemes))
    }

    func testSingleScheme_unknownId_false() {
        var s = UserSettings()
        s.showAnnotation = true
        s.activeSchemeId = "ghost"
        let schemes = [makeScheme(id: "tiger", hasAnnotation: true)]
        XCTAssertFalse(compute(settings: s, schemes: schemes))
    }

    func testSingleScheme_emptyActiveId_false() {
        var s = UserSettings()
        s.showAnnotation = true
        s.activeSchemeId = ""
        let schemes = [makeScheme(id: "tiger", hasAnnotation: true)]
        XCTAssertFalse(compute(settings: s, schemes: schemes))
    }

    func testSingleScheme_noSchemesInstalled_false() {
        var s = UserSettings()
        s.showAnnotation = true
        s.activeSchemeId = "tiger"
        XCTAssertFalse(compute(settings: s, schemes: []))
    }

    // MARK: - 混打模式：mixInputEnabled=true 但 mixInputSchemes 为空时退化为单方案

    func testMixEnabled_emptyMixSchemes_fallsBackToSingle_true() {
        var s = UserSettings()
        s.showAnnotation = true
        s.activeSchemeId = "tiger"
        s.mixInputEnabled = true
        s.mixInputSchemes = []
        let schemes = [makeScheme(id: "tiger", hasAnnotation: true)]
        XCTAssertTrue(compute(settings: s, schemes: schemes))
    }

    func testMixEnabled_emptyMixSchemes_fallsBackToSingle_false() {
        var s = UserSettings()
        s.showAnnotation = true
        s.activeSchemeId = "pinyin"
        s.mixInputEnabled = true
        s.mixInputSchemes = []
        let schemes = [pinyinScheme(id: "pinyin", hasAnnotation: false)]
        XCTAssertFalse(compute(settings: s, schemes: schemes))
    }

    // MARK: - 混打模式

    func testMix_primaryHasAnno_true() {
        var s = UserSettings()
        s.showAnnotation = true
        s.activeSchemeId = "tiger"
        s.mixInputEnabled = true
        s.mixInputSchemes = [
            MixSchemeConfig(id: "tiger",  isEnabled: true, candidateColor: "#000000", priority: 0),
            MixSchemeConfig(id: "pinyin", isEnabled: true, candidateColor: "#FF0000", priority: 1)
        ]
        let schemes = [makeScheme(id: "tiger",  hasAnnotation: true),
                       pinyinScheme(id: "pinyin", hasAnnotation: false)]
        XCTAssertTrue(compute(settings: s, schemes: schemes))
    }

    /// 只有参与方案带注释列：合法方向（形码主 + 全拼参与）下参与方真的会出候选，注释行要跟着开
    func testMix_onlySecondaryHasAnno_true() {
        var s = UserSettings()
        s.showAnnotation = true
        s.activeSchemeId = "tiger"
        s.mixInputEnabled = true
        s.mixInputSchemes = [
            MixSchemeConfig(id: "tiger",  isEnabled: true, candidateColor: "#000000", priority: 0),
            MixSchemeConfig(id: "pinyin", isEnabled: true, candidateColor: "#FF0000", priority: 1)
        ]
        let schemes = [makeScheme(id: "tiger",   hasAnnotation: false),
                       pinyinScheme(id: "pinyin", hasAnnotation: true)]
        XCTAssertTrue(compute(settings: s, schemes: schemes))
    }

    /// 非法方向（拼音主 + 形码参与）：参与方不进链，它带不带注释都不算
    func testMix_illegalDirection_onlyPrimaryCounted() {
        var s = UserSettings()
        s.showAnnotation = true
        s.activeSchemeId = "pinyin"
        s.mixInputEnabled = true
        s.mixInputSchemes = [
            MixSchemeConfig(id: "pinyin", isEnabled: true, candidateColor: "#000000", priority: 0),
            MixSchemeConfig(id: "tiger",  isEnabled: true, candidateColor: "#FF0000", priority: 1)
        ]
        let schemes = [pinyinScheme(id: "pinyin", hasAnnotation: false),
                       makeScheme(id: "tiger",   hasAnnotation: true)]
        XCTAssertFalse(compute(settings: s, schemes: schemes),
                       "形码参与方不会生效，它的注释列不该把注释行打开")
    }

    /// 双拼词库不算合格参与方（存的是双拼码，与形码主方案不同源）
    func testMix_doublePinyinParticipantNotCounted() {
        var s = UserSettings()
        s.showAnnotation = true
        s.activeSchemeId = "tiger"
        s.mixInputEnabled = true
        s.mixInputSchemes = [
            MixSchemeConfig(id: "tiger", isEnabled: true, candidateColor: "#000000", priority: 0),
            MixSchemeConfig(id: "heEr",  isEnabled: true, candidateColor: "#FF0000", priority: 1)
        ]
        let schemes = [makeScheme(id: "tiger", hasAnnotation: false),
                       makeScheme(id: "heEr",  hasAnnotation: true,
                                  type: .doubleSyllable, codeSystem: .phonetic)]
        XCTAssertFalse(compute(settings: s, schemes: schemes))
    }

    func testMix_noSchemeHasAnno_false() {
        var s = UserSettings()
        s.showAnnotation = true
        s.activeSchemeId = "pinyin"
        s.mixInputEnabled = true
        s.mixInputSchemes = [
            MixSchemeConfig(id: "pinyin", isEnabled: true, candidateColor: "#000000", priority: 0),
            MixSchemeConfig(id: "wubi",   isEnabled: true, candidateColor: "#FF0000", priority: 1)
        ]
        let schemes = [pinyinScheme(id: "pinyin", hasAnnotation: false),
                       makeScheme(id: "wubi",   hasAnnotation: false)]
        XCTAssertFalse(compute(settings: s, schemes: schemes))
    }

    func testMix_disabledParticipantWithAnno_notCounted() {
        // 带注释的参与方案被禁用了，不会生效，不应计入（主方案用形码，保证混打本身是合法方向）
        var s = UserSettings()
        s.showAnnotation = true
        s.activeSchemeId = "tiger"
        s.mixInputEnabled = true
        s.mixInputSchemes = [
            MixSchemeConfig(id: "tiger",  isEnabled: true,  candidateColor: "#000000", priority: 0),
            MixSchemeConfig(id: "pinyin", isEnabled: false, candidateColor: "#FF0000", priority: 1)
        ]
        let schemes = [makeScheme(id: "tiger",   hasAnnotation: false),
                       pinyinScheme(id: "pinyin", hasAnnotation: true)]
        XCTAssertFalse(compute(settings: s, schemes: schemes))
    }

    func testMix_activeSchemeNotInMixList_stillCounted() {
        // 主方案不在 mixInputSchemes 里，但仍然参与判断
        var s = UserSettings()
        s.showAnnotation = true
        s.activeSchemeId = "tiger"
        s.mixInputEnabled = true
        s.mixInputSchemes = [
            MixSchemeConfig(id: "pinyin", isEnabled: true, candidateColor: "#FF0000", priority: 0)
        ]
        let schemes = [makeScheme(id: "tiger",  hasAnnotation: true),
                       pinyinScheme(id: "pinyin", hasAnnotation: false)]
        XCTAssertTrue(compute(settings: s, schemes: schemes))
    }

    /// 主方案未安装：画像取不到时混打整个不生效（宁可不混，也不放行没依据的组合），
    /// 于是只看得到那个查无此人的主方案 —— 注释行不开
    func testMix_activeSchemeNotInstalled_secondaryHasAnno_false() {
        var s = UserSettings()
        s.showAnnotation = true
        s.activeSchemeId = "ghost"
        s.mixInputEnabled = true
        s.mixInputSchemes = [
            MixSchemeConfig(id: "ghost", isEnabled: true, candidateColor: "#000000", priority: 0),
            MixSchemeConfig(id: "tiger", isEnabled: true, candidateColor: "#FF0000", priority: 1)
        ]
        let schemes = [makeScheme(id: "tiger", hasAnnotation: true)]
        XCTAssertFalse(compute(settings: s, schemes: schemes))
    }
}
