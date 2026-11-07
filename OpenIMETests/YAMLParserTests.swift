import XCTest
@testable import OpenIMECore

final class YAMLManifestParserTests: XCTestCase {

    // MARK: - 正常解析

    func testBasicParse() throws {
        let yaml = "id: my-scheme\nname: 我的方案\nversion: 1.0.0\nauthor: 作者\ndescription: 简介\n"
        let manifest = try YAMLManifestParser.parse(yaml)
        XCTAssertEqual(manifest.id, "my-scheme")
        XCTAssertEqual(manifest.name, "我的方案")
        XCTAssertEqual(manifest.version, "1.0.0")
        XCTAssertEqual(manifest.author, "作者")
        XCTAssertEqual(manifest.description, "简介")
    }

    func testOptionalFieldsDefaultToEmpty() throws {
        let yaml = "id: test\nname: 测试\n"
        let manifest = try YAMLManifestParser.parse(yaml)
        XCTAssertEqual(manifest.version, "1.0.0")
        XCTAssertEqual(manifest.author, "")
        XCTAssertEqual(manifest.description, "")
    }

    func testCommentLinesAreIgnored() throws {
        let yaml = "# 注释\nid: test\n# 另一条注释\nname: 测试\n"
        let manifest = try YAMLManifestParser.parse(yaml)
        XCTAssertEqual(manifest.id, "test")
    }

    func testValueWithColonIsPreservedCorrectly() throws {
        // value 中包含冒号，只取第一个冒号后的内容
        let yaml = "id: my-scheme\nname: 测试: 子标题\n"
        let manifest = try YAMLManifestParser.parse(yaml)
        XCTAssertEqual(manifest.name, "测试: 子标题")
    }

    // MARK: - 缺少必填字段

    func testMissingIdThrows() {
        let yaml = "name: 测试\n"
        XCTAssertThrowsError(try YAMLManifestParser.parse(yaml)) { err in
            guard case PackageInstaller.InstallError.invalidManifestFormat(let msg) = err else {
                return XCTFail("wrong error type")
            }
            XCTAssertTrue(msg.contains("id"))
        }
    }

    func testEmptyIdThrows() {
        let yaml = "id: \nname: 测试\n"
        XCTAssertThrowsError(try YAMLManifestParser.parse(yaml))
    }

    func testMissingNameThrows() {
        let yaml = "id: test\n"
        XCTAssertThrowsError(try YAMLManifestParser.parse(yaml)) { err in
            guard case PackageInstaller.InstallError.invalidManifestFormat(let msg) = err else {
                return XCTFail("wrong error type")
            }
            XCTAssertTrue(msg.contains("name"))
        }
    }

    func testEmptyNameThrows() {
        let yaml = "id: test\nname: \n"
        XCTAssertThrowsError(try YAMLManifestParser.parse(yaml))
    }

    func testEmptyContentThrows() {
        XCTAssertThrowsError(try YAMLManifestParser.parse(""))
    }
}

// MARK: -

final class YAMLSchemaParserTests: XCTestCase {

    func testDirectType() throws {
        let def = try YAMLSchemaParser.parse("type: direct\n")
        XCTAssertEqual(def.type, .direct)
    }

    func testSyllableType() throws {
        let def = try YAMLSchemaParser.parse("type: syllable\n")
        XCTAssertEqual(def.type, .syllable)
    }

    func testDoubleSyllableType() throws {
        let def = try YAMLSchemaParser.parse("type: double_syllable\n")
        XCTAssertEqual(def.type, .doubleSyllable)
    }

    func testUnknownTypeDefaultsToDirect() throws {
        let def = try YAMLSchemaParser.parse("type: foobar\n")
        XCTAssertEqual(def.type, .direct)
    }

    func testMissingTypeDefaultsToDirect() throws {
        let def = try YAMLSchemaParser.parse("max_code_length: 4\n")
        XCTAssertEqual(def.type, .direct)
    }

    func testMaxCodeLength() throws {
        let def = try YAMLSchemaParser.parse("type: direct\nmax_code_length: 4\n")
        XCTAssertEqual(def.maxCodeLength, 4)
    }

