import Foundation

// MARK: - 字级二元语法（只读侧车）
//
// dict.lm.bin 是编译期从词库多字词导出的一份「相邻字搭配」统计，专供长串词图切分打分用：
// 词图选出「你好 + 吗」还是「你好 + 那」，光看词频会挑词频更高的「那」，只有知道「好吗」是常见
// 搭配、「好那」几乎不出现，才能把尾巴判对。这份数据独立成文件，dict.bin 一个字节都不动，
// 老读者永远看不见它；文件缺失或损坏时，所有查询退回「没见过的搭配」，等于回到没有二元语法的老行为。
//
// 与 DictReader 一样保持 mmap 的 Data 就地二分，不把整份文件拷进内存（这份表可能有几 MB，
// 拷进来就常驻了，违背小内存的底线）。
//
// 文件结构（小端）：
//   [Header] 40 字节
//     magic "OLM1"(4) + version(2) + flags(2) + totalFreq(8, UInt64)
//     + charCount(4) + pairCount(4) + charTableOffset(4) + pairTableOffset(4) + charTotalOffset(4) + reserved(4)
//   [CharTable] charCount 个 UInt32：去重后的汉字码点，升序，二分查「字 -> 下标」
//   [CharTotal] charCount 个 UInt32：每个字作为「搭配前字」时的总计数（二元语法的分母）
//   [PairTable] pairCount 条（aIdx UInt32 + bIdx UInt32 + count UInt32）：按 (aIdx,bIdx) 升序，二分查某一对字的计数

public struct CharBigram {

    private static let headerSize = 40
    static let magicBytes: [UInt8] = [0x4F, 0x4C, 0x4D, 0x31]   // "OLM1"

    /// 加性平滑的伪计数（add-one），没见过的搭配也留一点概率，不至于 log(0)
    private let data: Data
    private let totalFreq: UInt64
    private let charCount: Int
    private let pairCount: Int
    private let charTableOffset: Int
    private let pairTableOffset: Int
    private let charTotalOffset: Int

    /// 空表（文件缺失 / 损坏 / 词库里一个多字词都没有）：所有查询都退回缺省值
    public var isEmpty: Bool { charCount == 0 }

    /// 语料总词频的对数，交给词图做「每用一个词」的归一化代价
    public var corpusLogFreq: Double {
        totalFreq > 0 ? log(Double(totalFreq) + 1) : 16
    }

    public init(sidecar url: URL) {
        guard let mapped = try? Data(contentsOf: url, options: [.mappedIfSafe, .uncached]),
              mapped.count >= Self.headerSize,
              [UInt8](mapped.prefix(4)) == Self.magicBytes else {
            self.data = Data()
            self.totalFreq = 0
            self.charCount = 0
            self.pairCount = 0
            self.charTableOffset = 0
            self.pairTableOffset = 0
            self.charTotalOffset = 0
            return
        }
        self.data = mapped
        self.totalFreq = Self.u64(mapped, 8)
        self.charCount = Int(Self.u32(mapped, 16))
        self.pairCount = Int(Self.u32(mapped, 20))
        self.charTableOffset = Int(Self.u32(mapped, 24))
        self.pairTableOffset = Int(Self.u32(mapped, 28))
        self.charTotalOffset = Int(Self.u32(mapped, 32))
    }

    /// 相邻两字的 log 概率 log P(b | a)：越大表示这个搭配越常见。
    /// a 没在表里（没有以它开头的搭配统计）时，退化成 1/字表大小 的中性缺省值。
    public func logProb(_ a: Character, _ b: Character) -> Double {
        let vocab = Double(max(charCount, 1))
        guard !isEmpty,
              let aIdx = charIndex(a),
              let bIdx = charIndex(b) else {
            // 缺 a 或缺 b 都当「没见过的搭配」：概率 = 1 / 字表大小
            return log(1.0 / (vocab + 1.0))
        }
        let countAB = Double(pairLookup(aIdx: aIdx, bIdx: bIdx))
        let countA = Double(charTotal(at: aIdx))
        // 加一平滑：分子分母各留一个伪计数，未出现的搭配也有一个很小的概率下限
        return log((countAB + 1.0) / (countA + vocab))
    }

