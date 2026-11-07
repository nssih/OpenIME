import Foundation

// MARK: - 键盘形态
//
// 新增文件，用于区分两种键盘形态：
//   - pinyin26：原有 26 键全拼键盘（默认值，行为与原实现完全一致）
//   - heEr    ：小鹤双拼模块，小鹤双拼 26 键键盘
//
// 该枚举同时被键盘扩展（切换菜单、视图路由）与 Runtime（输入编码展开）使用。
//
// 九宫（T9）形态已整体下线：数字串→全拼的多读音展开在每次击键都要重算，
// 在键盘扩展的内存/主线程预算里做不到不卡，连引擎侧的数字码索引一起删除。
// 老用户持久化的 "t9" 会走 KeyboardModeStore 的未知值回落，自动回到 26 键。

public enum KeyboardMode: String, Codable, CaseIterable, Identifiable {

    /// 原有 26 键全拼键盘
    case pinyin26 = "pinyin26"
    /// 小鹤双拼模块：小鹤双拼 26 键键盘
    case heEr = "heEr"

    public var id: String { rawValue }

    /// 显示名称（用于键盘切换菜单）
    public var displayName: String {
        switch self {
        case .pinyin26: return "全拼 26 键"
        case .heEr:     return "小鹤双拼"
        }
    }

    /// 菜单图标（SF Symbol）
    public var symbolName: String {
        switch self {
        case .pinyin26: return "keyboard"
        case .heEr:     return "character.cursor.ibeam"
        }
    }
}

// MARK: - 键盘形态持久化
//
// 说明：不改动 UserSettings 的 Codable 结构（新增字段会导致旧 settings.json 解码失败），
// 因此键盘形态单独存放在 App Group 的 UserDefaults 中。

public final class KeyboardModeStore {

    public static let shared = KeyboardModeStore()

    /// 键盘形态变化通知：键盘扩展据此重算高度约束
    /// （两种形态的键盘体几何不同，切换后必须同步新的总高）
    public static let didChangeNotification = Notification.Name("com.openime.keyboardModeChanged")

    private let defaultsKey = "com.openime.keyboardMode"
    private let defaults: UserDefaults

    private init() {
        defaults = UserDefaults(suiteName: AppGroupContainer.groupID) ?? .standard
    }

    /// 当前键盘形态，默认原有 26 键全拼键盘
    ///
    /// 读到不认识的 rawValue（例如九键下线前存下的 "t9"）时回落 26 键，
    /// 并把回落结果写回去，避免每次冷启都走一遍「未知值」分支
    public var mode: KeyboardMode {
        get {
            guard let raw = defaults.string(forKey: defaultsKey) else { return .pinyin26 }
            guard let mode = KeyboardMode(rawValue: raw) else {
                defaults.set(KeyboardMode.pinyin26.rawValue, forKey: defaultsKey)
                return .pinyin26
            }
            return mode
        }
        set {
            guard newValue != mode else { return }
            defaults.set(newValue.rawValue, forKey: defaultsKey)
            NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
        }
    }
}

// MARK: - 中 / 英输入模式持久化
//
// 与 KeyboardModeStore 同一套路：不碰 UserSettings 的 Codable 结构
// （新增字段会让旧 settings.json 解码失败），单独存 App Group UserDefaults。
// 英文模式 = 纯字母直上屏：不查词库、不产生内嵌编码，
// 与主流中文输入法的「中/英」键行为一致。

public final class EnglishModeStore {

    public static let shared = EnglishModeStore()

    private let defaultsKey = "com.openime.englishMode"
    private let defaults: UserDefaults

    private init() {
        defaults = UserDefaults(suiteName: AppGroupContainer.groupID) ?? .standard
    }

    /// 当前是否英文模式，默认中文
    public var isEnglish: Bool {
        get { defaults.bool(forKey: defaultsKey) }
        set { defaults.set(newValue, forKey: defaultsKey) }
    }
}
