import SwiftUI
import OpenIMECore

// MARK: - 键盘按键布局

struct KeyboardRowsView: View, Equatable {
    // 击键间跳过重绘：键盘根视图每次击键都因 runtime 的 @Published 变化重算 body，连带把整棵
    // 键位树重建一遍（26 个字母键各带手势与修饰符）。而击键并不改变键位外观——shift 态、几何、
    // 设置、hasInput 全不变，只有动作回调闭包换了新实例。让键位视图 Equatable + 调用处 .equatable()，
    // == 为真时 SwiftUI 整棵跳过重绘。== 只比决定外观的输入：闭包不改键面、@State 各自触发重绘，
    // 二者不纳入；其余输入全部比较，宁多比不漏比（漏比会导致该更新时不更新）。
    static func == (lhs: KeyboardRowsView, rhs: KeyboardRowsView) -> Bool {
        lhs.isShifted == rhs.isShifted
            && lhs.isCapsLocked == rhs.isCapsLocked
            && lhs.metrics == rhs.metrics
            && lhs.layoutSettings == rhs.layoutSettings
            && lhs.appearanceSettings == rhs.appearanceSettings
            && lhs.hasInput == rhs.hasInput
    }

    @Binding var isShifted: Bool
    let isCapsLocked: Bool
    let metrics: KeyboardMetrics
    let layoutSettings: KeyboardLayoutSettings
    let appearanceSettings: KeyboardAppearanceSettings
    let onKey: (String) -> Void
    let onBackspace: () -> Void
    let onReturn: () -> Void
    let onSpace: () -> Void
    let onSwitchToNumbers: () -> Void
    let onNextKeyboard: () -> Void
    let hasInput: Bool
    let onMoveCursor: (Int) -> Void       // 正数右移，负数左移
    let onCursorModeStart: () -> Void     // 进入光标模式时调用；摘掉内嵌编码的 markedText（缓冲区与候选保留）
    let onCursorModeEnd: () -> Void       // 退出光标模式（松手）时调用；把内嵌编码重新挂到新光标位置
    let onShiftTap: () -> Void            // 单击临时大写 / 双击锁定 / 锁定后单击解锁

    private let rows: [[String]] = [
        ["q","w","e","r","t","y","u","i","o","p"],
        ["a","s","d","f","g","h","j","k","l"],
        ["z","x","c","v","b","n","m"]
    ]

    // 光标移动状态（跨按键共享）
    @State private var isCursorMode = false
    @State private var cursorAnchorX: CGFloat = 0
    @State private var cursorStepCount: Int = 0

