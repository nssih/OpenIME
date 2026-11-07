import Foundation

// MARK: - 外部方案（*.schema.yaml）解析
//
// OpenIME 自己的 schema.yaml 是扁平的 key: value，现有的 YAMLSchemaParser 一路扫下来就够；
// 但外部格式的 schema 是真正的嵌套结构（speller/alphabet、translator/enable_sentence…），
// 扁平扫描会把深层的键全捞到同一层，`dictionary` 到底属于 translator 还是 reverse_lookup 都分不清。
// 这里补一个只支持「够用子集」的缩进式 YAML 读取器，把需要的路径读准。
//
// 支持的子集：嵌套映射、块序列、行内 [a, b] / {k: v}、单双引号、块标量（| 与 >）、行尾注释。
// 一律忽略的：文档标记（--- / ... / %YAML）、锚点与别名（&x / *x / <<:）、`__include` / `__patch`。
// 忽略而不报错是刻意的 —— 第三方方案里满是 OpenIME 用不上的字段，
// 因为读不懂一个锚点就整包拒装，比少读一个字段糟糕得多。

/// 缩进式 YAML 的解析结果
public indirect enum YAMLNode {
    case null
    case scalar(String)
    case map([(key: String, value: YAMLNode)])
    case sequence([YAMLNode])

    /// 取子节点。用数组而不是字典存键是为了保留声明顺序（调试时读得懂），
    /// 一个 schema 只有几十个键，线性查找比建字典更省
    public subscript(key: String) -> YAMLNode? {
        guard case .map(let pairs) = self else { return nil }
        return pairs.first { $0.key == key }?.value
    }

    /// 依次按路径下钻，任何一层缺失都返回 nil
    public subscript(path: [String]) -> YAMLNode? {
        var node: YAMLNode? = self
        for key in path { node = node?[key] }
        return node
    }

    public var stringValue: String? {
        guard case .scalar(let s) = self else { return nil }
        return s
    }

    public var intValue: Int? { stringValue.flatMap { Int($0) } }

    public var doubleValue: Double? { stringValue.flatMap { Double($0) } }

    /// YAML 的真假值写法五花八门（true/True/yes/on/1），全认
    public var boolValue: Bool? {
        guard let s = stringValue?.lowercased() else { return nil }
        switch s {
        case "true", "yes", "on", "1":  return true
        case "false", "no", "off", "0": return false
        default:                        return nil
        }
    }

    /// 序列里的标量项。`initials` 既可以写成 'abcdef' 一个字符串，也可以写成列表，两种都收
    public var stringList: [String] {
        switch self {
        case .sequence(let items):
            return items.compactMap { $0.stringValue }.filter { !$0.isEmpty }
        case .scalar(let s):
            // 单个字符串：外部格式的 alphabet/initials 就是这么写的，按字符拆开没有意义，整串返回
            return s.isEmpty ? [] : [s]
        default:
            return []
        }
    }
}

public enum MiniYAML {

    /// 解析一段 YAML 文本。任何输入都不抛错：读不出结构就返回 .null
    public static func parse(_ content: String) -> YAMLNode {
        var lines = prepare(content)
        guard !lines.isEmpty else { return .null }
        var index = 0
        return parseBlock(&lines, index: &index, indent: lines[0].indent) ?? .null
    }

    // MARK: 行预处理

    private struct Line {
        var indent: Int
        var text: String     // 已去掉缩进、行尾注释，且不为空
    }

