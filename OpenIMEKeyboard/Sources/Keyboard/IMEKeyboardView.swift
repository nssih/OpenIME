import SwiftUI
import UIKit
import AudioToolbox
import OpenIMECore

// MARK: - 触感发生器（全键盘共享，按 style 各持一个静态实例复用）
//
// 击键、长按进光标、光标逐格移动、副键盘选宽都是重复触发，每次 new 一个 UIImpactFeedbackGenerator
// 是无谓的临时分配（键盘内存要压到最低）；改为按 style 各缓存一个静态实例全键盘复用，触发前 prepare()
// 唤醒 Taptic Engine（闲置休眠后不唤醒会被吞），prepare 只唤醒引擎、不分配内存。
// 三档 style 对应三种既定手感，改档等于改手感，不得随意动。
enum Haptics {
    /// 按键点击：.rigid 短促结实的「硬点击」，质感清脆。原先用 .light（软、扩散），连打时像一团颤震、发飘。
    private static let tapGenerator = UIImpactFeedbackGenerator(style: .rigid)
    /// 进入光标模式 / 长按选宽：.medium，比按键更明显的一下确认感。
    private static let confirmGenerator = UIImpactFeedbackGenerator(style: .medium)
    /// 光标逐格移动 / 选宽滑动切换：.light，最轻的一下，连续触发也不喧宾夺主。
    private static let stepGenerator = UIImpactFeedbackGenerator(style: .light)

    static func tap() { fire(tapGenerator) }
    static func confirm() { fire(confirmGenerator) }
    static func step() { fire(stepGenerator) }

    private static func fire(_ generator: UIImpactFeedbackGenerator) {
        generator.prepare()
        generator.impactOccurred()
    }
}

// MARK: - 按键声音 + 震动反馈
//
// 与系统输入法同款的点击手感：声音用 iOS 标准键盘点击音，震动走共享的 Haptics.tap()（.rigid）。
// 声音 / 震动各自可关（见 UserSettings.keySoundEnabled / keyHapticEnabled），调用方传开关进来。
enum KeyFeedback {
    /// iOS 标准键盘点击音（Tock）——别的输入法用的就是这个系统音，不自己带音频文件
    private static let clickSoundID: SystemSoundID = 1104

    /// 按开关播一下点击音 / 震一下；两个开关都关时什么都不做
    static func play(sound: Bool, haptic: Bool) {
        if sound { AudioServicesPlaySystemSound(clickSoundID) }
        if haptic { Haptics.tap() }
    }
}

// MARK: - 键盘主视图

struct IMEKeyboardView: View {
    @EnvironmentObject private var runtime: IMERuntime

    let onInsert: (String) -> Void
    let onBackspace: () -> Void
    let onReturn: () -> Void
    let onDismiss: () -> Void
    let onNextKeyboard: () -> Void
    let onMoveCursor: (Int) -> Void
    /// 进入光标模式：宿主侧摘掉内嵌编码的 markedText（缓冲区与候选保留），
    /// 否则光标被 marked 区间困住移不动
    let onCursorModeStart: () -> Void
    /// 退出光标模式（松手）：宿主侧把内嵌编码重新挂到新光标位置
    let onCursorModeEnd: () -> Void
    let homeIndicatorHeight: () -> CGFloat   // 闭包，每次布局动态读取

    @State private var isShifted = false
    /// 大写锁定：双击 Shift 进入、锁定后单击退出（锁定期间字母不再自动回落小写）
    @State private var isCapsLocked = false
    @State private var lastShiftTap: Date = .distantPast
    @State private var showingNumbers = false
    @State private var isExpanded = false
    /// 快捷面板：点候选栏左侧标志展开，覆盖整个键盘输入区
    @State private var isLogoPanel = false
    /// 剪贴板历史面板：点快捷面板分区四「查看历史」或候选栏空态的剪贴板快捷图标展开
    @State private var isClipboardPanel = false
    /// 手动组句面板：长码时候选栏「组句」入口展开，覆盖整个键盘输入区（与其它面板互斥）
    @State private var isComposing = false
    /// 中 / 英 输入模式（持久化在 EnglishModeStore）：英文 = 纯字母直上屏
    @State private var isEnglish = EnglishModeStore.shared.isEnglish

    // 小鹤双拼 / 26 键：当前键盘形态，默认使用原有 26 键全拼键盘
    @State private var keyboardMode: KeyboardMode = KeyboardModeStore.shared.mode

    /// 顶部执行结果 toast 文案（nil = 不显示）：动作型 / 开关型按钮点击后短暂提示
    @State private var toastText: String?

    private var layout: KeyboardLayoutSettings { runtime.settings.keyboardLayout }
    private var appearance: KeyboardAppearanceSettings { runtime.settings.keyboardAppearance }

    /// 生效中的英文模式 = 用户选择的中/英状态。中英切换只走候选栏快捷栏的 En
    ///（.toggleEnglish → handleToggleLanguage），键盘布局上不再有物理中/英键。
    private var isEnglishActive: Bool { isEnglish }

