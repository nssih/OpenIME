import Foundation

// MARK: - 方案能力模型
//
// 「这个方案能用什么」以前散在各处：键盘快捷面板无条件列全部形态，混打设置页任何组合都能勾，
// 于是虎码激活时还能停在双拼（敲什么都是空候选）、拼音主方案还能混进形码词库（噪声压过主方案）。
// 这里把判断收成一处：所有 UI 显隐与运行时门控都只问能力位，不各自再判一遍方案类型。
//
// 推导方式不是查表，而是两侧各算一个「编码空间」集合再看有没有交集：
//   键盘形态决定击键被解码成什么（双拼码还原成全拼、26 键原样字母）；
//   方案决定它的词库能被什么编码空间查到（全拼音节 / 双拼码 / 字根码 / 音形复合码）。
// 有交集才可能出候选。将来加一种键盘只要给它补一个解码产物，规则不用改。
//
// 收敛的边界（新增功能前必读）：只隐藏技术上不可能生效的功能。
// 「能生效但属反模式」的（例如给全拼方案强开满码连打）不隐藏 —— 用户设置优先是硬规范，
// 能力模型只负责挡住必然空转的入口，不替用户做偏好决定。
//
// 纯函数、值语义、不做磁盘 IO：可以随手调用，也便于单测穷举整张矩阵。

/// 一段击键最终被解码成的编码空间
///
/// `letters` 是通配：原样字母串对任何词库都能做前缀查询，所以 26 键恒可用。
/// 其余四种互不相交 —— 全拼音节查不到字根码表，双拼码也查不到全拼词库。
public enum DecodedSpace: Hashable {
    /// 原样字母串（26 键恒等直通）
    case letters
    /// 全拼音节串（双拼码还原）
    case fullPinyin
    /// 双拼码（键面码即词库码）
    case doublePinyinCodes
    /// 形码字根码
    case shapeCodes
    /// 音形复合码
    case phonoShapeCodes
}

/// 当前输入链：主方案 + 实际生效的混打参与方案
///
/// 链用于混打候选合并（主方案与参与方案同时出候选），但不扩展键盘形态可用性：
/// 形态只看主方案（`profiles.first`），参与方贡献候选而不改变键盘。
public struct SchemeChain {

    public let profiles: [SchemeProfile]

    public init(profiles: [SchemeProfile]) {
        self.profiles = profiles
    }

    public init(primary: SchemeProfile, participants: [SchemeProfile] = []) {
        self.profiles = [primary] + participants
    }

    /// 链上一个方案都没有（方案还没加载完 / 一个都没装）
    public var isEmpty: Bool { profiles.isEmpty }
}

public enum SchemeCapability {

    // MARK: - 编码空间推导

    /// 某键盘形态在某个方案下把击键解码成什么
    /// - Parameter profile: 参与判定的方案画像；nil 表示方案还没就绪，按最常见的全拼还原处理
    public static func decodedSpaces(_ mode: KeyboardMode,
                                     profile: SchemeProfile?) -> Set<DecodedSpace> {
        switch mode {
        case .pinyin26:
            // 26 键解码是恒等映射，字母串对任何码制都能查
            return [.letters]
        case .heEr:
            // 小鹤双拼键盘：双拼类方案的词库本来就存双拼码，键面码即词库码，恒等直通；
            // 全拼类方案的词库存全拼，双拼码要先还原成全拼
            if profile?.type == .doubleSyllable { return [.doublePinyinCodes] }
            return [.fullPinyin]
        }
    }

    /// 某方案的词库能被哪些编码空间查到
    public static func queryableSpaces(_ profile: SchemeProfile) -> Set<DecodedSpace> {
        switch (profile.type, profile.codeSystem) {
        case (.syllable, .phonetic):
            return [.fullPinyin]
        case (.doubleSyllable, _):
            return [.doublePinyinCodes]
        case (.direct, .shape):
            return [.shapeCodes]
        case (.direct, .phonoShape):
            return [.phonoShapeCodes]
        case (.syllable, _), (.direct, _):
            // 没见过的组合（如 syllable + shape）：保守放行，宁可多给一个入口也不误杀。
            // 这类包本身就是矛盾的，真装进来也查不出东西，不该由能力模型替它编一套规则
            return [.fullPinyin, .doublePinyinCodes, .shapeCodes, .phonoShapeCodes]
        }
    }

