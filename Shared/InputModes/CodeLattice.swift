import Foundation

// MARK: - 长串切分（词图）
//
// 常规前缀查询的语义是「词库里的 code 以整串输入为前缀」。输入一旦长过词库里最长的那个词，
// 就没有任何 code 能拿它当前缀，于是一条候选都出不来（八位以上长串打不出字就是这么来的）。
// 这里换一种切法：把长串铺成一张词图，每个位置向后枚举「能成词的一段编码」，
// 再用词频加字级二元语法给整条切分打分，束搜索选出分数最高的几条整句。
//
// 两种编码的「一段」定义不同，但束搜索的骨架完全一样，所以共用一套：
//   拼音（syllable）：一段必须是若干个合法音节的连写，用 segment，边由音节表铺出来；
//   形码（direct）：编码没有音节结构，一段就是 1 到 max_code_length 个字母，用 segmentCode。
//
// 这个模块只做纯计算：音节表来自 PinyinSyllables，词表和二元语法都由调用方注入，
// 因此既方便单测（手搓小词库就能验证切分对不对），也方便日后换更好的语言模型。

public enum CodeLattice {

    /// 词图里的一条边所对应的词：文本 + 词频（来自词库中精确匹配这段编码的词条）
    public struct Word: Equatable {
        public let text: String
        public let freq: Int
        public init(text: String, freq: Int) {
            self.text = text
            self.freq = freq
        }
    }

    /// 一条切分结果：组成好的整句 + 内部打分（分数只用于排序，调用方不必关心量纲）
    public struct Sentence: Equatable {
        public let text: String
        public let score: Double
        public init(text: String, score: Double) {
            self.text = text
            self.score = score
        }
    }

    /// 束搜索里一条走到中途的部分整句
    private struct State {
        let text: String
        let score: Double
        let lastChar: Character?   // 供跨词边界的二元语法打分用
    }

    static let syllables: Set<String> = Set(PinyinSyllables.all)

    /// 最长音节的字母数（zhuang / chuang 这类，用来限定单个音节的枚举长度）
    static let maxSyllableLen: Int = PinyinSyllables.all.map { $0.count }.max() ?? 6

    /// 把整串拼音切成词图，束搜索出最多 topN 条覆盖全串的整句。
    ///
    /// - Parameters:
    ///   - input: 全小写、无声调、无分隔符的拼音串（如 nihaomashijie）
    ///   - maxWordSyllables: 一个词最多由几个音节组成，限定词图边的跨度（默认 4，够覆盖绝大多数词）
    ///   - beamWidth: 每个位置保留的部分整句条数，越大越准但越慢
    ///   - topN: 最终返回几条整句
    ///   - corpusLogFreq: 语料总词频的对数，用来把每个词的词频归一化成「概率」再取对数。
    ///     没有它的话，分数就是各词 log(词频) 直接相加，会一味奖励「切得越碎越好」
    ///     （三个高频单字的 log 之和能盖过一个真实词），归一化后每多用一个词都扣同样的常数，
    ///     不同词数的切分才可比。生产环境应传词库编译期算出的真实总频对数。
    ///   - lookup: 给定一段拼音（若干音节连写），返回精确匹配这段拼音的词；查不到返回空数组
    ///   - bigram: 给定相邻两个汉字，返回它们的 log 概率（越常用越大）；没有数据时应返回一个偏小的缺省值
    /// - Returns: 按分数从高到低排列的整句；无法完整切分（末尾还差半个音节等）时返回空数组
    public static func segment(_ input: String,
                               maxWordSyllables: Int = 4,
                               beamWidth: Int = 8,
                               topN: Int = 5,
                               corpusLogFreq: Double = 16,
                               lookup: (String) -> [Word],
                               bigram: (Character, Character) -> Double) -> [Sentence] {
        let chars = Array(input.lowercased())
        let n = chars.count
        // 太短的串常规前缀查询就能搞定，轮不到词图兜底；这里只处理确实切得开的长串
        guard n >= 2, maxWordSyllables >= 1, beamWidth >= 1, topN >= 1 else { return [] }

        let edges = buildSyllableEdges(chars: chars, maxWordSyllables: maxWordSyllables, lookup: lookup)
        guard !edges.isEmpty else { return [] }
        return runBeam(chars: chars, edges: edges, beamWidth: beamWidth, topN: topN,
                       corpusLogFreq: corpusLogFreq, bigram: bigram)
    }

