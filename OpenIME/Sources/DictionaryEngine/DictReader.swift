import Foundation

// MARK: - 词库查询引擎
// 使用 mmap 内存映射，支持 5GB+ 词库，运行时内存极低

public final class DictReader {

    private let data: Data
    private let entryCount: Int
    private let indexOffset: Int
    private let dataOffset: Int
    private let schemeType: SchemeType

    // 编码 → 数据区偏移表（v3 起随文件预编译，查询靠它二分定位前缀区间）
    //
    // 旧格式（v2）只按「前两字符」建桶：多字符前缀查询要把整个两字符桶逐条扫一遍。
    // 拼音热门声母桶（ji / shi…）动辄几万条，每敲一键都重扫，实测每键 30～90ms。
    // 数据区严格按 code 升序，任一前缀的命中条目必是「一段连续区间」；v3 改存每条
    // 词条的起始偏移表，查询时对偏移表二分定位区间端点（O(log n)），再只顺序扫这一段，
    // 与桶大小彻底解耦。偏移表在文件里是干净的 mmap 页，不占进程脏内存。
    private let offsetTableInFile: Bool
    /// 旧格式（v2）词库的兼容回退：初始化时顺序扫一遍数据区，在内存里补建同一张偏移表，
    /// 让查询路径与 v3 完全一致。仅存在于「主 App 后台重编完成之前」的短暂窗口，重编后即被替换。
    private let legacyOffsets: [UInt32]

    // MARK: - v4 侧车（可选，编译期预排索引）
    //
    // dict.ptn.bin：大区间前缀的 top-N 预排偏移表。命中即 O(N) 读 N 个偏移，与区间大小无关；
    //   未命中说明该前缀区间 ≤ 编译阈值（300），回退顺序扫小区间也 <1ms。两条路都可证明 <1ms。
    // dict.ti.bin：text → 最短编码 有序表。反查（i+拼音 补编码）改按 text 二分 O(log n)，
    //   不再每键全扫数据区（真机实测全扫 55 万条 ≈ 1s/键）。
    // 两者都是 mmap 干净页、加载不到（老词库）就保持 nil，查询自动走原有扫描路径，零风险。
    private var ptn: Data?
    private var ptnMode: UInt8 = 0      // 0=纯词频 1=码表(同词频码短者优先)
    private var ptnCount: Int = 0
    private var ptnDirOff: Int = 0
    private var ptnPoolOff: Int = 0
    private var ti: Data?
    private var tiCount: Int = 0
    private var tiDirOff: Int = 0
    private var tiTextPool: Int = 0
    private var tiCodePool: Int = 0
    /// 与编译期 ptnMaxPrefixLen 一致：更长的前缀不进侧车（区间本就小）
    private static let ptnMaxPrefixLenReader = 8

    /// 单字符前缀的结果缓存
    ///
    /// 单字符查询要把 36 个第二字符桶全部扫一遍（几万条词条），是首键延迟的主要来源；
    /// 而词库是只读的，同一个字母的结果永远一样。26 键 / 双拼每次输入都从第一键开始，
    /// 缓存命中后首键几乎无开销。
    private static let singleCharCacheLimit = 50
    private let cacheLock = NSLock()
    private var singleCharCache: [String: [Candidate]] = [:]

    // MARK: - 反查用「文字 → 最短编码」记忆
    //
    /// 反查要的字码对照表：词库没有文字侧索引，每个新文字都要整趟数据区扫描（几十万条）。
    /// 而反查是在打字途中逐击键调用的：敲 i+拼音 时每按一个键都会把同一批高频字重查一遍，
    /// 实测就是「快码里打拼音非常卡」的直接成因。
    /// 词库只读，所以同一个字的最短编码在一个会话里永不变，记下来就是最终答案；
    /// 上一批没查到的字同样记为「查不到」（空串），免得它每次击键都重新拉一趟全场扫描。
    private var shortestCodeMemo: [String: String] = [:]

    /// 记忆上限：反查给的是候选栏那几十个字，正常用量远碰不到这个数；
    /// 真超了就直接清空重建（词库只读，重算结果一致），不给无界增长留口子
    private static let shortestCodeMemoLimit = 4_000

    /// 系统内存告警时清掉查询缓存：都是可重建的派生数据（词库只读，
    /// 下次查询自然重建）；mmap 的数据本体是干净页，系统可自行回收，不用在这里动
    public func purgeCaches() {
        cacheLock.lock()
        singleCharCache.removeAll()
        shortestCodeMemo.removeAll()
        cacheLock.unlock()
    }

    // MARK: - 初始化

