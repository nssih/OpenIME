import Foundation

// MARK: - 候选引擎
// 单方案查询 + 音节切分 + 用户自定义词融合

public final class CandidateEngine {

    private var readers: [String: DictReader] = [:]    // schemeId 对应 DictReader
    private var schemes: [String: InstalledScheme] = [:]
    /// 方案画像缓存：画像是纯计算的值类型，一个方案算一次就够（装卸方案时跟着失效）
    private var profiles: [String: SchemeProfile] = [:]
    private var customWords: [CustomWord] = []
    /// 自定义词的 code 有序下标：`customWords` 的下标按各自 code 升序排好（只存下标、不含词本身，占 8N 字节）。
    /// mergeExtras 在它上二分定位「以 input 为前缀」的连续区间，每键 O(len·logN)，开销随词量对数增长。
    /// 自定义词无上限、且随组句学习（learnPhrase）持续累积，二分让击键热路径不被总量线性拖垮；
    /// 相比给每个前缀建字典条目的前缀索引（内存随 N×码长 无界膨胀，键盘扩展最忌被 jetsam 顶掉），只占线性 8N 字节。
    /// 仅在 updateCustomWords（启停 / 重载 / 学词，低频）时随数组一并重排。
    private var customWordSortedIdx: [Int] = []

    /// 拼音动态调频查询器：由 Runtime 注入，按「词库码 + 词」返回学习次数（0 = 没学过）。
    /// 只做主线程内存读、不碰磁盘；为 nil 时候选排序与引入调频前逐字节一致（天然向后兼容）。
    public var frequencyBoost: ((String, String) -> Int)?

    public init() {}

    // MARK: - 加载方案

    public func loadScheme(_ scheme: InstalledScheme) throws {
        let reader = try DictReader(binURL: scheme.dictBinPath)
        readers[scheme.id] = reader
        schemes[scheme.id] = scheme
        profiles[scheme.id] = SchemeProfile(scheme: scheme)
    }

    public func unloadScheme(id: String) {
        readers.removeValue(forKey: id)
        schemes.removeValue(forKey: id)
        profiles.removeValue(forKey: id)
    }

    /// 系统内存告警：清掉所有已加载词库的查询缓存（可重建的派生数据）。
    /// reader 本身保留：mmap 的干净页由系统自行回收，不占进程脏内存，
    /// 而卸载后下次击键要重新建映射和索引，得不偿失
    public func purgeCaches() {
        for reader in readers.values { reader.purgeCaches() }
    }

    /// 后台构建词库 reader（纯构造，不碰任何现有状态）：
    /// IMERuntime.reloadSettings 的异步阶段在后台队列调用，构建完成后整体
    /// 移交主线程走 applyReloaded 安装，构建与查询之间没有并发访问
    public static func buildReaders(for schemes: [InstalledScheme]) -> [String: DictReader] {
        var built: [String: DictReader] = [:]
        for scheme in schemes {
            if let reader = try? DictReader(binURL: scheme.dictBinPath) {
                built[scheme.id] = reader
            }
        }
        return built
    }

    /// 主线程原子应用重载结果：卸掉已消失的方案、装入新构建的 reader、
    /// 刷新方案表与画像。newReaders 里没有的已装 reader 原地保留
    ///（词库文件没变就不必重建 mmap）。查询与安装都只跑在主线程，
    /// 旧 reader 被替换后由 ARC 释放，正在进行的查询拿着旧引用也不会断
    public func applyReloaded(schemes: [InstalledScheme], newReaders: [String: DictReader]) {
        let validIds = Set(schemes.map { $0.id })
        // 先收集再卸载： unloadScheme 会变更 readers，不能边遍历边改
        let staleIds = readers.keys.filter { !validIds.contains($0) }
        for id in staleIds {
            unloadScheme(id: id)
        }
        for (id, reader) in newReaders {
            readers[id] = reader
        }
        for scheme in schemes {
            self.schemes[scheme.id] = scheme
            profiles[scheme.id] = SchemeProfile(scheme: scheme)
        }
    }

