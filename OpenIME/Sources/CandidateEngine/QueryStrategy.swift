import Foundation

// MARK: - 检索策略（对应外部格式的 translator 分派）
//
// 同一次击键，音码 / 形码 / 音形码要走完全不同的检索路径：音码要把整串按音节切开，
// 形码按方案声明的码长滑窗，音形码两者交替，双拼还得先把双键码还原成全拼。
// 以前这些分支挤在 `CandidateEngine.query` 的一个 switch 里，加一种码制就得改那个 switch，
// 而且「码制」与「存储类型」的差别（快码是音形码但走前缀直查）在那个 switch 里根本表达不出来。
//
// 现在按方案画像分派到策略：新增码制只是多一个策略实现，CandidateEngine 不再关心具体怎么查。
// 策略都是无状态值类型，只读上下文由 CandidateEngine 一次备好传进来 ——
// 不持有词库、不做磁盘 IO、不加锁，也不存在跨次击键的残留状态。

/// 一次检索需要的全部只读上下文
public struct QueryContext {

    /// 本次要查的编码（双拼策略会用展开后的全拼另建一个上下文）
    public let input: String
    public let schemeId: String
    public let limit: Int
    /// 查不到时是否允许把编码末尾去掉一个字符再查一次（26 键「输入未完成」的兼容行为）
    public let allowPartialFallback: Bool
    /// 方案画像：分段规则、是否允许整句拼接、词条长度上限都由它给
    public let profile: SchemeProfile
    public let reader: DictReader
    /// 展开面板「看全部」的全量扫描开关：为 true 时绕过 DictReader 的 ptn top-N 侧车与
    /// 单字符缓存，对整个命中区间扫描（配合大 limit 拿到近乎全部候选）。默认 false，击键热路径逐字节不变。
    public let fullScan: Bool
    /// 长串词图兜底：只在常规检索彻底落空时才调用，内部自己按画像挑切分方式。
    /// nil 表示本次查询不允许兜底 —— 词图是 O(输入长²) 的词库扫描，
    /// 双拼一次击键会把还原出的几条读音各查一次，逐条兜底会把主线程拖到像死机一样，
    /// 所以那种场景由调用方关掉、整组落空后单独兜底一次
    public let lattice: ((String) -> [Candidate])?

    public init(input: String,
                schemeId: String,
                limit: Int,
                allowPartialFallback: Bool,
                profile: SchemeProfile,
                reader: DictReader,
                fullScan: Bool = false,
                lattice: ((String) -> [Candidate])? = nil) {
        self.input = input
        self.schemeId = schemeId
        self.limit = limit
        self.allowPartialFallback = allowPartialFallback
        self.profile = profile
        self.reader = reader
        self.fullScan = fullScan
        self.lattice = lattice
    }

    /// 换一段编码复用同一个上下文（双拼展开成全拼后接着走音节路）
    public func withInput(_ input: String) -> QueryContext {
        QueryContext(input: input, schemeId: schemeId, limit: limit,
                     allowPartialFallback: allowPartialFallback,
                     profile: profile, reader: reader, fullScan: fullScan, lattice: lattice)
    }
}

/// 一种码制的检索路径
public protocol QueryStrategy {
    /// 这次输入的候选。不含用户词 / 自定义词（由 CandidateEngine 统一并入），也未去重
    func candidates(_ context: QueryContext) -> [Candidate]
}

extension QueryStrategy {

    /// 给词库查回来的候选盖上归属方案（DictReader 只认编码，不知道自己在哪个方案里）
    func stamped(_ candidates: [Candidate], schemeId: String) -> [Candidate] {
        guard !candidates.isEmpty else { return candidates }
        return candidates.map {
            Candidate(text: $0.text, code: $0.code, annotation: $0.annotation,
                      freq: $0.freq, sourceSchemeId: schemeId)
        }
    }

    /// 码表类方案（形码 / 音形码）的检索：整码精确匹配优先，更长码的补全在后。
    ///
    /// 这是外部格式 table translator 的语义：敲 lc 先给整码就是 lc 的字（齿、艹、艸、丌…），
    /// 再给 lc 开头的更长码词条。若把精确与补全按词频混排，虎码 lc 里有 16 条码长>2、
    /// 权重高于 270 的词组会把偏旁「艹(270)」挤出可见候选 —— 与原版字库输出不一致的根因即此。
    /// 补全部分走 `queryTable`（同词频时码短者优先）：超强快码这类全库 weight 恒为 1 的码表，
    /// 若按扫描序（= code 字母序）取 top-N，单字母 `h` 下 200 多条 `ha*` 长码会把「好」(hb)
    /// 这类高频简码整批挤出候选 —— 简码常用字必须优先。
    /// 音码不走这里：拼音的候选顺序是另一套已验收的语义。
    func tableCandidates(_ context: QueryContext) -> [Candidate] {
        let exact = context.reader.queryExact(code: context.input)
        var results = exact
        let completionQuota = context.limit - exact.count
        if completionQuota > 0 {
            // 补全配额要把精确条数让出来：query 的 limit 是混合 top-N，
            // 不多要 exact.count 条的话补全会被精确条目挤掉配额。
            // 展开全量扫描时改走 queryAll（绕过 ptn 侧车，同词频码短者优先的决胜规则与 queryTable 一致）
            let completion = context.fullScan
                ? context.reader.queryAll(prefix: context.input,
                                          limit: context.limit + exact.count,
                                          preferShorterCode: true)
                : context.reader.queryTable(prefix: context.input, limit: context.limit + exact.count)
            results += completion
                .filter { $0.code != context.input }
                .prefix(completionQuota)
        }
        guard !results.isEmpty else { return context.lattice?(context.input) ?? [] }
        return stamped(results, schemeId: context.schemeId)
    }
}

