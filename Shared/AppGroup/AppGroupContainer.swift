import Foundation

// MARK: - App Group 共享容器
// App 本体和键盘扩展通过此类读写共享数据
// App Group ID 需在 Xcode Signing 中配置

public final class AppGroupContainer {
    public static let groupID = "group.com.openime.shared"

    /// 跨进程「设置已变更」广播名：主 App 各 Store 与 IMERuntime 发出，键盘扩展的
    /// NotificationCenter 观察者与 Darwin 观察者都引用这一处（口径同 FrequencyAdjustEngine.clearedNotificationName）
    public static let settingsChangedNotification = "com.openime.settingsChanged"

    public static let shared = AppGroupContainer()
    private init() {}

    private var containerURL: URL {
        if let url = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: Self.groupID
        ) {
            return url
        }
        return URL(fileURLWithPath: "/tmp/OpenIMEShared", isDirectory: true)
    }

    // MARK: - 目录

    /// 主 App Documents/schemes/ — 存放方案 zip 包，由 UIFileSharingEnabled 暴露给 Files.app
    /// 用户可在 Files.app 里查看、分享、删除 zip；App 启动时 syncSchemesStore 自动同步
    public var schemesStoreURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("schemes", isDirectory: true)
    }

    public var packagesURL: URL {
        containerURL.appendingPathComponent("packages", isDirectory: true)
    }

    public var userDataURL: URL {
        containerURL.appendingPathComponent("user", isDirectory: true)
    }

    public var cacheURL: URL {
        containerURL.appendingPathComponent("cache", isDirectory: true)
    }

    public var settingsFileURL: URL {
        userDataURL.appendingPathComponent("settings.json")
    }

    public var customWordsFileURL: URL {
        userDataURL.appendingPathComponent("custom_words.json")
    }

    public var predictionFileURL: URL {
        userDataURL.appendingPathComponent("prediction.bin")
    }

    /// 拼音动态调频学习量（user/frequency.json）——存「码、词、次数」，与预测同级、独立存储
    public var frequencyFileURL: URL {
        userDataURL.appendingPathComponent("frequency.json")
    }

    /// 方案展示顺序（user/scheme_order.json）—— 已安装方案 id 的稳定排列，决定方案管理页的列表次序：
    /// 内置三套按规范序在前，用户导入的按导入先后追加到末尾；卸载即从中剔除（位置记忆一并忘掉）。
    /// 存在 App Group 根目录下、不在任何包目录内，删方案不会波及它
    public var schemeOrderFileURL: URL {
        userDataURL.appendingPathComponent("scheme_order.json")
    }

    /// 剪贴板历史目录（user/clipboard/）——与自定义词典同级，存放 index.json 与 items/ 内容文件
    public var clipboardDirectoryURL: URL {
        userDataURL.appendingPathComponent("clipboard", isDirectory: true)
    }

    public func packageURL(for schemeId: String) -> URL {
        packagesURL.appendingPathComponent(schemeId, isDirectory: true)
    }

    /// 主 App Documents/logs/ — 由 UIFileSharingEnabled 暴露给 Files.app
    /// 键盘扩展不写此目录
    public var installLogsURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("logs", isDirectory: true)
    }

    /// 主 App Documents/templates/ — 存放示例 yaml 模版，由 UIFileSharingEnabled 暴露给 Files.app
    public var templatesURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("templates", isDirectory: true)
    }

    // MARK: - 初始化目录

    public func prepareDirectories() throws {
        let dirs = [packagesURL, userDataURL, cacheURL, schemesStoreURL, clipboardDirectoryURL]
        for dir in dirs {
            try FileManager.default.createDirectory(
                at: dir, withIntermediateDirectories: true
            )
        }
    }

    // MARK: - 设置读写

    public func loadSettings() -> UserSettings {
        guard let data = try? Data(contentsOf: settingsFileURL),
              let settings = try? JSONDecoder().decode(UserSettings.self, from: data)
        else {
            return UserSettings()
        }
        return settings
    }

    public func saveSettings(_ settings: UserSettings) throws {
        let data = try JSONEncoder().encode(settings)
        try data.write(to: settingsFileURL, options: .atomic)
    }

    // MARK: - 方案展示顺序读写

    /// 已安装方案的稳定展示顺序（id 列表）。读不到 / 解码失败返回空数组，
    /// 由 IMERuntime.reconciledSchemeOrder 按内置规范序 + 字母序重建 —— 不崩、不丢方案
    public func loadSchemeOrder() -> [String] {
        guard let data = try? Data(contentsOf: schemeOrderFileURL),
              let order = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return order
    }

    public func saveSchemeOrder(_ order: [String]) throws {
        let data = try JSONEncoder().encode(order)
        try data.write(to: schemeOrderFileURL, options: .atomic)
    }

    // MARK: - 用户自定义词读写

    public func loadCustomWords() -> [CustomWord] {
        guard let data = try? Data(contentsOf: customWordsFileURL),
              let words = try? JSONDecoder().decode([CustomWord].self, from: data)
        else {
            return []
        }
        return words
    }

    public func saveCustomWords(_ words: [CustomWord]) throws {
        let data = try JSONEncoder().encode(words)
        try data.write(to: customWordsFileURL, options: .atomic)
    }

    // MARK: - 已安装方案列表

    public func installedSchemeIds() -> [String] {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: packagesURL,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return [] }

        return contents.compactMap { url -> String? in
            var isDir: ObjCBool = false
            fm.fileExists(atPath: url.path, isDirectory: &isDir)
            guard isDir.boolValue else { return nil }
            // 以 . 开头的不是方案：安装过程中的暂存目录就叫 .<id>-staging-xxxx，
            // 万一泄漏（进程被杀）也不能让它被当成一个已装方案列出来
            let name = url.lastPathComponent
            guard !name.hasPrefix(".") else { return nil }
            return name
        }.sorted()
    }

    /// 已安装方案的版本号（读包目录里的 manifest.json）；没装或读不到返回 nil。
    /// 内置包升级补装要靠它与 App Bundle 里 manifest.yaml 的版本比对。
    public func installedSchemeVersion(id schemeId: String) -> String? {
        let url = packageURL(for: schemeId).appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object["version"] as? String
    }
}
