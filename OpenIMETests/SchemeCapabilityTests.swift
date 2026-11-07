import XCTest
@testable import OpenIMECore

// MARK: - 方案能力模型
//
// 「这个方案能用什么」的唯一事实来源。UI 显隐与运行时门控都只问它，
// 所以这里必须把整张矩阵穷举出来：type × codeSystem 全组合的形态可用性、
// 混打的唯一合法方向、以及链感知（参与方不扩展形态，只看主方案）。
//
// 判定不是查表而是编码空间求交集，因此「没见过的组合」也必须有确定行为 —— 保守放行，不误杀。

final class SchemeCapabilityTests: XCTestCase {

    // MARK: - 辅助

    private func profile(_ id: String,
                         _ type: SchemeType,
                         _ codeSystem: CodeSystem) -> SchemeProfile {
        SchemeProfile(id: id, type: type, codeSystem: codeSystem)
    }

    private let allTypes: [SchemeType] = [.syllable, .doubleSyllable, .direct]
    private let allCodeSystems: [CodeSystem] = [.phonetic, .shape, .phonoShape]

    /// 全拼（雾凇拼音那一类）
    private var fullPinyin: SchemeProfile { profile("pinyin", .syllable, .phonetic) }
    /// 双拼（小鹤双拼方案：词库存双拼码）
    private var doublePinyin: SchemeProfile { profile("heEr", .doubleSyllable, .phonetic) }
    /// 纯形码（虎码）
    private var shape: SchemeProfile { profile("tiger", .direct, .shape) }
    /// 音形码
    private var phonoShape: SchemeProfile { profile("phonoShape", .direct, .phonoShape) }

    private func mixConfig(_ id: String, enabled: Bool = true, priority: Int = 0) -> MixSchemeConfig {
        MixSchemeConfig(id: id, isEnabled: enabled, candidateColor: "#FF0000", priority: priority)
    }

    // MARK: - 编码空间推导

    func testDecodedSpacesPerMode() {
        XCTAssertEqual(SchemeCapability.decodedSpaces(.pinyin26, profile: shape), [.letters],
                       "26 键原样透传字母，与方案无关")
        XCTAssertEqual(SchemeCapability.decodedSpaces(.heEr, profile: fullPinyin), [.fullPinyin],
                       "全拼方案上双拼码要还原成全拼")
        XCTAssertEqual(SchemeCapability.decodedSpaces(.heEr, profile: doublePinyin), [.doublePinyinCodes],
                       "双拼方案上键面码就是词库码")
        XCTAssertEqual(SchemeCapability.decodedSpaces(.heEr, profile: nil), [.fullPinyin],
                       "画像缺失时按最常见的全拼还原处理")
    }

    func testQueryableSpacesPerProfile() {
        XCTAssertEqual(SchemeCapability.queryableSpaces(fullPinyin), [.fullPinyin])
        XCTAssertEqual(SchemeCapability.queryableSpaces(doublePinyin), [.doublePinyinCodes])
        XCTAssertEqual(SchemeCapability.queryableSpaces(shape), [.shapeCodes])
        XCTAssertEqual(SchemeCapability.queryableSpaces(phonoShape), [.phonoShapeCodes])
    }

    /// 四种码制的可查询空间互不相交 —— 这正是「混打反方向必烂」的机理
    func testQueryableSpacesAreMutuallyDisjoint() {
        let spaces = [fullPinyin, doublePinyin, shape, phonoShape].map { SchemeCapability.queryableSpaces($0) }
        for i in spaces.indices {
            for j in spaces.indices where i != j {
                XCTAssertTrue(spaces[i].isDisjoint(with: spaces[j]),
                              "第 \(i) 与第 \(j) 个方案的可查询空间不该有交集")
            }
        }
    }

    // MARK: - 形态可用性矩阵（type × codeSystem 全组合穷举）