    private static func prepare(_ content: String) -> [Line] {
        var result: [Line] = []
        var blockScalar: (indent: Int, fold: Bool, lines: [String])?

        for raw in content.components(separatedBy: "\n") {
            let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw

            // 块标量（description: | 那种）：整段原样收下，不做注释剥离也不看键值
            if var pending = blockScalar {
                let indent = leadingIndent(line)
                if line.trimmingCharacters(in: .whitespaces).isEmpty {
                    pending.lines.append("")
                    blockScalar = pending
                    continue
                }
                if indent > pending.indent {
                    pending.lines.append(String(line.dropFirst(min(indent, line.count))))
                    blockScalar = pending
                    continue
                }
                result.append(Line(indent: pending.indent + 1,
                                   text: "\"" + pending.lines.joined(separator: pending.fold ? " " : "\n")
                                        .replacingOccurrences(of: "\"", with: "\\\"") + "\""))
                blockScalar = nil
            }

            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            if trimmed == "---" || trimmed == "..." || trimmed.hasPrefix("%") { continue }

            let indent = leadingIndent(line)
            let body = stripComment(trimmed)
            if body.isEmpty { continue }

            if body.hasSuffix("|") || body.hasSuffix(">")
                || body.hasSuffix("|-") || body.hasSuffix(">-")
                || body.hasSuffix("|+") || body.hasSuffix(">+") {
                blockScalar = (indent, body.hasSuffix(">") || body.hasSuffix(">-") || body.hasSuffix(">+"), [])
                // 键本身还要作为普通映射项收下，值随后由块标量补上
                let key = String(body.dropLast(body.hasSuffix("-") || body.hasSuffix("+") ? 2 : 1))
                    .trimmingCharacters(in: .whitespaces)
                result.append(Line(indent: indent, text: key))
                continue
            }
            result.append(Line(indent: indent, text: body))
        }

        if let pending = blockScalar {
            result.append(Line(indent: pending.indent + 1,
                               text: "\"" + pending.lines.joined(separator: "\n")
                                    .replacingOccurrences(of: "\"", with: "\\\"") + "\""))
        }
        return result
    }

    private static func leadingIndent(_ line: String) -> Int {
        line.prefix(while: { $0 == " " || $0 == "\t" }).count
    }

    /// 去掉行尾注释。引号里的 # 不算注释（`xform/^#(.*)/#/` 这类规则里满是 #）
    private static func stripComment(_ s: String) -> String {
        var inSingle = false, inDouble = false
        var depth = 0
        var cut: String.Index?
        var previous: Character = " "
        for (i, c) in s.enumerated() {
            switch c {
            case "'" where !inDouble:   inSingle.toggle()
            case "\"" where !inSingle:  inDouble.toggle()
            case "[", "{":              if !inSingle && !inDouble { depth += 1 }
            case "]", "}":              if !inSingle && !inDouble { depth = max(0, depth - 1) }
            case "#" where !inSingle && !inDouble && depth == 0:
                // 只有前面是空白（或就在行首）的 # 才是注释；`a#b` 是普通字符
                if i == 0 || previous == " " || previous == "\t" { cut = s.index(s.startIndex, offsetBy: i); }
            default: break
            }
            if cut != nil { break }
            previous = c
        }
        guard let cut else { return s.trimmingCharacters(in: .whitespaces) }
        return String(s[s.startIndex..<cut]).trimmingCharacters(in: .whitespaces)
    }

    // MARK: 递归下降

    private static func isSequenceItem(_ text: String) -> Bool {
        text == "-" || text.hasPrefix("- ")
    }

    /// 解析同一缩进层级上的一整块（可能是映射，也可能是序列）
    private static func parseBlock(_ lines: inout [Line], index: inout Int, indent: Int) -> YAMLNode? {
        guard index < lines.count, lines[index].indent == indent else { return nil }
        let text = lines[index].text
        if isSequenceItem(text) {
            return parseSequence(&lines, index: &index, indent: indent)
        }
        // 不是 key: value 就当成一个纯量值 —— 块标量（description: | 那段）在预处理时
        // 已经被压成紧随键后的一行引号字符串，走到这里
        if splitKeyValue(text) == nil {
            index += 1
            return .scalar(unquote(text))
        }
        return parseMap(&lines, index: &index, indent: indent)
    }

