import UIKit
import XCTest
@testable import OpenIMECore

// MARK: - ClipboardHistoryStore 持久化
//
// 直接注入临时目录与固定 maxCount，不碰 UIPasteboard、不污染全局 ClipboardSettingsStore 单例。
// 所有断言前先 flush()（queue.sync），确保异步写盘完成后再读，结果确定。

final class ClipboardHistoryStoreTests: XCTestCase {

    private var directoryURL: URL!
    private var store: ClipboardHistoryStore!

    /// 测试用保留条数上限（3 条便于验证 trim）
    private let testMaxCount = 3

    override func setUp() {
        super.setUp()
        directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipboard_test_\(UUID().uuidString)", isDirectory: true)
        // 注入固定上限，避免依赖 / 污染全局 ClipboardSettingsStore.shared
        store = ClipboardHistoryStore(directoryURL: directoryURL, maxCountProvider: { [testMaxCount] in testMaxCount })
    }

    override func tearDown() {
        store.flush()
        try? FileManager.default.removeItem(at: directoryURL)
        store = nil
        directoryURL = nil
        super.tearDown()
    }

    private var itemsDirectoryURL: URL {
        directoryURL.appendingPathComponent("items", isDirectory: true)
    }

    // MARK: - 构造辅助

    private func textItem(_ text: String) -> ClipboardItem {
        ClipboardItem(kind: .text, text: text,
                      contentSignature: ClipboardItem.textSignature(text, kind: .text))
    }

    private func imageItem(fileName: String, data: Data) -> ClipboardItem {
        ClipboardItem(kind: .image, fileName: fileName,
                      contentSignature: ClipboardItem.imageSignature(data))
    }

    // MARK: - 基本往返

    func testEmptyStoreLoadsEmpty() {
        XCTAssertTrue(store.load().isEmpty)
        XCTAssertEqual(store.count, 0)
    }

