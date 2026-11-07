import Foundation
import ZIPFoundation  // 需在 Package.swift 中添加依赖

// MARK: - 方案包安装器
// 负责 ZIP 导入、解压、校验、编译词库、安装

public final class PackageInstaller {

    public enum InstallError: Error, LocalizedError {
        case invalidZip
        case missingManifest
        case missingSchema
        case missingDictionary
        case invalidManifestFormat(String)
        case duplicateScheme(String)
        case compileFailed(String)

        public var errorDescription: String? {
            switch self {
            case .invalidZip:                  return "ZIP 文件损坏或格式不正确"
            case .missingManifest:             return "缺少 manifest.yaml"
            case .missingSchema:               return "缺少 schema.yaml"
            case .missingDictionary:           return "词库目录不存在或为空"
            case .invalidManifestFormat(let s): return "manifest.yaml 格式错误：\(s)"
            case .duplicateScheme(let id):     return "方案 \(id) 已安装，请先卸载"
            case .compileFailed(let s):        return "词库编译失败：\(s)"
            }
        }
    }

    public struct InstallResult {
        public let schemeId: String
        public let schemeName: String
        public let dictEntryCount: Int
        public let partialFailures: [String]

        public init(schemeId: String, schemeName: String, dictEntryCount: Int, partialFailures: [String] = []) {
            self.schemeId = schemeId
            self.schemeName = schemeName
            self.dictEntryCount = dictEntryCount
            self.partialFailures = partialFailures
        }
    }

    private let container = AppGroupContainer.shared
    private let fm = FileManager.default

    public init() {}

    // MARK: - 安装主流程
    // 支持三种格式：
    //   单方案：zip 根目录直接含 manifest.yaml
    //   多方案目录：zip 内含 schemes/ 目录，每个子目录是一个方案
    //   ZIP-in-ZIP：zip 根目录含若干 .zip 文件，每个子 zip 是一个方案

    public func install(zipURL: URL, overwrite: Bool = false, isBundled: Bool = false) async throws -> InstallResult {
        let tempDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fm.removeItem(at: tempDir) }

        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        try fm.unzipItem(at: zipURL, to: tempDir)

        // 1. 单方案：根目录直接有 manifest.yaml
        if fm.fileExists(atPath: tempDir.appendingPathComponent("manifest.yaml").path) {
            return try await installSchemeDir(tempDir, overwrite: overwrite, isBundled: isBundled)
        }

        // 2. 多方案目录：根目录有 schemes/ 子目录
        let schemesDir = tempDir.appendingPathComponent("schemes")
        if fm.fileExists(atPath: schemesDir.path) {
            let subDirs = (try? fm.contentsOfDirectory(at: schemesDir, includingPropertiesForKeys: [.isDirectoryKey]))
                .map { $0.filter { url in (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true } }
                ?? []
            guard !subDirs.isEmpty else { throw InstallError.missingManifest }
            return try await installMultipleDirs(subDirs, overwrite: overwrite, isBundled: isBundled)
        }

        // 3. ZIP-in-ZIP：根目录含 .zip 文件
        let rootItems = (try? fm.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil)) ?? []
        let nestedZips = rootItems.filter { $0.pathExtension.lowercased() == "zip" }
        if !nestedZips.isEmpty {
            var schemeDirs: [URL] = []
            for zipFile in nestedZips {
                let subTemp = tempDir.appendingPathComponent(zipFile.deletingPathExtension().lastPathComponent, isDirectory: true)
                try? fm.createDirectory(at: subTemp, withIntermediateDirectories: true)
                if (try? fm.unzipItem(at: zipFile, to: subTemp)) != nil {
                    schemeDirs.append(subTemp)
                }
            }
            guard !schemeDirs.isEmpty else { throw InstallError.missingManifest }
            return try await installMultipleDirs(schemeDirs, overwrite: overwrite, isBundled: isBundled)
        }

        // 4. 裸外部词库 ZIP：没有 manifest/schema，只有词库文件，合并为一个方案
        //    根目录的 *.yaml 与子目录里的 *.dict.yaml 都要收：雾凇拼音把词表放在 cn_dicts/ 下，
        //    主表只有一句 import_tables，不收子目录就等于装进来一个空壳
        let dictYAMLsInRoot = rootItems.filter {
            $0.lastPathComponent.hasSuffix(".dict.yaml") || $0.pathExtension == "yaml"
        }
        let nestedDictYAMLs = Self.nestedDictYAMLs(in: tempDir)
        if !dictYAMLsInRoot.isEmpty || !nestedDictYAMLs.isEmpty {
            let zipBaseName = zipURL.deletingPathExtension().lastPathComponent
            return try await installBareDictYAMLs(dictYAMLsInRoot + nestedDictYAMLs, root: tempDir,
                                                  zipName: zipBaseName,
                                                  overwrite: overwrite, isBundled: isBundled)
        }