    public init(binURL: URL) throws {
        // 用 mmap 方式加载，不占用实际内存
        self.data = try Data(contentsOf: binURL, options: [.mappedIfSafe, .uncached])

        guard data.count >= 20 else {
            throw DictError.invalidFormat("文件太小")
        }

        // 验证 magic
        let magic = String(bytes: data[0..<4], encoding: .utf8)
        guard magic == "OIME" else {
            throw DictError.invalidFormat("Magic 不匹配")
        }

        let type: SchemeType
        let schemeCode = data[6]
        switch schemeCode {
        case 0: type = .direct
        case 1: type = .syllable
        case 2: type = .doubleSyllable
        default: type = .direct
        }

        let entryCount = Int(data.readUInt32(at: 8))
        let indexOffset = Int(data.readUInt32(at: 12))
        let dataOffset  = Int(data.readUInt32(at: 16))
        let version = Int(data.readUInt16(at: 4))

        self.schemeType = type
        self.entryCount = entryCount
        self.indexOffset = indexOffset
        self.dataOffset = dataOffset

        // v3 起索引区就是「每条词条相对数据区起点的偏移表」（entryCount × UInt32 LE），
        // 查询二分它定位前缀区间；偏移表留在 mmap 干净页里按需读，初始化不拷贝、O(1)。
        // v2 及更早没有这张表：顺序扫一遍数据区在内存里补建同构偏移表，查询路径与 v3 完全一致，
        // 只存在于「主 App 按 compilerEpoch 后台重编完成之前」的短暂窗口，重编后 reader 被替换。
        if version >= 3 {
            self.offsetTableInFile = true
            self.legacyOffsets = []
        } else {
            self.offsetTableInFile = false
            self.legacyOffsets = Self.buildOffsetsByScanning(data, dataOffset: dataOffset,
                                                             entryCount: entryCount)
        }
        loadSidecars(nextTo: binURL)
    }

    /// 旧格式兼容：顺序扫数据区补建「每条词条相对 dataOffset 的起始偏移表」。
    /// 数据区一律按 code 升序（编译期第 7 步排序），补出来的表与 v3 预编译表同构；
    /// 词条数被 entryCount 兜住，旧文件数据区后即便还挂着已停用的附加区也不会扫进去。
    private static func buildOffsetsByScanning(_ data: Data, dataOffset: Int,
                                               entryCount: Int) -> [UInt32] {
        var offsets: [UInt32] = []
        offsets.reserveCapacity(entryCount)
        var pos = dataOffset
        for _ in 0..<entryCount {
            guard pos < data.count else { break }
            offsets.append(UInt32(pos - dataOffset))
            let codeLen = Int(data[pos]); pos += 1 + codeLen
            guard pos + 2 <= data.count else { break }
            let textLen = Int(data.readUInt16(at: pos)); pos += 2 + textLen
            guard pos + 2 <= data.count else { break }
            let annoLen = Int(data.readUInt16(at: pos)); pos += 2 + annoLen
            guard pos + 4 <= data.count else { break }
            pos += 4
        }
        return offsets
    }

    // MARK: - v4 侧车加载与查询

    /// 可选加载同目录两张侧车；认不出 / 不存在就保持 nil，查询自动回退原有扫描路径
    private func loadSidecars(nextTo binURL: URL) {
        let dir = binURL.deletingLastPathComponent()
        if let p = try? Data(contentsOf: dir.appendingPathComponent("dict.ptn.bin"),
                             options: [.mappedIfSafe, .uncached]),
           p.count >= 24, String(bytes: p[0..<4], encoding: .utf8) == "OPTN" {
            ptn = p
            ptnMode = p[6]
            ptnCount = Int(p.readUInt32(at: 8))
            ptnDirOff = Int(p.readUInt32(at: 12))
            ptnPoolOff = Int(p.readUInt32(at: 16))
        }
        if let t = try? Data(contentsOf: dir.appendingPathComponent("dict.ti.bin"),
                             options: [.mappedIfSafe, .uncached]),
           t.count >= 24, String(bytes: t[0..<4], encoding: .utf8) == "OTIX" {
            ti = t
            tiCount = Int(t.readUInt32(at: 8))
            tiDirOff = Int(t.readUInt32(at: 12))
            tiTextPool = Int(t.readUInt32(at: 16))
            tiCodePool = Int(t.readUInt32(at: 20))
        }
    }

    /// 二分 prefixTopN 目录（16B/条）取该前缀预排的 top-N 偏移（相对 dataOffset）；未收录返回 nil
    private func ptnOffsets(for prefix: [UInt8]) -> [Int]? {
        guard let ptn, ptnCount > 0 else { return nil }
        var lo = 0, hi = ptnCount
        while lo < hi {
            let mid = (lo + hi) / 2
            if comparePtnPrefix(at: ptnDirOff + mid * 16, prefix) < 0 { lo = mid + 1 } else { hi = mid }
        }
        guard lo < ptnCount, comparePtnPrefix(at: ptnDirOff + lo * 16, prefix) == 0 else { return nil }
        let at = ptnDirOff + lo * 16
        let storedCount = Int(ptn.readUInt16(at: at + 2))
        let poolBase = ptnPoolOff + Int(ptn.readUInt32(at: at + 12))
        var out: [Int] = []
        out.reserveCapacity(storedCount)
        for k in 0..<storedCount {
            out.append(Int(ptn.readUInt32(at: poolBase + k * 4)))
        }
        return out
    }

