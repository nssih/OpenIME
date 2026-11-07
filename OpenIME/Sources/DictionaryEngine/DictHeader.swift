import Foundation

// MARK: - 词库文件头解析
//
// 为什么单独成型：DictCompiler 过去只从 front matter 里捞一个 columns，
// 而外部词库的「通用」恰恰全在这段头部里 —— import_tables 决定这份码表由哪几张表合成
// （雾凇拼音的 ice.dict.yaml 自己不装词，全靠导入 cn_dicts/ 下五张表），
// encoder 决定没有编码的词组怎么从单字码自动派生（超强快码连整句诗都靠它编码）。
// 把这些解析成结构化数据，编译逻辑就不必为每种方案写特例。
//
// 解析原则：只认自己需要的键，读不懂的一律忽略而不是报错 —— 第三方词库千奇百怪，
// 因为一个不认识的字段就整包拒装，比少解析一个字段糟糕得多。
// 逐行去掉行尾 \r 再 trim 判等，因此 LF 与 CRLF 都对（Windows 下整理的外部词库常是 CRLF）。

/// front matter 的三种形态
public enum FrontMatterKind {
    /// 有独立的 `...` 结束标记，词条在其后（外部 .dict.yaml）
    case dictYaml
    /// 只有 `---` 分隔符，词条在其后（OpenIME 单文件格式）
    case openIMESingleFile
    /// 没有任何分隔标记，整个文件都是词条
    case none
}

/// 一份词库文件的头部解析结果 + 词条区从哪一行开始
public struct FrontMatter {
    public let kind: FrontMatterKind
    public let header: DictHeader
    /// 词条区起始行下标（0-based），指向分隔标记之后的第一行
    public let dataStartIndex: Int
    /// 头部覆盖的行范围。跳过统计只看词条区，头部里的 `columns:` 之类不该被当成格式错误的词条
    public let headerLineRange: Range<Int>
}

/// 外部词库 front matter
public struct DictHeader {
    public var name: String?
    public var version: String?
    /// by_weight | original | by_phrase
    public var sort: String?
    /// 本轮只解析并记录，预设词汇合并留待后续
    public var usePresetVocabulary: Bool = false
    /// 原样保留声明顺序，既用于定位数据列，也用于写 columns_meta
    public var columns: [String] = []
    /// 支持子路径与省略后缀（`cn_dicts/8105` 展开成 cn_dicts/8105.dict.yaml）
    public var importTables: [String] = []
    public var encoder: DictEncoder?

    public init() {}
}

/// 词组自动编码规则（外部格式的 encoder）
public struct DictEncoder {
    /// 命中这些正则的编码不收录。超强快码用 `^[iuv].*$|[ao]$` 滤掉临时拼音与反查码，
    /// 否则那些码会混进主码表污染候选
    public var excludePatterns: [String] = []
    /// 按序匹配，第一条命中的生效
    public var rules: [Rule] = []

    public struct Rule {
        /// 词长恰好等于
        public var lengthEqual: Int?
        /// 词长落在闭区间内（对应外部格式的 length_in_range: [4, 99]）
        public var rangeMin: Int?
        public var rangeMax: Int?
        /// 取码公式，如 AaAbBaBb / AaBaCaZa
        public var formula: String = ""

        public func matches(wordLength: Int) -> Bool {
            if let eq = lengthEqual { return eq == wordLength }
            if let lo = rangeMin, let hi = rangeMax { return wordLength >= lo && wordLength <= hi }
            return false
        }
    }

    public init() {}

    /// 词长匹配到的第一条规则
    public func rule(forWordLength length: Int) -> Rule? {
        rules.first { $0.matches(wordLength: length) }
    }

    /// 把 exclude_patterns 预编译成正则。编译一次、逐条词条复用，不在热路径上重复编译
    public func compiledExcludePatterns() -> [NSRegularExpression] {
        excludePatterns.compactMap {
            try? NSRegularExpression(pattern: $0, options: [])
        }
    }
}

public enum DictHeaderParser {

