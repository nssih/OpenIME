import Foundation

// MARK: - 用户全局设置（存入 App Group，键盘扩展和主 App 共享）

public struct UserSettings: Codable, Equatable {
    // 当前激活方案 ID
    public var activeSchemeId: String = ""

    // 混打设置
    public var mixInputEnabled: Bool = false
    public var mixInputSchemes: [MixSchemeConfig] = []  // 有序列表，顺序即优先级

    // 候选注释显示（全局默认）
    public var showAnnotation: Bool = true

    // 按方案的独立设置（key=schemeId）
    public var schemeConfigs: [String: SchemeUserConfig] = [:]

    // 键盘布局
    public var keyboardLayout: KeyboardLayoutSettings = KeyboardLayoutSettings()

    // 键盘外观
    public var keyboardAppearance: KeyboardAppearanceSettings = KeyboardAppearanceSettings()

    // 标点符号
    public var punctuationMode: PunctuationMode = .chinese
    public var customPunctuations: [PunctuationEntry] = []

    // 候选栏
    public var candidateBarRows: Int = 1   // 1=单行滚动，将来支持多行

    // 智能预测
    public var showPrediction: Bool = true

    // emoji 候选：打出某词时紧跟原词追加「词 + emoji」变体（如「地球」→「地球 🌍 🌎 🌏」），
    // 全方案通吃（映射作用于候选文字，拼音 / 形码 / 双拼都生效），默认开、可关
    public var showEmoji: Bool = true

    // 拼音动态调频：手选某码下的词时累积其学习量、逐渐前移（仅音码生效，与预测正交、可关）
    public var dynamicFreqEnabled: Bool = true

    // 按键声音：敲键时播放系统标准键盘点击音（与别的输入法同款），默认开
    public var keySoundEnabled: Bool = true

    // 按键震动：敲键时给一下极轻的触感反馈，默认关（想开在键盘外观页 / 快捷面板里打开）
    public var keyHapticEnabled: Bool = false

    public init() {}

    /// 顶层容错解码：Swift 合成的 Decodable 对非可选键一律用 decode（不认属性默认值），
    /// 缺任一键就整体抛错；而 AppGroupContainer.loadSettings 用 try?，一抛错就退回全默认
    /// UserSettings() —— 把用户的所有设置（含激活方案 activeSchemeId）一次清零，
    /// 表现为「每次启动激活方案都变回默认、其它设置也丢」。旧版 settings.json 少一个后加的
    /// 顶层字段、或将来新增字段，都会触发这个回归（KeyboardLayoutSettings /
    /// KeyboardAppearanceSettings 早已各自做了容错解码，这里是补齐最外层这一环）。
    ///
    /// 逐字段 decodeIfPresent + 独立回落：默认值单一来源仍是上面的属性声明（先 self.init()
    /// 取到，再用 ?? 兜底），任一字段缺失或类型损坏都只影响它自己，绝不连累其余字段。
    /// 只覆盖 init(from:)，encode(to:) 与 CodingKeys 仍由编译器合成（与嵌套类型同一范式）。
    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        activeSchemeId     = (try? c.decodeIfPresent(String.self, forKey: .activeSchemeId)) ?? activeSchemeId
        mixInputEnabled    = (try? c.decodeIfPresent(Bool.self, forKey: .mixInputEnabled)) ?? mixInputEnabled
        mixInputSchemes    = (try? c.decodeIfPresent([MixSchemeConfig].self, forKey: .mixInputSchemes)) ?? mixInputSchemes
        showAnnotation     = (try? c.decodeIfPresent(Bool.self, forKey: .showAnnotation)) ?? showAnnotation
        schemeConfigs      = (try? c.decodeIfPresent([String: SchemeUserConfig].self, forKey: .schemeConfigs)) ?? schemeConfigs
        keyboardLayout     = (try? c.decodeIfPresent(KeyboardLayoutSettings.self, forKey: .keyboardLayout)) ?? keyboardLayout
        keyboardAppearance = (try? c.decodeIfPresent(KeyboardAppearanceSettings.self, forKey: .keyboardAppearance)) ?? keyboardAppearance
        punctuationMode    = (try? c.decodeIfPresent(PunctuationMode.self, forKey: .punctuationMode)) ?? punctuationMode
        customPunctuations = (try? c.decodeIfPresent([PunctuationEntry].self, forKey: .customPunctuations)) ?? customPunctuations
        candidateBarRows   = (try? c.decodeIfPresent(Int.self, forKey: .candidateBarRows)) ?? candidateBarRows
        showPrediction     = (try? c.decodeIfPresent(Bool.self, forKey: .showPrediction)) ?? showPrediction
        showEmoji          = (try? c.decodeIfPresent(Bool.self, forKey: .showEmoji)) ?? showEmoji
        dynamicFreqEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .dynamicFreqEnabled)) ?? dynamicFreqEnabled
        keySoundEnabled    = (try? c.decodeIfPresent(Bool.self, forKey: .keySoundEnabled)) ?? keySoundEnabled
        keyHapticEnabled   = (try? c.decodeIfPresent(Bool.self, forKey: .keyHapticEnabled)) ?? keyHapticEnabled
    }
}

