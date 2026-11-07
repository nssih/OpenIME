import Foundation
import os

// MARK: - 拼音动态调频引擎
//
// 记录「某个拼音编码下用户反复选了哪个词」，据此在候选排序里把该词逐渐抬起 ——
// 这是智能预测（词↔词搭配）之外的第二条学习轴：同一个码，你到底要哪个词。
//
// 为什么只对拼音生效：形码 / 音形码的编码与结果近乎一对一（打满码即确定，所以能顶字上屏），
// 天然不需要「猜你想要哪个」；只有拼音是多对一的高歧义码（ji 下几十上百个字），
// 谁排前面才值得跟着用户的实际选择走。故本引擎的学习量以「规范化全拼码」为键，
// 26 键全拼、简拼、双拼（配全拼词库）拿到的候选 code 都是词库里的同一串全拼，学习量天然跨键盘形态共享。
//
// 设计底线对齐（高效率 / 小内存 / 无线程竞争阻塞）：
//   - 运行效率：查询期只做 O(1) 内存读（活表按主线程独占，不加锁、不阻塞），
//     重活（序列化落盘 / 读盘解码）全丢后台串行队列；
//   - 小内存：只存「码、词、次数」三元学习量，全局上界由进程内存实时派生并按最少选中修剪，
//     绝不写死绝对条目数（详见 maxEntries 派生说明）；
//   - 无线程竞争：活表只在主线程读写（选词、查询都发生在主线程）；后台队列只拿
//     值类型快照做磁盘序列化，绝不跨线程触碰活表 —— 无锁、无信号量、无阻塞等待。
//   - 落盘三个出口互斥不双写：满 50 次节流（连续猛打）/ 收起与内存告警的补写（生命周期）/
//     5 秒时间防抖（尾量兜底，盖住「只选了几个词键盘就开着被杀进程」的缝隙）。
//     防抖只在选词路径被武装，空着不打字零计时器开销；任一落盘出口归零计数并撤销挂起防抖，
//     每条学习记录一生恰好被写一次。
//
// 与智能预测同源又正交：两者都用「渐进、有界、可回退、后台落盘」这套稳健范式，
// 预测管「上屏 A 后下一个词常是 B」，调频管「打这个码常要这个词」，互不替代、互不打架。

public final class FrequencyAdjustEngine {

    // MARK: - 行为参数（无法由数据源派生，具名常量单源）

    /// 抬升饱和所需的选中次数：达到即把该词抬到「本批候选里的最高词频」同档。
    /// 属学习率行为参数：定义「多少次确认算可靠偏好」，无法从进程内存 / 屏幕尺寸 / 词库
    /// 容量等外部数据源派生。取 3 与 `PredictionEngine.advanceThreshold = 3` 同源 ——
    /// 偶发误选不足以撼动词库天然高频词，稳定偏好又能很快上位。
    public static let promoteCap = 3

    /// 每触发一次落盘所累计的选词次数。属 I/O 频率行为参数：
    /// 与 `PredictionEngine`「每 100 次上屏落盘」同量级；调频记录比预测更稀疏
    /// （一码一码积累），取一半即 50 次触发，摊薄磁盘写。
    /// internal 供单测推演触发次数（与 clearMarkerKey 同法）。
    static let commitInterval = 50

    /// 选词后尾量补写的防抖窗口（秒）。属 I/O 触发频率行为参数（与 `commitInterval` 同类，
    /// 无法由数据源派生）：50 次节流和键盘收起补写都盖不住「只选了几个词、键盘一直开着时
    /// 进程被杀」（Xcode 重跑 / jetsam 抢跑在告警前）的尾量，时间防抖正堵这个缝：
    /// 每次选词重新武装，最后一下安静满 5 秒才落一次盘；连续打字则一直被顺延，
    /// 不会与 50 次节流双写。internal 供单测断言窗口值与行为常量同源。
    static let persistDebounceSeconds: TimeInterval = 5

    /// 防抖调度器：收（延时, 触发闭包），返回一个可撤销该次挂起的闭包。
    /// 生产实现用主线程一次性 Timer —— 武装与回调都发生在主线程，与活表
    /// 「主线程独占」的既有不变式同一套，零跨线程竞争；单测注入可控实现，
    /// 「武装/顺延/撤销/触发」断言全同步确定，不用 sleep 等真实时钟。
    public typealias DebounceScheduler = (_ delay: TimeInterval, _ fire: @escaping () -> Void) -> () -> Void