    var body: some View {
        // 键盘高度改为「内容自驱动」（对齐元书 / KeyboardKit）：先在 GeometryReader 外用屏宽 +
        // 底部安全区算出键盘总高 totalHeight，再用它把 GeometryReader 定高（见 body 末尾
        // .frame(height:)）。这样内容有了确定的 intrinsicContentSize，键盘高度由内容决定 ——
        // VC 侧不再压一条高度约束去和系统 UIInputSetHostView 抢（那条 999 约束正是转场把
        // inputView 撑到整屏 844、底部锚定内容上方留出透明缝、透出系统灰背板 = 半屏灰闪的根源）。
        // 宽度沿用 GeometryReader 读到的 offered 宽度（键盘宽 == 屏宽）；安全区真值到达 / 旋转 /
        // 改设置后由 VC 重设 rootView 触发本 body 重算，刷新 totalHeight 与 intrinsic 高度。
        let screenWidth = UIScreen.main.bounds.width
        let totalHeight = KeyboardMetrics.totalHeight(
            screenWidth: screenWidth,
            safeAreaBottom: homeIndicatorHeight(),
            layoutSettings: layout,
            appearanceSettings: appearance,
            showAnnotation: true
        )
        GeometryReader { geo in
            // 永久固定取开启注释的高度，不再跟随runtime.showAnnotationRow变化
            let candidateH = CGFloat(appearance.candidateBarHeight(showAnnotation: true))
            let metrics = KeyboardMetrics(
                screenWidth: geo.size.width,
                layoutSettings: layout,
                appearanceSettings: appearance
            )
            let bodyHeight = metrics.bodyHeight
            let panelTotalHeight = candidateH + bodyHeight

            VStack(spacing: 0) {
                if isComposing {
                    // 手动组句面板：覆盖整个键盘输入区，用户逐段挑字词组成长句
                    CompositionPanel(
                        appearance: appearance,
                        bottomBarHeight: candidateH * 0.85,
                        onFinish: { text in
                            onInsert(text)
                            withAnimation(.easeInOut(duration: KeyboardAnimation.transitionDuration)) { isComposing = false }
                        },
                        onCancel: closeComposition
                    )
                    .frame(height: panelTotalHeight)
                } else if isClipboardPanel {
                    // 剪贴板历史面板：覆盖整个键盘输入区，形态同快捷面板 / 候选展开面板
                    ClipboardHistoryPanel(
                        letterKeySize: metrics.letterKeyWidth,
                        appearance: appearance,
                        bottomBarHeight: candidateH * 0.85,
                        onInsertText: { text in onInsert(text) },
                        onClose: closeClipboardPanel
                    )
                    .frame(height: panelTotalHeight)
                } else if isLogoPanel {
                    // 快捷面板：切输入方案 / 切键盘形态（后续可继续加分区）
                    QuickPanelView(
                        letterKeySize: metrics.letterKeyWidth,
                        appearance: appearance,
                        bottomBarHeight: candidateH * 0.85,
                        schemes: runtime.installedSchemes,
                        activeSchemeId: runtime.settings.activeSchemeId,
                        currentMode: keyboardMode,
                        onSelectScheme: { id in
                            runtime.activateScheme(id: id)
                            closeLogoPanel()
                        },
                        onSelectKeyboard: { mode in
                            if runtime.availableKeyboardModes.contains(mode) {
                                switchKeyboardMode(mode)
                                closeLogoPanel()
                            } else {
                                showToast("「\(activeSchemeName)」不支持\(mode.displayName)")
                            }
                        },
                        onDismissKeyboard: onDismiss,
                        onOpenClipboard: openClipboardPanel,
                        onClose: closeLogoPanel
                    )
                    .frame(height: panelTotalHeight)
                } else if isExpanded {
                    CandidateExpandedPanel(
                        candidates: runtime.candidates,
                        mode: keyboardMode,
                        appearance: appearance,
                        bottomBarHeight: candidateH * 0.85,
                        onSelect: { candidate in
                            let text = runtime.selectCandidate(candidate)
                            onInsert(text)
                            // 瞬切收起（不用 withAnimation）：面板与键盘体等高，无需动画，
                            // 避免 if/else 交叉浡入的键盘残影（与展开时的修法一致）
                            isExpanded = false
                        },
                        onDismiss: {
                            isExpanded = false
                        },
                        onDeleteRaw: {
                            if runtime.inputBuffer.isEmpty {
                                onBackspace()
                            } else {
                                runtime.deleteLastInput(mode: keyboardMode)
                            }
                        }
                    )
                    .frame(height: panelTotalHeight)
                } else {
                    // 候选栏：两种键盘形态共用原有 CandidateBarView，
                    // 保证「横向滑动 + 展开面板」的行为与效果和原 26 键完全一致
                    candidateBar(candidateHeight: candidateH, metrics: metrics)

                    ZStack {
                        if showingNumbers {
                            // 副键盘布局模块：数字符号副键盘，中间数字键阵加两侧符号
                            NumberKeyboardView (
                                metrics: metrics,
                                appearanceSettings: appearance,
                                // 副键盘符号的半全角由 KeypadKeySpec.glyph(isEnglish:) 就地处理：
                                // 数字页/符号页英文模式出半角、中文模式出全角，中文专用符两模式同形，
                                // 长按还能弹气泡滑动显式取另一种；故这里 onInsert 原样上屏，不再统一过 asciiEquivalent
                                isEnglishActive: isEnglishActive,
                                hasInput: !runtime.inputBuffer.isEmpty,
                                onInsert: { text in playKeyFeedback(); onInsert(text) },
                                onBackspace: handleBackspace,
                                onReturn: handleReturn,
                                onSwitchToLetters: { showingNumbers = false },
                                onCursorModeStart: onCursorModeStart,
                                onCursorModeEnd: onCursorModeEnd,
                                onMoveCursor: onMoveCursor
                            )
                        } else if keyboardMode == .heEr {
                            // 小鹤双拼模块：小鹤双拼 26 键键盘
                            // 键盘形态切换不在主键盘上占键位：走候选栏标志打开的快捷面板
                            HeErKeyboardView(
                                isShifted: $isShifted,
                                isCapsLocked: isCapsLocked,
                                metrics: metrics,
                                appearanceSettings: appearance,
                                layoutSettings: layout,
                                onKey: handleKey,
                                onBackspace: handleBackspace,
                                onReturn: handleReturn,
                                onSpace: handleSpace,
                                onSwitchToNumbers: { showingNumbers = true },
                                onNextKeyboard: onNextKeyboard,
                                onCursorModeStart: onCursorModeStart,
                                onCursorModeEnd: onCursorModeEnd,
                                onMoveCursor: onMoveCursor,
                                onShiftTap: handleShiftTap,
                                hasInput: !runtime.inputBuffer.isEmpty
                            )
                            // 击键间跳过重绘：HeErKeyboardView 已 Equatable，== 为真时整棵键位树不重建
                            .equatable()
                            // 键面占满整宽并靠左对齐，避免被 ZStack 居中悬浮出左右空白带
                            .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            // 原有 26 键全拼键盘：中英键已下线，底行只剩左下键 + 空格 + 回车
                            KeyboardRowsView (
                                isShifted: $isShifted,
                                isCapsLocked: isCapsLocked,
                                metrics: metrics,
                                layoutSettings: layout,
                                appearanceSettings: appearance,
                                onKey: handleKey,
                                onBackspace: handleBackspace,
                                onReturn: handleReturn,
                                onSpace: handleSpace,
                                onSwitchToNumbers: { showingNumbers = true },
                                onNextKeyboard: onNextKeyboard,
                                hasInput: !runtime.inputBuffer.isEmpty,
                                onMoveCursor: onMoveCursor,
                                onCursorModeStart: onCursorModeStart,
                                onCursorModeEnd: onCursorModeEnd,
                                onShiftTap: handleShiftTap
                            )
                            // 击键间跳过重绘：KeyboardRowsView 已 Equatable，== 为真时整棵键位树不重建
                            .equatable()
                        }
                    }
                    .frame (height: bodyHeight)
                }
            }
            .frame (width: geo.size.width, height: geo.size.height, alignment: .top)
            .overlay (alignment: .top) { toastView }
            .onChange (of: runtime.inputBuffer) { buf in
                if buf.isEmpty { withAnimation (.easeInOut (duration: KeyboardAnimation.transitionDuration)) { isExpanded = false } }
            }
        }
        // 定高 + 底衬：GeometryReader 被 totalHeight 定死后不再贪婪，UIHostingController 能报出确定的
        // intrinsic 高度自驱动键盘高度；底衬铺在这块「定高内容」上（而非 UIKit inputView / 宿主），
        // 内容高度恒为 totalHeight、背景只填满键盘区，转场即使 inputView 被系统瞬时撑大，内容之外仍
        // 透明透出宿主 App，不会像 opaque 铺 inputView 那样整屏涂 board 色一闪。半透明度与原 UIKit
        // 底色同源（backgroundOpacity），候选栏 + 键盘体 + 底部安全区留白一并被这层背景铺满。
        .frame(height: totalHeight)
        .background(KeyboardTheme.background(appearance).opacity(appearance.backgroundOpacity))
        // 转场瞬态宿主被系统从整屏 844 逐帧收到稳态时，让这块定高内容贴 inputView 底而非居中：
        // 外层贪婪撑满宿主、内容按 .bottom 对齐，键盘背景带就落在屏幕底部（键盘本该在的位置）不悬到
        // 中上部。稳态宿主高 == totalHeight，贴底即填满、无副作用；贪婪层的 ideal 高度仍是里层定高的
        // totalHeight，UIHostingController 的 intrinsicContentSize 不受影响，inputView 照旧被内容撑到
        // totalHeight（四边约束的 top 把这一高度回灌给 inputView，见 KeyboardViewController.mountKeyboard）。
        // 背景只铺在里层定高 frame 上（盖 totalHeight），贪婪层不带背景，转场时上方透明透出宿主 App。
        .frame(maxHeight: .infinity, alignment: .bottom)
        .onAppear {
            // 键盘出现时把持久化的键盘形态同步给 Runtime
            // （.pinyin26 时 setInputMode 会直接 return，原有键盘行为完全不变）
            runtime.setInputMode(keyboardMode)
        }
        // 形态变化时再同步一次，避免「屏幕上的键盘」与「解析用的规则」脱节
        // （.pinyin26 时 setInputMode 会直接 return，原有键盘行为完全不变）
        .onChange(of: keyboardMode) { mode in
            runtime.setInputMode(mode)
        }
        // Runtime 对账后可能把不合法的形态回落成 26 键（从小鹤双拼切到虎码时停在双拼就是这种）。
        // store 是全局的、@State 只在 mount 时读过一次，不监听就会「解析规则已回落、键盘体还是双拼」
        .onReceive(NotificationCenter.default.publisher(for: KeyboardModeStore.didChangeNotification)) { _ in
            syncKeyboardModeFromStore()
        }
        .ignoresSafeArea (.keyboard)
    }

