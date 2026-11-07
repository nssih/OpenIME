import XCTest
@testable import OpenIMECore

// MARK: - CandidateBarShortcut 目录 + resolve 映射
//
// 目录枚举与 id 到枚举的映射都是纯逻辑，直接校验，不碰 CandidateBarShortcutStore.shared
// （App Group UserDefaults 单例，测试写它会污染全局、影响其他用例）。

final class CandidateBarShortcutTests: XCTestCase {

    // MARK: - allCases 完整性

    func testAllCaseIDsAreUnique() {
        let ids = CandidateBarShortcut.allCases.map { $0.id }
        XCTAssertEqual(Set(ids).count, ids.count, "每个快捷功能的 id（rawValue）必须唯一")
    }

    func testRawValueMatchesID() {
        for shortcut in CandidateBarShortcut.allCases {
            XCTAssertEqual(shortcut.id, shortcut.rawValue)
        }
    }

    func testAllCasesHaveNonEmptySymbolAndTitle() {
        for shortcut in CandidateBarShortcut.allCases {
            XCTAssertFalse(shortcut.symbolName.isEmpty, "\(shortcut.id) 缺少图标名")
            XCTAssertFalse(shortcut.title.isEmpty, "\(shortcut.id) 缺少标题")
        }
    }

    func testIsToggleClassification() {
        // 开关型：点一下翻状态
        XCTAssertTrue(CandidateBarShortcut.numberKeyboard.isToggle)
        XCTAssertTrue(CandidateBarShortcut.toggleEnglish.isToggle)
        XCTAssertTrue(CandidateBarShortcut.toggleAnnotation.isToggle)
        XCTAssertTrue(CandidateBarShortcut.togglePrediction.isToggle)
        XCTAssertTrue(CandidateBarShortcut.toggleDynamicFreq.isToggle)
        // 动作型：打开面板 / 清空 / 主题循环，点下去不翻任何状态
        // 剪贴板算动作型：候选栏上点它是展开历史面板，记录开关在快捷面板分区四
        XCTAssertFalse(CandidateBarShortcut.clipboardHistory.isToggle)
        XCTAssertFalse(CandidateBarShortcut.theme.isToggle)
        XCTAssertFalse(CandidateBarShortcut.keyboardMode.isToggle)
        XCTAssertFalse(CandidateBarShortcut.scheme.isToggle)
        XCTAssertFalse(CandidateBarShortcut.clearInput.isToggle)
    }

    /// 着色口径比开关型宽一档：剪贴板图标本身不是开关，但颜色必须跟着「记录剪贴板」
    /// 开关走，否则用户开完记录回到键盘，图标仍灰着，看不出到底在不在记
    func testReflectsStateClassification() {
        for shortcut in CandidateBarShortcut.allCases where shortcut.isToggle {
            XCTAssertTrue(shortcut.reflectsState, "\(shortcut.id) 是开关型却不着色，开关状态在候选栏上无从读出")
        }
        XCTAssertTrue(CandidateBarShortcut.clipboardHistory.reflectsState)
        // 非开关且无持续状态的动作型：主题三态循环 / 二级入口 / 清空，没有「开」可读
        XCTAssertFalse(CandidateBarShortcut.theme.reflectsState)
        XCTAssertFalse(CandidateBarShortcut.keyboardMode.reflectsState)
        XCTAssertFalse(CandidateBarShortcut.scheme.reflectsState)
        XCTAssertFalse(CandidateBarShortcut.clearInput.reflectsState)
    }

    /// 能进候选栏的功能必须状态可着色：用户定的规矩——候选栏里点一下绿、再点一下灰，
    /// 状态永远读不出来的动作型（只是打开快捷面板、还要再选一次）不得进候选栏，
    /// 否则图标永远灰着没有状态可读
    func testEveryBarEligibleShortcutReflectsState() {
        for shortcut in CandidateBarShortcut.allCases where shortcut.isBarEligible {
            XCTAssertTrue(shortcut.reflectsState, "\(shortcut.id) 能进候选栏却状态不可着色，候选栏上无法呈现开/关状态")
        }
    }

    /// 名称跟行为对齐：候选栏那个图标点下去是看历史，不是翻记录开关；
    /// 执行开关动作的那颗芯片在快捷面板分区四，叫「记录剪贴板」，两者不得同名
    func testClipboardShortcutTitleNamesThePanelNotTheToggle() {
        XCTAssertTrue(CandidateBarShortcut.clipboardHistory.title.contains("历史"),
                      "候选栏剪贴板图标打开的是历史面板，名称必须说「历史」")
        XCTAssertFalse(CandidateBarShortcut.clipboardHistory.title.contains("记录"),
                       "名称里带「记录」会被当成开关，与快捷面板那颗开关撞语义")
    }

