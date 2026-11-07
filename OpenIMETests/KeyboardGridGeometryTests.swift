import XCTest
import CoreGraphics
@testable import OpenIMECore

/// 键盘高度可调（KeyboardGridGeometry 高度系数）的几何单测。
///
/// 核心不变式：
/// 1. 默认系数 1.0 时按键严格正方形（键高 == 键宽），与放开高度可调之前的历史行为逐字节一致；
/// 2. 调高 / 调低只改键高，键宽恒按屏宽 10 等分不变（横向继续随屏幕自适应）；
/// 3. 横屏等受限场景有「屏高 × 上限」护栏，键高最多回到正方形尺寸，绝不溢出屏幕；
/// 4. 功能键文字字号跟键宽，调高时不变（防止标签横向溢出、与绝对的字母字号保持一致）。
final class KeyboardGridGeometryTests: XCTestCase {

    private func geom(_ heightRatio: CGFloat = 1.0,
                      availableWidth: CGFloat = 390,
                      screenHeight: CGFloat = 844,
                      keySpacing: CGFloat = 6,
                      rowSpacingRatio: CGFloat = 0.18) -> KeyboardGridGeometry {
        KeyboardGridGeometry(availableWidth: availableWidth,
                             screenHeight: screenHeight,
                             keySpacing: keySpacing,
                             rowSpacingRatio: rowSpacingRatio,
                             heightRatio: heightRatio)
    }

    // MARK: - 默认系数：正方形，复现历史行为

    func testDefaultRatioKeepsSquareKeys() {
        let g = geom(1.0)
        XCTAssertEqual(g.keyHeight, g.letterKeyWidth, accuracy: 0.0001,
                       "默认系数 1.0 时按键必须是正方形")
        XCTAssertGreaterThan(g.keyHeight, 0)
    }

    func testDefaultBodyHeightFormula() {
        let g = geom(1.0)
        let expected = g.keyHeight * 4 + g.rowSpacing * 3 + g.topBotPad * 2
        XCTAssertEqual(g.bodyHeight, expected, accuracy: 0.0001,
                       "键盘体高 = 4×键高 + 3×行距 + 2×上下留白")
    }

    func testDefaultRowSpacingIsKeyHeightTimesRatio() {
        let g = geom(1.0, rowSpacingRatio: 0.18)
        XCTAssertEqual(g.rowSpacing, g.keyHeight * 0.18, accuracy: 0.0001)
    }

    // MARK: - 调高 / 调低：只动键高，键宽不变

    func testTallerRatioScalesHeightNotWidth() {
        let base = geom(1.0)
        let tall = geom(1.2)
        XCTAssertEqual(tall.letterKeyWidth, base.letterKeyWidth, accuracy: 0.0001,
                       "键宽不随高度系数变化")
        XCTAssertEqual(tall.keyHeight, base.letterKeyWidth * 1.2, accuracy: 0.0001,
                       "键高 = 键宽 × 系数")
        XCTAssertGreaterThan(tall.bodyHeight, base.bodyHeight, "调高后键盘体更高")
    }

    func testShorterRatioScalesHeightDown() {
        let base = geom(1.0)
        let short = geom(0.9)
        XCTAssertEqual(short.letterKeyWidth, base.letterKeyWidth, accuracy: 0.0001)
        XCTAssertEqual(short.keyHeight, base.letterKeyWidth * 0.9, accuracy: 0.0001)
        XCTAssertLessThan(short.bodyHeight, base.bodyHeight, "调矮后键盘体更矮")
    }

    func testTallerRatioIsRectangular() {
        let tall = geom(1.3)
        XCTAssertGreaterThan(tall.keyHeight, tall.letterKeyWidth,
                             "系数 > 1 时键高 > 键宽，按键变矩形")
    }

    // MARK: - 限高护栏：横屏调高不溢出

