import Foundation

// MARK: - 方案包元数据

public struct SchemeManifest: Codable, Identifiable {
    public let id: String
    public let name: String
    public let version: String
    public let author: String
    public let description: String
    public var installedAt: Date = Date()
    /// 编译这份词库时用的 DictCompiler.compilerEpoch。旧包的 manifest.json 里没有这个键，
    /// 解出 nil 即视为「纪元未知」，同样需要重编。Optional 是为了让老 manifest.json 照旧能解码
    public var compilerEpoch: Int?

    public init(id: String, name: String, version: String, author: String, description: String, installedAt: Date = Date(), compilerEpoch: Int? = nil) {
        self.id = id
        self.name = name
        self.version = version
        self.author = author
        self.description = description
        self.installedAt = installedAt
        self.compilerEpoch = compilerEpoch
    }

    enum CodingKeys: String, CodingKey {
        case id, name, version, author, description, installedAt
        case compilerEpoch = "compiler_epoch"
    }
}

// MARK: - 方案输入规则

/// 码制：方案靠什么把击键变成字
///
/// 为什么不只用 `SchemeType`：SchemeType 描述的是「词库编码怎么查」（前缀直查 / 音节切分 / 双拼展开），
/// 是存储层的分类；而码制描述的是「这个方案的输入逻辑属于哪一类」，是行为层的分类。
/// 两者不是一一对应：超强快码是音形码，词库却走 direct 前缀直查。
/// 全 Optional 存进 schema.json，旧包解出 nil 时由 SchemeProfile 回落到 SchemeType 映射。
public enum CodeSystem: String, Codable {
    /// 形码：虎码、五笔、仓颉、郑码 —— 编码是字根序列，定长顶字上屏
    case shape
    /// 音码：拼音、粤拼、双拼 —— 编码是读音，需要音节切分与整句拼接
    case phonetic
    /// 音形码：超强快码这类音码开头、形码结尾的方案
    case phonoShape = "phono_shape"
}

public struct SchemeDefinition: Codable {
    public let type: SchemeType
    public let maxCodeLength: Int?
    public let autoSelect: Bool?
    public let alphabet: String?
    public let doublePinyinTable: [String: String]?
    public let normalizeCode: String?     // 编译时 code 规范化，支持 "strip_spaces"
    /// 码制。旧包没这个键，解出 nil 时由 SchemeProfile 根据 type 回落
    public let codeSystem: CodeSystem?
    /// 外部格式的 speller/delimiter：编码里的分隔符（默认 " '"），分段与上屏都用得到
    public let delimiter: String?
    /// 外部格式的 auto_clear：顶字上屏后怎么清屏（max_length | unique | always）
    public let autoClear: String?
    /// 外部格式的 translator/max_phrase_length：参与整句拼接的词条最大字数
    public let maxPhraseLength: Int?
    /// 外部格式的 translator/enable_sentence：解析保留仅供兼容，行为层不拿它当开关
    /// （整句候选是 OpenIME 自家词图兜底，见 CandidateEngine.latticeCandidates）
    public let enableSentence: Bool?
    /// 外部格式的 translator/initial_quality：本方案候选的基础权重，多方案混打时用来分高下
    public let initialQuality: Double?
    /// 音形码方案的「反查引导符」：编码以它开头就说明用户要打拼音，去掉引导符借音码方案查字。
    /// 超强快码约定用 `i`（写在包的 schema.yaml 里）。nil 表示方案没声明 —— 运行期只对音形码
    /// 回落到约定俗成的 `i`（见 SchemeProfile.reverseLookupGuide），其余码制永不触发反查。
    /// 这是 Rime「路由规则写在 schema、不写死在引擎里」的同一思路：换个引导符只改包不改代码。
    public let reverseLookupGuide: String?