    func testKeyboardModeMatrixCoversEveryCombination() {
        for type in allTypes {
            for codeSystem in allCodeSystems {
                let p = profile("s", type, codeSystem)
                let modes = SchemeCapability.availableKeyboardModes(chain: SchemeChain(primary: p))
                // 26 键恒可用：字母串对任何码制都能做前缀查询
                XCTAssertTrue(modes.contains(.pinyin26), "\(type)/\(codeSystem) 丢了 26 键")
                XCTAssertEqual(modes.first, .pinyin26, "顺序必须与 KeyboardMode.allCases 一致")
                XCTAssertEqual(Set(modes), expectedModes(type, codeSystem),
                               "\(type)/\(codeSystem) 的形态可用性变了")
            }
        }
    }

    /// 期望值单独写一份，与 `SchemeCapability` 的推导互为对照（改一处必须同时改另一处）
    private func expectedModes(_ type: SchemeType, _ codeSystem: CodeSystem) -> Set<KeyboardMode> {
        switch (type, codeSystem) {
        case (.syllable, .phonetic):     return [.pinyin26, .heEr]        // 全拼：两种都行
        case (.doubleSyllable, _):       return [.pinyin26, .heEr]        // 双拼：键面码即词库码
        case (.direct, .shape):          return [.pinyin26]               // 形码：只有 26 键
        case (.direct, .phonoShape):     return [.pinyin26]               // 音形码：只有 26 键
        // 没见过的组合保守放行：这类包本身就矛盾，真装进来也查不出东西，
        // 但不该由能力模型替它编一套规则、更不该把入口一刀切掉
        case (.syllable, .shape), (.syllable, .phonoShape), (.direct, .phonetic):
            return [.pinyin26, .heEr]
        }
    }

    func testShapeSchemeLosesDoublePinyin() {
        let modes = SchemeCapability.availableKeyboardModes(chain: SchemeChain(primary: shape))
        XCTAssertEqual(modes, [.pinyin26], "虎码激活时双拼压根不该出现")
        XCTAssertFalse(SchemeCapability.supportsKeyboardMode(.heEr, chain: SchemeChain(primary: shape)))
    }

    func testDoublePinyinSchemeSupportsItsOwnKeyboard() {
        let modes = SchemeCapability.availableKeyboardModes(chain: SchemeChain(primary: doublePinyin))
        XCTAssertEqual(modes, [.pinyin26, .heEr])
        XCTAssertTrue(SchemeCapability.supportsKeyboardMode(.heEr, profile: doublePinyin),
                      "双拼方案配小鹤双拼键盘是恒等直通，必须可用")
    }

    /// 链上一个方案都没有：只有恒等直通能放行，其余形态没有判定依据
    func testEmptyChainOnlyAllowsIdentityMode() {
        let empty = SchemeChain(profiles: [])
        XCTAssertTrue(empty.isEmpty)
        XCTAssertEqual(SchemeCapability.availableKeyboardModes(chain: empty), [.pinyin26])
        XCTAssertTrue(SchemeCapability.supportsKeyboardMode(.pinyin26, chain: empty))
        XCTAssertFalse(SchemeCapability.supportsKeyboardMode(.heEr, chain: empty))
    }

    // MARK: - 链感知：参与方不扩展形态，只看主方案

    func testShapePrimaryWithPinyinParticipantDoesNotWidenModes() {
        let chain = SchemeChain(primary: shape, participants: [fullPinyin])
        XCTAssertEqual(SchemeCapability.availableKeyboardModes(chain: chain), [.pinyin26],
                       "参与方不扩展形态：形码主方案永远只有 26 键")
    }

    /// 参与方案本身不合格（双拼词库）时不算进链，形态照旧收窄
    func testShapePrimaryWithDoublePinyinParticipantStaysNarrow() {
        let chain = SchemeChain(primary: shape, participants: [doublePinyin])
        XCTAssertEqual(SchemeCapability.availableKeyboardModes(chain: chain), [.pinyin26],
                       "参与方不扩展形态：主方案是形码就只有 26 键")
    }

    // MARK: - 混打方向矩阵