    func testHeightClampedByScreenHeightInLandscape() {
        // 横屏：可用宽度大、屏幕高度小，边长本身已被屏高上限截住
        let g = geom(1.3, availableWidth: 844, screenHeight: 390)
        let cap = 390 * KeyboardGridGeometry.maxLetterKeyHeightRatio
        XCTAssertLessThanOrEqual(g.keyHeight, cap + 0.0001,
                                 "受限场景键高不得超过「屏高 × 上限」护栏")
    }

    // MARK: - 滑杆上限 180%：竖屏真实生效、横屏护栏兜底

    /// 滑杆上限提到 180% 后，竖屏下系数 1.8 必须完全生效（键高 = 键宽 × 1.8），
    /// 且远未触到「屏高 × maxLetterKeyHeightRatio」护栏 —— 否则用户拉到最高却不见变高就是 bug；
    /// 同一系数在横屏仍被护栏夹住，绝不溢出屏幕。
    func testMaxRatio180TakesEffectInPortraitAndClampedInLandscape() {
        // 竖屏（390×844）：1.8 完全生效，键高严格按系数放大，键盘体比旧的 1.3 上限更高
        let base = geom(1.0)
        let max = geom(1.8)
        XCTAssertEqual(max.letterKeyWidth, base.letterKeyWidth, accuracy: 0.0001,
                       "键宽不随高度系数变化")
        XCTAssertEqual(max.keyHeight, base.letterKeyWidth * 1.8, accuracy: 0.0001,
                       "上限 1.8 在竖屏完全生效：键高 = 键宽 × 1.8")
        let portraitCap = 844 * KeyboardGridGeometry.maxLetterKeyHeightRatio
        XCTAssertLessThan(max.keyHeight, portraitCap,
                          "竖屏 1.8 的键高远低于屏高护栏（~290% 才触顶），未被夹取、真实变高")
        XCTAssertGreaterThan(max.bodyHeight, geom(1.3).bodyHeight,
                             "1.8 比旧上限 1.3 的键盘体更高")

        // 横屏（844×390）：同一 1.8 被护栏夹住，键高不超过屏高上限，绝不溢出
        let land = geom(1.8, availableWidth: 844, screenHeight: 390)
        let landCap = 390 * KeyboardGridGeometry.maxLetterKeyHeightRatio
        XCTAssertLessThanOrEqual(land.keyHeight, landCap + 0.0001,
                                 "横屏拉到最高 1.8 仍被护栏夹住，不溢出屏幕")
    }

    // MARK: - 功能键文字字号跟键宽

    func testFuncFontSizeTiedToWidthNotHeight() {
        let base = geom(1.0)
        let tall = geom(1.3)
        XCTAssertEqual(tall.funcFontSize, base.funcFontSize, accuracy: 0.0001,
                       "调高时功能键文字字号不变（跟键宽）")
        XCTAssertEqual(base.funcFontSize, base.letterKeyWidth * KeyboardGridGeometry.funcFontRatio,
                       accuracy: 0.0001)
    }

    // MARK: - 键面图标（Shift / 退格）字号基准跟键宽、不跟键高
    //
    // 图标若按 keyHeight 定字号，用户调高键盘（系数 > 1）时 keyHeight 变大、图标被拉粗显得很重；
    // 改以 letterKeyWidth 为基准（= 默认系数下的正方形键高，不随系数变化），图标大小恒定，
    // 与 funcFontSize / 字母字号一样「跟键宽不跟键高」。默认系数下 letterKeyWidth == keyHeight，零回归。
    func testIconSizeBasisTiedToWidthNotHeight() {
        let base = geom(1.0)
        let tall = geom(1.3)
        // 图标基准 letterKeyWidth 不随高度系数变化 → 调高键盘图标不变粗
        XCTAssertEqual(KeyboardGridGeometry.iconFontSize(forKeyHeight: tall.letterKeyWidth),
                       KeyboardGridGeometry.iconFontSize(forKeyHeight: base.letterKeyWidth),
                       accuracy: 0.0001,
                       "调高键盘时图标字号基准（letterKeyWidth）不变，图标不变粗")
        // 默认系数下 letterKeyWidth == keyHeight，图标字号与「按 keyHeight」逐字节一致（零回归）
        XCTAssertEqual(KeyboardGridGeometry.iconFontSize(forKeyHeight: base.letterKeyWidth),
                       KeyboardGridGeometry.iconFontSize(forKeyHeight: base.keyHeight),
                       accuracy: 0.0001,
                       "默认系数下基准切换零回归（letterKeyWidth == keyHeight）")
        // 反证：keyHeight 会随系数变大——正是「按 keyHeight 定图标字号」会变粗的根源
        XCTAssertGreaterThan(KeyboardGridGeometry.iconFontSize(forKeyHeight: tall.keyHeight),
                             KeyboardGridGeometry.iconFontSize(forKeyHeight: tall.letterKeyWidth),
                             "调高后 keyHeight > letterKeyWidth，若图标跟 keyHeight 就会变粗")
    }