    func testAutoSelectTrue() throws {
        let def = try YAMLSchemaParser.parse("type: direct\nauto_select: true\n")
        XCTAssertEqual(def.autoSelect, true)
    }

    func testAutoSelectFalse() throws {
        let def = try YAMLSchemaParser.parse("type: direct\nauto_select: false\n")
        XCTAssertEqual(def.autoSelect, false)
    }

    func testAutoSelectCaseInsensitive() throws {
        let def = try YAMLSchemaParser.parse("type: direct\nauto_select: True\n")
        XCTAssertEqual(def.autoSelect, true)
    }

    func testNormalizeCode() throws {
        let def = try YAMLSchemaParser.parse("type: syllable\nnormalize_code: strip_spaces\n")
        XCTAssertEqual(def.normalizeCode, "strip_spaces")
    }

    func testOptionalFieldsAreNilWhenAbsent() throws {
        let def = try YAMLSchemaParser.parse("type: direct\n")
        XCTAssertNil(def.maxCodeLength)
        XCTAssertNil(def.autoSelect)
        XCTAssertNil(def.alphabet)
        XCTAssertNil(def.normalizeCode)
        XCTAssertNil(def.reverseLookupGuide)
    }

    /// 反查引导符从 schema.yaml 读入（数据驱动，不写死在引擎里）：超强快码约定用 i
    func testReverseLookupGuideParsed() throws {
        let def = try YAMLSchemaParser.parse(
            "type: direct\ncode_system: phono_shape\nreverse_lookup_guide: i\n")
        XCTAssertEqual(def.reverseLookupGuide, "i")
    }
}

// MARK: -

final class YAMLSingleFileImporterTests: XCTestCase {

    private var tmpDir: URL!