    func testCanMixOnlyForPureShape() {
        XCTAssertTrue(SchemeCapability.canMix(primary: shape), "只有纯形码方案能开混打")
        XCTAssertFalse(SchemeCapability.canMix(primary: fullPinyin))
        XCTAssertFalse(SchemeCapability.canMix(primary: doublePinyin))
        XCTAssertFalse(SchemeCapability.canMix(primary: phonoShape), "音形码自带消歧，再挂拼音等于把它打回原形")
    }

    func testCanParticipateOnlyForFullPinyinDictionary() {
        // 形码主 + 全拼参与：唯一合法方向
        XCTAssertTrue(SchemeCapability.canParticipate(primary: shape, participant: fullPinyin))
        // 形码主 + 双拼 / 形码 / 音形码参与：编码空间不同源，混入只会产生噪声
        XCTAssertFalse(SchemeCapability.canParticipate(primary: shape, participant: doublePinyin))
        XCTAssertFalse(SchemeCapability.canParticipate(primary: shape, participant: shape))
        XCTAssertFalse(SchemeCapability.canParticipate(primary: shape, participant: phonoShape))
        // 反方向的参与方也不合格：形码词库无论挂在谁后面都只会添乱
        XCTAssertFalse(SchemeCapability.canParticipate(primary: fullPinyin, participant: shape))
        XCTAssertFalse(SchemeCapability.canParticipate(primary: fullPinyin, participant: phonoShape))
        XCTAssertFalse(SchemeCapability.canParticipate(primary: fullPinyin, participant: doublePinyin))
    }

    /// 方向性由两个闸分工把守：`canParticipate` 只看参与方是不是全拼词库（与主方案无关），
    /// 「谁能开混打」是 `canMix` 的事。两个闸都过才算合法组合 —— 拼音主 / 音形码主在这里被挡下
    func testMixDirectionNeedsBothGates() {
        let configs = [mixConfig("pinyin")]
        let pinyin = fullPinyin
        let profileOf: (String) -> SchemeProfile? = { _ in pinyin }
        for primary in [fullPinyin, doublePinyin, phonoShape] {
            XCTAssertFalse(SchemeCapability.canMix(primary: primary),
                           "\(primary.id) 为主方案时任何参与方都不该生效")
            XCTAssertTrue(SchemeCapability.effectiveMixConfigs(configs, primary: primary,
                                                              profileOf: profileOf).isEmpty)
        }
        XCTAssertTrue(SchemeCapability.canMix(primary: shape))
        XCTAssertEqual(SchemeCapability.effectiveMixConfigs(configs, primary: shape,
                                                           profileOf: profileOf).count, 1)
    }

    /// 同 id 一律拒绝：主方案行由设置页单独维护，不该被当成参与方重复查询
    func testCanParticipateRejectsSameId() {
        let pinyin2 = profile("pinyin", .syllable, .phonetic)
        XCTAssertFalse(SchemeCapability.canParticipate(primary: fullPinyin, participant: pinyin2))
    }

    // MARK: - 运行时兜底过滤

    func testEffectiveMixConfigsKeepsOnlyLegalParticipants() {
        let configs = [mixConfig("pinyin", priority: 0), mixConfig("tiger", priority: 1)]
        let profiles = ["pinyin": fullPinyin, "tiger": shape]
        let kept = SchemeCapability.effectiveMixConfigs(configs, primary: shape,
                                                        profileOf: { profiles[$0] })
        XCTAssertEqual(kept.map { $0.id }, ["pinyin"])
    }

    func testEffectiveMixConfigsEmptyWhenPrimaryCannotMix() {
        let configs = [mixConfig("tiger")]
        let profiles = ["tiger": shape]
        for primary in [fullPinyin, doublePinyin, phonoShape] {
            XCTAssertTrue(SchemeCapability.effectiveMixConfigs(configs, primary: primary,
                                                              profileOf: { profiles[$0] }).isEmpty,
                          "\(primary.id) 为主方案时混打不该生效")
        }
    }

