import UIKit

// MARK: - 剪贴板抓取（键盘扩展与主 App 共用）
//
// iOS 平台约束：无法后台监听剪贴板、系统只保留最近一条、读取实际内容会弹一次「已粘贴」提示，
// 但读 UIPasteboard.changeCount 是静默的。因此本模块的抓取策略是：
//   先用 changeCount 静默判断「有没有变」，只有真变了才读一次内容（弹一次提示）并入库。
// 触发入口（多入口抓取）：键盘弹出 / 键盘可见期低频轮询 / 主 App 打开或回前台。
// 分享扩展（OpenIMEShare）是另一条独立入口，用于覆盖「键盘收起时在别处复制」，不走本文件。

public enum ClipboardCapture {

    /// 若剪贴板内容自上次抓取后有变化，则读取并入库（幂等、跨入口共享 lastChangeCount）
    /// - Note: 需在主线程调用（读取 UIPasteboard.general）
    public static func captureIfNeeded() {
        let settings = ClipboardSettingsStore.shared
        guard settings.isEnabled else { return }

        let pasteboard = UIPasteboard.general
        // changeCount 读取静默、不弹提示；未变化直接返回，避免无谓的「已粘贴」提示
        let currentChangeCount = pasteboard.changeCount
        guard currentChangeCount != settings.lastChangeCount else { return }

        // 内容确实变了才读取（读取会触发一次系统提示）
        guard let captured = readPasteboard(pasteboard) else {
            // 读不出可用内容（剪贴板被清空 / 仅含不支持类型）：仍推进 changeCount，避免反复尝试
            settings.lastChangeCount = currentChangeCount
            return
        }

        // 与上次抓取内容签名相同则跳过写入（去重）
        if captured.item.contentSignature == settings.lastSignature {
            settings.lastChangeCount = currentChangeCount
            return
        }

        ClipboardHistoryStore.shared.append(captured.item, imageData: captured.imageData)
        settings.lastChangeCount = currentChangeCount
        settings.lastSignature = captured.item.contentSignature
    }

    // MARK: - 内容转条目（纯函数，键盘抓取与分享扩展共用，便于单测）

    /// 抓取 / 分享的结果：待入库的条目 + 需要落盘的图片数据（纯文本为 nil）
    public struct Captured {
        public let item: ClipboardItem
        public let imageData: Data?
    }

    /// 把一个已加载的对象（UIImage / URL / Data / String）转成剪贴板条目。
    /// 不依赖 UIPasteboard / extensionContext —— 纯转换，方便单测直接喂对象校验；
    /// 分享扩展（OpenIMEShare）把 NSItemProvider 加载出的对象交给它，与键盘抓取同一套转换。
    /// 类型判断隐含优先级：图片 > URL > 文本。
    public static func makeItem(from object: Any?) -> Captured? {
        if let image = object as? UIImage, let data = image.pngData() {
            return imageItem(data: data)
        }
        if let url = object as? URL {
            let kind: ClipboardItemKind = url.isFileURL ? .fileURL : .url
            let value = url.absoluteString
            let item = ClipboardItem(kind: kind, text: value,
                                     contentSignature: ClipboardItem.textSignature(value, kind: kind))
            return Captured(item: item, imageData: nil)
        }
        if let data = object as? Data {
            // 分享 / 拖拽可能给到裸 Data：能解码成图片就当图片，否则按 UTF-8 文本
            if let image = UIImage(data: data) {
                return imageItem(data: image.pngData() ?? data)
            }
            if let text = String(data: data, encoding: .utf8) {
                return textItem(text)
            }
            return nil
        }
        if let text = object as? String {
            return textItem(text)
        }
        return nil
    }

    // MARK: - 私有

    private static func imageItem(data: Data) -> Captured {
        let id = UUID()
        let item = ClipboardItem(id: id, kind: .image, fileName: "\(id.uuidString).png",
                                 contentSignature: ClipboardItem.imageSignature(data))
        return Captured(item: item, imageData: data)
    }

    private static func textItem(_ text: String) -> Captured? {
        guard !text.isEmpty else { return nil }
        let item = ClipboardItem(kind: .text, text: text,
                                 contentSignature: ClipboardItem.textSignature(text, kind: .text))
        return Captured(item: item, imageData: nil)
    }

    /// 读取剪贴板内容，优先级：图片 > URL > 文本（图片信息量最大，与系统粘贴习惯一致）
    private static func readPasteboard(_ pasteboard: UIPasteboard) -> Captured? {
        if pasteboard.hasImages, let image = pasteboard.image, let captured = makeItem(from: image) {
            return captured
        }
        if pasteboard.hasURLs, let url = pasteboard.url, let captured = makeItem(from: url) {
            return captured
        }
        if pasteboard.hasStrings, let string = pasteboard.string, let captured = makeItem(from: string) {
            return captured
        }
        return nil
    }
}
