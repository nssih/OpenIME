import XCTest
@testable import OpenIMECore

// MARK: - 内置方案安装路径回归测试
//
// 真机现象：App 装到手机上，一个内置方案都没自动生成。
// 根因是「首装提速」那轮把内置方案改成直接编 App Bundle 里的 .bundle 目录（不再先打包成 zip
// 再解压），而编译产物当时仍写回「源目录」：模拟器里包体可写，全部自动化测试照样绿；
// 真机上 App Bundle 受代码签名保护是只读的，写 dict.bin 必失败，三个内置包全军覆没。
//
// 这里用 chmod 把源目录做成只读，复刻真机的包体条件 —— 这类「只在真机暴露」的坑只能靠
// 把条件搬进单测来兜住。

final class PackageInstallerTests: XCTestCase {

    private let container = AppGroupContainer.shared
    private let installer = PackageInstaller()
    private let fm = FileManager.default
    /// 本用例写进 packages/ 的方案 id，tearDown 统一卸掉，不给开发机的模拟器留垃圾
    private var installedIds: [String] = []

    override func tearDownWithError() throws {
        for id in installedIds {
            try? installer.uninstall(schemeId: id)
        }
        installedIds.removeAll()
    }

    // MARK: - 夹具

    /// 每次跑都用唯一 id，避免与并行用例或机器上的真实方案撞名
    private func newSchemeId() -> String {
        let id = "zzinst\(UUID().uuidString.prefix(6))".lowercased()
        installedIds.append(id)
        return id
    }

    /// 一份最小可编译方案目录（manifest.yaml + schema.yaml + dictionaries/main.dict.yaml）
    private func makeSchemeDir(id: String) throws -> URL {
        let yaml = """
        id: \(id)
        name: 安装路径回归
        type: syllable
        ---
        你好\tnihao\t1000\t
        你们\tnimen\t950\t
        你\tni\t900\t
        """
        return try YAMLSingleFileImporter.buildTempDir(content: yaml, fileName: id)
    }

    private func setWritable(_ writable: Bool, _ url: URL) throws {
        try fm.setAttributes([.posixPermissions: writable ? 0o755 : 0o555], ofItemAtPath: url.path)
    }

    /// 目录内文件总字节数（只用来在三个内置包里挑最小的那个）
    private func dirSize(_ url: URL) -> Int {
        guard let en = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total = 0
        for case let child as URL in en {
            if let values = try? child.resourceValues(forKeys: [.fileSizeKey]) {
                total += values.fileSize ?? 0
            }
        }
        return total
    }

