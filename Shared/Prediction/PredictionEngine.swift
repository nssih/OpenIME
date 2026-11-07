import Foundation

// MARK: - 智能预测引擎
// 记录用户手动选词后的上一个词到当前词的关联，提供基于上下文的预测候选
// 存储格式：二进制，全量内存操作，写入条件：viewWillDisappear 或每 100 次上屏

public final class PredictionEngine {

    // MARK: - 常量

    public static let maxPairs = 10_000
    private static let version: UInt32 = 2
    private static let advanceThreshold = 3

    // MARK: - 数据结构

    // [prevText: [text: PairData]]
    private var table: [String: [String: PairData]] = [:]
    private let fileURL: URL
    private let queue = DispatchQueue(label: "com.openime.prediction", qos: .utility)

    // 上屏计数（每 100 次触发写盘）
    private var commitCount: Int = 0

    /// 当前词对总数
    /// —— 全表 reduce 求总数在每次上屏都要遍历一遍，这里维护计数器，
    ///    trim 判断变成 O(1)，让 record 不再随词对数量变慢
    private var pairCount: Int = 0

    struct PairData {
        // 该词对被选择的累计次数（用于修剪排序）
        var totalCount: Int
        // 连续选择次数（达到阈值后重置并前移 position）
        var consecutiveCount: Int
        // 预测位置：4=第4位, 3=第3位, 2=第2位（最高）
        var position: Int

        static let initialPosition = 4
        static let maxPosition = 2
    }

    // MARK: - 初始化

    public init(fileURL: URL) {
        self.fileURL = fileURL
        // 读盘放到内部串行队列上：文件最多 10,000 条词对，同步解析会卡住调用线程
        // （键盘扩展里就是主线程，正好卡在用户第一次击键时）。
        // predict / record / flush 全部要走同一个队列，天然排在这条任务之后，不会读到半成品。
        queue.async { [weak self] in self?.load() }
    }

    // MARK: - 记录选词

    /// 用户手动选词后调用，记录 prev 到 current 的关联（线程安全，派发到内部队列）
    public func record(prev: String, current: String) {
        guard !prev.isEmpty, !current.isEmpty else { return }
        queue.async { [weak self] in self?.recordInternal(prev: prev, current: current) }
    }

    private func recordInternal(prev: String, current: String) {
        if table[prev] == nil {
            table[prev] = [:]
        }

        let isNewPair = table[prev]![current] == nil
        var pair = table[prev]![current] ?? PairData(
            totalCount: 0,
            consecutiveCount: 0,
            position: PairData.initialPosition
        )
        pair.totalCount += 1
        pair.consecutiveCount += 1

        if pair.consecutiveCount >= PredictionEngine.advanceThreshold {
            pair.consecutiveCount = 0
            pair.position = max(pair.position - 1, PairData.maxPosition)
        }

        table[prev]![current] = pair
        if isNewPair {
            pairCount += 1
            trimIfNeeded()
        }

        commitCount += 1
        if commitCount >= 100 {
            commitCount = 0
            writeToDisk()
        }
    }

    // MARK: - 预测

    /// 返回预测候选，按 position 升序排列（position 越小越靠前）
    /// - Note: 同一个词可能学出多个后继（如「的」后面跟过很多词），
    ///   这里返回全量，由调用方根据 position 槽位做取舍
    public func predict(after prev: String) -> [(text: String, position: Int, totalCount: Int)] {
        guard !prev.isEmpty else { return [] }
        return queue.sync {
            guard let pairs = table[prev] else { return [] }
            return pairs
                .map { (text: $0.key, position: $0.value.position, totalCount: $0.value.totalCount) }
                .sorted { $0.position < $1.position }
        }
    }

    // MARK: - 查询（测试用）

    public var totalPairsCount: Int {
        queue.sync { pairCount }
    }

    // MARK: - 清除

    public func clear() {
        queue.async { [weak self] in
            self?.table = [:]
            self?.commitCount = 0
            self?.pairCount = 0
            self?.writeToDisk()
        }
    }

    // MARK: - 持久化