    /// 取方案画像（loadScheme 时已经算好，这里只兜住「先查询后加载」这类极端顺序）
    private func profile(for scheme: InstalledScheme) -> SchemeProfile {
        if let cached = profiles[scheme.id] { return cached }
        let profile = SchemeProfile(scheme: scheme)
        profiles[scheme.id] = profile
        return profile
    }

    /// 按方案 id 取画像（混打守门用：调用方要知道参与方案是什么码制、什么存储类型）
    /// - Returns: 未加载的方案返回 nil
    public func profile(of schemeId: String) -> SchemeProfile? {
        guard let scheme = schemes[schemeId] else { return nil }
        return profile(for: scheme)
    }

    /// 按方案 id 取已加载的词库 reader（异步词图给反查候选补编码注释用）。
    /// DictReader 只读不可变数据、缓存自带 NSLock，交给后台线程调用是安全的。
    /// - Returns: 未加载的方案返回 nil
    public func reader(for schemeId: String) -> DictReader? {
        readers[schemeId]
    }

    public func updateCustomWords(_ words: [CustomWord]) {
        self.customWords = words
        // 按 code 升序排出下标（O(N·len·logN)，仅启停 / 重载 / 学词这些低频时机跑一次）；
        // 同 code 的相对顺序不影响区间查找（它们会被一并命中、再按存储序还原），故 sorted 不稳定无妨
        self.customWordSortedIdx = (0..<words.count).sorted { words[$0].code < words[$1].code }
    }

    // MARK: - 查询

    /// - Parameter allowPartialFallback: 查不到时是否把编码末尾去掉一个字符再查一次
    ///   （原有 26 键的「输入未完成」兼容行为）。小鹤双拼的编码由展开器
    ///   保证是合法全拼前缀，查不到就是词库没有，不应回退 —— 否则会把不相关候选混进来。
    /// - Parameter allowLattice: 查不到时是否跑长串词图兜底。词图是 O(输入长²) 的词库扫描，
    ///   一次击键只该跑一次：小鹤双拼会把输入展开成多条读音逐条查询，
    ///   逐条兜底等于把扫描放大几倍（实测能把主线程拖到像死机），
    ///   所以那些路径传 false，整组落空后由 Runtime 单独兜底一次
    public func query(input: String, schemeId: String, limit: Int = 50,
                      allowPartialFallback: Bool = true,
                      allowLattice: Bool = true,
                      fullScan: Bool = false) -> [Candidate] {
        guard let reader = readers[schemeId],
              let scheme = schemes[schemeId] else { return [] }

        let profile = self.profile(for: scheme)
        let context = QueryContext(input: input, schemeId: schemeId, limit: limit,
                                   allowPartialFallback: allowPartialFallback,
                                   profile: profile, reader: reader,
                                   fullScan: fullScan,
                                   lattice: allowLattice ? { code in
                                       self.latticeCandidates(input: code, reader: reader,
                                                              schemeId: schemeId, profile: profile)
                                   } : nil)

        // 按画像分派到检索策略：音码 / 形码 / 音形码 / 双拼各走各的路（见 QueryStrategy）
        let results = QueryStrategies.strategy(for: profile).candidates(context)
        // 动态调频：只重排词库候选本身的学习偏好，自定义词 / 预测仍在后续各步按原规则叠加
        let ordered = applyFrequency(results, profile: profile)

        // 自定义词按点选次数定位次（第5位起、升频封顶第2位、降频回落第5位），最后同词去重。
        // 去重放在最后：自定义词已就位，同一个词的多条码才能留对那一条
        return CandidateScoring.uniquify(
            mergeExtras(ordered, input: input),
            initialQuality: profile.initialQuality)
    }