    /// 生产防抖实现：一次性主线程 Timer（到点自动释放，repeats:false），
    /// 返回的撤销闭包供重新武装与落盘出口 invalidate。
    /// 引擎常驻（runtime 单例持有）；局部实例先于到点释放时回调走 [weak self] 自然落空，
    /// deinit 再兜一道 invalidate。
    public static let wallClockDebounce: DebounceScheduler = { delay, fire in
        let timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { _ in fire() }
        return { timer.invalidate() }
    }

    // MARK: - 容量上限（从进程数据源动态派生，禁止凭空写死）

    /// 学习表允许占用的进程内存比例分母（无量纲比例）。
    /// 取 50，意思是学习表最多占进程可用内存的 2%；即便在 24 MB 上限的旧键盘扩展上，
    /// 也留 480 KB 给学习表；主输入路径与词典读取仍占绝大多数内存，
    /// 该比例只影响「记不记得生僻偏好」，不会挤掉输入本身。
    private static let memoryBudgetDenominator: UInt64 = 50

    /// 单条「码、词、次数」在 `[String: [String: Int]]` 里的估算字节开销。
    /// 无法在 init 瞬间动态测得（测得先分配大表，反噬本要约束的预算），
    /// 但作为除数参与派生：最终 maxEntries 仍由 `os_proc_available_memory()`
    /// 的实时返回值决定，随设备内存自适应。经验构成：外层分桶均摊 ~20 B
    /// + 内层分桶均摊 ~20 B + CJK String 头 + utf8 buffer ~30 B + Int 计数 8 B
    /// + 对齐/头开销 ~18 B ≈ 96 B。
    private static let estimatedEntryCostBytes: UInt64 = 96

    /// 全局最多记住多少个「码、词」学习项。
    /// 由 `os_proc_available_memory()`（当前进程被 jetsam 杀前的剩余内存预算）
    /// 乘上学习表预算比例、再除以单条估算开销动态派生。未注入时每次读取重估、但只许上调
    /// 不许下调（单调棘轮）：init 瞬间可用内存偏低（系统刚回收过别的进程）时后续可
    /// 以涨回来；而剩余水位本来就会随学习表增长、词库装载而收缩，就地取新值会造成
    /// 「上限越用越小、进而振荡自残修剪」，故绝不下调。单测通过 init 注入定值验证修剪边界。
    public var maxEntries: Int {
        if let fixed = fixedMaxEntries { return fixed }
        let derived = Self.derivedMaxEntries()
        if derived > maxEntriesFloor { maxEntriesFloor = derived }
        return maxEntriesFloor
    }
    /// 注入的固定上限（单测/特殊场景），非注入为 nil
    private let fixedMaxEntries: Int?
    /// 单调棘轮的下界：init 时评估一次，后续只增不减
    private var maxEntriesFloor: Int

    /// 从给定内存预算基数派生条目上限（纯函数，可脱离真实 syscall 单测）。
    static func maxEntries(fromBudgetBase baseBytes: UInt64) -> Int {
        let budget = baseBytes / memoryBudgetDenominator
        return max(Int(budget / estimatedEntryCostBytes), promoteCap)
    }

    /// 由进程数据源派生学习表条目上限；至少给到 promoteCap 条保证一轮衰减走得完。
    private static func derivedMaxEntries() -> Int {
        // os_proc_available_memory() 在 Swift 桥接为 Int（size_t），与 UInt64 常量同乘除前先归位。
        let available = UInt64(os_proc_available_memory())
        // 无 jetsam 限制的环境（Mac Catalyst / 单测宿主等）该 API 返回 0；
        // 若直接拿去派生会踩到只剩 promoteCap（≈3 条）的地面，学习表形同虚设、
        // 失效还是静默的。回退用物理内存套同一预算比例：比例语义不变（仍是预算的 1/50），
        // 无限制环境里这笔预算本来就宽，实际条目数由用户真实选词决定，不会凭空爆内存。
        return maxEntries(fromBudgetBase: available > 0 ? available : ProcessInfo.processInfo.physicalMemory)
    }

    // MARK: - 跨进程清除同步（防「清除后被存活进程复活」）

    /// 清除学习数据的跨进程广播名（键盘扩展观察者与 IMERuntime 同源引用）
    public static let clearedNotificationName = "com.openime.frequencyCleared"

    /// 清除标记在 App Group UserDefaults 里的键（internal 可见供单测直接模拟另一进程）。
    /// 广播是即时层（进程活着就能收到）；标记是兜底层 —— 被挂起的进程会错过广播，
    /// 唤醒后 record / 落盘前比对标记仍能丢弃陈旧活表，堵死「迟到 flush 把刚清的
    /// 数据写回盘」的复活路径。两套一起才完整。
    static let clearMarkerKey = "com.openime.frequency.clearedAt"