    // MARK: - 键盘形态路由（小鹤双拼 / 副键盘）

    /// 候选栏：两种键盘形态共用原有 CandidateBarView
    /// —— 小鹤双拼的「横向滑动 + 展开候选面板」与 26 键是同一个组件、同一条数据源，
    ///    行为与效果天然一致（展开后的网格面板见 CandidateExpandedPanel）
    /// —— 两端槽位（logo / 主动收起 / 展开列表）的尺寸引用字母键边长，由 metrics 传入
    @ViewBuilder
    private func candidateBar(candidateHeight: CGFloat, metrics: KeyboardMetrics) -> some View {
        CandidateBarView(
            candidates: runtime.candidates,
            inputBuffer: runtime.inputBuffer,
            isExpanded: $isExpanded,
            onSelect: { candidate in
                let text = runtime.selectCandidate(candidate)
                onInsert(text)
                isExpanded = false
            },
            onEnterComposition: openComposition,
            letterKeySize: metrics.letterKeyWidth,
            hPad: metrics.hPad,
            keySpacing: metrics.keySpacing,
            onDismissKeyboard: onDismiss,
            onOpenLogoPanel: openLogoPanel,
            barShortcuts: barShortcuts,
            shortcutOn: isShortcutOn,
            onShortcut: handleShortcut
        )
        .frame(height: candidateHeight)
    }

    /// 打开快捷面板：与候选展开面板互斥，同时只覆盖键盘区一次
    private func openLogoPanel() {
        withAnimation(.easeInOut(duration: KeyboardAnimation.transitionDuration)) {
            isExpanded = false
            isLogoPanel = true
        }
    }