    private static func parseMap(_ lines: inout [Line], index: inout Int, indent: Int) -> YAMLNode {
        var pairs: [(key: String, value: YAMLNode)] = []
        while index < lines.count, lines[index].indent == indent,
              !isSequenceItem(lines[index].text) {
            let text = lines[index].text
            index += 1

            guard let (key, rest) = splitKeyValue(text) else { continue }
            // 合并键与包含指令：OpenIME 不解析这些，直接丢掉
            if key == "<<" || key.hasPrefix("__") { continue }

            if !rest.isEmpty {
                pairs.append((key, parseValue(rest)))
                continue
            }
            // 值在下一行更深的缩进里（也可能是块标量，预处理时已经塞成紧随其后的一个更深缩进的伪行）
            if index < lines.count, lines[index].indent > indent {
                let child = parseBlock(&lines, index: &index, indent: lines[index].indent)
                pairs.append((key, child ?? .null))
            } else {
                pairs.append((key, .null))
            }
        }
        return .map(pairs)
    }

    private static func parseSequence(_ lines: inout [Line], index: inout Int, indent: Int) -> YAMLNode {
        var items: [YAMLNode] = []
        while index < lines.count, lines[index].indent == indent,
              isSequenceItem(lines[index].text) {
            let text = lines[index].text
            let rest = String(text.dropFirst()).trimmingCharacters(in: .whitespaces)
            // 列表项内容在原始行里的起始列：`- name: x` 的 name 落在缩进 + 2 处，
            // 同一个列表项的后续键也写在同一列上，把这一行改写成缩进更深的映射行即可复用 parseMap
            let contentIndent = indent + (text.count - rest.count)

            if rest.isEmpty {
                index += 1
                if index < lines.count, lines[index].indent > indent {
                    items.append(parseBlock(&lines, index: &index, indent: lines[index].indent) ?? .null)
                } else {
                    items.append(.null)
                }
                continue
            }

            if splitKeyValue(rest) != nil {
                lines[index] = Line(indent: contentIndent, text: rest)
                items.append(parseMap(&lines, index: &index, indent: contentIndent))
                continue
            }

            index += 1
            items.append(parseValue(rest))
        }
        return .sequence(items)
    }

    /// 把一个标量或行内集合解析成节点
    private static func parseValue(_ text: String) -> YAMLNode {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return .null }
        // 别名与锚点：不解析引用，当成空值（OpenIME 用不到这些字段）
        if trimmed.hasPrefix("*") { return .null }
        let withoutAnchor = trimmed.hasPrefix("&")
            ? String(trimmed.drop(while: { $0 != " " }).dropFirst()).trimmingCharacters(in: .whitespaces)
            : trimmed
        if withoutAnchor.hasPrefix("[") && withoutAnchor.hasSuffix("]") {
            return .sequence(splitFlow(withoutAnchor).map { parseValue($0) })
        }
        if withoutAnchor.hasPrefix("{") && withoutAnchor.hasSuffix("}") {
            let pairs = splitFlow(withoutAnchor).compactMap { item -> (key: String, value: YAMLNode)? in
                guard let (key, rest) = splitKeyValue(item) else { return nil }
                return (key, parseValue(rest))
            }
            return .map(pairs)
        }
        return .scalar(unquote(withoutAnchor))
    }

    /// 拆行内集合的内容（按顶层逗号切，尊重引号与嵌套括号）
    private static func splitFlow(_ text: String) -> [String] {
        let body = String(text.dropFirst().dropLast())
        var items: [String] = []
        var current = ""
        var inSingle = false, inDouble = false, depth = 0
        for c in body {
            switch c {
            case "'" where !inDouble:  inSingle.toggle(); current.append(c)
            case "\"" where !inSingle: inDouble.toggle(); current.append(c)
            case "[" where !inSingle && !inDouble: depth += 1; current.append(c)
            case "{" where !inSingle && !inDouble: depth += 1; current.append(c)
            case "]" where !inSingle && !inDouble: depth -= 1; current.append(c)
            case "}" where !inSingle && !inDouble: depth -= 1; current.append(c)
            case "," where !inSingle && !inDouble && depth == 0:
                items.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            default: current.append(c)
            }
        }
        let tail = current.trimmingCharacters(in: .whitespaces)
        if !tail.isEmpty { items.append(tail) }
        return items
    }

    /// 在第一个「不在引号/括号里、后面跟着空白或行尾」的冒号处切开
    private static func splitKeyValue(_ text: String) -> (key: String, value: String)? {
        var inSingle = false, inDouble = false, depth = 0
        for i in text.indices {
            let c = text[i]
            switch c {
            case "'" where !inDouble:  inSingle.toggle()
            case "\"" where !inSingle: inDouble.toggle()
            case "[" where !inSingle && !inDouble: depth += 1
            case "{" where !inSingle && !inDouble: depth += 1
            case "]" where !inSingle && !inDouble: depth -= 1
            case "}" where !inSingle && !inDouble: depth -= 1
            case ":" where !inSingle && !inDouble && depth == 0:
                let next = text.index(after: i)
                guard next == text.endIndex || text[next] == " " || text[next] == "\t" else { continue }
                let key = String(text[text.startIndex..<i]).trimmingCharacters(in: .whitespaces)
                guard !key.isEmpty else { return nil }
                return (unquote(key), String(text[next...]).trimmingCharacters(in: .whitespaces))
            default: break
            }
        }
        return nil
    }

    private static func unquote(_ s: String) -> String {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2 else { return trimmed }
        let first = trimmed.first!
        let last = trimmed.last!
        guard (first == "\"" && last == "\"") || (first == "'" && last == "'") else { return trimmed }
        let body = String(trimmed.dropFirst().dropLast())
        return first == "\"" ? body.replacingOccurrences(of: "\\\"", with: "\"") : body
    }
}

