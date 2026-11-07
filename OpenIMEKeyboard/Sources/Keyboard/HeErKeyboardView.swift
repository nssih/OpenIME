import SwiftUI
import OpenIMECore

// MARK: - 小鹤双拼模块：小鹤双拼 26 键键盘
//
// 布局：与原有 26 键全拼键盘完全同形（10 / 9 / Shift+7+退格 / 功能行），便于迁移打字习惯：
//   第一行 q w e r t y u i o p
//   第二行 a s d f g h j k l（右移半键，与原键盘一致）
//   第三行 Shift + z x c v b n m + 退格（与老 26 键同形：行首 Shift、行尾退格，两键同宽）
//   第四行 左下功能键（123/地球，与老 26 键同一个设置）+ 空格 + 回车
// 键盘切换：不占用主键盘键位，走候选栏标志打开的快捷面板（与原有 26 键全拼键盘一致）
// 键面标注：主字母 + 下方韵母 + 右上角声母（仅 v=zh / i=ch / u=sh）。
//   标注数据来自 HeErDoublePinyin.shared.keyLabels，与编码引擎同源，不会出现两处不一致。
//   排版：主字母行与韵母行各自占固定行高（没有韵母的键也留空行），
//         整排键的垂直节奏统一；声母角标固定在右上角同一位置。
// 输入：字母直接写入输入缓冲区，由 HeErDoublePinyin 展开成全拼前缀后再查词库。
// 交互：轻点输入；长按空格 1 秒进入光标模式，激活后整个键盘区域都生效
//       （光标模式下所有按键不再上屏，手指可在整个键盘区域横向滑动移动光标）。
//
// 注意：本视图是独立新增的键盘，原有 26 键全拼键盘（KeyboardRowsView）完全未改动。

struct HeErKeyboardView: View, Equatable {

    // 击键间跳过重绘（说明见 KeyboardRowsView 同款注释）：== 只比决定键位外观的输入，
    // 动作回调闭包与内部 @State 不纳入，其余全比。
    static func == (lhs: HeErKeyboardView, rhs: HeErKeyboardView) -> Bool {
        lhs.isShifted == rhs.isShifted
            && lhs.isCapsLocked == rhs.isCapsLocked
            && lhs.metrics == rhs.metrics
            && lhs.appearanceSettings == rhs.appearanceSettings
            && lhs.layoutSettings == rhs.layoutSettings
            && lhs.hasInput == rhs.hasInput
    }

    @Binding var isShifted: Bool
    let isCapsLocked: Bool
    let metrics: KeyboardMetrics
    let appearanceSettings: KeyboardAppearanceSettings
    let layoutSettings: KeyboardLayoutSettings

    let onKey: (String) -> Void            // 字母：追加到输入缓冲区
    let onBackspace: () -> Void
    let onReturn: () -> Void
    let onSpace: () -> Void
    let onSwitchToNumbers: () -> Void
    let onNextKeyboard: () -> Void
    let onCursorModeStart: () -> Void      // 进入光标模式时调用；摘掉内嵌编码的 markedText（缓冲区与候选保留）
    let onCursorModeEnd: () -> Void        // 退出光标模式（松手）时调用；把内嵌编码重新挂到新光标位置
    let onMoveCursor: (Int) -> Void        // 光标移动（正数右移，负数左移）
    let onShiftTap: () -> Void             // 单击临时大写 / 双击锁定 / 锁定后单击解锁

    /// 输入缓冲区是否非空（决定回车键显示「字符上屏」还是「回车」）
    let hasInput: Bool

    /// 光标模式（键盘级共享：激活后整个键盘区域的按键都不再上屏）
    @State private var isCursorMode = false

    /// 三排字母（与原有 26 键全拼键盘顺序一致；与设置页预览同源 Shared/KeyboardLetterRows）
    private let letterRows: [[Character]] = KeyboardLetterRows.rows

    var body: some View {
        let m = metrics
        let a = appearanceSettings

        VStack(spacing: m.rowSpacing) {
            letterRow(letterRows[0], metrics: m, appearance: a)
                .padding(.horizontal, m.hPad)

            letterRow(letterRows[1], metrics: m, appearance: a)
                .padding(.horizontal, m.hPad + m.row2Indent)

            thirdRow(metrics: m, appearance: a)

            bottomRow(metrics: m, appearance: a)
        }
        .padding(.top, m.topBotPad)
    }