    /// 目录条目内联前缀与目标的字节序比较（负/0/正）；目录按前缀字节升序，可直接二分
    private func comparePtnPrefix(at: Int, _ prefix: [UInt8]) -> Int {
        guard let ptn else { return -1 }
        let len = Int(ptn[at])
        let common = Swift.min(len, prefix.count)
        for i in 0..<common {
            let a = ptn[at + 4 + i], b = prefix[i]
            if a != b { return a < b ? -1 : 1 }
        }
        if len == prefix.count { return 0 }
        return len < prefix.count ? -1 : 1
    }

    /// 由「相对 dataOffset 的偏移」解析一条词条为 Candidate（侧车预排路径专用，无需前缀判定）
    private func candidate(atRelativeOffset rel: Int) -> Candidate? {
        var pos = dataOffset + rel
        guard pos < data.count else { return nil }
        let codeLen = Int(data[pos]); pos += 1
        guard pos + codeLen <= data.count else { return nil }
        let codeStart = pos; pos += codeLen
        guard pos + 2 <= data.count else { return nil }
        let textLen = Int(data.readUInt16(at: pos)); pos += 2
        guard pos + textLen <= data.count else { return nil }
        let textStart = pos; pos += textLen
        guard pos + 2 <= data.count else { return nil }
        let annoLen = Int(data.readUInt16(at: pos)); pos += 2
        let annoStart = pos; pos += annoLen
        guard pos + 4 <= data.count else { return nil }
        let freq = Int(data.readInt32(at: pos))
        guard let code = String(bytes: data[codeStart..<(codeStart + codeLen)], encoding: .utf8),
              let text = String(bytes: data[textStart..<(textStart + textLen)], encoding: .utf8) else { return nil }
        let annotation = annoLen > 0
            ? String(bytes: data[annoStart..<(annoStart + annoLen)], encoding: .utf8) : nil
        return Candidate(text: text, code: code, annotation: annotation,
                         freq: freq, sourceSchemeId: "")
    }

    /// 二分反查侧车（12B/条）取 text 的最短编码；词库里没有返回 nil
    private func tiCode(for text: String) -> String? {
        guard let ti, tiCount > 0 else { return nil }
        let target = Array(text.utf8)
        var lo = 0, hi = tiCount
        while lo < hi {
            let mid = (lo + hi) / 2
            if compareTiText(at: tiDirOff + mid * 12, target) < 0 { lo = mid + 1 } else { hi = mid }
        }
        guard lo < tiCount, compareTiText(at: tiDirOff + lo * 12, target) == 0 else { return nil }
        let at = tiDirOff + lo * 12
        let codeLen = Int(ti.readUInt16(at: at + 2))
        let codeOff = tiCodePool + Int(ti.readUInt32(at: at + 8))
        guard codeOff + codeLen <= ti.count else { return nil }
        return String(bytes: ti[codeOff..<(codeOff + codeLen)], encoding: .utf8)
    }

    /// 目录条目 text 与目标的字节序比较（负/0/正）；目录按 text 字节升序，可直接二分
    private func compareTiText(at: Int, _ target: [UInt8]) -> Int {
        guard let ti else { return -1 }
        let len = Int(ti.readUInt16(at: at))
        let base = tiTextPool + Int(ti.readUInt32(at: at + 4))
        let common = Swift.min(len, target.count)
        for i in 0..<common {
            let a = ti[base + i], b = target[i]
            if a != b { return a < b ? -1 : 1 }
        }
        if len == target.count { return 0 }
        return len < target.count ? -1 : 1
    }

    // MARK: - 查询

    /// 精确前缀查询：返回所有 code 以 prefix 开头的候选
    ///
    /// 性能要点（一次击键可能要查多条全拼前缀，单字符前缀还要合并 36 个桶）：
    /// 桶定位走 init 时建好的哈希表，O(1)
    /// 逐条读取时先用字节比较判断前缀，不匹配的词条不构造字符串
    /// 用 freq 小顶堆只留前 limit 条，避免对整桶候选做全量排序
    /// 查询语义（哪些词条命中、按 freq 从大到小）与原实现一致。
    public func query(prefix: String, limit: Int = 50) -> [Candidate] {
        collect(prefix: prefix, limit: limit, exactOnly: false)
    }

    /// 码表补全专用前缀查询（形码 / 音形码的 tableCandidates 走这里）
    ///
    /// 与 `query(prefix:)` 的唯一差别是「同词频时码短者优先」。码表词库（如超强快码 cqkm）
    /// 全库 weight 恒为 1，`query` 的 freq 小顶堆在词频全相等时退化成按扫描顺序（= code 字母序）
    /// 取前 N 条 —— 单字母 `h` 下 200 多条 `ha*` 长码会把「好」(hb) 这类高频简码整批挤出候选。
    /// 这里在词频相同（乃至全库恒定）时改按码长决胜，简码 / 常用字优先，与外部格式 table
    /// translator 的语义一致。拼音路径不走这里，逐字节保持原样。
    public func queryTable(prefix: String, limit: Int = 50) -> [Candidate] {
        collect(prefix: prefix, limit: limit, exactOnly: false, preferShorterCode: true)
    }