        throw InstallError.missingManifest
    }

    /// 子目录里的 *.dict.yaml（相对 root 至少深一层），按路径排序
    ///
    /// 只认 `.dict.yaml` 后缀：子目录里的 symbols.yaml / key_bindings.yaml 不是词库，
    /// 收进来会被当成词条编出一堆垃圾
    private static func nestedDictYAMLs(in root: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        else { return [] }
        let rootPath = root.standardizedFileURL.path
        var result: [URL] = []
        for case let url as URL in enumerator {
            guard url.lastPathComponent.hasSuffix(".dict.yaml") else { continue }
            // 根目录那批调用方已经收过了
            if url.deletingLastPathComponent().standardizedFileURL.path == rootPath { continue }
            result.append(url)
        }
        return result.sorted { $0.path < $1.path }
    }

    /// url 相对 root 的路径（保留 cn_dicts/base.dict.yaml 这样的子目录层级）
    private static func relativePath(of url: URL, from root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPath) else { return url.lastPathComponent }
        var relative = String(path.dropFirst(rootPath.count))
        while relative.hasPrefix("/") { relative.removeFirst() }
        return relative.isEmpty ? url.lastPathComponent : relative
    }

    /// 去掉 .dict.yaml / .schema.yaml / .yaml 后缀，得到外部格式里的表名
    private static func dictBaseName(_ url: URL) -> String {
        let name = url.lastPathComponent
        for ext in [".dict.yaml", ".schema.yaml", ".yaml"] where name.lowercased().hasSuffix(ext) {
            return String(name.dropLast(ext.count))
        }
        return name
    }

    /// 读同批文件里的 *.schema.yaml。与词库同名的优先（tiger.schema.yaml 配 tiger.dict.yaml），
    /// 否则按文件名取第一份；读不出内容返回 nil，推断会退化到码表统计，不影响安装
    private static func loadImportedSchema(from schemaURLs: [URL], dictURLs: [URL]) -> ImportedSchema? {
        let sorted = schemaURLs.sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !sorted.isEmpty else { return nil }
        let dictNames = Set(dictURLs.map { dictBaseName($0) })
        let preferred = sorted.first { dictNames.contains(dictBaseName($0)) } ?? sorted[0]
        guard let content = try? String(contentsOf: preferred, encoding: .utf8) else { return nil }
        return SchemaParser.parse(content)
    }

    /// 抽样顺序：主码表在前（schema 的 translator/dictionary 指名道姓），其余按路径排。
    /// 主码表最能代表这个方案怎么打字，别让小表把统计带偏；最多读 4 份文件的开头
    private static func sampleOrder(mainDictionary: String?, dictURLs: [URL]) -> [URL] {
        let sorted = dictURLs.sorted { $0.path < $1.path }
        guard let main = mainDictionary, !main.isEmpty else { return Array(sorted.prefix(4)) }
        let mains = sorted.filter { dictBaseName($0) == main }
        return Array((mains + sorted.filter { !mains.contains($0) }).prefix(4))
    }

    /// 裸外部词库包：没有 manifest / schema，全部信息从词库与同批的 *.schema.yaml 里推
    private func installBareDictYAMLs(_ yamlURLs: [URL], root: URL, zipName: String,
                                     overwrite: Bool, isBundled: Bool) async throws -> InstallResult {
        // *.schema.yaml 不是词库，是这个方案的输入规则：择出来当推断依据，别当词条编进 dict.bin
        let schemaURLs = yamlURLs.filter { $0.lastPathComponent.hasSuffix(".schema.yaml") }
        let dictURLs = yamlURLs.filter { !$0.lastPathComponent.hasSuffix(".schema.yaml") }
        guard !dictURLs.isEmpty else { throw InstallError.missingDictionary }
        let importedSchema = Self.loadImportedSchema(from: schemaURLs, dictURLs: dictURLs)

        // 方案名：外部 schema 里的 schema/name 最准（就是给用户看的名字），
        // 没有再从词库 front matter 提，同时兼容外部格式与 OpenIME 单文件格式
        var schemeName = importedSchema?.name ?? ""
        if schemeName.isEmpty {
            for url in dictURLs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                if let content = try? String(contentsOf: url, encoding: .utf8) {
                    let fields = extractAnyFormatFields(content)
                    if let n = fields["name"], !n.isEmpty {
                        schemeName = n
                        break
                    }
                }
            }
        }
        if schemeName.isEmpty { schemeName = zipName }

        // 方案 id：优先用 schema_id（tiger / ice_pinyin 这种干净标识），
        // 没 schema 才把中文名转拼音（否则「虎码官方单字」会变成 hu-ma-guan-fang-dan-zi）
        let schemeId: String = {
            if let declared = importedSchema?.schemaId {
                let clean = declared.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "-" }
                if clean.contains(where: { $0.isLetter || $0.isNumber }) { return clean }
            }
            let raw = YAMLSingleFileImporter.pinyinId(from: schemeName)
            let clean = raw.filter { $0.isLetter || $0.isNumber || $0 == "-" }
            let hasAlphanumeric = clean.contains { $0.isLetter || $0.isNumber }
            return hasAlphanumeric ? clean : String(UUID().uuidString.prefix(8).lowercased())
        }()

        // 码制推断：抽样编码 + schema 特征，得出音码 / 形码 / 音形码与要不要去空格。
        // 抽样要顺着 import_tables 走到底：雾凇的 ice.dict.yaml 自己不装词，
        // 只抽它自己那几十行大写数字，会把一整个拼音方案判成形码、空格也不会去
        let sampledFiles = DictCompiler.expandImportTables(
            Self.sampleOrder(mainDictionary: importedSchema?.dictionary, dictURLs: dictURLs),
            resourceRoot: root).urls
        let codes = CodeSystemInference.sampleCodes(fromFiles: sampledFiles)
        let inference = CodeSystemInference.infer(schema: importedSchema, codes: codes)

        // 构建临时方案目录
        let tempDir = fm.temporaryDirectory
            .appendingPathComponent("bare_dict_\(schemeId)_\(UUID().uuidString.prefix(6))", isDirectory: true)
        defer { try? fm.removeItem(at: tempDir) }
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let manifestContent = "id: \(schemeId)\nname: \(schemeName)\nversion: 1.0.0\n"
        try manifestContent.write(to: tempDir.appendingPathComponent("manifest.yaml"),
                                  atomically: true, encoding: .utf8)
        try CodeSystemInference.schemaYAML(result: inference, schema: importedSchema)
            .write(to: tempDir.appendingPathComponent("schema.yaml"), atomically: true, encoding: .utf8)

        // 词库：保留原有子目录层级，import_tables 里的 `cn_dicts/base` 靠它才解得开。
        // 但根目录一张表都没有、只有子目录里有词库时（用户直接把 cn_dicts/ 打了包），
        // 层级没有意义反而会让编译扫不到文件（installSchemeDir 只看 dictionaries/ 第一层），这时摊平
        let hasRootDict = dictURLs.contains { Self.relativePath(of: $0, from: root) == $0.lastPathComponent }
        let dictDir = tempDir.appendingPathComponent("dictionaries", isDirectory: true)
        try fm.createDirectory(at: dictDir, withIntermediateDirectories: true)
        for url in dictURLs {
            let relative = hasRootDict ? Self.relativePath(of: url, from: root) : url.lastPathComponent
            let dest = dictDir.appendingPathComponent(relative)
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            // 摊平时不同子目录里的同名文件会撞上，留先到的那份（与重复合并的「首现胜出」一致）
            guard !fm.fileExists(atPath: dest.path) else { continue }
            try fm.copyItem(at: url, to: dest)
        }

        let result = try await installSchemeDir(tempDir, overwrite: overwrite, isBundled: isBundled)
        appendInferenceLog(schemeId: result.schemeId, inference: inference, schema: importedSchema,
                           sampledFiles: sampledFiles)
        return result
    }

    /// 把码制推断的依据追写到安装日志末尾（日志本体由 installSchemeDir 写）。
    /// 判错了用户得能自己看出为什么，否则只能看到「拼音库打不出字」而不知道去哪反馈
    private func appendInferenceLog(schemeId: String,
                                   inference: CodeSystemInference.Result,
                                   schema: ImportedSchema?,
                                   sampledFiles: [URL]) {
        let logFile = container.installLogsURL.appendingPathComponent("\(schemeId)_install_log.txt")
        guard fm.fileExists(atPath: logFile.path),
              let handle = try? FileHandle(forWritingTo: logFile) else { return }
        defer { try? handle.close() }
        var text = """

=== 码制推断 ===
判定结果：码制 \(inference.codeSystem.rawValue)，检索方式 \(inference.type.rawValue)
判定依据：\(inference.basis)
"""
        if inference.stripSpaces { text += "\n编码规范化：strip_spaces（词库里的空格是音节分隔符，编译时去掉）" }
        text += "\n抽样文件：\(sampledFiles.map { $0.lastPathComponent }.joined(separator: "、"))"
        if let schema {
            text += "\n外部 schema：\(schema.schemaId ?? "无")"
            if let max = schema.maxCodeLength { text += "，max_code_length=\(max)" }
            if let delimiter = schema.delimiter { text += "，delimiter=\(delimiter)" }
        } else {
            text += "\n外部 schema：同批文件里没有 *.schema.yaml"
        }
        text += "\n=== 推断结束 ===\n"
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(text.utf8))
    }

    // 兼容两种格式提取 header 字段：
    // - 外部格式：--- 到 ... 之间（或文件开头到 ...）
    // - OpenIME 单文件格式：--- 之前的行
    private func extractAnyFormatFields(_ content: String) -> [String: String] {
        var result: [String: String] = [:]
        let lines = content.components(separatedBy: .newlines)
        let hasDictEndMarker = content.contains("\n...\n") || content.hasSuffix("\n...") || content.hasSuffix("\n...\n")
        let hasDashSeparator = content.hasPrefix("---\n") || content.contains("\n---\n")
        let isOpenIMESingleFile = hasDashSeparator && !hasDictEndMarker

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "..." { break }
            // OpenIME 单文件：--- 是分隔符，--- 之后是词条，停止提取 header
            if trimmed == "---" && isOpenIMESingleFile { break }
            if trimmed == "---" || trimmed.hasPrefix("#") || trimmed.isEmpty { continue }
            if let colonIdx = trimmed.firstIndex(of: ":") {
                let key = String(trimmed[trimmed.startIndex..<colonIdx]).trimmingCharacters(in: .whitespaces)
                let val = String(trimmed[trimmed.index(after: colonIdx)...]).trimmingCharacters(in: .whitespaces)
                if !key.isEmpty { result[key] = val }
            }
        }
        return result
    }

    private func installMultipleDirs(_ dirs: [URL], overwrite: Bool, isBundled: Bool) async throws -> InstallResult {
        var firstResult: InstallResult?
        var failedNames: [String] = []
        for schemeDir in dirs {
            do {
                let result = try await installSchemeDir(schemeDir, overwrite: overwrite, isBundled: isBundled)
                if firstResult == nil { firstResult = result }
            } catch {
                let dirName = schemeDir.lastPathComponent
                failedNames.append("\(dirName): \(error.localizedDescription)")
            }
        }
        if let result = firstResult {
            if failedNames.isEmpty {
                return result
            } else {
                return InstallResult(
                    schemeId: result.schemeId,
                    schemeName: result.schemeName,
                    dictEntryCount: result.dictEntryCount,
                    partialFailures: failedNames
                )
            }
        }
        throw InstallError.compileFailed(failedNames.joined(separator: "\n"))
    }

    private func installSchemeDir(_ dir: URL, overwrite: Bool, isBundled: Bool = false) async throws -> InstallResult {
        var manifest = try parseManifest(in: dir)
        let installedDir = container.packageURL(for: manifest.id)
        if fm.fileExists(atPath: installedDir.path) && !overwrite {
            throw InstallError.duplicateScheme(manifest.id)
        }
        // 新包先搭在同一个 packages/ 下的暂存目录里，全部写成功后一步换过去：
        // 中途任何失败（编译报错、磁盘写满）都不会把用户正在用的旧包弄没。
        // 暂存目录名以 . 开头，installedSchemeIds() 会跳过它，即使泄漏也不会变成幽灵方案。
        let targetDir = container.packagesURL.appendingPathComponent(
            ".\(manifest.id)-staging-\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? fm.removeItem(at: targetDir) }

        let schema = try parseSchema(in: dir)
        let dictDir = dir.appendingPathComponent("dictionaries")
        guard fm.fileExists(atPath: dictDir.path) else { throw InstallError.missingDictionary }
        let dictYAMLs = try yamlFiles(in: dictDir)
        guard !dictYAMLs.isEmpty else { throw InstallError.missingDictionary }

        // 编译产物落可写的临时 scratch，绝不写回源目录：内置方案是直接编 App Bundle 里
        // 那个 .bundle 目录的（IMERuntime.installMissingBundled 走 installDir），而真机上包体
        // 受代码签名保护、写入必失败，模拟器却侥幸能写 —— 于是「内置方案一个都装不上」只在真机暴露。
        // dict.lm.bin 由 DictCompiler 写在 outputURL 的同级目录，两者必须一起进 scratch。
        let scratch = fm.temporaryDirectory.appendingPathComponent(
            "oime_compile_\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? fm.removeItem(at: scratch) }
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        let tempBin = scratch.appendingPathComponent("dict.bin")
        var discoveredColumns: Set<String> = []
        do {
            let (cols, report) = try DictCompiler.compileMultipleWithReport(
                yamlURLs: dictYAMLs,
                outputURL: tempBin,
                schemeType: schema.type,
                normalizeCode: schema.normalizeCode,
                resourceRoot: dir,
                wordFrequencyURL: Self.wordFrequencyCorpusURL
            )
            discoveredColumns = cols
            // 写 log 到 Documents/logs/ — Files.app 可见
            let logsDir = container.installLogsURL
            try? fm.createDirectory(at: logsDir, withIntermediateDirectories: true)
            let logFile = logsDir.appendingPathComponent("\(manifest.id)_install_log.txt")
            try? report.logText().write(to: logFile, atomically: true, encoding: .utf8)
        } catch {
            // 编译失败时也写 log，让用户知道原因
            let logsDir = container.installLogsURL
            try? fm.createDirectory(at: logsDir, withIntermediateDirectories: true)
            let failLogFile = logsDir.appendingPathComponent("\(manifest.id)_install_log.txt")
            let failText = """
=== OpenIME 词库编译日志 ===
编译结果：失败
方案 ID：\(manifest.id)
方案名称：\(manifest.name)

错误信息：
\(error.localizedDescription)

=== 日志结束 ===
"""
            try? failText.write(to: failLogFile, atomically: true, encoding: .utf8)
            throw InstallError.compileFailed(error.localizedDescription)
        }

        try fm.createDirectory(at: targetDir, withIntermediateDirectories: true)
        do {
            try fm.copyItem(at: tempBin, to: targetDir.appendingPathComponent("dict.bin"))
        } catch {
            throw InstallError.compileFailed(error.localizedDescription)
        }

        // 编译期顺带产出的侧车都写在 scratch 里，必须一并搬进安装目录，否则运行期在安装目录
        // 读不到、白白退回老路径：dict.lm.bin（字级二元语法，长串词图兜底）、
        // dict.ptn.bin（大区间前缀 top-N 预排，前缀查询 O(N)）、dict.ti.bin（text→最短码，反查 O(log n)）。
        // 缺哪张就少哪样加速，主 dict.bin 照常可用，故每张都 fileExists 守一下、拷失败也不抛。
        for sidecarName in ["dict.lm.bin", "dict.ptn.bin", "dict.ti.bin"] {
            let src = scratch.appendingPathComponent(sidecarName)
            if fm.fileExists(atPath: src.path) {
                try? fm.copyItem(at: src, to: targetDir.appendingPathComponent(sidecarName))
            }
        }

        let colsMeta = Array(discoveredColumns).sorted()
        if let colsData = try? JSONEncoder().encode(colsMeta) {
            try? colsData.write(to: targetDir.appendingPathComponent("columns_meta.json"), options: .atomic)
        }
        for extra in ["keyboard.yaml", "theme.yaml", "assets"] {
            let src = dir.appendingPathComponent(extra)
            if fm.fileExists(atPath: src.path) {
                try? fm.copyItem(at: src, to: targetDir.appendingPathComponent(extra))
            }
        }
        // 记下编译纪元：下次启动对账时据此判断「这份 dict.bin 是不是老编译器编的」
        manifest.compilerEpoch = DictCompiler.compilerEpoch
        try saveJSON(manifest, to: targetDir.appendingPathComponent("manifest.json"))
        try saveJSON(schema,   to: targetDir.appendingPathComponent("schema.json"))
        let source = ["bundled": isBundled]
        if let sourceData = try? JSONEncoder().encode(source) {
            try? sourceData.write(to: targetDir.appendingPathComponent("source.json"), options: .atomic)
        }

        // 反查与码元提示模块：方案包里若带可选的 extras.json，就编一份侧车索引放进安装目录。
        // 没有这个文件、或解析编译失败，都不影响主流程，运行期读不到侧车自动走老路。
        let extrasSrc = dir.appendingPathComponent("extras.json")
        if let extrasData = try? Data(contentsOf: extrasSrc),
           let extras = try? JSONDecoder().decode(SchemeExtras.self, from: extrasData) {
            let sidecar = targetDir.appendingPathComponent("dict.extras.bin")
            try? ExtrasIndexBuilder.build(extras: extras, to: sidecar)
        }

        // 上面全部写成功，才把旧包换掉（覆盖安装的最后一步，此前旧包一直可用）
        if fm.fileExists(atPath: installedDir.path) { try fm.removeItem(at: installedDir) }
        try fm.moveItem(at: targetDir, to: installedDir)

        return InstallResult(
            schemeId: manifest.id,
            schemeName: manifest.name,
            dictEntryCount: countEntries(binURL: installedDir.appendingPathComponent("dict.bin"))
        )
    }


    public func installPackage(zipURL: URL, overwrite: Bool = false, isBundled: Bool = false) async throws -> InstallResult {
        try await install(zipURL: zipURL, overwrite: overwrite, isBundled: isBundled)
    }

    /// 直接安装一个已解压好的方案目录（供 YAML 单文件导入与内置方案安装使用）
    ///
    /// isBundled 必须能传进来：它写进 packages/<id>/source.json，是「这个方案来自 App 内置」
    /// 的唯一凭据 —— 丢了它，启动对账会把 schemes/ 里补打出的 zip 当孤儿删掉，
    /// 内置方案的版本升级通道（installMissingBundled 比版本号那一段）也跟着断。
    /// 默认 false 保持旧调用方（用户导入）行为逐字节不变。
    public func installDir(_ dir: URL, overwrite: Bool = true, isBundled: Bool = false) async throws -> InstallResult {
        try await installSchemeDir(dir, overwrite: overwrite, isBundled: isBundled)
    }

    // MARK: - 卸载

    public func uninstall(schemeId: String) throws {
        let targetDir = container.packageURL(for: schemeId)
        guard fm.fileExists(atPath: targetDir.path) else { return }
        try fm.removeItem(at: targetDir)
    }

    // MARK: - 加载已安装方案

    public func loadInstalled(schemeId: String) throws -> InstalledScheme {
        let dir = container.packageURL(for: schemeId)
        let manifestData = try Data(contentsOf: dir.appendingPathComponent("manifest.json"))
        let schemaData   = try Data(contentsOf: dir.appendingPathComponent("schema.json"))
        let manifest = try JSONDecoder().decode(SchemeManifest.self, from: manifestData)
        let schema   = try JSONDecoder().decode(SchemeDefinition.self, from: schemaData)
        let colsData = try? Data(contentsOf: dir.appendingPathComponent("columns_meta.json"))
        let availableCols = colsData.flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
        return InstalledScheme(id: schemeId, manifest: manifest, definition: schema,
                               installPath: dir, availableColumns: availableCols)
    }

    // MARK: - 私有辅助

    /// 通用词频语料：随包的雾凇 base.dict.yaml（55 万词，THUOCL + 现代汉语常用词表 + 腾讯词向量）。
    /// 编译「零词频码表」时被 WordFrequencyCorpus 流式读取，给多字词补真实词频。
    /// 读的是只读 App bundle（键盘扩展无此资源，但键盘从不编译，永不触达）；缺失时返回 nil，
    /// 编译安全降级为几何均值兜底。仅作为语料使用，不依赖雾凇是否被安装为方案。
    private static let wordFrequencyCorpusURL: URL? = {
        guard let root = Bundle.main.url(forResource: "BundledSchemes", withExtension: nil) else { return nil }
        let url = root.appendingPathComponent("oime-ice-pinyin.bundle/dictionaries/base.dict.yaml")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }()

    private func parseManifest(in dir: URL) throws -> SchemeManifest {
        let path = dir.appendingPathComponent("manifest.yaml")
        guard fm.fileExists(atPath: path.path) else { throw InstallError.missingManifest }
        let content = try String(contentsOf: path, encoding: .utf8)
        return try YAMLManifestParser.parse(content)
    }

    private func parseSchema(in dir: URL) throws -> SchemeDefinition {
        let path = dir.appendingPathComponent("schema.yaml")
        guard fm.fileExists(atPath: path.path) else { throw InstallError.missingSchema }
        let content = try String(contentsOf: path, encoding: .utf8)
        return try YAMLSchemaParser.parse(content)
    }

    private func yamlFiles(in dir: URL) throws -> [URL] {
        let contents = try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        return contents.filter { $0.pathExtension == "yaml" || $0.lastPathComponent.hasSuffix(".dict.yaml") }
    }

    private func countEntries(binURL: URL) -> Int {
        guard let data = try? Data(contentsOf: binURL, options: .mappedIfSafe),
              data.count >= 12 else { return 0 }
        return Int(data.readUInt32(at: 8))
    }

    private func saveJSON<T: Encodable>(_ value: T, to url: URL) throws {
        let data = try JSONEncoder().encode(value)
        try data.write(to: url, options: .atomic)
    }
}

// MARK: - 极简 YAML 解析器（manifest / schema）

struct YAMLManifestParser {
    static func parse(_ content: String) throws -> SchemeManifest {
        let fields = parseFields(content)
        guard let id = fields["id"], !id.isEmpty else {
            throw PackageInstaller.InstallError.invalidManifestFormat("缺少 id 字段")
        }
        guard let name = fields["name"], !name.isEmpty else {
            throw PackageInstaller.InstallError.invalidManifestFormat("缺少 name 字段")
        }
        return SchemeManifest(
            id: id,
            name: name,
            version: fields["version"] ?? "1.0.0",
            author: fields["author"] ?? "",
            description: fields["description"] ?? ""
        )
    }
}

struct YAMLSchemaParser {
    static func parse(_ content: String) throws -> SchemeDefinition {
        let fields = parseFields(content)
        let schemeType = CodeSystemInference.schemeType(named: fields["type"] ?? "direct") ?? .direct

        return SchemeDefinition(
            type: schemeType,
            maxCodeLength: fields["max_code_length"].flatMap { Int($0) },
            autoSelect: boolValue(fields["auto_select"]),
            alphabet: fields["alphabet"],
            doublePinyinTable: nil,
            normalizeCode: fields["normalize_code"],
            codeSystem: fields["code_system"].flatMap { CodeSystem(rawValue: $0.lowercased()) },
            delimiter: fields["delimiter"],
            autoClear: fields["auto_clear"],
            maxPhraseLength: fields["max_phrase_length"].flatMap { Int($0) },
            enableSentence: boolValue(fields["enable_sentence"]),
            initialQuality: fields["initial_quality"].flatMap { Double($0) },
            reverseLookupGuide: fields["reverse_lookup_guide"]
        )
    }

    /// YAML 的真假值写法五花八门（true/True/yes/on/1），全认；读不懂则当没写
    private static func boolValue(_ raw: String?) -> Bool? {
        guard let raw else { return nil }
        switch raw.lowercased() {
        case "true", "yes", "on", "1":   return true
        case "false", "no", "off", "0":  return false
        default:                         return nil
        }
    }
}

private func parseFields(_ content: String) -> [String: String] {
    var result: [String: String] = [:]
    for line in content.components(separatedBy: .newlines) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("#") || trimmed.isEmpty { continue }
        if let colonRange = trimmed.range(of: ":") {
            let key   = String(trimmed[trimmed.startIndex..<colonRange.lowerBound]).trimmingCharacters(in: .whitespaces)
            let value = String(trimmed[colonRange.upperBound...]).trimmingCharacters(in: .whitespaces)
            if !key.isEmpty {
                result[key] = unquoteScalar(value)
            }
        }
    }
    return result
}