    // MARK: - 活表（主线程独占，读写都不加锁）

    /// [规范化全拼码: [词: 学习次数]]
    private var table: [String: [String: Int]] = [:]
    /// 学习项总数，O(1) 判断是否需要修剪（避免每次插入都全表 reduce）
    private var entryCount = 0

    private let fileURL: URL
    /// 只做磁盘序列化的后台串行队列；活表从不交给它，交给它的都是值类型快照
    private let ioQueue = DispatchQueue(label: "com.openime.frequency", qos: .utility)
    /// 距上次落盘累计的选词次数；严格语义 = 「还没落过盘的选词数」，
    /// 每个落盘出口（节流/防抖/收起补写/内存告警同步写）统一归零
    private var commitsSinceWrite = 0
    /// 读盘是否已完成（完成前发生的选词不被旧盘数据覆盖）
    private var loadedFromDisk = false
    /// 跨进程清除标记（App Group UserDefaults）；nil = 不启用标记层，仅靠广播。
    /// 由使用方注入，引擎不自己碰 App Group 配置，保持可单测、可零污染。
    private let clearMarker: UserDefaults?
    /// 本进程已知最新的清除戳；高于它的外部戳 = 别的进程清过（初始化时先对齐，避免启动即误清）
    private var knownClearStamp: Double
    /// 防抖调度器（生产为主线程 Timer，单测注入可控实现）
    private let debounceScheduler: DebounceScheduler
    /// 当前挂起防抖的撤销句柄；nil = 无挂起。
    /// 不变式：非 nil 只可能出现在「有选词还没落盘」的窗口里，空着不打字时永远为 nil（零计时器）
    private var cancelPendingDebounce: (() -> Void)?

    public init(fileURL: URL,
                maxEntries: Int? = nil,
                clearMarker: UserDefaults? = nil,
                debounce: @escaping DebounceScheduler = FrequencyAdjustEngine.wallClockDebounce) {
        self.fileURL = fileURL
        self.fixedMaxEntries = maxEntries
        self.maxEntriesFloor = maxEntries ?? Self.derivedMaxEntries()
        self.clearMarker = clearMarker
        self.knownClearStamp = clearMarker?.double(forKey: Self.clearMarkerKey) ?? 0
        self.debounceScheduler = debounce
        // 读盘放后台，避免键盘扩展首次击键被同步解码卡住（与预测同一处置）。
        // 解码是纯静态函数、在后台跑；回主线程只做一次字典合并，之后活表只由主线程触碰。
        let url = fileURL
        ioQueue.async { [weak self] in
            guard let self else { return }
            let decoded = Self.decode(contentsOf: url)
            DispatchQueue.main.async {
                self.applyLoaded(decoded)
            }
        }
    }

    deinit {
        // 局部实例（单测）先于到点释放时，收回挂起的防抖，不留孤儿计时器；
        // 回调本身已走 [weak self]，这里只是收尾干净，不是安全依赖。
        cancelPendingDebounce?()
    }

    // MARK: - 查询（主线程，O(1)，不碰磁盘、不加锁）

    /// 某个「码、词」当前的学习次数；没有则返回 0。
    /// 热路径上每条候选都会读一次，必须是纯字典下标，绝不能排队或同步等 IO。
    public func count(code: String, text: String) -> Int {
        table[FrequencyCodec.normalizedKey(code)]?[text] ?? 0
    }

    public var isEmpty: Bool { entryCount == 0 }

    /// 当前学习项总数（内部可见，供单元测试断言 trim 将总条目控制在实例级 maxEntries 内）
    var totalEntries: Int { entryCount }

    // MARK: - 记录（主线程：选词发生在主线程）

    /// 用户为某码选定了某词 —— 抬高它，同码的其它词各退一步。
    /// 竞争衰减让「换意图」可回退：连着改选别的词，旧词的抬升会逐步掉回去，避免一旦选中就永久霸榜（回音室）。
    public func record(code: String, text: String) {
        // 落盘/选词前先核对外部清除：别的进程清过就丢弃陈旧活表，只记新选（防复活）
        syncExternalClearIfNeeded()
        guard !code.isEmpty, !text.isEmpty else { return }
        let key = FrequencyCodec.normalizedKey(code)
        var bucket = table[key] ?? [:]

        // 竞争者各 -1，归零即删；被选词 +1（不再封顶，liftedFreq 已在 promoteCap 处饱和）
        for (word, value) in bucket where word != text {
            let next = value - 1
            if next <= 0 { bucket.removeValue(forKey: word) }
            else { bucket[word] = next }
        }
        let isNew = bucket[text] == nil
        // 次数不再封顶：liftedFreq 在 promoteCap 处已饱和，超计数只影响 trim 排序
        // （高频项被优先保留）；Int 为 64 位，用户手选一辈子也不会溢出。
        let picked = (bucket[text] ?? 0) + 1
        bucket[text] = picked
        table[key] = bucket
        if isNew {
            entryCount += 1
            trimIfNeeded()
        }

        commitsSinceWrite += 1
        if commitsSinceWrite >= Self.commitInterval {
            schedulePersist()          // 归零计数与撤销防抖在落盘出口内统一做
        } else {
            armDebounce()              // 尾量兜底：每次选词重新武装，计的是「最后一次选词后 5 秒」
        }
    }

