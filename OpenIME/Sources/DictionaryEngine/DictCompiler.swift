import Foundation

// MARK: - 词库二进制格式
//
// dict.bin 结构（v3）：
//
// [Header]  24 bytes
//   magic:      4 bytes  "OIME"
//   version:    2 bytes  0x0003（v3 索引区改为词条偏移表；v1 头部只有 20 字节，旧文件照旧可读）
//   schemeType: 1 byte   0=direct 1=syllable 2=double_syllable
//   reserved:   1 byte
//   entryCount: 4 bytes  UInt32 LE
//   indexOffset:4 bytes  UInt32 LE  (拼音前缀索引区起始位置)
//   dataOffset: 4 bytes  UInt32 LE  (数据区起始位置)
//   tailOffset: 4 bytes UInt32 LE  (数据区之后的附加区起始位置，0 = 无)
//
// [Index]  词条偏移表（v3 起）：entryCount 条 UInt32 LE
//   第 k 条 = 数据区里第 k 个词条相对 dataOffset 的起始偏移。
//   数据区按 code 升序，故偏移表单调递增；查询时对它二分即可定位任一前缀的命中区间，
//   把「多字符前缀线性扫整个两字符桶」的 O(桶大小) 降到 O(log n)。
//   （v2 及更早这里是「前两字符前缀桶」prefixHash(4)+offset(4)+count(2)，多字符前缀要
//     线性扫整桶——拼音热门声母桶几万条、每键重扫，是每键 30~90ms 卡顿的根因；
//     旧文件由读侧在内存补建同构偏移表兼容，见 DictReader。）
//
// [Data]   按编码字典序排列的词条
//   每条:
//     codeLen:   1 byte
//     code:      codeLen bytes  UTF-8
//     textLen:   2 bytes  UInt16 LE
//     text:      textLen bytes  UTF-8
//     annoLen:   2 bytes  UInt16 LE
//     anno:      annoLen bytes  UTF-8 (0 = 无注释)
//     freq:      4 bytes  Int32 LE
//
// [T9Index]  九宫数字码索引（旧版本为拼音方案写的一段尾部附加区，已停用）
//   bucketCount: 2 bytes  UInt16 LE（固定 100 = 前两位数字 00~99）
//   bucketCount x (start(4) + count(4))：桶在偏移表中的起点与条数
//   偏移表: N x UInt32  指向 Data 区的词条偏移，先按数字码升序、同码按 freq 降序
//
// 九宫（T9）键盘形态已从产品与引擎两侧整体下线，新编的词库不再写这段（tailOffset 恒为 0）。
// 已经装好的 v2 文件里它仍在数据区之后留着：读者靠 entryCount 与索引桶边界定位词条，
// 永不踩进这段尾巴；只有「从已编译 dict.bin 补建二元语法侧车」那一趟扫描需要按 tailOffset 收尾（见
// buildLanguageModelIfNeeded），因此这个字段与头部长度都不能动。

public final class DictCompiler {

    public enum CompileError: Error, LocalizedError {
        case emptyDict
        case readFailed(String)
        case writeError(String)

        public var errorDescription: String? {
            switch self {
            case .emptyDict:
                return "词库为空：所有词库文件合并后没有解析出任何词条。请检查文件格式和编码（必须是 UTF-8，列之间用 Tab 分隔）。"
            case .readFailed(let path):
                return "无法读取文件：\(path)。请确认文件未损坏且编码为 UTF-8。"
            case .writeError(let msg):
                return "写入编译结果失败：\(msg)"
            }
        }
    }

    // MARK: - 单文件解析诊断

    public struct FileParseReport {
        public let fileName: String
        public let parsedCount: Int
        public let skippedCount: Int
        public let skippedLines: [SkippedLine]

        public struct SkippedLine {
            public let lineNumber: Int    // 1-based
            public let content: String    // 原始行内容（截断到80字符）
            public let reason: String     // 跳过原因
        }
    }

    // MARK: - 整体编译报告

    public struct CompileReport {
        public let files: [FileParseReport]
        public let totalParsed: Int
        public let totalSkipped: Int
        public let normalizeCode: String?
        public let schemeType: SchemeType
        /// 通过 import_tables 实际导入的表名
        public var importedTables: [String] = []
        /// 声明了却找不到的表（外部格式遇到这种情况会卡死，这里只警告并继续）
        public var missingTables: [String] = []
        /// 由 encoder 规则派生出来的编码条数
        public var derivedCodes: Int = 0
        /// 同词同码重复、被合并掉的条数（外部格式语义：最上面的生效）
        public var mergedDuplicates: Int = 0
        /// 被 exclude_patterns 滤掉的编码条数
        public var excludedCodes: Int = 0
        /// 词库里声明了但 OpenIME 不用的列
        public var ignoredColumns: [String] = []
        /// 是否对「零词频码表」叠加了通用字频（见 overlayFrequency）
        public var frequencyOverlaid: Bool = false
        /// 叠加时命中通用词频语料的多字词条数（0 = 未提供语料或全走几何均值兜底）
        public var overlaidWordFreqHits: Int = 0

        public init(files: [FileParseReport],
                    totalParsed: Int,
                    totalSkipped: Int,
                    normalizeCode: String?,
                    schemeType: SchemeType) {
            self.files = files
            self.totalParsed = totalParsed
            self.totalSkipped = totalSkipped
            self.normalizeCode = normalizeCode
            self.schemeType = schemeType
        }

        public func logText() -> String {
            let dateStr = ISO8601DateFormatter().string(from: Date())
            var lines: [String] = []
            lines.append("=== OpenIME 词库编译日志 ===")
            lines.append("编译时间：\(dateStr)")
            lines.append("方案类型：\(schemeType.displayName)")
            if let n = normalizeCode { lines.append("编码规范化：\(n)") }
            lines.append("")

            for report in files {
                lines.append("── 文件：\(report.fileName)")
                lines.append("   成功解析：\(report.parsedCount) 条")
                if report.skippedCount > 0 {
                    lines.append("   跳过行数：\(report.skippedCount) 行（见下方详情）")
                } else {
                    lines.append("   跳过行数：0（全部解析正常）")
                }
                if !report.skippedLines.isEmpty {
                    lines.append("")
                    lines.append("   跳过详情（最多显示前 30 条）：")
                    for skip in report.skippedLines.prefix(30) {
                        let preview = skip.content.count > 80
                            ? String(skip.content.prefix(80)) + "…"
                            : skip.content
                        lines.append("   第 \(skip.lineNumber) 行：\(skip.reason)")
                        lines.append("         内容：\(preview)")
                    }
                    if report.skippedLines.count > 30 {
                        lines.append("   … 还有 \(report.skippedLines.count - 30) 条跳过行未显示")
                    }
                }
                lines.append("")
            }

            lines.append("── 汇总")
            lines.append("   总词条数：\(totalParsed)")
            lines.append("   总跳过行：\(totalSkipped)")
            if !importedTables.isEmpty {
                lines.append("   导入词表：\(importedTables.count) 张（\(importedTables.joined(separator: "、"))）")
            }
            if !missingTables.isEmpty {
                lines.append("   缺失词表：\(missingTables.joined(separator: "、"))（已跳过，不影响其余词条）")
            }
            if derivedCodes > 0 {
                lines.append("   自动编码：按 encoder 规则派生 \(derivedCodes) 条")
            }
            if mergedDuplicates > 0 {
                lines.append("   重复合并：\(mergedDuplicates) 条（同词同码，保留最上面那条）")
            }
            if excludedCodes > 0 {
                lines.append("   规则过滤：\(excludedCodes) 条编码被 exclude_patterns 排除")
            }
            if !ignoredColumns.isEmpty {
                lines.append("   未使用的列：\(ignoredColumns.joined(separator: "、"))")
            }
            if frequencyOverlaid {
                if overlaidWordFreqHits > 0 {
                    lines.append("   字频叠加：全库词频无区分度，已重排——单字用通用字频表(8105)，多字词命中通用词频语料 \(overlaidWordFreqHits) 条(真实词频)，其余按各字字频几何均值兜底")
                } else {
                    lines.append("   字频叠加：全库词频无区分度，已按通用汉字字频表重排（常用单字靠前、词组按各字字频）")
                }
            }
            if totalParsed == 0 {
                lines.append("")
                lines.append("⚠️  警告：没有解析出任何词条！")
                lines.append("   常见原因：")
                lines.append("   1. 列之间不是 Tab（\\t）分隔，而是空格分隔")
                lines.append("   2. 文件保存时编码不是 UTF-8（如保存成了 GBK / GB2312）")
                lines.append("   3. front matter 中的 columns: 字段顺序与实际数据列不匹配")
                lines.append("   4. 数据行没有在 front matter 的 '...' 结束标记之后")
                lines.append("   5. 文件完全是空的或只有注释行（以 # 开头）")
            }
            lines.append("")
            lines.append("=== 日志结束 ===")
            return lines.joined(separator: "\n")
        }
    }

