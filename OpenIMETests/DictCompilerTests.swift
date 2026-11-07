import XCTest
@testable import OpenIMECore

final class DictCompilerTests: XCTestCase {

    private var tmpDir: URL!

    override func setUp() {
        super.setUp()
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DictCompilerTests_\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmpDir)
        super.tearDown()
    }

    // MARK: - 辅助

    private func writeYAML(_ content: String, name: String = "test.dict.yaml") -> URL {
        let url = tmpDir.appendingPathComponent(name)
        try! content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func outputURL(_ name: String = "out.bin") -> URL {
        tmpDir.appendingPathComponent(name)
    }

    // MARK: - 反查：文字 → 最短编码（DictReader.shortestCodes）

    /// 形码的「i + 拼音」反查靠它把候选的编码补出来。词库只按编码前缀建索引，
    /// 文字方向只能扫一趟数据区，所以这里守住三件事：同字多码取最短、多字词条查得到、
    /// 词库里没有的不混进来。
    func testShortestCodesScanForReverseLookup() throws {
        let yaml = """
        ---
        columns:
          - text
          - code
          - weight
          - annotation
        ...
        春\tchu\t1\t
        春\tc\t1\t
        春\taaa\t1\t
        天地\ttd\t1\t
        """
        let url = writeYAML(yaml)
        let out = outputURL()
        try DictCompiler.compile(yamlURL: url, outputURL: out, schemeType: .direct)
        let reader = try DictReader(binURL: out)
        let codes = reader.shortestCodes(forTexts: ["春", "天地", "查无此字"])
        XCTAssertEqual(codes["春"], "c", "同字多码应取最短那条（用户要的是最少按键）")
        XCTAssertEqual(codes["天地"], "td", "多字词条也要查得到：反查候选里本来就有词")
        XCTAssertNil(codes["查无此字"], "词库里没有的文字不该出现在结果里")
        XCTAssertTrue(reader.shortestCodes(forTexts: []).isEmpty, "空入参不该动词库")
    }

    // MARK: - 反查记忆（shortestCodeMemo）：提速不许改变任何可观察结果
    //
    // 词库只按编码前缀建索引，文字方向每个新字都要整趟数据区扫描；而 i+拼音 是逐击键
    // 调用的 —— 同一批高频字每按一次键就把整库重扫一遍，这就是「快码里打拼音非常卡」的成因。
    // 修法是按字记忆（连「查不到」也记为空串，免得它每次击键再拉一趟全场扫描）。
    // 风险在于记忆可能吞掉「重算才能得到」或「根本查不到」这两种答案，所以逐条钉死：
    // 结果幂等、清缓存后一致、记忆撑满上限时是清空重建而不是越用越错。

    /// 反查用词库：20 条文字，每个字都给一长一短两条编码（记忆存的必须是最短那条）
    private func reverseLookupReader() throws -> DictReader {
        var lines = ["---", "columns:", "  - text", "  - code", "  - weight", "  - annotation", "..."]
        for i in 0..<20 {
            lines.append("测\(i)\tca\(i)\t1\t")
            lines.append("测\(i)\tcccc\(i)\t1\t")
        }
        let url = writeYAML(lines.joined(separator: "\n") + "\n", name: "reverse.dict.yaml")
        let out = outputURL("reverse.bin")
        try DictCompiler.compile(yamlURL: url, outputURL: out, schemeType: .direct)
        return try DictReader(binURL: out)
    }

    /// 幂等：同一批文字重复查，答案必须与第一次逐字相同；「词库里没有」也不能第二次冒出来
    func testShortestCodesAreIdempotentAcrossMemo() throws {
        let reader = try reverseLookupReader()
        let real = (0..<20).map { "测\($0)" }
        let texts = real + ["查无此字", "另一个也没有的"]

        let first = reader.shortestCodes(forTexts: texts)
        XCTAssertEqual(Set(first.keys), Set(real), "只有词库里有的文字才该出现在结果里")
        XCTAssertEqual(first["测1"], "ca1", "记忆里存的也是最短那条")

        // 第二次全部命中记忆，根本不扫描：结果必须与扫描出来的那份完全一致
        XCTAssertEqual(reader.shortestCodes(forTexts: texts), first,
                       "记忆命中与重新扫描必须给出同一份答案")
        // 已记忆的和全新的混着查：没查到的新字不该混进结果
        XCTAssertEqual(reader.shortestCodes(forTexts: texts + ["新字"]), first,
                       "新加的查不到的字不该凭空多出一项")
    }

    /// 内存告警清缓存后重建，结果与缓存命中时一致（缓存只是派生数据）
    func testPurgeCachesKeepsShortestCodesIdentical() throws {
        let reader = try reverseLookupReader()
        let texts = (0..<20).map { "测\($0)" }
        let cached = reader.shortestCodes(forTexts: texts)
        reader.purgeCaches()
        XCTAssertEqual(reader.shortestCodes(forTexts: texts), cached, "清缓存后重扫应给出同一份答案")
    }

    /// 记忆撑满上限（shortestCodeMemoLimit）：整表清空重建，而不是继续累积或给出半截答案
    func testShortestCodesMemoOverflowRebuilds() throws {
        let reader = try reverseLookupReader()
        let real = (0..<20).map { "测\($0)" }
        // 两批各 2500 个文字（绝大多数词库里没有），第二批会把记忆推过 4000 的上限
        let batchA = real + (1000..<3480).map { "字\($0)" }
        let batchB = real + (4000..<6480).map { "字\($0)" }

        let a = reader.shortestCodes(forTexts: batchA)
        let b = reader.shortestCodes(forTexts: batchB)
        XCTAssertEqual(Set(a.keys), Set(real), "第一批的命中不受上限影响")
        XCTAssertEqual(Set(b.keys), Set(real), "第二批同理")
        // 上限触发后第一批的记忆已被清掉：再查必须重扫出同样的答案，而不是落空
        XCTAssertEqual(reader.shortestCodes(forTexts: batchA), a, "记忆清空重建后答案不变")
    }

    // MARK: - 外部格式基础解析

    func testBasicExternalFormat() throws {
        let yaml = """
---
columns:
  - text
  - code
  - weight
  - annotation
...
你好\tnihao\t1000\tnǐ hǎo
世界\tshijie\t800\tshì jiè
"""
        let url = writeYAML(yaml)
        let out = outputURL()
        try DictCompiler.compile(yamlURL: url, outputURL: out, schemeType: .syllable)
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.path))
        let data = try Data(contentsOf: out)
        XCTAssertTrue(data.count > 20)
        // 验证 magic
        XCTAssertEqual(String(bytes: data[0..<4], encoding: .utf8), "OIME")
    }

    func testEntryCountInBinaryHeader() throws {
        let yaml = """
---
columns:
  - text
  - code
  - weight
  - annotation
...
你好\tnihao\t1000\t
世界\tshijie\t800\t
中国\tzhongguo\t900\t
"""
        let url = writeYAML(yaml)
        let out = outputURL()
        try DictCompiler.compile(yamlURL: url, outputURL: out, schemeType: .syllable)
        let data = try Data(contentsOf: out)
        // entryCount 在 header offset 8
        let count = data.readUInt32(at: 8)
        XCTAssertEqual(Int(count), 3)
    }

    func testSchemeTypeBinaryCode() throws {
        let yaml = "---\ncolumns:\n  - text\n  - code\n  - weight\n  - annotation\n...\n你好\tnihao\t100\t\n"
        let url = writeYAML(yaml)

        for (type, expectedCode): (SchemeType, UInt8) in [(.direct, 0), (.syllable, 1), (.doubleSyllable, 2)] {
            let out = outputURL("out_\(type).bin")
            try DictCompiler.compile(yamlURL: url, outputURL: out, schemeType: type)
            let data = try Data(contentsOf: out)
            XCTAssertEqual(data[6], expectedCode, "schemeType byte for \(type)")
        }
    }

    // MARK: - 列顺序灵活性

    func testCodeTextWeightColumnOrder() throws {
        // columns 声明为 code/text/weight（非默认顺序）
        let yaml = """
---
columns:
  - code
  - text
  - weight
  - annotation
...
nihao\t你好\t1000\t
shijie\t世界\t800\t
"""
        let url = writeYAML(yaml)
        let out = outputURL()
        let cols = try DictCompiler.compileMultiple(yamlURLs: [url], outputURL: out, schemeType: .syllable)
        XCTAssertTrue(cols.contains("text"))
        XCTAssertTrue(cols.contains("code"))
        let data = try Data(contentsOf: out)
        XCTAssertEqual(data.readUInt32(at: 8), 2)
    }

    func testAnnotationColumnDetected() throws {
        let yaml = """
---
columns:
  - text
  - code
  - weight
  - annotation
...
你好\tnihao\t1000\tnǐ hǎo
"""
        let url = writeYAML(yaml)
        let out = outputURL()
        let cols = try DictCompiler.compileMultiple(yamlURLs: [url], outputURL: out, schemeType: .syllable)
        XCTAssertTrue(cols.contains("annotation"))
    }

    // MARK: - 跳过行逻辑

    func testSpaceSeparatedLineIsSkipped() throws {
        let yaml = """
---
columns:
  - text
  - code
  - weight
  - annotation
...
你好 nihao 1000\t
正常\tnormal\t500\t
"""
        let url = writeYAML(yaml)
        let out = outputURL()
        let (_, report) = try DictCompiler.compileMultipleWithReport(
            yamlURLs: [url], outputURL: out, schemeType: .syllable)
        XCTAssertEqual(report.totalParsed, 1)
        XCTAssertEqual(report.totalSkipped, 1)
        XCTAssertTrue(report.files[0].skippedLines[0].reason.contains("Tab"))
    }

    func testEmptyTextColumnIsSkipped() throws {
        let yaml = "---\ncolumns:\n  - text\n  - code\n  - weight\n  - annotation\n...\n\tnihao\t500\t\n正常\tnormal\t500\t\n"
        let url = writeYAML(yaml)
        let out = outputURL()
        let (_, report) = try DictCompiler.compileMultipleWithReport(
            yamlURLs: [url], outputURL: out, schemeType: .syllable)
        XCTAssertEqual(report.totalParsed, 1)
        XCTAssertEqual(report.totalSkipped, 1)
        // reason 为中文"词（text 列）为空"
        XCTAssertFalse(report.files[0].skippedLines[0].reason.isEmpty)
    }

    func testEmptyCodeColumnIsSkipped() throws {
        let yaml = "---\ncolumns:\n  - text\n  - code\n  - weight\n  - annotation\n...\n你好\t\t500\t\n正常\tnormal\t500\t\n"
        let url = writeYAML(yaml)
        let out = outputURL()
        let (_, report) = try DictCompiler.compileMultipleWithReport(
            yamlURLs: [url], outputURL: out, schemeType: .syllable)
        XCTAssertEqual(report.totalParsed, 1)
        XCTAssertEqual(report.totalSkipped, 1)
        XCTAssertTrue(report.files[0].skippedLines[0].reason.contains("code"))
    }

    func testCommentLinesAreIgnored() throws {
        let yaml = "---\ncolumns:\n  - text\n  - code\n  - weight\n  - annotation\n...\n# 这是注释\n你好\tnihao\t1000\t\n"
        let url = writeYAML(yaml)
        let out = outputURL()
        let (_, report) = try DictCompiler.compileMultipleWithReport(
            yamlURLs: [url], outputURL: out, schemeType: .syllable)
        XCTAssertEqual(report.totalParsed, 1)
        XCTAssertEqual(report.totalSkipped, 0)
    }

    func testWeightDefaultsTo500WhenNonEmpty() throws {
        // weight 列为空时默认 500，annotation 有内容，4 列满足条件，正常解析
        let yaml = "---\ncolumns:\n  - text\n  - code\n  - weight\n  - annotation\n...\n你好\tnihao\t\t注释\n"
        let url = writeYAML(yaml)
        let out = outputURL()
        let (_, report) = try DictCompiler.compileMultipleWithReport(
            yamlURLs: [url], outputURL: out, schemeType: .syllable)
        // weight 为空默认 500，annotation 有内容，4 列满足条件
        XCTAssertEqual(report.totalParsed, 1)
        XCTAssertEqual(report.totalSkipped, 0)
        let data = try Data(contentsOf: out)
        XCTAssertEqual(data.readUInt32(at: 8), 1)
    }

    func testWeightEmptyTrailingTabParses() throws {
        // trim fix 后：weight 为空的行（text\tcode\t\t）末尾 tab 不再被 strip，
        // 仍有 4 列，满足列数要求，条目正常解析（weight 默认 500）
        let yaml = "---\ncolumns:\n  - text\n  - code\n  - weight\n  - annotation\n...\n你好\tnihao\t\t\n正常\tnihao\t1000\t注释\n"
        let url = writeYAML(yaml)
        let out = outputURL()
        let (_, report) = try DictCompiler.compileMultipleWithReport(
            yamlURLs: [url], outputURL: out, schemeType: .syllable)
        XCTAssertEqual(report.totalParsed, 2)
        XCTAssertEqual(report.totalSkipped, 0)
    }

    // MARK: - CRLF 行尾（上游方案包 / Windows 导出常见）

    func testCRLFLineEndingsDoNotCorruptCode() throws {
        // code 是最后一列时，行尾 \r 若不剥掉会粘在码上（t\r / jafm\r），整表查不到。
        // 归一在 parseFileContent 入口做，头部与数据区一次到位。
        let yaml = "---\r\ncolumns:\r\n  - text\r\n  - code\r\n...\r\n我\tt\r\n今天\tjafm\r\n"
        let url = writeYAML(yaml)
        let out = outputURL()
        let (_, report) = try DictCompiler.compileMultipleWithReport(
            yamlURLs: [url], outputURL: out, schemeType: .direct)
        XCTAssertEqual(report.totalParsed, 2)
        XCTAssertEqual(report.totalSkipped, 0)
        let reader = try DictReader(binURL: out)
        XCTAssertEqual(reader.queryExact(code: "jafm").first?.text, "今天", "CRLF 不应污染末列 code")
        XCTAssertEqual(reader.queryExact(code: "t").first?.text, "我")
    }

    func testBOMPrefixDoesNotBreakHeader() throws {
        // 带 BOM 的文件（超强两笔主表就是）头部解析不能被 BOM 干扰
        let yaml = "\u{FEFF}---\ncolumns:\n  - text\n  - code\n...\n你好\tnihao\n"
        let url = writeYAML(yaml)
        let out = outputURL()
        let (_, report) = try DictCompiler.compileMultipleWithReport(
            yamlURLs: [url], outputURL: out, schemeType: .direct)
        XCTAssertEqual(report.totalParsed, 1)
        XCTAssertEqual(report.totalSkipped, 0)
    }

    // MARK: - 空词库

    func testEmptyDictThrows() throws {
        let yaml = "---\ncolumns:\n  - text\n  - code\n  - weight\n  - annotation\n...\n"
        let url = writeYAML(yaml)
        let out = outputURL()
        XCTAssertThrowsError(try DictCompiler.compile(yamlURL: url, outputURL: out, schemeType: .syllable)) { err in
            XCTAssertTrue(err is DictCompiler.CompileError)
        }
    }

    func testAllSkippedLinesThrowsEmptyDict() throws {
        // 全是空格分隔的行，全部跳过，得到 emptyDict
        let yaml = "---\ncolumns:\n  - text\n  - code\n  - weight\n  - annotation\n...\nnihao 你好 1000\n"
        let url = writeYAML(yaml)
        let out = outputURL()
        XCTAssertThrowsError(
            try DictCompiler.compileMultiple(yamlURLs: [url], outputURL: out, schemeType: .syllable)
        )
    }

    // MARK: - 无 front matter

    func testNoFrontMatterParsesAsData() throws {
        // 没有 --- 分隔符，整个文件按数据区处理（默认列顺序 text/code/weight）
        let yaml = "你好\tnihao\t1000\t\n世界\tshijie\t800\t\n"
        let url = writeYAML(yaml)
        let out = outputURL()
        try DictCompiler.compile(yamlURL: url, outputURL: out, schemeType: .syllable)
        let data = try Data(contentsOf: out)
        XCTAssertEqual(data.readUInt32(at: 8), 2)
    }

    // MARK: - normalizeCode（去空格）

    func testNormalizeCodeStripsSpaces() throws {
        let yaml = "---\ncolumns:\n  - text\n  - code\n  - weight\n  - annotation\n...\n你好\tni hao\t1000\t\n"
        let url = writeYAML(yaml)
        let out = outputURL()
        try DictCompiler.compileMultiple(
            yamlURLs: [url], outputURL: out, schemeType: .syllable, normalizeCode: "strip_spaces")
        let data = try Data(contentsOf: out)
        XCTAssertEqual(data.readUInt32(at: 8), 1)
    }

    // MARK: - 多文件合并

    func testMultipleFilesAreMerged() throws {
        let yaml1 = "---\ncolumns:\n  - text\n  - code\n  - weight\n  - annotation\n...\n你好\tnihao\t1000\t\n"
        let yaml2 = "---\ncolumns:\n  - text\n  - code\n  - weight\n  - annotation\n...\n世界\tshijie\t800\t\n"
        let url1 = writeYAML(yaml1, name: "a.dict.yaml")
        let url2 = writeYAML(yaml2, name: "b.dict.yaml")
        let out = outputURL()
        try DictCompiler.compileMultiple(yamlURLs: [url1, url2], outputURL: out, schemeType: .syllable)
        let data = try Data(contentsOf: out)
        XCTAssertEqual(data.readUInt32(at: 8), 2)
    }

    func testUnreadableFileIsReportedNotCrashed() throws {
        let missingURL = tmpDir.appendingPathComponent("nonexistent.yaml")
        let goodYAML = "---\ncolumns:\n  - text\n  - code\n  - weight\n  - annotation\n...\n你好\tnihao\t1000\t\n"
        let goodURL = writeYAML(goodYAML)
        let out = outputURL()
        let (_, report) = try DictCompiler.compileMultipleWithReport(
            yamlURLs: [missingURL, goodURL], outputURL: out, schemeType: .syllable)
        XCTAssertEqual(report.files.count, 2)
        XCTAssertEqual(report.totalParsed, 1)
    }

    // MARK: - OpenIME 单文件格式作为词库文件（compileMultiple 路径）

    func testOpenIMESingleFileInDictDir() throws {
        // OpenIME 单文件格式：header 在 --- 之前，词条在 --- 之后
        let yaml = """
id: test
name: 测试方案
type: syllable
---
你好\tnihao\t1000\t
世界\tshijie\t800\t
"""
        let url = writeYAML(yaml, name: "main.dict.yaml")
        let out = outputURL()
        let (_, report) = try DictCompiler.compileMultipleWithReport(
            yamlURLs: [url], outputURL: out, schemeType: .syllable)
        XCTAssertEqual(report.totalParsed, 2, "OpenIME 单文件格式词条应被正确解析")
        XCTAssertEqual(report.totalSkipped, 0)
    }

    func testOpenIMESingleFileMixedWithExternalFile() throws {
        // 混合：一个 OpenIME 单文件 + 一个外部格式文件，合并编译
        let openIMEYaml = "name: 测试\n---\n你好\tnihao\t1000\t\n"
        let externalYaml = "---\ncolumns:\n  - text\n  - code\n  - weight\n  - annotation\n...\n世界\tshijie\t800\t\n"
        let url1 = writeYAML(openIMEYaml, name: "a.dict.yaml")
        let url2 = writeYAML(externalYaml, name: "b.dict.yaml")
        let out = outputURL()
        let (_, report) = try DictCompiler.compileMultipleWithReport(
            yamlURLs: [url1, url2], outputURL: out, schemeType: .syllable)
        XCTAssertEqual(report.totalParsed, 2, "OpenIME + 外部格式混合词库应合并为 2 条")
    }

    func testLogTextContainsSummary() throws {
        let yaml = "---\ncolumns:\n  - text\n  - code\n  - weight\n  - annotation\n...\n你好\tnihao\t1000\t\n"
        let url = writeYAML(yaml)
        let out = outputURL()
        let (_, report) = try DictCompiler.compileMultipleWithReport(
            yamlURLs: [url], outputURL: out, schemeType: .syllable)
        let log = report.logText()
        XCTAssertTrue(log.contains("总词条数：1"))
        XCTAssertTrue(log.contains("OpenIME"))
    }

    func testLogTextWarnsOnZeroEntries() throws {
        // 给一个无效文件和一个正常文件（但先用全跳过触发 totalParsed=0 分支）
        // 这里用 FileParseReport 验证 logText 含警告
        let report = DictCompiler.CompileReport(
            files: [],
            totalParsed: 0,
            totalSkipped: 0,
            normalizeCode: nil,
            schemeType: .syllable
        )
        XCTAssertTrue(report.logText().contains("警告"))
    }

    // MARK: - 当前版本头部：数据区之后不再有附加区
    //
    // 早先的版本会在拼音词库末尾另写一段九宫数字码索引（tailOffset 指向它）。九宫形态下线后
    // 这段不再产出，但字段与 24 字节头都保留 —— 读侧还要靠它把老文件的尾巴挡在扫描之外。

    private func writePinyinDict() throws -> URL {
        let yaml = """
---
columns:
  - text
  - code
  - weight
  - annotation
...
你好\tnihao\t1000\t
你好吗\tnihaoma\t900\t
米\tmi\t300\t
你\tni\t200\t
"""
        let url = writeYAML(yaml)
        let out = outputURL("pinyin.bin")
        try DictCompiler.compile(yamlURL: url, outputURL: out, schemeType: .syllable)
        return out
    }

    func testPinyinSchemeWritesCurrentVersionHeaderWithoutTail() throws {
        let out = try writePinyinDict()
        let data = try Data(contentsOf: out)

        XCTAssertEqual(data.readUInt16(at: 4), DictCompiler.binaryVersion, "词库应当写成当前版本")
        XCTAssertEqual(DictCompiler.binaryVersion(at: out), DictCompiler.binaryVersion)
        XCTAssertEqual(data.readUInt32(at: 20), 0, "新编词库的数据区之后没有附加区")
    }

    func testDirectSchemeHasNoTailEither() throws {
        // 形码（五笔等）的编码不是拼音，从来就没有这段附加区
        let yaml = "---\ncolumns:\n  - text\n  - code\n  - weight\n  - annotation\n...\n你好\tabcd\t1000\t\n"
        let url = writeYAML(yaml, name: "direct.dict.yaml")
        let out = outputURL("direct.bin")
        try DictCompiler.compile(yamlURL: url, outputURL: out, schemeType: .direct)
        let data = try Data(contentsOf: out)
        XCTAssertEqual(data.readUInt32(at: 20), 0, "非拼音方案同样不该有附加区偏移")
    }

    /// 老词库在数据区后面挂着一段附加区，tailOffset 指向它的起点。
    /// 前缀查询按索引区定位，压根不碰尾巴；而「从已编译 dict.bin 补建二元语法侧车」那趟
    /// 是顺着数据区逐条解的，必须按 tailOffset 收尾 —— 越过边界就会把附加区当词条继续解，
    /// 判定成「数据区损坏」而静默放弃构建（表现为长串切分的候选质量莫名变差）。
    func testLegacyTailRegionIsSkippedWhenScanning() throws {
        let out = try writePinyinDict()
        var data = try Data(contentsOf: out)
        let tailStart = data.count
        data.append(Data(repeating: 0xFF, count: 64))   // 冒充当年那段九宫索引
        let field = withUnsafeBytes(of: UInt32(tailStart).littleEndian) { Array($0) }
        for i in 0..<4 { data[20 + i] = field[i] }
        let legacy = outputURL("legacy_tail.bin")
        try data.write(to: legacy)

        let reader = try DictReader(binURL: legacy)
        XCTAssertEqual(reader.query(prefix: "ni").map { $0.text }, ["你好", "你好吗", "你"],
                       "尾巴不该影响前缀查询")

        // 编译期顺手写好的那份侧车先删掉，复现「老包只有 dict.bin、没有侧车」的现场
        let lmURL = outputURL("dict.lm.bin")
        try? FileManager.default.removeItem(at: lmURL)
        XCTAssertTrue(try DictCompiler.buildLanguageModelIfNeeded(at: legacy),
                      "扫描按 tailOffset 收尾，数据区完整解出才谈得上构建侧车")
        XCTAssertFalse(try Data(contentsOf: lmURL).isEmpty, "侧车应当真的落盘")
        XCTAssertFalse(try DictCompiler.buildLanguageModelIfNeeded(at: legacy),
                       "侧车已存在时不该重复扫描")

        // 反证：尾巴还在、但 tailOffset 被抹成 0（等于没有边界可依），同一趟扫描就会解进附加区
        for i in 0..<4 { data[20 + i] = 0 }
        let broken = outputURL("broken_tail.bin")
        try data.write(to: broken)
        try? FileManager.default.removeItem(at: lmURL)
        XCTAssertFalse(try DictCompiler.buildLanguageModelIfNeeded(at: broken),
                       "失去边界时扫描会把附加区当词条解、判成数据区损坏而放弃构建")
    }

    /// 内存告警清缓存后，查询重建结果必须一致：缓存只是派生数据，purge 不能改变任何可观察行为
    func testPurgeCachesKeepsQueryResultsIdentical() throws {
        let reader = try DictReader(binURL: try writePinyinDict())
        let before = [reader.query(prefix: "ni").map { $0.text },
                      reader.query(prefix: "m").map { $0.text }]

        reader.purgeCaches()

        XCTAssertEqual([reader.query(prefix: "ni").map { $0.text },
                        reader.query(prefix: "m").map { $0.text }], before,
                       "清缓存后重建结果应一致")
    }

    // MARK: - 通用字频叠加（零词频码表）

    /// CharFrequency：高频字打分更高（越大越常用），非汉字 / 未收录为 0
    func testCharFrequencyScoresCommonCharsHigher() {
        XCTAssertFalse(CharFrequency.isEmpty)
        XCTAssertGreaterThan(CharFrequency.count, 8000, "《通用规范汉字表》应有 8000+ 字")
        XCTAssertGreaterThan(CharFrequency.score(of: "的"), CharFrequency.score(of: "是"))
        XCTAssertGreaterThan(CharFrequency.score(of: "是"), CharFrequency.score(of: "我"))
        XCTAssertGreaterThan(CharFrequency.score(of: "我"), CharFrequency.score(of: "好"))
        XCTAssertEqual(CharFrequency.score(of: "A"), 0, "非汉字 / 未收录字打分为 0")
    }

    /// weightsAreUniform：全库词频完全一致才 true；有区分度 / 空数组都为 false
    func testWeightsAreUniformDetection() {
        XCTAssertTrue(DictCompiler.weightsAreUniform([
            DictEntry(code: "a", text: "的", freq: 1, annotation: nil),
            DictEntry(code: "b", text: "是", freq: 1, annotation: nil),
        ]))
        XCTAssertFalse(DictCompiler.weightsAreUniform([
            DictEntry(code: "a", text: "的", freq: 1, annotation: nil),
            DictEntry(code: "b", text: "是", freq: 2, annotation: nil),
        ]), "有区分度（虎码这类）不算零词频")
        XCTAssertFalse(DictCompiler.weightsAreUniform([]))
    }

    /// overlayFrequency：常用单字即便编码字母序靠后，叠加后打分也更高；
    /// 单字档整体高于词组档（码表补全里简码常用单字永远排在词组之前）
    func testOverlayFrequencyBoostsCommonSingleChar() {
        let overlaid = DictCompiler.overlayFrequency([
            DictEntry(code: "hzz", text: "的", freq: 1, annotation: nil),    // 最高频字，编码字母序最后
            DictEntry(code: "haa", text: "好", freq: 1, annotation: nil),
            DictEntry(code: "hab", text: "好人", freq: 1, annotation: nil),  // 词组
        ])
        func freq(_ text: String) -> Int { overlaid.first { $0.text == text }!.freq }
        XCTAssertGreaterThan(freq("的"), freq("好"), "更高频的字打分更高，与编码字母序无关")
        XCTAssertGreaterThan(freq("好"), freq("好人"), "单字档整体高于词组档")
    }

    /// 编译期门控：只看「全库词频是否一致」，不看码制——零词频的形码与拼音都叠加；
    /// 自带真实权重的码表（虎码）不叠加，逐字节保持原样
    func testFrequencyOverlayGating() throws {
        let uniformDirect = writeYAML("---\ncolumns:\n  - text\n  - code\n  - weight\n...\n的\thzz\t1\n好\thaa\t1\n", name: "u_direct.yaml")
        let (_, r1) = try DictCompiler.compileMultipleWithReport(
            yamlURLs: [uniformDirect], outputURL: outputURL("u_direct.bin"), schemeType: .direct)
        XCTAssertTrue(r1.frequencyOverlaid, "零词频形码码表应叠加通用字频")

        let weightedDirect = writeYAML("---\ncolumns:\n  - text\n  - code\n  - weight\n...\n的\thzz\t100\n好\thaa\t50\n", name: "w_direct.yaml")
        let (_, r2) = try DictCompiler.compileMultipleWithReport(
            yamlURLs: [weightedDirect], outputURL: outputURL("w_direct.bin"), schemeType: .direct)
        XCTAssertFalse(r2.frequencyOverlaid, "自带真实权重的码表（虎码）不叠加")

        let uniformSyllable = writeYAML("---\ncolumns:\n  - text\n  - code\n  - weight\n...\n的\tde\t1\n好\thao\t1\n", name: "u_syl.yaml")
        let (_, r3) = try DictCompiler.compileMultipleWithReport(
            yamlURLs: [uniformSyllable], outputURL: outputURL("u_syl.bin"), schemeType: .syllable)
        XCTAssertTrue(r3.frequencyOverlaid, "门控已泛化：无权重拼音方案（全库词频一致）也能受益")

        let weightedSyllable = writeYAML("---\ncolumns:\n  - text\n  - code\n  - weight\n...\n的\tde\t100\n好\thao\t50\n", name: "w_syl.yaml")
        let (_, r4) = try DictCompiler.compileMultipleWithReport(
            yamlURLs: [weightedSyllable], outputURL: outputURL("w_syl.bin"), schemeType: .syllable)
        XCTAssertFalse(r4.frequencyOverlaid, "自带真实权重的拼音方案（雾凇）不叠加")
    }

    /// 三档尺度：提供真实词频时，单字 > 命中语料的词组（按真实词频降序）> 未命中的兜底词组
    func testOverlayFrequencyBandsSingleCoveredUncovered() {
        let entries = [
            DictEntry(code: "a", text: "的", freq: 1, annotation: nil),    // 单字
            DictEntry(code: "b", text: "你好", freq: 1, annotation: nil),   // covered（高频词）
            DictEntry(code: "c", text: "中国", freq: 1, annotation: nil),   // covered（低频词）
            DictEntry(code: "d", text: "龘齾", freq: 1, annotation: nil),   // uncovered（语料没有）
        ]
        let overlaid = DictCompiler.overlayFrequency(entries, wordFreqs: ["你好": 100000, "中国": 2000])
        func freq(_ t: String) -> Int { overlaid.first { $0.text == t }!.freq }
        XCTAssertGreaterThan(freq("的"), freq("你好"), "单字档 > covered 词组档")
        XCTAssertGreaterThan(freq("你好"), freq("中国"), "covered 内部按真实词频降序")
        XCTAssertGreaterThan(freq("中国"), freq("龘齾"), "covered 词组 > uncovered 兜底词组")
    }

    /// 回归保护：不提供词频语料（wordFreqs 为空）时，词组走几何均值兜底，与旧行为一致——
    /// 常用字构成的词组打分高于生僻字构成的，且都低于单字档
    func testOverlayFrequencyFallsBackToGeometricMeanWithoutCorpus() {
        let entries = [
            DictEntry(code: "a", text: "的", freq: 1, annotation: nil),
            DictEntry(code: "b", text: "好的", freq: 1, annotation: nil),   // 常用字构成
            DictEntry(code: "c", text: "龘齾", freq: 1, annotation: nil),   // 生僻字构成
        ]
        let overlaid = DictCompiler.overlayFrequency(entries)
        func freq(_ t: String) -> Int { overlaid.first { $0.text == t }!.freq }
        XCTAssertGreaterThan(freq("的"), freq("好的"), "单字档高于词组档")
        XCTAssertGreaterThan(freq("好的"), freq("龘齾"), "常用字构成的词组几何均值更高")
    }
}

