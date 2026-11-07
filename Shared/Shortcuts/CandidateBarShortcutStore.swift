import Foundation

// MARK: - 候选栏快捷功能条的用户配置
//
// 与 KeyboardModeStore / EnglishModeStore 同一套路：不碰 UserSettings 的 Codable 结构，单独存 App Group UserDefaults。
// 存的是「用户挑选并排好序的功能 id 列表」，键盘扩展空态据此在中段渲染图标。
//
// 「立即生效」约定：orderedIDs 的 setter 写入后补 Darwin 广播，主 App 改完键盘扩展立刻重绘。

public final class CandidateBarShortcutStore {

    public static let shared = CandidateBarShortcutStore()

    private let defaultsKey = "com.openime.candidateBarShortcuts"
    private let defaults: UserDefaults

    private init() {
        defaults = UserDefaults(suiteName: AppGroupContainer.groupID) ?? .standard
    }

    /// 首次安装（从未设置过）时默认全选的快捷功能 id 列表：
    /// 全部 bar-eligible 功能预选，顺序为「en → 剪贴 → 调频 → 智能 → 注释 → 字符」
    ///（即 orderedIDs 的逻辑先后；候选栏沿用既有约定把最先的贴右端、往后依次往左排）。
    /// 末尾再兜上任何未列进这份显式顺序、但具备收录资格的功能，日后新增开关不会漏掉。
    public static let defaultOrderedIDs: [String] = {
        let preferred: [CandidateBarShortcut] = [
            .toggleEnglish, .clipboardHistory, .toggleDynamicFreq,
            .togglePrediction, .toggleAnnotation, .numberKeyboard
        ]
        let rest = CandidateBarShortcut.allCases.filter { $0.isBarEligible && !preferred.contains($0) }
        return (preferred.filter(\.isBarEligible) + rest).map(\.rawValue)
    }()

    /// 用户挑选并排序后的快捷功能 id 列表
    /// —— 默认全选：从未写入过（stringArray 返回 nil，即首次安装 / 卸载重装后）时返回全部 bar-eligible 功能；
    ///    一旦用户在设置页动过（哪怕删到只剩一个、或显式清空），stored 就非 nil，此后一律尊重用户的选择，
    ///    不再回落到默认全选（区分 nil「没设置过」与 []「用户主动清空」）
    public var orderedIDs: [String] {
        get {
            if let stored = defaults.stringArray(forKey: defaultsKey) { return stored }
            return Self.defaultOrderedIDs
        }
        set {
            guard newValue != orderedIDs else { return }
            defaults.set(newValue, forKey: defaultsKey)
            // 该配置不在 UserSettings 里，不走 updateSettings 就没有通知；补跨进程广播，
            // 保证主 App 改完键盘空态立即反映（任何自定义设定立即生效、无需重新部署）
            CFNotificationCenterPostNotification(
                CFNotificationCenterGetDarwinNotifyCenter(),
                CFNotificationName(AppGroupContainer.settingsChangedNotification as CFString),
                nil, nil, true
            )
        }
    }

    /// orderedIDs 映射成枚举：跳过未知项（版本回退时可能出现）、保序、去重
    public var shortcuts: [CandidateBarShortcut] {
        // 过滤掉不再具备快捷栏收录资格的功能（如键盘形态 / 输入方案）：
        // 老配置里若残留这些 id，也不应在候选栏渲染（收录资格见 isBarEligible 注释）
        CandidateBarShortcut.resolve(orderedIDs).filter(\.isBarEligible)
    }
}