/// 去掉值两端的成对引号：`delimiter: " '"` 读回来必须是空格与撇号本身，不能带着引号
private func unquoteScalar(_ value: String) -> String {
    let trimmed = value.trimmingCharacters(in: .whitespaces)
    guard trimmed.count >= 2 else { return trimmed }
    let first = trimmed.first!
    let last = trimmed.last!
    guard (first == "\"" && last == "\"") || (first == "'" && last == "'") else { return trimmed }
    let body = String(trimmed.dropFirst().dropLast())
    return first == "\"" ? body.replacingOccurrences(of: "\\\"", with: "\"") : body
}

// MARK: - 单文件 YAML 导入器

struct YAMLSingleFileImporter {
    enum ImportError: Error, LocalizedError {
        case emptyContent
        case missingName

        var errorDescription: String? {
            switch self {
            case .emptyContent: return "YAML 文件内容为空"
            case .missingName:  return "YAML 文件缺少 name 字段"
            }
        }
    }

    /// 将任意字符串（中文、英文混合）转为纯小写字母+连字符格式的 id
    static func pinyinId(from text: String) -> String {
        // 汉字转带声调拼音（系统自带，零依赖）
        guard var result = text.applyingTransform(.toLatin, reverse: false) else {
            return text.filter { $0.isLetter || $0.isNumber || $0 == "-" }.lowercased()
        }
        // 去声调
        result = result.applyingTransform(.stripDiacritics, reverse: false) ?? result
        // 小写，空白转 -，过滤非法字符
        return result.lowercased()
            .components(separatedBy: .whitespaces)
            .map { $0.filter { $0.isLetter || $0.isNumber || $0 == "-" } }
            .filter { !$0.isEmpty }
            .joined(separator: "-")
    }