    public init(type: SchemeType, maxCodeLength: Int? = nil, autoSelect: Bool? = nil, alphabet: String? = nil, doublePinyinTable: [String: String]? = nil, normalizeCode: String? = nil, codeSystem: CodeSystem? = nil, delimiter: String? = nil, autoClear: String? = nil, maxPhraseLength: Int? = nil, enableSentence: Bool? = nil, initialQuality: Double? = nil, reverseLookupGuide: String? = nil) {
        self.type = type
        self.maxCodeLength = maxCodeLength
        self.autoSelect = autoSelect
        self.alphabet = alphabet
        self.doublePinyinTable = doublePinyinTable
        self.normalizeCode = normalizeCode
        self.codeSystem = codeSystem
        self.delimiter = delimiter
        self.autoClear = autoClear
        self.maxPhraseLength = maxPhraseLength
        self.enableSentence = enableSentence
        self.initialQuality = initialQuality
        self.reverseLookupGuide = reverseLookupGuide
    }

    enum CodingKeys: String, CodingKey {
        case type
        case maxCodeLength = "max_code_length"
        case autoSelect = "auto_select"
        case alphabet
        case doublePinyinTable = "double_pinyin_table"
        case normalizeCode = "normalize_code"
        case codeSystem = "code_system"
        case delimiter
        case autoClear = "auto_clear"
        case maxPhraseLength = "max_phrase_length"
        case enableSentence = "enable_sentence"
        case initialQuality = "initial_quality"
        case reverseLookupGuide = "reverse_lookup_guide"
    }
}

public enum SchemeType: String, Codable {
    case direct      // 形码：虎码、快码、五笔、仓颉
    case syllable    // 音码：拼音、粤拼
    case doubleSyllable = "double_syllable"  // 双拼：小鹤、自然码
}

// MARK: - 完整方案包（安装后）

public struct InstalledScheme: Identifiable, Codable {
    public let id: String              // = manifest.id
    public let manifest: SchemeManifest
    public let definition: SchemeDefinition
    public let installPath: URL
    public var isEnabled: Bool = true
    public var availableColumns: [String] = []  // 词库声明的列，如 ["text","code","annotation"]

    public init(id: String, manifest: SchemeManifest, definition: SchemeDefinition, installPath: URL, isEnabled: Bool = true, availableColumns: [String] = []) {
        self.id = id
        self.manifest = manifest
        self.definition = definition
        self.installPath = installPath
        self.isEnabled = isEnabled
        self.availableColumns = availableColumns
    }

    // 运行时加载的词库索引路径
    public var dictBinPath: URL {
        installPath.appendingPathComponent("dict.bin")
    }
}

// MARK: - 候选项

public struct Candidate: Identifiable, Equatable {
    public let id: UUID = UUID()
    public let text: String
    public let code: String
    public let annotation: String?
    public let freq: Int
    public let sourceSchemeId: String
    public var isUserWord: Bool = false
    public var userFreq: Int = 0
    /// emoji 变体候选的「原词」：变体 text 是「词 + emoji」整串，这里存不带 emoji 的原词，
    /// 供上屏后回填 lastCommittedText / 预测关联（学习信号应是原词而非整串 emoji）。仅 emoji 变体非 nil。
    public var emojiBase: String? = nil

    public init(text: String, code: String, annotation: String?, freq: Int, sourceSchemeId: String, isUserWord: Bool = false, userFreq: Int = 0, emojiBase: String? = nil) {
        self.text = text
        self.code = code
        self.annotation = annotation
        self.freq = freq
        self.sourceSchemeId = sourceSchemeId
        self.isUserWord = isUserWord
        self.userFreq = userFreq
        self.emojiBase = emojiBase
    }

    /// 智能预测候选的来源标识（这类候选不是词库条目，code 为空）
    public static let predictionSchemeId = "_prediction"

    /// emoji 变体候选的来源标识（紧跟原词追加的「词 + emoji」，非词库条目，code 为空）
    public static let emojiSchemeId = "_emoji"

    /// 是否为智能预测候选
    public var isPrediction: Bool { sourceSchemeId == Self.predictionSchemeId }

    /// 是否为 emoji 变体候选
    public var isEmoji: Bool { sourceSchemeId == Self.emojiSchemeId }

    public static func == (lhs: Candidate, rhs: Candidate) -> Bool {
        lhs.text == rhs.text
    }
}

// MARK: - 词库条目（YAML 解析用）

public struct DictEntry: Codable {
    public let code: String
    public let text: String
    public let freq: Int
    public let annotation: String?

    public init(code: String, text: String, freq: Int, annotation: String?) {
        self.code = code
        self.text = text
        self.freq = freq
        self.annotation = annotation
    }
}
