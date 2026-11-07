import Foundation

// MARK: - 候选打分与去重（对应外部格式的 filter 层）
//
// 候选的先后次序散落在好几个地方：词库按权重排、用户词按热度插、自定义词永远前插、
// 整句由词图内部打分。这里把「两条候选谁该排前面」这件事收拢成一个纯函数，
// 顺手补上外部格式的 `filter/uniquifier`（同词去重）与 `filter/single_char`（单字优先）。
//
// 纯函数、无状态、不碰磁盘：给它候选就还你候选，因此可以单独测，也可以在任意一条查询路径上复用。
//
// 没有收进来的两项，是有意为之：
//   - 字级二元语法只在「整句拼接」内部起作用（见 `CodeLattice.runBeam`），它比较的是
//     两种切法哪个更像人话，而不是两条候选谁排前面，量纲与词频不通，不能混进同一个分数；
//   - 预测候选按槽位插入（见 `IMERuntime.pickPredictionSlots`），它的位置表达的是
//     「插到第几位」而不是排序键，参与打分反而会被高频词挤走。

public enum CandidateScoring {

    /// 用户词 / 自定义词的分数起点：必须高过任何词库词频，
    /// 用户调过频的词才不会被一个天生高频的词盖回去（只在本模块 `rankScore` 里参与排序）
    public static let userWordBase = 100_000

    /// 统一的排序分：用户词 > 自定义词的热度 > 词库词频乘方案基础权重
    ///
    /// - Parameter initialQuality: 外部格式的 `translator/initial_quality`。同一个方案内它是常数，
    ///   乘完次序一点不变；它真正起作用是在多方案、多路候选合并的时候 —— 那才是「这个方案的
    ///   候选整体上该不该压过另一个方案」的旋钮。缺省 1.0，旧包没有这个字段时行为不变。
    /// - Parameter isUserWord: 是否用户调过频的词（自定义词走「按点选次数定位次」那条路，不用这个开关）
    public static func rankScore(freq: Int,
                                 initialQuality: Double = 1,
                                 isUserWord: Bool = false,
                                 userFreq: Int = 0) -> Double {
        if isUserWord {
            return Double(userWordBase + userFreq * 10)
        }
        return Double(freq) * max(initialQuality, 0)
    }

    /// 一条候选的排序分（`rankScore(freq:…)` 的便捷入口）
    public static func rankScore(_ candidate: Candidate, initialQuality: Double = 1) -> Double {
        rankScore(freq: candidate.freq,
                  initialQuality: initialQuality,
                  isUserWord: candidate.isUserWord,
                  userFreq: candidate.userFreq)
    }

    /// 同词去重：外部格式 `filter/uniquifier` 的等价物
    ///
    /// 词库里同一个词常常有多条码（形码的多码字、音码的多音字），前缀查询会把它们全部捞上来，
    /// 候选栏里于是出现两三个一模一样的词，白白占掉位置。这里按 text 收拢成一条：
    ///   - 留下排序分最高的那条，所以并入用户词之后再去重，用户调过频的词（isUserWord）总是赢；
    ///     自定义词由 mergeExtras 按位次插入且 text 与词库不重叠，去重不会丢它们；
    ///   - 位置沿用这个词第一次出现的地方，既有排序一点不打乱。
    /// 没有重复时原样返回入参数组，一个候选对象都不新建 —— 击键路径上不该为没发生的事付钱。
    public static func uniquify(_ candidates: [Candidate], initialQuality: Double = 1) -> [Candidate] {
        guard candidates.count > 1 else { return candidates }
        var best: [String: Candidate] = [:]
        var order: [String] = []
        order.reserveCapacity(candidates.count)
        for candidate in candidates {
            if let existing = best[candidate.text] {
                if rankScore(candidate, initialQuality: initialQuality)
                    > rankScore(existing, initialQuality: initialQuality) {
                    best[candidate.text] = candidate
                }
            } else {
                best[candidate.text] = candidate
                order.append(candidate.text)
            }
        }
        guard order.count != candidates.count else { return candidates }
        return order.compactMap { best[$0] }
    }

    /// 单字优先：外部格式 `filter/single_char` 的等价物
    ///
    /// 形码方案里「先顶一个单字再顶下一个」往往比连着打词组更稳，用户想要的是一屏里先看到单字。
    /// 开关关掉时原样返回，候选顺序一个都不变；
    /// 开关打开时也只做一次稳定分区（组内仍按原来的排序分），不重新打分。
    public static func singleCharFirst(_ candidates: [Candidate], enabled: Bool) -> [Candidate] {
        singleCharFirst(candidates, enabled: enabled, text: { $0.text })
    }

    /// 单字优先的通用形态：混打候选带着颜色与来源方案，
    /// 降级成 `Candidate` 再升回来会丢掉这些信息，所以分区逻辑直接对元素类型泛型
    public static func singleCharFirst<T>(_ candidates: [T],
                                          enabled: Bool,
                                          text: (T) -> String) -> [T] {
        guard enabled, candidates.count > 1 else { return candidates }
        let singles = candidates.filter { text($0).count == 1 }
        guard !singles.isEmpty, singles.count != candidates.count else { return candidates }
        return singles + candidates.filter { text($0).count != 1 }
    }
}
