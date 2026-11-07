import Foundation

// MARK: - 码制推断
//
// 用户拖进来的第三方词库不会附带自己属于什么码制的说明：雾凇拼音的 cn_dicts 只有 *.dict.yaml，
// 虎码是一个文件夹，超强快码的词组连编码都不写。以前这两条路径一律硬编 `type: direct`，
// 结果是雾凇的 `ni hao` 被当成形码存进前缀索引 —— 装是装进来了，按音节打却查不到。
//
// 这里按三级证据推断，优先级从高到低：
//   1. 包里自己写明的（`code_system` / `type`）——作者最清楚，直接照办；
//   2. 外部 schema 的 speller / translator 特征——定长顶字上屏是形码的招牌，音节派生 algebra 是音码的招牌；
//   3. 码表本身的统计——抽样一批编码，看能不能整段切成合法拼音音节，这是最硬的地面真相。
// 三级都给不出结论时按形码保守处理：direct 前缀直查对任何码表都成立，最坏只是查得笨一点，不会查不到。
//
// 推断只在安装期跑一次，结果写进 schema.json；运行期读的是画像，不做任何猜测。

public struct CodeSystemInference {

    // MARK: 结果

    public struct Result {
        /// 词库编码怎么查（写进 schema.json 的 type）
        public let type: SchemeType
        /// 输入逻辑属于哪一类（写进 schema.json 的 code_system）
        public let codeSystem: CodeSystem
        /// 编码里的空格是音节分隔符（雾凇 `ni hao`），编译期需要去掉
        public let stripSpaces: Bool
        /// 抽样里「整段能切成合法音节」的比例，仅用于日志与测试断言
        public let phoneticRatio: Double
        public let sampleCount: Int
        /// 中文说明：为什么判成这个码制。写进安装日志，用户看得懂
        public let basis: String
    }

    /// 编码样本的统计特征
    public struct CodeStatistics {
        public var sampleCount = 0
        /// 含空格的编码占比
        public var spaceRatio = 0.0
        /// 去掉空格后能整段切成合法音节的编码占比
        public var phoneticRatio = 0.0
        /// 样本里最长的编码长度
        public var longestCode = 0
    }

    // MARK: 推断主入口

    /// - Parameters:
    ///   - explicitType: 包自己写的 `type`（syllable / double_syllable / direct），nil 表示没写
    ///   - explicitCodeSystem: 包自己写的 `code_system`，nil 表示没写
    ///   - schema: 同目录下的 *.schema.yaml 解析结果，nil 表示没有 schema
    ///   - codes: 抽样出来的编码
    public static func infer(explicitType: String? = nil,
                             explicitCodeSystem: String? = nil,
                             schema: ImportedSchema? = nil,
                             codes: [String]) -> Result {
        let stats = statistics(of: codes)
        let stripSpaces = stats.spaceRatio >= 0.5

        // 1. 包里写明了码制：不再猜
        if let raw = explicitCodeSystem?.lowercased(), let declared = CodeSystem(rawValue: raw) {
            return Result(type: explicitType.flatMap(schemeType(named:)) ?? storageType(for: declared),
                          codeSystem: declared,
                          stripSpaces: stripSpaces,
                          phoneticRatio: stats.phoneticRatio,
                          sampleCount: stats.sampleCount,
                          basis: "方案包写明了 code_system: \(raw)")
        }

        // 2. 包里写明了检索方式：syllable / double_syllable 一定是音码。
        //    direct 只说明「按前缀直查」，形码与音形码都走这条路，所以还要继续往下判码制
        switch explicitType?.lowercased() {
        case "syllable":
            return Result(type: .syllable, codeSystem: .phonetic, stripSpaces: stripSpaces,
                          phoneticRatio: stats.phoneticRatio, sampleCount: stats.sampleCount,
                          basis: "方案包写明了 type: syllable")
        case "double_syllable":
            return Result(type: .doubleSyllable, codeSystem: .phonetic, stripSpaces: stripSpaces,
                          phoneticRatio: stats.phoneticRatio, sampleCount: stats.sampleCount,
                          basis: "方案包写明了 type: double_syllable")
        case "direct":
            // 作者说了走前缀直查：能这么写的只会是形码或音形码，一律按形码存
            return Result(type: .direct, codeSystem: .shape, stripSpaces: stripSpaces,
                          phoneticRatio: stats.phoneticRatio, sampleCount: stats.sampleCount,
                          basis: "方案包写明了 type: direct")
        default:
            break
        }

        // 3. 外部 schema 特征
        var phoneticEvidence: String?
        var shapeEvidence: String?
        if let schema {
            if !schema.initials.isEmpty && !schema.finals.isEmpty {
                phoneticEvidence = "speller 里声母表与韵母表齐全"
            } else if hasSyllableAlgebra(schema.algebra) {
                phoneticEvidence = "speller/algebra 里有音节派生规则"
            }
            // 定长顶字上屏是形码的招牌：音码方案的编码长度由音节数决定，不会写死上限。
            // 双拼的上限是 2，落在 3...6 之外，不会被误判成形码
            if let max = schema.maxCodeLength, (3...6).contains(max), schema.enableSentence != true {
                shapeEvidence = "speller/max_code_length = \(max) 且没开整句"
            }
        }

        // 4. 码表统计：地面真相。schema 与码表打架时以码表为准 ——
        //    检索方式最终要落到「这些编码长什么样」上，猜错就查不到字
        let codeSystem: CodeSystem
        var basis: String
        if stats.phoneticRatio >= 0.9, stats.sampleCount > 0 {
            codeSystem = .phonetic
            basis = "抽样 \(stats.sampleCount) 条编码，\(percent(stats.phoneticRatio)) 能整段切成合法拼音音节"
            if let shapeEvidence { basis += "（schema 有 \(shapeEvidence)，但编码本身是音节，按音码检索）" }
        } else if let phoneticEvidence, let shapeEvidence {
            // 音码与形码特征并存，而编码又不是纯音节：音码开头、形码收尾的音形码
            codeSystem = .phonoShape
            basis = "\(phoneticEvidence)，同时 \(shapeEvidence)，而编码只有 \(percent(stats.phoneticRatio)) 像音节"
        } else if let phoneticEvidence {
            codeSystem = .phonetic
            basis = phoneticEvidence
        } else if let shapeEvidence {
            codeSystem = .shape
            basis = shapeEvidence
        } else if stats.sampleCount > 0 {
            codeSystem = .shape
            basis = "抽样 \(stats.sampleCount) 条编码，只有 \(percent(stats.phoneticRatio)) 像音节，按字根序列处理"
        } else {
            codeSystem = .shape
            basis = "没有可抽样的编码，按形码保守处理（前缀直查对任何码表都成立）"
        }

        return Result(type: storageType(for: codeSystem),
                      codeSystem: codeSystem,
                      stripSpaces: stripSpaces,
                      phoneticRatio: stats.phoneticRatio,
                      sampleCount: stats.sampleCount,
                      basis: basis)
    }

