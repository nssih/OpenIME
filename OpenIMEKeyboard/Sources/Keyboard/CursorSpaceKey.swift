import SwiftUI
import OpenIMECore

// MARK: - 长按空格模块：光标移动模式
//
// 交互约定：
//   不为每个按键单独做长按符号气泡；
//   长按只在空格键上触发，且激活后整个键盘区域都进入光标模式：
//       1. 按住空格不放（非点按，超过 CursorModeConfig.longPressDuration 的极短窗口）即进入
//          光标模式；未上屏编码与候选保留不动
//          （光标移动只动宿主光标，清编码会丢用户已打内容——曾因此被判定为 bug）
//       2. 光标模式下整个键盘的按键都不再上屏（避免误输入）
//       3. 手指可在整个键盘区域任意横向滑动，每「字母键边长 × moveStepRatio」移动一格光标
//       4. 松开手指退出光标模式
//
// 说明：原有 26 键全拼键盘使用它自己的 SpaceKey / CursorGestureModifier，完全未改动；
// 本组件供小鹤双拼、副键盘两个模块共用。

struct CursorSpaceKey<Label: View>: View {

    let width: CGFloat?
    let height: CGFloat
    /// 空格标签主字号（光标模式提示文字在此基础上下调一档，与原有 SpaceKey 一致）
    let fontSize: CGFloat
    let keyCorner: CGFloat
    let appearance: KeyboardAppearanceSettings
    /// 横向滑动移动一格光标的位移（pt）：由调用方用 metrics.letterKeyWidth × CursorModeConfig.moveStepRatio
    /// 算好传入，本组件不写死绝对点数（尺寸按比例推导）
    let cursorStepPoints: CGFloat

    /// 是否处于光标模式（键盘级共享状态，用于禁用其它按键的点击）
    @Binding var isCursorMode: Bool

    /// 进入光标模式时回调；调用方在这里摘掉内嵌编码的 markedText（缓冲区与候选保留），
    /// 否则宿主光标被 marked 区间困住，adjustTextPosition 移不动
    let onCursorModeStart: () -> Void
    /// 退出光标模式（松手）时回调；调用方把内嵌编码重新挂到新光标位置
    let onCursorModeEnd: () -> Void
    /// 光标移动回调：正数右移，负数左移
    let onMoveCursor: (Int) -> Void
    /// 轻点回调（上屏空格）
    let onTap: () -> Void

    let label: Label

    // 长按识别状态
    @State private var pressTimer: Timer?
    @State private var longPressTriggered = false
    @State private var lastTouchX: CGFloat = 0
    @State private var cursorAnchorX: CGFloat = 0
    @State private var cursorStepCount: Int = 0

    init(width: CGFloat? = nil,
         height: CGFloat,
         fontSize: CGFloat,
         keyCorner: CGFloat,
         appearance: KeyboardAppearanceSettings,
         cursorStepPoints: CGFloat,
         isCursorMode: Binding<Bool>,
         onCursorModeStart: @escaping () -> Void,
         onCursorModeEnd: @escaping () -> Void = {},
         onMoveCursor: @escaping (Int) -> Void,
         onTap: @escaping () -> Void,
         @ViewBuilder label: () -> Label) {
        self.width = width
        self.height = height
        self.fontSize = fontSize
        self.keyCorner = keyCorner
        self.appearance = appearance
        self.cursorStepPoints = cursorStepPoints
        self._isCursorMode = isCursorMode
        self.onCursorModeStart = onCursorModeStart
        self.onCursorModeEnd = onCursorModeEnd
        self.onMoveCursor = onMoveCursor
        self.onTap = onTap
        self.label = label()
    }