    // MARK: - 展开面板「看全部」的后台全量扫描
    //
    // 展开面板要绕过 ptn top-N 侧车扫整个命中区间（单字母 `h` 在雾凇 55 万词下命中几万条、
    // 物化数千候选，真机实测主线程同步跑 205ms），这 205ms 卡在主线程上会把展开动画整个冻住 ——
    // 用户点一下「下拉」感觉不是立刻打开。检索策略本身（QueryStrategies）只读 DictReader（缓存自带锁），
    // 与词图后台计算同源、可安全在后台队列并发跑；只有动态调频（frequencyBoost 读 settings）与自定义词
    // （customWords）是主线程可变状态，必须留在主线程。于是把 query() 拆成「后台纯扫描 + 主线程收尾」两半，
    // 收尾复用与 query() 完全相同的 applyFrequency / mergeExtras / uniquify，产出逐字节一致。
    // 这套快照 API 是纯加法，击键热路径的 query() 不受任何影响。

    /// 后台安全的全量扫描快照（与 `LatticeJob` 同源设计）：reader / profile 是主线程当前已加载的只读引用，
    /// DictReader 只读不可变数据、缓存自带锁，可整体丢到后台队列跑而不触碰任何可变状态
    public struct ScanJob {
        public let input: String
        public let reader: DictReader
        public let schemeId: String
        public let profile: SchemeProfile
        public let limit: Int
        public let allowPartialFallback: Bool
    }

    /// 主线程取一份全量扫描快照；方案未加载返回 nil。调用方据此把展开的全量扫描移到后台算
    public func scanJob(input: String, schemeId: String, limit: Int,
                        allowPartialFallback: Bool) -> ScanJob? {
        guard let reader = readers[schemeId], let scheme = schemes[schemeId] else { return nil }
        return ScanJob(input: input, reader: reader, schemeId: schemeId,
                       profile: profile(for: scheme), limit: limit,
                       allowPartialFallback: allowPartialFallback)
    }

    /// 后台安全：只跑纯检索策略（fullScan 全区间扫描，不带词图兜底），不碰 frequencyBoost / customWords
    /// 等主线程可变状态。结果交回主线程用 `finalizeScan` 补齐调频 / 自定义词 / 去重（可在任意线程调用）
    public static func runRawScan(_ job: ScanJob) -> [Candidate] {
        let context = QueryContext(input: job.input, schemeId: job.schemeId, limit: job.limit,
                                   allowPartialFallback: job.allowPartialFallback,
                                   profile: job.profile, reader: job.reader,
                                   fullScan: true, lattice: nil)
        return QueryStrategies.strategy(for: job.profile).candidates(context)
    }

    /// 主线程：把后台扫回的原始候选补齐 `query()` 的尾部三步（动态调频 → 自定义词 → 去重），
    /// 与同步 `query(fullScan: true, allowLattice: false)` 产出完全一致。frequencyBoost / customWords
    /// 都是主线程可变状态，只能在这跑；输入是已物化的 ≤limit 条，这三步是 O(n) 主线程开销、毫秒级
    public func finalizeScan(_ raw: [Candidate], input: String, profile: SchemeProfile) -> [Candidate] {
        let ordered = applyFrequency(raw, profile: profile)
        return CandidateScoring.uniquify(
            mergeExtras(ordered, input: input),
            initialQuality: profile.initialQuality)
    }

    /// 文字 → 该方案词库里的最短编码（形码「i + 拼音」反查给候选补编码注释用）
    ///
    /// 只有反查这一条低频路径需要：反查候选来自音码方案，不带主方案编码，而用户反查
    /// 就是想学这个字在手上这套形码里怎么拼。未加载的方案 / 空入参给空表。
    public func shortestCodes(for texts: [String], schemeId: String) -> [String: String] {
        guard !texts.isEmpty, let reader = readers[schemeId] else { return [:] }
        return reader.shortestCodes(forTexts: texts)
    }

