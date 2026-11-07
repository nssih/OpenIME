import XCTest
@testable import OpenIMECore

// MARK: - 重复条目与排序确定性
//
// 外部格式的语义是「同词同码，最上面的那条生效」；同词不同码则全部保留（形码的多码字、音码的多音字）。
// 合并计数要进报告，用户才知道安装时发生了什么。
// 排序还必须在 code、freq 都相同时用原始序号 tie-break —— Swift 的 sorted 不保证稳定，
// 不这么做的话同一份 YAML 编两次会得到两份字节不同的 dict.bin，`sort: by_weight` 也就无从重现。

final class DuplicateEntryTests: XCTestCase {

    private var tmpDir: URL!

    override func setUp() {
        super.setUp()
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DupTests_\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmpDir)
        tmpDir = nil
        super.tearDown()
    }

    // MARK: - 辅助

    @discardableResult
    private func write(_ entries: String, name: String, columns: String? = nil) -> URL {
        let cols = columns ?? "columns:\n  - text\n  - code\n  - weight\n"
        let url = tmpDir.appendingPathComponent(name)
        try! ("---\n" + cols + "...\n" + entries).write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func compile(_ urls: [URL], type: SchemeType = .direct,
                         name: String = "out.bin") throws -> (URL, DictCompiler.CompileReport) {
        let out = tmpDir.appendingPathComponent(name)
        let (_, report) = try DictCompiler.compileMultipleWithReport(
            yamlURLs: urls, outputURL: out, schemeType: type)
        return (out, report)
    }

    /// 按 dict.bin 里的存放顺序读出全部词条
    ///
    /// 不看索引、不经 DictReader 的排序，直接扫数据区 —— 排序与去重的结果就落在这个顺序里
    private func storedEntries(_ binURL: URL) throws -> [(code: String, text: String, freq: Int)] {
        let data = try Data(contentsOf: binURL)
        let entryCount = Int(data.readUInt32(at: 8))
        let dataOffset = Int(data.readUInt32(at: 16))
        // 旧版（v2）词库的数据区之后还接着一段九宫索引附加区，扫描必须停在它的起点；
        // 九宫下线后新编的文件该字段恒为 0，dataEnd 就是文件末尾
        var dataEnd = data.count
        if data.readUInt16(at: 4) >= 2, data.count >= 24 {
            let tailOffset = Int(data.readUInt32(at: 20))
            if tailOffset > dataOffset, tailOffset <= data.count { dataEnd = tailOffset }
        }
        var pos = dataOffset
        var result: [(String, String, Int)] = []
        for _ in 0..<entryCount {
            let codeLen = Int(data[pos])
            pos += 1
            let code = String(decoding: data[pos..<(pos + codeLen)], as: UTF8.self)
            pos += codeLen
            let textLen = Int(data.readUInt16(at: pos))
            pos += 2
            let text = String(decoding: data[pos..<(pos + textLen)], as: UTF8.self)
            pos += textLen
            let annoLen = Int(data.readUInt16(at: pos))
            pos += 2 + annoLen
            let freq = Int(data.readInt32(at: pos))
            pos += 4
            result.append((code, text, freq))
        }
        XCTAssertEqual(pos, dataEnd, "数据区应被完整扫完")
        return result
    }

    // MARK: - 同词同码：首现胜出

    func testSameTextSameCodeFirstWinsWithinFile() throws {
        let url = write("你好\tnihao\t500\n你好\tnihao\t900\n世界\tshijie\t800\n",
                        name: "dup.dict.yaml")
        let (out, report) = try compile([url], type: .syllable)
        XCTAssertEqual(report.mergedDuplicates, 1)
        XCTAssertEqual(report.totalParsed, 2)
        let stored = try storedEntries(out)
        XCTAssertEqual(stored.count, 2)
        XCTAssertEqual(stored.first { $0.text == "你好" }?.freq, 500,
                       "外部格式语义：最上面那条生效，不是词频最高的那条")
    }

    /// 一次传多份文件时，数组顺序就是优先级（与 import_tables 同一套语义）
    func testSameTextSameCodeFirstFileWins() throws {
        let first = write("你好\tnihao\t1000\n", name: "first.dict.yaml")
        let second = write("你好\tnihao\t100\n", name: "second.dict.yaml")
        let (out, report) = try compile([first, second], type: .syllable)
        XCTAssertEqual(report.mergedDuplicates, 1)
        XCTAssertEqual(try storedEntries(out).count, 1)
        XCTAssertEqual(try storedEntries(out).first?.freq, 1000)
    }

    /// 调用方文件在前、被导入表在后，所以同词同码时导入方的词频胜出
    func testImporterWinsOverImportedOnDuplicate() throws {
        write("你好\tnihao\t100\n", name: "sub.dict.yaml")
        let main = tmpDir.appendingPathComponent("main.dict.yaml")
        try ("---\ncolumns:\n  - text\n  - code\n  - weight\nimport_tables:\n  - sub\n...\n你好\tnihao\t1000\n")
            .write(to: main, atomically: true, encoding: .utf8)
        let (out, report) = try compile([main], type: .syllable)
        XCTAssertEqual(report.importedTables, ["sub"])
        XCTAssertEqual(report.mergedDuplicates, 1)
        XCTAssertEqual(try storedEntries(out).first { $0.text == "你好" }?.freq, 1000)
    }

    // MARK: - 同词不同码 / 同码不同词：全部保留

    func testSameTextDifferentCodeBothKept() throws {
        // 形码的多码字：我 既是简码 t，也是全码 tupg
        let url = write("我\tt\t2302420\n我\ttupg\t256\n", name: "multi.dict.yaml")
        let (out, report) = try compile([url])
        XCTAssertEqual(report.mergedDuplicates, 0)
        XCTAssertEqual(try storedEntries(out).count, 2)
        let reader = try DictReader(binURL: out)
        XCTAssertEqual(reader.queryExact(code: "t").map { $0.text }, ["我"])
        XCTAssertEqual(reader.queryExact(code: "tupg").map { $0.text }, ["我"])
    }

    func testDifferentTextSameCodeBothKept() throws {
        let url = write("你\tni\t800\n尼\tni\t700\n泥\tni\t600\n", name: "homo.dict.yaml",
                        columns: "columns:\n  - text\n  - code\n  - weight\n")
        let (out, report) = try compile([url], type: .syllable)
        XCTAssertEqual(report.mergedDuplicates, 0)
        XCTAssertEqual(try storedEntries(out).count, 3)
    }

    // MARK: - 排序确定性

    func testSortedByCodeAscendingThenFreqDescending() throws {
        let url = write("你\tni\t100\n尼\tni\t900\n泥\tni\t500\n啊\ta\t300\n",
                        name: "sort.dict.yaml", columns: "columns:\n  - text\n  - code\n  - weight\n")
        let (out, _) = try compile([url], type: .syllable)
        let stored = try storedEntries(out)
        XCTAssertEqual(stored.map { $0.text }, ["啊", "尼", "泥", "你"],
                       "编码升序，同码按词频降序")
    }

    /// code 与 freq 都相同时按词库里的先后 —— 不这么做，同一份 YAML 编两次会得到两份不同的 dict.bin
    func testEqualCodeAndFreqFallsBackToOriginalOrder() throws {
        let url = write("乙\tbb\t100\n甲\taa\t100\n丙\taa\t100\n", name: "tie.dict.yaml")
        let (out, _) = try compile([url])
        XCTAssertEqual(try storedEntries(out).map { $0.text }, ["甲", "丙", "乙"],
                       "同码同频时保持词库里的原始顺序")

        // 再编一次，字节级一致（可重现）
        let again = tmpDir.appendingPathComponent("again.bin")
        _ = try DictCompiler.compileMultiple(yamlURLs: [url], outputURL: again, schemeType: .direct)
        XCTAssertEqual(try storedEntries(again).map { $0.text }, ["甲", "丙", "乙"])
    }

    /// sort: by_weight 只是声明，OpenIME 一律按「码升序 + 频降序」存放，
    /// 因为前缀查询要靠码有序才能二分；权重次序由查询时排序保证
    func testWeightSortedDeclarationStillCompiles() throws {
        let url = tmpDir.appendingPathComponent("byweight.dict.yaml")
        try ("---\nname: t\nsort: by_weight\ncolumns:\n  - text\n  - code\n  - weight\n...\n甲\taa\t10\n乙\taa\t99\n")
            .write(to: url, atomically: true, encoding: .utf8)
        let (out, report) = try compile([url])
        XCTAssertEqual(report.totalParsed, 2)
        XCTAssertEqual(try storedEntries(out).map { $0.text }, ["乙", "甲"], "同码按词频降序")
    }

    // MARK: - 与 encoder 派生的相互作用

    /// 派生出来的码也可能和词库里已有的码撞上，同样按首现胜出合并
    func testDerivedCodeCollidingWithExistingIsMerged() throws {
        let yaml = """
---
columns:
  - text
  - code
  - weight
encoder:
  rules:
    - length_equal: 2
      formula: AaAbBaBb
...
今	jafm	100
天	gd	90
今天	jagd	80
今天		70
"""
        let url = tmpDir.appendingPathComponent("collide.dict.yaml")
        try yaml.write(to: url, atomically: true, encoding: .utf8)
        let out = tmpDir.appendingPathComponent("collide.bin")
        let (_, report) = try DictCompiler.compileMultipleWithReport(
            yamlURLs: [url], outputURL: out, schemeType: .direct)
        XCTAssertEqual(report.derivedCodes, 1)
        XCTAssertEqual(report.mergedDuplicates, 1)
        XCTAssertEqual(try storedEntries(out).count, 3)
        XCTAssertEqual(try storedEntries(out).first { $0.text == "今天" }?.freq, 80,
                       "已有的那条在前，派生的那条被合并掉")
    }

    // MARK: - 报告

    func testMergedDuplicatesAppearInLogText() throws {
        let url = write("你好\tnihao\t500\n你好\tnihao\t900\n", name: "log.dict.yaml")
        let (_, report) = try compile([url], type: .syllable)
        let log = report.logText()
        XCTAssertTrue(log.contains("重复合并：1 条"), "日志里要能看出合并了几条：\(log)")
    }

    func testNoDuplicatesMeansNoLogLine() throws {
        let url = write("你好\tnihao\t500\n", name: "clean.dict.yaml")
        let (_, report) = try compile([url], type: .syllable)
        XCTAssertFalse(report.logText().contains("重复合并"))
    }
}