    override func setUp() {
        super.setUp()
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("YAMLImport_\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmpDir)
        super.tearDown()
    }

    // MARK: - pinyinId

    func testPinyinIdFromChinese() {
        let id = YAMLSingleFileImporter.pinyinId(from: "我的方案")
        XCTAssertFalse(id.isEmpty)
        XCTAssertTrue(id.unicodeScalars.allSatisfy { CharacterSet.letters.union(.init(charactersIn: "-")).union(.decimalDigits).contains($0) })
    }

    func testPinyinIdFromEnglish() {
        let id = YAMLSingleFileImporter.pinyinId(from: "My Scheme")
        XCTAssertEqual(id, "my-scheme")
    }

    func testPinyinIdFromMixed() {
        let id = YAMLSingleFileImporter.pinyinId(from: "雾凇 Pinyin")
        XCTAssertFalse(id.isEmpty)
        XCTAssertFalse(id.contains(" "))
    }

    func testPinyinIdFiltersIllegalChars() {
        let id = YAMLSingleFileImporter.pinyinId(from: "test!@#$%")
        XCTAssertEqual(id, "test")
    }

    func testPinyinIdEmptyStringReturnsEmpty() {
        let id = YAMLSingleFileImporter.pinyinId(from: "")
        XCTAssertEqual(id, "")
    }

    func testPinyinIdIsLowercase() {
        let id = YAMLSingleFileImporter.pinyinId(from: "ABC")
        XCTAssertEqual(id, "abc")
    }

    // MARK: - buildTempDir 基本功能

    func testBuildTempDirCreatesExpectedFiles() throws {
        let yaml = "id: test\nname: 测试\ntype: syllable\n---\n你好\tnihao\t1000\t\n"
        let tempDir = try YAMLSingleFileImporter.buildTempDir(content: yaml, fileName: "test")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fm = FileManager.default
        XCTAssertTrue(fm.fileExists(atPath: tempDir.appendingPathComponent("manifest.yaml").path))
        XCTAssertTrue(fm.fileExists(atPath: tempDir.appendingPathComponent("schema.yaml").path))
        XCTAssertTrue(fm.fileExists(atPath: tempDir.appendingPathComponent("dictionaries/main.dict.yaml").path))
    }

    func testBuildTempDirUsesProvidedId() throws {
        let yaml = "id: my-id\nname: 测试\n---\n你好\tnihao\t1000\t\n"
        let tempDir = try YAMLSingleFileImporter.buildTempDir(content: yaml, fileName: "test")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let manifest = try String(contentsOf: tempDir.appendingPathComponent("manifest.yaml"), encoding: .utf8)
        XCTAssertTrue(manifest.contains("id: my-id"))
    }

    func testBuildTempDirFallsBackToFilenameWhenIdEmpty() throws {
        let yaml = "id: \nname: 测试\n---\n你好\tnihao\t1000\t注释\n"
        let tempDir = try YAMLSingleFileImporter.buildTempDir(content: yaml, fileName: "my-file")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let manifest = try String(contentsOf: tempDir.appendingPathComponent("manifest.yaml"), encoding: .utf8)
        // id 为空时兜底到 fileName 的 pinyinId，结果不能是空行
        let lines = manifest.components(separatedBy: .newlines)
        let idLine = lines.first { $0.hasPrefix("id:") }
        XCTAssertNotNil(idLine)
        let idValue = idLine!.dropFirst("id:".count).trimmingCharacters(in: .whitespaces)
        XCTAssertFalse(idValue.isEmpty)
    }

    func testBuildTempDirSchemaTypeWritten() throws {
        let yaml = "id: t\nname: 测试\ntype: syllable\n---\n你好\tnihao\t1000\t\n"
        let tempDir = try YAMLSingleFileImporter.buildTempDir(content: yaml, fileName: "test")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let schema = try String(contentsOf: tempDir.appendingPathComponent("schema.yaml"), encoding: .utf8)
        XCTAssertTrue(schema.contains("syllable"))
    }

    func testBuildTempDirDictContainsFrontMatter() throws {
        let yaml = "id: t\nname: 测试\n---\n你好\tnihao\t1000\t\n"
        let tempDir = try YAMLSingleFileImporter.buildTempDir(content: yaml, fileName: "test")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let dict = try String(contentsOf: tempDir.appendingPathComponent("dictionaries/main.dict.yaml"), encoding: .utf8)
        XCTAssertTrue(dict.contains("columns:"))
        XCTAssertTrue(dict.contains("annotation"))
        XCTAssertTrue(dict.contains("..."))
        XCTAssertTrue(dict.contains("你好"))
    }

    func testBuildTempDirNoSeparatorStillWorks() throws {
        // 没有 --- 分隔符，仍然不崩溃（dataLines 为空）
        let yaml = "id: t\nname: 测试\ntype: direct\n"
        let tempDir = try YAMLSingleFileImporter.buildTempDir(content: yaml, fileName: "test")
        defer { try? FileManager.default.removeItem(at: tempDir) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempDir.appendingPathComponent("manifest.yaml").path))
    }

    // MARK: - 错误情况

    func testEmptyContentThrows() {
        XCTAssertThrowsError(
            try YAMLSingleFileImporter.buildTempDir(content: "", fileName: "test")
        ) { err in
            XCTAssertTrue(err is YAMLSingleFileImporter.ImportError)
        }
    }

    func testWhitespaceOnlyContentThrows() {
        XCTAssertThrowsError(
            try YAMLSingleFileImporter.buildTempDir(content: "   \n\t\n", fileName: "test")
        )
    }

    func testMissingNameThrows() {
        let yaml = "id: test\ntype: syllable\n---\n你好\tnihao\t1000\t\n"
        XCTAssertThrowsError(
            try YAMLSingleFileImporter.buildTempDir(content: yaml, fileName: "test")
        ) { err in
            XCTAssertTrue(err is YAMLSingleFileImporter.ImportError)
        }
    }

    func testIdWithIllegalCharsIsFiltered() throws {
        let yaml = "id: test!@#\nname: 测试\n---\n你好\tnihao\t1000\t\n"
        let tempDir = try YAMLSingleFileImporter.buildTempDir(content: yaml, fileName: "f")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let manifest = try String(contentsOf: tempDir.appendingPathComponent("manifest.yaml"), encoding: .utf8)
        // 非法字符过滤后 id 应为 "test"
        XCTAssertTrue(manifest.contains("id: test"))
    }

