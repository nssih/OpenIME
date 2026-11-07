import Foundation

// MARK: - 小鹤双拼模块：小鹤双拼编码引擎
//
// 小鹤双拼（flypy）规则速查：
//   每个音节固定两键 —— 第一键是声母键，第二键是韵母键
//   声母特殊键：zh = v、ch = i、sh = u
//   韵母键位表见 finalKeyMap（如 an = j、ang = h、ing = k、uang = l …）
//   零声母音节：a=aa、o=oo、e=ee；ai/ei/ao/ou/an/en 原样两键；ang=ah、eng=eg、er=er
//
// 该引擎把用户敲的「双拼码」还原成「全拼前缀」，供词库做前缀查询：
//   例：nihc 展开为 ["nihao"]（ni + hao）、vi 展开为 ["zhi"]、yc 展开为 ["yao"]、ah 展开为 ["ang"]
//
// 与词库码的关系：词库仍以全拼（如 nihao）编码，双拼只负责输入侧展开，
// 因此不需要改动词库格式，也不会影响原有 26 键全拼键盘。

/// 双拼键盘按键上的标注（声母 + 韵母）
public struct HeErKeyLabel: Equatable {
    /// 声母标注，仅在「键名与声母不同」时给出（v=zh、i=ch、u=sh）
    public let initial: String?
    /// 韵母标注，多个用 / 分隔，如 "ing/uai"、"ui/ü"
    public let finals: String

    public init(initial: String?, finals: String) {
        self.initial = initial
        self.finals = finals
    }
}

public final class HeErDoublePinyin {

    public static let shared = HeErDoublePinyin()

    /// 默认最多展开条数（一屏候选足够用，避免一次击键做太多前缀查询）
    public static let defaultMaxResults = 8

    // MARK: - 键位表

    /// 声母到键位的映射（zh / ch / sh 使用 v / i / u）
    public static let initialKeyMap: [String: Character] = [
        "zh": "v", "ch": "i", "sh": "u",
        "b": "b", "p": "p", "m": "m", "f": "f", "d": "d", "t": "t",
        "n": "n", "l": "l", "g": "g", "k": "k", "h": "h", "j": "j",
        "q": "q", "x": "x", "r": "r", "z": "z", "c": "c", "s": "s",
        "y": "y", "w": "w",
    ]

    /// 键位到声母的反查（键面标红用）：23 个声母键才有值，a / e / o 纯韵母键没有
    public static let keyInitials: [Character: String] = {
        var map: [Character: String] = [:]
        for (initial, key) in initialKeyMap { map[key] = initial }
        return map
    }()

    /// 韵母到键位的映射（ü 写作 v）
    public static let finalKeyMap: [String: Character] = [
        "a": "a", "o": "o", "e": "e", "i": "i", "u": "u", "v": "v",
        "ai": "d", "ei": "w", "ao": "c", "ou": "z", "an": "j", "en": "f",
        "ang": "h", "eng": "g", "er": "r",
        "ia": "x", "ie": "p", "iao": "n", "iu": "q", "ian": "m",
        "in": "b", "iang": "l", "ing": "k", "iong": "s",
        "ua": "x", "uo": "o", "uai": "k", "ui": "v", "uan": "r", "un": "y",
        "uang": "l", "ue": "t", "ong": "s",
        "ve": "t",
    ]

    /// 零声母音节的固定双键码
    public static let zeroInitialCodes: [String: String] = [
        "a": "aa", "o": "oo", "e": "ee",
        "ai": "ai", "ei": "ei", "ao": "ao", "ou": "ou", "an": "an", "en": "en",
        "ang": "ah", "eng": "eg", "er": "er",
    ]

    // MARK: - 索引

    /// 双拼码转全拼音节（如 "vi" 得到 ["zhi"]、"vv" 得到 ["zhui"]）
    public let syllablesByCode: [String: [String]]
    /// 每个字母键的声母 / 韵母标注
    public let keyLabels: [Character: HeErKeyLabel]

    private init() {
        var byCode: [String: [String]] = [:]
        var initialLabels: [Character: Set<String>] = [:]
        var finalLabels: [Character: Set<String>] = [:]

        for syllable in PinyinSyllables.all {
            guard let code = HeErDoublePinyin.code(for: syllable) else { continue }
            byCode[code, default: []].append(syllable)

            // 零声母码（aa / oo / ee / ai / ah / eg / er …）的键位不遵循「声母键+韵母键」规则，
            // 不参与键面标注统计，否则会把 ai / an 之类误算到字母键上
            guard HeErDoublePinyin.zeroInitialCodes[syllable] == nil,
                  let split = HeErDoublePinyin.split(syllable) else { continue }

            // 声母标注：仅当键名与声母不一致时记录（v=zh、i=ch、u=sh）
            let firstKey = code[code.startIndex]
            if !split.initial.isEmpty, String(firstKey) != split.initial {
                initialLabels[firstKey, default: []].insert(split.initial)
            }
            // 韵母标注
            let secondKey = code[code.index(after: code.startIndex)]
            finalLabels[secondKey, default: []].insert(HeErDoublePinyin.displayFinal(split.final))
        }

        // 零声母音节补充：只有当「零声母码的第二个键」恰好等于该韵母的常规键位时才补标注。
        // 典型例子：er 编为 "er"（第二键 r = finalKeyMap["er"]），否则键 r 上永远不会出现 er；
        // 而 ai / an / ao / ei / en / ou 的零声母码第二键与常规键位不同，不应计入键面标注。
        for (syllable, zeroCode) in HeErDoublePinyin.zeroInitialCodes where zeroCode.count == 2 {
            let secondKey = zeroCode[zeroCode.index(after: zeroCode.startIndex)]
            guard HeErDoublePinyin.finalKeyMap[syllable] == secondKey else { continue }
            finalLabels[secondKey, default: []].insert(HeErDoublePinyin.displayFinal(syllable))
        }

        self.syllablesByCode = byCode
        self.keyLabels = HeErDoublePinyin.buildLabels(initialLabels: initialLabels,
                                                      finalLabels: finalLabels)
    }