    // MARK: - 二分查表

    /// 字 -> 下标（CharTable 升序，二分）
    private func charIndex(_ ch: Character) -> Int? {
        guard let scalar = ch.unicodeScalars.first else { return nil }
        let target = scalar.value
        var low = 0
        var high = charCount
        while low < high {
            let mid = (low + high) / 2
            let value = data.readUInt32(at: charTableOffset + mid * 4)
            if value < target { low = mid + 1 } else { high = mid }
        }
        guard low < charCount, data.readUInt32(at: charTableOffset + low * 4) == target else { return nil }
        return low
    }

    /// (aIdx,bIdx) -> 计数（PairTable 按 (aIdx,bIdx) 升序，二分）
    private func pairLookup(aIdx: Int, bIdx: Int) -> UInt32 {
        var low = 0
        var high = pairCount
        while low < high {
            let mid = (low + high) / 2
            let base = pairTableOffset + mid * 12
            let a = Int(data.readUInt32(at: base))
            let b = Int(data.readUInt32(at: base + 4))
            if a < aIdx || (a == aIdx && b < bIdx) { low = mid + 1 } else { high = mid }
        }
        guard low < pairCount else { return 0 }
        let base = pairTableOffset + low * 12
        guard Int(data.readUInt32(at: base)) == aIdx,
              Int(data.readUInt32(at: base + 4)) == bIdx else { return 0 }
        return data.readUInt32(at: base + 8)
    }

    private func charTotal(at idx: Int) -> UInt32 {
        data.readUInt32(at: charTotalOffset + idx * 4)
    }

    // MARK: - 小端读取

    private static func u32(_ d: Data, _ at: Int) -> UInt32 { d.readUInt32(at: at) }

    private static func u64(_ d: Data, _ at: Int) -> UInt64 {
        UInt64(d.readUInt32(at: at)) | (UInt64(d.readUInt32(at: at + 4)) << 32)
    }
}

// MARK: - 侧车缓存

/// CharBigram 的线程安全缓存。
///
/// 词图兜底每键都会为同一份 dict.lm.bin 新建一次 mmap（`CharBigram(sidecar:)` 每次都走一遍
/// 打开 + 映射 + 读表头），长串逐键下来这层重复映射是白付的开销。缓存后同一侧车只映射一次、
/// 跨击键复用；按路径为键，换方案 / 重装方案自然命中不同键，旧键随进程存续（一份 mmap 的
/// 干净页由系统回收，不占脏内存，与 DictReader 的取舍一致）。
///
/// CharBigram 是只读值语义（内部 Data 为 mmap 备份、就地二分，构造后不再改），可安全跨线程共享；
/// NSLock 只保护字典本身的读写。词图计算已被移到后台串行队列（见 IMERuntime.scheduleLattice），
/// 与主线程的实例查询路径可能并发访问同一缓存，故这里必须自带锁。
public final class CharBigramCache {

    private var cache: [String: CharBigram] = [:]
    private let lock = NSLock()

    public init() {}

    /// 取（或首次构建并缓存）指定侧车的二元语法表
    public func bigram(sidecar url: URL) -> CharBigram {
        let key = url.path
        lock.lock()
        if let hit = cache[key] {
            lock.unlock()
            return hit
        }
        lock.unlock()
        // 构建放在锁外：mmap 有 I/O，持锁做会挡住其它方案的查询
        let built = CharBigram(sidecar: url)
        lock.lock()
        cache[key] = built
        lock.unlock()
        return built
    }

    /// 清空缓存（内存告警等场景；侧车可按需重建）
    public func removeAll() {
        lock.lock()
        cache.removeAll()
        lock.unlock()
    }
}
