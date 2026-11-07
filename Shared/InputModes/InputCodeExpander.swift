import Foundation

// MARK: - 输入编码展开入口
//
// 新增文件。把用户实际敲的字符翻译成词库可查询的全拼前缀列表：
//   - pinyin26：原样返回（与原 26 键全拼键盘行为完全一致）
//   - heEr    ：小鹤双拼模块，双拼码展开成全拼前缀（见 HeErDoublePinyin）；
//                双拼类方案（词库存双拼码）下是恒等直通，见 `isIdentityDecoding`
//
// Runtime 只依赖这个入口，因此新增键盘不会改动原有查询分支。
//
// 传进方案画像（`profile`）时，键盘形态之上再叠一层方案自己的 speller 规则：
// 非法键不成立、分隔符不算编码、编译期去了空格的词库输入也去空格。
// 不传画像（旧签名）时行为逐字节不变。
//
// 九宫（T9）的「数字串展开成多条音节切分」已从产品与引擎两侧整体下线，
// 因此展开结果只剩「一条恒等码」与「双拼的少数几条读音」两种形态。

public enum InputCodeExpander {

    /// 一次输入的展开结果
    ///
    /// 对应外部格式里 `speller/algebra` 的求值结果：同一份全拼词库，
    /// 双拼的输入码先还原成音节级全拼，再交给词库做前缀查询。
    public struct Expansion {

        /// 解码出的全拼前缀，按可能性从高到低排序
        ///
        /// 恒等直通（26 键、双拼方案配双拼键盘）只有一条且就是原始输入；
        /// 双拼键盘配全拼词库则可能有多条（一个双键码对应几个合法读音），
        /// 由 Runtime 结合词库词频排定先后。
        public let codes: [String]
        /// 内嵌编码：宿主输入框里该显示的拼音（双拼码对用户没有意义）
        public let display: String
        /// 简拼第二路：侧车里按简拼前缀查到的词。
        /// 主路（`codes`）是精确音节展开，两者并存、不相互替换；没有简拼侧车时永远为空
        public let abbreviations: [(word: String, freq: Int)]

        /// 解码是不是恒等直通：只有一条 `codes` 且它就是规范化后的输入本身
        ///
        /// 26 键恒为真；小鹤双拼键盘配上双拼类方案（词库存双拼码）时也为真 ——
        /// 键面码就是词库码，不需要还原成全拼。调用方据此走「单条查询 + 简拼追加」
        /// 这条路径，而不是双拼的「多条读音分别查询后归组合并」
        public let isIdentity: Bool

        /// 该输入码在当前键盘形态下是否合法
        /// （等价于外部格式中「码能被当前 schema 的 speller 接受」，不合法就没有对应词条）
        public var isValid: Bool { !codes.isEmpty }

        public init(codes: [String], display: String,
                    abbreviations: [(word: String, freq: Int)] = [],
                    isIdentity: Bool = false) {
            self.codes = codes
            self.display = display
            self.abbreviations = abbreviations
            self.isIdentity = isIdentity
        }
    }

    /// 展开输入编码
    /// - Parameters:
    ///   - raw: 输入缓冲区中的原始字符（全拼字母 / 双拼码）
    ///   - mode: 当前键盘形态
    ///   - maxResults: 最多展开条数（nil 时用形态自己的默认值：双拼 8 条 ——
    ///     每个双键码就是一个音节，展开本就很少）
    /// - Returns: 供词库做前缀查询的全拼前缀列表，按可能性从高到低排序
    public static func expandCodes(_ raw: String,
                                   mode: KeyboardMode,
                                   maxResults: Int? = nil) -> [String] {
        expansion(raw, mode: mode, maxResults: maxResults).codes
    }