    func testAppendAndLoadRoundTrip() {
        let item = textItem("hello world")
        store.append(item)
        store.flush()

        let loaded = store.load()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.id, item.id)
        XCTAssertEqual(loaded.first?.text, "hello world")
        XCTAssertEqual(loaded.first?.previewText, "hello world")
    }

    func testLoadReturnsNewestFirst() {
        store.append(textItem("first"))
        store.append(textItem("second"))
        store.append(textItem("third"))
        store.flush()

        XCTAssertEqual(store.load().compactMap { $0.text }, ["third", "second", "first"])
    }

    func testReloadFromDiskPreservesItems() {
        store.append(textItem("persist-1"))
        store.append(textItem("persist-2"))
        store.flush()

        // 换一个 store 实例（模拟另一进程）读同一目录，应看到已落盘内容
        let reopened = ClipboardHistoryStore(directoryURL: directoryURL, maxCountProvider: { 3 })
        let items = reopened.load()
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items.first?.text, "persist-2", "最新的应排在最前")
    }

    // MARK: - 去重

    func testConsecutiveDuplicateSignatureIsSkipped() {
        store.append(textItem("same"))
        store.append(textItem("same"))  // 与最新一条签名相同，应跳过（已在首位）
        store.flush()

        XCTAssertEqual(store.load().count, 1)
    }

    func testNonConsecutiveDuplicateMovesToFront() {
        store.append(textItem("A"))
        store.append(textItem("B"))
        store.append(textItem("A"))  // 再次复制 A：应把 A 置顶，且历史里只留一条 A
        store.flush()

        let items = store.load()
        XCTAssertEqual(items.count, 2, "全历史去重：重复的 A 不新增，只把原有那条移到最前")
        XCTAssertEqual(items.compactMap { $0.text }, ["A", "B"],
                       "每次复制的内容永远排第一，上一次复制的顺延第二")
    }

    func testMoveToFrontKeepsRelativeOrderOfOthers() {
        store.append(textItem("X"))
        store.append(textItem("Y"))
        store.append(textItem("Z"))
        store.append(textItem("X"))  // X 从最旧移到最前
        store.flush()

        XCTAssertEqual(store.load().compactMap { $0.text }, ["X", "Z", "Y"],
                       "置顶 X 后，其余条目保持原有新旧相对顺序")
    }

    func testImageDuplicateMovesToFrontAndDeletesStaleFile() {
        let data = Data("same-image".utf8)
        store.append(imageItem(fileName: "old.png", data: data), imageData: data)
        store.append(textItem("interlude"))
        // 再复制同一张图（内容签名相同，但文件名不同）
        store.append(imageItem(fileName: "new.png", data: data), imageData: data)
        store.flush()

        let items = store.load()
        XCTAssertEqual(items.count, 2, "同一张图重复复制应去重置顶，不新增")
        XCTAssertEqual(items.first?.kind, .image, "最新一条应是重新复制的那张图")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: itemsDirectoryURL.appendingPathComponent("old.png").path),
            "被移走的旧图片文件应删除，避免孤儿文件")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: itemsDirectoryURL.appendingPathComponent("new.png").path),
            "新图片文件应落盘")
    }

    // MARK: - 修剪

    func testTrimRemovesOldestBeyondMaxCount() {
        for i in 0..<5 { store.append(textItem("t\(i)")) }
        store.flush()

        XCTAssertEqual(store.load().compactMap { $0.text }, ["t4", "t3", "t2"],
                       "超过上限应删最旧，只保留最新 \(testMaxCount) 条")
    }

    func testTrimDeletesOldestContentFile() {
        // 插入 4 张图片（上限 3），最旧那张的内容文件应被连带删除
        for i in 0..<4 {
            let data = Data("image-bytes-\(i)".utf8)
            store.append(imageItem(fileName: "img\(i).png", data: data), imageData: data)
        }
        store.flush()

        let oldestFile = itemsDirectoryURL.appendingPathComponent("img0.png")
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldestFile.path),
                       "trim 掉的最旧图片，其内容文件应被删除")
        XCTAssertEqual(store.load().count, testMaxCount)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: itemsDirectoryURL.appendingPathComponent("img3.png").path),
            "最新图片的内容文件应保留")
    }

    func testMaxCountZeroStoresNothing() {
        let zeroStore = ClipboardHistoryStore(directoryURL: directoryURL, maxCountProvider: { 0 })
        zeroStore.append(textItem("should not store"))
        zeroStore.flush()

        XCTAssertTrue(zeroStore.load().isEmpty, "maxCount=0 表示不保留任何记录")
    }

    // MARK: - 删除 / 清空

    func testDeleteSingleItem() {
        let keep = textItem("keep")
        let remove = textItem("remove")
        store.append(keep)
        store.append(remove)
        store.flush()

        store.delete(id: remove.id)
        store.flush()

        let items = store.load()
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.id, keep.id)
    }

    func testDeleteRemovesContentFile() {
        let data = Data("delete-me".utf8)
        let item = imageItem(fileName: "todelete.png", data: data)
        store.append(item, imageData: data)
        store.flush()

        let file = itemsDirectoryURL.appendingPathComponent("todelete.png")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))

        store.delete(id: item.id)
        store.flush()

        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path),
                       "删除图片条目应连带删除其内容文件")
        XCTAssertTrue(store.load().isEmpty)
    }

    func testClearAllEmptiesStoreAndDirectory() {
        let data = Data("x".utf8)
        store.append(textItem("a"))
        store.append(imageItem(fileName: "c.png", data: data), imageData: data)
        store.flush()
        XCTAssertEqual(store.load().count, 2)

        store.clearAll()
        store.flush()

        XCTAssertTrue(store.load().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: itemsDirectoryURL.path),
                       "clearAll 应删除整个 items 目录")
    }

    // MARK: - 图片落盘 / 懒加载

    func testImageDataRoundTrip() {
        let data = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])  // PNG 头几字节
        let item = imageItem(fileName: "round.png", data: data)
        store.append(item, imageData: data)
        store.flush()

        XCTAssertEqual(store.imageData(for: item), data, "图片内容应原样落盘并可懒加载读回")
    }

    func testImageDataForTextItemIsNil() {
        let item = textItem("no image")
        store.append(item)
        store.flush()

        XCTAssertNil(store.imageData(for: item), "无 fileName 的文本条目读图应返回 nil")
    }
}

// MARK: - ClipboardCapture.makeItem 纯转换（分享扩展 / 键盘抓取共用）
//
// 不依赖 UIPasteboard / extensionContext，直接喂对象校验输出条目，覆盖分享扩展的转换链路。

final class ClipboardCaptureTests: XCTestCase {