    /// 把整串形码切成词图，束搜索出最多 topN 条覆盖全串的整句。
    ///
    /// 形码（五笔 / 虎码 / 快码 / 仓颉这类）没有音节结构，一个词的编码就是若干字母，
    /// 长度不超过方案声明的 max_code_length。所以这里的「一段」不是音节连写，
    /// 而是从每个起点向后取 1 到 maxCodeLength 个字母，凡是词库里精确存在的都连一条边。
    /// 打分与束搜索和拼音完全共用一套：字级二元语法看的是切出来的汉字，与编码方式无关。
    ///
    /// - Parameters:
    ///   - input: 全小写的形码串（如 tujaoivj）
    ///   - maxCodeLength: 单个词编码的最大字母数，来自方案 schema（虎码 / 快码都是 4）
    ///   - 其余参数含义与 segment 一致
    /// - Returns: 按分数从高到低排列的整句；无法用词库里的编码铺满全串时返回空数组
    public static func segmentCode(_ input: String,
                                   maxCodeLength: Int,
                                   beamWidth: Int = 8,
                                   topN: Int = 5,
                                   corpusLogFreq: Double = 16,
                                   lookup: (String) -> [Word],
                                   bigram: (Character, Character) -> Double) -> [Sentence] {
        let chars = Array(input.lowercased())
        let n = chars.count
        guard n >= 2, maxCodeLength >= 1, beamWidth >= 1, topN >= 1 else { return [] }

        let edges = buildFixedCodeEdges(chars: chars, maxCodeLength: maxCodeLength, lookup: lookup)
        guard !edges.isEmpty else { return [] }
        return runBeam(chars: chars, edges: edges, beamWidth: beamWidth, topN: topN,
                       corpusLogFreq: corpusLogFreq, bigram: bigram)
    }

    /// 把整串音形码切成词图：每个起点既试「音节段」也试「定长形码段」，两套边合并后共用一套束搜索。
    ///
    /// 音形码（超强快码这类）的编码是「音码开头 + 形码补齐」交替连写：单靠音节切不开
    /// （形码段根本不是音节），单靠定长滑窗也切不开（音码段的长度不由码长决定）。
    /// 这里把 `segment` 与 `segmentCode` 各自铺的边并到一起，同一段编码两种解释都留着，
    /// 到底走哪种由词库能不能查到词、以及打分说了算。
    ///
    /// - Parameters:
    ///   - input: 全小写的音形码串
    ///   - maxCodeLength: 单个形码段的最大字母数，来自方案画像
    ///   - 其余参数含义与 `segment` 一致
    /// - Returns: 按分数从高到低排列的整句；铺不满全串时返回空数组
    public static func segmentMixed(_ input: String,
                                    maxCodeLength: Int,
                                    maxWordSyllables: Int = 4,
                                    beamWidth: Int = 8,
                                    topN: Int = 5,
                                    corpusLogFreq: Double = 16,
                                    lookup: (String) -> [Word],
                                    bigram: (Character, Character) -> Double) -> [Sentence] {
        let chars = Array(input.lowercased())
        let n = chars.count
        guard n >= 2, maxCodeLength >= 1, maxWordSyllables >= 1, beamWidth >= 1, topN >= 1 else { return [] }

        let edges = mergedEdges(
            buildSyllableEdges(chars: chars, maxWordSyllables: maxWordSyllables, lookup: lookup),
            buildFixedCodeEdges(chars: chars, maxCodeLength: maxCodeLength, lookup: lookup))
        guard !edges.isEmpty else { return [] }
        return runBeam(chars: chars, edges: edges, beamWidth: beamWidth, topN: topN,
                       corpusLogFreq: corpusLogFreq, bigram: bigram)
    }