    /// 同步等待所有已入队任务完成后写盘：调用线程会阻塞到写完。
    /// 用于系统内存告警（handleMemoryWarning）—— 真被 jetsam 杀掉前必须确保数据落盘；
    /// 也用于单元测试断言前强制同步。
    public func flush() {
        queue.sync { writeToDisk() }
    }

    /// 异步写盘：把写盘任务排到内部队列后立即返回，不阻塞调用线程。
    /// 用于键盘收起（viewWillDisappear）—— 同步写盘会卡住主线程、让收起动画掉帧（表现为「收得慢」）。
    /// 数据每 100 次上屏已落盘一次，这里异步补写最后一批；即便进程随后被系统回收，
    /// 最多丢最近不足 100 条学习记录，对预测这种尽力而为的功能可接受。
    public func flushAsync() {
        queue.async { [weak self] in self?.writeToDisk() }
    }

    // MARK: - 私有方法

    private func trimIfNeeded() {
        guard pairCount > PredictionEngine.maxPairs else { return }

        var allPairs: [(prev: String, text: String, totalCount: Int)] = []
        for (prev, texts) in table {
            for (text, data) in texts {
                allPairs.append((prev: prev, text: text, totalCount: data.totalCount))
            }
        }
        allPairs.sort { $0.totalCount < $1.totalCount }

        let toRemove = pairCount - PredictionEngine.maxPairs
        for i in 0..<min(toRemove, allPairs.count) {
            let item = allPairs[i]
            if table[item.prev]?.removeValue(forKey: item.text) != nil {
                pairCount -= 1
            }
            if table[item.prev]?.isEmpty == true {
                table.removeValue(forKey: item.prev)
            }
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL), data.count >= 8 else { return }
        guard let result = parseData(data) else { return }
        table = result
        pairCount = result.values.reduce(0) { $0 + $1.count }
    }

    private func parseData(_ data: Data) -> [String: [String: PairData]]? {
        var result: [String: [String: PairData]] = [:]
        var offset = 0

        guard let version: UInt32 = read(data, offset: &offset),
              version == PredictionEngine.version else { return nil }

        guard let prevCount: UInt32 = read(data, offset: &offset) else { return nil }

        for _ in 0..<Int(prevCount) {
            guard let prev = readString(data, offset: &offset) else { return nil }
            guard let pairCount: UInt32 = read(data, offset: &offset) else { return nil }

            var texts: [String: PairData] = [:]
            for _ in 0..<Int(pairCount) {
                guard let text = readString(data, offset: &offset),
                      let totalCount: UInt32 = read(data, offset: &offset),
                      let consecutiveCount: UInt32 = read(data, offset: &offset),
                      let position: UInt32 = read(data, offset: &offset) else { return nil }
                texts[text] = PairData(
                    totalCount: Int(totalCount),
                    consecutiveCount: Int(consecutiveCount),
                    position: Int(position)
                )
            }
            result[prev] = texts
        }
        return result
    }

    private func writeToDisk() {
        var buffer = Data()

        func w(_ value: UInt32) {
            var v = value
            buffer.append(contentsOf: withUnsafeBytes(of: &v) { Array($0) })
        }

        func wStr(_ s: String) {
            let bytes = Array(s.utf8)
            w(UInt32(bytes.count))
            buffer.append(contentsOf: bytes)
        }

        w(PredictionEngine.version)
        w(UInt32(table.count))
        for (prev, texts) in table {
            wStr(prev)
            w(UInt32(texts.count))
            for (text, data) in texts {
                wStr(text)
                w(UInt32(data.totalCount))
                w(UInt32(data.consecutiveCount))
                w(UInt32(data.position))
            }
        }

        try? buffer.write(to: fileURL, options: .atomic)
    }

    private func read<T>(_ data: Data, offset: inout Int) -> T? where T: FixedWidthInteger {
        let size = MemoryLayout<T>.size
        guard offset + size <= data.count else { return nil }
        let value = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: T.self) }
        offset += size
        return value
    }

    private func readString(_ data: Data, offset: inout Int) -> String? {
        guard let len: UInt32 = read(data, offset: &offset) else { return nil }
        let byteCount = Int(len)
        guard offset + byteCount <= data.count else { return nil }
        let str = String(bytes: data[offset..<(offset + byteCount)], encoding: .utf8)
        offset += byteCount
        return str
    }
}