    /// 展开输入编码（同时给出内嵌显示用的拼音）
    /// - Parameters:
    ///   - profile: 当前激活方案的画像。nil 时不叠方案规则，行为与以前逐字节一致
    ///   - abbreviations: 简拼侧车查询（前缀, 上限）。nil 表示该方案没有侧车，整条简拼路完全跳过
    /// - Note: 双拼的非法编码返回空结果，调用方据此「不给候选」而不是
    ///   退回全拼查询 —— 否则双拼键盘会退化成 26 键全拼（外部格式里没有对应码就没有词条）。
    public static func expansion(_ raw: String,
                                 mode: KeyboardMode,
                                 maxResults: Int? = nil,
                                 profile: SchemeProfile? = nil,
                                 abbreviations: ((String, Int) -> [(word: String, freq: Int)])? = nil) -> Expansion {
        guard !raw.isEmpty else { return Expansion(codes: [], display: "") }
        switch mode {
        case .pinyin26:
            // 26 键解码是恒等映射：原始字母串就是拼音本身，不做任何额外处理。
            // 传了画像时先过一遍方案自己的 speller 规则（非法键 / 分隔符 / 去空格）
            guard let code = normalizedCode(raw, profile: profile) else {
                return Expansion(codes: [], display: raw)
            }
            return Expansion(codes: [code], display: raw,
                             abbreviations: abbreviationHits(code: code, profile: profile,
                                                             abbreviations: abbreviations),
                             isIdentity: true)
        case .heEr:
            // 双拼类方案：词库里存的就是双拼码，键面码即词库码，恒等直通。
            // 这时候再还原成全拼反而对不上码表 —— 「小鹤双拼方案 + 小鹤双拼键盘」
            // 是用户直觉上最该有的组合，不能让它永远空候选
            if isIdentityDecoding(mode: .heEr, profile: profile) {
                guard let code = normalizedCode(raw, profile: profile) else {
                    return Expansion(codes: [], display: raw)
                }
                return Expansion(codes: [code], display: raw,
                                 abbreviations: abbreviationHits(code: code, profile: profile,
                                                                 abbreviations: abbreviations),
                                 isIdentity: true)
            }
            // 全拼类方案：一个双键码对就是一个完整音节，展开结果通常唯一
            let limit = maxResults ?? HeErDoublePinyin.defaultMaxResults
            let codes = HeErDoublePinyin.shared.expand(raw, maxResults: limit)
            return Expansion(codes: codes, display: codes.first ?? "")
        }
    }

    /// 恒等直通路径上的简拼追加（26 键与双拼方案共用这一份判定）
    ///
    /// 简拼只在音码方案上才有意义：形码的短码本来就是正式编码，不是简拼
    private static func abbreviationHits(code: String,
                                         profile: SchemeProfile?,
                                         abbreviations: ((String, Int) -> [(word: String, freq: Int)])?)
        -> [(word: String, freq: Int)] {
        guard let abbreviations, profile?.isPhonetic == true else { return [] }
        return abbreviations(code, abbreviationLimit)
    }

    /// 简拼第二路一次最多取几条：主路已经给了精确匹配的候选，
    /// 简拼只是补位，给多了会把真正想打的词挤到后面
    public static let abbreviationLimit = 8

    /// 该键盘形态在这个方案下是不是恒等直通（不解码，键面码就是词库码）
    ///
    /// 展开层用它决定要不要还原全拼，运行期与键盘侧用它决定「单条查询」还是「多读音归组」、
    /// 以及无候选时空格是原样上屏还是丢弃 —— 判定只有一份，三处不会走差
    /// - Parameter profile: 方案画像；nil（方案还没就绪）时只有 26 键算恒等
    public static func isIdentityDecoding(mode: KeyboardMode, profile: SchemeProfile?) -> Bool {
        switch mode {
        case .pinyin26: return true
        case .heEr:     return profile?.type == .doubleSyllable
        }
    }

    /// 按方案画像把原始输入整理成可查询的编码
    ///
    /// 三件事，都是外部格式 `speller` 在匹配前做的：
    ///   1. 全角字母转半角（全角码在词库里永远匹配不上，转了只多不少）；
    ///   2. 去掉分隔符与空格（分隔符是给人看分段的，不属于编码；词库编译时去了空格，输入也去）；
    ///   3. 出现不属于本方案 alphabet 的键就整串不成立，返回 nil。
    /// 大小写不折叠：编译期没有 lowercase 词库编码，输入侧也不能自作主张
    /// - Returns: nil 表示这次输入在当前方案下不成立（调用方给空候选）
    public static func normalizedCode(_ raw: String, profile: SchemeProfile?) -> String? {
        guard let profile else { return raw.isEmpty ? nil : raw }
        let delimiters = profile.delimiter.map { Set($0) }
        let legal = profile.alphabetChars
        var code = ""
        code.reserveCapacity(raw.count)
        for ch in raw {
            let folded = Self.halfWidth(ch)
            if folded == " " {
                if profile.stripSpacesInCode { continue }
                // 词库编码里留着空格的方案（形码的分段写法），空格当分隔符看
                if delimiters?.contains(" ") == true { continue }
            }
            if let delimiters, delimiters.contains(folded) { continue }
            if let legal, !legal.contains(folded) { return nil }
            code.append(folded)
        }
        return code.isEmpty ? nil : code
    }

    /// 全角 ASCII 转半角（Ａ写成 A、１写成 1），其余字符原样返回
    static func halfWidth(_ ch: Character) -> Character {
        guard let scalar = ch.unicodeScalars.first, ch.unicodeScalars.count == 1,
              scalar.value >= 0xFF01, scalar.value <= 0xFF5E else { return ch }
        return Character(UnicodeScalar(scalar.value - 0xFEE0)!)
    }
}