    // MARK: - 时间防抖补写（尾量兜底，与 50 次节流、生命周期补写互斥不双写）

    /// 防抖只在选词路径被武装：不打字就永远不走到这里 —— 键盘晾着、切前切后、重绘
    /// 都没有任何计时器开销（空引用）。每次选词撤销旧的重新武装，于是触发计的是
    /// 「最近一次选词后」；连续打字会一直被顺延，到 50 次由节流接手，两边不双写。
    private func armDebounce() {
        guard commitsSinceWrite > 0 else { return }
        cancelDebounce()
        cancelPendingDebounce = debounceScheduler(Self.persistDebounceSeconds) { [weak self] in
            guard let self else { return }
            self.cancelPendingDebounce = nil
            self.debounceDidFire()
        }
    }

    /// 到点再核一遍：若 50 次节流 / 收起补写 / 内存告警同步写已经把它落过盘（或表被弃），
    /// 未落盘计数已归零，就不再写快照，保证每条学习记录只被写一次。
    private func debounceDidFire() {
        guard commitsSinceWrite > 0 else { return }
        schedulePersist()
    }

    private func cancelDebounce() {
        cancelPendingDebounce?()
        cancelPendingDebounce = nil
    }

    // MARK: - 抬升曲线（纯函数，与磁盘 / 线程无关，可独立单测）

    /// 把「学习次数」翻译成候选排序用的抬升词频：以本批候选的最高词频为上界做线性抬升。
    ///
    /// 用批次自身的量纲（localMax）而非绝对增量，是为了对任意词库都成立 ——
    /// 雾凇词频上百万、快码恒为 1，固定加值对前者无效、对后者会炸；相对批次顶端抬升则两边都得体。
    /// 且抬升不超过 localMax：学习词最多追平本批最热的词、靠次数在平分中胜出，绝不凭空造出高于天然顶的权重（有界）。
    public static func liftedFreq(base: Int, count: Int, localMax: Int) -> Int {
        guard count > 0, localMax > base else { return base }
        let ratio = Double(min(count, promoteCap)) / Double(promoteCap)   // 0…1
        let headroom = Double(localMax - base)
        return base + Int(ratio * headroom)
    }

    // MARK: - 落盘 / 读盘（值类型快照交后台，活表只在主线程）

    /// 异步补写最后一批（viewWillDisappear）：主线程取快照、后台序列化，不卡键盘收起动画。
    public func flushAsync() {
        schedulePersist()
    }

    /// 同步落盘（内存告警）：必须在进程被回收前确保写完。取主线程快照后阻塞后台写完。
    /// 与异步出口同样收尾：归零未落盘计数、撤销挂起防抖（写都写了，防抖无事可做）。
    public func flush() {
        syncExternalClearIfNeeded()
        commitsSinceWrite = 0
        cancelDebounce()
        let snapshot = table
        let url = fileURL
        ioQueue.sync { Self.encode(snapshot, to: url) }
    }

    /// 清除全部学习数据（用户在设置里主动「清除调频记录」）。
    /// 主动清除自带跨进程同步：写标记 + 发广播。存活进程收广播即弃表；
    /// 被挂起/冷启动进程由标记兜底，不会再出现「清完又被迟到 flush 复活」。
    public func clear() {
        markClearedInMarker()
        discardLiveTable()
        schedulePersist()
        postClearedNotification()
    }

    /// 收到「frequencyCleared」广播时的响应（观察者路径调用）：只弃活表并对齐标记，
    /// 不落盘、不再广播 —— 发起方已把空文件写好，回声式转发会造成跨进程通知循环。
    public func applyExternalClear() {
        if let marker = clearMarker {
            knownClearStamp = max(knownClearStamp, marker.double(forKey: Self.clearMarkerKey))
        }
        discardLiveTable()
    }