    // MARK: - 公开接口

    public static func compile(yamlURL: URL, outputURL: URL, schemeType: SchemeType) throws {
        _ = try compileMultipleWithReport(yamlURLs: [yamlURL], outputURL: outputURL, schemeType: schemeType)
    }

    @discardableResult
    public static func compileMultiple(
        yamlURLs: [URL],
        outputURL: URL,
        schemeType: SchemeType,
        normalizeCode: String? = nil,
        resourceRoot: URL? = nil,
        wordFrequencyURL: URL? = nil
    ) throws -> Set<String> {
        let (columns, _) = try compileMultipleWithReport(
            yamlURLs: yamlURLs, outputURL: outputURL,
            schemeType: schemeType, normalizeCode: normalizeCode, resourceRoot: resourceRoot,
            wordFrequencyURL: wordFrequencyURL
        )
        return columns
    }

    /// 编译并返回列名、编译报告，供调用方写日志
    ///
    /// 一份外部词库往往不是自包含的：雾凇拼音的 ice.dict.yaml 自己不装词，
    /// 全靠 import_tables 导入 cn_dicts/ 下五张表；超强快码的词组不写码，全靠 encoder 从单字码派生。
    /// 这两件事都在编译期做完，运行期只管查 —— 第三方方案不用改一行 Swift 就能装进来。
    /// - Parameter resourceRoot: 方案包根目录，用于解析 import_tables 里带子路径的表名（如 `cn_dicts/8105`）。
    ///   不传就只在词库文件自己所在目录找。
    /// - Parameter wordFrequencyURL: 可选的通用词频语料（如雾凇 base.dict.yaml）。仅当本方案是
    ///   「零词频码表」（全库权重无区分度）时才会流式读取它给多字词补真实词频；不传则词组
    ///   走几何均值兜底（与旧行为逐字节一致）。
    public static func compileMultipleWithReport(
        yamlURLs: [URL],
        outputURL: URL,
        schemeType: SchemeType,
        normalizeCode: String? = nil,
        resourceRoot: URL? = nil,
        wordFrequencyURL: URL? = nil
    ) throws -> (Set<String>, CompileReport) {
        // 1. 按 import_tables 递归展开成实际要读的文件，再逐个解析
        //    顺序就是优先级：调用方传入的文件在前，被导入的表按声明顺序在后（外部格式「最上面的权重生效」）
        let expansion = expandImportTables(yamlURLs, resourceRoot: resourceRoot)
        var parsedFiles: [ParsedDictFile] = []
        parsedFiles.reserveCapacity(expansion.urls.count)
        for url in expansion.urls {
            if let content = try? String(contentsOf: url, encoding: .utf8) {
                parsedFiles.append(parseFileContent(content, fileName: url.lastPathComponent))
            } else {
                parsedFiles.append(ParsedDictFile.failed(fileName: url.lastPathComponent))
            }
        }
        let importedTables = expansion.importedTables
        let missingTables = expansion.missingTables

        // 2. 单字码表：encoder 派生词组码要从这里取每个字的码（同一个字多个码时取词频最高的）
        var charCodes: [String: (code: String, freq: Int)] = [:]
        for file in parsedFiles {
            for entry in file.entries where entry.text.count == 1 {
                if let known = charCodes[entry.text], known.freq >= entry.freq { continue }
                charCodes[entry.text] = (entry.code, entry.freq)
            }
        }

        // 3. 逐文件补上自动编码，并汇总词条、列名、跳过详情
        var allEntries: [DictEntry] = []
        var fileReports: [FileParseReport] = []
        var discoveredColumns = Set<String>()
        var ignoredColumns: [String] = []
        var excludePatterns: [NSRegularExpression] = []
        var derivedCodes = 0

        for var file in parsedFiles {
            if let encoder = file.header.encoder {
                excludePatterns.append(contentsOf: encoder.compiledExcludePatterns())
            }
            var skipped = file.skipped
            var parsedCount = file.entries.count

            for pending in file.noCode {
                guard let encoder = file.header.encoder, pending.text.count >= 2 else {
                    skipped.append(.init(lineNumber: pending.lineNumber, content: pending.content,
                                         reason: "编码（code 列）为空"))
                    continue
                }
                let codes = pending.text.map { charCodes[String($0)]?.code }
                guard codes.allSatisfy({ $0 != nil }),
                      let rule = encoder.rule(forWordLength: pending.text.count),
                      let derived = CodeFormula.derive(formula: rule.formula,
                                                           charCodes: codes.compactMap { $0 }) else {
                    skipped.append(.init(lineNumber: pending.lineNumber, content: pending.content,
                                         reason: "无法自动编码：词里有字在码表中找不到编码，或没有匹配词长的 encoder 规则"))
                    continue
                }
                file.entries.append(DictEntry(code: derived, text: pending.text,
                                              freq: pending.freq, annotation: pending.annotation))
                parsedCount += 1
                derivedCodes += 1
            }

            allEntries.append(contentsOf: file.entries)
            discoveredColumns.formUnion(file.columns)
            for col in file.ignoredColumns where !ignoredColumns.contains(col) {
                ignoredColumns.append(col)
            }
            fileReports.append(FileParseReport(fileName: file.fileName, parsedCount: parsedCount,
                                               skippedCount: skipped.count, skippedLines: skipped))
        }

        // 4. 编码规范化（可选）
        if normalizeCode == "strip_spaces" {
            allEntries = allEntries.map { e in
                DictEntry(code: e.code.replacingOccurrences(of: " ", with: ""),
                          text: e.text, freq: e.freq, annotation: e.annotation)
            }
        }

        // 5. exclude_patterns 过滤：临时拼音、反查码（快码里 i/u/v 开头那类）不能混进主码表
        var excludedCodes = 0
        if !excludePatterns.isEmpty {
            let before = allEntries.count
            allEntries = allEntries.filter { entry in
                let range = NSRange(entry.code.startIndex..., in: entry.code)
                return !excludePatterns.contains { $0.firstMatch(in: entry.code, range: range) != nil }
            }
            excludedCodes = before - allEntries.count
        }

        // 6. 同词同码去重（派生码也可能和已有码撞上）
        var mergedDuplicates = 0
        var seen = Set<String>()
        var deduped: [DictEntry] = []
        deduped.reserveCapacity(allEntries.count)
        for entry in allEntries {
            let key = entry.text + "\u{1}" + entry.code
            if seen.contains(key) {
                mergedDuplicates += 1
                continue
            }
            seen.insert(key)
            deduped.append(entry)
        }

        guard !deduped.isEmpty else { throw CompileError.emptyDict }

        // 6.5 通用字/词频叠加：任何「零词频码表」（全库 weight 无区分度，如超强快码全为 1）
        //     都用内置字频表 + 通用词频语料补齐区分度，让常用字/词在候选里靠前。
        //     门控只看「权重是否无区分度」，不看码制——五笔/仓颉/无权重拼音等一样受益；
        //     自带真实权重的码表（虎码、雾凇拼音）不满足此条件，逐字节保持原有排序，绝不覆盖。
        //     还要求去重后至少 2 条：叠加的本质是「给无区分度的多条候选重排序」，单条表无从排序，
        //     改写它反而会把作者声明的真实权重（如 import 合并后唯一存活的那条）无意义地丢掉。
        var frequencyOverlaid = false
        var overlaidWordFreqHits = 0
        var entriesToSort = deduped
        if !CharFrequency.isEmpty, deduped.count > 1, Self.weightsAreUniform(deduped) {
            // 只给「本方案里出现的多字词」流式取真实词频（内存受方案词条数约束，用完即释放）
            var wordFreqs: [String: Int] = [:]
            if let corpusURL = wordFrequencyURL {
                let needed = Set(deduped.lazy.map { $0.text }.filter { $0.count > 1 })
                wordFreqs = WordFrequencyCorpus.loadFrequencies(needed: needed, from: corpusURL)
            }
            entriesToSort = Self.overlayFrequency(deduped, wordFreqs: wordFreqs)
            overlaidWordFreqHits = wordFreqs.count
            frequencyOverlaid = true
        }

        // 7. 排序：编码升序、同码按词频降序，词频也相同时保持词库里的先后
        //    （Swift 的 sorted 不保证稳定，这里显式用原始序号 tie-break，让 sort: by_weight 的结果可重现）
        let sorted = entriesToSort.enumerated().sorted { a, b in
            if a.element.code != b.element.code { return a.element.code < b.element.code }
            if a.element.freq != b.element.freq { return a.element.freq > b.element.freq }
            return a.offset < b.offset
        }.map { $0.element }

        let built = buildBinary(entries: sorted, schemeType: schemeType)
        do {
            try built.data.write(to: outputURL, options: .atomic)
        } catch {
            throw CompileError.writeError(error.localizedDescription)
        }
        writeLanguageModelSidecar(entries: sorted, dictURL: outputURL)
        // v4 侧车：把运行时原本要 O(词库) 现算的两样东西提前到编译期预排，
        // 读取器命中即 O(N)/O(log n)，未命中回退原有扫描（老词库无侧车自动走老路）
        writePrefixTopNSidecar(entries: built.kept, offsets: built.offsets,
                               schemeType: schemeType, dictURL: outputURL)
        writeTextIndexSidecar(entries: built.kept, dictURL: outputURL)

        var report = CompileReport(
            files: fileReports,
            // 总词条数报的是真正写进 dict.bin 的条数：逐文件的 parsedCount 是去重、过滤之前的量，
            // 两者在有重复合并或 exclude_patterns 时会差一截，汇总行必须与安装结果对得上
            totalParsed: sorted.count,
            totalSkipped: fileReports.reduce(0) { $0 + $1.skippedCount },
            normalizeCode: normalizeCode,
            schemeType: schemeType
        )
        report.importedTables = importedTables
        report.missingTables = missingTables
        report.derivedCodes = derivedCodes
        report.mergedDuplicates = mergedDuplicates
        report.excludedCodes = excludedCodes
        report.ignoredColumns = ignoredColumns
        report.frequencyOverlaid = frequencyOverlaid
        report.overlaidWordFreqHits = overlaidWordFreqHits
        return (discoveredColumns, report)
    }

