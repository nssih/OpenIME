import Foundation

// MARK: - 方案画像
//
// 一个方案「该怎么输入」的规则散落在 schema.json 的好几个字段里，而且旧包缺字段是常态。
// 画像把这些规则一次性算成一个只读值类型：字段缺失时按码制回落到合理默认，
// 于是展开层、检索层、上屏层都只看画像，不必各自写一遍「旧包没有这个字段怎么办」。
//
// 只读、值语义、算一次就用到底：不持有词库、不做磁盘 IO，可以随手复制，也不存在线程竞争。

public struct SchemeProfile {

    public let id: String
    /// 词库编码怎么查（存储层分类，来自 dict.bin 头部，永远有值）
    public let type: SchemeType
    /// 输入逻辑属于哪一类（行为层分类，缺字段时按 type 回落）
    public let codeSystem: CodeSystem
    /// 本方案认哪些键；nil 表示不过滤（OpenIME 自有包大多不写）
    public let alphabet: String?
    /// 编码分隔符；nil 表示不分段
    public let delimiter: String?
    /// 最长编码。形码方案靠它做「满码连打」（满码即上 / 长串整句都要知道单段跨度）
    public let maxCodeLength: Int?
    /// 方案自己声明的自动上屏开关（与用户设置分开，谁优先见 `autoSelectLength`）
    public let autoSelect: Bool?
    /// 外部格式 speller/auto_clear 的原样值（manual | auto | max_length），旧 schema.json 兼容保留。
    /// 注意它不作行为开关：OpenIME 满码连打上屏后一律清屏。外部格式的 `manual` 是「留着编码
    /// 继续打」，那需要区分清空码 / 有码两种状态的状态机，当前没有；半吊子地留着码，
    /// 下一键会立即再顶一次同一个词
    public let autoClear: String?
    /// 参与整句拼接的词条最大字数；nil 表示不限制
    public let maxPhraseLength: Int?
    /// 外部格式 translator/enable_sentence 的原样值（旧 schema.json 兼容保留）。
    /// 注意它不参与任何行为开关：整句候选是 OpenIME 自家的词图兜底算法，
    /// 只在常规检索落空时救场，不该被数据源的拼句旗标关掉；
    /// 推断码制时读的是外部 schema 里的同名值作特征证据，与画像里这份无关
    public let enableSentence: Bool
    /// 本方案候选的基础权重，多方案混打时用来分高下
    public let initialQuality: Double
    /// 词库编码在编译期去掉了空格（雾凇的 `ni hao` 存成 `nihao`），
    /// 输入侧必须同样去掉才对得上 —— 编译期怎么规范化的，运行期就怎么规范化
    public let stripSpacesInCode: Bool
    public let doublePinyinTable: [String: String]
    /// 方案声明的反查引导符（schema.yaml 的 reverse_lookup_guide）；nil = 没声明。
    /// 最终取值见 `effectiveReverseLookupGuide`，别直接读这个原始字段。
    public let reverseLookupGuide: String?

    public init(scheme: InstalledScheme) {
        let definition = scheme.definition
        self.id = scheme.id
        self.type = definition.type
        self.codeSystem = definition.codeSystem ?? Self.fallbackCodeSystem(for: definition.type)
        self.alphabet = definition.alphabet
        self.delimiter = definition.delimiter
        self.maxCodeLength = definition.maxCodeLength
        self.autoSelect = definition.autoSelect
        self.autoClear = definition.autoClear
        self.maxPhraseLength = definition.maxPhraseLength
        self.enableSentence = definition.enableSentence ?? true
        self.initialQuality = definition.initialQuality ?? 1.0
        self.stripSpacesInCode = definition.normalizeCode == "strip_spaces"
        self.doublePinyinTable = definition.doublePinyinTable ?? [:]
        self.reverseLookupGuide = definition.reverseLookupGuide
    }

