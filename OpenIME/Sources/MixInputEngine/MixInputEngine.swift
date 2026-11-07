import Foundation

// MARK: - 混打引擎
// 多方案并行查询、候选融合、去重、按优先级排序

public final class MixInputEngine {

    private let candidateEngine: CandidateEngine

    public init(candidateEngine: CandidateEngine) {
        self.candidateEngine = candidateEngine
    }

    // MARK: - 混打查询

    /// - Parameters:
    ///   - input: 用户输入的编码串
    ///   - primarySchemeId: 主方案（永远排在最前）
    ///   - mixConfigs: 参与方案配置（有序，顺序即优先级）
    ///   - allowLattice: 透传给每个方案的查询（见 CandidateEngine.query）；
    ///     双拼逐条读音查询时传 false，避免词图扫描被成倍放大
    public func query(
        input: String,
        primarySchemeId: String,
        mixConfigs: [MixSchemeConfig],
        limit: Int = 80,
        allowLattice: Bool = true
    ) -> [MixCandidate] {

        // 主方案查询
        var resultsByScheme: [String: [Candidate]] = [:]
        resultsByScheme[primarySchemeId] = candidateEngine.query(
            input: input, schemeId: primarySchemeId, limit: limit,
            allowLattice: allowLattice
        )

        // 参与方案查询
        for config in mixConfigs where config.isEnabled && config.id != primarySchemeId {
            // 音码参与方案守门：主方案是形码时用户敲的是形码串（虎码 lc），
            // 而音码检索自带「去尾一字符再查」的部分回退，lc 会被退化成 l，
            // 把 l 开头的一整批与本次输入不相及的拼音候选混进来。
            // 串不是合法拼音前缀就不查该方案；双拼参与方案收的是双拼码，不适用此判定，不拦。
            // 只拦参与方案：主方案的既有语义（含 26 键打错字母时的容错）不动。
            if let profile = candidateEngine.profile(of: config.id),
               profile.codeSystem == .phonetic, profile.type != .doubleSyllable,
               !PinyinSyllables.isValidPinyinPrefix(input) {
                resultsByScheme[config.id] = []
                continue
            }
            resultsByScheme[config.id] = candidateEngine.query(
                input: input, schemeId: config.id, limit: limit,
                allowLattice: allowLattice
            )
        }

        // 融合：主方案优先，参与方案按配置顺序追加
        var merged: [MixCandidate] = []
        var seenTexts = Set<String>()

        // 先加主方案
        for c in resultsByScheme[primarySchemeId] ?? [] {
            if !seenTexts.contains(c.text) {
                merged.append(MixCandidate(candidate: c, colorHex: nil))
                seenTexts.insert(c.text)
            }
        }

        // 再按优先级加参与方案
        let sortedConfigs = mixConfigs
            .filter { $0.isEnabled && $0.id != primarySchemeId }
            .sorted { $0.priority < $1.priority }

        for config in sortedConfigs {
            for c in resultsByScheme[config.id] ?? [] {
                if !seenTexts.contains(c.text) {
                    merged.append(MixCandidate(candidate: c, colorHex: config.candidateColor))
                    seenTexts.insert(c.text)
                }
            }
        }

        return merged
    }
}

// MARK: - 带颜色信息的候选

public struct MixCandidate: Identifiable {
    public let id: UUID = UUID()
    public let candidate: Candidate
    public let colorHex: String?   // nil = 使用默认颜色（主方案）

    public init(candidate: Candidate, colorHex: String?) {
        self.candidate = candidate
        self.colorHex = colorHex
    }

    public var text: String { candidate.text }
    public var code: String { candidate.code }
    public var annotation: String? { candidate.annotation }
    public var sourceSchemeId: String { candidate.sourceSchemeId }
}