    private func closeLogoPanel() {
        withAnimation(.easeInOut(duration: KeyboardAnimation.transitionDuration)) {
            isLogoPanel = false
        }
    }

    /// 切换键盘形态：丢弃未上屏编码，避免把上一种键盘的编码带到新键盘
    private func switchKeyboardMode(_ mode: KeyboardMode) {
        guard mode != keyboardMode else { return }
        // 面板里已经不列当前方案撑不起的形态，这里是防其它入口绕过的双保险：
        // 虎码配双拼键盘敲什么都是空候选，宁可不动也不能把用户送进死胡同
        guard runtime.availableKeyboardModes.contains(mode) else {
            showToast("「\(activeSchemeName)」不支持\(mode.displayName)")
            return
        }
        runtime.setInputMode(mode)
        keyboardMode = mode
        KeyboardModeStore.shared.mode = mode
        withAnimation(.easeInOut(duration: KeyboardAnimation.transitionDuration)) { isExpanded = false }
        showingNumbers = false
        isShifted = false
    }

    /// 把持久化的键盘形态同步回视图；被 Runtime 降级时补一句气泡，告诉用户键盘为何变了
    private func syncKeyboardModeFromStore() {
        let stored = KeyboardModeStore.shared.mode
        guard stored != keyboardMode else { return }
        let previous = keyboardMode
        keyboardMode = stored
        // 手动切换时 @State 已先写好，走不到这里；能进来就是被对账回落的
        if stored == .pinyin26 {
            showToast("「\(activeSchemeName)」不支持\(previous.displayName)，已切回全拼 26 键")
        }
    }

    /// 当前激活方案的显示名（气泡文案用）；取不到时退回 id
    private var activeSchemeName: String {
        let id = runtime.settings.activeSchemeId
        return runtime.installedSchemes.first { $0.id == id }?.manifest.name ?? id
    }

    /// 标点 / 符号直接上屏：先把未决编码收尾，避免残留未决状态
    /// 标点是「接着往下写」，按输入法惯例把当前首候选上屏（nihao 上屏为「你好，」）；
    ///    回车键的「字符上屏」是另一回事，见 commitPendingInput
    private func insertLiteral(_ text: String) {
        if !runtime.inputBuffer.isEmpty,
           let first = runtime.candidates.first(where: { !$0.candidate.isPrediction }) {
            onInsert(runtime.selectCandidate(first, explicit: false))
        } else {
            commitPendingInput()
        }
        onInsert(text)
    }

    /// 字符上屏（回车键）
    /// 两种键盘统一：上屏输入框里显示的那串字符，不选候选、不参与预测学习。
    /// - 26 键：就是敲进去的字母
    /// - 小鹤双拼：展开还原后的拼音（nihc 对应 nihao），而不是双拼码
    private func commitPendingInput() {
        guard !runtime.inputBuffer.isEmpty else { return }
        onInsert(runtime.commitRawInput())
    }

    // MARK: - 按键处理

    /// 敲键反馈：读声音 / 震动两个开关播一下点击音 + 震一下。所有产出字符的键
    /// （字母 / 数字 / 符号）与空格 / 退格 / 回车都走这里，与系统输入法「每次按键都响」一致。
    /// 只读两个布尔开关、命中才发声 / 震动，关掉时近乎零成本，不拖累击键热路径。
    private func playKeyFeedback() {
        KeyFeedback.play(sound: runtime.settings.keySoundEnabled,
                         haptic: runtime.settings.keyHapticEnabled)
    }

    private func handleKey(_ char: String) {
        playKeyFeedback()
        // 先快照大写态：临时大写敲完这一个字母就回落，但本次落点仍按大写处理
        let shifted = isShifted
        let output = shifted ? char.uppercased() : char
        // 锁定大写期间不回落；临时大写只生效一个字母（与原行为一致）
        if shifted && !isCapsLocked { isShifted = false }
        // 英文模式：纯字母直上屏，不进拼音缓冲区、不查词库
        guard !isEnglishActive else { onInsert(output); return }
        // 中文模式的大写态（临时 shift 或双击锁定）：大写字母同样直接上屏，不进拼音缓冲区。
        // 拼音编码不含大写字母，塞进缓冲区只会污染候选；直接上屏也与主流中文输入法
        // 「shift 敲行内大写字母」的手感一致。此刻若有未决拼音，走 insertLiteral 先按既有
        // 惯例收尾（首候选 / 原样）再上屏，避免运行时缓冲区与宿主 markedText 状态错位。
        if shifted {
            insertLiteral(output)
            return
        }
        runtime.appendInput(output, mode: keyboardMode)
    }

    /// Shift 点击：单击临时大写、双击锁定、锁定后单击解锁（主流键盘的通用手感）
    private func handleShiftTap() {
        let now = Date()
        let isDoubleTap = now.timeIntervalSince(lastShiftTap) <= ShiftKeyConfig.doubleTapLockInterval
        lastShiftTap = now
        if isDoubleTap {
            isCapsLocked = true
            isShifted = true
        } else if isCapsLocked {
            isCapsLocked = false
            isShifted = false
        } else {
            isShifted.toggle()
        }
    }

    private func handleBackspace() {
        playKeyFeedback()
        if isEnglishActive || runtime.inputBuffer.isEmpty {
            onBackspace()
        } else {
            runtime.deleteLastInput(mode: keyboardMode)
        }
    }

    private func handleSpace() {
        playKeyFeedback()
        guard !isEnglishActive else { onInsert(" "); return }
        guard !runtime.inputBuffer.isEmpty else {
            onInsert(" ")
            return
        }
        if let first = runtime.candidates.first {
            onInsert(runtime.selectCandidate(first, explicit: false))
        } else if runtime.isIdentityDecoding {
            // 恒等直通（26 键，以及双拼方案配小鹤双拼键盘）：无候选时把编码原样上屏
            onInsert(runtime.commitRawInput())
        } else {
            // 小鹤双拼键盘配全拼词库：无候选说明编码非法或词库无对应词条，
            // 丢弃编码，不把双拼码直接上屏
            runtime.clearInput()
        }
    }

