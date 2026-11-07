import Foundation

// MARK: - 通用词频语料（编译期流式读取，零词频码表专用）
//
// 为什么单独成型：形码 / 音形码码表（如超强快码 cqkm）常全库 weight 恒定、词频零区分度，
// 运行时 top-N 退化成按编码字母序，常用字词被大量长码冷门词挤出候选。单字有内置的
// CharFrequency（8105 字）补齐，但多字词组需要一份「真实词频」——项目里已随包的雾凇
// base.dict.yaml（55 万词，来源 THUOCL + 现代汉语常用词表 + 腾讯词向量）就是现成的高质量语料，
// 收录量优于外部格式预设词频（约 8.8 万）。
//
// 设计底线（小内存 / 高效率）：
// 1. 绝不把 16 MB 的语料整份读进内存——用 FileHandle 分块流式扫描，逐行处理；
// 2. 只保留「当前正在编译的方案里出现过的多字词」的词频（needed 集合），未命中直接丢弃，
//    内存占用受方案自身词条数约束（cqkm ≤ 8.8 万），编译结束即释放；
// 3. 只在主 App 的编译路径调用（键盘扩展从不编译），任何异常都安全降级为空字典，绝不中断编译。
//
// 列映射沿用外部格式约定：优先按 front matter 的 columns 声明定位 text / weight 列，
// 没声明时按默认序 text(0) / code(1) / weight(2)——禁止按列位置硬假设（各词库 columns 顺序不同）。

public enum WordFrequencyCorpus {

    /// 分块读取的块大小（1 MB）：够大以减少系统调用，够小以不常驻大缓冲
    private static let chunkSize = 1 << 20

    /// 流式扫描语料词库，只为 `needed` 里的多字词返回真实词频（同词多条取最大）。
    ///
    /// - Parameters:
    ///   - needed: 当前方案里出现的多字词集合；空集合直接返回空（不必扫文件）
    ///   - url: 语料 .dict.yaml 路径；读不到 / 无 weight 列时返回空字典
    /// - Returns: `词 -> 词频`，仅含 needed 命中的词
    public static func loadFrequencies(needed: Set<String>, from url: URL) -> [String: Int] {
        guard !needed.isEmpty, let handle = try? FileHandle(forReadingFrom: url) else { return [:] }
        defer { try? handle.close() }

        var result: [String: Int] = [:]
        var columns: [String] = []
        var inColumnsBlock = false
        var inData = false
        var textIdx = 0
        var weightIdx = 2

        // 逐行状态机：头部区找 columns 声明与 `...` 数据标记，数据区按列名取值
        func processLine(_ raw: String) {
            let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if !inData {
                if trimmed == "..." {
                    // 头部结束：定下 text / weight 列下标（无 columns 声明走默认序）
                    if !columns.isEmpty {
                        textIdx = columns.firstIndex(of: "text") ?? 0
                        weightIdx = columns.firstIndex(of: "weight") ?? -1
                    } else {
                        textIdx = 0
                        weightIdx = 2
                    }
                    inData = true
                    return
                }
                if trimmed == "columns:" { inColumnsBlock = true; return }
                if inColumnsBlock {
                    if trimmed.hasPrefix("-") {
                        let col = trimmed.dropFirst().trimmingCharacters(in: .whitespaces)
                        if !col.isEmpty { columns.append(col) }
                    } else if !trimmed.isEmpty, !trimmed.hasPrefix("#") {
                        inColumnsBlock = false   // 缩进块结束
                    }
                }
                return
            }

            // 数据区：跳过空行与注释行；只收多字词，且只留 needed 命中的
            if trimmed.isEmpty || trimmed.hasPrefix("#") { return }
            guard weightIdx >= 0 else { return }
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard parts.count > max(textIdx, weightIdx) else { return }
            let text = String(parts[textIdx])
            guard text.count > 1, needed.contains(text) else { return }
            guard let weight = Int(parts[weightIdx].trimmingCharacters(in: .whitespaces)) else { return }
            if let existing = result[text] {
                if weight > existing { result[text] = weight }
            } else {
                result[text] = weight
            }
        }

        // 分块读 + 按换行切分：跨块的多字节 UTF-8 字符靠「只解码到 0x0A 为止的完整行」保证不截坏
        //（0x0A 不会出现在任何多字节序列内部），残行留在 buffer 里拼下一块
        var buffer = Data()
        while let chunk = try? handle.read(upToCount: chunkSize), !chunk.isEmpty {
            buffer.append(chunk)
            var start = buffer.startIndex
            while let nl = buffer[start...].firstIndex(of: 0x0A) {
                if let line = String(data: buffer[start..<nl], encoding: .utf8) { processLine(line) }
                start = buffer.index(after: nl)
            }
            buffer.removeSubrange(buffer.startIndex..<start)
        }
        if !buffer.isEmpty, let tail = String(data: buffer, encoding: .utf8) { processLine(tail) }
        return result
    }
}