    // MARK: - 组句面板：开头一段的可选词

    /// 组句面板用：给定（剩余）编码，返回把「开头这一段」能切成哪些词的全部选项 [(终点, 该段的词)]。
    /// 与 segment / segmentCode / segmentMixed 复用同一套「单起点铺边」逻辑（syllableEdges），但只铺起点 0
    /// 一个位置的边 —— 既保证面板里用户能手动挑的段与整句词图自动切出来的段完全一致（同一份 lookup、
    /// 同一套音节规则），又不必为整串每个起点都铺一遍：长拼音剩余码下那是主线程上一次很重的同步计算，
    /// 进组句 / 每选一段 / 每撤销都重跑，会把键盘扩展拖到被系统杀掉（= 被别的键盘顶掉）。
    /// 单起点的开销只跟 maxWordSyllables 有关，与整串长度无关。
    /// 束搜索打分在这里用不上：面板把选择权交给用户、不做自动裁决，故只枚举不需 bigram。
    /// 终点近的排前面（与 build* 一致），同一终点的词按 lookup 原序（词频降序）。
    ///
    /// - Parameters:
    ///   - input: 剩余编码（全小写、无声调、无分隔符），起点即这段的开头
    ///   - 其余参数含义与 segment 一致
    /// - Returns: 开头一段的可选 (终点, 词列表)；铺不出任何段时返回空
    public static func leadingSyllableOptions(_ input: String,
                                              maxWordSyllables: Int = 4,
                                              lookup: (String) -> [Word]) -> [(end: Int, words: [Word])] {
        let chars = Array(input.lowercased())
        guard !chars.isEmpty, maxWordSyllables >= 1 else { return [] }
        return syllableEdges(from: 0, chars: chars, maxWordSyllables: maxWordSyllables, lookup: lookup)
    }

    /// 形码版的「开头一段可选词」：与 segmentCode 复用 fixedCodeEdges 的单起点铺边，只铺起点 0
    ///（不为整串每个起点铺满，理由同 leadingSyllableOptions）。参数含义与 segmentCode 一致。
    public static func leadingCodeOptions(_ input: String,
                                          maxCodeLength: Int,
                                          lookup: (String) -> [Word]) -> [(end: Int, words: [Word])] {
        let chars = Array(input.lowercased())
        guard !chars.isEmpty, maxCodeLength >= 1 else { return [] }
        return fixedCodeEdges(from: 0, chars: chars, maxCodeLength: maxCodeLength, lookup: lookup)
    }

    /// 音形码版的「开头一段可选词」：只铺起点 0 的音节段 + 定长形码段，再用 mergedEdges 合并这一处
    ///（不为整串铺满，理由同 leadingSyllableOptions）。参数含义与 segmentMixed 一致。
    public static func leadingMixedOptions(_ input: String,
                                           maxCodeLength: Int,
                                           maxWordSyllables: Int = 4,
                                           lookup: (String) -> [Word]) -> [(end: Int, words: [Word])] {
        let chars = Array(input.lowercased())
        guard !chars.isEmpty, maxCodeLength >= 1, maxWordSyllables >= 1 else { return [] }
        let merged = mergedEdges(
            [0: syllableEdges(from: 0, chars: chars, maxWordSyllables: maxWordSyllables, lookup: lookup)],
            [0: fixedCodeEdges(from: 0, chars: chars, maxCodeLength: maxCodeLength, lookup: lookup)])
        return merged[0] ?? []
    }

    // MARK: - 束搜索骨架（拼音 / 形码共用）