// MARK: - 形码：整码前缀直查

/// 形码（虎码 / 五笔 / 仓颉 / 郑码）：编码就是字根序列，没有音节结构，
/// 用户敲的串本身就是词库里的码，直接前缀查询即可。
public struct CodeStringStrategy: QueryStrategy {

    public init() {}

    public func candidates(_ context: QueryContext) -> [Candidate] {
        // 整码精确优先、补全在后（见 tableCandidates）；落空才交词图按码长切回整句
        return tableCandidates(context)
    }
}

// MARK: - 音码：音节切分

/// 音码（拼音 / 粤拼）：编码是读音连写，前缀查询之外还要容忍「最后一个音节没打完」，
/// 整串长过词库里最长的词时由词图按音节切回整句。
public struct SyllableStrategy: QueryStrategy {

    public init() {}

    public func candidates(_ context: QueryContext) -> [Candidate] {
        // 直接前缀查询（词库 code 无空格，如 nihao）；展开全量扫描时绕过 ptn 侧车取全区间
        var entries = context.fullScan
            ? context.reader.queryAll(prefix: context.input, limit: context.limit)
            : context.reader.query(prefix: context.input, limit: context.limit)

        // 没结果时去掉末尾 1 字符再查（处理输入未完成时的中间状态）。
        // 双拼的编码由展开器保证是合法全拼前缀，查不到就是词库没有，
        // 不应回退 —— 否则会把不相关候选混进来，所以由调用方用 allowPartialFallback 关掉
        if entries.isEmpty, context.input.count > 1, context.allowPartialFallback {
            let dropped = String(context.input.dropLast())
            entries = context.fullScan
                ? context.reader.queryAll(prefix: dropped, limit: context.limit)
                : context.reader.query(prefix: dropped, limit: context.limit)
        }

        // 前缀查询彻底落空（输入长过词库里最长的词，如 nihaomashijie），才轮到词图兜底切整句
        if entries.isEmpty {
            return context.lattice?(context.input) ?? []
        }
        return stamped(entries, schemeId: context.schemeId)
    }
}

// MARK: - 双拼：先当全拼查，落空再展开双键码

/// 双拼（小鹤 / 自然码）：词库里存的仍是全拼，双拼只负责输入侧展开。
public struct DoubleSyllableStrategy: QueryStrategy {

    public init() {}

    public func candidates(_ context: QueryContext) -> [Candidate] {
        let syllable = SyllableStrategy()

        // 主路：进来的已经是全拼。双拼键盘的展开器早就把双键码还原成全拼了，
        // 这条路的行为与「双拼长串一律返回空」的年代完全一致，也是绝大多数击键走的路
        let pinyin = syllable.candidates(context)
        if !pinyin.isEmpty { return pinyin }

        // 补路：进来的还是双拼码本身（26 键键盘配双拼方案、混打里另一路是双拼）。
        // 以前这里直接返回空，一个候选都出不来；现在按双拼表展开成全拼再走音节路，
        // 音节路自带的词图兜底也跟着生效 —— 长串双拼码从此能切出整句
        var tried = Set<String>()
        for expanded in HeErDoublePinyin.shared.expand(context.input)
        where expanded != context.input && tried.insert(expanded).inserted {
            let results = syllable.candidates(context.withInput(expanded))
            if !results.isEmpty { return results }
        }
        return []
    }
}

// MARK: - 音形码：音码段与形码段交替

/// 音形码（超强快码这类）：编码是「音码开头 + 形码补齐」，词库里的整码词条前缀直查就能命中；
/// 落空时由词图按「音节段 + 定长形码段」混合切分（见 `CodeLattice.segmentMixed`，
/// 切分方式在 `CandidateEngine` 的兜底闭包里按画像挑好）。
public struct PhonoShapeStrategy: QueryStrategy {

    public init() {}

    public func candidates(_ context: QueryContext) -> [Candidate] {
        // 音形码词库同样是码表（外部格式 table translator）：整码精确优先、补全在后；
        // 不做音码那种「去尾再查」的部分回退，落空直接交混合切分的词图
        return tableCandidates(context)
    }
}

// MARK: - 分派

public enum QueryStrategies {

    /// 按画像挑检索策略
    ///
    /// 先看存储类型再看码制：双拼的「先展开成全拼」是词库存储方式决定的，压过码制；
    /// 其余情况由码制说了算 —— 这正是「快码是音形码、词库却走前缀直查」能表达出来的地方。
    public static func strategy(for profile: SchemeProfile) -> QueryStrategy {
        if profile.type == .doubleSyllable { return DoubleSyllableStrategy() }
        switch profile.codeSystem {
        case .phonoShape: return PhonoShapeStrategy()
        case .phonetic:   return SyllableStrategy()
        case .shape:      return CodeStringStrategy()
        }
    }
}