public struct MixSchemeConfig: Codable, Identifiable, Equatable {
    public let id: String          // scheme id
    public var isEnabled: Bool
    public var candidateColor: String   // #RRGGBB
    public var priority: Int            // 越小越高

    public init(id: String, isEnabled: Bool, candidateColor: String, priority: Int) {
        self.id = id
        self.isEnabled = isEnabled
        self.candidateColor = candidateColor
        self.priority = priority
    }
}

// MARK: - 方案级用户设置

public struct SchemeUserConfig: Codable, Equatable {
    // 满码连打三态开关：nil=跟随方案自己的规则（画像里的 auto_select + max_code_length），
    // true=强制开启（码长看 autoSelectLength），false=强制关闭（方案声明了 auto_select 也不自动上屏）
    public var autoSelectEnabled: Bool?
    // 自动上屏码长：有值=满 N 码且首选整码精确命中时立即上屏；非精确匹配则下一键顶出首选
    public var autoSelectLength: Int?
    // 注释显示：nil=继承全局 showAnnotation
    public var showAnnotation: Bool?
    // 单字优先：nil / false=按词频原序，true=单字整体提到候选最前（组内仍按原序）
    public var singleCharFirst: Bool?

    public init(autoSelectLength: Int? = nil, showAnnotation: Bool? = nil, singleCharFirst: Bool? = nil,
                autoSelectEnabled: Bool? = nil) {
        self.autoSelectLength = autoSelectLength
        self.showAnnotation = showAnnotation
        self.singleCharFirst = singleCharFirst
        self.autoSelectEnabled = autoSelectEnabled
    }
}

// MARK: - 键盘布局设置

public struct KeyboardLayoutSettings: Codable, Equatable {
    public var leftBottomKey: LeftBottomKeyType = .number123
    public var spaceBarLabel: String = "聿·输入法"

    public var rowSpacingRatio: Double = 0.16   // 行间距 = keyHeight * rowSpacingRatio

    /// 键盘高度系数：1.0 = 按键正方形（边长随屏宽动态计算）；>1 更高、<1 更矮。
    /// 键宽恒按屏宽 10 等分不变，键高 = 边长乘此系数；手动调高时按键自动变矩形并重算自适应。
    /// 默认 1.32（= 设置页滑杆 132%）：键高比正方形高一档，观感更饱满。
    public var keyboardHeightRatio: Double = 1.32

    public init() {}

    /// 容错解码：旧版 settings.json 缺 keyboardHeightRatio（或将来新增字段）时回落默认值，
    /// 避免「加一个字段就整份 UserSettings 解码失败、用户所有设置被清零」的回归
    /// （AppGroupContainer.loadSettings 用 try?，解码失败会退回全默认 UserSettings）。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        leftBottomKey       = try c.decodeIfPresent(LeftBottomKeyType.self, forKey: .leftBottomKey) ?? .number123
        spaceBarLabel       = try c.decodeIfPresent(String.self, forKey: .spaceBarLabel) ?? "聿·输入法"
        rowSpacingRatio     = try c.decodeIfPresent(Double.self, forKey: .rowSpacingRatio) ?? 0.16
        keyboardHeightRatio = try c.decodeIfPresent(Double.self, forKey: .keyboardHeightRatio) ?? 1.32
    }
}

public enum LeftBottomKeyType: String, Codable {
    case nextKeyboard  // 地球图标，切换输入法
    case number123     // 切换到数字/符号键盘
}

extension KeyboardLayoutSettings {

    /// 空格键实际显示的文字：用户在键盘布局里的空格键标签留空时回落到默认 "space"
    /// —— 只读计算属性，不参与 Codable 合成，settings.json 的结构与旧版完全兼容；
    ///    各键盘形态统一从这里取，避免「空值回落」规则在各处各写一份
    public var spaceBarDisplayLabel: String {
        spaceBarLabel.isEmpty ? "聿·输入法" : spaceBarLabel
    }
}

// MARK: - 键盘外观设置

public struct KeyboardAppearanceSettings: Codable, Equatable {
    public var theme: ThemeMode = .followSystem
    public var primaryColor: String = "#007AFF"
    public var keyCornerRadius: Double = 3
    public var keyFontSize: Double = 22
    public var candidateFontSize: Double = 22
    public var annotationFontSize: Double = 2
    public var keySpacing: Double = 6
    public var backgroundImagePath: String? = nil
    public var backgroundOpacity: Double = 1.0
    /// 候选正文加粗：文津宋体只有 Regular 一个字重，开启后由系统合成伪粗（描边加粗），
    /// 让宋体细笔画在小字号下更清晰。默认关闭，保持宋体原始观感。
    public var candidateFontBold: Bool = false