    /// 码制到词库检索方式。
    /// 音形码的编码不是纯音节，切不出音节图，只能按前缀直查（超强快码现在就是这么用的）
    public static func storageType(for codeSystem: CodeSystem) -> SchemeType {
        switch codeSystem {
        case .phonetic:              return .syllable
        case .shape, .phonoShape:    return .direct
        }
    }

    public static func schemeType(named raw: String) -> SchemeType? {
        switch raw.lowercased() {
        case "syllable":        return .syllable
        case "double_syllable": return .doubleSyllable
        case "direct":          return .direct
        default:                return nil
        }
    }

    /// algebra 里出现音节派生规则（简拼、模糊音、韵母改写）就说明这是音码方案。
    /// 形码方案的 algebra 要么没有，要么只处理字根，不会碰到元音
    static func hasSyllableAlgebra(_ algebra: [String]) -> Bool {
        algebra.contains { rule in
            let lower = rule.lowercased()
            guard lower.hasPrefix("abbrev/") || lower.hasPrefix("derive/")
                || lower.hasPrefix("xform/") || lower.hasPrefix("fuzz/") else { return false }
            return lower.contains("[aeiou]") || lower.contains("ng") || lower.contains("[zcs]h")
        }
    }

    // MARK: 统计

    public static func statistics(of codes: [String]) -> CodeStatistics {
        var stats = CodeStatistics()
        guard !codes.isEmpty else { return stats }
        var spaced = 0
        var phonetic = 0
        for code in codes {
            stats.sampleCount += 1
            if code.contains(" ") { spaced += 1 }
            let compact = code.filter { !$0.isWhitespace }.lowercased()
            stats.longestCode = max(stats.longestCode, compact.count)
            guard !compact.isEmpty, compact.allSatisfy({ $0.isLetter }) else { continue }
            if isSyllableSequence(compact) { phonetic += 1 }
        }
        stats.spaceRatio = Double(spaced) / Double(stats.sampleCount)
        stats.phoneticRatio = Double(phonetic) / Double(stats.sampleCount)
        return stats
    }

    /// 一个编码能不能整段切成合法拼音音节（动态规划，回溯宽度取最长音节 6 个字母）
    static func isSyllableSequence(_ code: String) -> Bool {
        let chars = Array(code)
        guard !chars.isEmpty else { return false }
        var reachable = [Bool](repeating: false, count: chars.count + 1)
        reachable[0] = true
        for end in 1...chars.count {
            for start in max(0, end - 6)..<end where reachable[start] {
                if syllableSet.contains(String(chars[start..<end])) {
                    reachable[end] = true
                    break
                }
            }
        }
        return reachable[chars.count]
    }

    private static let syllableSet: Set<String> = Set(PinyinSyllables.all)

    private static func percent(_ ratio: Double) -> String {
        "\(Int((ratio * 100).rounded()))%"
    }

    // MARK: 抽样

