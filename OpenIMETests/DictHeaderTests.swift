import XCTest
@testable import OpenIMECore

// MARK: - 词库文件头解析
//
// 第三方词库能不能「装得进」，全看这段头部解析得对不对：
// columns 决定哪一列是词、哪一列是码，import_tables 决定这份码表由哪几张表合成。
// 解析原则是「只认需要的键，读不懂的忽略而不是报错」，所以未知列、未知字段都要有测试锁定。

final class DictHeaderTests: XCTestCase {

    private var tmpDir: URL!

    override func setUp() {
        super.setUp()
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DictHeaderTests_\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmpDir)
        tmpDir = nil
        super.tearDown()
    }

    // MARK: - 辅助

    /// 在 tmpDir 下（可带子路径）写一份词库文件
    @discardableResult
    private func write(_ content: String, name: String) -> URL {
        let url = tmpDir.appendingPathComponent(name)
        try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try! content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func outputURL(_ name: String = "out.bin") -> URL {
        tmpDir.appendingPathComponent(name)
    }

    /// 读回编译好的词条（按编码精确查）
    private func entries(_ binURL: URL, code: String) throws -> [Candidate] {
        try DictReader(binURL: binURL).queryExact(code: code)
    }

    private let threeColumns = "columns:\n  - text\n  - code\n  - weight\n"

    /// 断言 front matter 形态（枚举没合成 Equatable，用模式匹配）
    private func assertKind(_ expected: FrontMatterKind,
                            _ front: FrontMatter,
                            file: StaticString = #filePath,
                            line: UInt = #line) {
        switch (expected, front.kind) {
        case (.dictYaml, .dictYaml), (.openIMESingleFile, .openIMESingleFile), (.none, .none):
            break
        default:
            XCTFail("front matter 形态不符（期望 \(expected)，实际 \(front.kind)）", file: file, line: line)
        }
    }

    // MARK: - front matter 三种形态

    func testKindDetectedByDotsMarker() {
        let front = DictHeaderParser.parse("---\nname: x\n...\n你好\tnihao\n")
        assertKind(.dictYaml, front)
        XCTAssertEqual(front.dataStartIndex, 3)
        XCTAssertEqual(front.header.name, "x")
    }

    /// OpenIME 单文件格式：只有 `---` 分隔符、没有 `...`，头部在它上面、词条在它下面
    func testOpenIMESingleFileKindDetectedByDashOnly() {
        let front = DictHeaderParser.parse("name: x\ntype: syllable\n---\n你好\tnihao\n")
        assertKind(.openIMESingleFile, front)
        XCTAssertEqual(front.dataStartIndex, 3, "`---` 就是分隔符，词条从它下一行开始")
        XCTAssertEqual(front.header.name, "x")
        XCTAssertEqual(front.headerLineRange, 0..<2)
    }

    func testNoMarkerMeansWholeFileIsData() {
        let front = DictHeaderParser.parse("你好\tnihao\n世界\tshijie\n")
        assertKind(.none, front)
        XCTAssertEqual(front.dataStartIndex, 0)
        XCTAssertTrue(front.header.columns.isEmpty)
    }

    /// CRLF 文件（Windows 下整理的外部词库）：`...` 后面跟着 \r，
    /// 逐行 trim 判等才认得出来。以前按整行字符串比较，这类文件一律被判成 OpenIME 单文件格式，
    /// front matter 的行全被当成词条，报一堆「列数不足」
    func testCRLFFileIsRecognizedAsDictYaml() {
        let content = "---\r\nname: tiger\r\ncolumns:\r\n  - text\r\n  - code\r\n...\r\n我\tt\r\n"
        let front = DictHeaderParser.parse(content)
        assertKind(.dictYaml, front, line: #line)
        XCTAssertEqual(front.header.name, "tiger")
        XCTAssertEqual(front.header.columns, ["text", "code"])
        // splitLines 去掉了行尾 \r，行号才与文件对得上
        XCTAssertEqual(DictHeaderParser.splitLines(content).count, 8)
        XCTAssertFalse(DictHeaderParser.splitLines(content).contains { $0.hasSuffix("\r") })
    }

    /// front matter 的行不计入跳过统计：头部里的 `columns:` 不是格式错误的词条
    func testFrontMatterLinesAreNotCountedAsSkipped() throws {
        let yaml = "---\nname: test\nversion: 1.0\nsort: by_weight\n" + threeColumns + "...\n你好\tnihao\t1000\n"
        let url = write(yaml, name: "clean.dict.yaml")
        let out = outputURL()
        let (_, report) = try DictCompiler.compileMultipleWithReport(
            yamlURLs: [url], outputURL: out, schemeType: .syllable)
        XCTAssertEqual(report.totalParsed, 1)
        XCTAssertEqual(report.totalSkipped, 0, "头部行不该被算成跳过的词条")
    }

    func testCRLFFileCompilesWithoutSkippedNoise() throws {
        let content = "---\r\nname: test\r\n" +
            threeColumns.replacingOccurrences(of: "\n", with: "\r\n") +
            "...\r\n你好\tnihao\t1000\r\n世界\tshijie\t900\r\n"
        let url = write(content, name: "crlf.dict.yaml")
        let out = outputURL()
        let (_, report) = try DictCompiler.compileMultipleWithReport(
            yamlURLs: [url], outputURL: out, schemeType: .syllable)
        XCTAssertEqual(report.totalParsed, 2)
        XCTAssertEqual(report.totalSkipped, 0)
        XCTAssertEqual(try entries(out, code: "nihao").map { $0.text }, ["你好"])
    }

    // MARK: - columns

    func testColumnsKeepDeclaredOrder() {
        let front = DictHeaderParser.parse(
            "---\ncolumns:\n  - code\n  - text\n  - weight\n  - stem\n...\n")
        XCTAssertEqual(front.header.columns, ["code", "text", "weight", "stem"],
                       "列序必须原样保留，数据列靠它定位")
    }

    func testColumnOrderDrivesFieldMapping() throws {
        // 列序反过来声明（code 在前），词与码不能张冠李戴
        let yaml = "---\ncolumns:\n  - code\n  - text\n  - weight\n...\nnihao\t你好\t1000\n"
        let url = write(yaml, name: "reversed.dict.yaml")
        let out = outputURL()
        try DictCompiler.compile(yamlURL: url, outputURL: out, schemeType: .syllable)
        let hits = try entries(out, code: "nihao")
        XCTAssertEqual(hits.map { $0.text }, ["你好"])
    }

    func testColumnListItemWithTrailingCommentIsCleaned() {
        // 快码里 `- cqkm_cm        #主码表` 这种写法很常见，不剥掉注释就会拿整串当表名
        let front = DictHeaderParser.parse(
            "---\nimport_tables:\n  - cqkm_cm        #主码表\n  - 'quoted'\n...\n")
        XCTAssertEqual(front.header.importTables, ["cqkm_cm", "quoted"])
    }

    // MARK: - 未知列

    func testUnknownColumnIsIgnoredAndReported() throws {
        let yaml = "---\ncolumns:\n  - text\n  - code\n  - weight\n  - radical\n...\n你\tni\t100\t乚\n"
        let url = write(yaml, name: "unknown.dict.yaml")
        let out = outputURL()
        let (_, report) = try DictCompiler.compileMultipleWithReport(
            yamlURLs: [url], outputURL: out, schemeType: .syllable)
        XCTAssertEqual(report.totalParsed, 1)
        XCTAssertEqual(report.totalSkipped, 0)
        XCTAssertEqual(report.ignoredColumns, ["radical"], "不认识的列要记进报告，而不是当成注释")
        XCTAssertNil(try entries(out, code: "ni").first?.annotation,
                     "未知列的内容不能变成注释")
    }

    /// 以前的 `default: if colAnno < 0 { colAnno = colIndex }` 会把第一个没认出的列当注释，
    /// 于是形码的 stem 会跑到 radical 的位置上去
    func testUnknownColumnBeforeStemDoesNotStealAnnotation() throws {
        let yaml = "---\ncolumns:\n  - text\n  - code\n  - radical\n  - stem\n...\n我\tt\t扌\t丿扌戈 · tupg\n"
        let url = write(yaml, name: "radical.dict.yaml")
        let out = outputURL()
        let (_, report) = try DictCompiler.compileMultipleWithReport(
            yamlURLs: [url], outputURL: out, schemeType: .direct)
        XCTAssertEqual(report.ignoredColumns, ["radical"])
        XCTAssertEqual(try entries(out, code: "t").first?.annotation, "丿扌戈 · tupg",
                       "注释必须取 stem 列，不能被前面的 radical 抢走")
    }

    // MARK: - stem / comment / annotation 三种注释列

    func testStemColumnUsedAsAnnotation() throws {
        let yaml = "---\ncolumns:\n  - text\n  - code\n  - weight\n  - stem\n...\n我\tt\t2302420\t丿扌戈 · tupg\n"
        let url = write(yaml, name: "stem.dict.yaml")
        let out = outputURL()
        try DictCompiler.compile(yamlURL: url, outputURL: out, schemeType: .direct)
        XCTAssertEqual(try entries(out, code: "t").first?.annotation, "丿扌戈 · tupg")
    }

    func testCommentColumnUsedAsAnnotation() throws {
        let yaml = "---\ncolumns:\n  - text\n  - code\n  - comment\n...\n你\tni\tnǐ\n"
        let url = write(yaml, name: "comment.dict.yaml")
        let out = outputURL()
        try DictCompiler.compile(yamlURL: url, outputURL: out, schemeType: .syllable)
        XCTAssertEqual(try entries(out, code: "ni").first?.annotation, "nǐ")
    }

    func testAnnotationTakesPrecedenceOverStem() throws {
        let yaml = "---\ncolumns:\n  - text\n  - code\n  - stem\n  - annotation\n...\n你\tni\t字根\t注音\n"
        let url = write(yaml, name: "both.dict.yaml")
        let out = outputURL()
        try DictCompiler.compile(yamlURL: url, outputURL: out, schemeType: .syllable)
        XCTAssertEqual(try entries(out, code: "ni").first?.annotation, "注音",
                       "annotation > comment > stem 的优先级")
    }

    /// 没有 weight 列的表（虎码单字库就是这样）不能整批判成「列数不足」
    func testTableWithoutWeightColumnIsAccepted() throws {
        let yaml = "---\ncolumns:\n  - text\n  - code\n...\n我\tt\n用\tty\n"
        let url = write(yaml, name: "noweight.dict.yaml")
        let out = outputURL()
        let (_, report) = try DictCompiler.compileMultipleWithReport(
            yamlURLs: [url], outputURL: out, schemeType: .direct)
        XCTAssertEqual(report.totalParsed, 2)
        XCTAssertEqual(report.totalSkipped, 0)
    }

    /// 声明了 columns 却没有 code 列的表（雾凇 cn_dicts/tencent.dict.yaml 是 text+weight 两列）
    /// 提供不了编码，整表跳过并只记一条原因 —— 不能把 weight 当 code，
    /// 否则整张表变成九十万条数字伪码
    func testTableWithoutCodeColumnIsSkippedWhole() throws {
        let main = "---\ncolumns:\n  - text\n  - code\n  - weight\n...\n你\tni\t100\n"
        let tencent = "---\ncolumns:\n  - text\n  - weight\n...\n人工智能\t99999\n机器学习\t88888\n"
        let mainURL = write(main, name: "main.dict.yaml")
        write(tencent, name: "tencent.dict.yaml")
        let out = outputURL()
        let (_, report) = try DictCompiler.compileMultipleWithReport(
            yamlURLs: [mainURL, tmpDir.appendingPathComponent("tencent.dict.yaml")],
            outputURL: out, schemeType: .syllable)
        XCTAssertEqual(report.totalParsed, 1)
        XCTAssertEqual(report.files[1].skippedCount, 1, "整表只记一条，不逐行刷告警")
        XCTAssertTrue(report.files[1].skippedLines[0].reason.contains("没有 text 或 code 列"))
    }

    // MARK: - import_tables 递归导入

    func testImportTablesBringsInEntries() throws {
        write("---\nname: sub\ncolumns:\n  - text\n  - code\n  - weight\n...\n世界\tshijie\t900\n",
              name: "sub.dict.yaml")
        let main = write("---\nname: main\n" + threeColumns +
                         "import_tables:\n  - sub\n...\n你好\tnihao\t1000\n",
                         name: "main.dict.yaml")
        let out = outputURL()
        let (_, report) = try DictCompiler.compileMultipleWithReport(
            yamlURLs: [main], outputURL: out, schemeType: .syllable)
        XCTAssertEqual(report.importedTables, ["sub"])
        XCTAssertTrue(report.missingTables.isEmpty)
        XCTAssertEqual(report.totalParsed, 2)
        XCTAssertEqual(try entries(out, code: "shijie").map { $0.text }, ["世界"],
                       "被导入表的词条必须装进来")
    }

    /// 雾凇拼音的 ice.dict.yaml 自己不装词，全靠导入 cn_dicts/ 下五张表。
    /// 表名带子路径、又省略 .dict.yaml 后缀，两种写法都要认
    func testImportTablesResolvesSubPathAndOmittedExtension() throws {
        write("---\ncolumns:\n  - text\n  - code\n  - weight\n...\n你\tni\t800\n",
              name: "cn_dicts/8105.dict.yaml")
        write("---\ncolumns:\n  - text\n  - code\n  - weight\n...\n好\thao\t700\n",
              name: "cn_dicts/ext.dict.yaml")
        let main = write("---\n" + threeColumns +
                         "import_tables:\n  - cn_dicts/8105\n  - cn_dicts/ext.dict.yaml\n...\n",
                         name: "ice.dict.yaml")
        let out = outputURL()
        let (_, report) = try DictCompiler.compileMultipleWithReport(
            yamlURLs: [main], outputURL: out, schemeType: .syllable)
        XCTAssertEqual(report.importedTables, ["cn_dicts/8105", "cn_dicts/ext.dict.yaml"])
        XCTAssertTrue(report.missingTables.isEmpty)
        XCTAssertEqual(report.totalParsed, 2)
    }

    /// resourceRoot 让表名能在包根目录与根目录下的 dictionaries/ 里找
    func testImportTablesUsesResourceRoot() throws {
        write("---\ncolumns:\n  - text\n  - code\n  - weight\n...\n甲\tjia\t600\n",
              name: "extra.dict.yaml")
        write("---\ncolumns:\n  - text\n  - code\n  - weight\n...\n乙\tyi\t500\n",
              name: "dictionaries/tbl.dict.yaml")
        let main = write("---\n" + threeColumns +
                         "import_tables:\n  - extra\n  - tbl\n...\n你\tni\t800\n",
                         name: "dictionaries/main.dict.yaml")
        let out = outputURL()
        let (_, report) = try DictCompiler.compileMultipleWithReport(
            yamlURLs: [main], outputURL: out, schemeType: .syllable, resourceRoot: tmpDir)
        XCTAssertEqual(report.importedTables, ["extra", "tbl"])
        XCTAssertTrue(report.missingTables.isEmpty)
        XCTAssertEqual(report.totalParsed, 3)
    }

    /// 不传 resourceRoot 时退化为同目录查找（旧签名、旧调用不受影响）
    func testImportTablesFallsBackToSiblingDirectory() throws {
        write("---\ncolumns:\n  - text\n  - code\n  - weight\n...\n世界\tshijie\t900\n",
              name: "sub.dict.yaml")
        let main = write("---\n" + threeColumns + "import_tables:\n  - sub\n...\n你好\tnihao\t1000\n",
                         name: "main.dict.yaml")
        let out = outputURL()
        let (_, report) = try DictCompiler.compileMultipleWithReport(
            yamlURLs: [main], outputURL: out, schemeType: .syllable)
        XCTAssertEqual(report.importedTables, ["sub"])
        XCTAssertEqual(report.totalParsed, 2)
    }

    /// A 导 B、B 导 A：visited 去环，同一张表只读一次，不能无限递归
    func testImportTablesCycleIsBroken() throws {
        write("---\n" + threeColumns + "import_tables:\n  - b\n...\n甲\taa\t600\n", name: "a.dict.yaml")
        write("---\n" + threeColumns + "import_tables:\n  - a\n...\n乙\tbb\t500\n", name: "b.dict.yaml")
        let out = outputURL()
        let (_, report) = try DictCompiler.compileMultipleWithReport(
            yamlURLs: [tmpDir.appendingPathComponent("a.dict.yaml")],
            outputURL: out, schemeType: .direct)
        XCTAssertEqual(report.totalParsed, 2, "每张表只读一次")
        XCTAssertEqual(Set(report.importedTables), ["a", "b"])
    }

    /// 找不到的表只记一笔警告然后继续 —— 外部格式碰到这种情况会卡死，本 App 不能
    func testMissingImportedTableIsTolerated() throws {
        let main = write("---\n" + threeColumns +
                         "import_tables:\n  - ghost\n  - also_missing\n...\n你好\tnihao\t1000\n",
                         name: "main.dict.yaml")
        let out = outputURL()
        let (_, report) = try DictCompiler.compileMultipleWithReport(
            yamlURLs: [main], outputURL: out, schemeType: .syllable)
        XCTAssertEqual(report.missingTables, ["ghost", "also_missing"])
        XCTAssertTrue(report.importedTables.isEmpty)
        XCTAssertEqual(report.totalParsed, 1, "缺失的表不影响其余词条")
        XCTAssertTrue(report.logText().contains("缺失词表"))
    }

    /// 调用方文件在前、声明顺序在后：同词同码时「最上面的权重生效」（外部格式语义）
    func testImporterEntriesWinOverImported() throws {
        write("---\n" + threeColumns + "...\n你好\tnihao\t100\n", name: "sub.dict.yaml")
        let main = write("---\n" + threeColumns +
                         "import_tables:\n  - sub\n...\n你好\tnihao\t1000\n",
                         name: "main.dict.yaml")
        let out = outputURL()
        let (_, report) = try DictCompiler.compileMultipleWithReport(
            yamlURLs: [main], outputURL: out, schemeType: .syllable)
        XCTAssertEqual(report.mergedDuplicates, 1)
        XCTAssertEqual(try entries(out, code: "nihao").first?.freq, 1000,
                       "导入方自己的词条优先级高于被导入表")
    }

    /// 递归导入：被导入的表自己还能再导别的表（深度优先）
    func testImportTablesIsTransitive() throws {
        write("---\n" + threeColumns + "...\n丙\tcc\t400\n", name: "leaf.dict.yaml")
        write("---\n" + threeColumns + "import_tables:\n  - leaf\n...\n乙\tbb\t500\n", name: "mid.dict.yaml")
        let main = write("---\n" + threeColumns + "import_tables:\n  - mid\n...\n甲\taa\t600\n",
                         name: "main.dict.yaml")
        let out = outputURL()
        let (_, report) = try DictCompiler.compileMultipleWithReport(
            yamlURLs: [main], outputURL: out, schemeType: .direct)
        XCTAssertEqual(report.importedTables, ["mid", "leaf"])
        XCTAssertEqual(report.totalParsed, 3)
    }

    // MARK: - expandImportTables：编译与码制推断共用的展开
    //
    // 抽样也要顺着 import_tables 走到底：雾凇的 ice.dict.yaml 自己不装词，
    // 只抽它自己那几十行 `A`、`M1` 之类，会把一整个拼音方案判成形码。

    func testExpansionKeepsCallerFirstThenDeclarationOrder() {
        write("---\n" + threeColumns + "...\n甲\tjia\t600\n", name: "sub1.dict.yaml")
        write("---\n" + threeColumns + "...\n乙\tyi\t500\n", name: "sub2.dict.yaml")
        let main = write("---\n" + threeColumns +
                         "import_tables:\n  - sub2\n  - sub1\n...\n你\tni\t800\n",
                         name: "main.dict.yaml")
        let expansion = DictCompiler.expandImportTables([main])
        XCTAssertEqual(expansion.urls.map { $0.lastPathComponent },
                       ["main.dict.yaml", "sub2.dict.yaml", "sub1.dict.yaml"],
                       "顺序即优先级：调用方在前，被导入的表按声明顺序在后")
        XCTAssertEqual(expansion.importedTables, ["sub2", "sub1"])
        XCTAssertTrue(expansion.missingTables.isEmpty)
    }

    /// 两张主表导入同一张底表：visited 去环，底表只读一次
    func testExpansionDedupsSharedDependency() {
        write("---\n" + threeColumns + "...\n共\tgong\t400\n", name: "shared.dict.yaml")
        let a = write("---\n" + threeColumns + "import_tables:\n  - shared\n...\n甲\taa\t600\n",
                      name: "a.dict.yaml")
        let b = write("---\n" + threeColumns + "import_tables:\n  - shared\n...\n乙\tbb\t500\n",
                      name: "b.dict.yaml")
        let expansion = DictCompiler.expandImportTables([a, b])
        XCTAssertEqual(expansion.urls.map { $0.lastPathComponent },
                       ["a.dict.yaml", "shared.dict.yaml", "b.dict.yaml"],
                       "shared 已经在 a 那一路读过了，b 不再重复读")
        XCTAssertEqual(expansion.importedTables, ["shared"])
    }

    /// 找不到的表只记一笔名字然后继续；读不到的顶层文件也要留在列表里，
    /// 编译那边靠它记一条「读取文件失败」，用户才知道是哪张表出了问题
    func testExpansionToleratesMissingAndUnreadableFiles() {
        let main = write("---\n" + threeColumns +
                         "import_tables:\n  - ghost\n  - cn_dicts/none\n...\n你\tni\t800\n",
                         name: "main.dict.yaml")
        let absent = tmpDir.appendingPathComponent("never_existed.dict.yaml")
        let expansion = DictCompiler.expandImportTables([main, absent], resourceRoot: tmpDir)
        XCTAssertEqual(expansion.missingTables, ["ghost", "cn_dicts/none"], "表名原样保留子路径写法")
        XCTAssertTrue(expansion.importedTables.isEmpty)
        XCTAssertEqual(expansion.urls.map { $0.lastPathComponent },
                       ["main.dict.yaml", "never_existed.dict.yaml"])
    }

    // MARK: - 其它头部字段

    func testHeaderFieldsAreParsed() {
        let front = DictHeaderParser.parse(
            "---\nname: tiger\nversion: 2024.1\nsort: by_weight\nuse_preset_vocabulary: true\nunknown_key: 42\n...\n")
        XCTAssertEqual(front.header.name, "tiger")
        XCTAssertEqual(front.header.version, "2024.1")
        XCTAssertEqual(front.header.sort, "by_weight")
        XCTAssertTrue(front.header.usePresetVocabulary)
        XCTAssertNil(front.header.encoder)
    }

    /// 读不懂的键一律忽略而不是报错：因为一个不认识的字段就整包拒装，比少解析一个字段糟糕得多
    func testUnknownHeaderKeysAreIgnoredWithoutFailing() throws {
        let yaml = "---\nname: test\nsome_future_key:\n  nested: value\n" + threeColumns +
                   "...\n你好\tnihao\t1000\n"
        let url = write(yaml, name: "future.dict.yaml")
        let out = outputURL()
        let (_, report) = try DictCompiler.compileMultipleWithReport(
            yamlURLs: [url], outputURL: out, schemeType: .syllable)
        XCTAssertEqual(report.totalParsed, 1)
        XCTAssertEqual(report.totalSkipped, 0)
    }
}