    /// 生成一张 4x4 纯色测试图
    private func testImage() -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4))
        return renderer.image { context in
            UIColor.blue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
    }

    func testMakeItemFromString() {
        let captured = ClipboardCapture.makeItem(from: "hello")
        XCTAssertEqual(captured?.item.kind, .text)
        XCTAssertEqual(captured?.item.text, "hello")
        XCTAssertNil(captured?.imageData)
    }

    func testMakeItemFromEmptyStringIsNil() {
        XCTAssertNil(ClipboardCapture.makeItem(from: ""))
    }

    func testMakeItemFromWebURL() {
        let url = URL(string: "https://example.com/page")!
        let captured = ClipboardCapture.makeItem(from: url)
        XCTAssertEqual(captured?.item.kind, .url)
        XCTAssertEqual(captured?.item.text, url.absoluteString)
    }

    func testMakeItemFromFileURL() {
        let url = URL(fileURLWithPath: "/tmp/example.txt")
        let captured = ClipboardCapture.makeItem(from: url)
        XCTAssertEqual(captured?.item.kind, .fileURL)
        XCTAssertEqual(captured?.item.text, url.absoluteString)
    }

    func testMakeItemFromImage() {
        let captured = ClipboardCapture.makeItem(from: testImage())
        XCTAssertEqual(captured?.item.kind, .image)
        XCTAssertNotNil(captured?.imageData)
        XCTAssertEqual(captured?.item.fileName?.hasSuffix(".png"), true)
        XCTAssertNil(captured?.item.text, "图片不落 text，只落内容文件")
    }

    func testMakeItemFromImageData() {
        let data = testImage().pngData()!
        let captured = ClipboardCapture.makeItem(from: data)
        XCTAssertEqual(captured?.item.kind, .image, "能解码成图片的 Data 应识别为图片")
        XCTAssertNotNil(captured?.imageData)
    }

    func testMakeItemFromTextData() {
        let captured = ClipboardCapture.makeItem(from: Data("plain text".utf8))
        XCTAssertEqual(captured?.item.kind, .text)
        XCTAssertEqual(captured?.item.text, "plain text")
    }

    func testMakeItemFromUnsupportedObjectIsNil() {
        XCTAssertNil(ClipboardCapture.makeItem(from: NSNumber(value: 42)))
        XCTAssertNil(ClipboardCapture.makeItem(from: nil))
    }

    func testImageSignatureIsStableAndContentSensitive() {
        let a = ClipboardItem.imageSignature(Data([1, 2, 3]))
        let b = ClipboardItem.imageSignature(Data([1, 2, 3]))
        let c = ClipboardItem.imageSignature(Data([1, 2, 4]))
        XCTAssertEqual(a, b, "相同内容签名应稳定（跨进程 / 跨启动可比）")
        XCTAssertNotEqual(a, c, "不同内容签名应不同")
    }

    func testTextSignatureDistinguishesKind() {
        let asText = ClipboardItem.textSignature("x", kind: .text)
        let asURL = ClipboardItem.textSignature("x", kind: .url)
        XCTAssertNotEqual(asText, asURL, "字面相同但类型不同，签名应不同")
    }
}

// MARK: - ClipboardSettingsStore.clampMaxCount 边界（纯静态函数）

final class ClipboardSettingsStoreClampTests: XCTestCase {

    func testClampWithinRangeIsIdentity() {
        let mid = (ClipboardSettingsStore.maxCountRange.lowerBound
                   + ClipboardSettingsStore.maxCountRange.upperBound) / 2
        XCTAssertEqual(ClipboardSettingsStore.clampMaxCount(mid), mid)
    }

    func testClampAtBoundaries() {
        let range = ClipboardSettingsStore.maxCountRange
        XCTAssertEqual(ClipboardSettingsStore.clampMaxCount(range.lowerBound), range.lowerBound)
        XCTAssertEqual(ClipboardSettingsStore.clampMaxCount(range.upperBound), range.upperBound)
    }

    func testClampBelowLowerBound() {
        let under = ClipboardSettingsStore.maxCountRange.lowerBound - 100
        XCTAssertEqual(ClipboardSettingsStore.clampMaxCount(under),
                       ClipboardSettingsStore.maxCountRange.lowerBound)
    }

    func testClampAboveUpperBound() {
        let over = ClipboardSettingsStore.maxCountRange.upperBound + 100
        XCTAssertEqual(ClipboardSettingsStore.clampMaxCount(over),
                       ClipboardSettingsStore.maxCountRange.upperBound)
    }
}