    // MARK: - 通用字/词频叠加（零词频码表专用）
    //
    // 形码 / 音形码码表（如超强快码 cqkm）常常全库 weight 恒定，词频毫无区分度：
    // 运行时 top-N 只能退化成按编码字母序，常用字（好 = hb）被 200 多条 ha* 长码挤出候选。
    // 外部格式靠「八股文」预设词频给这类词库补上区分度；编译期做等价的事——
    //   单字：内置通用汉字字频表（CharFrequency，源自《通用规范汉字表》25 亿字语料字频）；
    //   多字词：通用词频语料（WordFrequencyCorpus，流式读随包的雾凇 base.dict.yaml，55 万词）。
    // 两者合起来给零词频码表叠加真实字/词频，常用字词自然靠前。
    //
    // 门控只看「全库权重是否完全一致」，不看码制：五笔 / 仓颉 / 无权重拼音等一样受益；
    // 虎码、雾凇拼音这类自带真实权重的方案不满足条件，逐字节保持原有排序，绝不覆盖已验收的顺序。
    //
    // 三档尺度（保证排序语义正确、且互不越界）：
    //   单字           = singleCharFreqTier + 字频score   ∈ [1e6, 1e6+count]
    //   covered 词组   = 归一化真实词频                  ∈ [coveredBandFloor, phraseTierMax]
    //   uncovered 词组 = 各字字频几何均值               ∈ [1, count]（count « coveredBandFloor）
    // 于是恒有：单字 > 命中语料的词组 > 未命中的词组，各档内部按真实值正确排序。
    // 单字永远压过词组，保留「敲短码先要单字」的使用直觉；命中语料（真实词频）压过兜底估算，
    // 因为 base 覆盖 cqkm 88.4%，未命中即「55 万词库都没有」的罕见词，排在命中词之后合理。

    /// 单字档基准：叠加后单字词频整体高于任何词组，
    /// 保证码表补全里「简码常用单字」永远排在词组之前（与敲短码先要单字的使用直觉一致）
    private static let singleCharFreqTier = 1_000_000

    /// 词组档上限：严格低于单字档基准，任何词组都排在任何单字之后
    private static var phraseTierMax: Int { singleCharFreqTier - 1 }

    /// covered（命中语料）词组档下限：取单字档基准的一半。
    /// 通用字频表收录约 8105 字，几何均值上限 ≈ count « 500000，
    /// 故 uncovered 词组恒落在 [1, coveredBandFloor) 内，与 covered 档天然不重叠。
    private static var coveredBandFloor: Int { singleCharFreqTier / 2 }