// MARK: - 外部 schema 的取值结果

/// 一份外部 schema 里 OpenIME 关心的字段
///
/// 只取用得到的路径，其余一概不碰。全部 Optional：字段缺失时由 SchemeProfile 回落到默认值，
/// 绝不因为方案没写某一项就推断失败。
public struct ImportedSchema {
    public var schemaId: String?
    public var name: String?
    /// speller/alphabet：本方案认哪些键。形码方案常带 `;` `'` 这类引导键
    public var alphabet: String?
    /// speller/delimiter：编码分隔符
    public var delimiter: String?
    public var maxCodeLength: Int?
    /// speller/auto_select（布尔）与 auto_select_pattern（正则）在外部格式里是两件事，都留着
    public var autoSelect: Bool?
    public var autoSelectPattern: String?
    /// speller/auto_clear：manual | auto | max_length
    public var autoClear: String?
    public var initials: [String] = []
    public var finals: [String] = []
    public var algebra: [String] = []
    /// translator/dictionary：主码表名
    public var dictionary: String?
    public var maxPhraseLength: Int?
    public var enableSentence: Bool?
    public var enableEncoder: Bool?
    public var initialQuality: Double?

    public init() {}
}

public enum SchemaParser {

    public static func parse(_ content: String) -> ImportedSchema {
        let root = MiniYAML.parse(content)
        var schema = ImportedSchema()

        let schemaNode = root["schema"]
        schema.schemaId = schemaNode?["schema_id"]?.stringValue
        schema.name = schemaNode?["name"]?.stringValue

        if let speller = root["speller"] {
            schema.alphabet = speller["alphabet"]?.stringValue
            schema.delimiter = speller["delimiter"]?.stringValue
            schema.maxCodeLength = speller["max_code_length"]?.intValue
            schema.autoSelect = speller["auto_select"]?.boolValue
            schema.autoSelectPattern = speller["auto_select_pattern"]?.stringValue
            schema.autoClear = speller["auto_clear"]?.stringValue
            schema.initials = speller["initials"]?.stringList ?? []
            schema.finals = speller["finals"]?.stringList ?? []
            schema.algebra = speller["algebra"]?.stringList ?? []
        }

        if let translator = root["translator"] {
            schema.dictionary = translator["dictionary"]?.stringValue
            schema.maxPhraseLength = translator["max_phrase_length"]?.intValue
            schema.enableSentence = translator["enable_sentence"]?.boolValue
            schema.enableEncoder = translator["enable_encoder"]?.boolValue
            schema.initialQuality = translator["initial_quality"]?.doubleValue
        }
        return schema
    }
}
