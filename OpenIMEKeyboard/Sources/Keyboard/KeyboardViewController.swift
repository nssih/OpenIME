import UIKit
import SwiftUI
import os
import OpenIMECore

public class KeyboardViewController: UIInputViewController {

    private var hostingController: UIHostingController<AnyView>?
    private let runtime = IMERuntime.shared
    /// mountKeyboard 挂的宿主四边拉伸约束（leading/trailing/top/bottom）：teardown 时必须成对
    /// deactivate，否则宿主视图被移除后它们悬空仍 active，快速切换反复 remount 会累积悬空约束污染布局
    private var hostEdgeConstraints: [NSLayoutConstraint] = []

    /// 进程内当前活跃的键盘 VC：池化宿主的回调经它路由到「这一次弹出」的 VC。
    /// 池化宿主跨 VC 共享、可被多次领养，闭包不能捕获某一代 VC 的 weak self（那代释放后回调空转），
    /// 故一律经这个静态弱引用转发到当前 VC。viewDidLoad / 重挂时置为 self，deinit 时若仍指向自己则清空。
    private static weak var currentController: KeyboardViewController?
    /// 池化的 SwiftUI 宿主：整棵键盘树一个进程只建一次，收起不销毁、下次弹出直接复用。
    /// 它不只是省内存 / 杜绝每弹一次泄漏——更是「预渲染」宿主：复用时只重设 rootView 触发 diff，
    /// view 帧与内容早已稳定，切换即时、紧贴底部、无灰闪。改成每 VC 新建私有宿主（v8）会引入
    /// SwiftUI 首帧渲染 / 布局瞬态：内容渲染前 host.view 露出底色（半屏灰闪）、host 帧在约束解算前
    /// momentarily 错位（键盘飞出屏幕）。故池化是 load-bearing 的，不能删。
    private static var pooledHost: UIHostingController<AnyView>?

    /// 键盘可见期的剪贴板轮询定时器：低频静默读 changeCount，覆盖「键盘一直开着时复制」
    private var clipboardPollTimer: Timer?
    /// 轮询间隔（秒）：读 changeCount 静默不弹提示，只有内容真变了才读一次（弹一次「已粘贴」）
    private static let clipboardPollInterval: TimeInterval = 1.0

