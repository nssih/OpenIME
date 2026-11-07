import UIKit
import XCTest

final class OpenIMEUITests: XCTestCase {
    let app = XCUIApplication()

    /// 系统设置「添加新键盘」列表里本键盘的显示名：跟随 OpenIMEKeyboard/Info.plist
    /// 的 CFBundleDisplayName（App 中文名「聿·输入法」）。改显示名必须同步这里，
    /// 否则 enableKeyboardInSettingsIfNeeded 找不到行、真键盘端到端用例会被静默跳过。
    private let keyboardSettingsName = "聿·输入法"

    override func setUpWithError() throws {
        continueAfterFailure = true
        app.launch()
        sleep(3)
        resolvePastePermissionAlert(allow: false)
    }

    /// 系统「想从 X 粘贴」授权框：App 一启动就抓取剪贴板（MainTabView.onAppear →
    /// ClipboardCapture.captureIfNeeded），只要剪贴板有新内容就必然弹。没人点它，App 主线程就
    /// 一直挂在那次读取上，用例第一条 tap 会卡满 30 秒超时（实测整条用例跑 525 秒后失败）。
    /// 默认走 allow: false（点「不允许粘贴」）：允许会把 Mac 侧剪贴板内容当成一条历史记录写进用户的
    /// 剪贴板历史，测试不该给用户留这种垃圾数据；只有自己播了种子、需要它真入库的用例才点「允许」。
    ///
    /// 查的顺序必须是 SpringBoard 在前、App 在后：授权框由系统进程渲染，而此刻 App 主线程正挂在那次
    /// 粘贴板读取上（日志会先报「App event loop idle notification not received」），先查 App 的元素树
    /// 会 30 秒一次重试、最终整个 UI 查询超时报错，把整条用例直接带崩（实测如此）。
    /// SpringBoard 里命中就早退，根本不碰挂起的 App；两处都没弹则什么也不做。
    private func resolvePastePermissionAlert(allow: Bool) {
        // 完整文案之外的回落：某些系统版本按钮只写「允许」/「不允许」。用 BEGINSWITH 而不是
        // CONTAINS，「不允许粘贴」才不会被子串「允许」误命中（点错的代价是给用户写入垃圾历史）
        let wanted = allow ? "允许粘贴" : "不允许粘贴"
        let prefix = allow ? "允许" : "不允许"
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for host in [springboard, app] {
            let alert = host.alerts.firstMatch
            guard alert.waitForExistence(timeout: 2) else { continue }
            let exact = alert.buttons.matching(NSPredicate(format: "label == %@", wanted)).firstMatch
            let button = exact.exists ? exact : alert.buttons.matching(
                NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch
            guard button.exists else { return }
            button.tap()
            sleep(1)
            return
        }
    }

    // MARK: - 全功能 Smoke Test
    //
    // 意图（与最初版本一致）：五个 Tab 都能进去，每个 Tab 的关键内容真的渲染出来，
    // 并逐页截图留档（候选栏 / 注释行 / 键盘预览对不对，靠图看）。
    //
    // 维护备注：这套测试曾因界面文案重构而整体失效（「混打」改名「混合」、
    // 「候选栏高度」改由「候选大小」承担、「左侧 / 右侧功能键」「候选栏显示收起按钮」
    // 已从界面下线），但断言没跟着改，于是长期绿灯却没有保护作用。
    // 以后改界面文案时，必须同步改这里的断言 —— 断言对不上就等于是删掉了回归保护。

    func testSmokeAllFeatures() throws {
        snapshot("00_launch")

        // 1. 方案 Tab
        app.tabBars.buttons["方案"].tap(); sleep(2)
        XCTAssert(app.navigationBars["方案管理"].waitForExistence(timeout: 5),
                  "方案 Tab 应进入「方案管理」页")
        snapshot("01_scheme_tab")

        // 2. 键盘外观 Tab
        app.tabBars.buttons["键盘"].tap(); sleep(2)
        XCTAssert(app.navigationBars["键盘外观"].waitForExistence(timeout: 5),
                  "键盘 Tab 应进入「键盘外观」页")
        // 预览与实际键盘共用 KeyboardGridGeometry：能渲染出来，即说明正方形几何没算崩
        XCTAssert(app.descendants(matching: .any)["keyboardPreview"].waitForExistence(timeout: 5),
                  "键盘预览应存在并完成渲染")
        snapshot("02_keyboard_tab_top")
        // 滚动到页面底部的「键盘布局」Section（必须真的上屏，不能只是“存在于视图树”）
        requireOnScreen(app.staticTexts["行间距比例"], "键盘布局里的设置项应能滚到并可见")
        XCTAssert(app.staticTexts["键盘布局"].exists, "键盘布局 Section 标题应存在")
        snapshot("02_keyboard_tab_layout")

        // 3. 混合输入 Tab
        app.tabBars.buttons["混合"].tap(); sleep(2)
        XCTAssert(app.navigationBars["混合输入"].waitForExistence(timeout: 5),
                  "混合 Tab 应进入「混合输入」页")
        XCTAssert(app.staticTexts["打字测试"].exists, "混合页应有打字测试区")
        snapshot("03_mix_tab_empty")

        // 打字测试框：输入编码后候选区必须离开空状态（原测试就是靠这一步验证「打字链路通」）
        let testField = app.textFields.firstMatch
        XCTAssert(testField.waitForExistence(timeout: 5), "混合页应有编码输入框")
        testField.tap(); sleep(1)
        testField.typeText("zh"); sleep(2)
        XCTAssertEqual(testField.value as? String, "zh", "输入框应收到输入的编码")
        XCTAssertFalse(app.staticTexts["输入编码查看候选词"].exists,
                       "输入编码后应离开「输入编码查看候选词」空状态（说明查询已执行）")
        snapshot("04_mix_typing_zh")
        // 收键盘：打字区固定为页头后，app.swipeDown 的合成落点会掉在键盘上（而非 List），收不掉键盘、
        // 下方 List 又被键盘压住滚不动，后面的 requireOnScreen 便永远够不到设置项。改用真实用户的
        // 「点空白收键盘」：点打字区输出区（其 onTapGesture 会 resignFirstResponder）。
        app.staticTexts["选词后显示在此处..."].tap(); sleep(1)

        // 4. 候选注释 / 智能预测
        requireOnScreen(app.switches.matching(NSPredicate(format: "label CONTAINS '显示候选注释'")).firstMatch,
                        "候选注释开关应能滚到并可见")
        requireOnScreen(app.switches.matching(NSPredicate(format: "label CONTAINS '智能预测'")).firstMatch,
                        "智能预测开关应能滚到并可见")
        snapshot("05_mix_tab_bottom")

        // 5. 词典 Tab
        app.tabBars.buttons["词典"].tap(); sleep(2)
        XCTAssert(app.navigationBars["词典"].waitForExistence(timeout: 5),
                  "词典 Tab 应进入「词典」页")
        snapshot("06_words_tab")

        // 6. 关于 Tab
        app.tabBars.buttons["关于"].tap(); sleep(2)
        XCTAssert(app.navigationBars["关于"].waitForExistence(timeout: 5),
                  "关于 Tab 应进入「关于」页")
        snapshot("07_about_tab")
    }

    // MARK: - 键盘外观 / 布局设置专项测试
    //
    // 意图：外观页每个设置项都要能被找到（用户改不下去的项等于不存在）。
    // 断言与原版本的对应关系：
    //   「候选栏高度」改名为「候选大小」：候选字号本身就决定候选栏高度（见关于页参数说明）
    //   「左侧 / 右侧功能键」「候选栏显示收起按钮」已从界面下线，不再断言
    //   新增：键盘预览必须存在（与实际键盘同一套几何）

    func testKeyboardLayoutSettings() throws {
        app.tabBars.buttons["键盘"].tap(); sleep(2)

        XCTAssert(app.descendants(matching: .any)["keyboardPreview"].waitForExistence(timeout: 5),
                  "键盘预览应存在")

        // 主题
        XCTAssert(app.segmentedControls.buttons["浅色"].exists, "主题应有「浅色」")
        XCTAssert(app.segmentedControls.buttons["深色"].exists, "主题应有「深色」")
        XCTAssert(app.segmentedControls.buttons["跟随系统"].exists, "主题应有「跟随系统」")

        // 尺寸
        for title in ["键间距", "字母大小", "候选大小", "注释大小"] {
            XCTAssert(app.staticTexts[title].exists, "尺寸设置「\(title)」应存在")
        }
        snapshot("keyboard_settings_size")

        // 样式 / 背景：本页是「外层 ScrollView + 内层 Form」两层滚动，用 .slow 轻滚避免惯性冲过中部项
        for title in ["圆角", "主色调", "背景透明度"] {
            requireOnScreen(app.staticTexts[title], "设置项「\(title)」应能滚到并可见",
                            maxSwipes: 12, gentle: true)
        }
        snapshot("keyboard_settings_style")

        // 键盘布局（页面底部）：两层滚动都要走得通，用户才真能改到
        requireOnScreen(app.staticTexts["空格键标签"], "空格键标签输入框应能滚到并可见",
                        maxSwipes: 12, gentle: true)
        XCTAssert(app.staticTexts["行间距比例"].isHittable, "行间距比例应上屏可见")
        XCTAssert(app.staticTexts["键盘高度"].exists, "键盘布局里应有「键盘高度」调节项")
        XCTAssert(app.textFields.firstMatch.isHittable, "空格键标签应有可输入的输入框")
        snapshot("keyboard_layout_section")
    }

    // MARK: - 混合输入 Tab 打字截图
    //
    // 意图：用真实输入跑一遍混合查询，并留一张实机截图，人工核查候选颜色 / 注释行表现
    //（原来只截图不打字，看不出候选与注释到底对不对）。

    func testMixTabScreenshot() throws {
        app.tabBars.buttons["混合"].tap(); sleep(2)
        XCTAssert(app.navigationBars["混合输入"].waitForExistence(timeout: 5))

        let field = app.textFields.firstMatch
        XCTAssert(field.waitForExistence(timeout: 5), "混合页应有编码输入框")
        field.tap(); sleep(1)
        field.typeText("nihao"); sleep(2)
        snapshot("mix_tab_typing")

        XCTAssertEqual(field.value as? String, "nihao", "输入框应收到输入的编码")
        app.swipeDown(); sleep(1)   // 收键盘，避免影响后续用例
    }

    // MARK: - 方案能力收敛（键盘形态灰显 / 混打入口按方案显隐）
    //
    // 意图：能力模型的结论必须真的落到 UI 上 —— 两种键盘形态始终列出，主方案撑不起的
    // 标「不可用」（灰显而非隐藏）；拼音为主时混打页只剩一段说明，形码为主时混打开关回来。
    // 入口不见了而用户不知道为什么，是本组用例要挡住的回归。

    func testSchemeCapabilityConvergesUI() throws {
        selectTab("方案", showingNavBar: "方案管理")

        let pinyinKeyword = "拼音"
        let tigerKeyword = "虎码"
        let hasPinyin = schemeLabel(named: pinyinKeyword).exists
        let hasTiger = schemeLabel(named: tigerKeyword).exists
        try XCTSkipIf(!hasPinyin && !hasTiger, "环境里既没拼音也没形码方案，无法验证能力收敛")

        // 记住当前激活方案，用例结束时还原（测试不得改用户的方案选择）
        var keywords: [String] = []
        if hasPinyin { keywords.append(pinyinKeyword) }
        if hasTiger { keywords.append(tigerKeyword) }
        let original = activeScheme(among: keywords)

        // 1. 拼音为主：两种形态始终列出且全部可用；混打页不给开关，只给一段说明
        if hasPinyin {
            activateFromDetail(named: pinyinKeyword)
            // 激活是在详情页里做的，人还停在详情页，直接校验「方案能力」
            XCTAssert(requireOnScreen(app.staticTexts["方案能力"], "详情页应有「方案能力」一节"))
            XCTAssert(app.staticTexts["全拼 26 键"].exists, "能力一节应列出全拼 26 键")
            XCTAssert(app.staticTexts["小鹤双拼"].exists, "能力一节应列出小鹤双拼")
            XCTAssertFalse(app.staticTexts["不可用"].exists,
                           "全拼方案两种形态都可用，不该出现「不可用」标注")
            XCTAssertFalse(textContaining("可混入全拼词库").exists,
                           "拼音方案不支持混打，不该写「可混入」")
            snapshot("capability_detail_pinyin")
            app.navigationBars.buttons.firstMatch.tap(); sleep(2)

            selectTab("混合", showingNavBar: "混合输入")
            XCTAssert(requireOnScreen(textContaining("不支持混合输入"),
                                     "拼音为主时混打页应给出「不支持」说明",
                                     maxSwipes: 12, gentle: true))
            XCTAssertFalse(mixToggle.exists, "拼音为主时不该出现混打开关")
            snapshot("capability_mix_pinyin")
        }

        // 2. 形码为主：两种形态始终列出，但双拼标「不可用」；混打生效与否都不复活它
        if hasTiger {
            selectTab("方案", showingNavBar: "方案管理")
            activateFromDetail(named: tigerKeyword)
            app.navigationBars.buttons.firstMatch.tap(); sleep(2)

            selectTab("方案", showingNavBar: "方案管理")
            openSchemeDetail(named: tigerKeyword)
            XCTAssert(requireOnScreen(app.staticTexts["方案能力"], "详情页应有「方案能力」一节"))
            XCTAssert(app.staticTexts["全拼 26 键"].exists, "形码方案至少列出 26 键")
            // 双拼不隐藏，而是灰显列出并标「不可用」——参与方只贡献候选，不扩展形态
            XCTAssert(app.staticTexts["小鹤双拼"].exists, "双拼应始终列出（灰显而非隐藏）")
            XCTAssert(app.staticTexts["不可用"].exists, "形码撑不起双拼，应标注「不可用」")
            XCTAssert(textContaining("可混入全拼词库").exists, "形码方案应当可混打")
            snapshot("capability_detail_tiger")
            app.navigationBars.buttons.firstMatch.tap(); sleep(2)

            selectTab("混合", showingNavBar: "混合输入")
            XCTAssert(requireOnScreen(mixToggle, "形码为主时混打开关应能滚到并可见",
                                      maxSwipes: 12, gentle: true))
            snapshot("capability_mix_tiger")
        }

        // 还原：测试不得把用户的激活方案改掉
        selectTab("方案", showingNavBar: "方案管理")
        if let original { activateFromDetail(named: original) }
        app.navigationBars.buttons.firstMatch.tap(); sleep(1)
    }

    // MARK: - 真实用户模拟：打字测试区选词闭环
    //
    // 意图：用户视角把「输编码 → 出候选 → 点选上屏 → 清空 → 无效编码兜底」整条链走一遍。
    // 只断言「候选区离开空状态」是不够的：点了没反应 / 上屏不上屏才是用户真正感知的 bug。

    func testTypingTestFullUserFlow() throws {
        // 选词上屏闭环需要一个确定能出候选的拼音方案；先激活拼音（没有则跳过），
        // 用例结束还原用户原方案，测试不得改掉用户的方案选择。
        app.tabBars.buttons["方案"].tap(); sleep(2)
        guard schemeLabel(named: "拼音").exists else {
            throw XCTSkip("环境无拼音方案，无法验证选词上屏闭环")
        }
        var keywords: [String] = ["拼音"]
        if schemeLabel(named: "虎码").exists { keywords.append("虎码") }
        let original = activeScheme(among: keywords)
        activateFromDetail(named: "拼音")
        app.navigationBars.buttons.firstMatch.tap(); sleep(2)

        app.tabBars.buttons["混合"].tap(); sleep(2)
        XCTAssert(app.navigationBars["混合输入"].waitForExistence(timeout: 5))

        let field = app.textFields["mixCodeField"]
        XCTAssert(field.waitForExistence(timeout: 5), "混合页应有编码输入框")

        // 1. 输入 nihao，候选区必须出候选（用标识定位首选，不依赖聚合 label 文案）
        field.tap(); sleep(1)
        field.typeText("nihao"); sleep(2)
        let firstCandidate = app.buttons["mixCandidate-0"]
        XCTAssert(firstCandidate.waitForExistence(timeout: 5), "nihao 应出候选")
        snapshot("userflow_candidates_nihao")

        // 2. 点首选上屏：输出区离开占位态、编码被消费清空
        firstCandidate.tap(); sleep(1)
        XCTAssertFalse(app.staticTexts["选词后显示在此处..."].exists,
                       "选词后输出区应离开占位态（真的上屏了）")
        // 编码被消费的可靠信号：选词后 inputText 置空、candidates 清空，候选区必然回到空态。
        // 不读 field.value —— SwiftUI TextField 的 .value 在状态刚变更后拖影（时而读到占位符、
        // 时而读到旧值），而 staticText 空态文案是 @State 驱动的硬信号，抹不出拖影。
        XCTAssert(app.staticTexts["输入编码查看候选词"].waitForExistence(timeout: 3),
                  "选词后编码应被消费，候选区回到空态")
        snapshot("userflow_output_nihao")

        // 3. 清空输出（垃圾桶按钮）：占位文案回来
        app.buttons["trash"].firstMatch.tap(); sleep(1)
        XCTAssert(app.staticTexts["选词后显示在此处..."].waitForExistence(timeout: 3),
                  "清空后应回到占位态")

        // 4. 无效编码：必须明确告知「无候选」，而不是永远停在空状态让用户以为卡死
        field.tap(); sleep(1)
        field.typeText("zzzzz"); sleep(2)
        XCTAssert(app.staticTexts["无候选"].waitForExistence(timeout: 3),
                  "无效编码应显示「无候选」兜底态")
        snapshot("userflow_no_candidate")

        // 5. 清除按钮（x 图标）：回到空状态
        app.buttons["xmark.circle.fill"].firstMatch.tap(); sleep(1)
        XCTAssert(app.staticTexts["输入编码查看候选词"].waitForExistence(timeout: 3),
                  "清除编码后应回到空状态")
        app.swipeDown(); sleep(1)

        // 还原用户原方案
        app.tabBars.buttons["方案"].tap(); sleep(2)
        if let original { activateFromDetail(named: original) }
        app.navigationBars.buttons.firstMatch.tap(); sleep(1)
    }

    // MARK: - 真实用户模拟：开关可达与破坏性操作二次确认
    //
    // 意图：开关必须用户滚得到、点得动（可交互）；破坏性操作必须经过 alert 二次确认。
    // 注意：不靠 tap 后读 switch.value 来断言状态翻转 —— SwiftUI List 里的 Toggle
    // 的 tap/value 读不稳（见经验 75fffc67），改用「存在+可交互+弹框」这类结构信号。

    func testSettingsTogglesAndConfirmDialogs() throws {
        app.tabBars.buttons["混合"].tap(); sleep(2)
        XCTAssert(app.navigationBars["混合输入"].waitForExistence(timeout: 5))

        // 开关：必须能滚到、可交互（拨不动的开关等于设置项失效）
        let prediction = switchContaining("智能预测")
        let annotation = switchContaining("显示候选注释")
        XCTAssert(requireOnScreen(prediction, "智能预测开关应能滚到并可见"))
        XCTAssertTrue(prediction.isEnabled, "智能预测开关应可交互")
        XCTAssert(requireOnScreen(annotation, "候选注释开关应能滚到并可见"))
        XCTAssertTrue(annotation.isEnabled, "候选注释开关应可交互")

        // 清除预测记录：破坏性操作必须弹 alert 二次确认，取消不执行
        let clearButton = app.buttons.matching(NSPredicate(format: "label CONTAINS '清除预测记录'")).firstMatch
        XCTAssert(requireOnScreen(clearButton, "清除预测记录按钮应能滚到并可见"))
        clearButton.tap(); sleep(1)
        XCTAssert(app.alerts["清除预测记录"].waitForExistence(timeout: 3),
                  "破坏性操作应弹二次确认 alert")
        app.alerts.buttons["取消"].tap(); sleep(1)
        XCTAssertFalse(app.alerts["清除预测记录"].exists, "取消后 alert 应关闭")
        snapshot("userflow_alert_cancelled")
    }

    // MARK: - 真实用户模拟：键盘外观页交互
    //
    // 意图：主题切换、滑杆拖动、空格键标签输入都要真的可操作且状态可见；测完恢复原值。

    func testKeyboardAppearanceInteractions() throws {
        selectTab("键盘", showingNavBar: "键盘外观")

        // 1. 主题分段控件：点「深色」必须真的选中，测完拨回原主题
        let theme = app.segmentedControls.firstMatch
        let originalTheme = ["浅色", "深色", "跟随系统"].first { theme.buttons[$0].isSelected }
        theme.buttons["深色"].tap(); sleep(1)
        XCTAssert(theme.buttons["深色"].isSelected, "点「深色」后分段控件应选中深色（预览同步变暗）")
        snapshot("userflow_theme_dark")
        if let originalTheme, originalTheme != "深色" {
            theme.buttons[originalTheme].tap(); sleep(1)
            XCTAssert(theme.buttons[originalTheme].isSelected, "主题应能拨回原选择")
        }

        // 2. 滑杆：键间距必须拖得动（拖不动的滑杆等于设置项失效）。
        // 本页是「外层 ScrollView + 内层 Form」两层滚动，必须用轻滚：默认快甩的惯性会甩过目标行，
        // 上屏判定永远不成立（实测：默认参数下甩 6 次都滚不到「空格键标签」，同一页的
        // testKeyboardLayoutSettings 用轻滚一次就到）。
        XCTAssert(requireOnScreen(app.sliders.firstMatch, "尺寸滑杆应能滚到并可见",
                                  maxSwipes: 12, gentle: true))
        // 滑杆值就是用户设置（本页第一个滑杆是「键间距 0…20pt」），拖完必须拨回去：
        // 之前只拖不还原，跑完一次 UI 套件用户的键间距就停在拖到的位置，违反共享容器零污染
        let originalSliderValue = sliderValue(at: 0)
        app.sliders.element(boundBy: 0).adjust(toNormalizedSliderPosition: 0.7); sleep(1)
        let movedValue = sliderValue(at: 0)
        app.sliders.element(boundBy: 0).adjust(toNormalizedSliderPosition: 0.4); sleep(1)
        snapshot("userflow_slider_adjusted")
        XCTAssertNotEqual(movedValue, originalSliderValue,
                          "拖到 0.7 后读值应变化（拖不动的滑杆等于设置项失效）")
        restoreSlider(at: 0, to: originalSliderValue)

        // 3. 空格键标签输入框：用户滚得到、点得动、可编辑（真实打字已由词典页用例覆盖；
        // 此字段退格清空在模拟器上不稳，不在这里做输入回写，只验证控件可用）
        XCTAssert(requireOnScreen(app.staticTexts["空格键标签"], "空格键标签应能滚到并可见",
                                  maxSwipes: 12, gentle: true))
        let labelField = app.textFields.firstMatch
        XCTAssertTrue(labelField.exists && labelField.isHittable && labelField.isEnabled,
                      "空格键标签输入框应存在、可点、可编辑")
        app.swipeDown(); sleep(1)
    }

    // MARK: - 真实用户模拟：词典页增删查 + 剪贴板入口
    //
    // 意图：自定义词条「加→搜→删」闭环与剪贴板历史入口导航都必须真实可用；
    // 测完删除临时词条，不污染用户词典。

    func testDictionaryWordManagementFlow() throws {
        app.tabBars.buttons["词典"].tap(); sleep(2)
        XCTAssert(app.navigationBars["词典"].waitForExistence(timeout: 5))

        // 1. 添加词条：右上角 + → 填词与编码 → 保存（缺一必填项时保存键应禁用）
        app.navigationBars.buttons["plus"].tap(); sleep(2)
        XCTAssert(app.navigationBars["添加词条"].waitForExistence(timeout: 5), "点 + 应弹出添加词条页")
        let saveButton = app.navigationBars.buttons["保存"]
        XCTAssert(saveButton.exists && !saveButton.isEnabled, "词与编码都空着时「保存」应禁用")
        let textInput = app.textFields["词（如：你好世界）"]
        let codeInput = app.textFields["编码（如：nihaoshijie）"]
        textInput.tap(); textInput.typeText("测试词条甲")
        codeInput.tap(); codeInput.typeText("ceshicijia"); sleep(1)
        XCTAssert(saveButton.isEnabled, "两项都填好后「保存」应可点")
        saveButton.tap(); sleep(2)

        // 2. 新词条应出现在列表顶部（按创建时间倒序）
        let wordRow = app.staticTexts["测试词条甲"]
        XCTAssert(wordRow.waitForExistence(timeout: 5), "保存后列表应出现新词条")
        snapshot("userflow_word_added")

        // 3. 搜索过滤：搜得到→搜不到→清空恢复
        let searchField = app.navigationBars.searchFields.firstMatch
        if searchField.exists {
            searchField.tap(); searchField.typeText("ceshicijia"); sleep(1)
            XCTAssert(wordRow.exists, "按编码搜索应命中新词条")
            searchField.clearText()
            searchField.typeText("不存在zzz"); sleep(1)
            XCTAssertFalse(wordRow.exists, "搜索不命中时新词条应被过滤掉")
            searchField.clearText(); sleep(1)
            app.swipeDown(); sleep(1)
        }

        // 4. 剪贴板历史入口：推进子页再退回来
        let clipboardEntry = app.staticTexts["剪贴板历史"]
        XCTAssert(clipboardEntry.waitForExistence(timeout: 5), "词典页应有剪贴板历史入口")
        clipboardEntry.tap(); sleep(2)
        XCTAssert(app.navigationBars.buttons.count > 0, "应推进剪贴板历史子页")
        snapshot("userflow_clipboard_page")
        app.navigationBars.buttons.firstMatch.tap(); sleep(2)
        XCTAssert(app.navigationBars["词典"].waitForExistence(timeout: 5), "应能退回词典页")

        // 5. 删除临时词条：左滑→删除→确认消失（不留垃圾数据）
        XCTAssert(requireOnScreen(wordRow, "新词条应能滚到并可见"))
        wordRow.swipeLeft(); sleep(1)
        let deleteButton = app.buttons["删除"]
        XCTAssert(deleteButton.waitForExistence(timeout: 3), "左滑应露出删除按钮")
        deleteButton.tap(); sleep(2)
        XCTAssertFalse(wordRow.exists, "删除后词条应从列表消失")
        snapshot("userflow_word_deleted")
    }

    // MARK: - 真实用户模拟：剪贴板历史「编辑态红圈逐条删除」
    //
    // 意图：历史区改成固定高度框内滚动后，List 的左滑删除与 EditButton 都够不到这些行了，
    // 「只删掉某一条」全压在编辑态每行前面那个红圈上（ClipboardHistoryView.historyRow）。
    // 它一旦接错 —— 点了不删、删了列表不刷新、退出编辑态红圈不收起（留着就是误删风险）——
    // 用户就没有任何逐条删除的通道，而这条通道此前没有回归保护。
    //
    // 零污染：删的必须是本用例自己播进去的那一条。种子用带时间戳的唯一文本，只点最上面的红圈
    //（新内容恒插首位，见 ClipboardHistoryStore.append），用户既有历史一条不碰；
    // 记录开关原本是关的会临时打开（关着时抓取直接 return，种子进不了库），验完立即还原。

    func testClipboardEditDeleteFlow() throws {
        // 1. 进剪贴板历史页，记下记录开关原状
        openClipboardHistoryPage()
        let toggle = switchContaining("记录剪贴板历史")
        XCTAssert(toggle.waitForExistence(timeout: 5), "剪贴板历史页应有记录开关")
        let wasEnabled = (toggle.value as? String) == "1"
        if !wasEnabled { toggle.tap(); sleep(1) }

        // 2. 播种：从测试进程写一条带时间戳的文本到模拟器共享剪贴板，重启 App 触发抓取。
        // 这一步必须点「允许粘贴」（与 setUp 相反）：不点就读不到内容，条目进不了历史，删除无从验证。
        let marker = "UI测试剪贴板\(Int(Date().timeIntervalSince1970))"
        UIPasteboard.general.string = marker
        app.terminate(); sleep(1)
        app.launch(); sleep(3)
        resolvePastePermissionAlert(allow: true)

        // 3. 回页确认种子条目已入库；播不进去（系统授权框形态变了、跨进程剪贴板不可见）
        // 就不做任何破坏性点击，如实报跳过，不拿假绿灯糊弄，也不误删用户的记录
        openClipboardHistoryPage()
        let seededRow = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", marker)).firstMatch
        guard seededRow.waitForExistence(timeout: 5) else {
            restoreClipboardToggle(wasEnabled: wasEnabled)
            snapshot("clipboard_seed_missing")
            throw XCTSkip("测试进程写的剪贴板内容没进历史（系统授权环节变化），无法验证删除")
        }
        // 开关尽早还原：后面的断言就算失败，也不会给用户留下改掉的设置
        restoreClipboardToggle(wasEnabled: wasEnabled)
        snapshot("clipboard_seeded")

        // 4. 进编辑态：红圈必须出现且真的点得到（exists 不代表上屏，被遮挡或热区为零靠 isHittable 才挡得住）
        let editButton = app.navigationBars.buttons["编辑"]
        XCTAssert(editButton.waitForExistence(timeout: 5), "导航栏应有「编辑」")
        editButton.tap(); sleep(1)
        let circle = app.buttons["clipboardDeleteButton"].firstMatch
        XCTAssert(circle.waitForExistence(timeout: 5), "编辑态应在行首出现红圈删除按钮")
        XCTAssert(circle.isHittable, "红圈应真的可点")
        snapshot("clipboard_edit_mode")

        // 5. 点最上面的红圈 = 删刚播的那一条，列表应立刻刷新掉它（锁住 deleteItem 接线与 reload）
        circle.tap(); sleep(2)
        XCTAssertFalse(
            app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", marker)).firstMatch.exists,
            "点红圈后该条记录应从历史列表消失")
        snapshot("clipboard_after_delete")

        // 6. 退出编辑态：红圈应全部收起
        let doneButton = app.navigationBars.buttons["完成"]
        XCTAssert(doneButton.waitForExistence(timeout: 5), "编辑态下导航栏应变成「完成」")
        doneButton.tap(); sleep(1)
        XCTAssertFalse(app.buttons["clipboardDeleteButton"].exists,
                       "退出编辑态后不应再有红圈删除按钮")
    }

    // MARK: - 真实用户模拟：真键盘逐键打字（类 Playwright 端到端）
    //
    // 意图：在真实宿主 App（Safari 地址栏）里唤起 OpenIME 键盘扩展，逐键点击 n-i-h-a-o，
    // 验证候选出得对、再把首候选上屏，确认文本真的进了宿主输入框 —— 这是用户每天在走的链路。
    // 手法沿用已验证的经验：扩展内视图用 descendants+identifier 查；输入源用 nextKeyboard 切到
    // 目标键盘（短按循环 + 长按弹输入源列表两条路，见 cycleToOpenIME），并以空格键 spaceKey
    // 为「已唤起」判据。
    // 宿主 App / 扩展不可用时一律 XCTSkip（不误报红），真失败只在扩展已唤起但链路断时。
    //
    // 拼音前提：本用例断的是「nihao → 你好」，只有拼音方案给得出这个候选。用户当前用形码时
    //（实测：虎码下敲 nihao 出的是「成绩单间」这类形码候选），结果就取决于用户手上选哪个方案 ——
    // 那是随机红/绿而不是回归保护，所以这里先临时切到拼音、无论结果如何都还原。

    func testRealKeyboardTypingInHostApp() throws {
        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        let prefs = XCUIApplication(bundleIdentifier: "com.apple.Preferences")

        // 1. 确保键盘扩展已添加且允许完全访问。
        // 加不上就当场停：之前这里不看结果往下走，到 Safari 里才报「切不到键盘」，
        // 把「键盘没装」和「测试找不到切换键」两种原因揉成同一条跳过信息，查不下去
        guard enableKeyboardInSettingsIfNeeded(prefs) else {
            throw XCTSkip("系统键盘列表里没有聿·输入法且自动添加未成功（设置 → 通用 → 键盘 → 添加新键盘）")
        }

        // 2. 把输入方案固定为拼音（defer 保证失败/跳过路径上也能还原用户原方案）
        selectTab("方案", showingNavBar: "方案管理")
        guard schemeLabel(named: "拼音").exists else {
            throw XCTSkip("环境无拼音方案，无法验证拼音端到端打字")
        }
        var keywords = ["拼音"]
        if schemeLabel(named: "虎码").exists { keywords.append("虎码") }
        let original = activeScheme(among: keywords)
        activateFromDetail(named: "拼音")
        app.navigationBars.buttons.firstMatch.tap(); sleep(2)
        defer { restoreActiveScheme(original) }

        // 3. Safari 里聚焦地址栏，循环切到 OpenIME
        //
        // 为什么逐个试而不是直接取 textFields.firstMatch：见 focusHostField。
        safari.activate(); sleep(3)
        guard let hostField = focusHostField(in: safari) else {
            // 跳过也要留现场：不填进跳过原因，后面只能看到「切不到键盘」这句结论而看不到当时屏上是什么
            let kbCount = safari.keyboards.count
            snapshot("realkeyboard_no_keyboard")
            safari.terminate()
            throw XCTSkip("Safari 里试过多个输入元素都没能唤起键盘"
                + "（safari.keyboards=\(kbCount)），无法驱动真键盘")
        }
        snapshot("realkeyboard_ready")

        // 4. 逐键点击 nihao：每个键都必须可点（点不动的键就是 bug）
        //
        // 每键前先确认本 App 键盘还在：iOS 会在某些宿主输入框里自己把输入源换回系统英文键盘
        //（现场图 realkeyboard_key_missing_o：键面变大写、空格键角标「A」、蓝色搜索键），
        // 那不是扩展崩了（崩溃目录里没有任何 OpenIMEKeyboard 记录，且同一份代码单独跑是通的）。
        // 换源归因与处置见 ensureOpenIMEKeyboard：切不回来才算失败。
        for letter in ["n", "i", "h", "a", "o"] {
            guard ensureOpenIMEKeyboard(in: safari, beforeKey: letter) else {
                safari.terminate()
                return XCTFail("打\(letter) 前系统把输入源换走了，且切不回聿·输入法键盘")
            }
            let key = safari.descendants(matching: .any)[letter].firstMatch
            guard key.waitForExistence(timeout: 3), key.isHittable else {
                snapshot("realkeyboard_key_missing_\(letter)")
                safari.terminate()
                return XCTFail("字母键 \(letter) 应存在且可点")
            }
            key.tap(); sleep(1)
        }
        sleep(2)
        snapshot("realkeyboard_typed_nihao")

        // 5. 候选内容对不对：必须按槽位标识（candidate-N）定位，全 app 按文字找会先命中
        // Safari 自己的建议行（实测：系统 QuickType 建议里就有「你好」行，点了它地址栏纹丝不动）
        let firstSlot = safari.buttons["candidate-0"]
        XCTAssert(firstSlot.waitForExistence(timeout: 5), "敲完 nihao 应出现候选")
        let cand0 = firstSlot.label
        XCTAssert(cand0.hasPrefix("你好"), "拼音 nihao 的首选应是「你好」（实际：\(cand0)）")
        snapshot("realkeyboard_candidate")

        // 6. 首候选上屏：按空格把首选送进宿主输入框，跑完「敲键 → 解码 → 候选 → 上屏」整条链。
        //
        // 为什么这里用空格而不是点候选格：点候选格是另一条独立接线，单独由
        // testRealKeyboardCandidateCellTap 覆盖（在那里实测：格子的 frame 可信、元素级 tap 命中）；
        // 本用例负责的是「逐键编码 + 空格选首」这条用户高频链路，两者不重叠。
        let space = safari.descendants(matching: .any)["spaceKey"].firstMatch
        XCTAssert(space.waitForExistence(timeout: 5), "键盘应有空格键")
        space.tap(); sleep(2)
        // 编码被消费的硬信号：候选栏回到空态（左侧菜单标志回来）
        XCTAssert(safari.descendants(matching: .any)["candidateBarLogo"].waitForExistence(timeout: 5),
                  "按空格后编码应被消费，候选栏应回到空态")
        // 只断 contains 不断等值：内嵌编码走 markedText，最终读值由宿主怎么处置它决定 ——
        // 实测同一个地址栏在拼音下干净替换成「你好」（见 realkeyboard_committed 截图），
        // 另一次在形码方案下留下「nihao成绩单间」，而本 App 自己的输入框只读得到「你好」。
        // 本用例要断的是「候选真的送进了宿主」，不是宿主对 markedText 的处置方式，
        // 所以下限用 contains，不把某个宿主的观感写死成断言。
        let hostValue = (hostField.value as? String) ?? ""
        snapshot("realkeyboard_committed")
        XCTAssert(hostValue.contains("你好"), "首候选「你好」应真的上屏到地址栏（实际：\(hostValue)）")

        // 7. 恢复：切回系统键盘再退出，不把用户留在第三方键盘上
        switchBackToSystemKeyboard(in: safari)
        safari.terminate()
    }

    // MARK: - 真实用户模拟：键盘候选格点选（槽位顺序 + 点选上屏）
    //
    // 这条用例推翻了写在旧注释里的自动化结论：「扩展里 ScrollView 的候选格在 XCUITest 下点不动，
    // 四种手法全无反应，只能人工验收」。在 iPhone 16e 模拟器重测的事实：candidate-0 的 frame
    // 完全可信（12, 583.7, 36, 26.3 —— 与候选栏几何一致），isHittable = true，元素级 tap 与
    // 按该 frame 中心的坐标 tap 都能命中：点完编码立刻被消费、候选栏回到空态。
    // 老结论错在把「按候选文字在全 app 里找元素」找到的宿主同字行当成了键盘里的格子。
    //
    // 于是这个此前只能人工验收的环节现在有了两层回归：
    //   1. 槽位顺序：candidate-N 就是引擎的第 N 个候选（拼音 nihao 第一格必须是「你好」）；
    //   2. 点选接线：点第 2 格真的走 onSelect → selectCandidate → 上屏（硬信号是候选栏回空态）。
    // 特意点 candidate-1 而不是 candidate-0：空格首候选已由逐键打字用例覆盖，
    // 只有点非首格才能把「格 ↔ 候选下标」这条映射一并钉住。
    func testRealKeyboardCandidateCellTap() throws {
        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        let prefs = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        guard enableKeyboardInSettingsIfNeeded(prefs) else {
            throw XCTSkip("系统键盘列表里没有聿·输入法且自动添加未成功（设置 → 通用 → 键盘 → 添加新键盘）")
        }
        // 候选内容断言依赖拼音（形码下敲 nihao 出的是另一批字），测完还原用户原方案
        selectTab("方案", showingNavBar: "方案管理")
        guard schemeLabel(named: "拼音").exists else {
            throw XCTSkip("环境无拼音方案，无法验证候选格点选")
        }
        var keywords = ["拼音"]
        if schemeLabel(named: "虎码").exists { keywords.append("虎码") }
        let original = activeScheme(among: keywords)
        activateFromDetail(named: "拼音")
        app.navigationBars.buttons.firstMatch.tap(); sleep(2)
        defer { restoreActiveScheme(original) }

        safari.activate(); sleep(3)
        guard let hostField = focusHostField(in: safari) else {
            snapshot("candtap_no_keyboard")
            safari.terminate()
            throw XCTSkip("Safari 里试过若干输入元素都没能唤起键盘，无法驱动真键盘")
        }
        for letter in ["n", "i", "h", "a", "o"] {
            guard ensureOpenIMEKeyboard(in: safari, beforeKey: letter) else {
                safari.terminate()
                return XCTFail("打 \(letter) 前系统把输入源换走了，且切不回聿·输入法键盘")
            }
            let key = safari.descendants(matching: .any)[letter].firstMatch
            guard key.waitForExistence(timeout: 3), key.isHittable else {
                snapshot("candtap_key_missing_\(letter)")
                safari.terminate()
                return XCTFail("字母键 \(letter) 应存在且可点")
            }
            key.tap(); sleep(1)
        }
        sleep(2)

        // 1. 槽位顺序：candidate-N 必须就是第 N 个候选
        let firstSlot = safari.buttons["candidate-0"]
        let secondSlot = safari.buttons["candidate-1"]
        XCTAssert(firstSlot.waitForExistence(timeout: 5), "敲完 nihao 应有第一格候选")
        XCTAssert(secondSlot.waitForExistence(timeout: 5), "拼音 nihao 应有多于一个候选")
        let firstText = firstSlot.label
        let secondText = secondSlot.label
        XCTAssertTrue(firstText.hasPrefix("你好"), "第 1 格应是「你好」（实际：\(firstText)）")
        XCTAssertNotEqual(secondText, firstText, "第 2 格不该与第 1 格同字（否则测不出槽位错位）")
        snapshot("candtap_slots_ordered")

        // 2. 点第 2 格：编码被消费的硬信号 = 候选栏回到空态（左侧菜单标志回来）
        XCTAssertTrue(secondSlot.isHittable, "候选格应真的可点（扩展 ScrollView 内容在宿主镜像树里也有命中几何）")
        // 点非首候选是真真实实的主动选词，会被拼音动态调频学进 App Group 的学习表：
        // 不清掉的话，下一次跑单测时「nihao 首选你好」会被这条学习记录顶成「你好吗」
        //（实测栽过：2 条无关单测漂红）。所以学完必须清，且失败路径上也要清 —— 放 defer。
        defer { clearFrequencyLearning() }
        secondSlot.tap(); sleep(2)
        XCTAssert(safari.descendants(matching: .any)["candidateBarLogo"].waitForExistence(timeout: 5),
                  "点第 2 格后编码应被消费，候选栏应回到空态")

        // 3. 上屏文本：宿主读得到值时连内容一起断，钉住「送出去的就是这一格的候选」。
        // Safari 地址栏的 value 在 markedText 场景里读不稳（实验实测时而空串），读不到
        // 就不把它写成硬断言 —— 上面「编码被消费」已经把接线锁住，这里只补强不造红灯。
        let hostNow = (hostField.value as? String) ?? ""
        snapshot("candtap_committed")
        if hostNow.isEmpty {
            print("CANDTAP 宿主 value 读不到（Safari markedText 已知不稳），仅以候选栏回空态为凭")
        } else {
            XCTAssertTrue(hostNow.contains(secondText),
                          "上屏的应是第 2 格「\(secondText)」，实际宿主内容：\(hostNow)")
        }

        switchBackToSystemKeyboard(in: safari)
        safari.terminate()
    }

    // MARK: - 工具

    /// 在宿主 App 里找一个「点了能把本 App 键盘带起来」的输入框，返回那个元素。
    /// 不能直接 textFields.firstMatch：实测它会命中 Safari 底部标签栏条目（identifier =
    /// TabBarItemTitle，在 Safari 里也被报成 TextField），点它焦点进不了地址栏、键盘根本不出现；
    /// 而那次留下来的只是上一轮残留在 Safari 上的键盘状态，等于拿环保证当证据。
    /// 所以判据只看「点完这个元素，本 App 键盘真的起来了没有」。
    private func focusHostField(in host: XCUIApplication) -> XCUIElement? {
        let fieldCandidates = (host.textFields.allElementsBoundByIndex
            + host.searchFields.allElementsBoundByIndex)
            .filter { $0.identifier != "TabBarItemTitle" }
        for field in fieldCandidates {
            field.tap(); sleep(2)
            if cycleToOpenIME(in: host) { return field }
        }
        return nil
    }

    /// 逐键点击前先确认本 App 键盘还在：实测在 Safari 起始页搜索框里打完 n-i-h-a 之后，
    /// iOS 会自己把输入源换回系统英文键盘（现场图键面变大写、空格键角标「A」、蓝色搜索键），
    /// 那不是扩展崩了（崩溃目录里没有任何 OpenIMEKeyboard 记录）。换源是宿主输入框带的
    /// 键盘助手条 / 自动纠错引发的行为，本 App 管不了；但测试既不能被它绊红，也不能装看不见：
    /// 换走就切回来，切不回来由调用方判失败。
    private func ensureOpenIMEKeyboard(in host: XCUIApplication, beforeKey letter: String) -> Bool {
        if openIMEKeyboardUp(in: host) { return true }
        snapshot("realkeyboard_swapped_before_\(letter)")
        return cycleToOpenIME(in: host, shortRounds: 4)
    }

    /// 切 Tab 并确认切到了目标页。tab 的点选在页面转场未完成时会打偏：实测从方案详情页返回后
    /// 立刻点「混合」，结果停在了「关于」页，后面 6 次滚动全在错误的页面上白做，
    /// 失败信息看起来像「开关滚不到」，查不到真正的原因。所以点完用导航栏标题验一次，没中就再点。
    private func selectTab(_ tab: String, showingNavBar title: String) {
        for _ in 0..<3 {
            app.tabBars.buttons[tab].tap()
            sleep(2)
            if app.navigationBars[title].waitForExistence(timeout: 2) { return }
        }
        XCTFail("点「\(tab)」tab 应进入「\(title)」页")
    }

    /// 把激活方案还回用户原选择。给 defer 用，所以只能做 UI 操作、不再加断言。
    /// 调用方可能刚把焦点交给别的 App（真键盘端到端用例），所以先 activate 回自己。
    private func restoreActiveScheme(_ original: String?) {
        guard let original else { return }
        app.activate(); sleep(2)
        app.tabBars.buttons["方案"].tap(); sleep(2)
        activateFromDetail(named: original)
        app.navigationBars.buttons.firstMatch.tap(); sleep(1)
    }

    /// 混打页的总开关（文案与 MixInputSettingsView 里的 Toggle 一致）
    private var mixToggle: XCUIElement {
        app.switches.matching(NSPredicate(format: "label CONTAINS '参与混合输入'")).firstMatch
    }

    /// 方案列表里名字包含关键字的那一行文本。
    /// SwiftUI 的 NavigationLink 行不把方案名并进 cell 的聚合 label（实测 cell.label 为空），
    /// 所以按 staticTexts 定位；点它等价于点整行，会推进详情页。
    private func schemeLabel(named keyword: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", keyword)).firstMatch
    }

    /// 进方案详情页
    private func openSchemeDetail(named keyword: String) {
        let label = schemeLabel(named: keyword)
        guard label.waitForExistence(timeout: 5) else { return XCTFail("找不到方案行：\(keyword)") }
        label.tap(); sleep(2)
    }

    /// 在详情页里激活方案：已经是当前方案时那一行显示「当前使用中」，没有按钮可点。
    /// 走详情页而不是列表行尾的「激活」按钮，是因为列表里同名按钮有多个、且 cell label 匹配不到行。
    /// 调用结束后人停在详情页。
    private func activateFromDetail(named keyword: String) {
        openSchemeDetail(named: keyword)
        let button = app.buttons["激活此方案"]
        guard button.waitForExistence(timeout: 5) else { return }   // 已经是使用中
        button.tap(); sleep(3)
    }

    /// 逐个打开详情页看「当前使用中」，找出当前激活方案（列表徽标与方案名的相邻关系不可靠）
    private func activeScheme(among keywords: [String]) -> String? {
        for keyword in keywords {
            openSchemeDetail(named: keyword)
            let isActive = app.staticTexts["当前使用中"].exists
            app.navigationBars.buttons.firstMatch.tap(); sleep(2)
            if isActive { return keyword }
        }
        return nil
    }

    /// 文本包含关键字的静态元素：混打页说明、能力一节的「可混入全拼词库」这类较长文案，
    /// 按完整文本索引取不到，只能用 CONTAINS 匹配
    private func textContaining(_ keyword: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", keyword)).firstMatch
    }

    /// 清除动态调频学习记录（共享容器零污染）。
    /// 走 App 自己的「清除调频记录」按钮 + 二次确认：UI 测试 target 不挂 App Group，
    /// 碰不到容器里的 user/frequency.json，只有这条 UI 通道能真的把它清掉。
    /// 给 defer 用，但清不干净必须报红：残留会把下一次跑的单测候选断言带飘（已栽过）。
    private func clearFrequencyLearning() {
        app.activate(); sleep(2)
        selectTab("混合", showingNavBar: "混合输入")
        let clearButton = app.buttons.matching(NSPredicate(format: "label CONTAINS '清除调频记录'")).firstMatch
        guard requireOnScreen(clearButton, "清除调频记录按钮应能滚到并可见") else { return }
        clearButton.tap(); sleep(1)
        XCTAssert(app.alerts["清除调频记录"].waitForExistence(timeout: 3),
                  "破坏性操作应弹二次确认 alert")
        app.alerts.buttons["清除"].tap(); sleep(1)
    }

    /// 当前页面的主滚动容器（设置 List / Form）。
    /// 手势必须发给这个纵向容器而不是整个 app：底部 Section 往往要它自己滚才能上屏。
    /// 优先取显式标识的容器 —— 混合页把「打字测试区」固定为常驻页头后，页头里的横向候选
    /// ScrollView 也是 collectionView 且排在纵向设置 List 之前，firstMatch 会误取到它（对它 swipeUp
    /// 不滚动设置项，requireOnScreen 便永远够不到下沿的行：顶部的智能预测仍可见、下方的候选注释始终不可点）；
    /// 标识锁定的 List 不受此影响。取不到标识再回落到原有 table/collectionView 启发式（其它页零影响）。
    private var scrollableContainer: XCUIElement {
        let identified = app.descendants(matching: .any)["mixSettingsList"]
        if identified.exists { return identified }
        if app.tables.firstMatch.exists { return app.tables.firstMatch }
        if app.collectionViews.firstMatch.exists { return app.collectionViews.firstMatch }
        return app
    }

    /// 一直往下滚，直到元素真的上屏可见（isHittable）为止。
    /// 只判 exists 是不够的：Form / List 是惰性渲染的，屏幕外的行可能在视图树里“存在”但永远没出现在
    /// 屏幕上，那样的断言会给假绿灯 —— 而测试的目的就是保证用户点得到这些设置项。
    /// velocity 默认不传（与历史行为一致）；对「外层 ScrollView + 内层 Form」两层滚动、
    /// 且内容较高的页面（如键盘外观页），默认惯性甩动会一次冲过中部项、up-only 又无法回退，
    /// 这类调用传 gentle: true 轻滚（配更大的 maxSwipes）即可稳定命中。
    @discardableResult
    private func requireOnScreen(_ element: XCUIElement,
                                _ message: String,
                                maxSwipes: Int = 6,
                                gentle: Bool = false) -> Bool {
        for _ in 0...maxSwipes {
            if element.exists && element.isHittable { return true }
            if gentle {
                scrollableContainer.swipeUp(velocity: .slow)
            } else {
                scrollableContainer.swipeUp()
            }
            sleep(1)
        }
        XCTFail(message)
        return false
    }

    private func snapshot(_ name: String) {
        let s = XCUIScreen.main.screenshot()
        let a = XCTAttachment(screenshot: s); a.name = name; a.lifetime = .keepAlways; add(a)
    }

    /// 按包含关键字定位开关（SwiftUI Toggle 的聚合 label = 标题 + 副标题）
    private func switchContaining(_ keyword: String) -> XCUIElement {
        app.switches.matching(NSPredicate(format: "label CONTAINS %@", keyword)).firstMatch
    }

    /// 词典 Tab → 剪贴板历史子页（剪贴板相关用例都从这里进）
    private func openClipboardHistoryPage() {
        app.tabBars.buttons["词典"].tap(); sleep(2)
        XCTAssert(app.navigationBars["词典"].waitForExistence(timeout: 5), "应进入「词典」页")
        app.staticTexts["剪贴板历史"].tap(); sleep(2)
        XCTAssert(app.navigationBars["剪贴板历史"].waitForExistence(timeout: 5), "应进入剪贴板历史页")
    }

    /// 还原「记录剪贴板历史」开关：只在本用例临时打开过、且现在仍是开着的才点回去（需已在剪贴板历史页）
    private func restoreClipboardToggle(wasEnabled: Bool) {
        guard !wasEnabled else { return }
        let toggle = switchContaining("记录剪贴板历史")
        guard toggle.waitForExistence(timeout: 5), (toggle.value as? String) == "1" else { return }
        toggle.tap(); sleep(1)
    }

    // MARK: - 真键盘驱动辅助

    /// 系统键盘的「切换输入法」键（地球仪）。
    ///
    /// 必须在整个宿主 app 树里找，不能到 app.keyboards 里找：实测 app.keyboards.buttons
    /// 只有 shift 与 Search 两个直接子按钮（字母键在更深的 collection view 里），
    /// 在 keyboards 里查这颗键永远 nil —— 表现就是键盘明明起来了却报「切不到键盘」。
    /// 本次实测真正生效的是 label 那一档：日志里被 Tap 掉的元素调试描述是
    /// "下一个键盘" Button，点之后系统键盘确实在英文 / 拼音之间换掉了。
    /// identifier 'switch keyboard' 只作为回落保留，别当主路径：本次它跑了 5 次
    /// 都没拿到可命中元素（日志里只有那条谓词本身，没有命中结果）。
    /// 另：本 App 键盘自己的 globe 键（LeftBottomKeyType.nextKeyboard）是 label:"" 且未设
    /// accessibilityIdentifier，所以任何标识查法都不可能命中到本 App 键盘上那颗键。
    private func nextKeyboardButton(in app: XCUIApplication) -> XCUIElement? {
        let byLabel = app.buttons.matching(NSPredicate(format: "label CONTAINS '下一个键盘'")).firstMatch
        if byLabel.exists { return byLabel }
        let byId = app.buttons.matching(NSPredicate(format: "identifier == 'switch keyboard'"))
        for candidate in byId.allElementsBoundByIndex where candidate.isHittable {
            return candidate
        }
        return nil
    }

    /// 本 App 键盘当前是不是正在用：拿空格键标识当判据。
    /// 不能用 candidateBarLogo：它只在「无候选」空态渲染，打完字有候选时反而不在。
    /// spaceKey 在产品里只有一处定义（KeyboardRowsView 的 SpaceKey），
    /// 用例第 6 步的上屏也是靠同一个标识点到空格键的。
    /// 用 waitForExistence 而不是 exists：刚点完切换键时键盘还在换入动画里，exists 会抢到 false。
    private func openIMEKeyboardUp(in host: XCUIApplication) -> Bool {
        host.descendants(matching: .any)["spaceKey"].waitForExistence(timeout: 2)
    }

    /// 循环切换输入法直到本 App 键盘真的在屏上。
    ///
    /// 判据用 spaceKey 而不是 candidateBarLogo：后者只在「无候选」空态渲染，宿主输入框里
    /// 残留过文本时它会一直不出现，于是键盘明明已切过来却被报成「切不到」。
    ///
    /// 短按循环轮不到时补一条长按：实测同一份代码单独跑能过、跑在 UI 套件里连按 5 轮短按
    /// 都轮不到本 App（截图 candtap_no_keyboard：系统英文键盘在屏、左下角地球仪明明可点）。
    /// 短按的循环集合取决于该输入框上一次用过哪些键盘，那是系统偏好，不是测试能假定的东西；
    /// 长按地球仪弹出的输入源列表才是用户显式选输入源的通道，跟着走才稳。
    private func cycleToOpenIME(in host: XCUIApplication, shortRounds: Int = 5) -> Bool {
        if openIMEKeyboardUp(in: host) { return true }
        for _ in 0..<shortRounds {
            guard let next = nextKeyboardButton(in: host) else { break }
            next.tap(); sleep(2)
            if openIMEKeyboardUp(in: host) { return true }
        }
        return pickOpenIMEFromLongPressList(in: host)
    }

    /// 长按地球仪，在弹出的输入源列表里点本 App 那一行。
    /// 这层浮由系统渲染，既可能挂在宿主进程里也可能挂在 SpringBoard 里，两处都查。
    private func pickOpenIMEFromLongPressList(in host: XCUIApplication) -> Bool {
        guard let next = nextKeyboardButton(in: host) else { return false }
        next.press(forDuration: 1.5); sleep(2)
        for container in [host, XCUIApplication(bundleIdentifier: "com.apple.springboard")] {
            guard let row = openIMERow(in: container) else { continue }
            row.tap(); sleep(2)
            if openIMEKeyboardUp(in: host) { return true }
        }
        return false
    }

    /// 输入源列表里本 App 那一行：先精确等值，再 CONTAINS 回落（部分系统版本行 label 带状态后缀）
    private func openIMERow(in container: XCUIApplication) -> XCUIElement? {
        let any = container.descendants(matching: .any)
        let exact = any.matching(NSPredicate(format: "label == %@", keyboardSettingsName)).firstMatch
        if exact.exists { return exact }
        let loose = any.matching(NSPredicate(format: "label CONTAINS %@", keyboardSettingsName)).firstMatch
        return loose.exists ? loose : nil
    }

    /// 测完切回系统键盘（本 App 键盘不再在屏上即认为已离开）。
    /// 判据同 cycleToOpenIME：用 spaceKey 而不是空态才渲染的 logo，否则有候选时会误判“已经走了”，
    /// 把用户留在第三方键盘上。
    private func switchBackToSystemKeyboard(in host: XCUIApplication) {
        for _ in 0..<5 {
            guard openIMEKeyboardUp(in: host), let next = nextKeyboardButton(in: host) else { return }
            next.tap(); sleep(2)
        }
    }

    // MARK: - 滑杆读值与还原
    //
    // 一律「按序号现查元素」而不是持有 XCUIElement 引用：拿着旧引用连续读 value 会读到
    // 上一次查询的快照残值 —— 实测据此判方向做二分，连二分带邻域细扫都用完仍停在邻格
    //（原值 5、还原后读到 3），而且每一轮方向都和实际落点不符。
    // XCUIElement.value 是 Any?（SwiftUI Slider 给的是字符串还是数字、是绝对值还是百分比
    // 属于无障碍实现细节），统一转字符串比较，不让 as? String 失败时静默跳过还原。

    /// 现查现读：第 index 个滑杆的无障碍读值
    private func sliderValue(at index: Int) -> String? {
        app.sliders.element(boundBy: index).value.map { "\($0)" }
    }

    /// 落定读值：一次 adjust 之后 value 的回写比手势快慢不定，连续两次读到同一个值才算落定；
    /// 一直抖就返回末次读值，由调用方按事实断言而不是蒙混
    private func settledSliderValue(at index: Int, tries: Int = 4) -> String? {
        var previous = sliderValue(at: index)
        for _ in 0..<tries {
            usleep(400_000)
            let current = sliderValue(at: index)
            if current != nil, current == previous { return current }
            previous = current
        }
        return previous
    }

    /// 设一次位置并回读落定值
    private func setSlider(at index: Int, to position: Double) -> String? {
        app.sliders.element(boundBy: index).adjust(toNormalizedSliderPosition: position)
        sleep(1)
        return settledSliderValue(at: index)
    }

    /// 设到 position 并读值；读到 target 就停，否则把同一位置重设 retries 次。
    /// 为什么要重试：一次拖拽的落点本身带抖 —— 实测同一轮还原里 0.3320 读到 5、
    /// 0.3359 读到 8（两个位置差 0.004），目标格 6/7 被整段跳过，二分与邻域细扫
    /// 各自只试一次就会「所有位置都试完了、就是没读到过原值」（原值 6 那轮红了 20 次尝试）。
    /// 同一位置多试几次是把拖拽误差交给重采样，不是把断言改松。
    @discardableResult
    private func setSlider(_ index: Int, _ position: Double, hitting target: String, retries: Int = 1) -> String? {
        var last: String?
        for _ in 0...retries {
            last = setSlider(at: index, to: position)
            if last == target { return last }
        }
        return last
    }

    /// 把滑杆还原到原读值。为什么二分而不是一步换算：XCUITest 只能给归一化位置 0…1，
    /// 而读回的 value 单位形式不靠猜：value 随位置单调，先二分逼近，仍取不到原值再按邻域逐格细扫。
    /// 失败时把尝试过的位置与读值一并带进断言消息 —— 再红一次就能直接看出映射关系。
    private func restoreSlider(at index: Int, to original: String?) {
        guard let original else { return }
        var attempts: [String] = []
        if settledSliderValue(at: index) == original { return }
        var lo = 0.0, hi = 1.0
        var last = 0.5
        for _ in 0..<8 {
            let mid = (lo + hi) / 2
            let now = setSlider(index, mid, hitting: original)
            attempts.append("\(String(format: "%.4f", mid))→\(now ?? "nil")")
            if now == original { return }
            last = mid
            // 读值与原值同为可解析数字时才能定方向；解析不了就继续往两边走
            guard let a = now.flatMap({ Double($0) }), let b = Double(original) else {
                if hi - lo < 0.01 { break }
                lo = mid
                continue
            }
            if a < b { lo = mid } else { hi = mid }
        }
        // 带 step 的滑杆（键间距是 step:1）只有落进目标那一格的区间才吸得到目标值，
        // 二分的中点刚好压在格界上时会一直读到邻格的值，所以围绕最后中点向两侧逐格再试。
        for offset in 1...6 {
            for position in [last + Double(offset) * 0.01, last - Double(offset) * 0.01] {
                guard position >= 0, position <= 1 else { continue }
                let now = setSlider(index, position, hitting: original)
                attempts.append("\(String(format: "%.4f", position))→\(now ?? "nil")")
                if now == original { return }
            }
        }
        XCTAssertEqual(sliderValue(at: index), original,
                       "滑杆应能还原到拖动前的读值（尝试序列：\(attempts.joined(separator: " "))）")
    }

    /// 在系统设置里确保聿·输入法键盘已添加且允许完全访问；返回「列表里真的有它」。
    ///
    /// 路径（实测截图）：通用 → 键盘 → 键盘。外层「键盘」页第一行就是「键盘 3 >」（软件键盘列表，
    /// 后面的数字是已启用个数），同页还有自定义短语 / 单手键盘 / 字符预览 / 实体键盘等；
    /// 「添加新键盘…」在再里面一层，所以两次「键盘」都必需。之前它点不进去是因为
    /// tapSettingsRow 误命中了页面标题（见那个函数上的注释），不是层级写错。
    /// 结束时以「列表里真的出现本 App」为返回值，不再默默往下走。
    private func enableKeyboardInSettingsIfNeeded(_ prefs: XCUIApplication) -> Bool {
        prefs.terminate(); prefs.activate(); sleep(3)
        tapSettingsRow(in: prefs, keyword: "通用")
        tapSettingsRow(in: prefs, keyword: "键盘")
        sleep(2)
        tapSettingsRow(in: prefs, keyword: "键盘")
        sleep(2)

        // 列表里没有聿·输入法才去添加；已有则跳过（反复添加会产生重复条目）
        let ours = settingsRow(in: prefs, contains: keyboardSettingsName)
        let addRow = settingsRow(in: prefs, contains: "添加新键盘")
        if !ours.firstMatch.exists, addRow.firstMatch.exists {
            addRow.firstMatch.tap(); sleep(2)
            settingsRow(in: prefs, contains: keyboardSettingsName).firstMatch.tap(); sleep(2)
        }
        let present = ours.firstMatch.exists

        // 已添加：进详情确保「允许完全访问」打开（App Group 词库/设置依赖它）
        let entry = prefs.staticTexts.matching(NSPredicate(format: "label == %@", keyboardSettingsName)).firstMatch
        if present, entry.exists {
            entry.tap(); sleep(2)
            let fullAccess = prefs.switches.matching(NSPredicate(format: "label CONTAINS '完全访问'")).firstMatch
            if fullAccess.exists, (fullAccess.value as? String) != "1" {
                fullAccess.tap(); sleep(1)
                // 系统会弹风险确认 alert，点「允许」
                let allow = prefs.alerts.buttons.matching(NSPredicate(format: "label CONTAINS '允许'")).firstMatch
                if allow.exists { allow.tap(); sleep(1) }
            }
        }
        // 退掉设置：不把用户留在设置页，也不留残留搜索遮罩（下次进来所有行都会 not hittable）
        prefs.terminate(); sleep(1)
        return present
    }

    /// 设置页里的文本行查询（CONTAINS：「添加新键盘…」带省略号，精确匹配拿不到）
    private func settingsRow(in app: XCUIApplication, contains keyword: String) -> XCUIElementQuery {
        app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", keyword))
    }

    /// 设置页里按关键字点行（先滚到可见再点，点不到不硬失败 —— 由调用方断言后续页面）
    ///
    /// 两道都必需，都是实测踩出来的：
    /// 1) 查询限定在表格容器里。「键盘」页上 label 恰好等于「键盘」的静态文本有 2 个
    ///    （页面标题 + 那一行），app 级 firstMatch 先命中标题，而点标题是空操作 ——
    ///    表现就是日志里 Tap 打了、页面纹丝不动，后面几轮 swipeUp 全在白做。
    /// 2) 先拿精确匹配。表格里包含「键盘」两字的行很多，实测第二下曾命中
    ///    「轻点两下空格键插入句号（中文键盘）或句点与空格（其他键盘）。」这条说明行，
    ///    一点就跳去另一个页面。精确匹配在表格内能拿到真正的「键盘」行
    ///    （实测 exists 与 isHittable 都为 true）；精确拿不到才回落 CONTAINS
    ///    （「添加新键盘…」带省略号，只能模糊匹配）。
    private func tapSettingsRow(in prefs: XCUIApplication, keyword: String) {
        let container: XCUIElementQuery = prefs.tables.firstMatch.exists
            ? prefs.tables.firstMatch.staticTexts
            : prefs.staticTexts
        let scrolling = prefs.tables.firstMatch.exists ? prefs.tables.firstMatch : prefs
        for _ in 0..<5 {
            let exact = container.matching(NSPredicate(format: "label == %@", keyword)).firstMatch
            let row = exact.exists ? exact
                : container.matching(NSPredicate(format: "label CONTAINS %@", keyword)).firstMatch
            if row.exists && row.isHittable { row.tap(); sleep(2); return }
            scrolling.swipeUp()
            sleep(1)
        }
    }
}

// MARK: - XCUIElement 文本清空

extension XCUIElement {
    /// 清空输入框：按当前值长度逐个发退格（typeText 会把 \u{8} 当退格键处理）
    func clearText() {
        guard let value = self.value as? String, !value.isEmpty else { return }
        self.typeText(String(repeating: "\u{8}", count: value.count))
    }
}