    // MARK: - 键宽随屏幕宽度自适应（默认系数）

    func testLetterKeyWidthAdaptsToScreenWidth() {
        let narrow = geom(1.0, availableWidth: 320, screenHeight: 568)
        let wide = geom(1.0, availableWidth: 430, screenHeight: 932)
        XCTAssertGreaterThan(wide.letterKeyWidth, narrow.letterKeyWidth,
                             "更宽的屏 → 更大的按键")
        XCTAssertEqual(wide.keyHeight, wide.letterKeyWidth, accuracy: 0.0001,
                       "默认系数下宽屏仍是正方形")
    }

    // MARK: - 边界与退化输入（init 里每个 guard / 兜底分支都要覆盖）

    /// 可用宽度为 0：边长塌缩到 0，且不得出现负值 / NaN（Swift.max(...,0) 兜底）
    func testZeroAvailableWidthCollapsesWithoutNaN() {
        let g = geom(1.0, availableWidth: 0, screenHeight: 844)
        XCTAssertEqual(g.letterKeyWidth, 0, accuracy: 0.0001)
        XCTAssertEqual(g.keyHeight, 0, accuracy: 0.0001)
        XCTAssertFalse(g.letterKeyWidth.isNaN)
        XCTAssertFalse(g.keyHeight.isNaN)
        XCTAssertFalse(g.bodyHeight.isNaN)
        XCTAssertGreaterThanOrEqual(g.funcKeyWidth, 0)
    }

    /// 可用宽度为负：被 Swift.max(availableWidth, 0) 夹到 0，行为与 0 宽一致，绝不产生负边长
    func testNegativeAvailableWidthIsGuardedToZero() {
        let g = geom(1.0, availableWidth: -100, screenHeight: 844)
        XCTAssertEqual(g.letterKeyWidth, 0, accuracy: 0.0001)
        XCTAssertGreaterThanOrEqual(g.keyHeight, 0)
        XCTAssertGreaterThanOrEqual(g.letterKeyWidth, 0)
    }

    /// 键间距大到把 10 等分挤成负数：边长被 Swift.max(...,0) 兜到 0，不为负
    func testHugeKeySpacingFloorsSideAtZero() {
        let g = geom(1.0, availableWidth: 390, screenHeight: 844, keySpacing: 200)
        XCTAssertEqual(g.letterKeyWidth, 0, accuracy: 0.0001,
                       "键间距超过可用宽度时边长兜底为 0，不得为负")
        XCTAssertGreaterThanOrEqual(g.keyHeight, 0)
    }

    /// 高度系数为 0：键高为 0，但键宽不受影响（仍按屏宽 10 等分）
    func testZeroHeightRatioGivesZeroKeyHeight() {
        let g = geom(0.0, availableWidth: 390, screenHeight: 844)
        XCTAssertEqual(g.keyHeight, 0, accuracy: 0.0001)
        XCTAssertGreaterThan(g.letterKeyWidth, 0, "键宽与高度系数解耦，仍为正值")
    }

