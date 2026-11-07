import Foundation

// 反查与码元提示模块：dict.extras.bin 侧车索引的只读访问。
// 侧车是可选文件，没有它就完全走老路，老词库一点不受影响。
// 这里只用 mmap 打开做读，不写、不加锁，重活都在编译期做完了。
public struct ExtrasIndex {

    // 文件头固定 32 字节，小端。magic 用来一眼认出是不是这个格式
    private static let magic: [UInt8] = [0x4F, 0x45, 0x58, 0x31]  // OEX1
    private static let headerSize = 32

    // 三个区各自的记录步长，定长是为了能直接二分，省掉偏移表
    private static let reverseStride = 64   // code[16] + reading[48]
    private static let elementStride = 44   // root[8] + key[4] + element[32]
    private static let abbrevStride  = 68   // prefix[16] + word[48] + freq[4]

    private let bytes: [UInt8]
    private let reverseCount: Int
    private let reverseOffset: Int
    private let elementCount: Int
    private let elementOffset: Int
    private let abbrevCount: Int
    private let abbrevOffset: Int

    // 侧车缺失或格式不对时，三个区都记成空，查询自然全返回空
    public var isEmpty: Bool {
        reverseCount == 0 && elementCount == 0 && abbrevCount == 0
    }

    public init(sidecar url: URL) {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              data.count >= Self.headerSize,
              [UInt8](data.prefix(4)) == Self.magic else {
            self.bytes = []
            self.reverseCount = 0; self.reverseOffset = 0
            self.elementCount = 0; self.elementOffset = 0
            self.abbrevCount = 0; self.abbrevOffset = 0
            return
        }
        let b = [UInt8](data)
        self.bytes = b
        self.reverseCount  = Int(Self.u32(b, 8))
        self.reverseOffset = Int(Self.u32(b, 12))
        self.elementCount  = Int(Self.u32(b, 16))
        self.elementOffset = Int(Self.u32(b, 20))
        self.abbrevCount   = Int(Self.u32(b, 24))
        self.abbrevOffset  = Int(Self.u32(b, 28))
    }

    // 编码查读音，一个编码可能对多个读音，按写入顺序返回
    public func reverseLookup(code: String) -> [String] {
        let key = Self.fixed(code, 16)
        var out: [String] = []
        for idx in Self.matches(bytes: bytes, offset: reverseOffset, count: reverseCount,
                                stride: Self.reverseStride, keyLen: 16, key: key) {
            let base = reverseOffset + idx * Self.reverseStride
            out.append(Self.cstring(bytes, base + 16, 48))
        }
        return out
    }

    // 字根查键位和码元，形码逐键提示用，没有就返回 nil
    public func elementHint(root: String) -> (key: String, element: String)? {
        let key = Self.fixed(root, 8)
        guard let idx = Self.matches(bytes: bytes, offset: elementOffset, count: elementCount,
                                     stride: Self.elementStride, keyLen: 8, key: key).first else { return nil }
        let base = elementOffset + idx * Self.elementStride
        return (Self.cstring(bytes, base + 8, 4), Self.cstring(bytes, base + 12, 32))
    }

    // 简码前缀查候选词，写入时已按 freq 降序排好，最多取 limit 条
    public func abbreviations(prefix: String, limit: Int) -> [(word: String, freq: Int)] {
        let key = Self.fixed(prefix, 16)
        var out: [(String, Int)] = []
        for idx in Self.matches(bytes: bytes, offset: abbrevOffset, count: abbrevCount,
                                stride: Self.abbrevStride, keyLen: 16, key: key) {
            let base = abbrevOffset + idx * Self.abbrevStride
            out.append((Self.cstring(bytes, base + 16, 48), Int(Self.u32(bytes, base + 64))))
            if out.count >= limit { break }
        }
        return out
    }

    // 定长键的二分 lower_bound 加相等键收集，记录已按键升序排好
    private static func matches(bytes: [UInt8], offset: Int, count: Int,
                                stride: Int, keyLen: Int, key: [UInt8]) -> [Int] {
        guard count > 0, !bytes.isEmpty else { return [] }
        var lo = 0, hi = count
        while lo < hi {
            let mid = (lo + hi) / 2
            let base = offset + mid * stride
            if compare(bytes, base, key, keyLen) < 0 { lo = mid + 1 } else { hi = mid }
        }
        var res: [Int] = []
        var i = lo
        while i < count {
            let base = offset + i * stride
            if compare(bytes, base, key, keyLen) != 0 { break }
            res.append(i)
            i += 1
        }
        return res
    }

    private static func compare(_ bytes: [UInt8], _ base: Int, _ key: [UInt8], _ len: Int) -> Int {
        for i in 0..<len {
            let a = bytes[base + i], b = key[i]
            if a != b { return a < b ? -1 : 1 }
        }
        return 0
    }

    private static func u32(_ b: [UInt8], _ at: Int) -> UInt32 {
        UInt32(b[at]) | UInt32(b[at + 1]) << 8 | UInt32(b[at + 2]) << 16 | UInt32(b[at + 3]) << 24
    }

    // 字符串转定长字节，按字符边界截断，不够补零，避免把多字节字符切坏
    static func fixed(_ s: String, _ n: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: n)
        var i = 0
        outer: for ch in s {
            for b in String(ch).utf8 {
                if i >= n { break outer }
                out[i] = b
                i += 1
            }
        }
        return out
    }

    private static func cstring(_ b: [UInt8], _ at: Int, _ len: Int) -> String {
        var buf: [UInt8] = []
        for i in 0..<len {
            let v = b[at + i]
            if v == 0 { break }
            buf.append(v)
        }
        return String(decoding: buf, as: UTF8.self)
    }
}