    /// 解析文件头。任何内容都不会抛错：读不出头部就返回 kind == .none、整个文件当词条区
    public static func parse(_ content: String) -> FrontMatter {
        let lines = splitLines(content)

        var dashIndex: Int?
        var dotsIndex: Int?
        for (i, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "---" && dashIndex == nil { dashIndex = i }
            if trimmed == "..." { dotsIndex = i; break }
        }

        let kind: FrontMatterKind
        let dataStart: Int
        let headerRange: Range<Int>
        if let dots = dotsIndex {
            kind = .dictYaml
            dataStart = dots + 1
            headerRange = 0..<dots
        } else if let dash = dashIndex {
            kind = .openIMESingleFile
            dataStart = dash + 1
            headerRange = 0..<dash
        } else {
            kind = .none
            dataStart = 0
            headerRange = 0..<0
        }

        var header = DictHeader()
        if kind != .none {
            fill(&header, lines: Array(lines[headerRange]))
        }
        return FrontMatter(kind: kind, header: header,
                               dataStartIndex: dataStart, headerLineRange: headerRange)
    }

    /// 按行切分并去掉行尾 \r。不用 CharacterSet.newlines 切分 ——
    /// 那样 CRLF 会把 \r 也当分隔符，凭空多出一行空行，报告里的行号就和文件对不上了
    public static func splitLines(_ content: String) -> [String] {
        content.components(separatedBy: "\n").map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
    }

    // MARK: - 头部逐行解析

    /// 头部里正在解析的块
    private enum Block {
        case none
        case columns
        case importTables
        case encoderExclude
        case encoderRules
    }

    private static func fill(_ header: inout DictHeader, lines: [String]) {
        var block: Block = .none
        var encoder = DictEncoder()
        var hasEncoder = false
        var currentRule: DictEncoder.Rule?

        // 遇到新块时把攒着的规则收尾
        func flushRule() {
            if let rule = currentRule, !rule.formula.isEmpty {
                encoder.rules.append(rule)
            }
            currentRule = nil
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            let indent = line.prefix(while: { $0 == " " || $0 == "\t" }).count

            // 顶层键：结束上一个块
            if indent == 0 {
                flushRule()
                block = .none
                guard let colon = trimmed.range(of: ":") else { continue }
                let key = String(trimmed[trimmed.startIndex..<colon.lowerBound])
                    .trimmingCharacters(in: .whitespaces)
                let value = cleanValue(String(trimmed[colon.upperBound...]))
                switch key {
                case "name":                  header.name = value.isEmpty ? nil : value
                case "version":               header.version = value.isEmpty ? nil : value
                case "sort":                  header.sort = value.isEmpty ? nil : value
                case "use_preset_vocabulary": header.usePresetVocabulary = (value == "true")
                case "columns":               block = .columns
                case "import_tables":         block = .importTables
                case "encoder":
                    hasEncoder = true
                    block = .encoderExclude   // 子块由下面的缩进行决定，先置一个非 .none 的值
                default:                      break
                }
                continue
            }

            switch block {
            case .columns:
                guard trimmed.hasPrefix("-") else { block = .none; continue }
                let col = cleanValue(String(trimmed.dropFirst()))
                if !col.isEmpty { header.columns.append(col) }

            case .importTables:
                guard trimmed.hasPrefix("-") else { block = .none; continue }
                let table = cleanValue(String(trimmed.dropFirst()))
                if !table.isEmpty { header.importTables.append(table) }

            case .encoderExclude, .encoderRules:
                // encoder 内部：先看是不是切换了子块
                if let colon = trimmed.range(of: ":"), !trimmed.hasPrefix("-") {
                    let key = String(trimmed[trimmed.startIndex..<colon.lowerBound])
                        .trimmingCharacters(in: .whitespaces)
                    let value = cleanValue(String(trimmed[colon.upperBound...]))
                    switch key {
                    case "exclude_patterns":
                        flushRule()
                        block = .encoderExclude
                        continue
                    case "rules":
                        flushRule()
                        block = .encoderRules
                        continue
                    case "formula":
                        // 属于当前正在攒的规则
                        currentRule?.formula = value
                        continue
                    case "length_equal":
                        // 单行规则（极少见）：不带列表符直接写
                        if currentRule == nil { currentRule = DictEncoder.Rule() }
                        currentRule?.lengthEqual = Int(value)
                        continue
                    case "length_in_range":
                        if currentRule == nil { currentRule = DictEncoder.Rule() }
                        let (lo, hi) = parseRange(value)
                        currentRule?.rangeMin = lo
                        currentRule?.rangeMax = hi
                        continue
                    default:
                        break
                    }
                }

                if trimmed.hasPrefix("-") {
                    let item = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
                    if block == .encoderExclude {
                        let pattern = cleanValue(item)
                        if !pattern.isEmpty { encoder.excludePatterns.append(pattern) }
                    } else {
                        // rules 列表：每个 "-" 起一条新规则，行内可能直接带 length_equal / length_in_range
                        flushRule()
                        var rule = DictEncoder.Rule()
                        if let colon = item.range(of: ":") {
                            let key = String(item[item.startIndex..<colon.lowerBound])
                                .trimmingCharacters(in: .whitespaces)
                            let value = cleanValue(String(item[colon.upperBound...]))
                            switch key {
                            case "length_equal":    rule.lengthEqual = Int(value)
                            case "length_in_range":
                                let (lo, hi) = parseRange(value)
                                rule.rangeMin = lo
                                rule.rangeMax = hi
                            case "formula":         rule.formula = value
                            default: break
                            }
                        }
                        currentRule = rule
                    }
                }

            case .none:
                continue
            }
        }

        flushRule()
        if hasEncoder { header.encoder = encoder }
    }