    /// 高度系数为负：键高被 Swift.max(...,0) 兜到 0，绝不为负 / NaN
    func testNegativeHeightRatioFloorsKeyHeightAtZero() {
        let g = geom(-1.0, availableWidth: 390, screenHeight: 844)
        XCTAssertEqual(g.keyHeight, 0, accuracy: 0.0001)
        XCTAssertFalse(g.keyHeight.isNaN)
    }

    /// screenHeight == 0 表示「不限高」：高度护栏关闭，键高 = 边长 × 系数不被夹取；
    /// 对照给了真实屏高则同一系数被「屏高 × 上限」夹住 —— 两条分支都要覆盖
    func testZeroScreenHeightDisablesHeightClamp() {
        let unlimited = geom(3.0, availableWidth: 390, screenHeight: 0)
        XCTAssertEqual(unlimited.keyHeight, unlimited.letterKeyWidth * 3.0, accuracy: 0.0001,
                       "screenHeight=0 时不限高，键高严格按系数放大")
        let clamped = geom(3.0, availableWidth: 390, screenHeight: 844)
        XCTAssertEqual(clamped.keyHeight, 844 * KeyboardGridGeometry.maxLetterKeyHeightRatio, accuracy: 0.0001,
                       "有屏高时同一系数被屏高护栏夹住")
    }

    // MARK: - 上限 / 夹取边界

    /// 竖屏：边长由「10 等分（扣留白与间距）」决定，同时不超过屏宽上限与屏高上限两道护栏
    func testPortraitSideIsWidthDrivenAndRespectsCaps() {
        let width: CGFloat = 390, height: CGFloat = 844, spacing: CGFloat = 6
        let g = geom(1.0, availableWidth: width, screenHeight: height, keySpacing: spacing)
        let edge = width * KeyboardGridGeometry.screenEdgePaddingRatio
        let fitSide = (width - edge * 2 - spacing * 9) / 10
        XCTAssertEqual(g.letterKeyWidth, fitSide, accuracy: 0.0001, "竖屏边长 = 10 等分")
        XCTAssertLessThanOrEqual(g.letterKeyWidth, width * KeyboardGridGeometry.maxLetterKeyWidthRatio + 0.0001,
                                 "边长不得超屏宽上限")
        XCTAssertLessThanOrEqual(g.letterKeyWidth, height * KeyboardGridGeometry.maxLetterKeyHeightRatio + 0.0001,
                                 "边长不得超屏高上限")
    }

    /// 横屏：10 等分会超出屏高，边长被「屏高 × 上限」夹住，默认系数下仍是正方形
    func testLandscapeSideClampedByScreenHeightCap() {
        let g = geom(1.0, availableWidth: 844, screenHeight: 390)
        XCTAssertEqual(g.letterKeyWidth, 390 * KeyboardGridGeometry.maxLetterKeyHeightRatio, accuracy: 0.0001,
                       "横屏边长被屏高上限夹住")
        XCTAssertEqual(g.keyHeight, g.letterKeyWidth, accuracy: 0.0001, "横屏默认系数仍是正方形")
    }

    /// 任意高度系数下键高都不得越过「屏高 × 上限」护栏（含远超滑杆上限 1.8 的极端值），且恒非负
    func testKeyHeightNeverExceedsScreenHeightCapForAnyRatio() {
        let height: CGFloat = 844
        let cap = height * KeyboardGridGeometry.maxLetterKeyHeightRatio
        for ratio: CGFloat in [0.0, 0.5, 1.0, 1.8, 3.0, 10.0, 100.0] {
            let g = geom(ratio, availableWidth: 390, screenHeight: height)
            XCTAssertLessThanOrEqual(g.keyHeight, cap + 0.0001, "系数 \(ratio) 下键高越过屏高护栏")
            XCTAssertGreaterThanOrEqual(g.keyHeight, 0, "系数 \(ratio) 下键高为负")
        }
    }

    // MARK: - 不变式（任意合理输入下恒成立）