    private func handleReturn() {
        playKeyFeedback()
        if isEnglishActive {
            onReturn()
        } else if !runtime.inputBuffer.isEmpty {
            commitPendingInput()
        } else {
            onReturn()
        }
    }

    /// 中 / 英 切换：持久化 + 丢弃未上屏编码，避免两种模式的残留互相污染
    private func handleToggleLanguage() {
        isEnglish.toggle()
        EnglishModeStore.shared.isEnglish = isEnglish
        runtime.clearInput()
        isShifted = false
        isCapsLocked = false
        withAnimation(.easeInOut(duration: KeyboardAnimation.transitionDuration)) { isExpanded = false }
    }

    // MARK: - 候选栏空态快捷功能条（响应 + 状态）

    /// 候选栏空态中段渲染的快捷功能：每次重绘都从 Store 读，主 App 改完配置键盘立即跟上
    private var barShortcuts: [CandidateBarShortcut] { CandidateBarShortcutStore.shared.shortcuts }

    /// 某个快捷功能当前是否为「开」（用于候选栏着色）。
    /// 口径与 CandidateBarShortcut.reflectsState 一致：开关型报自己的开关，
    /// 剪贴板虽然点下去是开面板（不是开关），颜色仍跟着「记录剪贴板」开关。
    private func isShortcutOn(_ shortcut: CandidateBarShortcut) -> Bool {
        switch shortcut {
        case .clipboardHistory:  return ClipboardSettingsStore.shared.isEnabled
        case .numberKeyboard:    return showingNumbers
        case .toggleEnglish:     return isEnglishActive
        case .toggleAnnotation:  return runtime.settings.showAnnotation
        case .togglePrediction:  return runtime.settings.showPrediction
        case .toggleDynamicFreq: return runtime.settings.dynamicFreqEnabled
        case .theme, .keyboardMode, .scheme, .clearInput:
            return false
        }
    }

    /// 点击候选栏快捷功能：映射到既有的 handler / state，不新造一套逻辑。
    /// 开关型 / 动作型功能统一补一句执行结果 toast，让用户确认真的触发了背后的逻辑；
    /// 打开面板（剪贴板历史 / 快捷面板）本身就是明确反馈，不再叠加 toast。
    private func handleShortcut(_ shortcut: CandidateBarShortcut) {
        switch shortcut {
        case .clipboardHistory:
            // 图标颜色跟「记录剪贴板」开关走，但点击语义是打开历史面板：
            // 开关本身在快捷面板分区四里操作，不把候选栏变成第二颗开关
            openClipboardPanel()
        case .numberKeyboard:
            showingNumbers.toggle()
            showToast(showingNumbers ? "已切换到数字符号键盘" : "已返回字母键盘")
        case .toggleEnglish:
            handleToggleLanguage()
            showToast(isEnglishActive ? "已切换到英文输入" : "已切换到中文输入")
        case .toggleAnnotation:
            updateSettings { $0.showAnnotation.toggle() }
            showToast(stateText("候选注释", runtime.settings.showAnnotation))
        case .togglePrediction:
            updateSettings { $0.showPrediction.toggle() }
            showToast(stateText("智能预测", runtime.settings.showPrediction))
        case .toggleDynamicFreq:
            updateSettings { $0.dynamicFreqEnabled.toggle() }
            showToast(stateText("动态调频", runtime.settings.dynamicFreqEnabled))
        case .theme:
            cycleTheme()
            showToast("主题：\(themeName(runtime.settings.keyboardAppearance.theme))")
        case .keyboardMode, .scheme:
            openLogoPanel()
        case .clearInput:
            let hadInput = !runtime.inputBuffer.isEmpty
            runtime.clearInput()
            showToast(hadInput ? "已清空输入" : "输入框已为空")
        }
    }

    // MARK: - 执行结果 toast（动作型 / 开关型按钮点击后的统一反馈）

    /// 顶部短暂提示：显示一小段时间后自动消失，让用户确认动作已真正执行
    private func showToast(_ text: String) {
        withAnimation(.easeInOut(duration: KeyboardAnimation.transitionDuration)) {
            toastText = text
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + ToastStyle.displayDuration) {
            // 仅当仍是同一条提示时才清除，避免快速连点把新提示提前抹掉
            if toastText == text {
                withAnimation(.easeInOut(duration: KeyboardAnimation.transitionDuration)) {
                    toastText = nil
                }
            }
        }
    }

    /// 开关型功能的统一话术：「名称：已开启 / 已关闭」
    private func stateText(_ name: String, _ isOn: Bool,
                           on: String = "已开启", off: String = "已关闭") -> String {
        "\(name)：\(isOn ? on : off)"
    }

    private func themeName(_ mode: ThemeMode) -> String {
        switch mode {
        case .light:        return "浅色"
        case .dark:         return "深色"
        case .followSystem: return "跟随系统"
        }
    }

    @ViewBuilder
    private var toastView: some View {
        if let text = toastText {
            Text(text)
                .font(.system(size: ToastStyle.fontSize, weight: .medium))
                .foregroundColor(ToastStyle.foreground)
                .padding(.horizontal, ToastStyle.horizontalPadding)
                .padding(.vertical, ToastStyle.verticalPadding)
                .background(ToastStyle.background)
                .cornerRadius(ToastStyle.cornerRadius)
                .padding(.top, ToastStyle.topOffset)
                .transition(.opacity)
                .accessibilityIdentifier("keyboardToast")
        }
    }

    /// 改一处设置并落盘 + 广播：键盘立即重绘，主 App 下次读取也是新值（与 QuickPanelView 同一链路）
    private func updateSettings(_ mutate: (inout UserSettings) -> Void) {
        var s = runtime.settings
        mutate(&s)
        runtime.updateSettings(s)
    }

