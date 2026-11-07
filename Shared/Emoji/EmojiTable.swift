import Foundation

// MARK: - emoji 映射表
//
// 打出某个词时，候选里紧跟原词追加一条「词 + emoji」变体（如「地球」后跟「地球 🌍 🌎 🌏」），
// 对齐元书 / 雾凇拼音的 emoji 体验。数据来自 rime-ice 的 opencc/emoji_word.txt（6906 条，
// 每行「词<Tab>词 emoji1 emoji2」），随 OpenIMECore framework bundle 一起分发。
//
// 关键：映射作用于候选「文字」而非输入码，所以拼音 / 形码 / 双拼任何方案打出该词都会追加变体，
// 与原版 Rime 的 simplifier@emoji_cn 后置滤镜同层——挂在 IMERuntime.postProcess 里，全方案通吃。
public final class EmojiTable {

    public static let shared = EmojiTable()

    /// 资源文件名（不含扩展名），与打包进 framework bundle 的 emoji_word.txt 对应
    private static let resourceName = "emoji_word"
    private static let resourceExtension = "txt"

    /// 词 → 「词 + emoji」整串替换值（opencc 表右列原样）。
    /// 键是不带 emoji 的原词，所以变体串本身永远不会再命中映射，追加逻辑不会自我递归。
    private var map: [String: String]?
    private let lock = NSLock()

    private init() {}

    /// 查某词对应的 emoji 变体整串；无映射返回 nil。
    /// 首次调用时惰性解析并缓存（6906 行一次性建成字典，之后每次查询 O(1)）。
    public func replacement(for text: String) -> String? {
        guard !text.isEmpty else { return nil }
        return loadedMap()[text]
    }

    /// 映射条目数（单测 / 诊断用）：解析失败或资源缺失时为 0
    public var count: Int {
        loadedMap().count
    }

    /// 取（并按需构建）映射字典。加锁保证多线程只解析一次：
    /// IMERuntime 在主线程查，键盘扩展首帧与主 App 打字测试区可能并发触达。
    private func loadedMap() -> [String: String] {
        lock.lock()
        defer { lock.unlock() }
        if let map { return map }
        let built = Self.parse()
        map = built
        return built
    }

    /// 从 framework bundle 读 emoji_word.txt 并解析成字典。
    /// 用锚点类定位 bundle：IMERuntime / 本类都在 OpenIMECore，Bundle(for:) 拿到的正是
    /// 打包了该资源的核心库 bundle，主 App 与键盘扩展两种宿主下都成立。
    private static func parse() -> [String: String] {
        let bundle = Bundle(for: EmojiBundleAnchor.self)
        guard let url = bundle.url(forResource: resourceName, withExtension: resourceExtension),
              let content = try? String(contentsOf: url, encoding: .utf8) else {
            return [:]
        }
        var result: [String: String] = [:]
        result.reserveCapacity(7000)
        // 逐行「词<Tab>替换值」：只认第一个 Tab 分隔，右列整串（含空格与多个 emoji）原样作替换值。
        // 跳过注释行（# 开头）、空行、以及右列与左列相同（无 emoji）的退化条目。
        for line in content.split(separator: "\n", omittingEmptySubsequences: true) {
            guard !line.hasPrefix("#") else { continue }
            guard let tab = line.firstIndex(of: "\t") else { continue }
            let key = String(line[line.startIndex..<tab])
            let value = String(line[line.index(after: tab)...])
            guard !key.isEmpty, value != key else { continue }
            result[key] = value
        }
        return result
    }
}

/// 定位 OpenIMECore framework bundle 的锚点类（与 CJKFontBundleAnchor 同一手法）
private final class EmojiBundleAnchor {}
