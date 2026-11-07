import Foundation

// MARK: - 剪贴板历史持久化引擎
//
// 照 PredictionEngine 的串行队列线程安全范式，但采用「读盘-改-写盘」而非内存缓存：
// 主 App、键盘扩展、分享扩展是三个进程，各自持有 shared 单例，若缓存内存副本，
// 一个进程删了条目、另一个进程仍拿旧列表写回会「复活」已删项。剪贴板操作低频
// （仅在内容变化时写、面板打开时读），每次读一小份 index.json 代价可忽略，
// 以磁盘为准可天然避免跨进程陈旧。
//
// 目录结构：
//   <clipboardDirectoryURL>/index.json      元数据数组，新在前旧在后
//   <clipboardDirectoryURL>/items/<file>    —— 图片等落盘内容，懒加载读回

public final class ClipboardHistoryStore {

    public static let shared = ClipboardHistoryStore(
        directoryURL: AppGroupContainer.shared.clipboardDirectoryURL
    )

    private let directoryURL: URL
    private let indexURL: URL
    private let itemsDirectoryURL: URL
    private let queue = DispatchQueue(label: "com.openime.clipboardHistory", qos: .utility)
    /// 保留条数上限来源；默认读实时设置，单测可注入固定值
    private let maxCountProvider: () -> Int

    public init(
        directoryURL: URL,
        maxCountProvider: @escaping () -> Int = { ClipboardSettingsStore.shared.maxCount }
    ) {
        self.directoryURL = directoryURL
        self.indexURL = directoryURL.appendingPathComponent("index.json")
        self.itemsDirectoryURL = directoryURL.appendingPathComponent("items", isDirectory: true)
        self.maxCountProvider = maxCountProvider
    }

    // MARK: - 读取

    /// 全部历史（新在前旧在后）。以磁盘为准，跨进程一致
    public func load() -> [ClipboardItem] {
        queue.sync { readIndex() }
    }

    /// 当前条数（主 App 词典页副标题展示用）
    public var count: Int {
        queue.sync { readIndex().count }
    }

    /// 懒加载读回内容文件（图片缩略图 / 原图）
    public func imageData(for item: ClipboardItem) -> Data? {
        queue.sync {
            guard let fileName = item.fileName, !fileName.isEmpty else { return nil }
            let fileURL = itemsDirectoryURL.appendingPathComponent(fileName)
            return try? Data(contentsOf: fileURL)
        }
    }

    // MARK: - 写入

    /// 追加一条：去重（与最新一条签名相同则跳过），落内容文件，trim，写索引
    /// - Parameter imageData: 图片等需要落盘的内容；纯文本传 nil（值已在 item.text 里）
    public func append(_ item: ClipboardItem, imageData: Data? = nil) {
        queue.async { [weak self] in
            guard let self else { return }
            var items = self.readIndex()
            // maxCount == 0 表示不保留任何记录
            let limit = self.maxCountProvider()
            guard limit > 0 else { return }

            // 全历史去重 + 命中置顶：相同内容若已在历史里（不止最新一条），先删掉旧的那条，
            // 再把它当作最新内容重新插到最前 —— 用户每次复制的内容永远排第一位，
            // 上一次复制的顺延到第二位。旧条目本就在首位时直接跳过，省一次无谓写盘。
            // 查重是 ≤maxCount 元素的内存数组遍历（微秒级），且整段跑在串行后台队列，
            // 不新增磁盘 I/O（本就要 readIndex/writeIndex）、不碰击键热路径。
            if let existing = items.firstIndex(where: { $0.contentSignature == item.contentSignature }) {
                if existing == 0 { return }
                // 图片条目：旧那条的图片文件随移除一并删掉（新条目用的是另一个文件名），避免孤儿文件
                self.deleteContentFile(for: items[existing])
                items.remove(at: existing)
            }

            if let data = imageData, let fileName = item.fileName, !fileName.isEmpty {
                self.ensureItemsDirectory()
                let fileURL = self.itemsDirectoryURL.appendingPathComponent(fileName)
                try? data.write(to: fileURL, options: .atomic)
            }

            items.insert(item, at: 0)
            items = self.trim(items, to: limit)
            self.writeIndex(items)
        }
    }

    /// 删除单条（连带删内容文件）
    public func delete(id: UUID) {
        queue.async { [weak self] in
            guard let self else { return }
            var items = self.readIndex()
            guard let index = items.firstIndex(where: { $0.id == id }) else { return }
            let removed = items.remove(at: index)
            self.deleteContentFile(for: removed)
            self.writeIndex(items)
        }
    }

    /// 清空全部：删整个 items 目录 + 写空索引
    public func clearAll() {
        queue.async { [weak self] in
            guard let self else { return }
            try? FileManager.default.removeItem(at: self.itemsDirectoryURL)
            self.writeIndex([])
        }
    }

    /// 用户调小保留条数后触发一次修剪（主 App 设置页 onChange 调用）
    public func trimToLimit() {
        queue.async { [weak self] in
            guard let self else { return }
            let items = self.readIndex()
            let trimmed = self.trim(items, to: self.maxCountProvider())
            if trimmed.count != items.count {
                self.writeIndex(trimmed)
            }
        }
    }

    /// 同步等待所有已入队写操作完成
    /// —— 分享扩展在 completeRequest 前调用，避免进程被系统提前回收导致没落盘
    public func flush() {
        queue.sync {}
    }

    // MARK: - 私有

    private func readIndex() -> [ClipboardItem] {
        guard let data = try? Data(contentsOf: indexURL),
              let decoded = try? JSONDecoder().decode([ClipboardItem].self, from: data) else {
            return []
        }
        return decoded
    }

    private func writeIndex(_ items: [ClipboardItem]) {
        ensureDirectories()
        if let data = try? JSONEncoder().encode(items) {
            try? data.write(to: indexURL, options: .atomic)
        }
    }

    /// 保留前 limit 条（新在前旧在后），删掉更旧条目的内容文件；limit<=0 时清空
    private func trim(_ items: [ClipboardItem], to limit: Int) -> [ClipboardItem] {
        guard limit >= 0, items.count > limit else { return items }
        for item in items[limit...] {
            deleteContentFile(for: item)
        }
        return Array(items[0..<limit])
    }

    private func deleteContentFile(for item: ClipboardItem) {
        guard let fileName = item.fileName, !fileName.isEmpty else { return }
        let fileURL = itemsDirectoryURL.appendingPathComponent(fileName)
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func ensureDirectories() {
        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }

    private func ensureItemsDirectory() {
        try? FileManager.default.createDirectory(at: itemsDirectoryURL, withIntermediateDirectories: true)
    }
}