    /// `[4, 99]` 解成 (4, 99)
    private static func parseRange(_ raw: String) -> (Int?, Int?) {
        let body = raw.trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
        let parts = body.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2 else { return (nil, nil) }
        return (Int(parts[0]), Int(parts[1]))
    }

    /// 去引号、去行尾注释。外部词库里 `- cqkm_cm        #主码表` 这种写法很常见，
    /// 不把注释剥掉就会拿 "cqkm_cm        #主码表" 当表名去找文件
    private static func cleanValue(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespaces)
        if let quote = value.first, quote == "'" || quote == "\"" {
            if let end = value.dropFirst().firstIndex(of: quote) {
                return String(value[value.index(after: value.startIndex)..<end])
            }
            return String(value.dropFirst())
        }
        for separator in [" #", "\t#"] {
            if let hash = value.range(of: separator) {
                value = String(value[value.startIndex..<hash.lowerBound])
                break
            }
        }
        return value.trimmingCharacters(in: .whitespaces)
    }
}

// MARK: - 取码公式

/// 外部格式 encoder 的 formula 语义：
/// 大写字母 = 词里第几个字（A 第 1 字、B 第 2 字、C 第 3 字、Z 末字），
/// 小写字母 = 该字编码的第几位（a 第 1 位、b 第 2 位、c 第 3 位、z 末位）。
/// 于是 `AaAbBaBb` = 二字词各取前两码，`AaBaCaZa` = 多字词取前三字首码加末字首码。
public enum CodeFormula {

    /// 按公式派生编码。任一字缺码、或公式要的位置超出实际码长，都返回 nil（宁可不派生，也不写半截码）
    /// - Parameter charCodes: 词里每个字的编码，顺序与词一致
    public static func derive(formula: String, charCodes: [String]) -> String? {
        guard !formula.isEmpty, !charCodes.isEmpty else { return nil }
        var result = ""
        var current: String?
        let upperA = Unicode.Scalar("A").value
        let lowerA = Unicode.Scalar("a").value

        for scalar in formula.unicodeScalars {
            if scalar >= "A" && scalar <= "Z" {
                let index: Int
                if scalar == "Z" {
                    index = charCodes.count - 1
                } else {
                    index = Int(scalar.value - upperA)
                }
                guard index < charCodes.count else { return nil }
                current = charCodes[index]
            } else if scalar >= "a" && scalar <= "z", let code = current {
                let position: Int
                if scalar == "z" {
                    position = code.count - 1
                } else {
                    position = Int(scalar.value - lowerA)
                }
                guard position < code.count else { return nil }
                let idx = code.index(code.startIndex, offsetBy: position)
                result.append(code[idx])
            } else {
                // 公式里出现无法理解的字符（小写字母出现在任何大写字母之前也属于此类）
                return nil
            }
        }
        return result.isEmpty ? nil : result
    }
}