    private func hasBundles(_ url: URL) -> Bool {
        (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil))?
            .contains { $0.pathExtension == "bundle" } ?? false
    }

    /// 定位「内置方案目录」：优先用真正打进 App Bundle 的那份（顺带钉住资源确实进了包），
    /// 逐层往上找是因为 OpenIMECore.framework 就躺在 OpenIME.app/Frameworks/ 下；
    /// 找不到则退回仓库里 Packages/BundledSchemes 的源目录 —— 单元测试不宿主在 App 里跑，
    /// Bundle.main 是 Xcode 的 test agent、没有包体资源。project.yml 用的是 folder 引用（整目录
    /// 原样拷进包体），两份结构一致，拿源目录跑与拿包体跑等价。
    private func bundledSchemesRoot() -> URL? {
        var dir = Bundle(for: PackageInstaller.self).bundleURL
        for _ in 0..<4 {
            dir = dir.deletingLastPathComponent()
            let candidate = dir.appendingPathComponent("BundledSchemes", isDirectory: true)
            if hasBundles(candidate) { return candidate }
        }
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Packages/BundledSchemes", isDirectory: true)
        return hasBundles(repo) ? repo : nil
    }

    // MARK: - 只读源目录（= 真机的 App Bundle）

    /// 源目录只读也必须装成功：编译产物写进临时 scratch，安装结果落在 App Group 里。
    /// 修复前这条在真机条件下必失败（模拟器能写，所以当时没被发现）。
    func testInstallFromReadOnlySourceDirSucceeds() async throws {
        let id = newSchemeId()
        let dir = try makeSchemeDir(id: id)
        defer {
            try? setWritable(true, dir)
            try? fm.removeItem(at: dir)
        }
        try setWritable(false, dir)

        let result = try await installer.installDir(dir, overwrite: true, isBundled: true)

        XCTAssertEqual(result.schemeId, id)
        XCTAssertGreaterThan(result.dictEntryCount, 0, "词库应真的编出了词条")
        let pkg = container.packageURL(for: id)
        XCTAssertTrue(fm.fileExists(atPath: pkg.appendingPathComponent("dict.bin").path))
        XCTAssertTrue(fm.fileExists(atPath: pkg.appendingPathComponent("manifest.json").path))
        XCTAssertTrue(fm.fileExists(atPath: pkg.appendingPathComponent("schema.json").path))
        // isBundled 必须落进 source.json：它是「这个包来自 App 内置」的唯一凭据
        let sourceData = try Data(contentsOf: pkg.appendingPathComponent("source.json"))
        XCTAssertEqual(try JSONDecoder().decode([String: Bool].self, from: sourceData)["bundled"], true)
    }

    /// 源目录哪怕可写，也不许往里写编译产物 —— 上面那条靠「写不进去」暴露问题，这条直接钉不变量
    func testInstallLeavesNoBuildArtifactsInSourceDir() async throws {
        let id = newSchemeId()
        let dir = try makeSchemeDir(id: id)
        defer { try? fm.removeItem(at: dir) }

        _ = try await installer.installDir(dir, overwrite: true, isBundled: true)

        XCTAssertFalse(fm.fileExists(atPath: dir.appendingPathComponent("dict.bin").path),
                       "dict.bin 不该写进源目录")
        XCTAssertFalse(fm.fileExists(atPath: dir.appendingPathComponent("dict.lm.bin").path),
                       "字级二元语法侧车也不该留在源目录")
    }

    // MARK: - 真实内置包的首装路径（端到端）

    /// 拿 App Bundle 里真实的那个内置包，复刻真机首装的完整条件：源目录只读 + 走 installDir 直编
    /// （「首装提速」之后内置方案不再先打包成 zip 再解压，而是直接编包体里的 .bundle）。
    /// 上面的手搓夹具能验得住写入边界，却验不出「资源目录本身装不上」—— 用户报的正是后者。
    ///
    /// id 会改成唯一值再装，不去覆盖开发机上真正在用的那个内置方案；
    /// 只挑最小的一个包：这条实测要 22 秒（就是真机上编一个内置包的实际开销，不是测试自加的成本），
    /// 三个都编会把单测套件拖进分钟级 —— 取一个就足够钉住「首装路径能跑通」。
    /// 顺带一个副作用：这条的耗时就是「首装为什么慢」的量级样本，改编译器时盯着它看。
    func testInstallRealBundledSchemeFromReadOnlyCopy() async throws {
        guard let root = bundledSchemesRoot(),
              let items = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        else { return XCTFail("找不到 BundledSchemes —— 资源没进包，真机上必然一个内置方案都装不出来") }
        let bundles = items.filter { $0.pathExtension == "bundle" }
        XCTAssertFalse(bundles.isEmpty, "内置方案目录是空的（或是那份 folder 引用没进包）：首装不可能有方案")
        let smallest = try XCTUnwrap(bundles.min { dirSize($0) < dirSize($1) })

        let id = newSchemeId()
        let src = fm.temporaryDirectory.appendingPathComponent("zzbundled_\(id)", isDirectory: true)
        try? fm.removeItem(at: src)
        defer {
            try? setWritable(true, src)
            try? fm.removeItem(at: src)
        }
        try fm.copyItem(at: smallest, to: src)

        // 换 id：词库内容与 id 无关，改这一行只是为了不碰开发机上的真方案
        let manifestURL = src.appendingPathComponent("manifest.yaml")
        var yaml = try String(contentsOf: manifestURL, encoding: .utf8)
        let lines = yaml.components(separatedBy: .newlines)
        if let idx = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("id:") }) {
            var edited = lines
            edited[idx] = "id: \(id)"
            yaml = edited.joined(separator: "\n")
        } else {
            yaml = "id: \(id)\n" + yaml
        }
        try yaml.write(to: manifestURL, atomically: true, encoding: .utf8)

        try setWritable(false, src)
        let result = try await installer.installDir(src, overwrite: true, isBundled: true)

        XCTAssertEqual(result.schemeId, id)
        XCTAssertGreaterThan(result.dictEntryCount, 1_000, "真实词库该编出上万条")
        let binURL = container.packageURL(for: id).appendingPathComponent("dict.bin")
        XCTAssertTrue(fm.fileExists(atPath: binURL.path))
        // v4 侧车必须跟 dict.bin 一起进安装目录：编译期写在 scratch 里，安装流程若漏拷，
        // 运行期在安装目录读不到就白白退回老路径（真机实测过：ptn=0 ti=0，前缀查询仍每键几十毫秒）。
        let pkgDir = container.packageURL(for: id)
        XCTAssertTrue(fm.fileExists(atPath: pkgDir.appendingPathComponent("dict.ptn.bin").path),
                      "prefixTopN 侧车应随 dict.bin 一并拷进安装目录")
        XCTAssertTrue(fm.fileExists(atPath: pkgDir.appendingPathComponent("dict.ti.bin").path),
                      "textIndex 反查侧车应随 dict.bin 一并拷进安装目录")
        XCTAssertGreaterThan(dirSize(container.packageURL(for: id)), 100_000, "安装目录不该是个空壳")
        // 编译纪元号必须当场写对：否则每次启动都会多一轮「从 zip 重编」，
        // 而内置方案的 zip 是后台才补打的 —— 这个字段不对，升级与重编两条通道都会反复空跑
        let manifestData = try Data(contentsOf: container.packageURL(for: id)
            .appendingPathComponent("manifest.json"))
        let installed = try JSONDecoder().decode(SchemeManifest.self, from: manifestData)
        XCTAssertEqual(installed.compilerEpoch, DictCompiler.compilerEpoch)
    }

    // MARK: - 覆盖安装的中途失败不得吃掉旧包

    /// 先装好一份，再拿一份坏目录（没有词库）做 overwrite 重装。
    /// 失败是预期的，但旧包必须原样还在、还能被认成已安装方案 ——
    /// 「先删旧包再编译」的写法会让一次失败直接把用户的方案弄没。
    func testFailedOverwriteInstallKeepsPreviousPackage() async throws {
        let id = newSchemeId()
        let good = try makeSchemeDir(id: id)
        defer { try? fm.removeItem(at: good) }
        _ = try await installer.installDir(good, overwrite: true, isBundled: true)

        let binURL = container.packageURL(for: id).appendingPathComponent("dict.bin")
        XCTAssertTrue(fm.fileExists(atPath: binURL.path), "前提：第一份应装好")
        let before = try Data(contentsOf: binURL)

        // 坏目录：manifest 里的 id 一样，但 dictionaries/ 是空的
        let bad = fm.temporaryDirectory
            .appendingPathComponent("bad_\(id)", isDirectory: true)
        defer { try? fm.removeItem(at: bad) }
        try fm.createDirectory(at: bad.appendingPathComponent("dictionaries", isDirectory: true),
                               withIntermediateDirectories: true)
        try "id: \(id)\nname: 坏包\nversion: 1.0.0\n"
            .write(to: bad.appendingPathComponent("manifest.yaml"), atomically: true, encoding: .utf8)
        try "type: syllable\n"
            .write(to: bad.appendingPathComponent("schema.yaml"), atomically: true, encoding: .utf8)

        do {
            _ = try await installer.installDir(bad, overwrite: true, isBundled: true)
            XCTFail("空词库目录本该安装失败")
        } catch {
            // 预期内：只关心失败后旧包的状态
        }

        XCTAssertEqual(try Data(contentsOf: binURL), before, "旧包内容不该被动过")
        XCTAssertTrue(container.installedSchemeIds().contains(id), "旧包不该从已安装清单里消失")
    }

    // MARK: - 暂存目录不得被当成方案

    /// packages/ 下安装过程用的暂存目录叫 .<id>-staging-xxxx。
    /// 万一泄漏（编译成功但换目录前进程被杀），它也不能被 listed 成一个已安装方案 ——
    /// 否则会变成一个查不出候选的幽灵方案。
    func testStagingDirectoryIsNotListedAsInstalledScheme() throws {
        try fm.createDirectory(at: container.packagesURL, withIntermediateDirectories: true)
        let stray = container.packagesURL
            .appendingPathComponent(".zzstaging-leak-staging-0000", isDirectory: true)
        defer { try? fm.removeItem(at: stray) }
        try fm.createDirectory(at: stray, withIntermediateDirectories: true)

        XCTAssertFalse(container.installedSchemeIds().contains(stray.lastPathComponent),
                       "以 . 开头的暂存目录不该进已安装方案清单")
    }
}