    var body: some View {
        let m = metrics
        let a = appearanceSettings
        // 光标横移一格的实际位移：按字母键边长比例推导（尺寸不写死），由 body 统一算好注入各手势
        let stepPoints = m.letterKeyWidth * CursorModeConfig.moveStepRatio
        VStack(spacing: m.rowSpacing) {
            HStack(spacing: m.keySpacing) {
                ForEach(rows[0], id: \.self) { key in
                    LetterKey(
                        label: displayLabel(key), fontSize: m.letterFontSize,
                        height: m.keyHeight, keyCorner: m.keyCorner,
                        appearance: a, onTap: { if !isCursorMode { onKey(key) } },
                        cursorStepPoints: stepPoints,
                        isCursorMode: $isCursorMode,
                        cursorAnchorX: $cursorAnchorX,
                        cursorStepCount: $cursorStepCount,
                        onCursorModeStart: onCursorModeStart,
                        onCursorModeEnd: onCursorModeEnd,
                        onMoveCursor: onMoveCursor
                    )
                    .frame(width: m.letterKeyWidth)
                }
            }
            .padding(.horizontal, m.hPad)

            HStack(spacing: m.keySpacing) {
                ForEach(rows[1], id: \.self) { key in
                    LetterKey(
                        label: displayLabel(key), fontSize: m.letterFontSize,
                        height: m.keyHeight, keyCorner: m.keyCorner,
                        appearance: a, onTap: { if !isCursorMode { onKey(key) } },
                        cursorStepPoints: stepPoints,
                        isCursorMode: $isCursorMode,
                        cursorAnchorX: $cursorAnchorX,
                        cursorStepCount: $cursorStepCount,
                        onCursorModeStart: onCursorModeStart,
                        onCursorModeEnd: onCursorModeEnd,
                        onMoveCursor: onMoveCursor
                    )
                    .frame(width: m.letterKeyWidth)
                }
            }
            .padding(.horizontal, m.hPad + m.row2Indent)

            HStack(spacing: m.keySpacing) {
                ShiftKey(isShifted: isShifted, isLocked: isCapsLocked,
                         height: m.keyHeight, iconHeight: m.letterKeyWidth,
                         keyCorner: m.keyCorner, appearance: a, onTap: onShiftTap)
                    .frame(width: m.funcKeyWidth)

                HStack(spacing: m.keySpacing) {
                    ForEach(rows[2], id: \.self) { key in
                        LetterKey(
                            label: displayLabel(key), fontSize: m.letterFontSize,
                            height: m.keyHeight, keyCorner: m.keyCorner,
                            appearance: a, onTap: { if !isCursorMode { onKey(key) } },
                            cursorStepPoints: stepPoints,
                            isCursorMode: $isCursorMode,
                            cursorAnchorX: $cursorAnchorX,
                            cursorStepCount: $cursorStepCount,
                            onCursorModeStart: onCursorModeStart,
                            onCursorModeEnd: onCursorModeEnd,
                            onMoveCursor: onMoveCursor
                        )
                        .frame(width: m.letterKeyWidth)
                    }
                }

                BackspaceKey(height: m.keyHeight, iconHeight: m.letterKeyWidth,
                             keyCorner: m.keyCorner,
                             appearance: a, onTap: onBackspace)
                    .frame(width: m.funcKeyWidth)
            }
            .padding(.horizontal, m.hPad)

            HStack(spacing: m.keySpacing) {
                // 底行左下键（123 / 地球）：宽 = bottomCornerKeyWidth，右缘对齐第三行 z 键右缘。
                // 中英键已下线（中英切换只走候选栏快捷栏的 En），底行只剩左下键 + 弹性空格 + 回车。
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

                SpaceKey(
                    label: layoutSettings.spaceBarDisplayLabel,
                    fontSize: KeyboardKeyStyle.secondaryTextFontSize(letterFontSize: m.letterFontSize),
                    height: m.keyHeight, keyCorner: m.keyCorner,
                    appearance: a,
                    onTap: { if !isCursorMode { onSpace() } },
                    cursorStepPoints: stepPoints,
                    isCursorMode: $isCursorMode,
                    cursorAnchorX: $cursorAnchorX,
                    cursorStepCount: $cursorStepCount,
                    onCursorModeStart: onCursorModeStart,
                    onCursorModeEnd: onCursorModeEnd,
                    onMoveCursor: onMoveCursor
                )

                // 回车键：宽 = bottomCornerKeyWidth，左缘对齐第三行 m 键左缘（与左下键对称）
                ReturnKey(hasInput: hasInput, fontSize: m.funcFontSize,
                          height: m.keyHeight, keyCorner: m.keyCorner,
                          appearance: a, onTap: onReturn)
                    .frame(width: m.bottomCornerKeyWidth)
            }
            .padding(.horizontal, m.hPad)
        }
        .padding(.top, m.topBotPad)
    }

    private func displayLabel(_ key: String) -> String {
        isShifted ? key.uppercased() : key
    }
}

// MARK: - 按下反馈样式

struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            // 按压反馈三值复用 KeyboardKeyStyle 的命名常量（与副键盘纯键面按压观感同源、全仓单一定义），
            // 不再各写一份 0.94 / -0.08 / 0.08 的裸值
            .scaleEffect(configuration.isPressed ? KeyboardKeyStyle.pressScale : 1.0)
            .brightness(configuration.isPressed ? KeyboardKeyStyle.pressBrightness : 0)
            .animation(.easeInOut(duration: KeyboardKeyStyle.pressAnimationDuration), value: configuration.isPressed)
    }
}

