import XCTest
@testable import OpenIMECore

// MARK: - 通用词频语料流式读取（编译期给零词频码表补真实词频）
//
// WordFrequencyCorpus 只应在编译「零词频码表」时被调用，从随包的雾凇 base.dict.yaml 流式取词频。
// 这里锁定：只为 needed 命中的多字词返回词频、同词取最大、按 columns 列名映射（不按位置）、
// 空 needed / 缺文件安全返回空字典。用临时小语料文件替代 16 MB 的真实 base.dict.yaml。

final class WordFrequencyCorpusTests: XCTestCase {

    private var tmpDir: URL!

    override func setUp() {
        super.setUp()
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("WordFrequencyCorpusTests_\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmpDir)
        tmpDir = nil
        super.tearDown()
    }

    private func writeCorpus(_ body: String, name: String = "corpus.dict.yaml") -> URL {
        let url = tmpDir.appendingPathComponent(name)
        try! body.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// 只为 needed 命中的多字词返回词频；单字、注释行、不在 needed 里的词都忽略
    func testLoadsOnlyNeededMultiCharWords() {
        let url = writeCorpus(
            "---\nname: test\n...\n"
            + "# 注释行\n"
            + "你\tni\t500\n"                 // 单字：忽略
            + "你好\tni hao\t100000\n"
            + "中国\tzhong guo\t2000\n"
            + "生僻词\txx\t7\n"                // 多字但不在 needed：忽略
        )
        let got = WordFrequencyCorpus.loadFrequencies(needed: ["你好", "中国", "不存在"], from: url)
        XCTAssertEqual(got["你好"], 100000)
        XCTAssertEqual(got["中国"], 2000)
        XCTAssertEqual(got.count, 2, "只返回 needed 命中的多字词")
        XCTAssertNil(got["你"], "单字不收录（单字由 CharFrequency 负责）")
        XCTAssertNil(got["生僻词"], "不在 needed 里的词即便语料有也不返回")
    }

    /// 同词多条取最大词频
    func testKeepsMaxFreqForDuplicateWord() {
        let url = writeCorpus("---\nname: t\n...\n你好\tni hao\t100\n你好\tni hao\t999\n你好\tni hao\t500\n")
        XCTAssertEqual(WordFrequencyCorpus.loadFrequencies(needed: ["你好"], from: url)["你好"], 999)
    }

    /// 声明了 columns（text/weight 顺序不同）也按列名映射，绝不按列位置硬取
    func testRespectsDeclaredColumnOrder() {
        let url = writeCorpus(
            "---\ncolumns:\n  - text\n  - weight\n  - code\n...\n"
            + "你好\t100000\tni hao\n"
            + "中国\t2000\tzhong guo\n"
        )
        let got = WordFrequencyCorpus.loadFrequencies(needed: ["你好", "中国"], from: url)
        XCTAssertEqual(got["你好"], 100000, "weight 在第 2 列也要按列名取对")
        XCTAssertEqual(got["中国"], 2000)
    }

    /// 空 needed / 读不到文件 → 返回空字典，绝不抛错（编译安全降级）
    func testEmptyNeededAndMissingFileAreSafe() {
        XCTAssertTrue(WordFrequencyCorpus.loadFrequencies(
            needed: [], from: writeCorpus("---\nname: t\n...\n你好\tni hao\t1\n")).isEmpty,
                      "空 needed 不必扫文件")
        XCTAssertTrue(WordFrequencyCorpus.loadFrequencies(
            needed: ["你好"], from: tmpDir.appendingPathComponent("nonexistent.yaml")).isEmpty,
                      "缺文件返回空字典")
    }
}