    // MARK: - 编码 / 解码

    /// 全拼音节转双拼码（不含零声母的细分规则差异，纯查表）
    public static func code(for syllable: String) -> String? {
        let lower = syllable.lowercased()
        if let zero = zeroInitialCodes[lower] { return zero }
        guard let split = split(lower),
              let initialKey = initialKeyMap[split.initial],
              let finalKey = finalKeyMap[split.final] else { return nil }
        return String(initialKey) + String(finalKey)
    }

    /// 把不带声调的音节切成 (声母, 韵母)，韵母 ü 统一写作 v
    public static func split(_ syllable: String) -> (initial: String, final: String)? {
        let lower = syllable.lowercased()
        // 声母表按长度倒序匹配，保证 zh / ch / sh 优先于 z / c / s
        for initial in HeErDoublePinyin.initialOrder {
            if lower.hasPrefix(initial) {
                let final = String(lower.dropFirst(initial.count))
                return final.isEmpty ? nil : (initial, final)
            }
        }
        // 零声母
        return ("", lower)
    }

    /// 韵母显示文本：把内部写法 v 还原成 ü
    public static func displayFinal(_ final: String) -> String {
        final.replacingOccurrences(of: "v", with: "ü")
    }

    // MARK: - 展开

    /// 双拼码展开成全拼前缀候选（最可能的排在前面）
    public func expand(_ code: String, maxResults: Int = HeErDoublePinyin.defaultMaxResults) -> [String] {
        guard maxResults > 0 else { return [] }
        let chars = Array(code.lowercased())
        guard !chars.isEmpty else { return [] }

        var results: [String] = [""]
        var index = 0
        while index < chars.count {
            let options: [String]
            if index + 1 < chars.count {
                let pair = String(chars[index]) + String(chars[index + 1])
                guard let syllables = syllablesByCode[pair], !syllables.isEmpty else { return [] }
                options = syllables
                index += 2
            } else {
                // 末尾只剩一个键：用户还没打完音节，按「可能的声母」给出前缀
                options = HeErDoublePinyin.partialInitials(for: chars[index])
                index += 1
            }
            results = HeErDoublePinyin.combine(results, options, cap: maxResults)
            if results.isEmpty { return [] }
        }
        return results
    }

    // MARK: - 内部工具

    /// 韵母键面标注的官方顺序（小鹤键位图，内部写法：ü 记作 v）。
    /// 只影响键帽上多韵母的显示先后，不影响任何编码映射。
    static let officialFinalOrder: [String] = [
        "iu", "ei", "e", "uan", "er", "ue", "ve", "un", "u", "i", "uo", "o", "ie",
        "a", "ong", "iong", "ai", "en", "eng", "ang", "an",
        "uai", "ing", "iang", "uang", "ou", "ia", "ua", "ao", "ui", "in",
        "iao", "ian",
    ]

    /// 韵母在官方顺序表中的下标（不在表内的排最后）
    private static func officialFinalRank(_ final: String) -> Int {
        officialFinalOrder.firstIndex(of: final) ?? officialFinalOrder.count
    }

    /// 声母表（长度倒序，保证 zh / ch / sh 优先匹配）
    static let initialOrder: [String] = [
        "zh", "ch", "sh",
        "b", "p", "m", "f", "d", "t", "n", "l", "g", "k", "h",
        "j", "q", "x", "r", "z", "c", "s", "y", "w",
    ]

    /// 末尾单键可代表的声母（v=zh、i=ch、u=sh，其余键名即声母）
    static func partialInitials(for key: Character) -> [String] {
        switch key {
        case "v": return ["zh"]
        case "i": return ["ch"]
        case "u": return ["sh"]
        default:  return [String(key)]
        }
    }

    /// 笛卡尔积合并，并裁剪到上限
    static func combine(_ left: [String], _ right: [String], cap: Int) -> [String] {
        var out: [String] = []
        out.reserveCapacity(Swift.min(left.count * right.count, cap))
        for prefix in left {
            for suffix in right {
                out.append(prefix + suffix)
                if out.count >= cap { return out }
            }
        }
        return out
    }

    /// 生成每个字母键的标注（声母 + 韵母）
    private static func buildLabels(initialLabels: [Character: Set<String>],
                                    finalLabels: [Character: Set<String>]) -> [Character: HeErKeyLabel] {
        var labels: [Character: HeErKeyLabel] = [:]
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz")
        for key in alphabet {
            let initial = initialLabels[key]?
                .sorted { $0 < $1 }
                .joined(separator: "/")
            // 韵母：按小鹤官方键位图顺序（如 K=uai/ing、S=ong/iong、V=ui/ü），
            // 表外韵母兜底排最后（长在前、同长按字母序）
            let finals = (finalLabels[key] ?? [])
                .sorted { lhs, rhs in
                    let lr = officialFinalRank(finalToInternal(lhs))
                    let rr = officialFinalRank(finalToInternal(rhs))
                    if lr != rr { return lr < rr }
                    if lhs.count != rhs.count { return lhs.count > rhs.count }
                    return lhs < rhs
                }
                .joined(separator: "/")
            labels[key] = HeErKeyLabel(initial: initial, finals: finals)
        }
        return labels
    }

    /// 显示文本还原成内部写法（ü 还原成 v），用于查官方顺序表
    private static func finalToInternal(_ display: String) -> String {
        display.replacingOccurrences(of: "ü", with: "v")
    }
}