    /// 功能键宽 = max(第三行剩余平分, 边长)，故任何屏宽下都不会比字母键窄
    func testFuncKeyWidthNeverNarrowerThanLetterKey() {
        for width: CGFloat in [280, 320, 375, 390, 414, 430, 768, 844] {
            let g = geom(1.0, availableWidth: width, screenHeight: 844)
            XCTAssertGreaterThanOrEqual(g.funcKeyWidth, g.letterKeyWidth - 0.0001,
                                        "屏宽 \(width) 下功能键比字母键还窄")
        }
    }

    /// 小鹤双拼退格宽 = max(剩余, 功能键宽)，恒不小于功能键宽
    func testHeErBackspaceWidthAtLeastFuncKeyWidth() {
        for width: CGFloat in [320, 390, 430, 844] {
            let g = geom(1.0, availableWidth: width, screenHeight: 844)
            XCTAssertGreaterThanOrEqual(g.heErBackspaceWidth, g.funcKeyWidth - 0.0001)
        }
    }

    /// 一行净宽 + 两侧留白恰好铺满可用宽度（居中、不溢出）
    func testRowWidthPlusPaddingFillsUsableWidth() {
        for width: CGFloat in [320, 390, 430] {
            let g = geom(1.0, availableWidth: width, screenHeight: 844)
            XCTAssertEqual(g.hPad * 2 + g.rowWidth, width, accuracy: 0.0001,
                           "屏宽 \(width)：2×留白 + 行净宽应精确等于可用宽度")
            XCTAssertLessThanOrEqual(g.rowWidth, width + 0.0001, "行净宽不得溢出可用宽度")
        }
    }

    /// 上下留白 = 键间距 × 比例；键间距为 0 时留白也为 0
    func testTopBotPadDerivesFromKeySpacing() {
        let g = geom(1.0, availableWidth: 390, screenHeight: 844, keySpacing: 6)
        XCTAssertEqual(g.topBotPad, 6 * KeyboardGridGeometry.verticalEdgePaddingRatio, accuracy: 0.0001)
        let g0 = geom(1.0, availableWidth: 390, screenHeight: 844, keySpacing: 0)
        XCTAssertEqual(g0.topBotPad, 0, accuracy: 0.0001)
    }

    /// 底行角键宽 = 功能键宽 + 一个键间距 + 一个字母键宽（让左下键右缘对齐 z、回车左缘对齐 m）；
    /// 第二行缩进由「键格 = 边长 + 间距」按固定比例派生
    func testBottomCornerKeyWidthAndRow2IndentDeriveFromKeyCell() {
        let g = geom(1.0, availableWidth: 390, screenHeight: 844, keySpacing: 6)
        let cell = g.letterKeyWidth + g.keySpacing
        XCTAssertEqual(g.bottomCornerKeyWidth, g.funcKeyWidth + cell, accuracy: 0.0001,
                       "底行角键宽应 = 功能键宽 + 一个键格（对齐第三行 z 右缘 / m 左缘）")
        XCTAssertEqual(g.row2Indent, cell * KeyboardGridGeometry.secondRowIndentRatio, accuracy: 0.0001)
    }

    /// 数字副键盘行高 = (体高 − 2×留白 − 3×行距) / 4，恒等于键高（与系数无关）。
    /// 这正是「副键盘退格图标基准从 rowH 换成 letterKeyWidth 后默认系数零回归」的依据：
    /// 默认系数下 rowH == keyHeight == letterKeyWidth。
    func testNumberSubKeyboardRowHeightEqualsKeyHeight() {
        for ratio: CGFloat in [0.85, 1.0, 1.3, 1.8] {
            let g = geom(ratio, availableWidth: 390, screenHeight: 844)
            let rowH = (g.bodyHeight - g.topBotPad * 2 - g.rowSpacing * 3) / 4
            XCTAssertEqual(rowH, g.keyHeight, accuracy: 0.0001, "系数 \(ratio)：副键盘 4 等分行高应恒等于键高")
        }
        let base = geom(1.0, availableWidth: 390, screenHeight: 844)
        let baseRowH = (base.bodyHeight - base.topBotPad * 2 - base.rowSpacing * 3) / 4
        XCTAssertEqual(baseRowH, base.letterKeyWidth, accuracy: 0.0001, "默认系数下行高进一步等于键宽（正方形）")
    }