    /// 自定义词（组句学习的 + 手动添加的，两类走同一路径）新词的起始位次（1-based）。
    /// 绝不占据首选：形码有一简 / 二简 / 三简，长句一上来就顶掉简码字不科学。
    /// 属位次调频行为参数（无法由数据源派生）：与 `customWordBestRank` 共同界定升降区间。
    public static let customWordStartRank = 5

    /// 自定义词经反复点选能升到的最高位次（1-based 封顶）。
    /// 从第 `customWordStartRank` 位起每主动点选一次升一位，到此封顶（不再压过天然首选）。
    /// 起点到封顶相差 3 位，与 `FrequencyAdjustEngine.promoteCap = 3`（3 次点选饱和）天然对齐。
    public static let customWordBestRank = 2

    /// 取 code 以 `input` 为前缀的自定义词，按存储序（新词在前）返回 —— 与旧 `filter { hasPrefix }` 同集同序。
    /// - 空 input：hasPrefix("") 恒真，直接返回全量（保持存储序）。
    /// - 非空：在 code 有序下标数组上二分找「第一个 code >= input」的下界（同前缀的串在有序数组里必然连续，
    ///   且下界必落在前缀区间内），从下界向后线性收集同前缀的连续段，最后把命中下标升序还原存储序。
    /// 假设 code 为 ASCII 键面码（拼音 / 形码 / 双拼皆然），此时 String 的 `<` 全序与前缀关系一致、区间连续成立。
    private func customWordsMatching(_ input: String) -> [CustomWord] {
        guard !input.isEmpty else { return customWords }
        guard !customWordSortedIdx.isEmpty else { return [] }
        // 二分下界：第一个 code >= input 的位置
        var lo = 0
        var hi = customWordSortedIdx.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if customWords[customWordSortedIdx[mid]].code < input { lo = mid + 1 } else { hi = mid }
        }
        // 从下界向后收集连续同前缀段（一旦不匹配即可停：有序数组里同前缀相邻）
        var matchedIdx: [Int] = []
        var j = lo
        while j < customWordSortedIdx.count {
            let idx = customWordSortedIdx[j]
            guard customWords[idx].code.hasPrefix(input) else { break }
            matchedIdx.append(idx)
            j += 1
        }
        // 升序还原存储序（customWords[0] 最新），与旧 filter 的遍历序逐条一致
        matchedIdx.sort()
        return matchedIdx.map { customWords[$0] }
    }

    /// 并入用户自定义词（所有查询路径共用的尾部逻辑）：按点选次数定位次。
    /// 新词从第 `customWordStartRank` 位起、每主动点选一次升一位、封顶第 `customWordBestRank` 位；
    /// 改选同码其它候选时按 `FrequencyAdjustEngine` 竞争衰减自由回落，下限即起始的第 `customWordStartRank` 位。
    /// - Parameter input: 本次输入串。收录资格仍是「`code.hasPrefix(input)`」（口径不变），只是不再逐条扫全量：
    ///   改在 code 有序下标 `customWordSortedIdx` 上二分定位前缀区间，每键 O(len·logN)、开销随词量对数增长，
    ///   不随自定义词总数线性走（自定义词无上限且随组句学习累积，这点是热路径不被拖垮的关键）。
    private func mergeExtras(_ base: [Candidate], input: String) -> [Candidate] {
        // 命中集与旧 `filter { hasPrefix }` 同集同序（存储序、新词在前），下游插入行为逐条不变
        let matches = customWordsMatching(input)
        guard !matches.isEmpty else { return base }
        var result = base
        // 已在结果里的词（base 原有 + 已插入的自定义词）不再重复插入；uniquify 只按 text 去重、保序不重排
        var seen = Set(base.map { $0.text })
        // 自定义词按存储序（新词在前）依次插入各自的目标位次
        for w in matches where seen.insert(w.text).inserted {
            let count = frequencyBoost?(w.code, w.text) ?? 0
            // 0-based 目标位：count 0→第5位(idx4)、1→4(idx3)、2→3(idx2)、≥3→封顶第2位(idx1)
            var idx = max(Self.customWordBestRank - 1, (Self.customWordStartRank - 1) - count)
            idx = min(idx, result.count)  // base 不足目标位时落末尾兜底
            // freq 取插入位邻位候选的 freq：保持局部 freq 单调不增，防下游任何按 freq 的平分误移
            let neighborFreq = idx < result.count ? result[idx].freq : (result.last?.freq ?? 0)
            let candidate = Candidate(text: w.text, code: w.code, annotation: nil,
                                      freq: neighborFreq, sourceSchemeId: "")
            result.insert(candidate, at: idx)
        }
        return result
    }

    // MARK: - 拼音动态调频

    /// 把动态调频学到的偏好叠加到词库候选的排序词频上（仅音码）。
    ///
    /// 只重建内存 Candidate 的 freq，绝不改动 mmap 里的静态词频；抬升以本批最高词频为上界
    /// （见 `FrequencyAdjustEngine.liftedFreq`），并重排后仍保持「候选按 freq 降序」——
    /// 这是下游（去重打分 / 分组权重）共同依赖的不变式，改序不改序基会全线错乱。
    /// 冷启动、未开调频、或本批没有任何学习项时原样返回、零分配，多数击键不该为没发生的事付钱。
    private func applyFrequency(_ base: [Candidate], profile: SchemeProfile) -> [Candidate] {
        guard let boost = frequencyBoost, profile.codeSystem == .phonetic, base.count > 1 else { return base }
        var counts = [Int](repeating: 0, count: base.count)
        var anyBoost = false
        for (index, candidate) in base.enumerated() {
            let learned = boost(candidate.code, candidate.text)
            counts[index] = learned
            if learned > 0 { anyBoost = true }
        }
        guard anyBoost else { return base }
        let localMax = base.map { $0.freq }.max() ?? 0
        return base.enumerated()
            .map { index, candidate in
                (candidate: candidate,
                 lifted: FrequencyAdjustEngine.liftedFreq(base: candidate.freq,
                                                          count: counts[index], localMax: localMax),
                 learned: counts[index], order: index)
            }
            .sorted { a, b in
                // 抬升词频高的在前；平分时学习次数多的在前（用户反复选的压过词库天然顶字）；
                // 仍相等保持原有顺序（稳定，不让候选每击键都在抖）
                if a.lifted != b.lifted { return a.lifted > b.lifted }
                if a.learned != b.learned { return a.learned > b.learned }
                return a.order < b.order
            }
            .map {
                Candidate(text: $0.candidate.text, code: $0.candidate.code,
                          annotation: $0.candidate.annotation, freq: $0.lifted,
                          sourceSchemeId: $0.candidate.sourceSchemeId,
                          isUserWord: $0.candidate.isUserWord, userFreq: $0.candidate.userFreq)
            }
    }

    // MARK: - 长串词图兜底

    /// 是否启用长串词图兜底（只在常规查询落空时触发，天然正向，可一键关回老行为）
    private static let enableLatticeFallback = true
    /// 短于这个长度的串，前缀查询足以覆盖，不必劳动词图
    private static let latticeMinInputLength = 5
    /// 长于这个长度的串不再切：词图是 O(串长²) 的词库扫描，虽然已移到后台串行队列（不再堵主线程），
    /// 但串越长后台耗时与发热越高，仍需一个上界。64 字（约二十个音节，一整句长话）实测在
    /// 后台队列上毫秒级就算完（lookup 改走 queryExact 后每段只扫精确命中区间，比旧的前缀扫描快得多），
    /// 覆盖用户一口气打完一整句的常见场景；再长（整段粘贴）就该先上屏而不是死攥着一整段。
    /// 超过上限直接落空，等于回到没有词图兜底时的老行为。
    private static let latticeMaxInputLength = 64
    /// 每段拼音精确查词时取的候选上限（只需每段最好的几个词，够用又不拖慢）
    private static let latticeLookupLimit = 100

    /// 二元语法侧车缓存（进程级、线程安全）：词图计算已移到后台串行队列，
    /// 与主线程实例查询路径可能并发访问，故用自带锁的缓存统一持有一份份 mmap
    private static let bigramCache = CharBigramCache()

    /// 输入长度是否落在词图兜底区间内（供 Runtime 判断值不值得起后台任务）。
    /// 与 `computeLattice` 内部的长度护栏同源，两处不会走差
    public static func isLatticeLength(_ count: Int) -> Bool {
        enableLatticeFallback && count >= latticeMinInputLength && count <= latticeMaxInputLength
    }

    /// 后台词图计算所需的只读快照：reader / scheme / profile 全是主线程当前已加载的引用。
    /// DictReader 只读不可变数据（缓存自带锁）、CharBigram 只读 mmap、CodeLattice 纯计算，
    /// 三者都可安全并发调用 —— 这份快照因此可以整体丢到后台队列上跑词图而不触碰任何可变状态
    public struct LatticeJob {
        public let input: String
        public let reader: DictReader
        public let scheme: InstalledScheme
        public let schemeId: String
        public let profile: SchemeProfile
    }

    /// 主线程取一份词图计算快照；方案未加载返回 nil。调用方据此把长串词图移到后台算
    public func latticeJob(input: String, schemeId: String) -> LatticeJob? {
        guard let reader = readers[schemeId], let scheme = schemes[schemeId] else { return nil }
        return LatticeJob(input: input, reader: reader, scheme: scheme,
                          schemeId: schemeId, profile: profile(for: scheme))
    }

    /// 后台安全：对快照跑纯词图计算，不触碰任何 self 可变状态（可在任意线程调用）
    public static func computeLattice(_ job: LatticeJob) -> [Candidate] {
        computeLattice(input: job.input, reader: job.reader, scheme: job.scheme,
                       schemeId: job.schemeId, profile: job.profile)
    }

    /// 常规前缀查询落空时，把整串切成词图，用词频加字级二元语法选出几条整句当候选。
    ///
    /// 切分方式由画像的码制决定：音码按音节连写切，形码按方案声明的 max_code_length 滑窗切，
    /// 音形码两套边并到一起切，三者共用一套束搜索与打分。
    /// 词图纯计算、二元语法侧车只读，查不到侧车就退回「没有二元语法」的排序，仍然比空候选强。
    ///
    /// 静态、无 self：reader / scheme / profile 全部由调用方传入，可安全在后台队列运行
    /// （实例路径 `latticeCandidates` 只是把 `schemes[schemeId]` 补上后转调这里）
    public static func computeLattice(input: String, reader: DictReader, scheme: InstalledScheme,
                                      schemeId: String, profile: SchemeProfile) -> [Candidate] {
        guard enableLatticeFallback,
              input.count >= latticeMinInputLength,
              input.count <= latticeMaxInputLength else { return [] }
        // 词图是 OpenIME 自家的兜底算法（只在常规检索彻底落空时救场），不被外部格式的
        // enable_sentence 旗标开关：那是外部格式 translator 的拼句设置，写它的人不知道
        // 这套词图存在（虎码就写 false，曾把形码长串堵成一个候选都没有）。
        // 字段仍解析进画像（旧 schema.json 兼容），但行为层 OpenIME 自己说了算

        let lmURL = scheme.dictBinPath.deletingLastPathComponent()
            .appendingPathComponent("dict.lm.bin")
        let lm = bigramCache.bigram(sidecar: lmURL)
        // max_phrase_length：超长词条不参与整句拼接（外部格式同名字段的语义）。
        // 雾凇这类写了 99 的等于不限制；没写的方案也不限，与改动前一致
        let maxPhrase = profile.maxPhraseLength
        let lookup: (String) -> [CodeLattice.Word] = { code in
            // 必须走 queryExact（独立精确扫描），不能拿 query(prefix:).filter{code==} 凑：
            // 前缀查询的堆是「整码 + 更长码补全」按词频混排的 top-N，一个音节（如 pin）的整码单字
            // 会被同前缀的高词频长词（拼音 / 品质 / 频道…）整批挤出 top-100，filter 后这一段查不到词、
            // 词图在这个位置断边，整句束搜索覆盖不到末尾 → 长拼音「什么都查不到」（DictReader.queryExact 注释同源）
            reader.queryExact(code: code, limit: latticeLookupLimit)
                .filter { maxPhrase == nil || $0.text.count <= maxPhrase! }
                .map { CodeLattice.Word(text: $0.text, freq: $0.freq) }
        }
        let bigram: (Character, Character) -> Double = { a, b in lm.logProb(a, b) }

        let sentences: [CodeLattice.Sentence]
        switch profile.codeSystem {
        case .phonetic:
            sentences = CodeLattice.segment(input, corpusLogFreq: lm.corpusLogFreq,
                                            lookup: lookup, bigram: bigram)
        case .shape:
            // 没有声明码长（或声明成 0）就无从界定单段跨度，不切，保持老的「无候选」行为
            guard let maxCode = profile.maxCodeLength, maxCode >= 1 else { return [] }
            sentences = CodeLattice.segmentCode(input, maxCodeLength: maxCode,
                                                corpusLogFreq: lm.corpusLogFreq,
                                                lookup: lookup, bigram: bigram)
        case .phonoShape:
            // 音形码要音节段与形码段交替，形码段的跨度同样得方案声明了码长才能界定
            guard let maxCode = profile.maxCodeLength, maxCode >= 1 else { return [] }
            sentences = CodeLattice.segmentMixed(input, maxCodeLength: maxCode,
                                                 corpusLogFreq: lm.corpusLogFreq,
                                                 lookup: lookup, bigram: bigram)
        }
        guard !sentences.isEmpty else { return [] }

        // 分数只用于内部排序，落到候选上换成随名次递减的词频，保证即便下游按 freq 排也维持这个顺序
        let count = sentences.count
        return sentences.enumerated().map { index, sentence in
            Candidate(text: sentence.text, code: input, annotation: nil,
                      freq: (count - index) * 100, sourceSchemeId: schemeId)
        }
    }

    // MARK: - 组句面板：开头一段的可选词

    /// 组句面板用：给定（剩余）编码与方案，返回把「开头这一段」能切成哪些词的全部选项 [(终点, 该段词)]。
    /// 与词图兜底同源（同一份 reader / profile、lookup 走 queryExact），保证面板里用户能手动挑的段
    /// 与自动整句切出来的段完全一致。面板是低频用户交互，主线程调用即可（不必像词图那样丢后台）。
    /// - Returns: 方案未加载 / 剩余码铺不出任何段时返回空数组
    public func leadingOptions(input: String, schemeId: String) -> [(end: Int, words: [CodeLattice.Word])] {
        guard let reader = readers[schemeId], let scheme = schemes[schemeId] else { return [] }
        return Self.computeLeadingOptions(input: input, reader: reader, profile: profile(for: scheme))
    }

    /// 静态纯计算版：与 `computeLattice` 同样只依赖传入的 reader / profile，可脱离实例调用（便于单测）。
    /// 只取词图起点 0 的边，不做束搜索打分（面板把选择权交给用户、不自动裁决），故不需要二元语法侧车。
    public static func computeLeadingOptions(input: String, reader: DictReader,
                                             profile: SchemeProfile) -> [(end: Int, words: [CodeLattice.Word])] {
        guard input.count >= 2 else { return [] }
        // max_phrase_length：与整句拼接一致，超长词条不进面板选项
        let maxPhrase = profile.maxPhraseLength
        let lookup: (String) -> [CodeLattice.Word] = { code in
            reader.queryExact(code: code, limit: latticeLookupLimit)
                .filter { maxPhrase == nil || $0.text.count <= maxPhrase! }
                .map { CodeLattice.Word(text: $0.text, freq: $0.freq) }
        }
        switch profile.codeSystem {
        case .phonetic:
            return CodeLattice.leadingSyllableOptions(input, lookup: lookup)
        case .shape:
            // 没有声明码长（或声明成 0）就无从界定单段跨度，铺不出选项
            guard let maxCode = profile.maxCodeLength, maxCode >= 1 else { return [] }
            return CodeLattice.leadingCodeOptions(input, maxCodeLength: maxCode, lookup: lookup)
        case .phonoShape:
            guard let maxCode = profile.maxCodeLength, maxCode >= 1 else { return [] }
            return CodeLattice.leadingMixedOptions(input, maxCodeLength: maxCode, lookup: lookup)
        }
    }

    /// 组句面板的展示序：把 `leadingOptions` 的 [(终点, 词)] 摊平后按词频全局降序——
    /// 常用的词 / 字排最前，生僻、冷门的统统沉到最后。原来的「终点升序 + 组内词频降序」
    /// 会让最短那段（拼音里就是单字）的所有生僻字挤在常用多字词之前，故改成不分跨度、
    /// 只按词频这一个「常用度」信号排。同文本去重保留词频最高的一条（排序后首现即最高），
    /// 词频并列时终点近的在前、再按文本字典序，保证同一输入每次展平结果完全一致（可复现）。
    /// - Parameters:
    ///   - options: `leadingOptions` / `computeLeadingOptions` 的分组结果
    ///   - limit: 面板一次最多渲染的词数（WrapLayout 非懒布局，太多会卡）
    /// - Returns: 展示序的 (词, 该段消费码长)；options 为空时返回空
    public static func orderedCompositionChoices(
        _ options: [(end: Int, words: [CodeLattice.Word])],
        limit: Int
    ) -> [(text: String, spanLen: Int)] {
        guard limit > 0, !options.isEmpty else { return [] }
        // 摊平成 (文本, 码长, 词频)：词频是排序键，摊平后不再保留跨度分组
        var flat: [(text: String, spanLen: Int, freq: Int)] = []
        for option in options {
            for word in option.words {
                flat.append((word.text, option.end, word.freq))
            }
        }
        // 全局降序：词频高者前；并列时终点近者前、再按文本字典序（与 CodeLattice.prune 同一可复现口径）
        flat.sort { lhs, rhs in
            if lhs.freq != rhs.freq { return lhs.freq > rhs.freq }
            if lhs.spanLen != rhs.spanLen { return lhs.spanLen < rhs.spanLen }
            return lhs.text < rhs.text
        }
        // 同文本去重：排序后首现即词频最高（并列时码长最短）那条，留它就够了
        var seen = Set<String>()
        var result: [(text: String, spanLen: Int)] = []
        result.reserveCapacity(min(flat.count, limit))
        for item in flat where seen.insert(item.text).inserted {
            result.append((item.text, item.spanLen))
            if result.count >= limit { break }
        }
        return result
    }

    /// 实例路径的词图兜底（打字测试等同步查询用）：补上 `schemes[schemeId]` 后转调静态纯计算。
    /// 键盘击键路径已改走后台异步（见 IMERuntime.scheduleLattice），不再从这里同步跑词图
    private func latticeCandidates(input: String, reader: DictReader, schemeId: String,
                                   profile: SchemeProfile) -> [Candidate] {
        guard let scheme = schemes[schemeId] else { return [] }
        return Self.computeLattice(input: input, reader: reader, scheme: scheme,
                                   schemeId: schemeId, profile: profile)
    }
}