    /// 展开面板「看全部」专用：绕过 ptn top-N 侧车与单字符缓存，对命中区间做全量扫描，
    /// 一次性返回该前缀下的（近乎）全部词条（按词频 / 码长决胜排序，limit 给足够大即全量）。
    /// 大前缀（如单字母 y）编译期只预排了 ptnTopN 条、走侧车会被截断；这里跳过侧车直接扫
    /// 整个命中区间，让「字库里明明有、候选里就是不出」的冷门字也能在展开面板里出现。
    /// 仅低频的展开动作触发，不进击键热路径、不污染每键候选缓存。
    public func queryAll(prefix: String, limit: Int, preferShorterCode: Bool = false) -> [Candidate] {
        collect(prefix: prefix, limit: limit, exactOnly: false,
                preferShorterCode: preferShorterCode, ignoreTopNSidecar: true)
    }

    /// 精确查询：只返回 code 与入参完全相等的候选
    ///
    /// 必须独立扫描，不能拿 `query(prefix:)` 的结果再过滤：那个堆是「整码 + 更长码补全」
    /// 按词频混排的 top-N，低词频的整码条目会被同前缀的高词频补全挤出堆外
    ///（虎码 lc 下 艹270/艸269/丌268/廾257 就曾被 top50 的 426 门槛全部挡掉），
    /// 表现为「字库里明明有、候选里就是不出」。这里堆里全是精确命中，limit 才真正管得住。
    /// - Parameter limit: 精确条目自己的上限（形码一个整码可能有十几条同码字/偏旁）
    public func queryExact(code: String, limit: Int = 50) -> [Candidate] {
        collect(prefix: code, limit: limit, exactOnly: true)
    }

    /// 反查用：给一批文字，返回它们在本词库里的最短编码（文字 → 编码）
    ///
    /// 词库的索引只按「编码前缀」建（见 init 里的偏移表与 locateRange），没有文字侧索引，所以这里做
    /// 一趟数据区顺序扫描：按词条数逐条只读长度推进，命中判定先按 UTF-8 字节长度筛，
    /// 长度相同才比字节 —— 绝大多数记录连字符串都不构造。
    ///
    /// 存在的理由是形码方案的「i + 拼音」反查：候选来自借用的音码方案，本身不带主方案编码，
    /// 而用户反查就是为了知道这个字怎么拼，所以拿主方案词库把编码补出来（见 IMERuntime）。
    ///
    /// 性能两道（都是行为等价的纯提速，结果与逐条重扫完全一致）：
    /// 1. 整趟扫描只取一次 mmap 指针。原写法每条记录要调五六次 Data.readUInt16/readUInt32，
    ///    每次都进一次 withUnsafeBytes；几十万条乘下来，单是这层调用就把一次反查拖到百毫秒级。
    /// 2. 结果按字进 shortestCodeMemo（见该属性注释）：同一批高频字只在第一次击键付扫描代价。
    /// - Returns: 命中的文字 → 最短编码（同长再按编码字序取小）；词库里没有的不出现在结果里
    public func shortestCodes(forTexts texts: [String]) -> [String: String] {
        // v4 反查侧车：text → 最短码 有序表，按 text 二分 O(log n)，不再每键全扫数据区
        if ti != nil {
            var result: [String: String] = [:]
            for text in Set(texts) where !text.isEmpty {
                if let code = tiCode(for: text) { result[text] = code }
            }
            return result
        }
        // 先吃记忆：已查过的字（含「查不到」）不再劳动扫描
        cacheLock.lock()
        var memo = shortestCodeMemo
        cacheLock.unlock()

        var pending: [String] = []
        var best: [String: String] = [:]
        for text in Set(texts) where !text.isEmpty {
            if let known = memo[text] {
                if !known.isEmpty { best[text] = known }
            } else {
                pending.append(text)
            }
        }
        guard !pending.isEmpty else { return best }

        let found = scanShortestCodes(for: pending)

        // 未命中也记一笔空串：反查候选里混着词库没有的字，不记就等于每击键重扫一遍整库
        if memo.count + found.count + pending.count > Self.shortestCodeMemoLimit {
            memo.removeAll()
        }
        for text in pending {
            memo[text] = found[text] ?? ""
        }
        cacheLock.lock()
        shortestCodeMemo = memo
        cacheLock.unlock()
        return best.merging(found) { current, _ in current }
    }

