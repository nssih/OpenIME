import Foundation

// MARK: - 剪贴板历史设置
//
// 与 KeyboardModeStore / EnglishModeStore 同一套路：不碰 UserSettings 的 Codable 结构
// （新增字段会让旧 settings.json 解码失败），单独存 App Group UserDefaults。
//
// 「立即生效」约定：isEnabled / maxCount 是用户可见设定，setter 写入后补 Darwin 广播，
// 主 App 改完键盘扩展立刻刷新；lastChangeCount / lastSignature 是抓取内部状态，不广播。

public final class ClipboardSettingsStore {

    public static let shared = ClipboardSettingsStore()

    /// 保留条数上限的取值区间（0 = 不保留 / 关闭记录，1000 = 上限）
    public static let maxCountRange = 0...1000
    /// 保留条数默认值
    public static let defaultMaxCount = 100

    private let enabledKey = "com.openime.clipboardEnabled"
    private let maxCountKey = "com.openime.clipboardMaxCount"
    private let lastChangeCountKey = "com.openime.clipboardLastChangeCount"
    private let lastSignatureKey = "com.openime.clipboardLastSignature"

    private let defaults: UserDefaults

    private init() {
        defaults = UserDefaults(suiteName: AppGroupContainer.groupID) ?? .standard
    }

    // MARK: - 用户可见设定（写入即广播）

    /// 是否记录剪贴板历史
    /// —— 默认关闭：从老版本升级上来的用户还没做过选择，不应突然开始记录剪贴板；
    ///    UserDefaults.bool 对不存在的键返回 false，正好与「默认关闭」一致，
    ///    但仍用 object(forKey:) 守卫，语义上明确区分「未设置」与「显式关闭」
    public var isEnabled: Bool {
        get {
            guard defaults.object(forKey: enabledKey) != nil else { return false }
            return defaults.bool(forKey: enabledKey)
        }
        set {
            guard newValue != isEnabled else { return }
            defaults.set(newValue, forKey: enabledKey)
            postSettingsChanged()
        }
    }

    /// 最多保留多少条（0...1000），默认 100
    public var maxCount: Int {
        get {
            guard defaults.object(forKey: maxCountKey) != nil else { return Self.defaultMaxCount }
            return Self.clampMaxCount(defaults.integer(forKey: maxCountKey))
        }
        set {
            let clamped = Self.clampMaxCount(newValue)
            guard clamped != maxCount else { return }
            defaults.set(clamped, forKey: maxCountKey)
            postSettingsChanged()
        }
    }

    // MARK: - 抓取内部状态（不广播）

    /// 上次抓取时的 UIPasteboard.changeCount，默认 -1（保证首次一定触发一次读取）
    public var lastChangeCount: Int {
        get {
            guard defaults.object(forKey: lastChangeCountKey) != nil else { return -1 }
            return defaults.integer(forKey: lastChangeCountKey)
        }
        set { defaults.set(newValue, forKey: lastChangeCountKey) }
    }

    /// 上次抓取内容的签名，用于跨「抓取入口」去重（键盘 / 主 App 共享）
    public var lastSignature: String? {
        get { defaults.string(forKey: lastSignatureKey) }
        set {
            if let newValue {
                defaults.set(newValue, forKey: lastSignatureKey)
            } else {
                defaults.removeObject(forKey: lastSignatureKey)
            }
        }
    }

    // MARK: - 纯函数（便于单测边界）

    /// 把任意整数夹到合法保留条数区间
    public static func clampMaxCount(_ value: Int) -> Int {
        min(max(value, maxCountRange.lowerBound), maxCountRange.upperBound)
    }

    // MARK: - 私有

    private func postSettingsChanged() {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(AppGroupContainer.settingsChangedNotification as CFString),
            nil, nil, true
        )
    }
}