    /// 给定铺好的词图边，按位置从前往后推进束搜索，返回覆盖全串的整句。
    ///
    /// 走到位置 i 时，先把该位置的部分整句裁到束宽（此前所有更早位置的贡献都已汇入 beams[i]，
    /// 此刻裁剪不会漏掉更优路径），再沿词图边向后扩展。
    private static func runBeam(chars: [Character],
                                edges: [Int: [(end: Int, words: [Word])]],
                                beamWidth: Int,
                                topN: Int,
                                corpusLogFreq: Double,
                                bigram: (Character, Character) -> Double) -> [Sentence] {
        let n = chars.count
        var beams: [[State]] = Array(repeating: [], count: n + 1)
        beams[0] = [State(text: "", score: 0, lastChar: nil)]

        for i in 0..<n {
            prune(&beams[i], width: beamWidth)
            guard !beams[i].isEmpty, let outgoing = edges[i] else { continue }
            for (end, words) in outgoing {
                for state in beams[i] {
                    for word in words {
                        guard let first = word.text.first, let last = word.text.last else { continue }
                        var score = state.score + unigram(word.freq, corpusLogFreq: corpusLogFreq)
                        // 词内部的字间搭配已经体现在这个词的词频里，这里只补「跨词边界」那一对字的搭配，
                        // 它才是区分「你好吗 / 你好那」这类同词频尾巴的关键。
                        if let prev = state.lastChar {
                            score += bigram(prev, first)
                        }
                        beams[end].append(State(text: state.text + word.text,
                                                score: score,
                                                lastChar: last))
                    }
                }
            }
        }

        prune(&beams[n], width: max(beamWidth, topN))
        return beams[n].prefix(topN).map { Sentence(text: $0.text, score: $0.score) }
    }

    // MARK: - 词图构建

    /// 拼音：为每个起点枚举「向后能成词」的边：起点 -> [(终点, 该段拼音对应的词)]
    ///
    /// 从起点 i 出发沿音节边界逐步向后延伸（一个位置可能有多种音节切法，如 xian = xi+an 或 xian，
    /// 用 BFS 全部走到），每延伸出一个终点就把 i 到该终点的整段拼音交给 lookup 查词；
    /// 同一个终点只查一次（内部音节怎么切不影响这段拼音本身，查词结果一样）。
    private static func buildSyllableEdges(chars: [Character],
                                           maxWordSyllables: Int,
                                           lookup: (String) -> [Word]) -> [Int: [(end: Int, words: [Word])]] {
        let n = chars.count
        var edges: [Int: [(end: Int, words: [Word])]] = [:]
        for i in 0..<n {
            let list = syllableEdges(from: i, chars: chars, maxWordSyllables: maxWordSyllables, lookup: lookup)
            if !list.isEmpty { edges[i] = list }
        }
        return edges
    }

    /// 从单个起点 i 出发铺「向后能成词」的音节边：沿音节边界逐步向后延伸（一个位置可能有多种音节切法，
    /// 如 xian = xi+an 或 xian，用 BFS 全部走到），每延伸出一个终点就把 i 到该终点的整段拼音交给 lookup
    /// 查词；同一个终点只查一次。buildSyllableEdges 对每个起点调它铺满整张词图；leadingSyllableOptions
    /// 只对 i=0 调一次 —— 单起点开销只跟 maxWordSyllables 有关、与整串长度无关，长拼音组句不再在主线程白铺整张图。
    private static func syllableEdges(from i: Int, chars: [Character],
                                      maxWordSyllables: Int,
                                      lookup: (String) -> [Word]) -> [(end: Int, words: [Word])] {
        let n = chars.count
        var list: [(end: Int, words: [Word])] = []
        var frontier: [(pos: Int, syllables: Int)] = [(i, 0)]
        var reached = Set<Int>()   // 已经作为终点查过词的位置，避免重复查同一段拼音

        while let (pos, used) = frontier.first {
            frontier.removeFirst()
            guard pos < n, used < maxWordSyllables else { continue }
            let maxLen = min(maxSyllableLen, n - pos)
            for len in 1...maxLen {
                let piece = String(chars[pos..<(pos + len)])
                guard syllables.contains(piece) else { continue }
                let next = pos + len
                if !reached.contains(next) {
                    reached.insert(next)
                    let words = lookup(String(chars[i..<next]))
                    if !words.isEmpty {
                        list.append((end: next, words: words))
                    }
                }
                frontier.append((pos: next, syllables: used + 1))
            }
        }
        // 终点近的排前面，扩展时先铺短词，束裁剪更稳定
        list.sort { $0.end < $1.end }
        return list
    }