    /// 解析单文件 yaml，构建临时方案目录，返回目录 URL（调用方负责 defer 清理）
    static func buildTempDir(content: String, fileName: String) throws -> URL {
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ImportError.emptyContent
        }

        let lines = content.components(separatedBy: .newlines)

        // 判断是否为外部格式：存在独立的 "..." 行（外部格式 front matter 结束标记）
        let hasDictEndMarker = lines.contains { $0.trimmingCharacters(in: .whitespaces) == "..." }

        if hasDictEndMarker {
            return try buildTempDirFromExternal(content: content, lines: lines, fileName: fileName)
        } else {
            return try buildTempDirFromOpenIME(content: content, lines: lines, fileName: fileName)
        }
    }

    // 外部 .dict.yaml 单文件路径：整个文件原样写入词库，从 front matter 提取元信息
    private static func buildTempDirFromExternal(content: String, lines: [String], fileName: String) throws -> URL {
        // 提取 front matter 区域（--- 到 ... 之间，或文件开头到 ... 之间）
        var frontMatterLines: [String] = []
        var inFrontMatter = false
        var foundEnd = false
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !inFrontMatter {
                if trimmed == "---" { inFrontMatter = true; continue }
                if trimmed.hasPrefix("#") || trimmed.isEmpty { continue }
                // front matter 从第一个非注释行开始（无 --- 的外部格式文件）
                inFrontMatter = true
            }
            if trimmed == "..." { foundEnd = true; break }
            frontMatterLines.append(line)
        }
        _ = foundEnd

        let frontMatterContent = frontMatterLines.joined(separator: "\n")
        let fields = parseFields(frontMatterContent)

        // name 兜底：front matter 无 name 时用文件名去扩展名
        let rawName = (fields["name"] ?? "").isEmpty
            ? fileBaseName(fileName)
            : fields["name"]!

        // id 兜底：front matter 无 id 时依次尝试 name 转拼音、文件名、UUID 前 8 位
        var rawId = fields["id"] ?? ""
        if rawId.isEmpty { rawId = Self.pinyinId(from: rawName) }
        let cleanId = rawId.filter { $0.isLetter || $0.isNumber || $0 == "-" }
        let schemeId = cleanId.isEmpty ? String(UUID().uuidString.prefix(8).lowercased()) : cleanId

        let version = (fields["version"] ?? "").isEmpty ? "1.0.0" : fields["version"]!

        // 码制推断：单文件没有 schema 可读，全靠词库里的编码长相判。
        // 以前一律写死 direct，雾凇的 `ni hao` 就这么被当成形码存进了前缀索引，按音节打反而查不到
        let inference = CodeSystemInference.infer(codes: CodeSystemInference.sampleCodes(inContent: content))

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("yaml_import_\(schemeId)_\(UUID().uuidString.prefix(6))", isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let manifestContent = "id: \(schemeId)\nname: \(rawName)\nversion: \(version)\n"
        try manifestContent.write(to: tempDir.appendingPathComponent("manifest.yaml"),
                                  atomically: true, encoding: .utf8)

        let schemaContent = CodeSystemInference.schemaYAML(result: inference, schema: nil)
        try schemaContent.write(to: tempDir.appendingPathComponent("schema.yaml"),
                                atomically: true, encoding: .utf8)

        // 词库：整个原始文件原样写入，DictCompiler.parseExternalFormat 负责解析
        let dictDir = tempDir.appendingPathComponent("dictionaries", isDirectory: true)
        try fm.createDirectory(at: dictDir, withIntermediateDirectories: true)
        try content.write(to: dictDir.appendingPathComponent("main.dict.yaml"),
                          atomically: true, encoding: .utf8)

        return tempDir
    }

    // OpenIME 单文件路径：--- 之前是方案信息，--- 之后是词条
    private static func buildTempDirFromOpenIME(content: String, lines: [String], fileName: String) throws -> URL {
        var separatorIndex: Int? = nil
        for (i, line) in lines.enumerated() {
            if line.trimmingCharacters(in: .whitespaces) == "---" {
                separatorIndex = i
                break
            }
        }

        let headerLines: [String]
        let dataLines: [String]
        if let sep = separatorIndex {
            headerLines = Array(lines[0..<sep])
            dataLines = Array(lines[(sep + 1)...])
        } else {
            headerLines = lines
            dataLines = []
        }

        let headerContent = headerLines.joined(separator: "\n")
        let fields = parseFields(headerContent)

        var rawId = fields["id"] ?? ""
        if rawId.isEmpty {
            rawId = Self.pinyinId(from: fields["name"] ?? fileName)
        }
        let cleanId = rawId.filter { $0.isLetter || $0.isNumber || $0 == "-" }
        let schemeId = cleanId.isEmpty ? String(UUID().uuidString.prefix(8).lowercased()) : cleanId

        guard let name = fields["name"], !name.isEmpty else {
            throw ImportError.missingName
        }

        let typeStr = fields["type"] ?? "direct"
        let author  = fields["author"] ?? ""
        let desc    = fields["description"] ?? ""

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("yaml_import_\(schemeId)_\(UUID().uuidString.prefix(6))", isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let manifestContent = """
id: \(schemeId)
name: \(name)
version: 1.0.0
author: \(author)
description: \(desc)
"""
        try manifestContent.write(to: tempDir.appendingPathComponent("manifest.yaml"),
                                  atomically: true, encoding: .utf8)

        let schemaContent = "type: \(typeStr)\n"
        try schemaContent.write(to: tempDir.appendingPathComponent("schema.yaml"),
                                atomically: true, encoding: .utf8)

        let dictDir = tempDir.appendingPathComponent("dictionaries", isDirectory: true)
        try fm.createDirectory(at: dictDir, withIntermediateDirectories: true)

        let frontMatter = """
---
columns:
  - text
  - code
  - weight
  - annotation
...

"""
        let dictData = dataLines.joined(separator: "\n")
        let dictContent = frontMatter + dictData + "\n"
        try dictContent.write(to: dictDir.appendingPathComponent("main.dict.yaml"),
                              atomically: true, encoding: .utf8)

        return tempDir
    }

    private static func fileBaseName(_ fileName: String) -> String {
        var name = fileName
        // 去掉 .dict.yaml 或普通 .yaml 扩展名
        for ext in [".dict.yaml", ".yaml"] {
            if name.lowercased().hasSuffix(ext) {
                name = String(name.dropLast(ext.count))
                break
            }
        }
        return name.isEmpty ? fileName : name
    }
}