    func testEffectiveMixConfigsEmptyWhenPrimaryMissing() {
        let kept = SchemeCapability.effectiveMixConfigs([mixConfig("pinyin")], primary: nil,
                                                        profileOf: { _ in fullPinyin })
        XCTAssertTrue(kept.isEmpty, "主方案画像缺失时一律判空，宁可不混打也不放行非法组合")
    }

    func testEffectiveMixConfigsDropsDisabledAndUnknown() {
        let configs = [mixConfig("pinyin", enabled: false), mixConfig("ghost")]
        let profiles = ["pinyin": fullPinyin]
        let kept = SchemeCapability.effectiveMixConfigs(configs, primary: shape,
                                                        profileOf: { profiles[$0] })
        XCTAssertTrue(kept.isEmpty, "被禁用的与已卸载的参与方案都不生效")
    }

    /// 旧 settings.json 里存着「拼音主 + 形码参与」这种非法组合，运行时过滤掉即可，不改写磁盘
    func testLegacyIllegalCombinationIsFilteredNotRewritten() {
        var settings = UserSettings()
        settings.activeSchemeId = "pinyin"
        settings.mixInputEnabled = true
        settings.mixInputSchemes = [mixConfig("pinyin"), mixConfig("tiger", priority: 1)]
        let profiles = ["pinyin": fullPinyin, "tiger": shape]
        let kept = SchemeCapability.effectiveMixConfigs(
            settings.mixInputEnabled ? settings.mixInputSchemes : [],
            primary: profiles[settings.activeSchemeId],
            profileOf: { profiles[$0] })
        XCTAssertTrue(kept.isEmpty)
        XCTAssertEqual(settings.mixInputSchemes.count, 2, "用户磁盘配置不被偷偷改写")
    }

    // MARK: - 运行时形态回落钳制（形码×双拼的真实搭配）
    //
    // 能力层只回答「这个方案能用哪些形态」；运行时还得把用户的历史选择对账：
    // 形态是全局持久化的，切到撑不起它的方案时必须回落 26 键，不能把用户留在死胡同里。

    func testRuntimeFallsBackToPinyin26WhenShapeCannotHoldDoublePinyin() {
        let shapeChain = SchemeChain(primary: shape)
        XCTAssertEqual(IMERuntime.reconciledKeyboardMode(current: .heEr, chain: shapeChain), .pinyin26,
                       "形码撑不起双拼，历史选择的双拼必须回落 26 键")
        XCTAssertEqual(IMERuntime.reconciledKeyboardMode(current: .pinyin26, chain: shapeChain), .pinyin26,
                       "26 键恒合法，原样保留")
    }

    func testRuntimeKeepsModeWhenChainSupportsIt() {
        XCTAssertEqual(IMERuntime.reconciledKeyboardMode(current: .heEr, chain: SchemeChain(primary: fullPinyin)), .heEr,
                       "全拼撑得起双拼键盘，不该动用户的选择")
        XCTAssertEqual(IMERuntime.reconciledKeyboardMode(current: .heEr, chain: SchemeChain(primary: doublePinyin)), .heEr,
                       "双拼方案配小鹤键盘恒等直通，保留")
    }

    func testRuntimeKeepsModeWhenChainEmpty() {
        let empty = SchemeChain(profiles: [])
        for mode in [KeyboardMode.pinyin26, .heEr] {
            XCTAssertEqual(IMERuntime.reconciledKeyboardMode(current: mode, chain: empty), mode,
                           "方案还没加载完时没有判定依据，不动用户的选择")
        }
    }

    /// 链感知：参与方不扩展形态，形码主 + 全拼参与时双拼照样回落
    func testRuntimeFallbackIgnoresParticipants() {
        let chain = SchemeChain(primary: shape, participants: [fullPinyin])
        XCTAssertEqual(IMERuntime.reconciledKeyboardMode(current: .heEr, chain: chain), .pinyin26,
                       "参与方不扩展形态：形码主方案下双拼仍回落")
    }
}