    /// 数据区单趟顺序扫描：求一批文字在本词库里的最短编码（不做记忆，纯计算）
    private func scanShortestCodes(for texts: [String]) -> [String: String] {
        // 按字节长度分桶：扫描时长度不等直接跳过，不碰内容
        var wanted: [Int: [(text: String, bytes: [UInt8])]] = [:]
        for text in texts {
            wanted[text.utf8.count, default: []].append((text, Array(text.utf8)))
        }

        var best: [String: String] = [:]
        data.withUnsafeBytes { raw -> Void in
            guard let base = baseAddress(of: raw) else { return }
            let limit = raw.count
            var pos = dataOffset
            for _ in 0..<entryCount {
                guard pos < limit else { break }
                let codeLen = Int(base[pos]); pos += 1
                guard pos + codeLen <= limit else { break }
                let codeStart = pos; pos += codeLen
                guard pos + 2 <= limit else { break }
                let textLen = Int(le16(base, pos)); pos += 2
                guard pos + textLen <= limit else { break }
                let textStart = pos; pos += textLen
                // 注释与词频两段只用来推进偏移，反查不关心它们
                guard pos + 2 <= limit else { break }
                let annoLen = Int(le16(base, pos)); pos += 2 + annoLen
                guard pos + 4 <= limit else { break }
                pos += 4

                for target in wanted[textLen] ?? [] {
                    guard equalsBytes(base, target.bytes, at: textStart) else { continue }
                    // 同字多码取最短码：用户想知道的是「怎么拼」，最短那条才是他要打的键序。
                    // 比的是字节数，形码 / 拼音编码都是 ASCII 字母，字节数即字符数
                    if let current = best[target.text], current.utf8.count <= codeLen { continue }
                    let codeBytes = UnsafeBufferPointer(start: base + codeStart, count: codeLen)
                    guard let code = String(bytes: codeBytes, encoding: .utf8) else { continue }
                    best[target.text] = code
                }
            }
        }
        return best
    }

    /// 取 mmap 基址：空 Data 时返回 nil，避免下游做无谓扫描
    private func baseAddress(of raw: UnsafeRawBufferPointer) -> UnsafePointer<UInt8>? {
        raw.bindMemory(to: UInt8.self).baseAddress
    }

    /// 指针版小端 16 位读：与 Data.readUInt16(at:) 逐字节等价，只是不再每次重取 mmap 指针
    private func le16(_ base: UnsafePointer<UInt8>, _ at: Int) -> UInt16 {
        UInt16(base[at]) | (UInt16(base[at + 1]) << 8)
    }

    /// 指针版小端 32 位读：偏移表二分用它直接从 mmap 基址取，省去逐条 Data.readUInt32 重取指针
    private func le32(_ base: UnsafePointer<UInt8>, _ at: Int) -> UInt32 {
        UInt32(base[at]) | (UInt32(base[at + 1]) << 8)
            | (UInt32(base[at + 2]) << 16) | (UInt32(base[at + 3]) << 24)
    }