    /// 标记层核对：盘上出现了比本进程已知戳更新的外部清除戳，就丢弃陈旧活表。
    /// 只在 record/落盘路径（用户击键频率量级）读一次 UserDefaults 内存缓存，
    /// 不进候选查询热路径，查询侧的即时性由广播层负责。
    private func syncExternalClearIfNeeded() {
        guard let marker = clearMarker else { return }
        let stamp = marker.double(forKey: Self.clearMarkerKey)
        guard stamp > knownClearStamp else { return }
        knownClearStamp = stamp
        discardLiveTable()
    }

    /// 丢弃活表（发起清除/响应清除共用）：loadedFromDisk 置 true，
    /// 迟到的读盘合并不会再将旧数据灌回来
    private func discardLiveTable() {
        table = [:]
        entryCount = 0
        commitsSinceWrite = 0
        cancelDebounce()   // 弃表后已无可落盘的内容，挂起的防抖到点也只会白写一份快照
        loadedFromDisk = true
    }

    private func markClearedInMarker() {
        guard let marker = clearMarker else { return }
        let stamp = Date().timeIntervalSince1970
        knownClearStamp = max(knownClearStamp, stamp)
        marker.set(stamp, forKey: Self.clearMarkerKey)
    }

    private func postClearedNotification() {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(Self.clearedNotificationName as CFString),
            nil, nil, true
        )
    }

    private func schedulePersist() {
        // 所有异步落盘出口都汇到这里：归零计数、撤销挂起防抖（与时间防抖互斥，不双写），
        // commitsSinceWrite 始终且只表示「还没落过盘的选词数」
        commitsSinceWrite = 0
        cancelDebounce()
        // 任何落盘前都要先核对外部清除：防把陈旧表整盘写回盖掉别的进程刚清的空盘（复活）
        syncExternalClearIfNeeded()
        let snapshot = table
        let url = fileURL
        ioQueue.async { Self.encode(snapshot, to: url) }
    }

    private func applyLoaded(_ loaded: [String: [String: Int]]) {
        guard !loadedFromDisk else { return }
        loadedFromDisk = true
        for (key, bucket) in loaded {
            if var existing = table[key], !existing.isEmpty {
                // 读盘完成前本次会话已选了词：逐词取较大值合并，不让旧盘数据盖掉刚学的
                for (word, value) in bucket where (existing[word] ?? 0) < value {
                    existing[word] = value
                }
                table[key] = existing
            } else {
                table[key] = bucket
            }
        }
        entryCount = table.values.reduce(0) { $0 + $1.count }
        // 盘上快照可能超出本进程派生的上限（换设备/内存收紧后上限变小）：
        // 合并完立即修剪，超容窗口不过这一帧，容量上限不变式始终成立
        trimIfNeeded()
    }

    private func trimIfNeeded() {
        guard entryCount > maxEntries else { return }
        var all: [(key: String, word: String, value: Int)] = []
        for (key, bucket) in table {
            for (word, value) in bucket { all.append((key, word, value)) }
        }
        all.sort { $0.value < $1.value }
        let toRemove = entryCount - maxEntries
        for i in 0..<min(toRemove, all.count) {
            let item = all[i]
            if table[item.key]?.removeValue(forKey: item.word) != nil {
                entryCount -= 1
            }
            if table[item.key]?.isEmpty == true {
                table.removeValue(forKey: item.key)
            }
        }
    }

    // MARK: - 编解码（后台队列调用，纯静态，绝不触碰活表）

    // 编解码对内部可见：纯静态、可脱离异步读盘主线程时序独立单测落盘/读盘往返与容错解码
    static func encode(_ table: [String: [String: Int]], to url: URL) {
        // JSON 足够小且天然容错：读不到 / 解不出就当空表，绝不因学习文件损坏而拖累打字
        guard let data = try? JSONEncoder().encode(table) else { return }
        try? data.write(to: url, options: .atomic)
    }

    static func decode(contentsOf url: URL) -> [String: [String: Int]] {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: [String: Int]].self, from: data)
        else { return [:] }
        return decoded
    }
}

// MARK: - 编码归一化

/// 把词库编码归一成调频学习量的稳定键。record 与查询共用同一个函数，
/// 跨输入形态（26 键全拼 / 简拼 / 双拼）才能对到同一个键，学习量才共享得起来。
public enum FrequencyCodec {

    /// 规范化查询码：小写 + 去掉音节分隔（空格与外部格式的 '），
    /// 让 "ni hao" / "NIHAO" / "ni'hao" 归一到同一个键 "nihao"。
    public static func normalizedKey(_ code: String) -> String {
        let lowered = code.lowercased()
        var scalars = lowered.unicodeScalars
        scalars.removeAll { $0 == " " || $0 == "'" }
        return String(scalars)
    }
}
