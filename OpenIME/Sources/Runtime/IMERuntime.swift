import Foundation
import Combine
import ZIPFoundation

/// 词图后台计算的新鲜度闸门（线程安全）：主线程每次真正起算前写入最新世代号，
/// 后台串行队列在动手算之前先读一次 —— 若已不是最新（用户又敲了键），整段 O(n²) 词图
/// 直接跳过。连续击键时旧任务会在串行队列上排队，没有这道闸门它们会各自算完（真机实测
/// 一次长句输入触发几十段词图、每段数百毫秒），把当前串的结果压在十几秒的陈旧计算之后，
/// 表现为「码一长就半天不出候选」。用 NSLock 护一个 Int，读写都是纳秒级、不阻塞任何一方。
fileprivate final class LatticeFreshnessGate: @unchecked Sendable {
    private let lock = NSLock()
    private var generation = 0
    func set(_ value: Int) { lock.lock(); generation = value; lock.unlock() }
    func current() -> Int { lock.lock(); defer { lock.unlock() }; return generation }
}

// MARK: - Runtime Core
// 键盘扩展和主 App 都通过这个类访问所有功能

@MainActor
public final class IMERuntime: ObservableObject {

    // MARK: - 单例（键盘扩展内使用）
    public static let shared = IMERuntime()

    // MARK: - 状态
    @Published public private(set) var inputBuffer: String = ""
    @Published public private(set) var candidates: [MixCandidate] = []
    @Published public private(set) var installedSchemes: [InstalledScheme] = []
    @Published public private(set) var isReady: Bool = false

    @Published public private(set) var settings: UserSettings = UserSettings()

    // MARK: - 键盘形态（新增：小鹤双拼）
    // 只影响「输入编码如何展开成全拼前缀」，默认 .pinyin26 时走原有分支，行为与原实现完全一致。
    @Published public private(set) var inputMode: KeyboardMode = .pinyin26

    /// 内嵌编码：宿主输入框里显示的拼音
    /// 26 键全拼：就是输入码本身（与原实现一致）
    /// 小鹤双拼：展开还原后的拼音（如 nihc 对应 nihao）
    @Published public private(set) var inlineInput: String = ""

    // MARK: - 注释行可见性
    // 取决于全局开关以及当前参与方案是否有注释列，与候选内容无关，不随击键抖动。
    // 参与判断的方案 = 主方案 + 按能力策略真正生效的混打参与方案：
    // 非法混打组合在运行期根本不出候选，它的注释列也就不该把注释行撑出来（否则整行空白）。
    public var showAnnotationRow: Bool {
        IMERuntime.computeShowAnnotationRow(settings: settings, installedSchemes: installedSchemes)
    }

    public static nonisolated func computeShowAnnotationRow(
        settings: UserSettings,
        installedSchemes: [InstalledScheme]
    ) -> Bool {
        guard settings.showAnnotation else { return false }
        let schemeMap = Dictionary(uniqueKeysWithValues: installedSchemes.map { ($0.id, $0) })
        let activeId = settings.activeSchemeId
        let primaryProfile = schemeMap[activeId].map { SchemeProfile(scheme: $0) }
        let participants = SchemeCapability.effectiveMixConfigs(
            settings.mixInputEnabled ? settings.mixInputSchemes : [],
            primary: primaryProfile,
            profileOf: { id in schemeMap[id].map { SchemeProfile(scheme: $0) } })
        let ids = [activeId] + participants.map { $0.id }
        return ids.contains { id in
            schemeMap[id]?.availableColumns.contains("annotation") == true
        }
    }

    // MARK: - 子模块
    private let candidateEngine = CandidateEngine()
    private lazy var mixEngine = MixInputEngine(candidateEngine: candidateEngine)
    private let installer = PackageInstaller()
    private let container = AppGroupContainer.shared

    // 智能预测引擎（懒加载，用到时才初始化文件路径）
    private lazy var predictionEngine: PredictionEngine = {
        PredictionEngine(fileURL: container.predictionFileURL)
    }()

    // 拼音动态调频引擎（懒加载，与预测同构：学习走后台落盘、查询只做主线程内存读）。
    // 注入 App Group 标记：引擎在 record/落盘前自检「别的进程是否清过」，配合
    // frequencyCleared 广播双层防复活；suite 不可得时传 nil，退化为仅靠广播覆盖。
    private lazy var frequencyEngine: FrequencyAdjustEngine = {
        FrequencyAdjustEngine(
            fileURL: container.frequencyFileURL,
            clearMarker: UserDefaults(suiteName: AppGroupContainer.groupID)
        )
    }()

    // 上一个上屏词（用于预测关联记录）
    private var lastCommittedText: String = ""

    /// 预测槽位缓存（键 = 产生这批预测的上一个词）：predict() 是 PredictionEngine 内部串行队列的
    /// queue.sync，会阻塞主线程等它跑完（队列可能正在写盘）。两次上屏之间 lastCommittedText 不变、
    /// 该词的预测表也不变（新词对只在选词时 record，且 record 后 lastCommittedText 立即改变），
    /// 每键重算纯属浪费、还制造主线程与后台队列的竞争。按 lastCommittedText 缓存挑好的槽位，
    /// 把 queue.sync 从「每键一次」降到「每次上屏一次」。
    private var predictionCacheKey: String = ""
    private var predictionCache: [(text: String, position: Int)] = []

    /// 主 App 侧跨进程设置观察者是否已注册（幂等，避免重复注册叠加回调）
    private var didRegisterSettingsObserver = false

    private init() {
        // 把调频查询器注入候选引擎：只在主线程读活表（不碰磁盘、不阻塞），
        // 每次查询实时读 dynamicFreqEnabled —— 用户在设置里关掉立即生效，不必重开键盘。
        // weak 断开「candidateEngine 经 closure 指回 self」的循环引用（candidateEngine 由 self 持有）。
        candidateEngine.frequencyBoost = { [weak self] code, text in
            guard let self, self.settings.dynamicFreqEnabled else { return 0 }
            return self.frequencyEngine.count(code: code, text: text)
        }
    }

    // MARK: - 启动

    /// start() 的并发重入护栏：只挡「同一时刻并发重入」，不挡顺序重跑（单测 setUp 会对同一
    /// 单例反复 await start()，顺序重跑必须照常生效）。start() 里的 loadInstalledSchemes 会
    /// 重建全部方案 reader（mmap 打开词库），并发重入会让同一份词库被打开多次、内存翻倍；
    /// 键盘扩展进程内存上限低，累积到阈值就被 jetsam 杀掉、iOS 回落上一个键盘（「被顶掉」）。
    private var isStarting = false

    public func start() async {
        guard !isStarting else { return }
        isStarting = true
        defer { isStarting = false }
        do {
            try container.prepareDirectories()
            settings = container.loadSettings()
            let customWords = container.loadCustomWords()
            candidateEngine.updateCustomWords(customWords)
            // syncSchemesStore 依赖 App Bundle 资源和 Documents/，只在主 App 进程执行
            if !isKeyboardExtension {
                await syncSchemesStore()
                writeTemplateIfNeeded()
            }
            await loadInstalledSchemes()
            purgeOrphanSettings()
            reconcileKeyboardMode()
            isReady = true
        } catch {
            isReady = true
        }
    }

    private var isKeyboardExtension: Bool {
        Bundle.main.bundleIdentifier?.hasSuffix(".keyboard") == true
    }