    // MARK: - 字母行

    @ViewBuilder
    private func letterRow(_ keys: [Character],
                           metrics m: KeyboardMetrics,
                           appearance a: KeyboardAppearanceSettings) -> some View {
        HStack(spacing: m.keySpacing) {
            ForEach(keys, id: \.self) { key in
                letterKey(key, metrics: m, appearance: a)
                    .frame(width: m.letterKeyWidth)
            }
        }
    }

    /// 双拼字母键：三段式——灰色物理字母 + 红色声母（同行）+ 蓝色韵母（下方 1~2 行）
    @ViewBuilder
    private func letterKey(_ key: Character,
                           metrics m: KeyboardMetrics,
                           appearance a: KeyboardAppearanceSettings) -> some View {
        let label = HeErDoublePinyin.shared.keyLabels[key]
        // 声母：23 个声母键才有（a / e / o 纯韵母键不标红）
        let initial = HeErDoublePinyin.keyInitials[key]
        // 韵母按 / 拆行，最多两行（uan/van、ong/iong、uai/ing、iang/uang、ia/ua）
        let finalLines = (label?.finals ?? "")
            .split(separator: "/")
            .prefix(LayeredKeycapStyle.heErMaxFinalLines)
            .map(String.init)
        let lineCount = Swift.max(1, finalLines.count)
        // 字号按键宽实测回退（见 LayeredKeycapStyle 顶行/韵母行宽度实测一节）：
        // 纯按字母字号乘比例算，用户调大按键字号后「V zh」这类两字符声母会在窄键上摆不下，
        // 顶行就地拆行被切半截、韵母行缩到底还是省略号
        let topFont = LayeredKeycapStyle.heErTopRowFontSize(letterFontSize: m.letterFontSize,
                                                            keyWidth: m.letterKeyWidth)
        let finalsFont = LayeredKeycapStyle.heErFinalFontSize(letterFontSize: m.letterFontSize,
                                                              keyWidth: m.letterKeyWidth,
                                                              lineCount: lineCount)
        let letterLineH = m.keyHeight * LayeredKeycapStyle.heErTopRowHeightRatio
        let finalsAreaH = Swift.max(m.keyHeight - letterLineH
                                    - KeyboardKeyStyle.labelLineSpacing * CGFloat(lineCount), 0)
        let perFinalH = finalsAreaH / CGFloat(lineCount)

        Button {
            // 光标模式激活后，整个键盘区域不再上屏
            guard !isCursorMode else { return }
            onKey(String(key))
        } label: {
            VStack(spacing: KeyboardKeyStyle.labelLineSpacing) {
                // 顶行：灰色物理字母 + 红色声母（声母紧跟字母右侧，同一基线）
                // 单行锁死：字号已按键宽实测回退，正常不会超宽；万一钉到字号下限仍摆不下，
                // 也要保持一行不被切半截（拆两行时第二行会掉出 40% 行高之外，看不全）
                HStack(spacing: LayeredKeycapStyle.heErInitialGap) {
                    // 灰色物理字母恒为大写，不随 shift 变化
                    Text(String(key).uppercased())
                        .font(.system(size: topFont, weight: .regular))
                        .foregroundColor(KeyboardTheme.keyText(a)
                            .opacity(LayeredKeycapStyle.keyLetterDim))
                    if let initial = initial, !initial.isEmpty {
                        Text(initial)
                            .font(.system(size: topFont, weight: .semibold))
                            .foregroundColor(LayeredKeycapStyle.initialColor)
                    }
                }
                .lineLimit(1)
                .frame(height: letterLineH)

                // 韵母行：蓝色，没有韵母的键不占行（顶行已用 letterLineH 吃掉全部高度）
                ForEach(finalLines, id: \.self) { line in
                    Text(line)
                        .font(.system(size: finalsFont, weight: .medium))
                        .foregroundColor(LayeredKeycapStyle.finalColor)
                        .lineLimit(1)
                        .minimumScaleFactor(KeyboardKeyStyle.annotationMinScale)
                        .padding(.horizontal, KeyboardKeyStyle.heErFinalHorizontalPadding)
                        .frame(height: perFinalH)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: m.keyHeight)
            .background(KeyboardTheme.keyFill(a))
            .cornerRadius(m.keyCorner)
            .keyCapDepth()
        }
        .buttonStyle(PressStyle())
    }

    // MARK: - 第三行（Shift + 7 字母 + 退格，与老 26 键同形）

    /// 与老 26 键一致：行首 Shift、行尾退格，两个功能键同宽（funcKeyWidth），
    /// 中间 7 个字母键与上面两行等宽，右边缘与底行回车键对齐
    @ViewBuilder
    private func thirdRow(metrics m: KeyboardMetrics,
                          appearance a: KeyboardAppearanceSettings) -> some View {
        HStack(spacing: m.keySpacing) {
            ShiftKey(isShifted: isShifted, isLocked: isCapsLocked,
                     height: m.keyHeight, iconHeight: m.letterKeyWidth,
                     keyCorner: m.keyCorner, appearance: a, onTap: onShiftTap)
                .frame(width: m.funcKeyWidth)

            ForEach(letterRows[2], id: \.self) { key in
                letterKey(key, metrics: m, appearance: a)
                    .frame(width: m.letterKeyWidth)
            }

            BackspaceKey(height: m.keyHeight, iconHeight: m.letterKeyWidth,
                         keyCorner: m.keyCorner,
                         appearance: a, onTap: onBackspace)
                .frame(width: m.funcKeyWidth)
        }
        .padding(.horizontal, m.hPad)
    }

    // MARK: - 第四行（左下功能键 + 空格 + 回车，与老 26 键同形）

    @ViewBuilder
    private func bottomRow(metrics m: KeyboardMetrics,
                           appearance a: KeyboardAppearanceSettings) -> some View {
        HStack(spacing: m.keySpacing) {
            // 底行左下键（123 / 地球）：宽 = bottomCornerKeyWidth，右缘对齐第三行 z 键右缘。
            // 中英键已下线（中英切换只走候选栏快捷栏的 En），与老 26 键同形。
            switch layoutSettings.leftBottomKey {
            case .nextKeyboard:
                FuncKey(label: "", icon: "globe",
                        fontSize: m.funcFontSize, height: m.keyHeight,
                        keyCorner: m.keyCorner, appearance: a, onTap: onNextKeyboard)
                    .frame(width: m.bottomCornerKeyWidth)
            case .number123:
                FuncKey(label: "123",
                        fontSize: m.funcFontSize, height: m.keyHeight,
                        keyCorner: m.keyCorner, appearance: a, onTap: onSwitchToNumbers)
                    .frame(width: m.bottomCornerKeyWidth)
            }

            // 空格键：轻点上屏空格，长按进入全键盘光标模式
            CursorSpaceKey(
                height: m.keyHeight,
                fontSize: m.letterFontSize,
                keyCorner: m.keyCorner,
                appearance: a,
                cursorStepPoints: m.letterKeyWidth * CursorModeConfig.moveStepRatio,
                isCursorMode: $isCursorMode,
                onCursorModeStart: onCursorModeStart,
                onCursorModeEnd: onCursorModeEnd,
                onMoveCursor: onMoveCursor,
                onTap: onSpace
            ) {
                // 空格键文字与老 26 键同源：跟随「空格键标签」设置，留空时回落 "space"
                Text(layoutSettings.spaceBarDisplayLabel)
                    .font(.system(size: KeyboardKeyStyle.secondaryTextFontSize(
                        letterFontSize: m.letterFontSize)))
                    .foregroundColor(KeyboardTheme.keyText(a))
            }

            ReturnKey(hasInput: hasInput, fontSize: m.funcFontSize,
                      height: m.keyHeight, keyCorner: m.keyCorner,
                      appearance: a, onTap: onReturn)
                .frame(width: m.bottomCornerKeyWidth)
        }
        .padding(.horizontal, m.hPad)
    }
}