    var body: some View {
        // 注意：空格标签与光标模式提示必须同时存在于视图树中，只用透明度切换。
        // 若改用 `if isCursorMode { 提示 } else { 标签 }`，切换时当前分支视图会被销毁重建，
        // 挂在其上的 DragGesture 也被取消（onChanged / onEnded 不再回调），
        // 表现为「长按出现箭头后拖不动，必须松手再按一次」。（原 26 键 SpaceKey 用同一个
        // Text 只换文字，所以没有该问题。）
        ZStack {
            label
                .opacity(isCursorMode ? 0 : 1)

            // 光标模式提示（与原有 26 键的空格键提示一致）
            Text(CursorModeConfig.indicatorText)
                .font(.system(size: KeyboardKeyStyle.secondaryTextFontSize(letterFontSize: fontSize)))
                .foregroundColor(Color.accentColor)
                .opacity(isCursorMode ? 1 : 0)
        }
        .frame(width: width)
        .frame(maxWidth: width == nil ? .infinity : nil)
        .frame(height: height)
        .background(KeyboardTheme.keyFill(appearance))
        .cornerRadius(keyCorner)
        .keyCapDepth()
        .contentShape(Rectangle())
        .simultaneousGesture(cursorGesture)
    }

    // MARK: - 长按 / 滑动

    private var cursorGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { value in
                // 记录手指当前位置：长按触发时以「最后一帧位置」为锚点，避免激活瞬间光标跳动
                if !longPressTriggered {
                    lastTouchX = value.location.x
                }

                // 触摸开始（全局坐标，手指可移出空格键）
                if pressTimer == nil && !longPressTriggered {
                    if isCursorMode {
                        // 已在光标模式下：说明上一次触摸的结束回调没有收到
                        //（例如视图结构变化使系统取消了手势）。
                        // 直接把本次触摸当作「继续滑动」，不再等一次长按，
                        // 也避免沿用旧锚点造成光标跳格。
                        beginDragging(at: value.startLocation.x)
                    } else {
                        startLongPressTimer()
                    }
                }

                // 一滑即触发：长按定时器还没到点，但横向位移已超阈值 —— 立即进光标模式，
                // 不必死等 longPressDuration。对齐用户「只要在空格上滑动就立即移光标」的诉求。
                // 以起触点为锚：阈值（≈7pt）小于一格步长（≈18pt），moveCursor 换算 Int(dx/step)=0，不跳格
                if !longPressTriggered && pressTimer != nil {
                    let slideThreshold = cursorStepPoints * CursorModeConfig.slideTriggerRatio
                    if abs(value.translation.width) >= slideThreshold {
                        stopTimer()
                        beginDragging(at: value.startLocation.x)
                        isCursorMode = true
                        onCursorModeStart()
                        Haptics.confirm()
                    }
                }

                guard longPressTriggered else { return }

                // 整个键盘区域内横向滑动都生效：按固定步长换算光标位移
                moveCursor(to: value.location.x)
            }
            .onEnded { _ in
                stopTimer()
                if longPressTriggered {
                    // 长按过：退出光标模式，且不再上屏空格
                    longPressTriggered = false
                    isCursorMode = false
                    cursorStepCount = 0
                    onCursorModeEnd()
                } else {
                    onTap()
                }
            }
    }

    /// 启动长按计时：达到时长后进入光标模式，锚点取手指当前所在位置
    private func startLongPressTimer() {
        pressTimer = Timer.scheduledTimer(withTimeInterval: CursorModeConfig.longPressDuration,
                                          repeats: false) { _ in
            DispatchQueue.main.async {
                stopTimer()
                beginDragging(at: lastTouchX)
                isCursorMode = true
                onCursorModeStart()
                Haptics.confirm()
            }
        }
    }

    /// 进入（或继续）拖动：以 anchorX 为锚点、步数归零，之后同一手指的滑动都从这里算位移
    private func beginDragging(at anchorX: CGFloat) {
        longPressTriggered = true
        cursorAnchorX = anchorX
        cursorStepCount = 0
    }

    /// 手指横向位移换算成光标步数（每 cursorStepPoints 一格；以固定锚点绝对换算，不累积误差、不飘）
    private func moveCursor(to x: CGFloat) {
        let newStep = Int((x - cursorAnchorX) / cursorStepPoints)
        let delta = newStep - cursorStepCount
        guard delta != 0 else { return }
        cursorStepCount = newStep
        onMoveCursor(delta)
        Haptics.step()
    }

    private func stopTimer() {
        pressTimer?.invalidate()
        pressTimer = nil
    }
}