// MARK: - 光标模式手势 Modifier
// 按住不放（超过 CursorModeConfig.longPressDuration 的极短窗口）即进入光标模式，
// 横向拖动每「字母键边长 × moveStepRatio」移一格（步长由调用方注入，不写死绝对点数）

private struct CursorGestureModifier: ViewModifier {
    @Binding var isCursorMode: Bool
    @Binding var cursorAnchorX: CGFloat
    @Binding var cursorStepCount: Int
    /// 横向滑动移动一格光标的位移（pt）：调用方用 metrics.letterKeyWidth × CursorModeConfig.moveStepRatio 算好传入
    let cursorStepPoints: CGFloat
    let onCursorModeStart: () -> Void
    let onCursorModeEnd: () -> Void
    let onMoveCursor: (Int) -> Void

    // 长按识别状态（用 @State 跨 gesture 回调共享）
    @State private var longPressTriggered = false
    @State private var pressStartTime: Date = .distantPast
    @State private var pressTimer: Timer? = nil

    func body(content: Content) -> some View {
        content
            .simultaneousGesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .onChanged { value in
                        // 触摸开始（translation 接近零时）时启动长按计时器
                        if !longPressTriggered && pressTimer == nil {
                            if isCursorMode {
                                // 上一次触摸的 onEnded 没收到（系统打断手势 / 视图结构变化），
                                // 幽灵计时器已把光标模式置留。把本次触摸当作「继续滑动」：
                                // 换新锚点重算位移，不再白等一次长按 —— 与 CursorSpaceKey
                                // 的自愈分支同一修法，顺便把滞留的 isCursorMode 重新接管回来
                                pressStartTime = Date()
                                longPressTriggered = true
                                cursorAnchorX = value.startLocation.x
                                cursorStepCount = 0
                            } else {
                                pressStartTime = Date()
                                let startLoc = value.startLocation
                                pressTimer = Timer.scheduledTimer(withTimeInterval: CursorModeConfig.longPressDuration,
                                                                  repeats: false) { _ in
                                    DispatchQueue.main.async {
                                        longPressTriggered = true
                                        isCursorMode = true
                                        cursorAnchorX = startLoc.x
                                        cursorStepCount = 0
                                        onCursorModeStart()
                                        Haptics.confirm()
                                    }
                                }
                            }
                        }

                        // 一滑即触发：长按定时器还没到点，但横向位移已超阈值 —— 立即进光标模式（空格键与字母键一致）。
                        // 以起触点为锚：阈值（≈7pt）小于一格步长（≈18pt），Int(dx/step)=0，触发瞬间不跳格
                        if !longPressTriggered && pressTimer != nil {
                            let slideThreshold = cursorStepPoints * CursorModeConfig.slideTriggerRatio
                            if abs(value.translation.width) >= slideThreshold {
                                pressTimer?.invalidate()
                                pressTimer = nil
                                longPressTriggered = true
                                isCursorMode = true
                                cursorAnchorX = value.startLocation.x
                                cursorStepCount = 0
                                onCursorModeStart()
                                Haptics.confirm()
                            }
                        }

                        guard longPressTriggered else { return }

                        // 横向拖动计算步数
                        let dx = value.location.x - cursorAnchorX
                        let newStep = Int(dx / cursorStepPoints)
                        let delta = newStep - cursorStepCount
                        if delta != 0 {
                            cursorStepCount = newStep
                            onMoveCursor(delta)
                            Haptics.step()
                        }
                    }
                    .onEnded { _ in
                        pressTimer?.invalidate()
                        pressTimer = nil
                        let wasCursorMode = longPressTriggered
                        longPressTriggered = false
                        cursorStepCount = 0
                        // 延迟一拍再清 isCursorMode：Button 的 tap 动作在松手时仍会触发，
                        // 同步清零会让 onTap 里的 `if !isCursorMode` 守卫失效，
                        // 长按空格滑完光标松手又多上屏一个空格
                        DispatchQueue.main.async {
                            isCursorMode = false
                            if wasCursorMode { onCursorModeEnd() }
                        }
                    }
            )
            // 视图消失（键盘收起 / 切布局）时兜底拆计时器：这是 onEnded 缺席时
            // 唯一还保证会走的清理出口，防幽灵长按在回到前台后突然切入光标模式
            .onDisappear {
                pressTimer?.invalidate()
                pressTimer = nil
            }
    }
}