    public init() {}

    /// 候选栏高度 = 候选字行高 + 注释行高（开启时），行高系数 1.5 让文字有足够空间不被截断
    public func candidateBarHeight(showAnnotation: Bool) -> Double {
        let candLineH = candidateFontSize * 1.5
        let annoLineH = showAnnotation ? annotationFontSize * 1.5 : 0
        return candLineH + annoLineH
    }

    /// 容错解码：旧版 settings.json 缺 candidateFontBold（或将来新增字段）时回落默认值，
    /// 避免「加一个字段就整份 UserSettings 解码失败、用户所有设置被清零」的回归
    /// （与 KeyboardLayoutSettings 同一范式；loadSettings 用 try?，解码失败会退回全默认）。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        theme               = try c.decodeIfPresent(ThemeMode.self, forKey: .theme) ?? .followSystem
        primaryColor        = try c.decodeIfPresent(String.self, forKey: .primaryColor) ?? "#007AFF"
        keyCornerRadius     = try c.decodeIfPresent(Double.self, forKey: .keyCornerRadius) ?? 3
        keyFontSize         = try c.decodeIfPresent(Double.self, forKey: .keyFontSize) ?? 22
        candidateFontSize   = try c.decodeIfPresent(Double.self, forKey: .candidateFontSize) ?? 22
        annotationFontSize  = try c.decodeIfPresent(Double.self, forKey: .annotationFontSize) ?? 2
        keySpacing          = try c.decodeIfPresent(Double.self, forKey: .keySpacing) ?? 6
        backgroundImagePath = try c.decodeIfPresent(String.self, forKey: .backgroundImagePath)
        backgroundOpacity   = try c.decodeIfPresent(Double.self, forKey: .backgroundOpacity) ?? 1.0
        candidateFontBold   = try c.decodeIfPresent(Bool.self, forKey: .candidateFontBold) ?? false
    }
}

public enum ThemeMode: String, Codable {
    case light
    case dark
    case followSystem
}

// MARK: - 标点

public enum PunctuationMode: String, Codable {
    case chinese    // 中文标点：逗号句号用全角
    case english    // 原始 ASCII 标点
}

public struct PunctuationEntry: Codable, Identifiable, Equatable {
    public let id: UUID
    public let trigger: String    // 触发键，如 ","
    public let output: String     // 输出内容，如 "，"
    public var isEnabled: Bool

    public init(id: UUID, trigger: String, output: String, isEnabled: Bool) {
        self.id = id
        self.trigger = trigger
        self.output = output
        self.isEnabled = isEnabled
    }
}

// MARK: - 用户自定义词条

public struct CustomWord: Codable, Identifiable {
    public let id: UUID
    public var text: String
    public var code: String
    public var createdAt: Date

    public init(id: UUID = UUID(), text: String, code: String, createdAt: Date = Date()) {
        self.id = id
        self.text = text
        self.code = code
        self.createdAt = createdAt
    }
}

// MARK: - 自定义词表纯函数（去重 + 最新置顶）

/// 自定义词表的数组级纯函数集合。抽出来是为了让「学习长句」的去重 + 置顶规则可单测
/// （IMERuntime 是共享容器单例、难以脱污测，这里只测不碰磁盘的数组变换）。
public enum CustomWordStore {

    /// 去重 + 最新置顶（无上限）：把一条「码 → 词」插到表最前。
    /// 与剪贴板 `ClipboardHistoryStore.append` 同一套存法 —— 同 (code, text) 命中先删旧再插到 0 位，
    /// 唯独不做 trim/limit：自定义词 / 长句全存磁盘、不设任何条数上限。
    /// 纯函数：不改入参、返回新数组，便于断言「不产生第二条重复」「最新在 0 位」「大批量不裁剪」。
    /// - Parameters:
    ///   - words: 现有词表
    ///   - code: 新词的输入码
    ///   - text: 新词的文本
    ///   - now: 新词的创建时间（默认当前时刻；测试可注入固定值）
    /// - Returns: 插入并去重后的新词表，新词在 0 位
    public static func dedupPrepend(_ words: [CustomWord],
                                    code: String,
                                    text: String,
                                    now: Date = Date()) -> [CustomWord] {
        var result = words
        if let existing = result.firstIndex(where: { $0.code == code && $0.text == text }) {
            result.remove(at: existing)
        }
        result.insert(CustomWord(text: text, code: code, createdAt: now), at: 0)
        return result
    }
}
