import Foundation

// 反查与码元提示模块：方案包里可选的附加表。
// 三个字段都可有可无，老方案包不写就完全走老路，解码不会失败。
public struct SchemeExtras: Codable, Equatable {
    public var reverse: [ReverseEntry]?
    public var elements: [ElementEntry]?
    public var abbreviations: [AbbrevEntry]?

    public init(reverse: [ReverseEntry]? = nil,
                elements: [ElementEntry]? = nil,
                abbreviations: [AbbrevEntry]? = nil) {
        self.reverse = reverse
        self.elements = elements
        self.abbreviations = abbreviations
    }
}

// 编码到读音的反查条目。形码方案打不出字时用拼音反查编码，反过来也行
public struct ReverseEntry: Codable, Equatable {
    public var code: String
    public var reading: String
    public init(code: String, reading: String) {
        self.code = code
        self.reading = reading
    }
}

// 字根到键位和码元的提示条目，形码逐键提示用
public struct ElementEntry: Codable, Equatable {
    public var root: String
    public var key: String
    public var element: String
    public init(root: String, key: String, element: String) {
        self.root = root
        self.key = key
        self.element = element
    }
}

// 简码条目，前缀码到词，带词频用来排序
public struct AbbrevEntry: Codable, Equatable {
    public var prefix: String
    public var word: String
    public var freq: Int
    public init(prefix: String, word: String, freq: Int) {
        self.prefix = prefix
        self.word = word
        self.freq = freq
    }
}