// MARK: - 字母键

struct LetterKey: View {
    let label: String
    let fontSize: CGFloat
    let height: CGFloat
    let keyCorner: CGFloat
    let appearance: KeyboardAppearanceSettings
    let onTap: () -> Void
    /// 横向滑动移动一格光标的位移（pt），由调用方注入（尺寸按比例推导）
    let cursorStepPoints: CGFloat
    @Binding var isCursorMode: Bool
    @Binding var cursorAnchorX: CGFloat
    @Binding var cursorStepCount: Int
    let onCursorModeStart: () -> Void
    let onCursorModeEnd: () -> Void
    let onMoveCursor: (Int) -> Void

    var body: some View {
        Button(action: onTap) {
            Text(label)
                .font(.system(size: fontSize, weight: .regular))
                .foregroundColor(KeyboardTheme.keyText(appearance))
                .frame(maxWidth: .infinity)
                .frame(height: height)
                .background(
                    KeyboardTheme.keyFill(appearance)
                        .overlay(isCursorMode ? Color.accentColor.opacity(0.08) : Color.clear)
                )
                .cornerRadius(keyCorner)
                .keyCapDepth()
        }
        .buttonStyle(PressStyle())
        .modifier(CursorGestureModifier(
            isCursorMode: $isCursorMode,
            cursorAnchorX: $cursorAnchorX,
            cursorStepCount: $cursorStepCount,
            cursorStepPoints: cursorStepPoints,
            onCursorModeStart: onCursorModeStart,
            onCursorModeEnd: onCursorModeEnd,
            onMoveCursor: onMoveCursor
        ))
    }
}

// MARK: - 空格键（支持光标移动）

struct SpaceKey: View {
    let label: String
    let fontSize: CGFloat
    let height: CGFloat
    let keyCorner: CGFloat
    let appearance: KeyboardAppearanceSettings
    let onTap: () -> Void
    /// 横向滑动移动一格光标的位移（pt），由调用方注入（尺寸按比例推导）
    let cursorStepPoints: CGFloat
    @Binding var isCursorMode: Bool
    @Binding var cursorAnchorX: CGFloat
    @Binding var cursorStepCount: Int
    let onCursorModeStart: () -> Void
    let onCursorModeEnd: () -> Void
    let onMoveCursor: (Int) -> Void

    var body: some View {
        Button(action: onTap) {
            // 光标模式提示文字与新增键盘共用同一份定义（取值与原实现完全一致）
            Text(isCursorMode ? CursorModeConfig.indicatorText : label)
                .font(.system(size: isCursorMode ? fontSize - KeyboardKeyStyle.secondaryTextFontDelta : fontSize))
                .foregroundColor(isCursorMode ? Color.accentColor : KeyboardTheme.keyText(appearance))
                .frame(maxWidth: .infinity)
                .frame(height: height)
                .background(KeyboardTheme.keyFill(appearance))
                .cornerRadius(keyCorner)
                .keyCapDepth()
        }
        .buttonStyle(.plain)
        // 空格键的 label 是用户可自定义的空格键标签（默认「space」），自动化不能按文字找；
        // 给一个与标签无关的稳定标识（与候选栏 candidateBarLogo / expandCandidatesKey 同一套约定）
        .accessibilityIdentifier("spaceKey")
        .modifier(CursorGestureModifier(
            isCursorMode: $isCursorMode,
            cursorAnchorX: $cursorAnchorX,
            cursorStepCount: $cursorStepCount,
            cursorStepPoints: cursorStepPoints,
            onCursorModeStart: onCursorModeStart,
            onCursorModeEnd: onCursorModeEnd,
            onMoveCursor: onMoveCursor
        ))
    }
}