    // 键盘扩展收到跨进程通知后调用，从磁盘重新加载设置。
    // 主线程只做两件事：指纹判定 + 轻量的设置解码与形态对账（微秒级，击键路径零等待）；
    // 重活（读自定义词、解析全部方案清单、构建新词库 reader）全部后台，
    // 完成后回主线程原子切换 —— 装方案 / 换词库永远不打断打字
    public func reloadSettings() {
        // 磁盘指纹护栏：键盘端每次击键（textWillChange）、每次布局 pass（viewWillLayoutSubviews）
        // 都会调到这里，副键盘的翻屏跟手 / 长按气泡 / 按压动画更是逐帧触发；无护栏时每次调用
        // 都要解码设置、重载全部已装方案并作废候选缓存，主线程 I/O 风暴会让扩展进程被系统
        // 回收、iOS 回落系统键盘。指纹不变说明磁盘没动过，直接返回；
        // 主 App 存设置 / 装缷方案必然改变指纹，跨进程同步语义不受影响。
        let fingerprint = currentReloadFingerprint()
        guard fingerprint != lastReloadFingerprint else { return }
        lastReloadFingerprint = fingerprint

        // 轻活留在主线程：设置 JSON 很小，就地解码赋值，开关类改动立即反映到界面；
        // 形态对账也就地进行 —— 切方案通常发生在已装方案之间，画像缓存就在手边，
        // 不合法的形态当场收回，不用等后台（新装方案尚未就位时链为空，对账自然跳过）
        settings = container.loadSettings()
        reconcileKeyboardMode()

        // 重活全部丢后台：期间打字继续用旧的一套 reader（mmap 旧文件天然安全），
        // 完成后回主线程原子切换。世代号防旧盖新：连续多次重载时只允许最后一次落地
        reloadGeneration += 1
        let generation = reloadGeneration
        // 主线程值快照：哪些方案已经有 reader，没变的不重建
        let loadedIds = Set(installedSchemes.map { $0.id })
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let customWords = self.container.loadCustomWords()
            // 与方案管理页同源的稳定顺序（持久化插入序，新导入在末尾）；纯读不写盘 ——
            // 这条路径每次击键都可能触发，写盘会抖动磁盘、拖慢打字
            let schemes = self.orderedInstalledSchemeIds()
                .compactMap { try? self.installer.loadInstalled(schemeId: $0) }
            let newReaders = CandidateEngine.buildReaders(
                for: schemes.filter { !loadedIds.contains($0.id) })
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                guard self.reloadGeneration == generation else { return }
                self.candidateEngine.applyReloaded(schemes: schemes, newReaders: newReaders)
                self.candidateEngine.updateCustomWords(customWords)
                self.installedSchemes = schemes
                self.invalidateSchemeCaches()
                // 新装方案可能改变可用形态集合（如装了形码后双拼不再被撑起），再对一次账
                self.reconcileKeyboardMode()
            }
        }
    }

    /// 异步重载的世代号（只在主线程读写）：后台结果回主线程落地前比对，
    /// 过期快照直接丢弃，保证只有最后一次重载的结果生效
    private var reloadGeneration = 0

    /// reloadSettings 的磁盘指纹。
    ///
    /// settings.json 用内容哈希而非 mtime：主 App / 键盘两端存设置走的是原子写
    /// （.atomic 先写临时文件再替换），哪怕写入的内容与磁盘上完全一致，替换动作也会把
    /// mtime 顶到新值。首启时字段抖动会连着触发若干次「内容没变的空写」，mtime 指纹据此
    /// 判定磁盘动过 → RELOAD → 重解码设置 → @Published 变 → 视图 onChange 又存一次 →
    /// 自激环（真机实测首启十几次空 SAVE 与 RELOAD 交织）。改成内容哈希后，内容不变指纹
    /// 就不变，环自然断开；只有设置真的改了才重载，跨进程同步语义不受影响。
    /// settings.json 只有几 KB，读一遍算 FNV-1a 是微秒级，远比一次 RELOAD 风暴便宜。
    /// customWords 不在自激环里（只在用户显式增删自定义词时才写）且可能较大，沿用 mtime+size。
    private var lastReloadFingerprint: String = ""

    private func currentReloadFingerprint() -> String {
        let fm = FileManager.default
        func stamp(_ url: URL) -> String {
            guard let attrs = try? fm.attributesOfItem(atPath: url.path),
                  let date = attrs[.modificationDate] as? Date,
                  let size = attrs[.size] as? Int64 else { return "-" }
            return "\(date.timeIntervalSince1970):\(size)"
        }
        return Self.contentHash(of: container.settingsFileURL) + "|"
            + stamp(container.customWordsFileURL) + "|"
            + container.installedSchemeIds().joined(separator: ",")
    }

    /// 小文件内容指纹（FNV-1a 64 位）：读不到返回 "-"，与旧指纹缺省值一致。
    /// 只在主线程读几 KB 的 settings.json，无锁无阻塞。
    private static func contentHash(of url: URL) -> String {
        guard let data = try? Data(contentsOf: url) else { return "-" }
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in data {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return "\(data.count):\(hash)"
    }

    /// 主 App 侧监听跨进程设置广播（Darwin 通知），收到后切回主线程重载设置。
    ///
    /// 键盘扩展是独立进程：在它里面激活方案 / 改开关只写盘 + 发 Darwin 通知。主 App 在前台、
    /// 键盘同屏时（如在混合页的打字测试区里用键盘切方案），scenePhase 始终是 .active 不会触发
    /// 回前台重载，只有这个观察者能实时收到。回前台重载（scenePhase）则覆盖 App 曾被挂起、
    /// 错过广播的情况，两者互补。
    ///
    /// 只由主 App 的 UI 层调用，不放进 start()：单元测试直接跑 IMERuntime.shared 而不建 UI，
    /// 若在 start() 注册会让每个 setUp 都叠加一个观察者、并引入异步 reload 干扰断言。
    /// 键盘进程有自己的 KeyboardViewController 观察者（还要顺带重算高度），这里用 isKeyboardExtension 排除。
    /// reloadSettings 在主线程只剩指纹判定与轻量设置解码（重活已异步化，见其注释），
    /// 键盘端每次击键 textWillChange 都会调它也不阻塞；
    /// 幂等：root view 常驻，注册一次即可，无需移除。
    public func observeSettingsChangesIfNeeded() {
        guard !isKeyboardExtension, !didRegisterSettingsObserver else { return }
        didRegisterSettingsObserver = true
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            { _, _, _, _, _ in
                // Darwin 回调在非主线程；用单例切回主 actor，闭包不捕获任何上下文（可作 C 函数指针）
                Task { @MainActor in IMERuntime.shared.reloadSettings() }
            },
            AppGroupContainer.settingsChangedNotification as CFString,
            nil,
            .deliverImmediately
        )
    }

    // MARK: - 启动时方案仓库对账
    //   packages/ 有但 schemes/ 无 zip：内置方案补回 zip；用户方案删掉孤儿产物
    //   schemes/ 有 zip 但 packages/ 无产物：重新安装
    //   两边都没有：从 App Bundle 初始化内置方案

    private func writeTemplateIfNeeded() {
        let dir = container.templatesURL
        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent("示例方案.yaml")
        guard !fm.fileExists(atPath: dest.path) else { return }
        let template =
            "# 方案唯一标识，只能用字母、数字、连字符，在 App 内必须唯一\n" +
            "id: shi-li-fang-an\n\n" +
            "# 方案显示名称\n" +
            "name: 示例方案\n\n" +
            "# 方案类型\n" +
            "# syllable        音码（雾凇拼音、粤拼等）\n" +
            "# direct          形码（虎码、五笔、仓颉等）或音形码（快码、二笔等）\n" +
            "# double_syllable 双拼（小鹤双拼、自然码等）\n" +
            "type: syllable\n\n" +
            "# 作者名（可选，可以不填）\n" +
            "author:\n\n" +
            "# 方案简介（可选，显示在方案详情页）\n" +
            "description:\n\n" +
            "# ── 词库 ──────────────────────────────────────────────────────\n" +
            "# --- 下方开始填写词条，每行一个，各列之间用 Tab 键分隔（不能用空格）\n" +
            "# 格式：汉字[Tab]编码[Tab]权重[Tab]注释\n" +
            "#\n" +
            "# 权重：数字，越大候选越靠前；不填则所有词等权重\n" +
            "# 注释：在 App 方案设置里开启「显示候选注释」后，注释会显示在候选词上方\n" +
            "#       注释列必须保留（字段存在但内容可以留空）\n" +
            "---\n" +
            "你好\tnihao\t1000\tnǐ hǎo\n" +
            "你们\tnimen\t950\t\n" +
            "你好吗\tnihaoma\t900\tnǐ hǎo ma\n" +
            "年级\tnanji\t800\t\n" +
            "年龄\tnanling\t780\t\n" +
            "世界\tshijie\t1000\tshì jiè\n" +
            "时间\tshijian\t950\t\n" +
            "事情\tshiqing\t900\t\n" +
            "拼音\tpinyin\t1000\tpīn yīn\n" +
            "苹果\tpingguo\t950\tpíng guǒ\n" +
            "朋友\tpengyou\t900\t\n" +
            "品质\tpinzhi\t850\t\n" +
            "漂亮\tpiaoliang\t800\t\n" +
            "中国\tzhongguo\t1000\tzhōng guó\n" +
            "中文\tzhongwen\t950\t\n" +
            "自然\tziran\t900\t\n" +
            "知识\tzhishi\t850\t\n" +
            "重要\tzhongyao\t800\t\n" +
            "汉字\thanzi\t900\t\n" +
            "汉语\thanyu\t850\t\n" +
            "学习\txuexi\t900\t\n" +
            "学生\txuesheng\t850\t\n" +
            "生活\tshenghuo\t900\t\n" +
            "工作\tgongzuo\t900\t\n" +
            "开心\tkaixing\t850\t\n" +
            "快乐\tkuaile\t850\t\n"
        try? template.write(to: dest, atomically: true, encoding: .utf8)
    }

    //   整条对账链 nonisolated 在后台跑：首装 / 版本迁移时这里有扫目录、重排 dict.bin、
    //   打包 zip、解包重编等数百毫秒级文件重活，留在主线程会拖慢 App 启动、推迟键盘首字。
    //   依赖面已核：container / installer 无共享可变状态（纯文件操作单例）；引擎副作用
    //   （unloadScheme）回主线程执行 —— 与 reloadSettings 的异步化范式同源。
    //   start() 里仍然 await 它：对账没跑完不进入 loadInstalledSchemes，顺序语义不变。
    private nonisolated func syncSchemesStore() async {
        // 引擎副作用回主线程：打字查询只跑主线程，卸载动作也必须在主线程改字典
        let engine = candidateEngine
        let fm = FileManager.default
        let schemesDir = container.schemesStoreURL

        // 读取 packages/ 下所有已安装 id
        let installedIds = container.installedSchemeIds()

        // 读取 schemes/ 下所有 zip，建立 id 到 zipURL 的映射
        var zipById: [String: URL] = [:]
        if let zips = try? fm.contentsOfDirectory(at: schemesDir, includingPropertiesForKeys: nil) {
            for url in zips where url.pathExtension == "zip" {
                if let id = schemeId(ofZip: url) {
                    zipById[id] = url
                }
            }
        }

        // 0. 补建长串词图兜底要用的字级二元语法侧车：旧版本装好的拼音方案只有 dict.bin。
        //     扫一份 30MB 词库派生二元语法是秒级重活，放后台队列做，绝不占主线程；
        //     它与候选加载互不依赖（独立文件），没建好时那一次长串切分退回没有二元语法的排序，随后自动变好。
        let lmTargets = installedIds.map { container.packageURL(for: $0).appendingPathComponent("dict.bin") }
        DispatchQueue.global(qos: .utility).async {
            for binURL in lmTargets {
                _ = try? DictCompiler.buildLanguageModelIfNeeded(at: binURL)
            }
        }

        // 1. packages/ 有但 schemes/ 没有对应 zip
        let deletedBundled = Self.deletedBundledIDs()
        for id in installedIds where zipById[id] == nil {
            let isBundled = self.isBundledScheme(id: id)
            if isBundled && !deletedBundled.contains(id) {
                // 内置方案：从 App Bundle 重新打包 zip 补回来
                rebuildBundledZip(id: id)
                // 重新读一次，让后续步骤能看到
                if let zips = try? fm.contentsOfDirectory(at: schemesDir, includingPropertiesForKeys: nil) {
                    for url in zips where url.pathExtension == "zip" {
                        if let zid = schemeId(ofZip: url), zid == id {
                            zipById[id] = url
                        }
                    }
                }
            } else {
                // 用户方案：zip 已删，视为用户主动删除，清掉编译产物
                try? installer.uninstall(schemeId: id)
                await MainActor.run { engine.unloadScheme(id: id) }
            }
        }

        // 2. schemes/ 有 zip 但 packages/ 没有编译产物
        //    内置方案重新安装；用户方案的 zip 是孤儿残留，直接删除
        for (id, zipURL) in zipById where !installedIds.contains(id) {
            let isBundled = isBundledScheme(id: id)
            if isBundled {
                _ = try? await installer.install(zipURL: zipURL, overwrite: false, isBundled: true)
            } else {
                try? fm.removeItem(at: zipURL)
            }
        }

        // 3. 补装缺失的内置方案。不能只在「两边都空」时才装 —— 老安装升级上来
        //    时 packages 里已经有旧方案了，App 新收录的内置方案（如虎码 / 超强快码）
        //    就永远装不进来；用户主动删掉的内置方案记在 deletedSet 里，不会复活。
        await installMissingBundled(installedIds: container.installedSchemeIds())

        // 4. 编译纪元对账：老包里的 dict.bin 格式完全合法，却是老编译器编的 ——
        //    比如雾凇拼音缺了 import_tables 导入的五张表、超强快码缺了 encoder 派生的词组码。
        //    upgradeBinaryIfNeeded 认不出这种「格式对但词条少」的情况，只有纪元号能。
        recompileOutdatedSchemes(ids: container.installedSchemeIds(), zipById: zipById)
    }

    /// 编译纪元落后的方案，从原始 zip 重编替换
    ///
    /// 为什么必须后台：解 zip + 解析几十 MB YAML + 重写 dict.bin 是秒级重活，
    /// 而它只是「让老包享受到新编译逻辑」，晚几秒生效完全无害 —— 沿用二元语法侧车那套不阻塞启动的做法。
    /// 为什么必须有 zip：zip 是唯一的原始词库来源，用户删了就保留旧库继续用，绝不凭空重编。
    /// 重编失败也只记一笔就跳过：旧库再差也比没有强。
    private nonisolated func recompileOutdatedSchemes(ids: [String], zipById: [String: URL]) {
        let installer = self.installer
        let engine = self.candidateEngine
        let targets: [(id: String, zip: URL, bundled: Bool)] = ids.compactMap { id in
            guard let zipURL = zipById[id],
                  Self.needsRecompile(manifestURL: container.packageURL(for: id)
                                        .appendingPathComponent("manifest.json"))
            else { return nil }
            return (id, zipURL, isBundledScheme(id: id))
        }
        guard !targets.isEmpty else { return }

        Task.detached(priority: .utility) {
            for target in targets {
                guard (try? await installer.install(zipURL: target.zip, overwrite: true,
                                                    isBundled: target.bundled)) != nil else { continue }
                // 换掉了 dict.bin，把还 mmap 着旧文件的 reader 丢掉，下次查询自然读新的
                await MainActor.run { engine.unloadScheme(id: target.id) }
            }
        }
    }

    /// manifest 里记的编译纪元是否落后于当前编译器
    ///
    /// 旧包没有这个键，解出 nil 按 0 算 —— 它们确实是老编译器编的，正该重编。
    /// manifest.json 都读不到说明这个包本身就不完整，交给前面的对账步骤处理，这里不插手。
    private nonisolated static func needsRecompile(manifestURL: URL) -> Bool {
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(SchemeManifest.self, from: data)
        else { return false }
        return (manifest.compilerEpoch ?? 0) < DictCompiler.compilerEpoch
    }

    /// 判断某个已安装方案是否来自内置（读 packages/<id>/source.json）
    private nonisolated func isBundledScheme(id: String) -> Bool {
        let sourceURL = container.packageURL(for: id).appendingPathComponent("source.json")
        guard let data = try? Data(contentsOf: sourceURL),
              let dict = try? JSONDecoder().decode([String: Bool].self, from: data)
        else { return false }
        return dict["bundled"] == true
    }

    /// 从 App Bundle 找到对应的 .bundle 目录，打包成 zip 写入 Documents/schemes/
    private nonisolated func rebuildBundledZip(id: String) {
        guard let bundledDir = Bundle.main.url(forResource: "BundledSchemes", withExtension: nil),
              let items = try? FileManager.default.contentsOfDirectory(
                at: bundledDir, includingPropertiesForKeys: nil)
        else { return }
        for bundleURL in items where bundleURL.pathExtension == "bundle" {
            // 读 manifest.yaml 确认 id 匹配
            guard Self.manifestField(ofBundle: bundleURL, key: "id") == id else { continue }
            let zipName = bundleURL.deletingPathExtension().lastPathComponent + ".zip"
            let destZip = container.schemesStoreURL.appendingPathComponent(zipName)
            try? FileManager.default.zipItem(at: bundleURL, to: destZip, shouldKeepParent: false)
            return
        }
    }

    /// 内置方案并行安装的并发上限
    ///
    /// 取 2 而不是全开：编译一个内置包要同驻内存「源 YAML + 解析出的词条数组 + 二进制缓存」
    /// 三份（雾凇那套实测上百兆），三个同时跑在手机上会把内存顶到告警线；
    /// 而键盘扩展进程与主 App 共存在同一台设备上，也得给它的词库 mmap 留页。
    /// 两路已能吃满多核收益的绝大部分，第三包只需等一个很短的尾巴。
    private static let bundledInstallConcurrency = 2

    /// 补装缺失的内置方案：未安装且不在 deletedSet 的 .bundle 全部直接装进 packages/。
    /// 首次安装（installedIds 为空）时等价于「装全所有内置方案」，与原 installAllBundled 行为一致。
    ///
    /// 同时承担内置方案的版本升级：已安装但 App Bundle 里的 manifest.yaml 版本
    /// 与已安装 manifest.json 版本不一致时重装 ——
    /// 否则改过词库的内置方案（如快码放开 i/u/v）永远到不了老安装。
    /// 只升内置来源的包（source.json bundled=true），用户自己导入的同 id 方案不动。
    /// 用户数据（自造词 / 预测库 / 设置）都在 App Group 根目录、不在包目录内，overwrite 重装不会丢。
    ///
    /// 为什么不从 zip 装：以前这里是「先把 .bundle 打包成 zip，再解压回临时目录编译」，
    /// 而源本就是一个可读的目录 —— 那趟 Deflate + 解压既不产出任何新信息，又坐在用户第一次
    /// 打开 App 的等待路径上（三个包共 20MB 出头，实测白等两三秒）。现在直接编目录，
    /// zip 副本改到后台补。
    ///
    /// zip 为什么补得起：schemes/ 里那份是「编译纪元落后时从原始词库重编」的唯一来源
    /// （见 recompileOutdatedSchemes），但本轮已从 .bundle 目录编好了，打包不在关键路径上。
    /// 打包失败或 App 中途被杀也不影响使用：下次启动 syncSchemesStore 第 1 步会发现
    /// 「packages 有、schemes 无 zip」并按内置方案重新补打。
    private nonisolated func installMissingBundled(installedIds: [String]) async {
        // 引擎副作用回主线程：打字查询只跑主线程，卸载动作也必须在主线程改字典
        let engine = candidateEngine
        let installed = Set(installedIds)
        let deleted = Self.deletedBundledIDs()
        guard let bundledDir = Bundle.main.url(forResource: "BundledSchemes", withExtension: nil),
              let items = try? FileManager.default.contentsOfDirectory(
                at: bundledDir, includingPropertiesForKeys: [.isDirectoryKey])
        else { return }

        // 先把「该不该装」算完（读两个 manifest 的微秒级活），再把编译这一段并行起来
        var work: [(bundleURL: URL, id: String)] = []
        for bundleURL in items where bundleURL.pathExtension == "bundle" {
            guard let id = Self.manifestField(ofBundle: bundleURL, key: "id"),
                  !deleted.contains(id) else { continue }
            let bundledVersion = Self.manifestField(ofBundle: bundleURL, key: "version")
            if installed.contains(id) {
                // 已安装：仅当「内置来源 + 双方版本都读得到 + 版本不一致」才升级重装
                guard isBundledScheme(id: id),
                      let newVersion = bundledVersion,
                      let oldVersion = container.installedSchemeVersion(id: id),
                      newVersion != oldVersion else { continue }
            }
            work.append((bundleURL, id))
        }
        guard !work.isEmpty else { return }

        let installer = self.installer
        var reloadedIds: [String] = []
        var cursor = 0
        while cursor < work.count {
            // 分波提交：TaskGroup 本身不限并发，上限靠「一波最多几路、等完再开下一波」保证
            let upper = Swift.min(cursor + Self.bundledInstallConcurrency, work.count)
            let batch = Array(work[cursor..<upper])
            cursor = upper
            await withTaskGroup(of: (id: String, ok: Bool).self) { group in
                for item in batch {
                    group.addTask {
                        // 失败只记一笔就跳过：旧库再差也比没有强（与重编那一段同口径）
                        let result = try? await installer.installDir(item.bundleURL,
                                                                     overwrite: true,
                                                                     isBundled: true)
                        return (item.id, result != nil)
                    }
                }
                for await outcome in group {
                    guard outcome.ok else { continue }
                    reloadedIds.append(outcome.id)
                }
            }
        }
        // 换掉了 dict.bin，把还 mmap 着旧文件的 reader 丢掉，下次查询自然读新的
        await MainActor.run {
            for id in reloadedIds { engine.unloadScheme(id: id) }
        }

        // 后台补 zip 副本（不阻塞启动）：打包是纯文件活，不碰引擎状态
        let zipWork = work.filter { reloadedIds.contains($0.id) }
        let schemesDir = container.schemesStoreURL
        let fm = FileManager.default
        Task.detached(priority: .background) {
            for item in zipWork {
                let zipName = item.bundleURL.deletingPathExtension().lastPathComponent + ".zip"
                let destZip = schemesDir.appendingPathComponent(zipName)
                if fm.fileExists(atPath: destZip.path) {
                    try? fm.removeItem(at: destZip)
                }
                try? fm.zipItem(at: item.bundleURL, to: destZip, shouldKeepParent: false)
            }
        }
    }

    /// .bundle 目录里 manifest.yaml 的标量字段（id / version 等；读不到就返回 nil）
    private nonisolated static func manifestField(ofBundle bundleURL: URL, key: String) -> String? {
        let manifestURL = bundleURL.appendingPathComponent("manifest.yaml")
        guard let content = try? String(contentsOf: manifestURL, encoding: .utf8) else { return nil }
        let prefix = key + ":"
        return content.components(separatedBy: .newlines).compactMap { line -> String? in
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix(prefix) else { return nil }
            return String(t.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        }.first
    }

    // MARK: - 内置方案删除记录（deletedSet）
    // 内置方案随 App Bundle 走，syncSchemesStore 看到「没装」就会补装；用户主动删掉
    // 某个内置方案（释放存储）后必须记一笔，否则下次启动又装回来、永远删不掉。
    // 记录放 App Group UserDefaults 而不是 settings.json：它是安装层的事实，
    // 不该混进用户可导出/备份的设置里。
    private static let deletedBundledKey = "com.openime.deletedBundledSchemes"

    nonisolated private static var deletedDefaults: UserDefaults {
        UserDefaults(suiteName: AppGroupContainer.groupID) ?? .standard
    }

    /// 被用户删除过、不该再自动补装的内置方案 id
    public nonisolated static func deletedBundledIDs() -> Set<String> {
        Set(deletedDefaults.stringArray(forKey: deletedBundledKey) ?? [])
    }

    private static func markBundledDeleted(_ id: String) {
        var set = deletedBundledIDs()
        set.insert(id)
        deletedDefaults.set(set.sorted(), forKey: deletedBundledKey)
    }

    /// 内置方案被重新安装成功后撤销删除记录（当前没有这条路径，留着给将来的「恢复内置方案」入口）
    public static func clearBundledDeleted(_ id: String) {
        var set = deletedBundledIDs()
        set.remove(id)
        deletedDefaults.set(set.sorted(), forKey: deletedBundledKey)
    }

    // 打字测试用：与真实键盘走相同路径，不影响输入缓冲区
    // 混打生效时走 MixInputEngine，否则查指定 schemeId
    public func queryCandidates(input: String, schemeId: String, limit: Int = 20) -> [MixCandidate] {
        guard !input.isEmpty, !schemeId.isEmpty else { return [] }
        if mixActive {
            return mixEngine.query(
                input: input,
                primarySchemeId: schemeId,
                mixConfigs: effectiveMixConfigs
            )
        } else {
            return candidateEngine.query(input: input, schemeId: schemeId, limit: limit)
                .map { MixCandidate(candidate: $0, colorHex: nil) }
        }
    }

    // MARK: - 反查与码元提示（只读，不进候选链路）

    // 当前方案的侧车索引路径，没有这个文件时查询自然返回空
    private func extrasURL(forSchemeId id: String) -> URL {
        container.packageURL(for: id).appendingPathComponent("dict.extras.bin")
    }

    private var activeExtrasURL: URL { extrasURL(forSchemeId: settings.activeSchemeId) }

    // 编码查读音。属于用户触发的低频查询，用完即释放、不长期持有，符合小内存原则
    public func reverseLookup(code: String) -> [String] {
        ExtrasIndex(sidecar: activeExtrasURL).reverseLookup(code: code)
    }

    // 字根查键位和码元，形码逐键提示用
    public func elementHint(root: String) -> (key: String, element: String)? {
        ExtrasIndex(sidecar: activeExtrasURL).elementHint(root: root)
    }

    // MARK: - 方案画像与简拼侧车（击键路径上的只读缓存）

    /// 方案画像缓存：画像是纯计算的值类型，一个方案算一次就够，装卸方案时整体失效
    private var profileCache: [String: SchemeProfile] = [:]

    /// 简拼侧车存在性：探测一次记下来，之后每键都是查字典，没有侧车的方案彻底零成本
    private var abbreviationAvailable: [String: Bool] = [:]

    /// 当前方案的侧车索引，只留一份：简拼在击键路径上每键都要查，
    /// 每键重新构造等于每键把整个侧车重读一遍；换方案 / 重装方案时丢弃，
    /// 内存占用上界就是一份侧车，不会随方案数量累积
    private var abbreviationIndex: (schemeId: String, index: ExtrasIndex)?

    /// 当前方案的画像；id 为空或方案还没加载完时返回 nil，各层据此退回改动前的行为
    private func profile(forSchemeId id: String) -> SchemeProfile? {
        guard !id.isEmpty else { return nil }
        if let cached = profileCache[id] { return cached }
        guard let scheme = installedSchemes.first(where: { $0.id == id }) else { return nil }
        let profile = SchemeProfile(scheme: scheme)
        profileCache[id] = profile
        return profile
    }

    /// 形码 / 音形码候选的「剩余整码」：整码去掉已输入前缀后剩下的尾巴。
    /// 例：输入 jaf、候选「今天」整码 jafm，返回 "m"，键面渲染成「今天m」提示还差哪几键。
    /// 非形码方案、整码已打完、或整码不以当前输入开头时返回空串（不显示）。
    public func remainingCode(for candidate: Candidate, input: String) -> String {
        guard !input.isEmpty,
              let schemeProfile = profile(forSchemeId: candidate.sourceSchemeId),
              schemeProfile.isShape || schemeProfile.isPhonoShape,
              candidate.code.hasPrefix(input),
              candidate.code.count > input.count else { return "" }
        return String(candidate.code.dropFirst(input.count))
    }

    /// 简拼侧车查询闭包；没有侧车时返回 nil，调用方整条简拼路跳过
    private func abbreviationLookup(schemeId id: String) -> ((String, Int) -> [(word: String, freq: Int)])? {
        guard !id.isEmpty else { return nil }
        if abbreviationAvailable[id] == nil {
            abbreviationAvailable[id] = FileManager.default.fileExists(atPath: extrasURL(forSchemeId: id).path)
        }
        guard abbreviationAvailable[id] == true else { return nil }
        if abbreviationIndex?.schemeId != id {
            let index = ExtrasIndex(sidecar: extrasURL(forSchemeId: id))
            // 文件在但三个区都空：同样当没有侧车，别每键白构造一次
            guard !index.isEmpty else {
                abbreviationAvailable[id] = false
                abbreviationIndex = nil
                return nil
            }
            abbreviationIndex = (id, index)
        }
        guard let index = abbreviationIndex?.index else { return nil }
        return { prefix, limit in index.abbreviations(prefix: prefix, limit: limit) }
    }

    /// 装卸方案后整体失效：画像与侧车都必须跟着磁盘上的新产物走
    private func invalidateSchemeCaches() {
        profileCache.removeAll()
        abbreviationAvailable.removeAll()
        abbreviationIndex = nil
        // reader 换代：旧词图 merged 基于旧词库，一律作废（键不含 reader 世代，整表清最安全）
        clearLatticeCache()
    }

    // MARK: - 方案能力（键盘形态可用性 / 混打合法性）
    //
    // 判定规则只有一份，在 SchemeCapability 里；这里只负责把「当前方案的画像」凑成输入。
    // UI（快捷面板列哪几种键盘、混打页给不给开关）与运行时（非法混打不生效、
    // 形态不合法自动回落）问的都是这几个属性，不再各自判一遍方案类型。

    /// 当前输入链：主方案 + 按策略真正生效的混打参与方案
    ///
    /// 链用于混打候选合并（主方案与参与方同时出候选），
    /// 但键盘形态可用性只看主方案，参与方不扩展形态
    public var activeChain: SchemeChain {
        let primary = profile(forSchemeId: settings.activeSchemeId)
        let participants = effectiveMixConfigs.compactMap { profile(forSchemeId: $0.id) }
        return SchemeChain(profiles: (primary.map { [$0] } ?? []) + participants)
    }

    /// 当前主方案撑得起的键盘形态（UI 据此灰显不可用项，运行时据此回收不合法的历史选择）
    public var availableKeyboardModes: [KeyboardMode] {
        SchemeCapability.availableKeyboardModes(chain: activeChain)
    }

    /// 当前形态在这个方案下是不是恒等直通（键盘侧据此决定无候选时空格是原样上屏还是丢弃）
    public var isIdentityDecoding: Bool {
        InputCodeExpander.isIdentityDecoding(mode: inputMode,
                                            profile: profile(forSchemeId: settings.activeSchemeId))
    }

    /// 按能力策略过滤后的混打配置：主方案不是纯形码时判空，参与方案只留全拼词库
    ///
    /// 这是运行时兜底 —— 旧 settings.json 里存着的非法组合不会生效，
    /// 也不必主动改写用户的磁盘配置（想清洗得等他自己打开混打设置页）
    private var effectiveMixConfigs: [MixSchemeConfig] {
        guard settings.mixInputEnabled, !settings.mixInputSchemes.isEmpty else { return [] }
        return SchemeCapability.effectiveMixConfigs(
            settings.mixInputSchemes,
            primary: profile(forSchemeId: settings.activeSchemeId),
            profileOf: { profile(forSchemeId: $0) })
    }

    /// 混打是否真的生效：策略过滤后还剩参与方案才算
    /// —— 「勾了开关但组合非法」等同于没开混打，满码连打等单方案行为照常生效
    private var mixActive: Bool { !effectiveMixConfigs.isEmpty }

    /// 键盘形态与当前方案对账：形态不被方案链撑起来就回落 26 键。
    ///
    /// 形态是全局持久化的，切方案时没人管就会把用户留在死胡同里
    /// （虎码 + 双拼：敲什么都是空候选）。store 的 setter 自带去重与变更通知，
    /// 形态合法时这里一个字节都不写，所以放进高频的 reloadSettings 也没有成本
    private func reconcileKeyboardMode() {
        // 链为空说明方案还没加载完（或一个都没装），此时没有判定依据，不动用户的选择
        guard !activeChain.isEmpty else { return }
        let mode = KeyboardModeStore.shared.mode
        let reconciled = Self.reconciledKeyboardMode(current: mode, chain: activeChain)
        guard reconciled != mode else { return }
        KeyboardModeStore.shared.mode = reconciled
        setInputMode(reconciled)
    }

    /// 形态回落的纯决策（单测锁定）：当前形态被方案链撑起来就原样保留，撑不起就回落 26 键。
    /// 链为空时没有判定依据，保留用户的历史选择（与 `reconcileKeyboardMode` 的前置 guard 同口径）。
    /// 典型场景：用户在拼音方案下选了双拼，切到虎码（形码，只有 26 键）后，双拼敲什么都是空候选，
    /// 必须自动回落 26 键，不能把用户留在死胡同里。
    static nonisolated func reconciledKeyboardMode(current: KeyboardMode, chain: SchemeChain) -> KeyboardMode {
        guard !chain.isEmpty else { return current }
        return SchemeCapability.supportsKeyboardMode(current, chain: chain) ? current : .pinyin26
    }

    /// 简拼第二路：把侧车查到的词追加到精确路候选之后
    ///
    /// 追加而不是替换 —— 精确音节展开（nihao ⇒ 你好）永远排在简拼（nh ⇒ 你好 / 年会 / …）
    /// 前面，简拼只是精确路之外的补充；同一个词在精确路里已经出现就不再重复一遍，
    /// 总条数仍受同一个 `limit` 约束，候选栏不会因此变长。
    /// - Parameter code: 本次输入的编码，写进候选的 code 供注释行 / 反查显示
    static nonisolated func appendAbbreviations(_ base: [MixCandidate],
                                                hits: [(word: String, freq: Int)],
                                                schemeId: String,
                                                code: String,
                                                limit: Int = candidateLimit) -> [MixCandidate] {
        guard !hits.isEmpty else { return base }
        var results = base
        var seen = Set(base.map { $0.text })
        // 侧车在编译期已按词频降序写好，这里保持原序，不再重排
        for hit in hits {
            guard results.count < limit, seen.insert(hit.word).inserted else { continue }
            let candidate = Candidate(text: hit.word, code: code, annotation: nil,
                                      freq: hit.freq, sourceSchemeId: schemeId)
            results.append(MixCandidate(candidate: candidate, colorHex: nil))
        }
        return results
    }

    // MARK: - 输入处理

    /// 追加字符到输入缓冲区
    /// - Parameter mode: 当前键盘形态。由视图显式传入，不再依赖 `setInputMode` 是否被某个
    ///   生命周期回调调用过 —— 保证「屏幕上显示的键盘」与「解析用的规则」永远是同一个值。
    public func appendInput(_ char: String, mode: KeyboardMode? = nil) {
        let activeMode = mode ?? inputMode
        // 满码连打（仅非混打模式生效）。码长由谁说了算：用户设置优先，其次是显式关闭开关，
        // 都没有才用方案自己写的规则。虎码的 schema 写了 auto_select + max_code_length 4，
        // 装进来就该满 4 码即打即上；但用户改了设置必须立即生效，画像不能反过来盖掉用户的选择。
        // 画像取不到时（方案还没加载完）退回只看用户设置，与改动前的行为一致。
        // i+拼音反查串不参与自动上屏：它不是主方案整码，满码顶字会把反查首选（如 ichu 的「出」）
        // 错误顶上屏，把反查输入拦腰截断
        let reverseActive = isReversePinyinInput(inputBuffer, primarySchemeId: settings.activeSchemeId)
        let autoLen = Self.effectiveAutoCommitLength(mixActive: mixActive,
                                                     reverseActive: reverseActive,
                                                     resolved: resolvedAutoSelectLength())
        // 顶字兜底：追加前判断，避免新字符污染候选。已满码长但首选不是整码精确匹配的串
        //（如 3 码字带出下一字第 1 键），沿用「下一键顶出首选」的老语义。
        // 这里故意不查重码：顶功的语义就是「你要继续打，上一串就当你认了」，
        // 一旦也要求唯一，连打会在每个重码处停下来等选词，反而把老手感打断。
        if let autoLen,
           inputBuffer.count >= autoLen,
           let first = candidates.first {
            commitAutoSelect(first.text)
        }
        inputBuffer.append(char)
        refreshCandidates(mode: activeMode)
        // 满码即上：敲满 N 码、首选整码精确命中、而且这条码没有重码，才立即上屏清屏。
        // 对齐外部格式的 auto_select_unique_candidate（无重码才自动上屏），而不是 auto_select
        //（打满就吞首选）：超强快码与虎码的重码不是边缘情况 —— 实测 4 码码位里
        // 快码 15.1%（13448/89044）、虎码 32.5%（20032/61598）有第二条候选，
        // 盲上等于每三五个字就替用户在重码里猜一次第一名，猜完立即清屏连反悔窗口都不留；
        // 而这份重码在原版是靠选重键兜的，这里没有那两颗键，就更不能只继承「盲上」那一半。
        // 重码时编码留在栏上：用户点候选格 / 展开面板选第二个，空格仍选首；
        // 没在意继续打字，则由上面的顶字兜底把首选顶上屏，只晚一个键，连打手感不变。
        // 判据只数「整码精确命中这条码的候选」，绝不能拿 candidates.count 当重码数：
        // 列表里还混着补全出来的长码候选（打 nihao 会带出「你好吗」），
        // 按总条数判会把几乎每次满码都误判成重码，连打直接退化。
        // 计数走候选列表而不回查词库：精确命中的条目本就排在最前（QueryStrategy 的整码精确优先），
        // 候选上限 300 也远大于两份形码码表实测的单码最大候选数（快码 44 / 虎码 43），不会被截断漏判。
        // 扫描放在「已满码长」判定之后：拼音用户（autoLen 为 nil）和没满码的前几键都不付这个成本。
        if let autoLen, inputBuffer.count >= autoLen {
            let exactMatchCount = candidates.reduce(into: 0) { count, mixCand in
                if mixCand.candidate.code == inputBuffer { count += 1 }
            }
            if Self.shouldCommitOnFullCode(buffer: inputBuffer,
                                           firstCandidateCode: candidates.first?.candidate.code,
                                           exactMatchCount: exactMatchCount,
                                           autoLen: autoLen),
               let first = candidates.first {
                commitAutoSelect(first.text)
            }
        }
    }

    /// 满码即上的判定（纯函数，单测锁定）：已满码长、首选的编码与输入完全相等，
    /// 且整码精确命中的候选不超过一条（exactMatchCount <= 1）。
    /// 相等才上：输入串只是某些长词的前缀时，首选是「猜」出来的，自动上屏会错得很隐蔽；
    /// 有重码也不上：那是同一串码要用户自己定夺，替系统选一个就是把猜的当用户要的。
    static nonisolated func shouldCommitOnFullCode(buffer: String,
                                                   firstCandidateCode: String?,
                                                   exactMatchCount: Int,
                                                   autoLen: Int) -> Bool {
        guard buffer.count >= autoLen,
              let code = firstCandidateCode, !code.isEmpty else { return false }
        return code == buffer && exactMatchCount <= 1
    }

    /// 本次击键真正生效的满码即上码长（纯函数，单测锁定）。
    /// 混打与「i+拼音」反查串都必须豁免满码即上：这两种模式下输入串不是主方案整码，
    /// 满码顶字会把混打/反查的首选错误顶上屏，把用户的连续输入拦腰截断。
    /// 只有两者都不激活时，才把用户设置/方案规则解析出的码长原样放行。
    static nonisolated func effectiveAutoCommitLength(mixActive: Bool,
                                                      reverseActive: Bool,
                                                      resolved: Int?) -> Int? {
        (mixActive || reverseActive) ? nil : resolved
    }

    /// 本次击键生效的自动上屏码长：nil 表示不自动上屏（混打模式 / 用户显式关闭 / 方案没声明且用户没填）
    private func resolvedAutoSelectLength() -> Int? {
        let cfg = settings.schemeConfigs[settings.activeSchemeId]
        if let len = profile(forSchemeId: settings.activeSchemeId)?
            .autoSelectLength(userSetting: cfg?.autoSelectLength, enabled: cfg?.autoSelectEnabled) {
            return len
        }
        // 画像取不到时退回只看用户设置，显式关闭的开关仍然优先
        return cfg?.autoSelectEnabled == false ? nil : cfg?.autoSelectLength
    }

    /// 自动上屏（满码即上与顶字兜底共用）：清屏并通知宿主键盘插入文本。
    /// auto_clear: manual（外部格式里唯一不清屏的取值）现在也照样清屏：
    /// 「留着编码继续打」得分清空码与有码两种状态，OpenIME 还没有这个状态机，
    /// 半吊子地留着会让下一键立即再顶一次同一个词
    private func commitAutoSelect(_ text: String) {
        clearInput()
        NotificationCenter.default.post(
            name: .imeAutoSelectFired,
            object: nil,
            userInfo: ["text": text]
        )
    }

    /// 删除最后一个输入字符
    public func deleteLastInput(mode: KeyboardMode? = nil) {
        guard !inputBuffer.isEmpty else { return }
        inputBuffer.removeLast()
        // isShrink：退格是「串变短」，与前进打字的语义相反 —— 见 refreshCandidates 里对占位候选的处理
        refreshCandidates(mode: mode ?? inputMode, isShrink: true)
    }

    /// 清空输入缓冲区（上屏后调用）
    public func clearInput() {
        // 输入结束：撤销挂起中的防抖词图，别让它 120ms 后对着已清空的串白算一场
        cancelPendingLattice()
        inputBuffer = ""
        candidates = []
        inlineInput = ""
        // 缓冲会话结束（上屏 / 切方案 / 键盘收起）：词图缓存的生命周期就是一个未上屏串的编辑期，
        // 此处整表清掉 —— 既杜绝陈旧 merged 跨会话复活，也把内存压回零（稳态远低于容量上限的关键）
        clearLatticeCache()
    }

    // MARK: - 键盘形态切换（小鹤双拼模块入口）

    /// 切换输入编码形态，并丢弃未上屏的编码
    public func setInputMode(_ mode: KeyboardMode) {
        guard mode != inputMode else { return }
        inputMode = mode
        clearInput()
        // 通知宿主输入框清掉内嵌编码
        NotificationCenter.default.post(name: .imeInputBufferChanged, object: nil)
    }

    /// 上屏候选（选词）
    /// - Parameter explicit: 是否是用户「主动点选某个候选」。默认 true；空格 / 打标点等
    ///   把首候选当编码收尾自动带上屏的场合传 false —— 调频只学主动选择，不学自动吞首候选，
    ///   免得把「恰好排第一」的词自我加固成回音室（方案 B）。预测关联不受此影响。
    public func selectCandidate(_ candidate: MixCandidate, explicit: Bool = true) -> String {
        let text = candidate.text
        // emoji 变体上屏时，返回的是整串「词 + emoji」（照原样插入输入框），
        // 但预测 / 上下文关联要学的是不带 emoji 的原词（emojiBase）——整串 emoji 几乎不会
        // 作为下一词的上下文重现，拿它当学习信号只会污染词对表；非 emoji 候选 emojiBase 为 nil，回落 text
        let contextText = candidate.candidate.emojiBase ?? text
        // 记录预测关联（仅在开启预测且有上一个词时记录）—— 空格上屏对预测仍是有效学习信号，两轴分开
        if settings.showPrediction {
            predictionEngine.record(prev: lastCommittedText, current: contextText)
        }
        // 拼音动态调频：只学「用户主动点选候选」，空格 / 标点自动吞首候选不记（方案 B）。
        // 记数对象放宽为「音码词库候选 或 自定义词」：自定义词（sourceSchemeId 为空）
        // 无论当前是音码 / 形码 / 混打 / 反查，点选都要累加 count 驱动其位次上升（第5位起、封顶第2位）。
        // 音码词库候选维持原门控（形码一对一无需调频）；预测候选不记（两轴分开）。
        if explicit, settings.dynamicFreqEnabled,
           !candidate.code.isEmpty, !candidate.candidate.isPrediction {
            let isCustomWord = candidate.candidate.sourceSchemeId.isEmpty
            let isPhoneticDict = profile(forSchemeId: settings.activeSchemeId)?.codeSystem == .phonetic
            if isCustomWord || isPhoneticDict {
                frequencyEngine.record(code: candidate.code, text: text)
            }
        }
        lastCommittedText = contextText
        clearInput()
        return text
    }

    /// 字符上屏：把输入框里显示的那串字符原样上屏（不记录预测）
    /// - 26 键全拼：就是输入码本身（与原行为一致）
    /// - 小鹤双拼：上屏展开还原后的拼音（nihc 对应 nihao），
    ///   而不是双拼码 —— 用户在输入框里看到的就是这串拼音
    public func commitRawInput() -> String {
        let text = inlineInput.isEmpty ? inputBuffer : inlineInput
        // 原始上屏重置上下文，下一次不做预测关联
        lastCommittedText = ""
        clearInput()
        return text
    }

    // MARK: - 手动组句状态机
    //
    // 长串自动词图只给「它认为最好」的整句，用户想要自己定夺「由哪些字 / 词组成」时无从下手。
    // 组句面板把选择权交回用户：进入时快照当前展开查询码为待组整串，逐段列出开头这一段能切的词
    // （复用 C1 的 CandidateEngine.leadingOptions，与词图同源），用户点一段就消费对应的码长并接到句尾，
    // 全部码组完后「完成」——学习整句（learnPhrase）+ 上屏 + 清空。拼音 / 形码 / 音形码通用（三套分段器）。
    // 组句期间与常规候选刷新链路隔离：不走 refreshCandidates，冻结后台词图，避免结果盖掉面板。

    /// 组句态：非 nil 表示正在组句面板里。fullCode 是进入时快照的展开查询码
    /// （与 reader.queryExact / CustomWord.code 同码空间，双拼时是还原后的全拼而非键面双拼码），
    /// consumedEnd 指向已消费到的字符下标，composedText 累积已选字词，pickedSpans 供撤销回退。
    private struct CompositionState {
        let fullCode: String
        let schemeId: String
        var composedText: String
        var consumedEnd: Int
        var pickedSpans: [(text: String, len: Int)]
    }
    private var compositionState: CompositionState?

    /// 是否处于组句态（供 UI 判断显示组句面板）。@Published 的替代：面板开合由视图侧 @State 驱动，
    /// 这里只提供只读查询，避免组句态每步变动都广播整个 runtime 的 objectWillChange。
    public var isComposing: Bool { compositionState != nil }

    /// 组句预览：已组好的句子 + 剩余未消费的编码（面板顶部显示）。非组句态返回空。
    public var compositionPreview: (composed: String, remainingCode: String) {
        guard let s = compositionState else { return ("", "") }
        return (s.composedText, String(s.fullCode.dropFirst(s.consumedEnd)))
    }

    /// 整串码是否已全部组完：只有组完（consumedEnd==fullCode.count）「完成」才有效 ——
    /// 学到的 CustomWord.code 必须等于整串码，用户重打同一串码时 mergeExtras 的 hasPrefix 才命中。
    /// 学到的词不强制置顶：与其它自定义词一样走位次调频（第5位起、点选升频封顶第2位）。
    public var canFinishComposition: Bool {
        guard let s = compositionState else { return false }
        return s.consumedEnd == s.fullCode.count && !s.composedText.isEmpty
    }

    /// 用指定方案的画像展开一串输入、取展开查询码首条（组句待组整串用）。
    /// donor 路（反查 / 混打借来的音码方案）传 `.pinyin26`：借来的那串一定是全拼，
    /// 恒等展开即规范化全拼码，与 `reversePinyinCandidates` / `mixEngine.query` 查询同一码空间。
    /// 展开不出查询码（空串）返回 nil，调用方据此不进入组句。
    private func expandCode(_ input: String, schemeId: String, mode: KeyboardMode) -> String? {
        let profile = profile(forSchemeId: schemeId)
        let expansion = InputCodeExpander.expansion(
            input, mode: mode, profile: profile,
            abbreviations: profile?.isPhonetic == true ? abbreviationLookup(schemeId: schemeId) : nil)
        guard let code = expansion.codes.first, !code.isEmpty else { return nil }
        return code
    }

    /// 组句应落到哪个方案、哪串码：混打拼音 / i+拼音反查时借用的音码方案按拼音分段，
    /// 常规时维持当前主方案。返回 nil 表示无法展开出查询码（调用方不进入组句）。
    /// - 反查路（快码 i+拼音）：剥掉引导符，用借用的音码方案按全拼展开。
    /// - 混打路（虎码开混打打拼音）：主方案是纯形码、整串是合法拼音前缀时，
    ///   用参与混打的音码方案展开；主方案本身是音码时走常规路（无需借道）。
    /// - 常规路：用当前主方案按当前键盘形态展开。
    private func compositionTarget(mode: KeyboardMode) -> (schemeId: String, code: String)? {
        let activeId = settings.activeSchemeId
        guard !activeId.isEmpty else { return nil }
        // 反查路：i 是引导符、其后是合法拼音前缀，借音码方案展开（快码打 ini… 组句）
        if isReversePinyinInput(inputBuffer, primarySchemeId: activeId),
           let guide = profile(forSchemeId: activeId)?.effectiveReverseLookupGuide,
           let donor = phoneticDonorSchemeId(excluding: activeId) {
            let pinyin = String(inputBuffer.dropFirst(guide.count))
            if let code = expandCode(pinyin, schemeId: donor, mode: .pinyin26) {
                return (donor, code)
            }
        }
        // 混打路：主方案是纯形码（自己不会按音节切拼音）、整串是合法拼音前缀时借音码参与方案
        if mixActive, profile(forSchemeId: activeId)?.isShape == true,
           PinyinSyllables.isValidPinyinPrefix(inputBuffer) {
            let donor = effectiveMixConfigs.first(where: {
                $0.isEnabled && $0.id != activeId
                    && profile(forSchemeId: $0.id)?.codeSystem == .phonetic
            })?.id ?? phoneticDonorSchemeId(excluding: activeId)
            if let donor, let code = expandCode(inputBuffer, schemeId: donor, mode: .pinyin26) {
                return (donor, code)
            }
        }
        // 常规路：当前主方案 + 当前键盘形态（音码方案可能需双拼还原，故用真实 mode）
        if let code = expandCode(inputBuffer, schemeId: activeId, mode: mode) {
            return (activeId, code)
        }
        return nil
    }

    /// 进入组句：快照当前展开查询码作为待组整串。返回是否成功进入
    /// （非组句态、有输入、有激活方案、能展开出查询码才进入）。
    /// 混打 / 反查时经 `compositionTarget` 路由到借用的音码方案按拼音分段，其余用当前主方案。
    @discardableResult
    public func enterComposition(mode: KeyboardMode? = nil) -> Bool {
        guard compositionState == nil, !inputBuffer.isEmpty else { return false }
        guard let target = compositionTarget(mode: mode ?? inputMode) else { return false }
        // 组句期间冻结后台词图：撤销挂起中的防抖任务，别让它算完回来盖掉面板状态
        cancelPendingLattice()
        compositionState = CompositionState(fullCode: target.code, schemeId: target.schemeId,
                                            composedText: "", consumedEnd: 0, pickedSpans: [])
        return true
    }

    /// 退出组句（取消）：非破坏性 —— 丢弃组句中间态，inputBuffer 与常规候选原样保留，
    /// 面板收起后回到进入前的候选栏（不清空、不上屏）。
    public func exitComposition() {
        guard compositionState != nil else { return }
        compositionState = nil
    }

    /// 当前剩余码开头一段的可选词（面板中部列表）。剩余码铺完 / 非组句态返回空。
    /// 返回的 end 是相对剩余码起点的终点，选词时作为 spanLen 回传给 pickCompositionWord。
    public func compositionOptions() -> [(end: Int, words: [CodeLattice.Word])] {
        guard let s = compositionState, s.consumedEnd < s.fullCode.count else { return [] }
        let remaining = String(s.fullCode.dropFirst(s.consumedEnd))
        return candidateEngine.leadingOptions(input: remaining, schemeId: s.schemeId)
    }

    /// 选一段词：接到已组句子末尾，消费对应的码长，入撤销栈。
    /// - Parameters:
    ///   - text: 用户挑中的词
    ///   - spanLen: 这段词消费的编码字符数（= 选项的 end，相对剩余码起点）
    public func pickCompositionWord(text: String, spanLen: Int) {
        guard var s = compositionState, spanLen >= 1,
              s.consumedEnd + spanLen <= s.fullCode.count else { return }
        s.composedText += text
        s.consumedEnd += spanLen
        s.pickedSpans.append((text: text, len: spanLen))
        compositionState = s
    }

    /// 撤销一段：弹出最后选的那段，回退已组句子与消费位置。无可选段时不动。
    public func undoComposition() {
        guard var s = compositionState, let last = s.pickedSpans.popLast() else { return }
        s.consumedEnd -= last.len
        s.composedText = String(s.composedText.dropLast(last.text.count))
        compositionState = s
    }

    /// 完成组句：学习整句（learnPhrase）→ 退出组句 → 清输入。返回上屏文本。
    /// 仅当整串码全部组完（canFinishComposition）才有效，否则返回 nil、不改变任何状态 ——
    /// 学到的 code 必须是整串码，才能对上「重打同码首选出现」。上屏由调用方（键盘）拿返回值插入。
    public func finishComposition() -> String? {
        guard let s = compositionState, canFinishComposition else { return nil }
        let text = s.composedText
        let code = s.fullCode
        compositionState = nil
        learnPhrase(code: code, text: text)
        lastCommittedText = text
        clearInput()
        return text
    }

    // MARK: - 学习为自定义词（去重 + 最新置顶 + 无上限 + 立即生效 + 广播）

    /// 把一条「码 → 整句」学成自定义词：去重（同 code+text 命中先删旧）→ 新词插到数组最前（最新置顶）
    /// → 落盘（无任何条数上限，长句全存磁盘）→ 立即刷新内存候选（自定义设定立即生效铁律）
    /// → 发 Darwin 广播让主 App / 其它键盘进程重载。存法与剪贴板 append 一致（去重 + insert at 0），
    /// 唯独去掉 trim/limit。去重 + 置顶本身抽成纯函数 CustomWordStore.dedupPrepend 便于单测。
    /// 学到的词不播种调频计数、不强制置顶：新词从候选第 5 位起，用户主动点选才逐位上升（封顶第 2 位）——
    /// 形码有一简 / 二简 / 三简，长句一上来就顶掉简码字不科学，故一律走位次调频（CandidateEngine.mergeExtras）。
    private func learnPhrase(code: String, text: String) {
        guard !code.isEmpty, !text.isEmpty else { return }
        let updated = CustomWordStore.dedupPrepend(container.loadCustomWords(), code: code, text: text)
        do {
            try container.saveCustomWords(updated)
        } catch {
            return
        }
        // 立即生效：刷新内存里的自定义词表，同码再打这条整句立刻按位次调频出现在候选里（第 5 位起）
        candidateEngine.updateCustomWords(updated)
        // 跨进程广播：主 App / 其它键盘进程收到后重载自定义词（与 UserWordsView.saveAndNotify 同源）
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(AppGroupContainer.settingsChangedNotification as CFString),
            nil, nil, true
        )
    }

    // MARK: - 候选刷新

    /// 单次输入给出的候选上限（顶部候选栏）
    /// —— 26 键单码查询与小鹤双拼的多码展开共用这个值，
    ///    保证两种键盘的候选列表长度、展开面板规模完全一致。
    ///    取 300：limit 只决定入堆 / 渲染条数，不省构造成本（字母前缀查询已对全部命中构造并缓存
    ///    singleCharCache），几十到几百条内近乎免费；顶部候选栏已改 LazyHStack，每键只渲染可见的
    ///    十来格，候选总数上涨不再增加每键渲染成本。300 覆盖绝大多数常用 + 次常用字，
    ///    把「81 名以后永不出现」的截断大幅推后。真正「一个不落」的全量由展开面板的
    ///    allCandidatesForCurrentInput（绕过 ptn top-N 侧车）兜底。
    ///    注意：大前缀（命中区间 > ptnRangeThreshold）走 dict.ptn.bin 侧车，编译期预排 ptnTopN 条（现 360，
    ///    已 ≥ 本值 300），故这类前缀顶部栏也能到满 candidateLimit，不再被侧车更小上限卡住；再超出靠展开全量补齐。
    private static let candidateLimit = 300

    /// 展开面板「看全部」的全量查询上限：绕过 ptn top-N 侧车后对整个命中区间扫描。
    /// 仅低频的展开动作触发，不进击键热路径。
    ///
    /// 必须有界且不能太大：键盘扩展的内存预算很紧（真机实测 foot 冲到 67.4MB / avail 仅 9.6MB
    /// 就触发 memoryWarning → jetsam 杀进程重启）。单字母 `h` 命中 3 万条区间，若上限取 5000，
    /// 物化 5000 条带 String 的 Candidate + CandidateExpandedPanel 非懒 WrapLayout 累积渲染数千 cell，
    /// 一路滚到底就把脏内存顶穿崩溃。取 600：既覆盖单字母前缀下人能翻看的常见字 / 词
    ///（配合每批 50 的滚动加载，最多渲染 600 cell，落在键盘扩展的安全内存内），
    /// 又给「一路滚到底也不会崩」兜住总量上界 —— 单纯缩小每批格数不能防崩（总量无界），
    /// 必须在这里把总量钉死。绝大多数输入的候选都远少于 600，展开即全见、根本不触顶。
    private static let expandedCandidateLimit = 600

    /// - Parameter isShrink: 本次刷新是否由「退格使输入变短」触发。前进打字与退格对占位候选的取舍相反，
    ///   见下方 `if !runLattice || isShrink` 处的说明。
    private func refreshCandidates(mode: KeyboardMode, isShrink: Bool = false) {
        // 每键先撤销上一键挂起的防抖词图：本键若仍需词图会在末尾重新挂起（刷新防抖窗口），
        // 若本键常规查询已命中（core 非空）或输入已清空，则不会再挂，旧串的后台词图就此作废
        cancelPendingLattice()
        guard !inputBuffer.isEmpty else {
            candidates = []
            inlineInput = ""
            NotificationCenter.default.post(name: .imeInputBufferChanged, object: nil)
            return
        }

        let activeId = settings.activeSchemeId
        // 画像：方案自己的 speller 规则（认哪些键、分隔符、编译期有没有去空格）叠在键盘形态之上。
        // 方案还没加载完时为 nil，展开层退回「只按键盘形态展开」，行为与改动前逐字节一致
        let profile = profile(forSchemeId: activeId)

        // 小鹤双拼：按当前键盘形态把输入展开成全拼前缀。
        // 与外部格式的 speller/algebra 等价：双拼的双键码先还原成音节级全拼再查词库。
        // 简拼闭包只在音码方案且侧车存在时非 nil —— 形码的短码本来就是正式编码，不是简拼
        let expansion = InputCodeExpander.expansion(
            inputBuffer, mode: mode, profile: profile,
            abbreviations: profile?.isPhonetic == true ? abbreviationLookup(schemeId: activeId) : nil)
        // 内嵌编码显示还原后的拼音（26 键时就是输入码本身，与原行为一致）。
        // 注意：必须在「是否有激活方案」的判断之前赋值 —— 否则方案未就绪时输入框会把
        // 双拼码原样显示出来，看起来就像「双拼打不出拼音」。
        inlineInput = expansion.display
        // 内嵌编码就地推给宿主，不等下面查词：setMarkedText 只依赖 inlineInput / inputBuffer，
        // 二者此刻已定稿（后续 queryCode / postProcess 只改 candidates，不再动 inlineInput）。
        // 通知原本压在查词之后，而单键 queryUs 实测常见 5ms、尖峰 15~31ms（诊断 SEGMENT 行）；
        // 长串触发后台词图时更要等词图算完（dispatchLattice 落地才发）—— 编码显示被整段查询阻塞，
        // 就是用户感到的「按了字母编码不跟手」。提前到这里发，编码上屏只等展开（expandUs 数十~两百微秒），
        // 候选随后经 @Published 各自刷新；下面几处原有的 post 因 inlineInput 不再变而删除，每键仍恰好一次。
        NotificationCenter.default.post(name: .imeInputBufferChanged, object: nil)

        guard !activeId.isEmpty, !expansion.codes.isEmpty else {
            // 没有激活方案，或双拼码在 speller 里不成立（如双拼非法码）：
            // 一律清空候选，避免上一次击键的候选残留（内嵌编码已在上面 inlineInput 定稿时推给宿主）
            candidates = []
            return
        }

        // 常规查询一律关掉词图兜底：词图是 O(输入长²) 的词库扫描，绝不能在击键的主线程上
        // 同步跑（长串每敲一键常规查询都落空、都从头重算一遍词图，击键 backlog 堆在主线程
        // 就是「码一长就超级卡」的根因）。主线程只出即时候选，长串整句词图移到后台算完再并入
        let queryInput = expansion.codes[0]
        let core: [MixCandidate]
        if expansion.isIdentity {
            // 恒等直通（26 键，以及双拼方案配小鹤双拼键盘）：键面码就是词库码，单条查询
            core = queryCode(queryInput, primarySchemeId: activeId,
                             allowPartialFallback: true, allowLattice: false)
        } else {
            // 小鹤双拼键盘配全拼词库：双拼键位表一对一，还原出的读音必然只有一条，
            // 拿它查完再把「码与输入完全相等」的词条提到前面（对齐外部格式的 exact 优先）
            core = orderedGroup(queryInput,
                                queryCode(queryInput, primarySchemeId: activeId,
                                          allowPartialFallback: false, allowLattice: false))
        }
        // 常规查询是否落空：词图只在落空时才该救场（与策略内 `context.lattice?` 的触发条件一致）
        let coreEmpty = core.isEmpty
        // 常规落空且输入在词图区间内：起后台任务算长串整句词图，算完回主线程并入（防旧盖新）
        let runLattice = coreEmpty && CandidateEngine.isLatticeLength(queryInput.count)

        // 先出一版即时候选：常规查询 + 简拼 + 单字优先 + 预测，主线程零等待。
        // 例外：常规落空且本键会起后台词图（runLattice）时，不清空 candidates——保留上一版
        // 候选占位，避免候选栏 hasContent 由 true 翻成 false 触发 ScrollView 从候选分支结构性
        // 切到快捷图标分支（肉眼「先清空再上屏」的闪烁），直到 dispatchLattice 回主线程用
        // postProcess(merged) 整体替换。仅在输入真正清空 / 无词图可救时才置空。
        //
        // 退格例外（isShrink）：此时「上一版占位」是更长、已失效的整句（如从整串退到两个词，
        // 占位仍是原来那句长句），且快速退格每键都 cancelPendingLattice 取消新词图，占位会一直挂屏
        // = 用户看到的「退到两个词了候选还是那条很长的错误句子」。故退格一律整体替换（core 落空即清空），
        // 宁可瞬时空也不留错误长句；前进打字的占位防闪逻辑（!isShrink 分支）原样保留。
        // 词图缓存命中（长串退格 / 重访已算过的串）：同步拿现成 merged 走一遍 postProcess 出候选，
        // 跳过 50ms 防抖 + 后台 O(n²) 重算，直接消除「退格时候选先清空、隔一会儿才更新」的空窗；
        // 命中即无需再排后台词图。未命中才落回下面的占位 / 清空 + 防抖起算老路径
        var latticeCacheHit = false
        if runLattice, let cached = latticeCacheGet(queryInput, primarySchemeId: activeId) {
            candidates = postProcess(cached, expansion: expansion, activeId: activeId)
            latticeCacheHit = true
        }
        if !latticeCacheHit, !runLattice || isShrink {
            candidates = postProcess(core, expansion: expansion, activeId: activeId)
        }
        if runLattice, !latticeCacheHit {
            scheduleLattice(queryInput: queryInput, primarySchemeId: activeId,
                            expansion: expansion, bufferSnapshot: inputBuffer)
        }
    }

    /// 展开面板「看全部」：对当前输入做一次绕过 ptn top-N 侧车的全量查询，返回近乎完整的候选列表。
    ///
    /// 与 refreshCandidates 共用同一套展开（双拼还原 / 简拼闭包）与后处理（简拼追加 / 单字优先 / 预测），
    /// 差别只在把 limit 提到 expandedCandidateLimit 并打开 fullScan —— 顶部候选栏受 candidateLimit（现 300）
    /// 截断的冷门字（ptn 侧车 ptnTopN=360 已 ≥ 300，不再是更紧的上限），在这里补齐，做到「展开即见全部、不截断」。
    ///
    /// 只在用户点「展开」这一低频动作时调用（不在击键热路径上）：单方案常规路径的全区间扫描
    /// 移到后台队列跑（runRawScan，只读 DictReader），主线程只做毫秒级收尾（调频 / 自定义词 / 去重），
    /// 展开动画不再被主线程上的全量扫描冻住（真机实测单字母 h 同步扫 205ms）；再由 CandidateExpandedPanel
    /// 分批懒渲染，不会因候选总数上涨而卡顿。
    /// 混打 / i+拼音反查路径不支持绕过侧车（各自 merge 多方案 / 借方案查字，本就不受单一 ptn 上限约束），
    /// 退回常规 candidateLimit（已足够宽、且很便宜），沿用同步 queryCode，语义自洽。
    public func allCandidatesForCurrentInput(mode: KeyboardMode) async -> [MixCandidate] {
        guard !inputBuffer.isEmpty else { return [] }
        let activeId = settings.activeSchemeId
        let profile = profile(forSchemeId: activeId)
        let expansion = InputCodeExpander.expansion(
            inputBuffer, mode: mode, profile: profile,
            abbreviations: profile?.isPhonetic == true ? abbreviationLookup(schemeId: activeId) : nil)
        guard !activeId.isEmpty, !expansion.codes.isEmpty else { return candidates }
        let queryInput = expansion.codes[0]
        // 只有「非反查、非混打」的单方案常规路径才有那条 205ms 的 fullScan 重活，取一份后台扫描快照；
        // 反查 / 混打不支持 fullScan（退回 candidateLimit，很便宜），job 为 nil 时沿用同步 queryCode
        let job = (!isReversePinyinInput(queryInput, primarySchemeId: activeId) && !mixActive)
            ? candidateEngine.scanJob(input: queryInput, schemeId: activeId,
                                      limit: Self.expandedCandidateLimit,
                                      allowPartialFallback: expansion.isIdentity)
            : nil
        let core: [MixCandidate]
        if let job {
            // 后台纯扫描：runRawScan 只读 DictReader（缓存自带锁），与词图后台计算同源、并发安全；
            // 主线程在 await 期间不被阻塞，展开动画与占位候选照常渲染
            let raw: [Candidate] = await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(returning: CandidateEngine.runRawScan(job))
                }
            }
            // 回主线程收尾：与同步 query(fullScan) 尾部同一套 applyFrequency / mergeExtras / uniquify，产出一致
            var finalized = candidateEngine.finalizeScan(raw, input: queryInput, profile: job.profile)
                .map { MixCandidate(candidate: $0, colorHex: nil) }
            if !expansion.isIdentity { finalized = orderedGroup(queryInput, finalized) }
            core = finalized
        } else {
            let syncCore: [MixCandidate]
            if expansion.isIdentity {
                syncCore = queryCode(queryInput, primarySchemeId: activeId,
                                     allowPartialFallback: true, allowLattice: false, fullScan: true)
            } else {
                syncCore = orderedGroup(queryInput,
                                        queryCode(queryInput, primarySchemeId: activeId,
                                                  allowPartialFallback: false, allowLattice: false, fullScan: true))
            }
            core = syncCore
        }
        // 全量扫描也落空（如长串只有词图能救）：退回顶部栏已有的候选（可能已含词图整句），不硬凑空列表
        guard !core.isEmpty else { return candidates }
        let result = postProcess(core, expansion: expansion, activeId: activeId)
        return result
    }

    /// 候选后处理：简拼追加 → 单字优先 → 预测插入。
    /// 同步首屏与异步词图并入共用这一份，保证两条路径产出的候选顺序、去重、预测完全一致
    private func postProcess(_ core: [MixCandidate],
                             expansion: InputCodeExpander.Expansion,
                             activeId: String) -> [MixCandidate] {
        var results = core
        // 简拼第二路：追加在精确路之后，不抢主路的位置（形码短码不是简拼，侧车闭包本就为 nil）
        if !expansion.abbreviations.isEmpty {
            results = Self.appendAbbreviations(results, hits: expansion.abbreviations,
                                               schemeId: activeId, code: expansion.codes[0])
        }
        // 单字优先（方案级开关，默认关）：形码用户常想一个字一个字地顶，
        // 打开后单字整体提到最前，组内仍是原来的排序；关闭时这一步一个候选也不动
        if settings.schemeConfigs[activeId]?.singleCharFirst == true {
            results = CandidateScoring.singleCharFirst(results, enabled: true) { $0.text }
        }
        // 插入预测候选（开启预测且有上一个词时）
        if settings.showPrediction && !lastCommittedText.isEmpty {
            // 预测按 lastCommittedText 缓存：两次上屏之间该词的预测不变，键不变直接复用，
            // 不再每键 predict()（queue.sync 阻塞主线程）。详见 predictionCache 属性注释。
            if predictionCacheKey != lastCommittedText {
                predictionCache = Self.pickPredictionSlots(predictionEngine.predict(after: lastCommittedText))
                predictionCacheKey = lastCommittedText
            }
            // 按 position 从小到大插入：低位先插，插入点在高位之前，高位目标索引不受影响
            for pred in predictionCache {
                let alreadyExists = results.contains { $0.text == pred.text }
                guard !alreadyExists else { continue }
                // position 1-based（4=第4候选），转为 0-based 插入索引，不超出数组边界
                let insertIndex = min(pred.position - 1, results.count)
                let predCandidate = Candidate(
                    text: pred.text,
                    code: "",
                    annotation: nil,
                    freq: 0,
                    sourceSchemeId: Candidate.predictionSchemeId
                )
                results.insert(MixCandidate(candidate: predCandidate, colorHex: nil), at: insertIndex)
            }
        }
        // emoji 变体：紧跟每条命中原词追加一条「词 + emoji」（Rime simplifier@emoji_cn 同款），
        // 放在预测插入之后统一处理——映射作用于候选文字，全方案通吃；变体串本身不命中映射，不会自我递归
        if settings.showEmoji {
            results = Self.appendEmojiVariants(results)
        }
        return results
    }

    /// 给候选列表追加 emoji 变体：遍历每条候选，凡其文字在 emoji 映射表里有对应「词 + emoji」整串的，
    /// 就在它正后方插一条变体（text = 整串、code 空、sourceSchemeId = _emoji、emojiBase = 原词）。
    /// 变体沿用原词的混打配色（colorHex），视觉上与它归属同一个词。
    /// 已出现过的变体串不再重复插入；emoji 变体自身跳过（其 text 带 emoji，本就不命中映射，这里再挡一层更省心）。
    /// 纯函数、nonisolated，便于单测直接喂列表断言插入位置与去重。
    static nonisolated func appendEmojiVariants(_ base: [MixCandidate]) -> [MixCandidate] {
        var results: [MixCandidate] = []
        results.reserveCapacity(base.count * 2)
        var seen = Set<String>()
        for item in base {
            results.append(item)
            seen.insert(item.text)
            guard !item.candidate.isEmoji else { continue }
            guard let variant = EmojiTable.shared.replacement(for: item.text),
                  !seen.contains(variant) else { continue }
            let cand = Candidate(text: variant, code: "", annotation: nil, freq: 0,
                                 sourceSchemeId: Candidate.emojiSchemeId, emojiBase: item.text)
            results.append(MixCandidate(candidate: cand, colorHex: item.colorHex))
            seen.insert(variant)
        }
        return results
    }

    // MARK: - 长串词图后台异步
    //
    // 词图兜底是 O(输入长²) 的词库扫描（32 字实测约 130ms），过去同步跑在主线程上：长串每敲一键
    // 常规查询都落空、都从头重算一遍词图，击键 backlog 堆在主线程，表现为「码一长就超级卡」。
    // 现在主线程只跑常规查询即时出候选，词图整句移到后台串行队列算，算完回主线程并入。
    // 世代号 + inputBuffer 快照双重防旧盖新：用户已经继续敲键 / 清空时，过期结果直接丢弃。

    /// 词图异步的世代号（只在主线程读写）：连续击键时只有最后一次的结果落地
    private var latticeGeneration = 0

    /// 与 latticeGeneration 同步的新鲜度闸门（线程安全）：后台串行队列开算前先读它，
    /// 过期任务整段跳过、不在队列上白算 O(n²)（见 LatticeFreshnessGate 注释）
    private let latticeGate = LatticeFreshnessGate()

    /// 词图计算专用后台串行队列：串行保证同一时刻只有一段词图在算，配合世代号丢弃过期任务；
    /// 不与 reloadSettings 的 global 并发队列抢，避免重载与词图互相拖累
    private let latticeQueue = DispatchQueue(label: "com.openime.lattice", qos: .userInitiated)

    /// 词图防抖间隔：连续击键时不立即起后台词图，等用户停顿这么久才算当前串。
    ///
    /// 长串每敲一键常规查询都落空，若每键都立刻起一次 O(输入长²) 的后台词图，绝大多数算到一半就被下一键作废。
    /// 真机实测（2026-11-07，一段 64 字长拼音）：50ms 防抖下 122 次起算、每次 computeMs 100~198ms（越长越慢），
    /// 其中 58 次算完是空（merged=0）、17 次算完才判过期丢弃 —— 击键间隔实测 100~220ms 普遍大于 50ms，
    /// 等于每键（含退格）都白算一遍，后台队列被 O(n²) 占满、与主线程抢 CPU 并发热，这就是「码一长就卡」；
    /// 而主线程同步查询对长码 <1ms、根本没被堵。把防抖提到 0.15s（≈ 长串击键间隔中位数）后，连续输入期间
    /// 不再每键起算，只在用户真正停顿（要读候选 / 要选词）时算一次；词图本就是长串落空的兜底、即时候选
    /// 早已在主线程出了，晚 100ms 出现对用户无感。注意：只有「常规查询落空的长串」才会排词图，
    /// 正常短词（nihao 这类）同步就命中、根本不走这里，故提高防抖不影响日常打字。
    private static let latticeDebounceInterval: TimeInterval = 0.15

    /// 挂起中的防抖词图任务（只在主线程读写）：新击键 / 输入结束时先 cancel 它，只有停顿够久才真正起算
    private var pendingLatticeTask: Task<Void, Never>?

    /// 撤销挂起中的防抖词图任务（主线程调用）：连续击键时压掉上一键的空转，输入结束时防止对着空串白算
    private func cancelPendingLattice() {
        guard pendingLatticeTask != nil else { return }
        pendingLatticeTask?.cancel()
        pendingLatticeTask = nil
    }

    // MARK: - 词图结果 LRU 缓存
    //
    // 长串退格 / 重访已算过的串时，refreshCandidates 同步命中这里，直接拿现成的 merged 走一遍
    // postProcess 出候选，跳过「50ms 防抖 + 后台 O(输入长²) 重算」——这正是「长码退格时候选先清空、
    // 隔一会儿才更新」那段空窗的根治点。只在主线程读写（IMERuntime 是 @MainActor，与 predictionCache
    // 同一并发口径），无需加锁。

    /// 词图缓存：键 = 方案 id + 输入码，值 = dispatchLattice 算出的完整 merged（postProcess 之前）。
    /// 命中时用当前 expansion 现算 postProcess，与异步落地走同一份后处理，顺序 / 预测完全一致。
    private var latticeCache: [String: [MixCandidate]] = [:]
    /// LRU 新旧序（末尾最新）：容量满时从头淘汰最久未用。条数 ≤ latticeCacheCapacity，
    /// 命中时把键搬到末尾的 O(n) 移动在这个量级（≤100）可忽略
    private var latticeCacheOrder: [String] = []

    /// 词图缓存容量上限（具名常量，禁魔法值）。100 条足够宽裕：因 clearInput 每次上屏 / 切方案
    /// 都整表清空，缓存生命周期只覆盖「一个未上屏串的编辑期」，稳态至多持当前串的若干前缀，
    /// 远达不到上限。每条 merged 数十候选、数百字节到数 KB，满载也就几百 KB 封顶，且几乎不会满载
    private static let latticeCacheCapacity = 100

    /// 词图缓存键：方案 id + 分隔符 + 输入码。用不可见分隔符 \u{1} 拼接，避免「方案 id 尾字符 +
    /// 码首字符」相邻拼接产生歧义碰撞。配置变化（装卸方案 / 混打组合 / 键盘形态）会整表清空，
    /// 故键无需再含配置指纹 —— 同一 (方案, 输入码) 在表存活期内配置恒定，merged 必然可复现
    private func latticeCacheKey(_ queryInput: String, primarySchemeId: String) -> String {
        primarySchemeId + "\u{1}" + queryInput
    }

    /// 查缓存并刷新新旧序（主线程）：命中把键移到 LRU 末尾，返回缓存的 merged
    private func latticeCacheGet(_ queryInput: String, primarySchemeId: String) -> [MixCandidate]? {
        let key = latticeCacheKey(queryInput, primarySchemeId: primarySchemeId)
        guard let merged = latticeCache[key] else { return nil }
        if let idx = latticeCacheOrder.firstIndex(of: key) {
            latticeCacheOrder.remove(at: idx)
        }
        latticeCacheOrder.append(key)
        return merged
    }

    /// 写缓存（主线程）：新键入表并追加到 LRU 末尾，超容量从头淘汰最久未用
    private func latticeCachePut(_ queryInput: String, primarySchemeId: String, merged: [MixCandidate]) {
        let key = latticeCacheKey(queryInput, primarySchemeId: primarySchemeId)
        if latticeCache[key] != nil, let idx = latticeCacheOrder.firstIndex(of: key) {
            latticeCacheOrder.remove(at: idx)
        }
        latticeCache[key] = merged
        latticeCacheOrder.append(key)
        while latticeCacheOrder.count > Self.latticeCacheCapacity {
            latticeCache.removeValue(forKey: latticeCacheOrder.removeFirst())
        }
    }

    /// 整表清空词图缓存（上屏 / 切方案 / 装卸重载 / 内存告警）：这些时机要么缓冲会话结束、
    /// 要么 reader 或配置换代，旧 merged 一律失效，清掉既保正确也把内存压回零
    private func clearLatticeCache() {
        guard !latticeCache.isEmpty || !latticeCacheOrder.isEmpty else { return }
        latticeCache.removeAll()
        latticeCacheOrder.removeAll()
    }

    /// 常规查询落空后，防抖地把长串词图整句计算排到后台：连续击键只保留最后一次，
    /// 停顿 latticeDebounceInterval 后才真正起算，避免每键都白算一遍马上被作废的词图。
    /// 防抖等待走可取消的 Task.sleep（挂起而非阻塞主线程），与 @MainActor 隔离天然契合
    private func scheduleLattice(queryInput: String, primarySchemeId: String,
                                 expansion: InputCodeExpander.Expansion, bufferSnapshot: String) {
        // 防抖：撤销上一键挂起的词图，把本次快照重新排到 quiet 窗口之后
        cancelPendingLattice()
        let nanos = UInt64(Self.latticeDebounceInterval * 1_000_000_000)
        pendingLatticeTask = Task { @MainActor [weak self] in
            // 可被 cancel 打断的防抖等待：被撤销时 sleep 抛 CancellationError，try? 吞掉后由 isCancelled 兜住
            try? await Task.sleep(nanoseconds: nanos)
            guard let self, !Task.isCancelled else { return }
            self.pendingLatticeTask = nil
            self.dispatchLattice(queryInput: queryInput, primarySchemeId: primarySchemeId,
                                 expansion: expansion, bufferSnapshot: bufferSnapshot)
        }
    }

    /// 防抖窗口到点后真正起算：主线程捕获只读快照（reader/scheme/profile）与本次输入指纹，
    /// 丢到后台串行队列纯计算，算完回主线程并入候选（后台不碰 self 可变状态）
    private func dispatchLattice(queryInput: String, primarySchemeId: String,
                                 expansion: InputCodeExpander.Expansion, bufferSnapshot: String) {
        // 主线程捕获本次击键里所有会触发词图的方案快照（反查 / 混打 / 单方案）
        let jobs = buildLatticeJobs(queryInput: queryInput, primarySchemeId: primarySchemeId)
        guard !jobs.isEmpty else { return }
        latticeGeneration += 1
        let generation = latticeGeneration
        // 同步写进线程安全闸门：后台队列开算前先读它，过期任务整段跳过，不白算 O(n²)
        latticeGate.set(generation)
        let gate = latticeGate
        latticeQueue.async { [weak self] in
            // 开算前先确认自己仍是最新世代：连续击键会让上一串的词图任务在串行队列上排队，
            // 不先判新鲜度的话它们会各自算完再被判过期丢弃（真机日志：105 次 schedule 仅 50 次落地，
            // 31 次算完才判过期），几十段 O(n²) 计算堆成长龙把当前串的结果压在十几秒之后 —— 这就是「码一长就卡」
            guard gate.current() == generation else {
                return
            }
            // 后台：对每份快照跑纯词图计算，按捕获顺序（即合并优先级）合并、同词去重
            var merged: [MixCandidate] = []
            var seen = Set<String>()
            for (job, colorHex, annotateReader) in jobs {
                // 多方案（混打 / 反查）逐份计算之间也复查一次新鲜度，过期就整段停手
                guard gate.current() == generation else { return }
                var produced = CandidateEngine.computeLattice(job)
                // 反查路径：候选来自借用的音码方案，用主方案词库补出编码当注释（见 reversePinyinCandidates）
                if let annotateReader, !produced.isEmpty {
                    let codes = annotateReader.shortestCodes(forTexts: produced.map { $0.text })
                    produced = produced.map {
                        Candidate(text: $0.text, code: $0.code,
                                  annotation: $0.annotation ?? codes[$0.text],
                                  freq: $0.freq, sourceSchemeId: $0.sourceSchemeId)
                    }
                }
                for candidate in produced where seen.insert(candidate.text).inserted {
                    merged.append(MixCandidate(candidate: candidate, colorHex: colorHex))
                }
            }
            guard !merged.isEmpty else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                // 写入词图缓存：merged 是 (queryInput, primarySchemeId) 在当前配置下的完整词图结果，
                // 配置一变就整表清空，故键只需 方案 + 输入码。放在防旧盖新之前：即便本次结果因用户
                // 又敲了键 / 缓冲区已变而作废不上屏，它对该输入码仍是正确答案，值得缓存供重访 / 退格命中
                self.latticeCachePut(queryInput, primarySchemeId: primarySchemeId, merged: merged)
                // 双重防旧盖新：世代号变了（用户又敲了键）或输入缓冲区已不是当初那串，过期结果丢弃
                guard self.latticeGeneration == generation,
                      self.inputBuffer == bufferSnapshot else { return }
                // 词图整句作为核心候选，重跑同一份后处理，与同步首屏的顺序 / 预测完全一致
                self.candidates = self.postProcess(merged, expansion: expansion, activeId: primarySchemeId)
                NotificationCenter.default.post(name: .imeInputBufferChanged, object: nil)
            }
        }
    }

    /// 捕获本次击键里所有会触发词图的方案的只读快照（主线程调用），与 `queryCode` 的分派一一对应：
    /// 反查 → 借用的音码方案；混打 → 主方案 + 生效参与方案；否则单方案。
    /// - Returns: (词图快照, 候选颜色, 反查注释用的主方案 reader) 列表，顺序即合并优先级
    private func buildLatticeJobs(queryInput: String, primarySchemeId: String)
        -> [(job: CandidateEngine.LatticeJob, colorHex: String?, annotateReader: DictReader?)] {

        // 反查（i + 拼音）：词图跑在借用的音码方案上、输入是去 i 后的拼音；候选要用主方案词库补编码注释
        if isReversePinyinInput(queryInput, primarySchemeId: primarySchemeId),
           let donorId = phoneticDonorSchemeId(excluding: primarySchemeId),
           let donorJob = candidateEngine.latticeJob(input: String(queryInput.dropFirst()), schemeId: donorId) {
            return [(donorJob, nil, candidateEngine.reader(for: primarySchemeId))]
        }

        // 混打：主方案优先，参与方案按优先级；音码参与方案沿用 MixInputEngine 的合法拼音前缀守门
        if mixActive {
            var jobs: [(CandidateEngine.LatticeJob, String?, DictReader?)] = []
            if let primaryJob = candidateEngine.latticeJob(input: queryInput, schemeId: primarySchemeId) {
                jobs.append((primaryJob, nil, nil))
            }
            let sorted = effectiveMixConfigs
                .filter { $0.isEnabled && $0.id != primarySchemeId }
                .sorted { $0.priority < $1.priority }
            for config in sorted {
                if let profile = candidateEngine.profile(of: config.id),
                   profile.codeSystem == .phonetic, profile.type != .doubleSyllable,
                   !PinyinSyllables.isValidPinyinPrefix(queryInput) {
                    continue
                }
                if let job = candidateEngine.latticeJob(input: queryInput, schemeId: config.id) {
                    jobs.append((job, config.candidateColor, nil))
                }
            }
            return jobs
        }

        // 单方案
        if let job = candidateEngine.latticeJob(input: queryInput, schemeId: primarySchemeId) {
            return [(job, nil, nil)]
        }
        return []
    }

    /// 组内排序：码与输入完全相等的词条优先，
    /// 避免长码高频词（如 xing 的「行」）压过精确匹配 xin 的「心」
    private func orderedGroup(_ reading: String, _ candidates: [MixCandidate]) -> [MixCandidate] {
        let exact = candidates.filter { $0.candidate.code == reading }
        let loose = candidates.filter { $0.candidate.code != reading }
        return exact + loose
    }

    /// 统一查词入口：单条拼音前缀查候选
    /// 26 键与双拼走的是同一个 CandidateEngine / MixInputEngine，没有第二套查询逻辑。
    /// - Parameter allowLattice: 落空时是否跑长串词图兜底。双拼的读音查询传 false：
    ///   长串词图扫描是 O(输入长²) 的活，同一次击键里最多只让它跑一遍，
    ///   所以兜底改由 refreshCandidates 在读音查询整条落空后单独补一次
    private func queryCode(_ code: String,
                           primarySchemeId: String,
                           allowPartialFallback: Bool,
                           allowLattice: Bool = true,
                           fullScan: Bool = false) -> [MixCandidate] {
        // 形码系主方案的 i+拼音反查优先：i 是引导符，不再当形码查
        if let reversed = reversePinyinCandidates(code: code,
                                                   primarySchemeId: primarySchemeId,
                                                   allowLattice: allowLattice) {
            return reversed
        }
        if mixActive {
            return mixEngine.query(
                input: code,
                primarySchemeId: primarySchemeId,
                mixConfigs: effectiveMixConfigs,
                allowLattice: allowLattice
            )
        }
        return candidateEngine.query(input: code, schemeId: primarySchemeId,
                                     limit: fullScan ? Self.expandedCandidateLimit : Self.candidateLimit,
                                     allowPartialFallback: allowPartialFallback,
                                     allowLattice: allowLattice,
                                     fullScan: fullScan)
            .map { MixCandidate(candidate: $0, colorHex: nil) }
    }

    /// 可借用来反查的已安装音码方案 id（排除主方案）
    private func phoneticDonorSchemeId(excluding primarySchemeId: String) -> String? {
        installedSchemes.first(where: {
            $0.id != primarySchemeId && profile(forSchemeId: $0.id)?.isPhonetic == true
        })?.id
    }

    /// 当前输入是否走「引导符 + 拼音」反查路径（见 reversePinyinCandidates）：
    /// 引导符由方案画像给出（schema 声明的 reverse_lookup_guide，音形码缺省回落 "i"），
    /// 以它开头且去掉引导符后为合法拼音前缀、且有可借用的音码方案。非音形码方案 guide 为 nil，直接否。
    private func isReversePinyinInput(_ input: String, primarySchemeId: String) -> Bool {
        guard let primaryProfile = profile(forSchemeId: primarySchemeId),
              let guide = primaryProfile.effectiveReverseLookupGuide,
              input.hasPrefix(guide), input.count > guide.count else { return false }
        return PinyinSyllables.isValidPinyinPrefix(String(input.dropFirst(guide.count)))
            && phoneticDonorSchemeId(excluding: primarySchemeId) != nil
    }

    /// 音形码主方案（如超强快码）的「i + 拼音」反查：i 后面跟拼音，借已安装的音码方案按拼音查字。
    /// 例：快码下敲 ini，去掉 i 拿 ni 去查拼音方案，得到 你 / 尼 / 泥…
    /// 纯形码方案不接管 i（i 可能是其合法码元），只给音形码开这个入口。
    /// 命中即直接返回反查结果，落空回退正常查询。
    ///
    /// 反查候选还要拿主方案词库补出编码当注释：用户反查的目的就是「这个字在我的形码里怎么拼」，
    /// 只给字不给码等于把答案问了一半。候选来自音码方案、自身 annotation 多为空，
    /// 所以拿同一批文字去主方案词库查最短编码（那一趟扫描只在反查路径上跑）。
    private func reversePinyinCandidates(code: String,
                                         primarySchemeId: String,
                                         allowLattice: Bool) -> [MixCandidate]? {
        guard let guide = profile(forSchemeId: primarySchemeId)?.effectiveReverseLookupGuide,
              isReversePinyinInput(code, primarySchemeId: primarySchemeId),
              let phoneticId = phoneticDonorSchemeId(excluding: primarySchemeId) else { return nil }
        let pinyin = String(code.dropFirst(guide.count))
        let hits = candidateEngine.query(input: pinyin, schemeId: phoneticId,
                                         limit: Self.candidateLimit,
                                         allowPartialFallback: true,
                                         allowLattice: allowLattice)
        guard !hits.isEmpty else { return nil }
        let codes = candidateEngine.shortestCodes(for: hits.map { $0.text },
                                                  schemeId: primarySchemeId)
        return hits.map { hit in
            MixCandidate(candidate: Candidate(text: hit.text, code: hit.code,
                                              annotation: hit.annotation ?? codes[hit.text],
                                              freq: hit.freq, sourceSchemeId: hit.sourceSchemeId,
                                              isUserWord: hit.isUserWord, userFreq: hit.userFreq),
                         colorHex: nil)
        }
    }

    // MARK: - 方案管理

    /// 首次安装（无任何激活记录）时默认激活的方案 id：雾凇拼音。
    /// 它是内置的通用拼音方案，适合绝大多数用户，也符合「首装默认雾凇拼音」的产品预期。
    private static let preferredDefaultSchemeId = "oime-ice-pinyin"

    /// 从已装方案里挑默认激活方案：优先雾凇拼音，用户删掉了它则回落到列表第一个
    /// （installedSchemeIds() 已按 id 排序，取值稳定）。
    /// 绝不能直接拿 id 字母序第一个当默认 —— 内置三套里 oime-cqkm（超强快码，形码）
    /// 排在 oime-ice-pinyin 前，那样新用户一上来就是形码，与预期相悖。
    static nonisolated func defaultSchemeId(in schemes: [InstalledScheme]) -> String {
        if schemes.contains(where: { $0.id == preferredDefaultSchemeId }) {
            return preferredDefaultSchemeId
        }
        return schemes.first?.id ?? ""
    }

    /// 内置三套方案的规范展示序（与「关于页」文案一致：雾凇拼音、虎码、超强快码）。
    /// 仅用于首次安装（还没有任何持久化顺序）时给内置方案落一个符合产品预期的初始位置；
    /// 用户之后导入的方案一律追加到末尾，删掉再导入也排到末尾（位置记忆随删除清除）。
    /// 未收录进这里的 id（含将来新增的内置方案）不特殊对待，按字母序稳定兜底。
    private static let canonicalBundledOrder = ["oime-ice-pinyin", "oime-tiger", "oime-cqkm"]

    /// 计算稳定的方案展示顺序（纯函数，便于单测）：
    /// 1. 以 persisted（上次落盘的顺序）为基准，剔除已不在 installed 里的 —— 卸载即忘位置；
    /// 2. 把 installed 里新出现的 id 追加到末尾：首次安装时内置三套按 canonicalBundledOrder 落位，
    ///    其余（用户导入 / 未知内置）按 id 字母序稳定兜底。
    /// 由此：新导入恒在末尾；删掉某方案会清掉它的位置记忆，重新导入必然又落到末尾。
    static nonisolated func reconciledSchemeOrder(installed: [String], persisted: [String]) -> [String] {
        let installedSet = Set(installed)
        var order = persisted.filter { installedSet.contains($0) }
        let placed = Set(order)
        let appended = installed.filter { !placed.contains($0) }.sorted { lhs, rhs in
            let rl = canonicalBundledRank(lhs)
            let rr = canonicalBundledRank(rhs)
            return rl == rr ? lhs < rhs : rl < rr
        }
        order.append(contentsOf: appended)
        return order
    }

    /// 内置方案在规范序里的位次；非内置 / 未收录返回 .max，排到内置之后按字母序兜底
    private static nonisolated func canonicalBundledRank(_ id: String) -> Int {
        canonicalBundledOrder.firstIndex(of: id) ?? Int.max
    }

    /// 一趟重载后应当留下的方案表（纯函数，便于单测）：「此刻读不到」不等于「已被卸载」。
    ///
    /// 起因是内置方案升级与编译纪元重编都会先删掉 dict.bin 再写回（installMissingBundled /
    /// recompileOutdatedSchemes 的 overwrite 重装），若这一趟后台扫描正落在删与写之间，
    /// loadInstalled 会对那个方案抛错。让它从 installedSchemes 里缺席，下一步
    /// purgeOrphanSettings 就把用户正在用的方案判成「已卸载」并回落到默认拼音 ——
    /// 现场表现为「突然一卡，方案自己变成拼音了」，而方案其实好端端在盘上。
    ///
    /// 判据用 declaredIds 本身：它来自 container.installedSchemeIds()，是 packages/ 目录的真实
    /// 清单，卸载路径会先把目录删掉，所以「清单里有、这趟没读到」只可能是瞬时读不到（或包体
    /// 损坏）。两种情况都该保留旧记录继续打字，绝不该顺手改用户的激活选择。
    /// - Parameters: - loaded: 这一趟真的读到了的方案（顺序即读到的顺序）
    ///   - previous: 上一趟留下的方案表
    ///   - declaredIds: packages/ 目录的真实清单，是「还在不在」的唯一凭据
    static nonisolated func reloadedSchemeList(loaded: [InstalledScheme],
                                               previous: [InstalledScheme],
                                               declaredIds: Set<String>) -> [InstalledScheme] {
        let loadedIds = Set(loaded.map { $0.id })
        let survivors = previous.filter { declaredIds.contains($0.id) && !loadedIds.contains($0.id) }
        return loaded + survivors
    }

    /// 已安装方案的稳定展示顺序（纯读，绝不写盘）：击键路径 reloadSettings 与方案管理页同源。
    /// 落盘只在 loadInstalledSchemes 那个低频漏斗里做，避免每次击键抖动磁盘、拖慢打字。
    private func orderedInstalledSchemeIds() -> [String] {
        Self.reconciledSchemeOrder(
            installed: container.installedSchemeIds(), persisted: container.loadSchemeOrder())
    }

    public func loadInstalledSchemes() async {
        // 稳定展示顺序：以持久化的既有顺序为基准对账（剔除已卸载、把新出现的追加到末尾），
        // 首次安装时内置三套按规范序落位。用户导入 / 删除 / 重新导入都在这一个低频漏斗里收敛并落盘。
        let persistedOrder = container.loadSchemeOrder()
        let ids = Self.reconciledSchemeOrder(
            installed: container.installedSchemeIds(), persisted: persistedOrder)
        if ids != persistedOrder {
            try? container.saveSchemeOrder(ids)
        }
        // 读每个方案的 manifest（磁盘 I/O）+ 构建 DictReader（mmap + 解析索引）都是重活。
        // 放后台队列执行、start() 在主 actor 上 await 这里：期间主 actor 不被同步 I/O 阻塞，
        // 可以继续渲染键盘、响应首键（与 reloadSettings 同一异步范式）。构建完再回主 actor 原子安装。
        let loaded: (schemes: [InstalledScheme], readers: [String: DictReader]) =
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    guard let self else {
                        continuation.resume(returning: ([], [:]))
                        return
                    }
                    var built: [InstalledScheme] = []
                    for id in ids {
                        if let scheme = try? self.installer.loadInstalled(schemeId: id) {
                            built.append(scheme)
                        }
                    }
                    let readers = CandidateEngine.buildReaders(for: built)
                    continuation.resume(returning: (built, readers))
                }
            }
        // 「此刻读不到」不等于「已被卸载」，把上一次的成功记录留住（行为与由来见 reloadedSchemeList）。
        // reader 不在 newReaders 里时 applyReloaded 会原地保留已装的那份（mmap 旧文件仍可读），
        // 新文件写好后下一趟重载自然换过来。
        let schemesThisPass = Self.reloadedSchemeList(
            loaded: loaded.schemes, previous: installedSchemes, declaredIds: Set(ids))
        // 回主 actor：原子安装 reader + 方案表 + 画像（applyReloaded 会卸掉已消失的方案，
        // 与原 loadScheme 循环等价：卸载路径的调用方已先行 unloadScheme，此处不会误删）
        candidateEngine.applyReloaded(schemes: schemesThisPass, newReaders: loaded.readers)
        installedSchemes = schemesThisPass
        invalidateSchemeCaches()

        // 首次安装（没有激活方案）：默认激活雾凇拼音，而非 id 字母序第一个（那会是形码超强快码）。
        // 只在 activeSchemeId 为空时兜底 —— 用户已选定的方案永远以用户为准，绝不覆盖。
        if settings.activeSchemeId.isEmpty {
            let fallback = Self.defaultSchemeId(in: loaded.schemes)
            if !fallback.isEmpty {
                settings.activeSchemeId = fallback
                try? container.saveSettings(settings)
            }
        }
    }

    public func installPackage(zipURL: URL) async throws -> PackageInstaller.InstallResult {
        // 先把 zip 存到 Documents/schemes/（覆盖同名旧文件）
        let fm = FileManager.default
        let destURL = container.schemesStoreURL.appendingPathComponent(zipURL.lastPathComponent)
        if fm.fileExists(atPath: destURL.path) {
            try? fm.removeItem(at: destURL)
        }
        try? fm.copyItem(at: zipURL, to: destURL)
        // 从 Documents/schemes/ 里的副本安装，保证路径一致
        let result = try await installer.install(zipURL: destURL, overwrite: true)
        await loadInstalledSchemes()
        return result
    }

    public func installFromYAML(url: URL) async throws -> PackageInstaller.InstallResult {
        let content = try String(contentsOf: url, encoding: .utf8)
        let fileName = url.deletingPathExtension().lastPathComponent
        let tempDir = try YAMLSingleFileImporter.buildTempDir(content: content, fileName: fileName)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let result = try await installer.installDir(tempDir, overwrite: true)
        await loadInstalledSchemes()
        return result
    }

    /// 启动後清理 settings 中引用了已不存在方案的孤儿数据
    private func purgeOrphanSettings() {
        let validIds = Set(installedSchemes.map { $0.id })
        var changed = false

        // 修正 activeSchemeId：三道判据（见 purgedActiveSchemeId），确证已卸载才回落默认方案
        let nextActive = Self.purgedActiveSchemeId(
            active: settings.activeSchemeId,
            validIds: validIds,
            onDiskIds: Set(container.installedSchemeIds()),
            fallback: Self.defaultSchemeId(in: installedSchemes))
        if nextActive != settings.activeSchemeId {
            settings.activeSchemeId = nextActive
            changed = true
        }

        let beforeMix = settings.mixInputSchemes.count
        settings.mixInputSchemes.removeAll { !validIds.contains($0.id) }
        if settings.mixInputSchemes.count != beforeMix { changed = true }

        let beforeCfg = settings.schemeConfigs.count
        settings.schemeConfigs = settings.schemeConfigs.filter { validIds.contains($0.key) }
        if settings.schemeConfigs.count != beforeCfg { changed = true }

        if changed {
            try? container.saveSettings(settings)
        }
    }

    /// 清理孤儿数据后应当保留的激活方案（纯函数，便于单测）：只在「确证已卸载」时才回落。
    ///
    /// 三道判据缺一不可：
    /// 1. validIds 为空说明方案还没加载好（或本次加载整个失败），此刻没有判定依据，
    ///    绝不能把用户的激活选择清成空（与 reconcileKeyboardMode「链为空不动用户选择」同口径）；
    /// 2. active 不在 validIds 里时还要再问一次 packages/ 目录 —— 加载链路是「读清单 → 逐个读
    ///    包」，中间任何一步抖动都可能让一个盘上明明还在的方案短暂缺席（reloadedSchemeList 已
    ///    堵住常规路径，这里兜住其它调用顺序）。目录里没有才是真被卸载；
    /// 3. 用户本来就还没选过方案（active 为空）时保持为空，首装默认由 loadInstalledSchemes 单独定。
    /// - Parameters：fallback 为「确证已卸载」时的回落目标，由调用方给出（见 defaultSchemeId）
    static nonisolated func purgedActiveSchemeId(active: String, validIds: Set<String>,
                                                 onDiskIds: Set<String>,
                                                 fallback: String) -> String {
        guard !active.isEmpty else { return active }
        if validIds.contains(active) || onDiskIds.contains(active) { return active }
        // 一个方案都没加载到时同样没有判定依据，别把用户的选择改成空串
        guard !validIds.isEmpty else { return active }
        return fallback
    }

    public func uninstallScheme(id: String) async throws {
        // 先记住它是不是内置方案：installer.uninstall 会把 packages/<id>/source.json
        // 一并删掉，事后再问 isBundledScheme 就永远得到 false 了
        let wasBundled = isBundledScheme(id: id)
        // 删编译产物
        try installer.uninstall(schemeId: id)
        candidateEngine.unloadScheme(id: id)
        // 清理 settings 中的孤儿数据
        settings.schemeConfigs.removeValue(forKey: id)
        settings.mixInputSchemes.removeAll { $0.id == id }
        try? container.saveSettings(settings)
        // 删 Documents/schemes/ 里对应的 zip（按方案 id 前缀匹配）
        let fm = FileManager.default
        if let files = try? fm.contentsOfDirectory(at: container.schemesStoreURL, includingPropertiesForKeys: nil) {
            for url in files where url.pathExtension == "zip" {
                // zip 文件名不一定等于 id，通过解析 manifest 确认
                if schemeId(ofZip: url) == id {
                    try? fm.removeItem(at: url)
                }
            }
        }
        // 内置方案被用户主动删除：记入 deletedSet，syncSchemesStore 不再自动补装
        if wasBundled {
            Self.markBundledDeleted(id)
        }
        await loadInstalledSchemes()
        if settings.activeSchemeId == id {
            // 删掉的正是当前激活方案：回落到默认方案（优先雾凇拼音），而非字母序第一个
            settings.activeSchemeId = Self.defaultSchemeId(in: installedSchemes)
            try container.saveSettings(settings)
        }
        // 通知键盘扩展同步卸载
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(AppGroupContainer.settingsChangedNotification as CFString),
            nil, nil, true
        )
    }

    /// 快速读取 zip 内 manifest.yaml 的 id 字段，只解压单个文件
    private nonisolated func schemeId(ofZip url: URL) -> String? {
        guard let archive = try? Archive(url: url, accessMode: .read) else { return nil }
        // 兼容单方案（manifest.yaml 在根）和多方案（schemes/xxx/manifest.yaml）
        let candidates = archive.filter {
            $0.path == "manifest.yaml" || $0.path.hasSuffix("/manifest.yaml")
        }
        guard let entry = candidates.first else { return nil }
        var content = ""
        _ = try? archive.extract(entry, consumer: { data in
            content += String(data: data, encoding: .utf8) ?? ""
        })
        for line in content.components(separatedBy: .newlines) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("id:") {
                return String(t.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    public func activateScheme(id: String) {
        settings.activeSchemeId = id
        clearInput()
        try? container.saveSettings(settings)
        // 新方案可能撑不起当前键盘形态（如从雾凇拼音切到虎码时停在小鹤双拼），当场对账回落
        reconcileKeyboardMode()
        // 激活方案同样是一次设置写入：与 updateSettings 一致地广播，另一进程才能立即同步
        //（键盘里切方案后，主 App 回前台 reloadSettings 拿到最新主方案；主 App 里切则键盘即时跟随）
        NotificationCenter.default.post(name: .imeSettingsChanged, object: nil)
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(AppGroupContainer.settingsChangedNotification as CFString),
            nil, nil, true
        )
    }

    // MARK: - 智能预测

    /// 预测候选的落位规则
    /// —— position 表达的是「插到第几位」，不是排序键，所以按槽位取而不是全量插入：
    ///   一个槽位只放一条：同一个词后面可能学出几十个后继（「的」这类高频词尤其如此），
    ///     全塞进去会把候选栏挤满；position 只有 2…4 三个槽位，因此最多插 3 条
    ///   同一个槽位里取累计选得最多的那条：越常用越该占住这个位置
    ///   次数相同按文字排序：Dictionary 的遍历顺序不稳定，不定序会让候选每次击键都在抖
    /// 原设计的初衷（预测永不占首位、不打断正常打字）不变。
    static nonisolated func pickPredictionSlots(
        _ predictions: [(text: String, position: Int, totalCount: Int)]
    ) -> [(text: String, position: Int)] {
        var occupied = Set<Int>()
        return predictions
            .sorted { lhs, rhs in
                if lhs.position != rhs.position { return lhs.position < rhs.position }
                if lhs.totalCount != rhs.totalCount { return lhs.totalCount > rhs.totalCount }
                return lhs.text < rhs.text
            }
            .filter { occupied.insert($0.position).inserted }
            .map { (text: $0.text, position: $0.position) }
    }

    /// 将预测数据写入磁盘（viewWillDisappear 时调用）：异步写盘，不阻塞键盘收起动画。
    /// 同步写盘（queue.sync）会让主线程等最多 1 万词对序列化落盘，收起时表现为「收得慢」；
    /// 数据每 100 次上屏已落盘一次，异步补写最后一批即可。内存告警路径仍用同步 flush 确保落盘。
    public func flushPrediction() {
        predictionEngine.flushAsync()
    }

    /// 将调频学习数据异步写入磁盘（viewWillDisappear 时与预测一同调用）
    public func flushFrequency() {
        frequencyEngine.flushAsync()
    }

    /// 系统内存告警（键盘扩展 didReceiveMemoryWarning 转进来）：
    /// 键盘扩展进程内存上限低，被系统杀掉后 iOS 会静默回落系统键盘。
    /// 主动减负：学习数据先落盘（真被杀也不丢），再清掉全部可重建缓存；
    /// mmap 的词库数据不动（干净页系统自行回收，重建映射成本高）
    public func handleMemoryWarning() {
        predictionEngine.flush()
        frequencyEngine.flush()
        invalidateSchemeCaches()
        candidateEngine.purgeCaches()
    }

    /// 清除所有预测数据
    public func clearPrediction() {
        predictionEngine.clear()
        // 预测表被清空，缓存槽位随之失效（lastCommittedText 未变，不主动清会返回陈旧预测）
        predictionCacheKey = ""
        predictionCache = []
    }

    /// 清除所有拼音动态调频学习数据
    public func clearFrequency() {
        // 引擎内部自动完成跨进程同步（写 App Group 标记 + 发 frequencyCleared 广播），
        // 存活键盘进程弃表、冷启动进程读空盘，清除不会被迟到 flush 复活
        frequencyEngine.clear()
    }

    /// 键盘扩展进程收到主 App「已清除调频记录」Darwin 广播后调用：
    /// 丢弃本进程陈旧活表，免得下一次 viewWillDisappear flush 把用户刚清的数据写回盘。
    /// 只弃表 + 对齐标记，不落盘、不再广播（见 applyExternalClear 的反回声设计）
    public func applyFrequencyClearNotice() {
        frequencyEngine.applyExternalClear()
    }

    // MARK: - 设置更新

    public func updateSettings(_ newSettings: UserSettings) {
        // 盘上现值读一次：空方案护栏与「重复写盘去重」共用，避免各读一趟
        let onDisk = container.loadSettings()
        // 空方案护栏：新进程刚起、异步 start() 还没把盘上设置 load 进来时，内存里的 settings
        // 是默认的 UserSettings()（activeSchemeId=""）。此时键盘侧任何一次「只为重绘」的全量
        // 写盘 updateSettings(runtime.settings) 都会把空方案盖到盘上，用户设的方案就此丢失、
        // 下次启动回落默认。绝不把盘上非空的 activeSchemeId 降级写成空 —— 传进来是空就以盘上现值为准。
        var settingsToSave = newSettings
        if settingsToSave.activeSchemeId.isEmpty, !onDisk.activeSchemeId.isEmpty {
            settingsToSave.activeSchemeId = onDisk.activeSchemeId
        }
        // 内存 settings 无条件更新：@Published 触发 SwiftUI 重绘，纯重绘调用（快捷面板 toggle）依赖它
        settings = settingsToSave

        // 首启空写风暴护栏：与盘上现值逐字段相同就不重复写盘、不重播 Darwin 广播。
        // 否则「视图 onChange → updateSettings 写盘 → settings.json 指纹变 → reloadSettings →
        // @Published 再触发视图 onChange」会自激成环：真机首启 2.7 秒连写 38 次相同的空 activeSchemeId，
        // 把键盘扩展启动期的磁盘 IO 打满。内容没变就跳过写盘，指纹不再抖，环即断；
        // 内存 settings 已更新、下方进程内通知照发，重绘与跨进程 Store 广播都不受影响。
        if settingsToSave != onDisk {
            try? container.saveSettings(settingsToSave)
            // 跨进程通知键盘扩展（Darwin notification）—— 只有 UserSettings 真的变了才广播
            CFNotificationCenterPostNotification(
                CFNotificationCenterGetDarwinNotifyCenter(),
                CFNotificationName(AppGroupContainer.settingsChangedNotification as CFString),
                nil, nil, true
            )
        }
        // 设置里改了激活方案或混打组合都可能让当前形态不再合法，跟着对一次账
        reconcileKeyboardMode()
        // 通知同进程内观察者
        NotificationCenter.default.post(name: .imeSettingsChanged, object: nil)
    }

}

// MARK: - 通知名

// public：键盘扩展（另一个 Target）也按名观察这三个通知，不再自己重写字面量
public extension Notification.Name {
    static let imeSettingsChanged    = Notification.Name(AppGroupContainer.settingsChangedNotification)
    static let imeAutoSelectFired    = Notification.Name("com.openime.autoSelectFired")
    static let imeInputBufferChanged = Notification.Name("com.openime.inputBufferChanged")
}