    /// 形码：为每个起点枚举 1 到 maxCodeLength 个字母的跨度，凡是词库里精确存在的都连一条边。
    ///
    /// 形码没有音节表可依据，直接按长度滑窗即可；同一段编码可能对应多个词（重码），全部收进来交给打分裁决。
    private static func buildFixedCodeEdges(chars: [Character],
                                            maxCodeLength: Int,
                                            lookup: (String) -> [Word]) -> [Int: [(end: Int, words: [Word])]] {
        let n = chars.count
        var edges: [Int: [(end: Int, words: [Word])]] = [:]
        for i in 0..<n {
            let list = fixedCodeEdges(from: i, chars: chars, maxCodeLength: maxCodeLength, lookup: lookup)
            if !list.isEmpty { edges[i] = list }
        }
        return edges
    }

    /// 从单个起点 i 出发铺 1 到 maxCodeLength 个字母的定长形码边（词库里精确存在的才连边）。
    /// 与 syllableEdges 同理：leadingCodeOptions 只对 i=0 调一次，不为整串铺满。
    private static func fixedCodeEdges(from i: Int, chars: [Character],
                                       maxCodeLength: Int,
                                       lookup: (String) -> [Word]) -> [(end: Int, words: [Word])] {
        let n = chars.count
        var list: [(end: Int, words: [Word])] = []
        let maxLen = min(maxCodeLength, n - i)
        for len in 1...maxLen {
            let end = i + len
            let words = lookup(String(chars[i..<end]))
            if !words.isEmpty {
                list.append((end: end, words: words))
            }
        }
        list.sort { $0.end < $1.end }
        return list
    }

    /// 合并两套词图边（音形码用）：同一起点同一终点的词并成一条边，同词只留一份。
    ///
    /// 两套边查的是同一个 lookup，同一段编码查回来的词与词频完全相同，因此去重留第一份就是留最重的；
    /// 终点近的排前面（与另两个 build 一致），束裁剪才稳定。
    private static func mergedEdges(_ lhs: [Int: [(end: Int, words: [Word])]],
                                    _ rhs: [Int: [(end: Int, words: [Word])]])
        -> [Int: [(end: Int, words: [Word])]] {
        var grouped: [Int: [Int: [Word]]] = [:]
        for source in [lhs, rhs] {
            for (start, list) in source {
                for (end, words) in list {
                    var bucket = grouped[start, default: [:]][end] ?? []
                    for word in words where !bucket.contains(where: { $0.text == word.text }) {
                        bucket.append(word)
                    }
                    grouped[start, default: [:]][end] = bucket
                }
            }
        }
        var edges: [Int: [(end: Int, words: [Word])]] = [:]
        edges.reserveCapacity(grouped.count)
        for (start, byEnd) in grouped {
            edges[start] = byEnd
                .map { (end: $0.key, words: $0.value) }
                .sorted { $0.end < $1.end }
        }
        return edges
    }

    // MARK: - 打分与裁剪

    /// 词频归一化成 log 概率：log(词频) 减去 log(语料总频)。
    /// 减掉的那个常数是「每用一个词」的固定代价，正是它让「一个真实词」能赢过「几个高频单字拼起来」。
    private static func unigram(_ freq: Int, corpusLogFreq: Double) -> Double {
        log(Double(max(freq, 0)) + 1) - corpusLogFreq
    }

    /// 把某个位置的部分整句裁到束宽：同文本只留分数最高的一条，再按分数从高到低截断。
    /// 分数并列时按文本字典序，保证同一输入每次跑出来的结果完全一致（可复现，便于差分验证）。
    private static func prune(_ beam: inout [State], width: Int) {
        guard beam.count > 1 else { return }
        var bestByText: [String: State] = [:]
        for state in beam {
            if let existing = bestByText[state.text], existing.score >= state.score {
                continue
            }
            bestByText[state.text] = state
        }
        var deduped = Array(bestByText.values)
        deduped.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.text < rhs.text
        }
        if deduped.count > width {
            deduped.removeLast(deduped.count - width)
        }
        beam = deduped
    }
}