// MARK: - Shift 键（三态：小写 / 临时大写 / 双击锁定大写）

struct ShiftKey: View {
    let isShifted: Bool
    let isLocked: Bool
    let height: CGFloat
    /// 图标字号的基准行高：默认跟键高走；调高键盘时传 letterKeyWidth（=默认系数下的正方形键高），
    /// 让 shift 图标不随键高被拉粗、显得很重（与退格键同一修法）
    var iconHeight: CGFloat? = nil
    let keyCorner: CGFloat
    let appearance: KeyboardAppearanceSettings
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            Image(systemName: iconName)
                .font(.system(size: KeyboardGridGeometry.iconFontSize(forKeyHeight: iconHeight ?? height), weight: .medium))
                .foregroundColor(KeyboardTheme.shiftKeyTint)
                .frame(maxWidth: .infinity)
                .frame(height: height)
                .background(KeyboardTheme.tintedKeyFill(appearance, tint: KeyboardTheme.shiftKeyTint.opacity(KeyboardKeyStyle.tintedKeyFillOpacity)))
                .cornerRadius(keyCorner)
                .keyCapDepth()
        }
        .buttonStyle(PressStyle())
    }

    /// 锁定态用 capslock 图标，与临时大写（shift.fill）区分开
    private var iconName: String {
        if isLocked { return "capslock.fill" }
        return isShifted ? "shift.fill" : "shift"
    }
}

// MARK: - 退格键（支持长按连续删除，向左滑动加速）

struct BackspaceKey: View {
    let height: CGFloat
    /// 图标字号的基准行高：默认跟键高走；键很高（如跨行的退格）时传入单行行高，
    /// 避免图标随键高翻倍显得过粗
    var iconHeight: CGFloat? = nil
    let keyCorner: CGFloat
    let appearance: KeyboardAppearanceSettings
    let onTap: () -> Void
    @State private var timer: Timer?
    @State private var currentInterval: Double = 0.1
    /// 连删起始时刻：供计时器自检最长时限（onEnded 缺席时的强制止损线）
    @State private var repeatStartTime: Date = .distantPast

    var body: some View {
        Button(action: {}) {
            Image(systemName: "delete.left")
                .font(.system(size: KeyboardGridGeometry.iconFontSize(forKeyHeight: iconHeight ?? height), weight: .medium))
                .foregroundColor(Color(.systemRed))
                .frame(maxWidth: .infinity)
                .frame(height: height)
                .background(KeyboardTheme.tintedKeyFill(appearance, tint: Color(.systemRed).opacity(KeyboardKeyStyle.tintedKeyFillOpacity)))
                .cornerRadius(keyCorner)
                .keyCapDepth()
        }
        .buttonStyle(PressStyle())
        .simultaneousGesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .local)
                .onChanged { value in
                    let dx = value.translation.width
                    let dy = value.translation.height

                    // 非向左方向偏移过大（向右/上/下）时停止
                    if dx > 40 || abs(dy) > 80 {
                        timer?.invalidate()
                        timer = nil
                        return
                    }

                    // 根据向左距离确定速度档位
                    let targetInterval: Double
                    if dx < -200 && abs(dy) < 80 {
                        targetInterval = 0.02   // 极速：约50次/秒
                    } else if dx < -100 && abs(dy) < 80 {
                        targetInterval = 0.04   // 快速：约25次/秒
                    } else {
                        targetInterval = 0.1    // 正常：约10次/秒
                    }

                    if timer == nil {
                        onTap()
                        currentInterval = targetInterval
                        repeatStartTime = Date()
                        timer = Timer.scheduledTimer(withTimeInterval: targetInterval, repeats: true) { t in
                            // 时限兜底：正常松手由 onEnded 停表；系统打断触摸时 onEnded 不保证
                            // 回调，repeats 计时器会无人喊停地删下去。超线强制停，
                            // 宁可误停也不冒连删整段文本的险（正常人按不满此时长）
                            if Date().timeIntervalSince(repeatStartTime) > BackspaceKeyConfig.maxRepeatDuration {
                                t.invalidate()
                                timer = nil
                                currentInterval = 0.1
                                return
                            }
                            DispatchQueue.main.async { self.onTap() }
                        }
                    } else if abs(targetInterval - currentInterval) > 0.001 {
                        // 变速重排：沿用 repeatStartTime，重置只认长按起点，不影响时限统计
                        timer?.invalidate()
                        currentInterval = targetInterval
                        timer = Timer.scheduledTimer(withTimeInterval: targetInterval, repeats: true) { t in
                            if Date().timeIntervalSince(repeatStartTime) > BackspaceKeyConfig.maxRepeatDuration {
                                t.invalidate()
                                timer = nil
                                currentInterval = 0.1
                                return
                            }
                            DispatchQueue.main.async { self.onTap() }
                        }
                    }
                }
                .onEnded { _ in
                    timer?.invalidate()
                    timer = nil
                    currentInterval = 0.1
                }
        )
        // 与光标手势同一兜底：视图消失时强制停表，防 onEnded 缺席后后台连删
        .onDisappear {
            timer?.invalidate()
            timer = nil
            currentInterval = 0.1
        }
    }
}