    /// 从一份词库文本里抽样编码。只读 front matter 声明的 code 列，读不出就返回空
    ///
    /// 抽样上限默认 2000 条：够判比例，又不至于把整张大表读进内存
    public static func sampleCodes(inContent content: String, limit: Int = 2000) -> [String] {
        let front = DictHeaderParser.parse(content)
        let declared = front.header.columns
        // 没声明 columns 的老文件按 text/code/weight 三列排（与 DictCompiler 的口径一致）
        let colCode = declared.isEmpty ? 1 : (declared.firstIndex(of: "code") ?? -1)
        guard colCode >= 0 else { return [] }

        let lines = DictHeaderParser.splitLines(content)
        var sample: [String] = []
        var index = front.dataStartIndex
        while index < lines.count, sample.count < limit {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            index += 1
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            let parts = trimmed.components(separatedBy: "\t")
            guard parts.count > colCode else { continue }
            let code = parts[colCode].trimmingCharacters(in: .whitespaces)
            if !code.isEmpty { sample.append(code) }
        }
        return sample
    }

    /// 从若干词库文件里抽样。只读每个文件的开头一段，大表（几十万行）也不吃内存
    ///
    /// 额度按文件平分，不让第一张表吃光：雾凇的 cn_dicts/8105 是单字表，编码里一个空格都没有，
    /// 而 cn_dicts/base 的多字词条才是「ni hao」这种空格分隔音节的写法。
    /// 只看第一张表就判不出「要不要去空格」，编出来的词库输入侧对不上
    ///
    /// - Parameter urls: 已经顺着 import_tables 展开的文件列表（调用方用
    ///   `DictCompiler.expandImportTables` 展开），否则只能看到那张不装词的壳文件
    public static func sampleCodes(fromFiles urls: [URL], limit: Int = 2000,
                                  headBytes: Int = 512 * 1024) -> [String] {
        guard !urls.isEmpty else { return [] }
        // 每张表至少抽 64 条：表多到额度平分不清时，宁肯少抽几张也不能一张只抽一条
        let perFile = max(64, limit / urls.count)
        var sample: [String] = []
        for url in urls {
            guard sample.count < limit else { break }
            guard let head = headText(of: url, maxBytes: headBytes) else { continue }
            sample.append(contentsOf: sampleCodes(inContent: head,
                                                  limit: min(perFile, limit - sample.count)))
        }
        return sample
    }

    /// 读文件开头 maxBytes 字节。截断可能落在半行上，末行丢弃
    ///
    /// 丢末行要在字节上做：Swift 把 CRLF 当成一个字素，`lastIndex(of: "\n")` 在
    /// Windows 换行的词库上一个也找不到（虎码的 tiger.dict.yaml 就是 CRLF），
    /// 那样会把整个数据区截掉，抽样得到 0 条，码制推断只能瞎猜
    private static func headText(of url: URL, maxBytes: Int) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maxBytes), !data.isEmpty else { return nil }
        var payload = data
        if data.count >= maxBytes, let cut = payload.lastIndex(of: 0x0A) {
            payload = Data(payload[payload.startIndex..<cut])
        }
        return String(decoding: payload, as: UTF8.self)
    }

    // MARK: 生成 OpenIME 的 schema.yaml

    /// 把推断结果与外部 schema 里读到的输入规则，写成 OpenIME 自己的扁平 schema.yaml
    ///
    /// 只写读得到的字段：缺失的一律省略，运行期由 `SchemeProfile` 回落到码制默认值。
    /// 值需要引号时用双引号包起来（`delimiter: " '"` 这种），读回来时由 `YAMLSchemaParser` 去掉
    public static func schemaYAML(result: Result, schema: ImportedSchema?) -> String {
        var lines: [String] = []
        lines.append("type: \(result.type.rawValue)")
        lines.append("code_system: \(result.codeSystem.rawValue)")
        if result.stripSpaces { lines.append("normalize_code: strip_spaces") }

        if let alphabet = schema?.alphabet, !alphabet.isEmpty {
            lines.append("alphabet: \(quoted(alphabet))")
        }
        if let delimiter = schema?.delimiter, !delimiter.isEmpty {
            lines.append("delimiter: \(quoted(delimiter))")
        }
        if let max = schema?.maxCodeLength, max > 0 {
            lines.append("max_code_length: \(max)")
        }
        if let autoSelect = schema?.autoSelect {
            lines.append("auto_select: \(autoSelect)")
        }
        if let autoClear = schema?.autoClear, !autoClear.isEmpty {
            lines.append("auto_clear: \(quoted(autoClear))")
        }
        if let maxPhrase = schema?.maxPhraseLength, maxPhrase > 0 {
            lines.append("max_phrase_length: \(maxPhrase)")
        }
        // enable_sentence 故意不写进扁平 schema：它是外部格式 translator 的拼句开关，
        // 而整句候选在 OpenIME 里是自家的词图兜底算法（只在常规检索落空时救场），
        // 不该被数据源的旗标开关。推断码制时它仍作为特征证据被读（见 infer），
        // 但行为层不再照搬 —— OpenIME 是主体，外部词库只贡献需要的字段
        if let quality = schema?.initialQuality {
            lines.append("initial_quality: \(quality)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func quoted(_ value: String) -> String {
        "\"" + value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