    /// 单个方案是否撑得起某键盘形态
    public static func supportsKeyboardMode(_ mode: KeyboardMode, profile: SchemeProfile) -> Bool {
        let decoded = decodedSpaces(mode, profile: profile)
        if decoded.contains(.letters) { return true }
        return !decoded.isDisjoint(with: queryableSpaces(profile))
    }

    // MARK: - 键盘形态可用性

    /// 整条输入链是否撑得起某键盘形态：只看主方案（链首），参与方不扩展可用形态
    ///
    /// 混打参与方只贡献候选，不改变键盘形态可用性 —— 形码主 + 全拼参与时
    /// 双拼对主方案完全无意义（主方案一条候选都出不来），不应放行。
    /// 链为空时只有 26 键算可用 —— 恒等直通不依赖任何方案知识，
    /// 而双拼要靠方案的词库类型才能判定，没依据就别放行
    public static func supportsKeyboardMode(_ mode: KeyboardMode, chain: SchemeChain) -> Bool {
        if mode == .pinyin26 { return true }
        guard let primary = chain.profiles.first else { return false }
        return supportsKeyboardMode(mode, profile: primary)
    }

    /// 当前可用的键盘形态，顺序与 `KeyboardMode.allCases` 一致（26 键、小鹤双拼）
    public static func availableKeyboardModes(chain: SchemeChain) -> [KeyboardMode] {
        KeyboardMode.allCases.filter { supportsKeyboardMode($0, chain: chain) }
    }

    // MARK: - 混打策略
    //
    // 混打的本质是「同一串输入的多种解释并存」：一次击键的编码同时投给主方案与参与方案，
    // 各自检索后合并、参与方案着色。所以它成立的前提是编码空间同源，否则不是多给几个候选，
    // 而是必然产生噪声 —— 噪声混进候选栏，主方案的排序优势被稀释，这才是「乱套」的机理。
    //
    // 方向性决定生死：
    //   形码主 + 拼音参与（合法）：想不起字根就整字打拼音，业界成熟用法，噪声量级可控；
    //   拼音主 + 形码参与（不合法）：任意拼音串都能在形码词库里凑出大量短码命中，噪声压过主方案；
    //   音形码不参与任何一侧（不合法）：它的码本身就是「音 + 形」复合，再挂拼音等于把同一段码
    //     重新解释成纯音，把它自带的消歧能力打回原形。

    /// 主方案能否开混打：只有纯形码可以
    public static func canMix(primary: SchemeProfile) -> Bool {
        primary.isShape
    }

    /// 某方案能否作为参与方案：只有全拼词库（音码 + 音节存储）
    ///
    /// 双拼词库不算 —— 它存的是双拼码，形码主方案打出的字根串被它当双拼码解释，
    /// 与「混进拼音候选」的意图无关，只会添乱
    public static func canParticipate(primary: SchemeProfile, participant: SchemeProfile) -> Bool {
        guard participant.id != primary.id else { return false }
        return participant.codeSystem == .phonetic && participant.type == .syllable
    }

    /// 按策略过滤混打配置：主方案不合格直接判空，参与方案逐个过 `canParticipate`
    ///
    /// 运行时用它做兜底 —— 旧 settings.json 里存着的非法组合不会生效，
    /// 也不必主动改写用户的磁盘配置
    /// - Parameters:
    ///   - primary: 主方案画像；nil 表示方案还没就绪，此时一律判空（宁可不混打，也不放行非法组合）
    ///   - profileOf: 按 id 取参与方案画像，取不到（已卸载 / 还没加载）的配置直接丢掉
    public static func effectiveMixConfigs(_ configs: [MixSchemeConfig],
                                           primary: SchemeProfile?,
                                           profileOf: (String) -> SchemeProfile?) -> [MixSchemeConfig] {
        guard let primary, canMix(primary: primary) else { return [] }
        return configs.filter { config in
            guard config.isEnabled, let participant = profileOf(config.id) else { return false }
            return canParticipate(primary: primary, participant: participant)
        }
    }
}