    public override func viewDidLoad() {
        super.viewDidLoad()

        // 先给 inputView 一个初始宽度（对齐元书 / KeyboardKit 的 setupInitialWidth）：挂载时
        // view.window 尚为 nil、bounds.width 可能还是 0，SwiftUI 首帧按 0 宽布局会算出错误的键宽 /
        // 总高。用屏宽兜底规避首帧布局 bug；真宽到达后系统布局会覆盖它。
        view.frame.size.width = UIScreen.main.bounds.width

        // inputView 与宿主都保持透明：键盘底衬已移进 SwiftUI 定高内容里（见 IMEKeyboardView），
        // 只填满键盘区那 totalHeight 高度。转场时系统会把 inputView 瞬时撑到整屏 844，若像以前那样
        // 把不透明底衬铺在 inputView / 宿主上，这一整片会被涂成 board 色一闪（整屏屏闪）；保持透明
        // 则内容之外透出宿主 App，配合「内容定高自驱动、不与系统抢高度」彻底消除半屏灰闪。
        applyKeyboardBackground()

        // 禁用系统 QuickType 候选栏，防止盖住本 App 候选栏
        inputAssistantItem.leadingBarButtonGroups  = []
        inputAssistantItem.trailingBarButtonGroups = []

        // 幂等护栏：一个进程只完整初始化一次。键盘每次弹出都新建 KeyboardViewController
        // → viewDidLoad，若无条件 Task { await start() }，start() 里的 loadInstalledSchemes
        // 会把全部已装方案的词库 reader 重新 mmap 一遍，反复弹出（切几次键盘）内存单调累积，
        // 键盘扩展进程内存上限低，累积到阈值就被 jetsam 杀掉、iOS 回落上一个键盘（用户感知
        // 为「被顶掉」，系统里已删的百度键盘条目会作为陈旧回落项冒出来）。runtime 是常驻单例，
        // isReady 已置位说明本进程初始化过，直接复用；跨进程设置变更由下面的 Darwin 观察者
        // 与 viewWillAppear/didAppear 的 reloadSettingsFromDisk 兜住，不依赖重跑 start()。
        if !runtime.isReady {
            Task {
                await runtime.start()
            }
        }
        CJKFont.warmUp()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAutoSelect(_:)),
            name: .imeAutoSelectFired,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSettingsChanged),
            name: .imeSettingsChanged,
            object: nil
        )

        // 跨进程：监听主 App 保存 settings 的 Darwin 通知
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            { _, observer, _, _, _ in
                guard let observer else { return }
                let vc = Unmanaged<KeyboardViewController>.fromOpaque(observer).takeUnretainedValue()
                DispatchQueue.main.async { [weak vc] in
                    vc?.reloadSettingsFromDisk()
                }
            },
            AppGroupContainer.settingsChangedNotification as CFString,
            nil,
            .deliverImmediately
        )

        // 跨进程：监听主 App「清除调频记录」的 Darwin 通知。存活的键盘扩展进程内存里
        // 还握着旧活表，不弃表的话下一次收起 flush 会把用户刚清掉的数据写回盘（复活）；
        // 错过广播（被挂起）的场景由引擎的 App Group 标记层兜底（record/落盘前自检）
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            { _, observer, _, _, _ in
                guard let observer else { return }
                let vc = Unmanaged<KeyboardViewController>.fromOpaque(observer).takeUnretainedValue()
                DispatchQueue.main.async { [weak vc] in
                    vc?.runtime.applyFrequencyClearNotice()
                }
            },
            FrequencyAdjustEngine.clearedNotificationName as CFString,
            nil,
            .deliverImmediately
        )

        // 池化宿主的回调经 currentController 路由：本 VC 即将 mount / 领养宿主，先登记为当前活跃 VC
        Self.currentController = self
        mountKeyboard()

        // 键盘高度改为「内容自驱动」（对齐元书 / KeyboardKit）：VC 侧不再压任何 inputView 高度约束，
        // 键盘高度 = SwiftUI 内容的 intrinsicContentSize（见 IMEKeyboardView 用 totalHeight 定高）。
        // 此前那条 999 优先级 view.heightAnchor 约束会与系统 UIInputSetHostView 转场布局硬碰，把
        // inputView 撑到整屏 844、底部内容上方留出透明缝透出系统灰背板 = 半屏灰闪的根源。安全区
        //（Home 条）真值、旋转、改布局设置会改变内容总高，靠下面 refreshKeyboardContent() 在
        // viewSafeAreaInsetsDidChange / viewWillTransition / reloadSettings 三处离散触发重算，
        // 绝不在布局 pass / 击键里重压。此刻 view.window 尚为 nil、homeIndicatorHeight 取 0 作基线。
        refreshKeyboardContent()

        // 监听输入缓冲区变化，同步内嵌编码到宿主输入框
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInputBufferChanged),
            name: .imeInputBufferChanged,
            object: nil
        )
    }

    // window 在 viewWillAppear 后才可用，在这里初始化高度约束
    public override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // 与 viewWillDisappear 的 teardownHostingController 对称：iOS 在部分输入法切换场景下
        // 会复用同一个 VC 实例（消失后未 dealloc 又再出现），此时宿主已被拆掉、hostingController
        // 为 nil，不重挂就会键盘空白。全新 VC 走 viewDidLoad 已挂好，这里的 guard 不会重复挂。
        if hostingController == nil {
            Self.currentController = self
            mountKeyboard()
        }
        reloadSettingsFromDisk()
        // 抓取一次：覆盖「键盘弹出前用户在别处复制」的内容（changeCount 变了才真读，弹一次提示）
        ClipboardCapture.captureIfNeeded()
        // 可见期低频轮询：覆盖「键盘一直开着时复制」的场景
        startClipboardPolling()
    }

    public override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // 键盘收起 / 切到别的页面：丢弃未上屏的半截编码，并清掉宿主里的内嵌编码 markedText。
        // IMERuntime 是常驻单例，缓冲区不清会跨「收起再弹出」存活，导致候选栏显示上一次的
        // 陈旧候选、而宿主已无对应 markedText（状态错位）；同时避免半截拼音被宿主当正文留下。
        runtime.clearInput()
        textDocumentProxy.setMarkedText("", selectedRange: NSRange(location: 0, length: 0))
        // 键盘收起时将预测数据写入磁盘
        runtime.flushPrediction()
        // 拼音动态调频学习数据同步落盘（与预测同一条异步补写路径，不卡收起动画）
        runtime.flushFrequency()
        // 键盘不可见时不该再读剪贴板，停止轮询
        stopClipboardPolling()
        // 收起即确定性拆掉 SwiftUI 宿主，不等 VC dealloc（真机日志实锤的每弹一次泄漏 ~2.5MB 根因）
        teardownHostingController()
    }

    /// 键盘收起时确定性 dismantling SwiftUI 宿主：断开对常驻单例 runtime 的 @EnvironmentObject 订阅。
    /// 真机日志实锤：每次弹出都新建一个 UIHostingController，其视图树订阅了 IMERuntime.shared 的
    /// objectWillChange；只靠 VC 释放来回收时，iOS 未必及时 dealloc 已收起的键盘 VC，宿主与整棵
    /// SwiftUI 树就被单例的观察者留住 —— 每弹一次泄漏约 2.5MB（纯切换、零打字也单调上涨），
    /// 累积到扩展内存上限被 jetsam 杀掉即用户感知的「被顶掉」。这里在 willDisappear（一定会来）
    /// 手动 willMove/removeFromSuperview/removeFromParent 并置 nil，把回收从「靠系统 dealloc」
    /// 变成「收起即释放」，下次弹出本来就是全新 VC，不受影响。
    private func teardownHostingController() {
        guard let hc = hostingController else { return }
        // 自己那套四边拉伸约束无条件失活：本就是本 VC 建的对象，留着会悬空残留、快速切换累积后污染 Auto Layout
        NSLayoutConstraint.deactivate(hostEdgeConstraints)
        hostEdgeConstraints.removeAll()
        // 归属守卫：池化宿主是跨 VC 共享的静态对象，本 VC 的 willDisappear 姗姗来时，宿主可能
        // 已被「这一次弹出」的新 VC 领养（superview 已是新 VC 的 view）。此时若无条件
        // removeFromSuperview，会把宿主从正在显示的新 VC 上硬摘走 → 新键盘沦为永久灰块（真机实锤）。
        // 故只在宿主仍挂在本 VC 的 view 上（确属本 VC 领养）时才摘除放手，让它回到空闲池待下次复用；
        // 否则只断开本 VC 对它的引用（置 nil），不碰已被他人领养的宿主。
        if hc.view.superview === view {
            hc.willMove(toParent: nil)
            hc.view.removeFromSuperview()
            hc.removeFromParent()
        }
        hostingController = nil
    }

    deinit {
        // 本 VC 释放时，若它仍是池化宿主回调路由指向的「当前活跃 VC」，清空该引用：
        // 避免「旧 VC 释放晚于新 VC 登记」的极端时序下把新 VC 的登记误清（weak 也会自动置 nil，显式清理更稳）
        if Self.currentController === self {
            Self.currentController = nil
        }
        CFNotificationCenterRemoveObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            CFNotificationName(AppGroupContainer.settingsChangedNotification as CFString),
            nil
        )
        CFNotificationCenterRemoveObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            CFNotificationName(FrequencyAdjustEngine.clearedNotificationName as CFString),
            nil
        )
    }

    /// 系统内存告警：键盘扩展进程内存上限低，被系统杀掉后 iOS 会静默回落
    /// 系统键盘（用户感知为「被顶掉」，需手动切回）。主动减负降低被 jetsam
    /// 选中的概率：学习数据落盘 + 释放全部可重建缓存（见 IMERuntime.handleMemoryWarning）
    public override func didReceiveMemoryWarning() {
        runtime.handleMemoryWarning()
        // 内存告警时，若池化宿主当前空闲（本 VC 未持有 = 已收起放手），弃掉它释放整棵预渲染树；
        // 下次弹出会重建（届时是一次冷渲染，但内存压力下这是必要取舍）。仍被持有（键盘正显示）时不动。
        if hostingController == nil {
            Self.pooledHost = nil
        }
        super.didReceiveMemoryWarning()
    }

    // 高度不再在 viewWillLayoutSubviews 里重算 —— 每次布局 pass 重压高度正是「跟系统抢布局」的
    // 源头（切换转场时系统动画与本 App 的约束逐帧互掐，产生 844→尖峰→244 的屏闪，配 999 时累加暴涨）。
    // 改为只在下面两个离散真实事件上校正：安全区变化、旋转。

    /// 系统在这一步才给出真实 safe-area（viewDidLoad 时 window 还是 nil、只能取 0 作基线）。
    /// Home Indicator 高度到达后校正键盘总高，取代此前每帧重算去「等」安全区的做法。
    public override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        refreshKeyboardContent()
    }

    /// 旋转 / 分屏尺寸变化：新尺寸到达后重算键盘总高（宽度变了，键宽与总高都要跟着变）。
    /// 转场期间与完成后各校正一次；旋转通常也会触发 viewSafeAreaInsetsDidChange 双重兜底。
    public override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        coordinator.animate(alongsideTransition: { [weak self] _ in
            self?.refreshKeyboardContent()
        }, completion: { [weak self] _ in
            self?.refreshKeyboardContent()
        })
    }

    // 注：不再重写 textWillChange。它每次击键都触发，而打字不会改变磁盘上的设置；
    // 跨进程设置变更由 Darwin 观察者实时送达，每键 reloadSettingsFromDisk 只会白白增加击键延迟。

    // MARK: - 安全区

    // 键盘扩展 view 本身在安全区外，从 view.window 读 Home Indicator 高度
    private var homeIndicatorHeight: CGFloat {
        view.window?.safeAreaInsets.bottom ?? 0
    }

    // MARK: - 键盘高度（内容自驱动，不再压约束）

    /// 触发 SwiftUI 内容重算键盘高度：键盘高度 = 内容的 intrinsicContentSize（见 IMEKeyboardView
    /// 用 KeyboardMetrics.totalHeight 定高），VC 侧不再压任何 inputView 高度约束去和系统
    /// UIInputSetHostView 抢。安全区（Home 条）真值到达、旋转、用户改布局 / 外观设置时内容总高会变，
    /// 这里重设池化宿主的 rootView，让 IMEKeyboardView 用最新的 homeIndicatorHeight() 重算
    /// totalHeight、刷新 intrinsic 高度，键盘随之重新定高。重设 rootView 不丢 @State（同一
    /// IMEKeyboardView 类型与位置，SwiftUI 按值 diff）；只在离散事件上调，绝不在布局 pass / 击键里调。
    private func refreshKeyboardContent() {
        hostingController?.rootView = Self.makeKeyboardView()
    }

    // MARK: - 挂载 SwiftUI 键盘

    private func mountKeyboard() {
        // 回调一律经 currentController 路由到当前 VC：池化的树可能被多次领养，
        // 闭包不能捕获某一代 VC 的 weak self（那代释放后回调就空转）
        let hc: UIHostingController<AnyView>
        // 灰块真根因：键盘区连切 globe 时 iOS 几秒内建几十个 VC，若它们都去 addSubview 硬抢
        // 同一棵池化宿主，宿主在 VC 间反复搬移、位置约束被非归属者失活、Auto Layout 永不 settle、
        // host.frame 冻结掉出可见区（永久灰块）。修法：只在宿主真正空闲（superview==nil，即上一
        // 个领养它的 VC 已 teardown 放手）时才复用这棵预渲染的树；宿主仍被占用（快速连切、旧 VC
        // 尚未放手）时另建一棵独立树，绝不硬抢——既保住「正常顺序切换复用预渲染宿主 = 紧贴底部、
        // 无灰闪」，又杜绝争抢导致的永久灰块。
        if let pooled = Self.pooledHost, pooled.view.superview == nil {
            hc = pooled
            hc.rootView = Self.makeKeyboardView()
        } else {
            let built = UIHostingController(rootView: Self.makeKeyboardView())
            if Self.pooledHost == nil {
                Self.pooledHost = built
            }
            hc = built
        }
        hostingController = hc
        // 让 SwiftUI 内容把 intrinsicContentSize 翻译到宿主 view 上（iOS16+）：键盘高度靠内容自驱动，
        // 必须让 UIHostingController 上报 intrinsic 高度，inputView 才会被系统按内容高度定尺寸。
        if #available(iOS 16.0, *) {
            hc.sizingOptions = [.intrinsicContentSize]
        }
        // 宿主与 inputView 都保持透明：底衬背景已移进 SwiftUI 定高内容里（见 IMEKeyboardView），
        // 只填满键盘区那 totalHeight。转场即使 inputView 被系统瞬时撑大，内容之外仍透明透出宿主 App，
        // 不再有 UIKit 侧底色孤岛（opaque 铺 inputView 会整屏涂 board 色一闪）。
        hc.view.backgroundColor = .clear

        addChild(hc)
        view.addSubview(hc.view)
        hc.view.translatesAutoresizingMaskIntoConstraints = false
        // 宿主四边贴住 inputView（top+bottom+leading+trailing）。这条 top 约束是「把内容高度回灌给
        // inputView」的唯一通道，load-bearing：真机 diag 实锤，去掉 top 只留底锚定后，系统不再按内容
        // intrinsic 撑高 inputView，而是回落到默认 216，此时 intrinsic 237.33 的宿主底边贴住 inputView
        // 底、顶边溢到 y=-21.33，候选栏顶部被裁掉约一半（用户报「聿候选栏只显示一半、调键盘高低都没用」
        // 的根因；steady 日志：view=(0,0,390,216) host=(0,-21.33,390,237.33) intrinsic=237.33 home=0）。
        // 四边拉伸时这条 top+bottom 把内容的 237.33 传给 inputView，稳态宿主高 == inputView 高、正好填满，
        // 候选栏完整可见（历史 steady 237.33、origin y=0 佐证）。
        // 转场瞬态（系统把 inputView 从整屏 844 逐帧收到稳态）宿主会被撑到 844，此时让「定高内容贴底」
        // 而非居中，即可避免键盘背景带悬到屏幕中上部——贴底放在 SwiftUI 侧做（见 IMEKeyboardView body
        // 末尾的 .frame(maxHeight:.infinity, alignment:.bottom)），不改这里的约束、不碰系统对 inputView
        // 高度的接管（零动画干预）。
        let edges = [
            hc.view.topAnchor.constraint(equalTo: view.topAnchor),
            hc.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hc.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hc.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ]
        NSLayoutConstraint.activate(edges)
        hostEdgeConstraints = edges
        hc.didMove(toParent: self)
    }

    /// 构造键盘 SwiftUI 视图值（不含 host）：回调一律经 static weak currentController 路由到
    /// 「当前这一次弹出」的 VC——池化宿主跨 VC 共享、会被多次领养，闭包若捕获某一代 VC 的 weak
    /// self，那代释放后回调就空转（点了没反应）。故这里不捕获实例，改走 currentController。
    private static func makeKeyboardView() -> AnyView {
        // safeAreaBottom 在 mountKeyboard 时 window 可能还是 nil，
        // 传 0 占位，viewWillAppear 后高度约束会更新，
        // SwiftUI 侧通过 @State 重新计算布局
        AnyView(
            IMEKeyboardView(
                onInsert:      { text in KeyboardViewController.currentController?.commitText(text) },
                onBackspace:   {
                    guard let vc = KeyboardViewController.currentController else { return }
                    vc.textDocumentProxy.setMarkedText("", selectedRange: NSRange(location: 0, length: 0))
                    vc.textDocumentProxy.deleteBackward()
                },
                onReturn:      { KeyboardViewController.currentController?.commitText("\n") },
                onDismiss:     {
                    guard let vc = KeyboardViewController.currentController else { return }
                    // 先清内嵌编码的 markedText，避免残留 marked 状态干扰下次激活
                    vc.textDocumentProxy.setMarkedText("", selectedRange: NSRange(location: 0, length: 0))
                    // 异步 dismiss：避免在 SwiftUI 手势事务中同步 dismiss 导致响应链状态错乱、
                    // 下次点输入框呼不出键盘
                    DispatchQueue.main.async { KeyboardViewController.currentController?.dismissKeyboard() }
                },
                onNextKeyboard:{ KeyboardViewController.currentController?.advanceToNextInputMode() },
                onMoveCursor:  { offset in
                    // 只动宿主光标。内嵌编码的 markedText 已在进入光标模式时摘掉
                    //（onCursorModeStart）、松手时重挂（onCursorModeEnd）；
                    // 每步重挂会把光标拉回 marked 末尾，表现为「有编码时光标不滑动」
                    KeyboardViewController.currentController?.textDocumentProxy.adjustTextPosition(byCharacterOffset: offset)
                },
                onCursorModeStart: { KeyboardViewController.currentController?.detachMarkedForCursorMode() },
                onCursorModeEnd:   { KeyboardViewController.currentController?.rehangMarkedAfterCursorMode() },
                homeIndicatorHeight: { KeyboardViewController.currentController?.homeIndicatorHeight ?? 0 }
            )
            .environmentObject(IMERuntime.shared)
        )
    }

    // MARK: - 通知

    @objc private func handleAutoSelect(_ notification: Notification) {
        guard let text = notification.userInfo?["text"] as? String else { return }
        textDocumentProxy.setMarkedText("", selectedRange: NSRange(location: 0, length: 0))
        textDocumentProxy.insertText(text)
    }

    @objc private func handleSettingsChanged() {}

    @objc func reloadSettingsFromDisk() {
        runtime.reloadSettings()
        applyKeyboardBackground()
        DispatchQueue.main.async { [weak self] in
            self?.refreshKeyboardContent()
        }
    }

    /// inputView 与宿主都保持透明：键盘底衬背景已移进 SwiftUI 定高内容里（见 IMEKeyboardView 的
    /// .background），只填满键盘区那 totalHeight。切换转场时系统会把 inputView 撑到整屏 844 再收回，
    /// 若把不透明底衬铺在 inputView / 宿主上，这一整片会被涂成键盘底色一闪（整屏屏闪）；两层都透明
    /// 后，转场时内容之外的区域透出宿主 App，配合「内容定高自驱动、不与系统抢高度」消除半屏灰闪。
    /// 主题 / 透明度变更后由 SwiftUI 侧随 runtime.settings 重绘自动同步，这里只维持两层透明。
    private func applyKeyboardBackground() {
        view.backgroundColor = .clear
        hostingController?.view.backgroundColor = .clear
    }

    // MARK: - 剪贴板轮询

    /// 起一个低频定时器，在键盘可见期静默检查剪贴板变化并抓取
    /// —— 用 .common 模式：滚动 / 交互期间也照常触发，不漏抓
    private func startClipboardPolling() {
        stopClipboardPolling()
        let timer = Timer(timeInterval: Self.clipboardPollInterval, repeats: true) { _ in
            ClipboardCapture.captureIfNeeded()
        }
        RunLoop.main.add(timer, forMode: .common)
        clipboardPollTimer = timer
    }

    private func stopClipboardPolling() {
        clipboardPollTimer?.invalidate()
        clipboardPollTimer = nil
    }

    // MARK: - 内嵌编码

    @objc private func handleInputBufferChanged(_ notification: Notification) {
        // 小鹤双拼：内嵌显示展开还原后的拼音（如 nihc 对应 nihao），
        // 而不是按键码本身；26 键全拼的 inlineInput 就是输入码，显示与原实现一致。
        let buffer = runtime.inlineInput.isEmpty ? runtime.inputBuffer : runtime.inlineInput
        if buffer.isEmpty {
            textDocumentProxy.setMarkedText("", selectedRange: NSRange(location: 0, length: 0))
        } else {
            textDocumentProxy.setMarkedText(buffer, selectedRange: NSRange(location: buffer.utf16.count, length: 0))
        }
        // 击键不再重压高度：打字不改变键盘总高（candidateH 固定取开启注释的高度、注释行出现也不
        // 变高），此前每键 async 重算纯属跟系统抢布局、徒增击键开销与切换抖动。高度只在安全区 /
        // 旋转 / 改设置三处离散校正。
    }

    private func commitText(_ text: String) {
        textDocumentProxy.setMarkedText("", selectedRange: NSRange(location: 0, length: 0))
        textDocumentProxy.insertText(text)
    }

    // MARK: - 光标模式与内嵌编码
    // 宿主光标被 markedText 区间困住：marked 存在时 adjustTextPosition 只在区间内挪动
    //（或干脆不动）。所以进入光标模式先摘掉 marked（编码仍在 runtime 缓冲区里，候选不变），
    // 松手退出时再挂回新光标位置——既不丢编码，也不阻碍光标移动。

    private func detachMarkedForCursorMode() {
        textDocumentProxy.setMarkedText("", selectedRange: NSRange(location: 0, length: 0))
    }

    private func rehangMarkedAfterCursorMode() {
        let buffer = runtime.inlineInput.isEmpty ? runtime.inputBuffer : runtime.inlineInput
        guard !buffer.isEmpty else { return }
        textDocumentProxy.setMarkedText(buffer, selectedRange: NSRange(location: buffer.utf16.count, length: 0))
    }
}