// MARK: - 功能键

struct FuncKey: View {
    let label: String
    let icon: String?
    let fontSize: CGFloat
    let height: CGFloat
    let keyCorner: CGFloat
    let appearance: KeyboardAppearanceSettings
    let onTap: () -> Void

    // 不给 fontSize / height / keyCorner 设默认值：默认值只能是写死的绝对点数（14 / 42 / 5），
    // 而每个调用方都传入随屏幕推导的 m.funcFontSize / m.keyHeight / m.keyCorner，故去掉这三个死默认值
    init(label: String, icon: String? = nil,
         fontSize: CGFloat, height: CGFloat, keyCorner: CGFloat,
         appearance: KeyboardAppearanceSettings = KeyboardAppearanceSettings(),
         onTap: @escaping () -> Void) {
        self.label = label
        self.icon = icon
        self.fontSize = fontSize
        self.height = height
        self.keyCorner = keyCorner
        self.appearance = appearance
        self.onTap = onTap
    }

    var body: some View {
        let primary = KeyboardTheme.primaryColor(appearance)
        Button(action: onTap) {
            Group {
                if let icon = icon {
                    // 图标字号 = 功能键字号乘 iconFontRatio（相对化）：不再用写死的「+3pt」，
                    // 换屏幕 / 改字号都跟着缩放，且与 Shift / 退格图标同源、同大小
                    Image(systemName: icon).font(.system(size: fontSize * KeyboardGridGeometry.iconFontRatio))
                } else {
                    Text(label).font(.system(size: fontSize))
                }
            }
            .foregroundColor(primary)
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .background(KeyboardTheme.tintedKeyFill(appearance, tint: primary.opacity(KeyboardKeyStyle.tintedKeyFillOpacity)))
            .cornerRadius(keyCorner)
            .keyCapDepth()
        }
        .buttonStyle(PressStyle())
    }
}

// MARK: - 回车键

struct ReturnKey: View {
    let hasInput: Bool
    let fontSize: CGFloat
    let height: CGFloat
    let keyCorner: CGFloat
    let appearance: KeyboardAppearanceSettings
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            Group {
                if hasInput {
                    Text("字符上屏")
                        .font(.system(size: fontSize - KeyboardKeyStyle.secondaryTextFontDelta))
                        .foregroundColor(KeyboardTheme.returnKeyTint)
                } else {
                    Image(systemName: "checkmark")
                        .font(.system(size: fontSize * KeyboardGridGeometry.returnIconFontRatio, weight: .semibold))
                        .foregroundColor(KeyboardTheme.returnKeyTint)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .background(KeyboardTheme.tintedKeyFill(appearance, tint: KeyboardTheme.returnKeyTint.opacity(KeyboardKeyStyle.tintedKeyFillOpacity)))
            .cornerRadius(keyCorner)
            .keyCapDepth()
        }
        .buttonStyle(PressStyle())
    }
}