    // MARK: - 字号 / 图标派生边界

    /// 字号随屏宽缩放、零宽时归零且不为 NaN；图标 / 回车图标字号按固定比例从功能键字号派生
    func testFontSizesScaleWithWidthAndVanishAtZeroWidth() {
        let narrow = geom(1.0, availableWidth: 320, screenHeight: 844)
        let wide = geom(1.0, availableWidth: 430, screenHeight: 844)
        XCTAssertGreaterThan(wide.funcFontSize, narrow.funcFontSize, "更宽的屏 → 更大的功能键字号")
        XCTAssertEqual(wide.funcFontSize, wide.letterKeyWidth * KeyboardGridGeometry.funcFontRatio, accuracy: 0.0001)
        XCTAssertEqual(wide.iconFontSize, wide.funcFontSize * KeyboardGridGeometry.iconFontRatio, accuracy: 0.0001)
        XCTAssertEqual(wide.returnIconFontSize, wide.funcFontSize * KeyboardGridGeometry.returnIconFontRatio, accuracy: 0.0001)
        let zero = geom(1.0, availableWidth: 0, screenHeight: 844)
        XCTAssertEqual(zero.funcFontSize, 0, accuracy: 0.0001)
        XCTAssertEqual(zero.iconFontSize, 0, accuracy: 0.0001)
        XCTAssertFalse(zero.funcFontSize.isNaN)
    }

    /// 静态图标字号入口：键高为 0 → 字号 0；随键高单调递增；与「功能键字号比例 × 图标比例」同源
    func testStaticIconFontSizeBoundaryAndMonotonic() {
        XCTAssertEqual(KeyboardGridGeometry.iconFontSize(forKeyHeight: 0), 0, accuracy: 0.0001)
        let small = KeyboardGridGeometry.iconFontSize(forKeyHeight: 20)
        let large = KeyboardGridGeometry.iconFontSize(forKeyHeight: 40)
        XCTAssertGreaterThan(large, small, "图标字号随键高单调递增")
        XCTAssertEqual(small, 20 * KeyboardGridGeometry.funcFontRatio * KeyboardGridGeometry.iconFontRatio, accuracy: 0.0001)
    }
}

// MARK: - 键盘总高（KeyboardMetrics.totalHeight）
//
// 两种键盘形态同构（都是四行字母键 + 底行），总高只由屏宽 / 屏高 / 高度系数决定，
// 不再有形态专有的分支；用户调高 / 调低必须如实反映到总高上。
final class KeyboardMetricsTotalHeightTests: XCTestCase {

    private func totalHeight(width: CGFloat, height: CGFloat, ratio: Double) -> CGFloat {
        var layout = KeyboardLayoutSettings()
        layout.keyboardHeightRatio = ratio
        return KeyboardMetrics.totalHeight(screenWidth: width,
                                           screenHeight: height,
                                           safeAreaBottom: 0,
                                           layoutSettings: layout,
                                           appearanceSettings: KeyboardAppearanceSettings(),
                                           showAnnotation: true)
    }

    // 键盘总高随用户高度系数变化
    func testTotalHeightStillFollowsRatio() {
        let base = totalHeight(width: 390, height: 844, ratio: 1.0)
        let tall = totalHeight(width: 390, height: 844, ratio: 1.3)
        XCTAssertGreaterThan(tall, base, "调高键盘高度时总高应变高")
    }

    // 横屏下总高被屏高夹住：系数继续往上加也不该把键盘撑出屏幕
    func testTotalHeightIsClampedByScreenHeightInLandscape() {
        let wide = totalHeight(width: 844, height: 390, ratio: 1.3)
        let huge = totalHeight(width: 844, height: 390, ratio: 1.8)
        XCTAssertEqual(wide, huge, accuracy: 0.0001, "横屏到夹取上限后总高不该再变")
    }
}

