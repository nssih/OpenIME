import Foundation

// MARK: - 剪贴板历史条目模型
//
// 纯数据模型，不依赖 UIKit / SwiftUI，编译进 OpenIMECore，
// 主 App、键盘扩展、分享扩展共用同一份定义。
//
// 设计取舍：
//   - text 保存文本 / URL / 文件路径的字面值；图片不落 text，只落内容文件（fileName）
//   - previewText 用计算属性派生（图片显示「[图片]」，文本折叠换行并截断），
//     避免存两份、也避免 text 变了预览还停在旧值
//   - contentSignature 用于去重，由抓取方（ClipboardCapture / ShareViewController）算好传入

/// 剪贴板内容类型
public enum ClipboardItemKind: String, Codable {
    /// 纯文本
    case text
    /// http(s) 等可打开的 URL
    case url
    /// 文件路径（file:// URL）
    case fileURL
    /// 图片（内容落盘为文件，缩略图懒加载）
    case image
}

/// 一条剪贴板历史记录
public struct ClipboardItem: Codable, Identifiable, Equatable {

    public let id: UUID
    public let kind: ClipboardItemKind
    /// 文本 / URL / 路径的字面值；图片为 nil
    public let text: String?
    /// 内容文件名（图片落盘用），位于 store 的 items/ 目录下；纯文本为 nil
    public let fileName: String?
    public let createdAt: Date
    /// 去重签名：文本按内容哈希，图片按「字节数 + 内容哈希」
    public let contentSignature: String

    public init(
        id: UUID = UUID(),
        kind: ClipboardItemKind,
        text: String? = nil,
        fileName: String? = nil,
        createdAt: Date = Date(),
        contentSignature: String
    ) {
        self.id = id
        self.kind = kind
        self.text = text
        self.fileName = fileName
        self.createdAt = createdAt
        self.contentSignature = contentSignature
    }

    // MARK: - 展示

    /// 列表展示用的一行预览：图片显示「[图片]」，其余折叠换行并截断
    public var previewText: String {
        switch kind {
        case .image:
            return "[图片]"
        case .text, .url, .fileURL:
            return ClipboardItem.singleLinePreview(text ?? "")
        }
    }

    /// 折叠换行 / 连续空白为单个空格，并截断到合理长度（列表只展示一行）
    static func singleLinePreview(_ raw: String, limit: Int = ClipboardItem.previewCharacterLimit) -> String {
        let folded = raw
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .joined(separator: " ")
        if folded.count <= limit { return folded }
        let end = folded.index(folded.startIndex, offsetBy: limit)
        return String(folded[..<end]) + "…"
    }

    /// 预览截断长度（字符数）：列表只展示一行，超出折叠为「…」，避免长文本撑爆 cell
    static let previewCharacterLimit = 80

    // MARK: - 去重签名（纯函数，便于单测）

    /// 文本类签名：前缀区分类型，避免文本与 URL 字面相同却误判
    public static func textSignature(_ text: String, kind: ClipboardItemKind) -> String {
        "\(kind.rawValue):\(fnv1a(Array(text.utf8)))"
    }

    /// 图片签名：字节数 + 内容哈希
    public static func imageSignature(_ data: Data) -> String {
        "image:\(data.count):\(fnv1a([UInt8](data)))"
    }

    /// FNV-1a 64 位哈希：跨进程 / 跨启动稳定（Swift.hashValue 有随机种子，不能持久化比较）
    /// 两个十六进制常量是 FNV-1a 标准定义的 64 位 offset basis 与 prime，非可调参数
    static func fnv1a(_ bytes: [UInt8]) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in bytes {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 16)
    }
}