    /// 全库词频是否完全一致（没有任何区分度）——只有这种词库才需要叠加
    static func weightsAreUniform(_ entries: [DictEntry]) -> Bool {
        guard let first = entries.first else { return false }
        return entries.allSatisfy { $0.freq == first.freq }
    }

    /// 给零词频码表叠加通用字/词频。
    /// - 单字：进「单字档」= singleCharFreqTier + 字频score；
    /// - 多字词：命中 wordFreqs 的进「covered 档」（真实词频归一化），未命中的进「uncovered 档」
    ///   （各字字频几何均值兜底）。wordFreqs 为空时所有词组都走兜底，与旧行为逐字节一致。
    /// 未收录的字按 0（单字）/ 1（词组内）计，几何均值与归一化都用对数避免大数溢出。
    static func overlayFrequency(_ entries: [DictEntry], wordFreqs: [String: Int] = [:]) -> [DictEntry] {
        guard !CharFrequency.isEmpty else { return entries }
        // covered 归一化用的动态 log 边界（用本次加载到的真实词频 min/max，不写死任何数值）
        let logBounds: (lo: Double, hi: Double)? = {
            guard !wordFreqs.isEmpty else { return nil }
            let values = wordFreqs.values
            let lo = log(Double(max(values.min() ?? 1, 1)))
            let hi = log(Double(max(values.max() ?? 1, 1)))
            return (lo, hi)
        }()
        return entries.map { entry in
            let chars = Array(entry.text)
            let freq: Int
            if chars.count == 1 {
                freq = singleCharFreqTier + CharFrequency.score(of: chars[0])
            } else if let real = wordFreqs[entry.text], let bounds = logBounds {
                freq = coveredPhraseFreq(realFreq: real, logLo: bounds.lo, logHi: bounds.hi)
            } else {
                freq = wordFrequencyScore(chars)
            }
            return DictEntry(code: entry.code, text: entry.text, freq: freq, annotation: entry.annotation)
        }
    }

    /// covered 词组打分：把真实词频按 log 压缩，用本次语料的动态 [logLo, logHi] 归一化到
    /// [coveredBandFloor, phraseTierMax]。logLo == logHi（只有一个词频值）时统一落到区间中点，避免除零。
    private static func coveredPhraseFreq(realFreq: Int, logLo: Double, logHi: Double) -> Int {
        let span = logHi - logLo
        let ratio = span > 0 ? (log(Double(max(realFreq, 1))) - logLo) / span : 0.5
        let clamped = min(max(ratio, 0), 1)
        let width = Double(phraseTierMax - coveredBandFloor)
        return coveredBandFloor + Int((clamped * width).rounded())
    }

    /// uncovered 词组兜底：各字 score 的几何均值（未收录按 1 计），∈ [1, CharFrequency.count]，
    /// 恒 < coveredBandFloor（约 8105 « 500000），故排在所有 covered 词组之后、且保持词组间相对序。
    private static func wordFrequencyScore(_ chars: [Character]) -> Int {
        guard !chars.isEmpty else { return 0 }
        var logSum = 0.0
        for char in chars {
            logSum += log(Double(max(CharFrequency.score(of: char), 1)))
        }
        return Int(exp(logSum / Double(chars.count)).rounded())
    }

    // MARK: - import_tables 递归展开

    /// import_tables 的展开结果
    public struct TableExpansion {
        /// 实际要读的文件，顺序即优先级
        public var urls: [URL] = []
        /// 认出的表名（原样保留 `cn_dicts/8105` 这种带子路径的写法）
        public var importedTables: [String] = []
        /// 声明了却找不到的表名
        public var missingTables: [String] = []

        public init() {}
    }

    /// 把调用方给的词库文件按 import_tables 递归展开成实际要读的文件列表
    ///
    /// 深度优先 + visited 去环（A 导 B、B 导 A 不会无限递归）；找不到的表只记一笔名字然后继续
    /// —— 外部格式碰到这种情况会卡死，这里不能。
    /// 编译与码制推断都得用它：雾凇的 ice.dict.yaml 自己不装词，只抽它自己那几十行
    /// 大写数字，会把一整个拼音方案判成形码。展开时只读每个文件的开头一段
    /// （front matter 一定在最前面），几十 MB 的大表也不吃内存。
    public static func expandImportTables(_ urls: [URL], resourceRoot: URL? = nil) -> TableExpansion {
        var result = TableExpansion()
        var visited = Set<String>()
        for url in urls {
            expandRecursive(url, root: resourceRoot, isImported: false,
                            into: &result, visited: &visited)
        }
        return result
    }

    private static func expandRecursive(_ url: URL, root: URL?, isImported: Bool,
                                        into result: inout TableExpansion,
                                        visited: inout Set<String>) {
        let key = url.standardizedFileURL.path
        guard !visited.contains(key) else { return }
        visited.insert(key)
        // 读不到的文件也要进列表：编译那边靠它记一条「读取文件失败」，用户才知道是哪张表出了问题
        result.urls.append(url)

        guard let head = headText(of: url) else {
            if isImported { appendUnique(url.lastPathComponent, to: &result.missingTables) }
            return
        }
        for name in DictHeaderParser.parse(head).header.importTables where !name.isEmpty {
            guard let resolved = resolveImportedTable(name, importerURL: url, root: root) else {
                appendUnique(name, to: &result.missingTables)
                continue
            }
            appendUnique(name, to: &result.importedTables)
            expandRecursive(resolved, root: root, isImported: true,
                            into: &result, visited: &visited)
        }
    }

    /// 表名只记一次：这两份名单要原样写进编译报告给用户看，
    /// 同一张底表被两处导入就列两遍，只会变成噪声（词库数量少，线性查找足够）
    private static func appendUnique(_ name: String, to list: inout [String]) {
        if !list.contains(name) { list.append(name) }
    }