// MARK: - 候选栏组句键 / 下拉键对齐 o·p 的几何（CandidateBarStyle 纯函数）
//
// 顶行 o = index 8、p = index 9。以「距屏幕右缘」度量（lk=letterKeyWidth、ks=keySpacing）：
//   p 左缘 = hPad + lk；o 左缘 = hPad + 2*lk + ks；o·p 间隙中点 D_mid = hPad + lk + 0.5*ks。
// 三个纯函数必须让这些闭式距离成立：组句键左缘齐 o 键、组句↔下拉分隔线落 D_mid、
// 无组句时下拉键左缘也落 D_mid。
final class CandidateBarGeometryTests: XCTestCase {

    private func geom() -> KeyboardGridGeometry {
        KeyboardGridGeometry(availableWidth: 390, screenHeight: 844,
                             keySpacing: 6, rowSpacingRatio: 0.18, heightRatio: 1.0)
    }

    /// o·p 间隙中点距右缘 = hPad + lk + 0.5*ks（p 左缘再往左半个键间距）
    func testOpMidpointInset() {
        let g = geom()
        let expected = g.hPad + g.letterKeyWidth + 0.5 * g.keySpacing
        XCTAssertEqual(CandidateBarStyle.opMidpointInsetFromTrailing(
            letterKeyWidth: g.letterKeyWidth, keySpacing: g.keySpacing, hPad: g.hPad),
            expected, accuracy: 0.0001)
    }

    /// 组句单元格左缘落 o 键左缘：宽 = lk + 0.5*ks - dividerWidth/2，
    /// 且 (D_mid + dividerWidth/2) + 宽 == o 左缘 (hPad + 2*lk + ks)
    func testComposeCellLeftEdgeAlignsOKey() {
        let g = geom()
        let dMid = g.hPad + g.letterKeyWidth + 0.5 * g.keySpacing
        let w = CandidateBarStyle.composeCellWidth(letterKeyWidth: g.letterKeyWidth,
                                                   keySpacing: g.keySpacing)
        XCTAssertEqual(w, g.letterKeyWidth + 0.5 * g.keySpacing - CandidateBarStyle.dividerWidth / 2,
                       accuracy: 0.0001)
        let composeLeftFromTrailing = (dMid + CandidateBarStyle.dividerWidth / 2) + w
        XCTAssertEqual(composeLeftFromTrailing, g.hPad + 2 * g.letterKeyWidth + g.keySpacing,
                       accuracy: 0.0001, "组句单元格左缘应落在 o 键左缘")
    }

    /// 有组句：下拉键左缘接居中于 D_mid 的分隔线右半线宽处（D_mid - dividerWidth/2）
    func testExpandInsetWithCompose() {
        let g = geom()
        let slotSize = g.letterKeyWidth
        let dMid = g.hPad + g.letterKeyWidth + 0.5 * g.keySpacing
        let inset = CandidateBarStyle.expandTrailingInset(
            letterKeyWidth: g.letterKeyWidth, keySpacing: g.keySpacing, hPad: g.hPad,
            slotSize: slotSize, hasCompose: true)
        XCTAssertEqual(inset + slotSize, dMid - CandidateBarStyle.dividerWidth / 2, accuracy: 0.0001,
                       "有组句时下拉键左缘接分隔线右半线宽处")
    }

    /// 无组句：下拉键左缘正落 o·p 中点 D_mid
    func testExpandInsetWithoutCompose() {
        let g = geom()
        let slotSize = g.letterKeyWidth
        let dMid = g.hPad + g.letterKeyWidth + 0.5 * g.keySpacing
        let inset = CandidateBarStyle.expandTrailingInset(
            letterKeyWidth: g.letterKeyWidth, keySpacing: g.keySpacing, hPad: g.hPad,
            slotSize: slotSize, hasCompose: false)
        XCTAssertEqual(inset + slotSize, dMid, accuracy: 0.0001,
                       "无组句时下拉键左缘正落 o·p 中点")
    }
}