    func testBarEligibilityExcludesNavigationOnly() {
        // 可选池 = 一键直达：剪贴板历史 / 123 / 中英 / 候选注释 / 智能预测 / 动态调频
        XCTAssertTrue(CandidateBarShortcut.clipboardHistory.isBarEligible)
        XCTAssertTrue(CandidateBarShortcut.numberKeyboard.isBarEligible)
        XCTAssertTrue(CandidateBarShortcut.toggleEnglish.isBarEligible)
        XCTAssertTrue(CandidateBarShortcut.toggleAnnotation.isBarEligible)
        XCTAssertTrue(CandidateBarShortcut.togglePrediction.isBarEligible)
        XCTAssertTrue(CandidateBarShortcut.toggleDynamicFreq.isBarEligible)
        // 不收：二级入口（键盘形态/方案）、低频非开关（主题/清空输入）
        XCTAssertFalse(CandidateBarShortcut.keyboardMode.isBarEligible)
        XCTAssertFalse(CandidateBarShortcut.scheme.isBarEligible)
        XCTAssertFalse(CandidateBarShortcut.theme.isBarEligible)
        XCTAssertFalse(CandidateBarShortcut.clearInput.isBarEligible)
    }

    func testIconTextOnlyForLanguageToggle() {
        // 中/英用纯文字「En」图标（比地球/字更直白），其余用 SF Symbol
        XCTAssertEqual(CandidateBarShortcut.toggleEnglish.iconText, "En")
        for shortcut in CandidateBarShortcut.allCases where shortcut != .toggleEnglish {
            XCTAssertNil(shortcut.iconText, "\(shortcut.id) 不应有文字图标")
        }
    }

    // MARK: - resolve 映射（纯函数，不碰 App Group 单例）

    func testResolvePreservesOrder() {
        let ids = [CandidateBarShortcut.theme.rawValue,
                   CandidateBarShortcut.numberKeyboard.rawValue,
                   CandidateBarShortcut.clearInput.rawValue]
        XCTAssertEqual(CandidateBarShortcut.resolve(ids),
                       [.theme, .numberKeyboard, .clearInput],
                       "映射应保持用户排序")
    }

    func testResolveSkipsUnknownIDs() {
        let ids = [CandidateBarShortcut.theme.rawValue,
                   "some.unknown.id",
                   CandidateBarShortcut.clearInput.rawValue]
        XCTAssertEqual(CandidateBarShortcut.resolve(ids), [.theme, .clearInput],
                       "未知 id（版本回退可能出现）应被跳过")
    }

    func testResolveDeduplicates() {
        let theme = CandidateBarShortcut.theme.rawValue
        XCTAssertEqual(CandidateBarShortcut.resolve([theme, theme, theme]), [.theme],
                       "重复 id 只保留一次")
    }

    func testResolveEmptyReturnsEmpty() {
        XCTAssertTrue(CandidateBarShortcut.resolve([]).isEmpty,
                      "用户显式删空（stored = []）→ resolve 返回空 → 候选栏空态中段留白")
    }

    func testResolveRoundTripsAllCases() {
        // 全部 case 的 rawValue 都能被 resolve 还原，且保序
        let all = CandidateBarShortcut.allCases
        XCTAssertEqual(CandidateBarShortcut.resolve(all.map { $0.rawValue }), all)
    }

    func testDefaultOrderedIDsIsAllBarEligible() {
        // 首次安装（从未写入）默认全选，且顺序为 en→剪贴→调频→智能→注释→字符
        // （静态常量，不触碰 App Group 单例）
        let expectedOrder: [String] = [
            CandidateBarShortcut.toggleEnglish, .clipboardHistory, .toggleDynamicFreq,
            .togglePrediction, .toggleAnnotation, .numberKeyboard
        ].map(\.rawValue)
        XCTAssertEqual(CandidateBarShortcutStore.defaultOrderedIDs, expectedOrder,
                       "默认快捷条顺序应为 en→剪贴→调频→智能→注释→字符")
        // 且恰好覆盖全部 bar-eligible 功能（不漏不多）
        XCTAssertEqual(Set(CandidateBarShortcutStore.defaultOrderedIDs),
                       Set(CandidateBarShortcut.allCases.filter(\.isBarEligible).map(\.rawValue)),
                       "默认快捷条应覆盖全部 bar-eligible 功能")
    }
}
