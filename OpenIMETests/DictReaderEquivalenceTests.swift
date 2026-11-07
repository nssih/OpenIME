import XCTest
@testable import OpenIMECore

// MARK: - 词库查询等价性测试
//
// DictReader 为了性能做过内部优化（索引哈希表、无分配整数读取、字节级前缀比较、
// freq top-k 堆、单字符前缀缓存）。这些改动不改变对外查询语义：
// 这里用「逐条全表扫描 + 全量排序」的朴素实现做参照，逐项对齐结果集与词频顺序。
//
// 它同时说明：不管哪种键盘形态，解码后查的都是同一份词库、同一套语义。

final class DictReaderEquivalenceTests: XCTestCase {

    private var tmpDir: URL!

    override func setUpWithError() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DictReaderEquivalence_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpDir)
        tmpDir = nil
    }

    // MARK: - 测试用词库

    /// 覆盖：单字符 / 多字符前缀、同音多字、长码、注释列、词频相同的词条
    private let dictionaryYAML = """
    ---
    columns:
      - text
      - code
      - weight
      - annotation
    ...
    你好\tnihao\t1000\tnǐ hǎo
    你们\tnimen\t950\t
    你好吗\tnihaoma\t900\t
    你\tni\t880\t
    尼\tni\t800\t
    泥\tni\t700\t
    逆\tni\t650\t
    年\tnian\t600\t
    念\tnian\t550\t
    新\txin\t1000\txīn
    心\txin\t980\t
    信\txin\t960\t
    辛\txin\t700\t
    行\txing\t990\t
    形\txing\t900\t
    星\txing\t880\t
    中国\tzhongguo\t1000\t
    中文\tzhongwen\t900\t
    中\tzhong\t850\t
    重\tzhong\t820\t
    """

    /// 编译一份真实二进制词库
    private func compileDictionary() throws -> (binURL: URL, data: Data) {
        let yamlURL = tmpDir.appendingPathComponent("test.dict.yaml")
        try dictionaryYAML.write(to: yamlURL, atomically: true, encoding: .utf8)
        let binURL = tmpDir.appendingPathComponent("dict.bin")
        try DictCompiler.compile(yamlURL: yamlURL, outputURL: binURL, schemeType: .syllable)
        return (binURL, try Data(contentsOf: binURL))
    }

    // MARK: - 参照实现：全表扫描

    /// 朴素实现：从头到尾扫每一条词条，`hasPrefix` 过滤后全量排序。
    /// 完全不依赖索引区，因此可以独立验证哈希索引没有漏桶。
    private func bruteForce(_ data: Data, prefix: String, limit: Int) -> [Candidate] {
        let entryCount = Int(data.readUInt32(at: 8))
        let dataOffset = Int(data.readUInt32(at: 16))
        var results: [Candidate] = []
        var offset = dataOffset

        for _ in 0..<entryCount {
            let codeLength = Int(data[offset])
            let code = String(decoding: data[(offset + 1)..<(offset + 1 + codeLength)], as: UTF8.self)
            var cursor = offset + 1 + codeLength

            let textLength = Int(data.readUInt16(at: cursor))
            cursor += 2
            let text = String(decoding: data[cursor..<(cursor + textLength)], as: UTF8.self)
            cursor += textLength

            let annotationLength = Int(data.readUInt16(at: cursor))
            cursor += 2
            let annotation = annotationLength > 0
                ? String(decoding: data[cursor..<(cursor + annotationLength)], as: UTF8.self)
                : nil
            cursor += annotationLength

            let freq = Int(data.readInt32(at: cursor))
            cursor += 4

            if code.hasPrefix(prefix) {
                results.append(Candidate(text: text, code: code, annotation: annotation,
                                         freq: freq, sourceSchemeId: "reference"))
            }
            offset = cursor
        }

        return Array(results.sorted { $0.freq > $1.freq }.prefix(limit))
    }

    // MARK: - 等价性

    /// 比较 DictReader 与全表扫描的结果集 / 词频序列
    /// - Note: 词频相同的词条先后顺序不做要求（两种实现都不保证稳定）
    private func assertEquivalent(_ prefix: String,
                                  limit: Int = 50,
                                  file: StaticString = #filePath,
                                  line: UInt = #line) throws {
        let (binURL, data) = try compileDictionary()
        let reader = try DictReader(binURL: binURL)
        // 先查一次触发可能的缓存写入，再比对第二次（缓存路径与普通路径都要一致）
        _ = reader.query(prefix: prefix, limit: limit)
        let actual = reader.query(prefix: prefix, limit: limit)
        let expected = bruteForce(data, prefix: prefix, limit: limit)

        XCTAssertEqual(actual.map { $0.text }.sorted(),
                       expected.map { $0.text }.sorted(),
                       "前缀 \(prefix) 的结果集与全表扫描不一致", file: file, line: line)
        XCTAssertEqual(actual.map { $0.freq }.sorted(by: >),
                       expected.map { $0.freq }.sorted(by: >),
                       "前缀 \(prefix) 的词频顺序与全表扫描不一致", file: file, line: line)
        XCTAssertLessThanOrEqual(actual.count, limit,
                                 "前缀 \(prefix) 超出 limit", file: file, line: line)
    }

    func testMultiCharacterPrefixMatchesBruteForce() throws {
        for prefix in ["ni", "nih", "niha", "xin", "xing", "zhong", "zho"] {
            try assertEquivalent(prefix)
        }
    }

    func testSingleCharacterPrefixMatchesBruteForce() throws {
        // 单字符前缀会走缓存
        for prefix in ["n", "x", "z", "a"] {
            try assertEquivalent(prefix)
        }
    }

    func testLimitTruncationMatchesBruteForce() throws {
        try assertEquivalent("ni", limit: 3)
    }

    func testMissingPrefixReturnsEmptyLikeBruteForce() throws {
        try assertEquivalent("zzz")
    }

    // MARK: - 单字母编码（形码一简码）

    /// 形码方案的一简码是单字母编码（虎码 t → 我）。索引按两字符前缀分桶，
    /// 单字母前缀查询如果只枚举「两字母桶」，这一整批简码就会全部查不出来。
    /// 这里锁定：单字母输入既能查到简码本身、也能查到更长的同前缀编码，且简码词频最高时排首位。
    func testSingleCharCodeIsQueryable() throws {
        let yaml = """
        ---
        columns:
          - text
          - code
          - weight
          - annotation
        ...
        我\tt\t2302420\t丿扌戈 · tupg
        用\tty\t607554\t
        我\ttupg\t256\t丿扌戈 · tupg
        """
        let yamlURL = tmpDir.appendingPathComponent("shortcut.dict.yaml")
        try yaml.write(to: yamlURL, atomically: true, encoding: .utf8)
        let binURL = tmpDir.appendingPathComponent("shortcut.bin")
        try DictCompiler.compile(yamlURL: yamlURL, outputURL: binURL, schemeType: .direct)
        let reader = try DictReader(binURL: binURL)

        XCTAssertEqual(reader.queryExact(code: "t").map { $0.text }, ["我"])
        XCTAssertEqual(reader.query(prefix: "t").first?.text, "我",
                       "一简码词频最高，应排在单字母输入的首位")
        XCTAssertEqual(Set(reader.query(prefix: "t").map { $0.code }), ["t", "ty", "tupg"],
                       "单字母前缀应同时覆盖简码本身与更长的同前缀编码")
    }

    // MARK: - 精确查询独立于前缀 top-N

    /// queryExact 必须独立扫描，不能拿 query(prefix:) 的 top-N 混合堆再过滤：
    /// 堆是「整码 + 更长码补全」按词频混排的，低词频的整码条目会被同前缀的
    /// 高词频补全挤出堆外（虎码 lc 下 艹(270) 等偏旁就曾被 top50 的 426 门槛全部挡掉），
    /// 表现为「字库里明明有、候选里就是不出」。
    func testExactMatchSurvivesHigherFreqCompletions() throws {
        var lines = ["---", "columns:", "  - text", "  - code", "  - weight", "  - annotation", "..."]
        lines.append("齿\tlc\t10000\t")          // 高频整码
        lines.append("艹\tlc\t270\t")            // 低词频整码（偏旁）
        for i in 0..<60 {                        // 60 条高频补全，把 limit=50 的堆全占满
            lines.append("词\(i)\tlca\(i)\t\(1000 + i)\t")
        }
        let yaml = lines.joined(separator: "\n")
        let yamlURL = tmpDir.appendingPathComponent("exact.dict.yaml")
        try yaml.write(to: yamlURL, atomically: true, encoding: .utf8)
        let binURL = tmpDir.appendingPathComponent("exact.bin")
        try DictCompiler.compile(yamlURL: yamlURL, outputURL: binURL, schemeType: .direct)
        let reader = try DictReader(binURL: binURL)

        let mixed = reader.query(prefix: "lc", limit: 50)
        XCTAssertFalse(mixed.contains { $0.text == "艹" },
                       "前提：混合 top-50 应已被高频补全占满，低频整码被挤出")
        XCTAssertEqual(Set(reader.queryExact(code: "lc").map { $0.text }), ["齿", "艹"],
                       "精确查询应返回全部整码条目，不受补全词频影响")
    }

    // MARK: - 码表路径（queryTable）：字节级快筛不许改变任何结果
    //
    // 形码开拼音混打时的卡顿与反查那条不同：不是整库扫描，而是「每条命中都先分配三个
    // String、再被堆原样丢掉」。形码一个两字母前缀下动辄上万条，混打时还要乘上参与方案的数量。
    // 修法是把后两层决胜（同词频比码长、仍同则比 code 字序）搬到 mmap 原始字节上先算一次
    //（losesToHeapTop），「必然进不了堆」的直接跳过。它替 insert 做了决定，所以逐字对齐：
    // 下面用「全量收集 + 朴素排序」的参照实现比对完整序列，再锁一个更强的性质：
    // 取前 k 条 == 取前 N 条（N 大到堆装得下整桶、快筛根本不触发）再截断前 k 条。

    /// 码表参照实现：词频降序 → 同词频码短者胜 → 仍同则 code 字序小者胜（不建堆、不限量、不读 mmap）
    private func naiveTableOrder(_ entries: [(text: String, code: String, freq: Int)],
                                 prefix: String, limit: Int) -> [Candidate] {
        entries.filter { $0.code.hasPrefix(prefix) }
            .sorted {
                if $0.freq != $1.freq { return $0.freq > $1.freq }
                if $0.code.count != $1.code.count { return $0.code.count < $1.code.count }
                return $0.code < $1.code
            }
            .prefix(limit)
            .map { Candidate(text: $0.text, code: $0.code, annotation: nil,
                             freq: $0.freq, sourceSchemeId: "reference") }
    }

    /// 编译一份码表词库（形码真实形态：权重区分度很小，全靠码长 / 字序决胜）
    private func compileTableDict(_ entries: [(text: String, code: String, freq: Int)]) throws -> URL {
        var lines = ["---", "columns:", "  - text", "  - code", "  - weight", "  - annotation", "..."]
        for entry in entries { lines.append("\(entry.text)\t\(entry.code)\t\(entry.freq)\t") }
        let yamlURL = tmpDir.appendingPathComponent("table.dict.yaml")
        try lines.joined(separator: "\n").write(to: yamlURL, atomically: true, encoding: .utf8)
        let binURL = tmpDir.appendingPathComponent("table.bin")
        try DictCompiler.compile(yamlURL: yamlURL, outputURL: binURL, schemeType: .direct)
        return binURL
    }

    /// 共 67 条，其中 65 条落在 ha 前缀下（码长 2 到 10 不等），另两条其它前缀不该出现在结果里
    private func tableEntries() -> [(text: String, code: String, freq: Int)] {
        var entries: [(text: String, code: String, freq: Int)] = [
            ("好", "ha", 1),          // 一简码：同词频下码最短，必须抢在最前
            ("号", "hab", 1),
            ("哈", "haz", 1),         // 同长同频 → 比字序：hab 在 haz 之前
            ("高频长码", "haaaaaaaaa", 900),  // 第一层是词频：长码也要盖过短码
            ("低频短码", "hac", 5),
            ("无关", "nb", 1),        // 不在 ha 前缀下，不该出现在结果里
            ("无关二", "hz", 1),      // 字序在 ha* 之前，但前缀不匹配
        ]
        for i in 0..<60 { entries.append(("简\(i)", String(format: "ha%03d", i), 1)) }
        return entries
    }

    /// 小 limit（堆一满就开始快筛）的结果必须与朴素参照逐字同序同调
    func testQueryTableMatchesNaiveReference() throws {
        let entries = tableEntries()
        let reader = try DictReader(binURL: try compileTableDict(entries))

        for limit in [1, 3, 20, 50] {
            let actual = reader.queryTable(prefix: "ha", limit: limit)
            let expected = naiveTableOrder(entries, prefix: "ha", limit: limit)
            XCTAssertEqual(actual.map { $0.code }, expected.map { $0.code },
                           "limit=\(limit)：快筛跳过的条目不该影响取哪几条、什么序")
            XCTAssertEqual(actual.map { $0.text }, expected.map { $0.text }, "limit=\(limit)")
        }
    }

    /// 更强的一层：同一个前缀下，小 limit 必须等于「大到快筛根本不触发」那份的前 k 条
    func testQueryTableFastFilterKeepsTopKIdentical() throws {
        let entries = tableEntries()
        let reader = try DictReader(binURL: try compileTableDict(entries))
        let all = reader.queryTable(prefix: "ha", limit: 100)   // 比整桶还大，一条也不会被快筛
        XCTAssertEqual(all.count, 65, "前提：limit 足够大时整桶 65 条全部入选")

        for k in [1, 2, 5, 20, 50] {
            let small = reader.queryTable(prefix: "ha", limit: k)
            XCTAssertEqual(small.map { $0.code }, Array(all.prefix(k)).map { $0.code },
                           "limit=\(k) 应等于全量结果的前 \(k) 条（快筛只是省分配，不是改语义）")
        }
    }

    /// 拼音路径（不开 preferShorterCode）仍只看词频：同词频不掺码长决胜，逐字节保持原行为
    func testPinyinPathIgnoresCodeLengthTieBreak() throws {
        let entries = tableEntries()
        let reader = try DictReader(binURL: try compileTableDict(entries))

        // 码表路径：词频层先到 haaaaaaaaa / hac，剩下的同词频按「码短→字序」排，整个序列被决胜规则唯一定下来
        XCTAssertEqual(reader.queryTable(prefix: "ha", limit: 5).map { $0.code },
                       ["haaaaaaaaa", "hac", "ha", "hab", "haz"],
                       "同词频下简码 hab / haz 必须抢在 ha0xx 这类长码之前")
        // 拼音路径：同词频保持原来的扫描序，不该把 haz 提到前面来
        XCTAssertFalse(reader.query(prefix: "ha", limit: 5).map { $0.code }.contains("haz"),
                       "拼音路径不该掺进码长决胜")
    }

    // MARK: - v3 索引格式：词条偏移表 + 二分定位
    //
    // v3 把索引区从「前两字符桶」换成「每条词条相对数据区起点的偏移表」（entryCount × UInt32 LE），
    // 查询时对偏移表二分定位前缀命中区间，复杂度从 O(桶大小) 降到 O(log n)。上面所有等价性用例
    // 的 bruteForce 参照直接扫数据区、不依赖索引区，因此已经逐前缀验证了二分定位没有漏桶 / 越界。
    // 下面两个用例锁定 v3 特有的两点：偏移表大小与词条数严格对齐；旧格式（version<3）回退路径
    // 在内存里补建同构偏移表后，查询结果与 bruteForce 完全一致。

    /// v3 索引区大小必须恰好是 entryCount × 4（偏移表与数据区严格对齐，不多不少一条）
    func testOffsetTableSizeMatchesEntryCount() throws {
        let (binURL, data) = try compileDictionary()
        XCTAssertEqual(data.readUInt16(at: 4), DictCompiler.binaryVersion,
                       "编译产物应是当前二进制版本")
        XCTAssertEqual(DictCompiler.binaryVersion, 3, "当前版本约定为 v3（偏移表索引）")
        let entryCount = Int(data.readUInt32(at: 8))
        let indexOffset = Int(data.readUInt32(at: 12))
        let dataOffset = Int(data.readUInt32(at: 16))
        XCTAssertEqual(entryCount, 20, "前提：测试词库共 20 条词条")
        XCTAssertEqual(dataOffset - indexOffset, entryCount * 4,
                       "v3 索引区应是 entryCount 条 UInt32 偏移，与数据区一一对齐")
        _ = binURL
    }

    /// 旧格式回退：把 version 字节改回 2，reader 走 buildOffsetsByScanning 在内存补建偏移表，
    /// 查询路径与 v3 完全一致，结果必须与 bruteForce 逐前缀等价。
    func testLegacyVersionFallbackMatchesBruteForce() throws {
        let (_, data) = try compileDictionary()
        var legacy = data
        legacy[4] = 2      // version 低字节
        legacy[5] = 0      // version 高字节 → 强制标记为旧格式 v2
        let legacyURL = tmpDir.appendingPathComponent("legacy.bin")
        try legacy.write(to: legacyURL, options: .atomic)

        let reader = try DictReader(binURL: legacyURL)
        for prefix in ["ni", "nih", "xin", "zhong", "zho", "n", "x", "z", "a", "zzz"] {
            _ = reader.query(prefix: prefix)   // 预热缓存路径
            let actual = reader.query(prefix: prefix, limit: 50)
            let expected = bruteForce(data, prefix: prefix, limit: 50)
            XCTAssertEqual(actual.map { $0.text }.sorted(), expected.map { $0.text }.sorted(),
                           "旧格式回退：前缀 \(prefix) 的结果集应与全表扫描一致")
            XCTAssertEqual(actual.map { $0.freq }.sorted(by: >), expected.map { $0.freq }.sorted(by: >),
                           "旧格式回退：前缀 \(prefix) 的词频顺序应与全表扫描一致")
        }
    }

    // MARK: - v4 侧车：prefixTopN 预排 + textIndex 反查
    //
    // v4 不改动 dict.bin 本体（仍 v3），另写两张可选侧车：dict.ptn.bin（大区间前缀的 top-N
    // 预排偏移）与 dict.ti.bin（text → 最短码）。读取器命中侧车即 O(N)/O(log n)，未命中回退
    // 区间扫。下面锁定：大区间前缀走侧车后结果仍与 bruteForce 一致；小区间前缀回退后也一致；
    // 反查侧车给出最短码。

    /// 编译任意 YAML 为二进制词库（侧车用例需要自定义词条规模）
    private func compileYAML(_ yaml: String, name: String) throws -> (binURL: URL, data: Data) {
        let yamlURL = tmpDir.appendingPathComponent("\(name).dict.yaml")
        try yaml.write(to: yamlURL, atomically: true, encoding: .utf8)
        let binURL = tmpDir.appendingPathComponent("\(name).bin")
        try DictCompiler.compile(yamlURL: yamlURL, outputURL: binURL, schemeType: .syllable)
        return (binURL, try Data(contentsOf: binURL))
    }

    /// 大区间前缀（>300 条）走 prefixTopN 侧车，结果集与词频序必须与 bruteForce 一致；
    /// 小区间前缀（未进侧车）回退区间扫，同样一致
    func testPrefixTopNSidecarMatchesBruteForceForLargeRange() throws {
        var lines = ["---", "columns:", "  - text", "  - code", "  - weight", "  - annotation", "..."]
        // 350 条共享前缀 "a"（> 阈值 300 → 进侧车）；词频互不相同避免并列歧义
        for i in 0..<350 {
            lines.append("词\(i)\ta\(String(format: "%03d", i))\t\(10000 - i)\t")
        }
        let (binURL, data) = try compileYAML(lines.joined(separator: "\n"), name: "ptn")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: tmpDir.appendingPathComponent("dict.ptn.bin").path),
            "编译应产出 prefixTopN 侧车")
        let reader = try DictReader(binURL: binURL)

        // 大区间前缀：走侧车
        for prefix in ["a", "a0", "a1"] {
            let actual = reader.query(prefix: prefix, limit: 50)
            let expected = bruteForce(data, prefix: prefix, limit: 50)
            XCTAssertEqual(actual.map { $0.text }.sorted(), expected.map { $0.text }.sorted(),
                           "侧车前缀 \(prefix) 的结果集应与全表扫描一致")
            XCTAssertEqual(actual.map { $0.freq }.sorted(by: >), expected.map { $0.freq }.sorted(by: >),
                           "侧车前缀 \(prefix) 的词频顺序应与全表扫描一致")
        }
        // 小区间前缀（未进侧车）：回退区间扫
        let small = reader.query(prefix: "a00", limit: 50)
        let smallExpected = bruteForce(data, prefix: "a00", limit: 50)
        XCTAssertEqual(small.map { $0.text }.sorted(), smallExpected.map { $0.text }.sorted(),
                       "小区间前缀回退路径应与全表扫描一致")
    }

    /// 反查侧车：同一文字多码时返回最短码；词库里没有的文字不出现
    func testTextIndexSidecarReverseLookupShortestCode() throws {
        let yaml = """
        ---
        columns:
          - text
          - code
          - weight
          - annotation
        ...
        春\tabcd\t100\t
        春\tab\t200\t
        春\ta\t50\t
        花\txy\t10\t
        """
        let (binURL, _) = try compileYAML(yaml, name: "ti")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: tmpDir.appendingPathComponent("dict.ti.bin").path),
            "编译应产出反查侧车")
        let reader = try DictReader(binURL: binURL)
        let codes = reader.shortestCodes(forTexts: ["春", "花", "无"])
        XCTAssertEqual(codes["春"], "a", "同字多码应返回最短码")
        XCTAssertEqual(codes["花"], "xy")
        XCTAssertNil(codes["无"], "词库里没有的文字不应出现在结果里")
    }
}