    /// 主题循环：浅、深、跟随系统，再回到浅
    private func cycleTheme() {
        updateSettings { s in
            switch s.keyboardAppearance.theme {
            case .light:        s.keyboardAppearance.theme = .dark
            case .dark:         s.keyboardAppearance.theme = .followSystem
            case .followSystem: s.keyboardAppearance.theme = .light
            }
        }
    }

    /// 打开剪贴板历史面板：与快捷面板、候选展开面板互斥
    private func openClipboardPanel() {
        withAnimation(.easeInOut(duration: KeyboardAnimation.transitionDuration)) {
            isExpanded = false
            isLogoPanel = false
            isClipboardPanel = true
        }
    }

    private func closeClipboardPanel() {
        withAnimation(.easeInOut(duration: KeyboardAnimation.transitionDuration)) {
            isClipboardPanel = false
        }
    }

    /// 打开手动组句面板：先让 runtime 快照当前展开码进入组句态，成功才开面板（与其它面板互斥）。
    /// 进入失败（编码展不开 / 无激活方案）时不动面板，给一句气泡告知。
    private func openComposition() {
        guard runtime.enterComposition(mode: keyboardMode) else {
            showToast("当前编码无法组句")
            return
        }
        withAnimation(.easeInOut(duration: KeyboardAnimation.transitionDuration)) {
            isExpanded = false
            isLogoPanel = false
            isClipboardPanel = false
            isComposing = true
        }
    }

    /// 关闭组句面板（取消）：非破坏性退出组句态，inputBuffer 与常规候选原样保留
    private func closeComposition() {
        runtime.exitComposition()
        withAnimation(.easeInOut(duration: KeyboardAnimation.transitionDuration)) {
            isComposing = false
        }
    }
}

// 键盘几何（KeyboardMetrics）与主题（KeyboardTheme）已下沉到
// Shared/Models/KeyboardMetrics.swift 与 Shared/Models/KeyboardStyle.swift，
// 主 App 设置页预览与真键盘共用同一份推导。

// MARK: - 快捷面板
//
// 点候选栏左侧的 logo 展开，覆盖「候选栏 + 键盘体」整块区域，
// 形态与 CandidateExpandedPanel 一致：上方可滚内容 + 底部操作栏 + 下拉收起。
//
// 目前两个分区：切输入方案 / 切键盘形态（后续可继续加分区，不必改主视图路由）。
// 尺寸全部以「字母键边长」为基准按比例推导（见 QuickPanelStyle），不写死点数。

struct QuickPanelView: View {

    /// 设置读写与主 App 同源：面板里的开关直接改 runtime.settings 并落盘广播
    @EnvironmentObject private var runtime: IMERuntime

    /// 字母键边长：面板里所有尺寸（选项高度 / 字号 / 间距）都由它推导
    let letterKeySize: CGFloat
    let appearance: KeyboardAppearanceSettings
    /// 底部操作栏高度：由调用方传 candidateH 乘 0.85，与候选展开面板同源
    let bottomBarHeight: CGFloat
    let schemes: [InstalledScheme]
    let activeSchemeId: String
    let currentMode: KeyboardMode
    let onSelectScheme: (String) -> Void
    let onSelectKeyboard: (KeyboardMode) -> Void
    let onDismissKeyboard: () -> Void
    /// 打开剪贴板历史面板（关快捷面板、开历史面板）
    let onOpenClipboard: () -> Void
    let onClose: () -> Void

    /// 当前翻页停留的分区序号（`sectionIDs` 的下标），底部上下翻页键据此滚动
    @State private var pageSection = 0

    /// 当前主方案撑得起的键盘形态（判定规则在 SchemeCapability，运行时只给结果）
    private var availableModes: [KeyboardMode] { runtime.availableKeyboardModes }

    /// 分区 id（候选栏快捷条 / 输入方案 / 键盘 / 快捷设置 / 剪贴板 / 主题）；
    /// 键盘分区始终渲染（不可用的灰显），翻页始终走六个分区
    private var sectionIDs: [Int] { [0, 1, 2, 3, 4, 5] }

