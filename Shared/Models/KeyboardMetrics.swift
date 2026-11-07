import SwiftUI
import UIKit

// MARK: - 键盘几何（键盘扩展与主 App 设置页预览共用同一份推导）

// 加 Equatable：键盘根视图每次击键都重算 body，需要靠 == 判断键位几何有没有变，
// 好让键位树在击键间被 SwiftUI 整棵跳过重绘。全部存储属性都是 CGFloat 或已 Equatable 的
// 设置值类型，== 由编译器自动合成，无手写风险。
public struct KeyboardMetrics: Equatable {

    // 设计比例
    // 26 键 / 双拼的网格比例与字号比例统一放在 Shared/KeyboardGridGeometry ——
    // 键盘扩展与主 App「设置页的键盘预览」共用同一份推导，不会各算一套。
    // 两种键盘形态同构（都是四行字母键 + 底行），因此这里不再有形态专有的比例。

    // 对外暴露的尺寸
    public let screenWidth: CGFloat
    public let screenHeight: CGFloat
    /// 候选栏以下、安全区以上的键盘体净高（26 键 / 双拼）
    public let bodyHeight: CGFloat
    /// 26 键 / 双拼字母键高（默认高度系数下 = 键宽、正方形；用户调高 / 调低时 = 键宽乘系数）
    public let keyHeight: CGFloat
    /// 26 键 / 双拼字母键宽（横向恒定，按屏宽 10 等分，不随高度系数变化）
    public let letterKeyWidth: CGFloat
    public let rowSpacing: CGFloat
    public let keySpacing: CGFloat
    public let hPad: CGFloat
    public let topBotPad: CGFloat
    /// 一行按键区的净宽（不含左右留白），第三行 / 底行都按它铺满
    public let rowWidth: CGFloat
    public let row2Indent: CGFloat
    /// 行首尾功能键宽（Shift / 退格 / 123）：第三行剩余宽度平分给两侧
    public let funcKeyWidth: CGFloat
    /// 底行两端角键宽（左下 123 / 地球、右下回车）：对齐第三行 z 右缘 / m 左缘
    public let bottomCornerKeyWidth: CGFloat
    /// 双拼第三行没有首功能键，退格键吃下整段剩余宽度
    public let heErBackspaceWidth: CGFloat
    public let keyCorner: CGFloat
    public let letterFontSize: CGFloat
    public let funcFontSize: CGFloat
    public let firstRowKeyWidth: CGFloat

    private let layoutSettings: KeyboardLayoutSettings
    private let appearanceSettings: KeyboardAppearanceSettings

    /// ViewController 调用：算键盘总约束高度（含候选栏 + 安全区）
    public static func totalHeight(screenWidth: CGFloat,
                                   screenHeight: CGFloat = UIScreen.main.bounds.height,
                                   safeAreaBottom: CGFloat,
                                   layoutSettings: KeyboardLayoutSettings,
                                   appearanceSettings: KeyboardAppearanceSettings,
                                   showAnnotation: Bool) -> CGFloat {
        let metrics = KeyboardMetrics(screenWidth: screenWidth,
                                      screenHeight: screenHeight,
                                      layoutSettings: layoutSettings,
                                      appearanceSettings: appearanceSettings)
        // 同步修改，外部计算键盘总高度时，强制固定开启注释高度
        let candidateH = CGFloat(appearanceSettings.candidateBarHeight(showAnnotation: true))
        return metrics.bodyHeight + candidateH + safeAreaBottom
    }

    /// IMEKeyboardView 调用
    public init(screenWidth: CGFloat,
                screenHeight: CGFloat = UIScreen.main.bounds.height,
                layoutSettings: KeyboardLayoutSettings,
                appearanceSettings: KeyboardAppearanceSettings) {

        self.screenWidth = screenWidth
        self.screenHeight = screenHeight
        self.layoutSettings = layoutSettings
        self.appearanceSettings = appearanceSettings

        keySpacing = CGFloat(appearanceSettings.keySpacing)
        let heightRatio = CGFloat(layoutSettings.keyboardHeightRatio)

        // 核心：26 键 / 双拼的网格几何（字母键宽按屏宽 10 等分、键高 = 键宽乘高度系数）
        // 统一由 Shared/KeyboardGridGeometry 推导 —— 主 App 设置页的键盘预览用的是同一份代码
        let grid = KeyboardGridGeometry(
            availableWidth: screenWidth,
            screenHeight: screenHeight,
            keySpacing: keySpacing,
            rowSpacingRatio: CGFloat(layoutSettings.rowSpacingRatio),
            heightRatio: heightRatio)
        letterKeyWidth     = grid.letterKeyWidth
        keyHeight          = grid.keyHeight
        firstRowKeyWidth   = grid.letterKeyWidth
        rowWidth           = grid.rowWidth
        hPad               = grid.hPad
        row2Indent         = grid.row2Indent
        funcKeyWidth       = grid.funcKeyWidth
        heErBackspaceWidth = grid.heErBackspaceWidth
        bottomCornerKeyWidth = grid.bottomCornerKeyWidth
        topBotPad          = grid.topBotPad
        rowSpacing         = grid.rowSpacing
        bodyHeight         = grid.bodyHeight

        keyCorner      = CGFloat(appearanceSettings.keyCornerRadius)
        letterFontSize = CGFloat(appearanceSettings.keyFontSize)
        funcFontSize   = grid.funcFontSize
    }
}