    // MARK: - 外部格式单文件导入

    func testBuildTempDirExternalFormatWithSeparator() throws {
        // cqkm 风格：注释行 + --- front matter + ... + 词条数据
        let yaml = """
# 外部 dict
# encoding: utf-8
---
name: cqkm_cm
version: "2024.01"
sort: by_weight
...
你好\tcqkm\t1000
世界\tshijie\t800
"""
        let tempDir = try YAMLSingleFileImporter.buildTempDir(content: yaml, fileName: "cqkm_cm.dict.yaml")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fm = FileManager.default
        XCTAssertTrue(fm.fileExists(atPath: tempDir.appendingPathComponent("manifest.yaml").path))
        XCTAssertTrue(fm.fileExists(atPath: tempDir.appendingPathComponent("schema.yaml").path))
        XCTAssertTrue(fm.fileExists(atPath: tempDir.appendingPathComponent("dictionaries/main.dict.yaml").path))

        let manifest = try String(contentsOf: tempDir.appendingPathComponent("manifest.yaml"), encoding: .utf8)
        XCTAssertTrue(manifest.contains("name: cqkm_cm"))

        // 词库文件应包含原始词条
        let dict = try String(contentsOf: tempDir.appendingPathComponent("dictionaries/main.dict.yaml"), encoding: .utf8)
        XCTAssertTrue(dict.contains("你好"))
        XCTAssertTrue(dict.contains("世界"))
    }

    func testBuildTempDirExternalFormatNoLeadingDash() throws {
        // tigress 风格：front matter 直接从第0行开始，无 --- 前缀
        let yaml = """
name: tigress
version: "2024.05"
sort: by_weight
...
虎\th\t10000
码\tm\t9000
"""
        let tempDir = try YAMLSingleFileImporter.buildTempDir(content: yaml, fileName: "tigress.dict.yaml")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let manifest = try String(contentsOf: tempDir.appendingPathComponent("manifest.yaml"), encoding: .utf8)
        XCTAssertTrue(manifest.contains("name: tigress"))

        let dict = try String(contentsOf: tempDir.appendingPathComponent("dictionaries/main.dict.yaml"), encoding: .utf8)
        XCTAssertTrue(dict.contains("虎"))
        XCTAssertTrue(dict.contains("码"))
    }

    func testBuildTempDirExternalFormatNameFallbackToFileName() throws {
        // front matter 无 name 时，从文件名（去扩展名）兜底
        let yaml = """
---
version: "1.0"
sort: by_weight
...
测试\tcs\t500
"""
        let tempDir = try YAMLSingleFileImporter.buildTempDir(content: yaml, fileName: "mydict.dict.yaml")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let manifest = try String(contentsOf: tempDir.appendingPathComponent("manifest.yaml"), encoding: .utf8)
        // name 应兜底为 "mydict"
        XCTAssertTrue(manifest.contains("name: mydict"))
    }

    func testBuildTempDirDictContentPassedThrough() throws {
        // 整个文件原样写入词库，词条不被截断或重写
        let yaml = """
---
name: passthrough_test
columns:
  - text
  - code
  - weight
...
一\ta\t9999
二\tb\t8888
三\tc\t7777
"""
        let tempDir = try YAMLSingleFileImporter.buildTempDir(content: yaml, fileName: "passthrough_test.dict.yaml")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let dict = try String(contentsOf: tempDir.appendingPathComponent("dictionaries/main.dict.yaml"), encoding: .utf8)
        // 原始 front matter 应在词库文件里
        XCTAssertTrue(dict.contains("columns:"))
        XCTAssertTrue(dict.contains("..."))
        // 全部词条应存在
        XCTAssertTrue(dict.contains("一"))
        XCTAssertTrue(dict.contains("二"))
        XCTAssertTrue(dict.contains("三"))
        XCTAssertTrue(dict.contains("9999"))
    }
}
