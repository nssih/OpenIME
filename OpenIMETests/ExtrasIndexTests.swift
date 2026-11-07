import XCTest
@testable import OpenIMECore

final class ExtrasIndexTests: XCTestCase {

    private var tmpDir: URL!

    override func setUp() {
        super.setUp()
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExtrasIndexTests_\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmpDir)
        super.tearDown()
    }

    private func sidecarURL(_ name: String = "dict.extras.bin") -> URL {
        tmpDir.appendingPathComponent(name)
    }

    // 侧车不存在时，所有查询都返回空，等于老行为
    func testAbsentFileIsEmpty() {
        let idx = ExtrasIndex(sidecar: sidecarURL("not_exist.bin"))
        XCTAssertTrue(idx.isEmpty)
        XCTAssertTrue(idx.reverseLookup(code: "gggg").isEmpty)
        XCTAssertNil(idx.elementHint(root: "木"))
        XCTAssertTrue(idx.abbreviations(prefix: "g", limit: 10).isEmpty)
    }

    // 没有 extras 时编译应当删掉侧车
    func testEmptyExtrasRemovesSidecar() throws {
        let url = sidecarURL()
        try ExtrasIndexBuilder.build(extras: nil, to: url)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))

        // 先建一个有内容的侧车，再用空 extras 编一次，应当被删掉
        try ExtrasIndexBuilder.build(extras: SchemeExtras(reverse: [ReverseEntry(code: "a", reading: "b")]), to: url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        try ExtrasIndexBuilder.build(extras: SchemeExtras(), to: url)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    // 编进去再读出来，三个区都要对得上
    func testRoundTrip() throws {
        let url = sidecarURL()
        let extras = SchemeExtras(
            reverse: [ReverseEntry(code: "gggg", reading: "wang"),
                      ReverseEntry(code: "gggg", reading: "guo")],
            elements: [ElementEntry(root: "木", key: "S", element: "木")],
            abbreviations: [AbbrevEntry(prefix: "g", word: "国", freq: 100),
                            AbbrevEntry(prefix: "g", word: "工", freq: 200)]
        )
        try ExtrasIndexBuilder.build(extras: extras, to: url)

        let idx = ExtrasIndex(sidecar: url)
        XCTAssertFalse(idx.isEmpty)
        XCTAssertEqual(Set(idx.reverseLookup(code: "gggg")), Set(["wang", "guo"]))
        XCTAssertEqual(idx.elementHint(root: "木")?.key, "S")
        XCTAssertEqual(idx.elementHint(root: "木")?.element, "木")

        let ab = idx.abbreviations(prefix: "g", limit: 10)
        XCTAssertEqual(ab.count, 2)
        XCTAssertEqual(ab.first?.word, "工")   // freq 降序，工 200 在前
        XCTAssertEqual(ab.first?.freq, 200)
    }

    // 多编码下二分查找要每条都命中，且互不串台
    func testBinarySearchManyCodes() throws {
        let url = sidecarURL()
        var rev: [ReverseEntry] = []
        for i in 0..<100 {
            rev.append(ReverseEntry(code: String(format: "c%03d", i), reading: "r\(i)"))
        }
        try ExtrasIndexBuilder.build(extras: SchemeExtras(reverse: rev), to: url)
        let idx = ExtrasIndex(sidecar: url)
        for i in 0..<100 {
            XCTAssertEqual(idx.reverseLookup(code: String(format: "c%03d", i)), ["r\(i)"])
        }
        XCTAssertTrue(idx.reverseLookup(code: "zzz").isEmpty)
    }

    // 简码取 limit 条时按 freq 降序截断
    func testAbbreviationLimitAndOrder() throws {
        let url = sidecarURL()
        let extras = SchemeExtras(abbreviations: [
            AbbrevEntry(prefix: "w", word: "我", freq: 10),
            AbbrevEntry(prefix: "w", word: "五", freq: 50),
            AbbrevEntry(prefix: "w", word: "无", freq: 30),
        ])
        try ExtrasIndexBuilder.build(extras: extras, to: url)
        let idx = ExtrasIndex(sidecar: url)
        let top2 = idx.abbreviations(prefix: "w", limit: 2)
        XCTAssertEqual(top2.map { $0.word }, ["五", "无"])
    }

    // 重复编译结果一致，且老侧车被原子替换（幂等）
    func testRebuildIsIdempotent() throws {
        let url = sidecarURL()
        let extras = SchemeExtras(reverse: [ReverseEntry(code: "gggg", reading: "wang")])
        try ExtrasIndexBuilder.build(extras: extras, to: url)
        let first = try Data(contentsOf: url)
        try ExtrasIndexBuilder.build(extras: extras, to: url)
        let second = try Data(contentsOf: url)
        XCTAssertEqual(first, second)
    }

    // 安装期走的是 JSON 解码，这里锁住这条契约：可选字段缺省即 nil
    func testJSONDecodeRoundTrip() throws {
        let json = """
        {"reverse":[{"code":"gggg","reading":"wang"}],
         "elements":[{"root":"木","key":"S","element":"木"}]}
        """.data(using: .utf8)!
        let extras = try JSONDecoder().decode(SchemeExtras.self, from: json)
        XCTAssertEqual(extras.reverse?.count, 1)
        XCTAssertEqual(extras.elements?.count, 1)
        XCTAssertNil(extras.abbreviations)

        let url = sidecarURL()
        try ExtrasIndexBuilder.build(extras: extras, to: url)
        let idx = ExtrasIndex(sidecar: url)
        XCTAssertEqual(idx.reverseLookup(code: "gggg"), ["wang"])
        XCTAssertEqual(idx.elementHint(root: "木")?.key, "S")
    }
}
