import Foundation

// 反查与码元提示模块：把可选的 extras 编成 dict.extras.bin 侧车。
// 编译期一次性做完，运行期只读。没有 extras 就删掉侧车，等于回到老行为。
enum ExtrasIndexBuilder {

    static func build(extras: SchemeExtras?, to url: URL) throws {
        let rev = extras?.reverse ?? []
        let ele = extras?.elements ?? []
        let abv = extras?.abbreviations ?? []
        guard !rev.isEmpty || !ele.isEmpty || !abv.isEmpty else {
            try? FileManager.default.removeItem(at: url)
            return
        }

        let revBytes = encodeReverse(rev)
        let eleBytes = encodeElements(ele)
        let abvBytes = encodeAbbrev(abv)

        let revOff = 32
        let eleOff = revOff + revBytes.count
        let abvOff = eleOff + eleBytes.count

        var out = Data(count: 32)
        out[0] = 0x4F; out[1] = 0x45; out[2] = 0x58; out[3] = 0x31
        putU32(&out, 4, 1)
        putU32(&out, 8, UInt32(rev.count))
        putU32(&out, 12, UInt32(revOff))
        putU32(&out, 16, UInt32(ele.count))
        putU32(&out, 20, UInt32(eleOff))
        putU32(&out, 24, UInt32(abv.count))
        putU32(&out, 28, UInt32(abvOff))
        out.append(revBytes)
        out.append(eleBytes)
        out.append(abvBytes)

        // 先写临时文件再原子换名，mmap 中的旧文件不受影响
        let tmp = url.appendingPathExtension("tmp")
        try out.write(to: tmp, options: .atomic)
        _ = try? FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: tmp, to: url)
    }

    // 排序按定长字节的字典序，和读侧的二分比较保持一致，不能用 String 的小于号
    private static func encodeReverse(_ list: [ReverseEntry]) -> Data {
        let sorted = list.sorted { a, b in
            let ka = ExtrasIndex.fixed(a.code, 16), kb = ExtrasIndex.fixed(b.code, 16)
            if ka != kb { return ka.lexicographicallyPrecedes(kb) }
            return ExtrasIndex.fixed(a.reading, 48).lexicographicallyPrecedes(ExtrasIndex.fixed(b.reading, 48))
        }
        var out = Data()
        for r in sorted {
            out.append(Data(ExtrasIndex.fixed(r.code, 16)))
            out.append(Data(ExtrasIndex.fixed(r.reading, 48)))
        }
        return out
    }

    private static func encodeElements(_ list: [ElementEntry]) -> Data {
        let sorted = list.sorted { a, b in
            let ka = ExtrasIndex.fixed(a.root, 8), kb = ExtrasIndex.fixed(b.root, 8)
            if ka != kb { return ka.lexicographicallyPrecedes(kb) }
            return ExtrasIndex.fixed(a.element, 32).lexicographicallyPrecedes(ExtrasIndex.fixed(b.element, 32))
        }
        var out = Data()
        for e in sorted {
            out.append(Data(ExtrasIndex.fixed(e.root, 8)))
            out.append(Data(ExtrasIndex.fixed(e.key, 4)))
            out.append(Data(ExtrasIndex.fixed(e.element, 32)))
        }
        return out
    }

    private static func encodeAbbrev(_ list: [AbbrevEntry]) -> Data {
        // 同前缀按 freq 降序，读侧顺序取 limit 条时高频在前
        let sorted = list.sorted { a, b in
            let ka = ExtrasIndex.fixed(a.prefix, 16), kb = ExtrasIndex.fixed(b.prefix, 16)
            if ka != kb { return ka.lexicographicallyPrecedes(kb) }
            if a.freq != b.freq { return a.freq > b.freq }
            return ExtrasIndex.fixed(a.word, 48).lexicographicallyPrecedes(ExtrasIndex.fixed(b.word, 48))
        }
        var out = Data()
        for a in sorted {
            out.append(Data(ExtrasIndex.fixed(a.prefix, 16)))
            out.append(Data(ExtrasIndex.fixed(a.word, 48)))
            out.append(Data(u32Bytes(UInt32(truncatingIfNeeded: a.freq))))
        }
        return out
    }

    private static func putU32(_ d: inout Data, _ at: Int, _ v: UInt32) {
        d[at] = UInt8(v & 0xFF)
        d[at + 1] = UInt8((v >> 8) & 0xFF)
        d[at + 2] = UInt8((v >> 16) & 0xFF)
        d[at + 3] = UInt8((v >> 24) & 0xFF)
    }

    private static func u32Bytes(_ v: UInt32) -> [UInt8] {
        [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]
    }
}