    /// 词库里从 offset 起的这段字节是否就是目标内容（逐字节比，不构造字符串）
    private func equalsBytes(_ target: [UInt8], at offset: Int) -> Bool {
        data.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return false }
            return equalsBytes(base, target, at: offset)
        }
    }

    /// 指针版：调用方已持有基址，省去每次重新取 mmap 指针
    private func equalsBytes(_ base: UnsafePointer<UInt8>, _ target: [UInt8], at offset: Int) -> Bool {
        guard offset >= 0, offset + target.count <= data.count else { return false }
        for i in 0..<target.count where base[offset + i] != target[i] { return false }
        return true
    }

    /// 检索主体：前缀模式与精确模式共用，差别只在「命中判定是否要求码长相等」。
    ///
    /// 数据区按 code 升序，任一前缀的命中词条必是一段连续区间。先用二分在偏移表上定位这段
    /// 区间（O(log n)，与桶大小无关），再从区间起点顺序扫到终点 —— 只碰真正命中的词条。
    /// 命中判定、freq top-k 堆、码表快筛全部沿用 scanEntry（逐字节等价，语义不变）。
    private func collect(prefix: String, limit: Int, exactOnly: Bool,
                         preferShorterCode: Bool = false,
                         ignoreTopNSidecar: Bool = false) -> [Candidate] {
        guard !prefix.isEmpty, limit > 0 else { return [] }

        let prefixBytes = Array(prefix.utf8)

        // 单字符前缀的结果缓存只适用于前缀模式：精确模式收的条目集合不同，不能混用。
        // 缓存键带上决胜规则：码表补全（同词频码短者优先）与拼音（同词频按扫描序）结果不同，不能共用
        // ignoreTopNSidecar（展开全量查询）时既不读也不写这个缓存：缓存只存 top-singleCharCacheLimit 条，
        // 读它会把全量查询截断，写它会把超长列表塞进为击键热路径准备的缓存里
        let isSingleChar = prefix.count == 1
        let cacheKey = (preferShorterCode ? "T:" : "P:") + prefix
        var cacheLimit = limit
        if isSingleChar, !exactOnly, !ignoreTopNSidecar {
            cacheLock.lock()
            let cached = singleCharCache[cacheKey]
            cacheLock.unlock()
            if let cached { return Array(cached.prefix(limit)) }
            cacheLimit = Swift.max(limit, Self.singleCharCacheLimit)
        }

        // v4 prefixTopN 快路径：大区间前缀直接读编译期预排的 top-N 偏移，O(N) 与区间大小无关。
        // 仅前缀模式 + v3 偏移表在文件 + 侧车模式与本次决胜规则匹配时才走；
        // 侧车未命中 ⇒ 该前缀区间 ≤ 编译阈值，落到下面的小区间顺序扫同样 <1ms。
        // ignoreTopNSidecar（展开全量查询）时跳过这条快路径：它只返回编译期预排的 ptnTopN 条，
        // 正是要绕开的截断源，改走下面的二分定位 + 全区间顺序扫
        if !exactOnly, !ignoreTopNSidecar, offsetTableInFile, ptn != nil,
           ptnMode == (preferShorterCode ? 1 : 0),
           prefixBytes.count <= Self.ptnMaxPrefixLenReader,
           let ranked = ptnOffsets(for: prefixBytes) {
            let cands = ranked.compactMap { candidate(atRelativeOffset: $0) }
            return Array(cands.prefix(limit))
        }

        // 二分定位命中区间 [lo, hi)：前缀模式取「>= prefix」到「>= prefix 的后继串」；
        // 精确模式取「== prefix」那段（等于 prefix 的词条在升序里连续且码长相等）
        let range = locateRange(prefixBytes: prefixBytes, exactOnly: exactOnly)

        var heap: [Candidate] = []
        heap.reserveCapacity(cacheLimit)
        if range.lo < range.hi {
            // 区间内词条在数据区连续：从起点取一次偏移，之后靠 scanEntry 返回的下一条偏移顺序推进
            var offset = entryOffset(range.lo)
            for _ in range.lo..<range.hi {
                guard let next = scanEntry(at: offset, prefixBytes: prefixBytes,
                                           exactCodeLength: exactOnly ? prefixBytes.count : nil,
                                           heap: &heap, limit: cacheLimit,
                                           preferShorterCode: preferShorterCode) else { break }
                offset = next
            }
        }

        let ordered = heap.sorted { isBetterCandidate($0, than: $1, preferShorterCode: preferShorterCode) }
        if isSingleChar, !exactOnly, !ignoreTopNSidecar {
            cacheLock.lock()
            singleCharCache[cacheKey] = ordered
            cacheLock.unlock()
        }
        return Array(ordered.prefix(limit))
    }

    // MARK: - 私有方法

    /// 偏移表条数（v3 = entryCount；旧格式回退 = 内存补建的条数，损坏时可能少于 entryCount）
    private var tableCount: Int { offsetTableInFile ? entryCount : legacyOffsets.count }

    /// 数据区里第 k 条词条的绝对起始偏移
    private func entryOffset(_ k: Int) -> Int {
        if offsetTableInFile {
            return dataOffset + Int(data.readUInt32(at: indexOffset + k * 4))
        }
        return dataOffset + Int(legacyOffsets[k])
    }

    /// 二分定位 prefix 的命中区间 [lo, hi)（数据区按 code 升序，命中必连续）
    ///
    /// - 前缀模式：lo = 第一个 code >= prefix；hi = 第一个 code >= prefix 的「后继串」
    ///   （末字节 +1，遇 0xFF 向前进位；prefix 全 0xFF 时无上界，hi = 末尾）。区间内每条都以 prefix 开头。
    /// - 精确模式：[lowerBound(prefix), upperBound(prefix)) —— 恰好是 code == prefix 的那段。
    /// 全程在单次 withUnsafeBytes 里用裸指针读偏移表与 code，避免逐条重取 mmap 指针。
    private func locateRange(prefixBytes: [UInt8], exactOnly: Bool) -> (lo: Int, hi: Int) {
        let n = tableCount
        guard n > 0 else { return (0, 0) }
        return data.withUnsafeBytes { raw -> (Int, Int) in
            guard let base = baseAddress(of: raw) else { return (0, 0) }
            let bound = raw.count

            // 第 k 条 code 的 (起始偏移, 长度)；越界返回 nil（按最小处理，二分不会因此误判命中）
            func codeSpan(_ k: Int) -> (start: Int, len: Int)? {
                let rel: Int
                if offsetTableInFile {
                    let at = indexOffset + k * 4
                    guard at + 4 <= bound else { return nil }
                    rel = Int(le32(base, at))
                } else {
                    guard k < legacyOffsets.count else { return nil }
                    rel = Int(legacyOffsets[k])
                }
                let off = dataOffset + rel
                guard off < bound else { return nil }
                let len = Int(base[off])
                guard off + 1 + len <= bound else { return nil }
                return (off + 1, len)
            }
            // code(k) 与 target 的字节序比较：负 = code < target，0 = 相等，正 = code > target
            func compare(_ k: Int, _ target: [UInt8]) -> Int {
                guard let span = codeSpan(k) else { return -1 }
                let common = Swift.min(span.len, target.count)
                for i in 0..<common {
                    let a = base[span.start + i], b = target[i]
                    if a != b { return a < b ? -1 : 1 }
                }
                if span.len == target.count { return 0 }
                return span.len < target.count ? -1 : 1
            }
            func lowerBound(_ target: [UInt8]) -> Int {
                var lo = 0, hi = n
                while lo < hi {
                    let mid = (lo + hi) / 2
                    if compare(mid, target) < 0 { lo = mid + 1 } else { hi = mid }
                }
                return lo
            }
            func upperBound(_ target: [UInt8]) -> Int {
                var lo = 0, hi = n
                while lo < hi {
                    let mid = (lo + hi) / 2
                    if compare(mid, target) <= 0 { lo = mid + 1 } else { hi = mid }
                }
                return lo
            }

            let lo = lowerBound(prefixBytes)
            if exactOnly { return (lo, upperBound(prefixBytes)) }
            // prefix 的后继串：末字节 +1（遇 0xFF 向前进位）；全 0xFF 则没有上界
            var succ = prefixBytes
            var idx = succ.count - 1
            var overflow = true
            while idx >= 0 {
                if succ[idx] < 0xFF {
                    succ[idx] += 1
                    succ.removeSubrange((idx + 1)..<succ.count)
                    overflow = false
                    break
                }
                idx -= 1
            }
            return (lo, overflow ? n : lowerBound(succ))
        }
    }

    /// 扫描一条词条：前缀不匹配时不构造任何字符串，只读出长度跳过字段
    /// - Parameter exactCodeLength: 非 nil 时为精确模式，额外要求码长与该值相等
    /// - Returns: 下一条词条的起始偏移；数据损坏时返回 nil
    private func scanEntry(at offset: Int,
                           prefixBytes: [UInt8],
                           exactCodeLength: Int? = nil,
                           heap: inout [Candidate],
                           limit: Int,
                           preferShorterCode: Bool = false) -> Int? {
        var pos = offset
        guard pos < data.count else { return nil }

        // 逐字段只读长度、记下起始偏移，先不构造字符串（能否入选要等 freq 快筛后才定）
        let codeLen = Int(data[pos]); pos += 1
        guard pos + codeLen <= data.count else { return nil }
        let matched = (exactCodeLength == nil || codeLen == exactCodeLength!)
            && matchesPrefix(at: pos, length: codeLen, prefix: prefixBytes)
        let codeStart = pos
        pos += codeLen

        guard pos + 2 <= data.count else { return nil }
        let textLen = Int(data.readUInt16(at: pos)); pos += 2
        guard pos + textLen <= data.count else { return nil }
        let textStart = pos
        pos += textLen

        guard pos + 2 <= data.count else { return nil }
        let annoLen = Int(data.readUInt16(at: pos)); pos += 2
        guard pos + annoLen <= data.count else { return nil }
        let annoStart = pos
        pos += annoLen

        guard pos + 4 <= data.count else { return nil }
        let freq = Int(data.readInt32(at: pos)); pos += 4

        guard matched else { return pos }

        // freq 快筛：拼音路径（preferShorterCode=false）的堆决胜只看 freq（见 isBetterCandidate），
        // 堆已满且本条 freq 不高于堆顶时，即便构造出 Candidate 也会被 insert 原样丢弃 —— 直接跳过，
        // 省掉字符串分配。单字符前缀要扫 37 个桶共几万条，堆填满后绝大多数命中这一分支，首键从
        // 「几万次 String/Candidate 分配」降到「纯字节读 + 比较」，结果与逐条构造完全等价。
        // 码表路径（preferShorterCode=true）同 freq 还要比码长 / code 字序，不能只凭 freq 快筛，
        // 但那套决胜同样可以在原始字节上算完（见 losesToHeapTop）—— 形码一个两字母前缀下动辄上万条，
        // 不开这个口子就等于每条都先分配三个 String 再丢弃，开混打时被参与方案数量成倍放大。
        if heap.count >= limit, let worst = heap.first {
            if preferShorterCode {
                if losesToHeapTop(freq: freq, codeStart: codeStart,
                                  codeLen: codeLen, worst: worst) { return pos }
            } else if freq <= worst.freq {
                return pos
            }
        }

        guard let code = String(bytes: data[codeStart..<(codeStart + codeLen)], encoding: .utf8),
              let text = String(bytes: data[textStart..<(textStart + textLen)], encoding: .utf8) else {
            return pos
        }
        let annotation = annoLen > 0
            ? String(bytes: data[annoStart..<(annoStart + annoLen)], encoding: .utf8)
            : nil
        let candidate = Candidate(text: text, code: code, annotation: annotation,
                                  freq: freq, sourceSchemeId: "")
        insert(candidate: candidate, into: &heap, limit: limit,
               preferShorterCode: preferShorterCode)
        return pos
    }

    /// 码表快筛：本条记录是否「必然进不了堆」，可以不构造字符串就直接跳过
    ///
    /// 判定内容与 isBetterCandidate(preferShorterCode: true) 同序同调：词频高者胜 →
    /// 同词频码短者胜 → 仍同则 code 字序小者胜。两侧编码都是纯 ASCII 时，字节数就是
    /// String.count、字节字序就是 String 字序，所以这里比出来的结论与逐条构造后送进
    /// insert 的结论逐字一致（包括「与堆顶完全相同」那条 —— insert 本来也不会替换它）。
    /// 任一侧含非 ASCII（字节数与图群数不再相等）就判不了，返回 false 让调用方走原来的
    /// 逐条构造 —— 形码 / 拼音的编码列正常都是 ASCII 字母，这条退路几乎不会被踩到。
    private func losesToHeapTop(freq: Int, codeStart: Int, codeLen: Int,
                               worst: Candidate) -> Bool {
        // 第一层：词频不同就到此为止（高者胜，与码长 / 字序无关）
        if freq != worst.freq { return freq < worst.freq }
        // 同词频要比码长与字序，而这两样都只在「两侧编码都是纯 ASCII」时能由字节直接决定：
        // ASCII 下字节数 == 图群数、字节字序 == String 字序。任一字节≥ 0x80 就判不了，
        // 返回 false 退回逐条构造（形码 / 拼音的编码列正常都是 ASCII 字母，这条退路几乎不会被踩到）。
        var i = 0
        while i < codeLen {
            guard data[codeStart + i] < 0x80 else { return false }
            i += 1
        }
        let worstBytes = worst.code.utf8
        guard worstBytes.allSatisfy({ $0 < 0x80 }) else { return false }
        // 第二层：同词频码短者胜
        if codeLen != worstBytes.count { return codeLen > worstBytes.count }
        // 第三层：同词频同码长才轮到 code 字序，小者胜
        let worstArray = Array(worstBytes)
        for j in 0..<codeLen where data[codeStart + j] != worstArray[j] {
            return data[codeStart + j] > worstArray[j]
        }
        return true     // 与堆顶逐字相同：insert 本来也不会替换，跳过等价
    }

    /// 字节级前缀比较（UTF-8 是自同步编码，字节前缀等价于原有 String.hasPrefix）
    private func matchesPrefix(at offset: Int, length: Int, prefix: [UInt8]) -> Bool {
        guard length >= prefix.count else { return false }
        for i in 0..<prefix.count where data[offset + i] != prefix[i] {
            return false
        }
        return true
    }

    // MARK: - freq top-k（小顶堆，堆顶为已入选里 freq 最小的候选）

    private func insert(candidate: Candidate, into heap: inout [Candidate], limit: Int,
                        preferShorterCode: Bool = false) {
        if heap.count < limit {
            heap.append(candidate)
            if heap.count == limit {
                for i in stride(from: heap.count / 2 - 1, through: 0, by: -1) {
                    siftDown(&heap, index: i, preferShorterCode: preferShorterCode)
                }
            }
            return
        }
        guard let worst = heap.first,
              isBetterCandidate(candidate, than: worst, preferShorterCode: preferShorterCode) else { return }
        heap[0] = candidate
        siftDown(&heap, index: 0, preferShorterCode: preferShorterCode)
    }

    /// 候选优先级：a 是否比 b 更该留在 top-k 里。
    /// 词频高者优先；`preferShorterCode` 时同词频按码长短者、再按 code 字序决胜
    ///（码表全库词频恒定的场景，否则退化成扫描序、把简码常用字挤出候选）；
    /// 不开启时同词频保持原有行为（后来者不替换已在堆里的），拼音路径逐字节不变。
    private func isBetterCandidate(_ a: Candidate, than b: Candidate,
                                   preferShorterCode: Bool) -> Bool {
        if a.freq != b.freq { return a.freq > b.freq }
        guard preferShorterCode else { return false }
        if a.code.count != b.code.count { return a.code.count < b.code.count }
        return a.code < b.code
    }

    private func siftDown(_ heap: inout [Candidate], index: Int, preferShorterCode: Bool = false) {
        var parent = index
        while true {
            let left = parent * 2 + 1
            let right = left + 1
            var smallest = parent
            if left < heap.count,
               isBetterCandidate(heap[smallest], than: heap[left], preferShorterCode: preferShorterCode) {
                smallest = left
            }
            if right < heap.count,
               isBetterCandidate(heap[smallest], than: heap[right], preferShorterCode: preferShorterCode) {
                smallest = right
            }
            if smallest == parent { return }
            heap.swapAt(parent, smallest)
            parent = smallest
        }
    }

    public enum DictError: Error {
        case invalidFormat(String)
    }
}

// MARK: - Data 扩展：小端读取
// 不用 subdata 切片：subdata 每次都会分配一块新内存，而查询一个高频前缀要读上万个整数，
// 这点开销在「一次击键查好几条全拼前缀」时会被放大成秒级卡顿。
// 这里直接按字节拼接，结果与原实现完全一致。

extension Data {
    func readUInt32(at offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= count else { return 0 }
        return withUnsafeBytes { raw in
            let b = raw.bindMemory(to: UInt8.self)
            return UInt32(b[offset])
                | (UInt32(b[offset + 1]) << 8)
                | (UInt32(b[offset + 2]) << 16)
                | (UInt32(b[offset + 3]) << 24)
        }
    }

    func readUInt16(at offset: Int) -> UInt16 {
        guard offset >= 0, offset + 2 <= count else { return 0 }
        return withUnsafeBytes { raw in
            let b = raw.bindMemory(to: UInt8.self)
            return UInt16(b[offset]) | (UInt16(b[offset + 1]) << 8)
        }
    }

    func readInt32(at offset: Int) -> Int32 {
        Int32(bitPattern: readUInt32(at: offset))
    }
}