    /// 测试与内部构造用的直接初始化
    public init(id: String,
                type: SchemeType,
                codeSystem: CodeSystem? = nil,
                alphabet: String? = nil,
                delimiter: String? = nil,
                maxCodeLength: Int? = nil,
                autoSelect: Bool? = nil,
                autoClear: String? = nil,
                maxPhraseLength: Int? = nil,
                enableSentence: Bool? = nil,
                initialQuality: Double? = nil,
                stripSpacesInCode: Bool = false,
                doublePinyinTable: [String: String]? = nil,
                reverseLookupGuide: String? = nil) {
        self.id = id
        self.type = type
        self.codeSystem = codeSystem ?? Self.fallbackCodeSystem(for: type)
        self.alphabet = alphabet
        self.delimiter = delimiter
        self.maxCodeLength = maxCodeLength
        self.autoSelect = autoSelect
        self.autoClear = autoClear
        self.maxPhraseLength = maxPhraseLength
        self.enableSentence = enableSentence ?? true
        self.initialQuality = initialQuality ?? 1.0
        self.stripSpacesInCode = stripSpacesInCode
        self.doublePinyinTable = doublePinyinTable ?? [:]
        self.reverseLookupGuide = reverseLookupGuide
    }

    /// 旧包没写码制时按 SchemeType 回落：这是唯一能保证的对应关系
    /// （syllable / double_syllable 一定是音码；direct 在旧包里一律是形码）
    public static func fallbackCodeSystem(for type: SchemeType) -> CodeSystem {
        switch type {
        case .syllable, .doubleSyllable: return .phonetic
        case .direct:                    return .shape
        }
    }

    // MARK: - 派生判断

    /// 有音码成分：音码与音形码都算（简拼第二路对它俩同样有意义），只有纯形码不算
    public var isPhonetic: Bool { codeSystem != .shape }
    /// 纯形码：编码是字根序列，不是音节
    public var isShape: Bool { codeSystem == .shape }
    /// 音形码：既要按读音分段，又要按字根补齐，走专门的检索策略
    public var isPhonoShape: Bool { codeSystem == .phonoShape }

    /// 反查引导符的最终取值：方案在 schema.yaml 里声明了就用声明的（数据驱动，可换可关）；
    /// 没声明时只对音形码回落到约定俗成的 "i"（超强快码的历史约定），其余码制返回 nil
    ///（纯形码的 i 可能是合法码元、音码方案根本不需要反查，都永不触发 i+拼音 路径）。
    /// 引导符来自数据而非引擎里对某个方案名的硬编码，符合 Rime「路由写在 schema」的精髓。
    public var effectiveReverseLookupGuide: String? {
        if let declared = reverseLookupGuide, !declared.isEmpty { return declared }
        return isPhonoShape ? "i" : nil
    }

    /// alphabet 的字符集合，用于过滤非法键。nil 表示不过滤
    public var alphabetChars: Set<Character>? {
        guard let alphabet, !alphabet.isEmpty else { return nil }
        return Set(alphabet)
    }

    /// 满码连打的码长：用户设置优先，没设置才用方案自己的规则
    ///
    /// 用户设置优先是硬规范 —— 方案作者写的 auto_select 只是默认值，
    /// 用户在设置页手填的码长必须立即生效，不能被画像盖掉。
    /// - Parameter userAutoSelectLength: 设置页里该方案的「自动上屏码长」，nil 表示没填
    /// - Returns: 达到这个长度就自动上屏首选；nil 表示不自动上屏
    public func autoSelectLength(userSetting userAutoSelectLength: Int?) -> Int? {
        if let userAutoSelectLength, userAutoSelectLength > 0 { return userAutoSelectLength }
        guard autoSelect == true else { return nil }
        guard let maxCodeLength, maxCodeLength > 0 else { return nil }
        return maxCodeLength
    }

    /// 三态开关版：用户在设置页显式关闭（enabled == false）时，
    /// 方案声明了 auto_select 也不自动上屏 —— 「关」必须是真的关，
    /// 否则长串整句流派（词图兜底 + 空格上屏）永远轮不到；
    /// nil=跟随方案，true=开启（码长仍由 userSetting / 方案规则决定）
    public func autoSelectLength(userSetting userAutoSelectLength: Int?, enabled: Bool?) -> Int? {
        if enabled == false { return nil }
        return autoSelectLength(userSetting: userAutoSelectLength)
    }
}