    /// 只读文件开头一段来找 front matter。截断落在半行上没关系：
    /// 头部是逐行解析的，残缺的末行最多让人少读一个用不上的键
    private static func headText(of url: URL, maxBytes: Int = 256 * 1024) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maxBytes), !data.isEmpty else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// 把 import_tables 里的表名解析成文件路径
    ///
    /// 外部格式的表名可以带子路径、也可以省略后缀（`cn_dicts/8105` 指 cn_dicts/8105.dict.yaml），
    /// 所以依次在「导入方所在目录、包根目录、包根目录/dictionaries」下试三种后缀。
    private static func resolveImportedTable(_ name: String, importerURL: URL, root: URL?) -> URL? {
        var dirs = [importerURL.deletingLastPathComponent()]
        if let root {
            dirs.append(root)
            dirs.append(root.appendingPathComponent("dictionaries", isDirectory: true))
        }
        let fm = FileManager.default
        for dir in dirs {
            for suffix in [".dict.yaml", ".yaml", ""] {
                let candidate = dir.appendingPathComponent(name + suffix)
                if fm.fileExists(atPath: candidate.path) { return candidate }
            }
        }
        return nil
    }

    // MARK: - 词库解析
    // 支持两种格式：
    // 格式A（OpenIME 原生）:
    //   entries:
    //     - code: nihao
    //       text: 你好
    //       freq: 1000
    //
    // 格式B（外部 dict.yaml 兼容）:
    //   ---（YAML front matter）
    //   ...
    //   code\ttext\tfreq  或  text\tcode\tweight\tstem（列序由 front matter 的 columns 决定）

    /// 一份词库文件的解析结果
    ///
    /// 之所以要把「有码的」和「没码的」分开装：外部格式词组经常不写码，靠 encoder 从单字码派生，
    /// 而派生要用到全部单字的码 —— 必须等所有文件都解析完才能算。没码的行先挂在这里，
    /// 不算失败也不算成功，等主流程补齐后再计入统计。
    private struct ParsedDictFile {
        var fileName: String
        var entries: [DictEntry] = []
        /// code 为空、等着 encoder 派生的行
        var noCode: [PendingEntry] = []
        var columns: Set<String> = []
        /// 声明了但 OpenIME 不认的列（只记录，不影响解析）
        var ignoredColumns: [String] = []
        var header = DictHeader()
        var skipped: [FileParseReport.SkippedLine] = []

        struct PendingEntry {
            var lineNumber: Int
            var content: String
            var text: String
            var freq: Int
            var annotation: String?
        }

        static func failed(fileName: String) -> ParsedDictFile {
            var file = ParsedDictFile(fileName: fileName)
            file.skipped.append(.init(lineNumber: 0, content: fileName,
                                      reason: "读取文件失败：文件不存在或不是 UTF-8 编码"))
            return file
        }
    }

    private static func parseFileContent(_ content: String, fileName: String) -> ParsedDictFile {
        // 上游方案包 / Windows 侧导出的词库常是 CRLF 行尾：行尾的 \r 会粘在最后一列上，
        // 末列是 code 时整表变成「tupg\r」这类永远查不到的伪码；文件头 BOM 同理只会干扰头部解析。
        // 在唯一的解析入口统一归一，两种格式、头部与数据区一次到位。
        var content = content
        if content.hasPrefix("\u{FEFF}") { content.removeFirst() }
        if content.contains("\r") {
            content = content.replacingOccurrences(of: "\r\n", with: "\n")
                             .replacingOccurrences(of: "\r", with: "\n")
        }
        if content.contains("entries:") {
            let (entries, skipped) = parseOpenIMEFormat(content)
            let cols: Set<String> = entries.contains(where: { $0.annotation != nil })
                ? ["text","code","annotation"] : ["text","code"]
            return ParsedDictFile(fileName: fileName, entries: entries,
                                  columns: cols, skipped: skipped)
        }
        return parseExternalFormat(content, fileName: fileName)
    }

    private static func parseOpenIMEFormat(_ content: String) -> ([DictEntry], [FileParseReport.SkippedLine]) {
        var entries: [DictEntry] = []
        var skipped: [FileParseReport.SkippedLine] = []
        let lines = content.components(separatedBy: .newlines)
        var i = 0

        while i < lines.count {
            let line = lines[i].trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("- code:") {
                var code = ""
                var text = ""
                var freq = 500
                var anno: String? = nil
                let startLine = i + 1

                code = String(line.dropFirst("- code:".count)).trimmingCharacters(in: .whitespaces)
                i += 1
                while i < lines.count {
                    let inner = lines[i].trimmingCharacters(in: .whitespaces)
                    if inner.hasPrefix("text:") {
                        text = String(inner.dropFirst("text:".count)).trimmingCharacters(in: .whitespaces)
                    } else if inner.hasPrefix("freq:") {
                        freq = Int(inner.dropFirst("freq:".count).trimmingCharacters(in: .whitespaces)) ?? 500
                    } else if inner.hasPrefix("annotation:") {
                        anno = String(inner.dropFirst("annotation:".count)).trimmingCharacters(in: .whitespaces)
                    } else if inner.hasPrefix("- code:") || inner.hasPrefix("-") {
                        i -= 1
                        break
                    }
                    i += 1
                }
                if !code.isEmpty && !text.isEmpty {
                    entries.append(DictEntry(code: code, text: text, freq: freq, annotation: anno))
                } else {
                    let reason = code.isEmpty ? "缺少 code 字段" : "缺少 text 字段"
                    skipped.append(.init(lineNumber: startLine, content: line, reason: reason))
                }
            }
            i += 1
        }
        return (entries, skipped)
    }

    /// 词条缺失 weight 列时的默认词频（与 OpenIME 原生格式保持一致）
    private static let defaultFreq = 500

    /// OpenIME 认识的列。外部词库的列五花八门（stem 字根、radical 部首、phonetic 注音、
    /// _custom_dict_code…），一律按名字取用，不认识的忽略并记进报告 —— 绝不能像以前那样
    /// 「第一个没认出的列就当注释」，否则形码的 stem 会跑到 radical 的位置上去
    private static let knownColumns: Set<String> = [
        "text", "code", "weight", "annotation", "comment", "stem"
    ]
    /// 注释列的取值优先级：annotation 是通用注释，comment 同义，
    /// stem 是形码的字根拆解提示（虎码「丿扌戈 · tupg」就来自这一列，显示效果不能回退）
    private static let annotationColumns = ["annotation", "comment", "stem"]

    private static func parseExternalFormat(_ content: String, fileName: String) -> ParsedDictFile {
        var result = ParsedDictFile(fileName: fileName)
        let front = DictHeaderParser.parse(content)
        result.header = front.header

        let declared = front.header.columns
        result.columns = Set(declared.isEmpty ? ["text", "code"] : declared)
        result.ignoredColumns = declared.filter { !knownColumns.contains($0) }

        // 声明了 columns 却没有 text/code 列的表（雾凇的 cn_dicts/tencent.dict.yaml 就是 text+weight 两列）
        // 提供不了编码，收录了也查不到。以前会把 weight 列当成 code，整张表变成九十万条数字伪码，
        // 比不收录糟得多。这里整表跳过，只记一条原因 —— 不逐行刷几十万条告警。
        guard declared.isEmpty || (declared.contains("text") && declared.contains("code")) else {
            result.skipped.append(.init(
                lineNumber: front.dataStartIndex + 1, content: fileName,
                reason: "columns 里没有 text 或 code 列（实际声明：\(declared.joined(separator: "、"))），这张表提供不了编码，整表跳过"))
            return result
        }

        let colText = declared.firstIndex(of: "text") ?? 0
        let colCode = declared.firstIndex(of: "code") ?? 1
        // 没声明 columns 的老文件按 text/code/weight 三列排（OpenIME 单文件格式），
        // 声明了却没 weight 的则一律取默认词频
        let colFreq = declared.isEmpty ? 2 : (declared.firstIndex(of: "weight") ?? -1)
        // weight 不是必需列：很多词库只有 text+code（虎码的单字库就是这样），
        // 以前把 requiredMax 算上 colFreq 会把这些行整批判成「列数不足」
        let requiredMax = max(colText, colCode)

        let lines = DictHeaderParser.splitLines(content)
        for (index, line) in lines.enumerated() where index >= front.dataStartIndex {
            let lineNumber = index + 1
            // 只吃空格，绝不能吃 Tab：Tab 是列分隔符本身，
            // 用 .whitespaces 会把「\tnihao\t500\t」这种 text 列为空的坏行 trim 成合法的两列
            let trimmed = line.trimmingCharacters(in: .init(charactersIn: " "))
            if trimmed.hasPrefix("#") || trimmed.isEmpty { continue }

            let parts = trimmed.components(separatedBy: "\t")
            // 只写了词、没写编码的行：超强快码把整句诗直接扔进词库，靠 encoder 从单字码派生。
            // 外部格式的语义是「缺的列就是空」，不能当成列数不足的格式错误。但真的用空格分隔的
            // 坏文件也只有一段，靠「行内有没有 ASCII 空格」区分 —— 诗句不含空格，空格分隔的行必然含。
            let bareWord = parts.count <= colCode && parts.count > colText
                && front.header.encoder != nil && !trimmed.contains(" ")
            guard parts.count > requiredMax || bareWord else {
                // 判断是否是空格分隔（常见错误）：行内有空格，且 tab 分割后第一列本身包含空格
                let firstPartHasSpaces = parts.first.map { $0.contains(" ") } ?? false
                let reason: String
                if firstPartHasSpaces {
                    reason = "列数不足（需要至少 \(requiredMax + 1) 列，只有 \(parts.count) 列）。列之间必须用 Tab（\\t）分隔，不能用空格"
                } else {
                    reason = "列数不足（需要至少 \(requiredMax + 1) 列，实际只有 \(parts.count) 列）"
                }
                result.skipped.append(.init(lineNumber: lineNumber, content: trimmed, reason: reason))
                continue
            }

            let text = parts[colText]
            let code = parts.count > colCode ? parts[colCode] : ""
            // weight 字段不是数字时静默取默认值：不计入 skipped，避免成千上万条告警淹没真正的问题
            let freq = (colFreq >= 0 && colFreq < parts.count)
                ? (Int(parts[colFreq]) ?? defaultFreq) : defaultFreq
            var anno: String? = nil
            for name in annotationColumns {
                guard let col = declared.firstIndex(of: name), col < parts.count,
                      !parts[col].isEmpty else { continue }
                anno = parts[col]
                break
            }

            if text.isEmpty {
                result.skipped.append(.init(lineNumber: lineNumber, content: trimmed,
                                            reason: "词（text 列）为空"))
                continue
            }
            if code.isEmpty {
                // 词里带着空格、码列又是空的：十有八九是拿空格当分隔符写的坏文件（`你好 nihao 1000`）。
                // 这类行以前靠「列数不足」被拦下来，而现在 weight 不再是必需列、拦不住了，
                // 得在这里把话说明白 —— 只报一句「编码为空」，用户根本不知道错在哪
                if text.contains(" ") {
                    result.skipped.append(.init(
                        lineNumber: lineNumber, content: trimmed,
                        reason: "编码（code 列）为空，且词（text 列）里带着空格。列之间必须用 Tab（\\t）分隔，不能用空格"))
                    continue
                }
                // 交给 encoder 派生；没有 encoder 的行由主流程统一记为「编码为空」
                result.noCode.append(.init(lineNumber: lineNumber, content: trimmed,
                                           text: text, freq: freq, annotation: anno))
                continue
            }
            result.entries.append(DictEntry(code: code, text: text, freq: freq, annotation: anno))
        }
        return result
    }

    // MARK: - 长串词图切分：字级二元语法侧车

    /// 编译时顺带产出一份 dict.lm.bin，供长输入的词图切分打分用。
    ///
    /// 它是独立文件，dict.bin 一个字节都不动，老读者永远看不见；构建失败也绝不牵连主编译流程
    /// （没有这份侧车，长串切分只是退回「没有二元语法」的排序，仍然比一条候选都没有强）。
    /// 三种存储类型都用得上：字级二元语法看的是切出来的汉字，与编码方式无关；
    /// 双拼的长串切分已经接上（展开成全拼后走音节图），同样要这份侧车。
    private static func writeLanguageModelSidecar(entries: [DictEntry],
                                                  dictURL: URL) {
        let lmURL = dictURL.deletingLastPathComponent().appendingPathComponent("dict.lm.bin")
        let words = entries.map { (text: $0.text, freq: $0.freq) }
        try? CharBigramBuilder.build(from: words, to: lmURL)
    }

    // MARK: - v4 侧车索引（编译期预排，运行时零 O(词库) 扫描）
    //
    // 真机日志实测：v3 的二分只把「定位前缀区间」做到 O(log n)，collect 仍要扫完整个命中区间
    //（单字母前缀动辄 3~4.7 万条 = 20~74ms/键）；反查 shortestCodes 更是每键全扫 55 万条（~1s/键）。
    // Rime 的精髓是「贵的都放编译期」：这里补两张侧车表，dict.bin 本体格式不动（仍 v3），
    // 读取器按文件名可选加载、加载不到就回退老路径，零风险。

    /// prefixTopN 只收录命中区间超过该条数的前缀：更小的前缀运行时顺序扫区间本身就 <1ms，
    /// 不值得占索引体积。读取器「侧车未命中 ⇒ 区间 ≤ 阈值」的假设与此阈值绑定
    private static let ptnRangeThreshold = 300
    /// 每个前缀预排的候选条数上限：必须 ≥ 顶部候选栏的查询上限（IMERuntime.candidateLimit，现 300），
    /// 否则大前缀走侧车时会被这个更小的值卡住、顶部栏到不了 candidateLimit（曾长期 120 < 300，
    /// 大前缀只能出 120 条）。取 360 ≈ 1.2×300，与旧 120:100 同比例，给侧车偏移物化失败留少量余量。
    /// 改这个值属于「影响编译产物」的改动，必须同步 +1 compilerEpoch 触发已装词库重编，否则真机静默不生效。
    private static let ptnTopN = 360
    /// 前缀内联字节上限：热前缀（单字母到五字母）都在此内，更长的前缀区间本就小
    private static let ptnMaxPrefixLen = 8

    /// 编译期排序比较器：与读取器 isBetterCandidate 同序，保证预排结果与运行时 top-N 一致。
    /// 纯词频模式同词频按 code 升序（= 数据区扫描序，堆「先来者不被替换」的等效结果）；
    /// 码表模式同词频再比码长、字序
    private static func betterEntry(_ a: DictEntry, _ b: DictEntry,
                                    preferShorterCode: Bool) -> Bool {
        if a.freq != b.freq { return a.freq > b.freq }
        guard preferShorterCode else { return a.code < b.code }
        if a.code.count != b.code.count { return a.code.count < b.code.count }
        return a.code < b.code
    }

    /// prefixTopN 侧车（dict.ptn.bin）：对每个命中区间 > 阈值的前缀，预存按运行时比较器排好的
    /// top-N 词条偏移（相对 dataOffset）。读取器二分前缀 → 直接读这 N 个偏移，O(N) 与区间大小无关
    private static func writePrefixTopNSidecar(entries: [DictEntry], offsets: [UInt32],
                                               schemeType: SchemeType, dictURL: URL) {
        let url = dictURL.deletingLastPathComponent().appendingPathComponent("dict.ptn.bin")
        // 形码 / 音形码走码表补全（同词频码短者优先），拼音 / 双拼走纯词频；
        // 一个词库只服务自己 schemeType 的主模式，读取器模式不匹配就回退区间扫
        let preferShorter = (schemeType == .direct)

        // 先收集桶，最后按前缀字节全局升序写目录：读取器对目录做二分，
        // 目录必须跨前缀长度全局有序（「a1」>「a00」，按长度分组不满足）
        var buckets: [(prefix: [UInt8], offsets: [UInt32])] = []

        for prefixLen in 1...ptnMaxPrefixLen {
            var i = 0
            while i < entries.count {
                let codeBytes = Array(entries[i].code.utf8)
                guard codeBytes.count >= prefixLen else { i += 1; continue }
                let prefix = Array(codeBytes.prefix(prefixLen))
                var j = i
                while j < entries.count,
                      entries[j].code.utf8.count >= prefixLen,
                      Array(entries[j].code.utf8.prefix(prefixLen)) == prefix {
                    j += 1
                }
                defer { i = j }
                guard j - i > ptnRangeThreshold else { continue }
                // 区间内按运行时同一比较器预排，取前 topN 条的偏移
                let ranked = Array((i..<j).sorted { a, b in
                    betterEntry(entries[a], entries[b], preferShorterCode: preferShorter)
                }.prefix(ptnTopN))
                buckets.append((prefix, ranked.map { offsets[$0] }))
            }
        }
        buckets.sort { $0.prefix.lexicographicallyPrecedes($1.prefix) }

        var dir = Data()
        var pool = Data()
        for bucket in buckets {
            let relPoolOff = UInt32(pool.count)
            for off in bucket.offsets {
                pool.append(contentsOf: withUnsafeBytes(of: off.littleEndian) { Data($0) })
            }
            dir.append(UInt8(bucket.prefix.count))
            dir.append(0)
            dir.append(contentsOf: withUnsafeBytes(of: UInt16(bucket.offsets.count).littleEndian) { Data($0) })
            var pb = bucket.prefix
            pb.append(contentsOf: [UInt8](repeating: 0, count: ptnMaxPrefixLen - pb.count))
            dir.append(contentsOf: pb)
            dir.append(contentsOf: withUnsafeBytes(of: relPoolOff.littleEndian) { Data($0) })
        }
        let bucketCount = UInt32(buckets.count)

        var header = Data()
        header.append(contentsOf: "OPTN".utf8)
        header.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Data($0) })
        header.append(preferShorter ? 1 : 0)
        header.append(0)
        header.append(contentsOf: withUnsafeBytes(of: bucketCount.littleEndian) { Data($0) })
        let dirOffset = UInt32(24)
        let poolOffset = dirOffset + UInt32(dir.count)
        header.append(contentsOf: withUnsafeBytes(of: dirOffset.littleEndian) { Data($0) })
        header.append(contentsOf: withUnsafeBytes(of: poolOffset.littleEndian) { Data($0) })
        header.append(contentsOf: withUnsafeBytes(of: UInt32(ptnRangeThreshold).littleEndian) { Data($0) })
        try? (header + dir + pool).write(to: url, options: .atomic)
    }

    /// 反查侧车（dict.ti.bin）：text → 最短编码 的有序表。读取器反查（i+拼音 补编码）改为
    /// 按 text 二分 O(log n)，不再每键全扫数据区（真机实测全扫 ~1s/键）
    private static func writeTextIndexSidecar(entries: [DictEntry], dictURL: URL) {
        let url = dictURL.deletingLastPathComponent().appendingPathComponent("dict.ti.bin")
        var best: [String: String] = [:]
        best.reserveCapacity(entries.count)
        for e in entries where !e.text.isEmpty {
            if let cur = best[e.text] {
                if e.code.count < cur.count || (e.code.count == cur.count && e.code < cur) {
                    best[e.text] = e.code
                }
            } else {
                best[e.text] = e.code
            }
        }
        let keys = best.keys.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
        var dir = Data(); var textPool = Data(); var codePool = Data()
        var written: UInt32 = 0
        for key in keys {
            let code = best[key]!
            let tb = Array(key.utf8); let cb = Array(code.utf8)
            guard tb.count <= Int(UInt16.max), cb.count <= Int(UInt16.max) else { continue }
            dir.append(contentsOf: withUnsafeBytes(of: UInt16(tb.count).littleEndian) { Data($0) })
            dir.append(contentsOf: withUnsafeBytes(of: UInt16(cb.count).littleEndian) { Data($0) })
            dir.append(contentsOf: withUnsafeBytes(of: UInt32(textPool.count).littleEndian) { Data($0) })
            dir.append(contentsOf: withUnsafeBytes(of: UInt32(codePool.count).littleEndian) { Data($0) })
            textPool.append(contentsOf: tb)
            codePool.append(contentsOf: cb)
            written += 1
        }
        var header = Data()
        header.append(contentsOf: "OTIX".utf8)
        header.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Data($0) })
        header.append(contentsOf: withUnsafeBytes(of: UInt16(0).littleEndian) { Data($0) })
        header.append(contentsOf: withUnsafeBytes(of: written.littleEndian) { Data($0) })
        let dirOffset = UInt32(24)
        let textPoolOffset = dirOffset + UInt32(dir.count)
        let codePoolOffset = textPoolOffset + UInt32(textPool.count)
        header.append(contentsOf: withUnsafeBytes(of: dirOffset.littleEndian) { Data($0) })
        header.append(contentsOf: withUnsafeBytes(of: textPoolOffset.littleEndian) { Data($0) })
        header.append(contentsOf: withUnsafeBytes(of: codePoolOffset.littleEndian) { Data($0) })
        try? (header + dir + textPool + codePool).write(to: url, options: .atomic)
    }

    // MARK: - 二进制构建

    /// 二进制版本（v3 = 索引区改为词条偏移表，查询二分定位前缀区间；v2 = 前两字符前缀桶）
    public static let binaryVersion: UInt16 = 3
    /// 编译纪元：编译逻辑本身变了、但 dict.bin 字节格式没变时靠它触发重编。
    ///
    /// binaryVersion 只管「读者认不认得这个文件格式」，管不了「同一份 YAML 编出来的词条对不对」。
    /// 比如这轮补上了 import_tables 递归导入与 encoder 自动编码：老包里的 dict.bin 格式完全合法，
    /// 词条却少了一大截，只有纪元号落后才认得出来。
    /// 每改一次会影响词条内容的编译逻辑就 +1，启动对账会据此在后台重编（见 IMERuntime.syncSchemesStore）。
    /// epoch 6→7：ptnTopN 120→360（侧车预排条数上限），属影响编译产物的改动，必须 bump 才能在已装词库上生效。
    public static let compilerEpoch: Int = 7
    /// 头部字节数（v1 是 20，v2 追加 tailOffset）
    private static let headerSize: UInt32 = 24

    /// 读取词库文件头的格式版本（读不到返回 nil）
    /// —— 供启动对账判断「已安装的词库是否还是旧格式」
    public static func binaryVersion(at url: URL) -> UInt16? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: Int(headerSize)),
              head.count >= 20,
              String(bytes: head[0..<4], encoding: .utf8) == "OIME" else { return nil }
        return head.readUInt16(at: 4)
    }

    /// 为一份已编译好的 dict.bin 补建字级二元语法侧车（dict.lm.bin），只在侧车缺失时才扫描。
    ///
    /// 为什么需要它：安装流程是「编译到临时 dict.bin 再拷进安装目录」，旧版本装好的方案只有
    /// dict.bin、没有 dict.lm.bin；启动对账时用这个补建一次即可，之后侧车存在就直接跳过（常态零成本）。
    /// 扫一遍数据区收集 (词, 词频) 交给 CharBigramBuilder，与编译期从内存词条构建的结果同构。
    /// - Returns: 是否真的构建了（侧车已存在 / 文件损坏都返回 false）
    @discardableResult
    public static func buildLanguageModelIfNeeded(at url: URL) throws -> Bool {
        let lmURL = url.deletingLastPathComponent().appendingPathComponent("dict.lm.bin")
        if FileManager.default.fileExists(atPath: lmURL.path) { return false }

        // 先只读头部确认是自己的词库，认不出就没必要 mmap 整份词库。
        // 这里不按存储类型筛：三种类型的长串切分都要用二元语法（与编译期产出口径一致）
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        let head = (try? handle.read(upToCount: Int(headerSize))) ?? Data()
        try? handle.close()
        guard head.count >= 20,
              String(bytes: head[0..<4], encoding: .utf8) == "OIME" else { return false }

        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        let dataOffset = Int(data.readUInt32(at: 16))
        guard dataOffset > 0, dataOffset < data.count else { return false }
        // 旧词库（九宫索引还在写的那几版）的数据区之后接着一段附加区，扫描必须停在它的起点，
        // 否则会扫进附加区把数据读乱；新编的词库这一项恒为 0，dataEnd 就是文件尾
        var dataEnd = data.count
        if data.readUInt16(at: 4) >= 2, data.count >= 24 {
            let tailOffset = Int(data.readUInt32(at: 20))
            if tailOffset > dataOffset, tailOffset <= data.count { dataEnd = tailOffset }
        }
        guard let records = collectTextFreqRecords(data, dataOffset: dataOffset, dataEnd: dataEnd) else { return false }

        try CharBigramBuilder.build(from: records, to: lmURL)
        return true
    }

    /// 扫描数据区，收集每条词条的 (词, 词频)，用于从已编译词库派生二元语法
    /// - Returns: nil 表示数据区损坏，放弃构建（不能把可用词库读坏）
    private static func collectTextFreqRecords(
        _ data: Data, dataOffset: Int, dataEnd: Int
    ) -> [(text: String, freq: Int)]? {
        var records: [(text: String, freq: Int)] = []
        var pos = dataOffset
        while pos < dataEnd {
            let codeLen = Int(data[pos])
            pos += 1 + codeLen
            guard pos + 2 <= dataEnd else { return nil }
            let textLen = Int(data.readUInt16(at: pos))
            pos += 2
            guard pos + textLen <= dataEnd else { return nil }
            let text = String(decoding: data[pos..<(pos + textLen)], as: UTF8.self)
            pos += textLen
            guard pos + 2 <= dataEnd else { return nil }
            let annoLen = Int(data.readUInt16(at: pos))
            pos += 2 + annoLen
            guard pos + 4 <= dataEnd else { return nil }
            let freq = Int(data.readInt32(at: pos))
            pos += 4
            if !text.isEmpty {
                records.append((text: text, freq: freq))
            }
        }
        return pos == dataEnd ? records : nil
    }

    private static func buildBinary(entries: [DictEntry], schemeType: SchemeType)
        -> (data: Data, offsets: [UInt32], kept: [DictEntry]) {
        var dataSection = Data()
        // v3：数据区按 code 升序，索引区改存「每条词条相对数据区起点的偏移表」。
        // 查询时对偏移表二分即可定位任一前缀的连续命中区间，与桶大小彻底解耦
        //（旧的前两字符桶让多字符前缀每键重扫整桶，是拼音卡顿的根因）。
        var offsetTable: [UInt32] = []
        offsetTable.reserveCapacity(entries.count)
        var kept: [DictEntry] = []
        kept.reserveCapacity(entries.count)
        var actualCount: UInt32 = 0

        for entry in entries {
            // 超长的 code / text / annotation 在计数和偏移记账之前就跳过，保证偏移表与数据区严格对齐
            // （三个长度字段分别是 1 / 2 / 2 字节，超了会溢出）
            let codeData = entry.code.data(using: .utf8) ?? Data()
            let textData = entry.text.data(using: .utf8) ?? Data()
            let annoData = (entry.annotation ?? "").data(using: .utf8) ?? Data()
            guard codeData.count <= 255,
                  textData.count <= Int(UInt16.max),
                  annoData.count <= Int(UInt16.max) else { continue }

            // 先记偏移再写字节：跳过的超长条目两侧都不进，偏移表下标与数据区第 k 条一一对应
            offsetTable.append(UInt32(dataSection.count))
            kept.append(entry)
            actualCount += 1

            dataSection.append(UInt8(codeData.count))
            dataSection.append(contentsOf: codeData)
            dataSection.append(contentsOf: withUnsafeBytes(of: UInt16(textData.count).littleEndian) { Data($0) })
            dataSection.append(contentsOf: textData)
            dataSection.append(contentsOf: withUnsafeBytes(of: UInt16(annoData.count).littleEndian) { Data($0) })
            dataSection.append(contentsOf: annoData)
            dataSection.append(contentsOf: withUnsafeBytes(of: Int32(entry.freq).littleEndian) { Data($0) })
        }

        var indexSection = Data(capacity: offsetTable.count * 4)
        for off in offsetTable {
            indexSection.append(contentsOf: withUnsafeBytes(of: off.littleEndian) { Data($0) })
        }

        let indexOffset = headerSize
        let dataOffset = indexOffset + UInt32(indexSection.count)

        var header = Data()
        header.append(contentsOf: "OIME".utf8)
        header.append(contentsOf: withUnsafeBytes(of: binaryVersion.littleEndian) { Data($0) })
        header.append(schemeType.binaryCode)
        header.append(0)
        header.append(contentsOf: withUnsafeBytes(of: actualCount.littleEndian) { Data($0) })
        header.append(contentsOf: withUnsafeBytes(of: indexOffset.littleEndian) { Data($0) })
        header.append(contentsOf: withUnsafeBytes(of: dataOffset.littleEndian) { Data($0) })
        // tailOffset 恒为 0：数据区之后没有附加区。字段与头部长度保留是为了解释旧文件里
        // 已经存在的那段九宫索引尾巴（见文件头的 [T9Index] 一节）
        header.append(contentsOf: withUnsafeBytes(of: UInt32(0).littleEndian) { Data($0) })

        return (header + indexSection + dataSection, offsetTable, kept)
    }
}

extension SchemeType {
    var binaryCode: UInt8 {
        switch self {
        case .direct:         return 0
        case .syllable:       return 1
        case .doubleSyllable: return 2
        }
    }

    var displayName: String {
        switch self {
        case .direct:         return "直接编码 (direct)"
        case .syllable:       return "拼音音节 (syllable)"
        case .doubleSyllable: return "双拼 (double_syllable)"
        }
    }
}