    var body: some View {
        let textColor = KeyboardTheme.keyText(appearance)
        let hSpacing = letterKeySize * QuickPanelStyle.itemHSpacingRatio
        let vSpacing = letterKeySize * QuickPanelStyle.itemVSpacingRatio

        ScrollViewReader { proxy in
        VStack(spacing: 0) {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading,
                       spacing: letterKeySize * QuickPanelStyle.sectionGroupSpacingRatio) {

                    // 分区〇：候选栏快捷条（候选栏空态「+」入口直达这里勾选添加）
                    // 只列「一键即达」的功能（isBarEligible）；键盘形态 / 输入方案这类
                    // 二级入口不收进快捷栏，收录资格见 CandidateBarShortcut.isBarEligible 注释
                    sectionTitle("候选栏快捷条").id(0)
                    WrapLayout(hSpacing: hSpacing, vSpacing: vSpacing) {
                        ForEach(CandidateBarShortcut.allCases.filter(\.isBarEligible)) { shortcut in
                            panelItem(icon: shortcut.symbolName,
                                      iconText: shortcut.iconText,
                                      title: shortcut.title,
                                      isSelected: CandidateBarShortcutStore.shared.orderedIDs.contains(shortcut.id),
                                      textColor: textColor) {
                                toggleBarShortcut(shortcut)
                            }
                        }
                    }

                    // 分区一：快速切换输入方案
                    sectionTitle("输入方案").id(1)
                    WrapLayout(hSpacing: hSpacing, vSpacing: vSpacing) {
                        if schemes.isEmpty {
                            emptyHint("尚未安装方案，请到「聿·输入法」主 App 里安装")
                        } else {
                            ForEach(schemes) { scheme in
                                panelItem(icon: "books.vertical",
                                          title: scheme.manifest.name,
                                          isSelected: scheme.id == activeSchemeId,
                                          textColor: textColor) {
                                    onSelectScheme(scheme.id)
                                }
                            }
                        }
                    }

                    // 分区二：键盘形态（始终全部列出，不可用的灰显 + 点击弹 toast 提示原因）
                    // 主方案决定可用形态，参与方不扩展；形码/音形码永远只有 26 键可用
                    sectionTitle("键盘").id(2)
                    WrapLayout(hSpacing: hSpacing, vSpacing: vSpacing) {
                        ForEach(KeyboardMode.allCases) { mode in
                            let isAvailable = availableModes.contains(mode)
                            panelItem(icon: mode.symbolName,
                                      title: mode.displayName,
                                      isSelected: mode == currentMode,
                                      isDisabled: !isAvailable,
                                      textColor: textColor) {
                                onSelectKeyboard(mode)
                            }
                        }
                    }

                    // 分区三：常用启闭开关（与主 App「混打 / 键盘外观」设置同一份数据，改完立即生效）
                    // 声音 / 震动两项是键盘侧手感的开关，只在本面板暴露（存 UserSettings 同一份数据，主 App 不另设页）
                    sectionTitle("快捷设置").id(3)
                    WrapLayout(hSpacing: hSpacing, vSpacing: vSpacing) {
                        panelItem(icon: "book",
                                  title: "候选注释",
                                  isSelected: runtime.settings.showAnnotation,
                                  textColor: textColor) {
                            updateSettings { $0.showAnnotation.toggle() }
                        }
                        panelItem(icon: "wand.and.stars",
                                  title: "智能预测",
                                  isSelected: runtime.settings.showPrediction,
                                  textColor: textColor) {
                            updateSettings { $0.showPrediction.toggle() }
                        }
                        panelItem(icon: "face.smiling",
                                  title: "emoji 候选",
                                  isSelected: runtime.settings.showEmoji,
                                  textColor: textColor) {
                            updateSettings { $0.showEmoji.toggle() }
                        }
                        panelItem(icon: "arrow.up.forward",
                                  title: "动态调频",
                                  isSelected: runtime.settings.dynamicFreqEnabled,
                                  textColor: textColor) {
                            updateSettings { $0.dynamicFreqEnabled.toggle() }
                        }
                        panelItem(icon: "speaker.wave.2",
                                  title: "按键声音",
                                  isSelected: runtime.settings.keySoundEnabled,
                                  textColor: textColor) {
                            updateSettings { $0.keySoundEnabled.toggle() }
                        }
                        panelItem(icon: "iphone.radiowaves.left.and.right",
                                  title: "按键震动",
                                  isSelected: runtime.settings.keyHapticEnabled,
                                  textColor: textColor) {
                            updateSettings { $0.keyHapticEnabled.toggle() }
                        }
                    }

                    // 分区四：剪贴板历史（记录开关 + 查看历史，与主 App 词典里的剪贴板历史同一份数据）
                    sectionTitle("剪贴板").id(4)
                    WrapLayout(hSpacing: hSpacing, vSpacing: vSpacing) {
                        panelItem(icon: "doc.on.clipboard",
                                  title: "记录剪贴板",
                                  isSelected: ClipboardSettingsStore.shared.isEnabled,
                                  textColor: textColor) {
                            toggleClipboardRecording()
                        }
                        panelItem(icon: "list.bullet",
                                  title: "查看历史",
                                  isSelected: false,
                                  textColor: textColor) {
                            onOpenClipboard()
                        }
                    }

                    // 分区五：主题（与主 App 键盘外观里的主题同一份数据）
                    sectionTitle("主题").id(5)
                    WrapLayout(hSpacing: hSpacing, vSpacing: vSpacing) {
                        panelItem(icon: "sun.max",
                                  title: "浅色",
                                  isSelected: appearance.theme == .light,
                                  textColor: textColor) {
                            updateSettings { $0.keyboardAppearance.theme = .light }
                        }
                        panelItem(icon: "moon",
                                  title: "深色",
                                  isSelected: appearance.theme == .dark,
                                  textColor: textColor) {
                            updateSettings { $0.keyboardAppearance.theme = .dark }
                        }
                        panelItem(icon: "circle.lefthalf.filled",
                                  title: "跟随系统",
                                  isSelected: appearance.theme == .followSystem,
                                  textColor: textColor) {
                            updateSettings { $0.keyboardAppearance.theme = .followSystem }
                        }
                    }
                }
                .padding(.horizontal, letterKeySize * QuickPanelStyle.panelHorizontalPaddingRatio)
                .padding(.vertical, vSpacing)
            }

            // 底部操作栏与上方滚动内容之间补一条分隔线，与栏内翻页/返回键之间的
            // 竖直 Divider 同一观感（此前只有竖线、顶边无线）
            Divider()

            // 底部操作栏：上一页 / 下一页（真翻页，按分区滚动内容）；
            // 关闭面板改用下拉手势，收起键盘在关面板后由候选栏空态右端的收起键承担
            HStack(spacing: 0) {
                bottomBarItem("chevron.up",
                              identifier: "quickPanelPrevPage",
                              textColor: textColor) {
                    prevPage(proxy: proxy)
                }
                Divider()
                bottomBarItem("chevron.down",
                              identifier: "quickPanelNextPage",
                              textColor: textColor) {
                    nextPage(proxy: proxy)
                }
                Divider()
                // 返回主键盘：关闭覆盖面板，露出下面的候选栏 + 键盘体；
                // 用 arrow.uturn.backward（长杆带半圆回头的 U 形返回符号）：
                // 同栏的上下翻页键已是 chevron 系，再来一个 chevron 易误读成翻页
                bottomBarItem("arrow.uturn.backward",
                              identifier: "quickPanelClose",
                              textColor: textColor,
                              action: onClose)
            }
            .frame(height: bottomBarHeight)
            .background(KeyboardTheme.background(appearance))
        }
        }
        .background(KeyboardTheme.background(appearance))
        .accessibilityIdentifier("quickPanel")
        .gesture(
            DragGesture(minimumDistance: letterKeySize * QuickPanelStyle.dragMinDistanceRatio,
                        coordinateSpace: .local)
                .onEnded { value in
                    if value.translation.height > letterKeySize * QuickPanelStyle.dragDismissThresholdRatio {
                        onClose()
                    }
                }
        )
    }

    // MARK: - 翻页（底部上下翻页键）

    /// 上一页：滚到上一个分区顶部
    private func prevPage(proxy: ScrollViewProxy) {
        guard pageSection > 0 else { return }
        pageSection -= 1
        withAnimation { proxy.scrollTo(sectionIDs[pageSection], anchor: .top) }
    }

    /// 下一页：滚到下一个分区顶部
    private func nextPage(proxy: ScrollViewProxy) {
        guard pageSection < sectionIDs.count - 1 else { return }
        pageSection += 1
        withAnimation { proxy.scrollTo(sectionIDs[pageSection], anchor: .top) }
    }

    /// 勾选 / 取消勾选候选栏快捷功能（orderedIDs setter 自带 Darwin 广播，候选栏立即跟上）
    private func toggleBarShortcut(_ shortcut: CandidateBarShortcut) {
        var ids = CandidateBarShortcutStore.shared.orderedIDs
        if let idx = ids.firstIndex(of: shortcut.id) {
            ids.remove(at: idx)
        } else {
            ids.append(shortcut.id)
        }
        CandidateBarShortcutStore.shared.orderedIDs = ids
        // 勾选状态存在 Store 里（不在 UserSettings），SwiftUI 观察不到它的变化；
        // 与中/英键、剪贴板开关同一套路：重播一次 settings 触发重绘，芯片高亮才实时更新。
        // 此前这步靠每帧的设置重载顺带重绘，重载加磁盘指纹护栏后不再免费重绘，必须显式补上
        runtime.updateSettings(runtime.settings)
    }

    // MARK: - 设置读写（与主 App 同一条链路）

    /// 改一处设置并落盘 + 广播：键盘侧立即重绘，主 App 下次读取也是新值
    private func updateSettings(_ mutate: (inout UserSettings) -> Void) {
        var s = runtime.settings
        mutate(&s)
        runtime.updateSettings(s)
    }

    /// 剪贴板记录开关存在 ClipboardSettingsStore（不在 UserSettings 里），
    /// 改完再广播一次 settings 触发重绘，芯片的对勾才会立刻跟上
    private func toggleClipboardRecording() {
        ClipboardSettingsStore.shared.isEnabled = !ClipboardSettingsStore.shared.isEnabled
        runtime.updateSettings(runtime.settings)
    }

    // MARK: - 子视图

    @ViewBuilder
    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: letterKeySize * QuickPanelStyle.sectionTitleSizeRatio, weight: .medium))
            .foregroundColor(KeyboardTheme.keyText(appearance)
                .opacity(QuickPanelStyle.sectionTitleOpacity))
            .padding(.bottom, letterKeySize * QuickPanelStyle.sectionSpacingRatio * 0.2)
    }

    /// 一个选项：高度 = 字母键边长（与键盘上的按键同一尺寸基准）。
    /// iconText 非 nil 时用纯文字图标（如中/英的「En」），否则用 SF Symbol
    @ViewBuilder
    private func panelItem(icon: String,
                           iconText: String? = nil,
                           title: String,
                           isSelected: Bool,
                           isDisabled: Bool = false,
                           textColor: Color,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: letterKeySize * QuickPanelStyle.itemHSpacingRatio * 0.5) {
                if let iconText {
                    Text(iconText)
                        .font(.system(size: letterKeySize * QuickPanelStyle.itemIconSizeRatio,
                                      weight: .semibold))
                } else {
                    Image(systemName: icon)
                        .font(.system(size: letterKeySize * QuickPanelStyle.itemIconSizeRatio))
                }
                Text(title)
                    .font(.system(size: letterKeySize * QuickPanelStyle.itemTextSizeRatio))
                    .lineLimit(1)
            }
            .foregroundColor(isSelected && !isDisabled
                             ? KeyboardTheme.primaryColor(appearance) : textColor)
            .padding(.horizontal, letterKeySize * QuickPanelStyle.itemHorizontalPaddingRatio)
            .frame(height: letterKeySize)
            .background(isSelected && !isDisabled
                        ? KeyboardTheme.primaryColor(appearance)
                            .opacity(QuickPanelStyle.selectedItemFillOpacity)
                        : KeyboardTheme.funcKeyFill(appearance))
            .cornerRadius(letterKeySize * QuickPanelStyle.itemCornerRatio)
            .opacity(isDisabled ? 0.35 : 1.0)
        }
        .buttonStyle(PressStyle())
        .accessibilityIdentifier("quickPanelItem-\(title)")
    }

    /// 底部操作栏的半区：整块可点（与候选展开面板的底部栏一致）
    @ViewBuilder
    private func bottomBarItem(_ icon: String,
                              identifier: String,
                              textColor: Color,
                              action: @escaping () -> Void) -> some View {
        VStack {
            Image(systemName: icon)
                .font(.system(size: bottomBarHeight * QuickPanelStyle.bottomBarIconSizeRatio,
                              weight: .semibold))
                .foregroundColor(textColor)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .accessibilityIdentifier(identifier)
    }

    @ViewBuilder
    private func emptyHint(_ text: String) -> some View {
        Text(text)
            .font(.system(size: letterKeySize * QuickPanelStyle.itemTextSizeRatio))
            .foregroundColor(KeyboardTheme.keyText(appearance)
                .opacity(QuickPanelStyle.sectionTitleOpacity))
            .frame(height: letterKeySize)
    }
}

