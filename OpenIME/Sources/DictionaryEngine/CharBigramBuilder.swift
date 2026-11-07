import Foundation

// MARK: - 字级二元语法构建（编译期）
//
// 把词库里的多字词扫一遍，统计「相邻两字」的搭配次数（用词频当权重），写成 CharBigram 能读的侧车。
// 这一步放在编译期，运行期只做只读二分；没有任何多字词时直接删掉侧车，等于回到没有二元语法的老行为。
// 写盘走「临时文件 + 原子替换」，替换瞬间键盘扩展即使正 mmap 着旧文件也不受影响。

enum CharBigramBuilder {

    static func build(from entries: [(text: String, freq: Int)], to url: URL) throws {
        var totalFreq: UInt64 = 0
        var pairCounts: [UInt64: UInt64] = [:]     // (前字码点<<32 | 后字码点) -> 累计词频
        var charTotal: [UInt32: UInt64] = [:]      // 前字码点 -> 它作为搭配前字时的总计数
        var charSet = Set<UInt32>()                // 出现在任意搭配里的字（前字或后字都要能被查到）

        for entry in entries {
            let weight = UInt64(max(entry.freq, 0))
            totalFreq = totalFreq &+ weight
            let scalars = Array(entry.text.unicodeScalars)
            guard scalars.count >= 2 else { continue }   // 单字词贡献不出相邻搭配
            for i in 0..<(scalars.count - 1) {
                let a = scalars[i].value
                let b = scalars[i + 1].value
                let key = (UInt64(a) << 32) | UInt64(b)
                pairCounts[key, default: 0] = pairCounts[key, default: 0] &+ weight
                charTotal[a, default: 0] = charTotal[a, default: 0] &+ weight
                charSet.insert(a)
                charSet.insert(b)
            }
        }

        // 一个多字词都没有：删掉旧侧车（如果存在），让读者走「空表」分支
        guard !charSet.isEmpty else {
            try? FileManager.default.removeItem(at: url)
            return
        }

        // 字表升序，字 -> 下标；下标用 UInt32，字表再大也放得下（Unicode 码点本就不超过 21 位）
        let chars = charSet.sorted()
        var indexOf: [UInt32: UInt32] = [:]
        indexOf.reserveCapacity(chars.count)
        for (idx, scalar) in chars.enumerated() {
            indexOf[scalar] = UInt32(idx)
        }

        // 搭配表按 (aIdx,bIdx) 升序，正好满足读侧的二分前提
        var records: [(aIdx: UInt32, bIdx: UInt32, count: UInt32)] = []
        records.reserveCapacity(pairCounts.count)
        for (key, count) in pairCounts {
            let a = UInt32(truncatingIfNeeded: key >> 32)
            let b = UInt32(truncatingIfNeeded: key & 0xFFFF_FFFF)
            guard let aIdx = indexOf[a], let bIdx = indexOf[b] else { continue }
            // 计数饱和到 UInt32：极高频搭配封顶，反正读侧还要取 log，封顶对排序毫无影响
            records.append((aIdx: aIdx, bIdx: bIdx, count: UInt32(clamping: count)))
        }
        records.sort { lhs, rhs in
            lhs.aIdx != rhs.aIdx ? lhs.aIdx < rhs.aIdx : lhs.bIdx < rhs.bIdx
        }

        let charTableOffset = 40
        let charTotalOffset = charTableOffset + chars.count * 4
        let pairTableOffset = charTotalOffset + chars.count * 4

        var out = Data(capacity: pairTableOffset + records.count * 12)
        // 头部 40 字节（version / flags 各 2 字节，务必与读侧的字段宽度一致，否则整体错位）
        out.append(contentsOf: CharBigram.magicBytes)
        out.append(contentsOf: putU16(1))          // version
        out.append(contentsOf: putU16(0))          // flags
        out.append(putU64(totalFreq))
        out.append(contentsOf: putU32(UInt32(clamping: chars.count)))
        out.append(contentsOf: putU32(UInt32(clamping: records.count)))
        out.append(contentsOf: putU32(UInt32(charTableOffset)))
        out.append(contentsOf: putU32(UInt32(pairTableOffset)))
        out.append(contentsOf: putU32(UInt32(charTotalOffset)))
        out.append(contentsOf: putU32(0))          // reserved

        // CharTable：升序码点
        for scalar in chars {
            out.append(contentsOf: putU32(scalar))
        }
        // CharTotal：与字表同序，每个字作为前字的总计数（只出现在后字位置的字这里是 0）
        for scalar in chars {
            out.append(contentsOf: putU32(UInt32(clamping: charTotal[scalar] ?? 0)))
        }
        // PairTable
        for record in records {
            out.append(contentsOf: putU32(record.aIdx))
            out.append(contentsOf: putU32(record.bIdx))
            out.append(contentsOf: putU32(record.count))
        }

        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent(url.lastPathComponent + ".building")
        try out.write(to: tmp, options: .atomic)
        _ = try? FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: tmp, to: url)
    }

    private static func putU16(_ value: UInt16) -> [UInt8] {
        var v = value.littleEndian
        return withUnsafeBytes(of: &v) { Array($0) }
    }

    private static func putU32(_ value: UInt32) -> [UInt8] {
        var v = value.littleEndian
        return withUnsafeBytes(of: &v) { Array($0) }
    }

    private static func putU64(_ value: UInt64) -> Data {
        var v = value.littleEndian
        return withUnsafeBytes(of: &v) { Data($0) }
    }
}
