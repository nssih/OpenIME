import XCTest
@testable import OpenIMECore

// MARK: - 键盘形态端到端测试（小鹤双拼、原有 26 键）
//
// 这些用例走的是和真实键盘完全相同的一条链路：
//   视图击键后依次经过 IMERuntime.appendInput(_:mode:)、InputCodeExpander、CandidateEngine 查到词库
// 因此只要这里通过，就说明「某个形态打不出候选」不是解析链路的问题，
// 而应检查键盘扩展是否跑的是最新二进制。
//
// 用例使用 App 内置的雾凇拼音方案（Runtime.start() 会自动安装内置方案）。

@MainActor
final class IMERuntimeModeTests: XCTestCase {

    /// 与 IMERuntime.candidateLimit 对应的候选上限（两种键盘共用）
    private static let candidateLimit = 300

    private let runtime = IMERuntime.shared

    // MARK: - 类级护栏：预测学习数据零污染
    //
    // 本类的预测用例会往共享 PredictionEngine 里 record 词对；record 每满 100 次上屏就把整张表
    // 落盘覆盖真实 prediction.bin。当前用例选词远不到 100 次故不会落盘，但这是「靠余量」不是
    // 「靠保证」。整类开跑前把用户的 prediction.bin 快照到临时目录、全跑完后原样盖回（各一次
    // 文件拷贝），让「测试绝不污染用户预测学习数据」成为与用例数量无关的结构性保证。
    // 只还原、绝不删用户原文件：快照不存在（拷贝失败或用户本就无预测数据）时不碰 original，杜绝误删。
    override class func setUp() {
        super.setUp()
        let fm = FileManager.default
        let original = AppGroupContainer.shared.predictionFileURL
        let snapshot = fm.temporaryDirectory.appendingPathComponent("openime_prediction_snapshot.bin")
        try? fm.removeItem(at: snapshot)   // 清掉可能残留的旧快照
        if fm.fileExists(atPath: original.path) {
            try? fm.copyItem(at: original, to: snapshot)
        }
    }

    override class func tearDown() {
        let fm = FileManager.default
        let original = AppGroupContainer.shared.predictionFileURL
        let snapshot = fm.temporaryDirectory.appendingPathComponent("openime_prediction_snapshot.bin")
        // 有快照才还原（盖掉测试期间可能落盘的词对）；没快照说明用户本就无预测数据，不碰 original
        if fm.fileExists(atPath: snapshot.path) {
            try? fm.removeItem(at: original)
            try? fm.copyItem(at: snapshot, to: original)
            try? fm.removeItem(at: snapshot)
        }
        super.tearDown()
    }

    /// setUp 里暂存用户的原始设置与键盘形态，tearDown 原样写回共享容器。
    /// 这些端到端用例和真实 App 共用同一个 App Group 容器：测试为了跑在确定环境下会强制切到全拼、
    /// 预测用例还会打开智能预测，若跑完不还原就会把「激活方案 / 智能预测开关」泄漏成测试值，
    /// 污染用户的真实设置（历史上栽过：容器遗留形码方案 → 拼音用例成批假性失败）。
    private var savedSettings: UserSettings?
    private var savedMode: KeyboardMode = .pinyin26

    override func setUp() async throws {
        await runtime.start()
        try XCTSkipIf(runtime.settings.activeSchemeId.isEmpty,
                      "当前环境没有可用方案，跳过端到端用例")
        // 先存档用户当前的真实设置（激活方案、智能预测开关、键盘形态…），tearDown 据此还原
        savedSettings = runtime.settings
        savedMode = KeyboardModeStore.shared.mode
        // 钉死「候选顺序只由词库与编译期词频决定」：动态调频读的是 App Group 里那张跨进程
        // 学习表，别的进程（真键盘 UI 用例点候选格就会学）写过一次，本类「nihao 首选你好」
        // 这类断言就会漂成「你好吗」—— 实测栽过（2 条用例红）。
        // 开关实时生效（frequencyBoost 每次查询都读 settings.dynamicFreqEnabled），
        // 关掉不碰任何文件；原值在 savedSettings 里，tearDown 原样写回，用户设置不受影响。
        // 调频本身的行为由 FrequencyAdjustEngineTests 用自己的临时文件守，不依赖这里。
        if runtime.settings.dynamicFreqEnabled {
            var pinned = runtime.settings
            pinned.dynamicFreqEnabled = false
            runtime.updateSettings(pinned)
        }
        // 强制切到全拼方案：本文件断言的都是雾凇拼音行为（26 键候选、双拼还原…），
        // 容器里遗留的激活方案可能是上一轮测试或用户手动切成的形码，不钉死就会假性失败
        if let pinyinId = fullPinyinSchemeId(), runtime.settings.activeSchemeId != pinyinId {
            runtime.activateScheme(id: pinyinId)
        }
    }

    override func tearDown() async throws {
        runtime.clearInput()
        // commitRawInput 会清掉 lastCommittedText，避免智能预测的上下文泄漏到下一个用例
        _ = runtime.commitRawInput()
        // 还原用户的原始设置与形态：把测试期间对共享容器的一切改动（激活方案、智能预测开关等）
        // 全部抹掉，真实保留用户的任何设置。setUp 跳过时 savedSettings 为 nil，退回原来的复位即可。
        if let savedSettings {
            KeyboardModeStore.shared.mode = savedMode
            runtime.updateSettings(savedSettings)
            runtime.setInputMode(savedMode)
        } else {
            runtime.setInputMode(.pinyin26)
        }
    }

    // MARK: - 智能预测（两种键盘形态都必须生效）

    func testPredictionAppearsForNextInput() {
        enablePrediction()
        runtime.setInputMode(.pinyin26)

        // 预测是上一个词到下一个词的关联：
        //   上屏「新」再上屏「你」记作 新到你，再上屏「新」记作 你到新
        // 之后「新」成为上下文，再输入任意内容就应该提示「你」。
        type("xin", mode: .pinyin26)
        guard let first = runtime.candidates.first else {
            return XCTFail("26 键 xin 应当有候选")
        }
        _ = runtime.selectCandidate(first)

        type("ni", mode: .pinyin26)
        guard let second = runtime.candidates.first else {
            return XCTFail("26 键 ni 应当有候选")
        }
        _ = runtime.selectCandidate(second)

        type("xin", mode: .pinyin26)
        _ = runtime.selectCandidate(first)

        // 换一个与 second 无关的输入，预测候选应当插进来
        type("hao", mode: .pinyin26)
        XCTAssertTrue(runtime.candidates.contains { $0.candidate.isPrediction && $0.text == second.text },
                      "26 键应当给出智能预测「\(second.text)」：\(runtime.candidates.map { $0.text }.prefix(8))")
    }

    /// 双拼走的是同一条预测链路：学出的词对按上屏文字记，与键盘形态无关
    func testHeErSharesPredictionBehaviour() {
        enablePrediction()
        runtime.setInputMode(.heEr)

        // 同样的上下文：新（xb）、你（ni）、新（xb）
        type("xb", mode: .heEr)
        guard let first = runtime.candidates.first else {
            return XCTFail("双拼 xb 应当有候选")
        }
        _ = runtime.selectCandidate(first)
        type("ni", mode: .heEr)
        guard let second = runtime.candidates.first else {
            return XCTFail("双拼 ni 应当有候选")
        }
        _ = runtime.selectCandidate(second)
        type("xb", mode: .heEr)
        _ = runtime.selectCandidate(first)

        // hc = hao：换一个与 second 无关的输入，预测候选的位置规则应当与 26 键一致
        type("hc", mode: .heEr)
        XCTAssertTrue(runtime.candidates.contains { $0.candidate.isPrediction && $0.text == second.text },
                      "同一条预测在两种键盘形态下的表现应当一致：\(runtime.candidates.map { $0.text }.prefix(8))")
    }

    // MARK: - 小鹤双拼

    func testHeErExpansionShowsPinyinAndCandidates() {
        runtime.setInputMode(.heEr)
        type("nihc", mode: .heEr)

        XCTAssertEqual(runtime.inlineInput, "nihao")
        XCTAssertEqual(runtime.candidates.first?.text, "你好")
    }

    func testHeErRejectsIllegalCode() {
        runtime.setInputMode(.heEr)
        // 全拼串在小鹤双拼下是非法码：与外部格式一致，不应回退成 26 键全拼
        type("zhongguo", mode: .heEr)

        XCTAssertTrue(runtime.inlineInput.isEmpty)
        XCTAssertTrue(runtime.candidates.isEmpty)
    }

    func testHeErCandidatesDoNotExceedSharedLimit() {
        runtime.setInputMode(.heEr)
        type("nihc", mode: .heEr)
        XCTAssertLessThanOrEqual(runtime.candidates.count, Self.candidateLimit)
    }

    func testHeErCandidatesAllDeriveFromExpandedCodes() {
        runtime.setInputMode(.heEr)
        // vi = zhi：词库里既有 zhi，也有 zh 打头的 zhong / zhe …
        // 展开出来的码都得严格前缀命中，查不到就把末尾去掉再查（allowPartialFallback）
        // 会让「中」「这」这类与本次击键无关的词混进候选。
        type("vi", mode: .heEr)

        let codes = HeErDoublePinyin.shared.expand("vi")
        XCTAssertEqual(codes, ["zhi"], "双拼解码由展开器保证合法")
        XCTAssertFalse(runtime.candidates.isEmpty, "双拼输入 vi 必须有候选")
        for mixCand in runtime.candidates where !mixCand.candidate.code.isEmpty {
            let code = mixCand.candidate.code
            XCTAssertTrue(codes.contains { code.hasPrefix($0) },
                          "候选「\(mixCand.text)」的编码「\(code)」不在 vi 的展开结果里")
        }
    }

    func testHeErContinuousInputStaysAccurate() {
        runtime.setInputMode(.heEr)
        // xbxb = xin + xin（x + in 的键位是 b）：整串匹配，不能退化成首音节的碎片候选
        type("xbxb", mode: .heEr)

        XCTAssertTrue(HeErDoublePinyin.shared.expand("xbxb").contains(runtime.inlineInput),
                      "内嵌编码应当是 xbxb 的一条完整切分，实际：\(runtime.inlineInput)")
        XCTAssertEqual(runtime.inlineInput.count, "xinxin".count)
        XCTAssertFalse(runtime.candidates.isEmpty, "连打 xbxb 必须能给出候选")
    }

    // MARK: - 原有 26 键（行为必须保持不变）

    func testPinyin26KeepsRawInput() {
        runtime.setInputMode(.pinyin26)
        type("nihao", mode: .pinyin26)

        // 26 键的内嵌编码就是输入码本身，与原实现一致
        XCTAssertEqual(runtime.inlineInput, "nihao")
        XCTAssertEqual(runtime.candidates.first?.text, "你好")
    }

    // MARK: - 字符上屏（两种键盘都上屏「输入框里显示的字符」，不是候选）

    func testCommitRawInputOnPinyin26KeepsTypedLetters() {
        runtime.setInputMode(.pinyin26)
        type("xin", mode: .pinyin26)

        XCTAssertEqual(runtime.commitRawInput(), "xin")
        XCTAssertTrue(runtime.inputBuffer.isEmpty)
    }

    func testCommitRawInputOnHeErOutputsFullPinyin() {
        runtime.setInputMode(.heEr)
        type("nihc", mode: .heEr)

        // 双拼码本身没有意义，上屏还原后的全拼
        XCTAssertEqual(runtime.inlineInput, "nihao")
        XCTAssertEqual(runtime.commitRawInput(), "nihao")
    }

    func testCommitRawInputDoesNotFeedPrediction() {
        // 设置页文案承诺「字符上屏」不参与学习：上屏后上下文必须断掉
        enablePrediction()
        runtime.setInputMode(.pinyin26)
        type("xin", mode: .pinyin26)
        guard let first = runtime.candidates.first else {
            return XCTFail("26 键 xin 应当有候选")
        }
        _ = runtime.selectCandidate(first)

        type("ni", mode: .pinyin26)
        _ = runtime.commitRawInput()

        type("xin", mode: .pinyin26)
        XCTAssertFalse(runtime.candidates.contains { $0.candidate.isPrediction },
                       "字符上屏不应产生预测关联")
    }

    // MARK: - 预测候选落位（position 是槽位，不是排序键）

    func testPredictionSlotsKeepOneWordPerPosition() {
        // 「的」这类高频词后面会学出很多后继，且全是 position 4：
        // 一个槽位只落一条，且落选得最多的那条
        let picked = IMERuntime.pickPredictionSlots([
            (text: "时候", position: 4, totalCount: 7),
            (text: "人", position: 4, totalCount: 42),
            (text: "话", position: 4, totalCount: 11),
        ])
        XCTAssertEqual(picked.count, 1, "同一个槽位只能落一条")
        XCTAssertEqual(picked.first?.text, "人")
        XCTAssertEqual(picked.first?.position, 4)
    }

    func testPredictionSlotsCapAtThree() {
        // position 只有 2…4，不管学出多少后继，最多插 3 条，不会把候选栏挤爆
        let predictions: [(text: String, position: Int, totalCount: Int)] = (0..<20).map {
            (text: "w\($0)", position: 2 + $0 % 3, totalCount: $0)
        }
        let picked = IMERuntime.pickPredictionSlots(predictions)
        XCTAssertEqual(picked.count, 3)
        XCTAssertEqual(picked.map { $0.position }, [2, 3, 4])
    }

    func testPredictionSlotsAreStableForEqualCounts() {
        // 刚学的新词都是 1 次，Dictionary 的遍历顺序又不固定，
        // 不定序会让候选在每次击键之间拖来拖去
        let predictions: [(text: String, position: Int, totalCount: Int)] = [
            (text: "丙", position: 3, totalCount: 1),
            (text: "甲", position: 3, totalCount: 1),
            (text: "乙", position: 3, totalCount: 1),
        ]
        let forward = IMERuntime.pickPredictionSlots(predictions)
        let backward = IMERuntime.pickPredictionSlots(Array(predictions.reversed()))
        XCTAssertEqual(forward.map { $0.text }, backward.map { $0.text })
    }

    // MARK: - 词库侧：内置词库的二进制格式

    /// 内置拼音词库必须是现代格式（v2 及以后，当前为 v3），老格式（v1）要被重编译
    /// —— 格式不对只是慢，不是错，静默退化后很难发现，所以在这里钉住
    func testActiveDictionaryUsesCurrentBinaryFormat() throws {
        let id = runtime.settings.activeSchemeId
        let scheme = try XCTUnwrap(runtime.installedSchemes.first { $0.id == id })
        let version = try XCTUnwrap(DictCompiler.binaryVersion(at: scheme.dictBinPath))
        XCTAssertGreaterThanOrEqual(version, 2, "老格式词库应当被重编译")
    }

    // MARK: - 方案能力门控（形态回落 / 非法混打不生效）
    //
    // 这里测的是运行时那一层：能力矩阵本身在 SchemeCapabilityTests 里穷举过了，
    // 这里只钉住「运行时真的按矩阵行事」—— 历史选择不合法时当场回落、
    // 旧 settings.json 里存着的非法混打组合不会生效。

    /// 纯形码方案（内置包只有雾凇拼音，虎码要靠装机时导入，没装就跳过相关用例）
    private func shapeSchemeId() -> String? {
        runtime.installedSchemes.first { SchemeProfile(scheme: $0).isShape }?.id
    }

    /// 全拼方案（音节存储 + 音码），也是唯一合格的混打参与方
    private func fullPinyinSchemeId() -> String? {
        runtime.installedSchemes.first {
            let profile = SchemeProfile(scheme: $0)
            return profile.type == .syllable && profile.codeSystem == .phonetic
        }?.id
    }

    /// 音形码方案（内置三套里只有超强快码）：i+拼音 反查只对这一类开放
    private func phonoShapeSchemeId() -> String? {
        runtime.installedSchemes.first { SchemeProfile(scheme: $0).isPhonoShape }?.id
    }

    /// 用例结束把设置与形态还原：这两个都是全局持久化的，
    /// 不还原会污染同文件里其它端到端用例（也会污染下一次跑测试的环境）
    private func withRestoredState(_ body: () throws -> Void) rethrows {
        let savedSettings = runtime.settings
        let savedMode = KeyboardModeStore.shared.mode
        defer {
            KeyboardModeStore.shared.mode = savedMode
            runtime.updateSettings(savedSettings)
            runtime.setInputMode(savedMode)
        }
        try body()
    }

    func testFullPinyinSchemeSupportsAllKeyboardModes() throws {
        let pinyinId = try XCTUnwrap(fullPinyinSchemeId(), "环境里没有全拼方案")
        try withRestoredState {
            runtime.activateScheme(id: pinyinId)
            XCTAssertEqual(runtime.availableKeyboardModes, KeyboardMode.allCases)
            XCTAssertEqual(runtime.activeChain.profiles.map { $0.id }, [pinyinId])
        }
    }

    /// 虎码激活时：双拼撑不起，可用形态只剩 26 键（快捷面板仍列两种、不可用的灰显），停在双拼的历史选择当场回落
    func testShapeSchemeFallsBackToPinyin26() throws {
        try XCTSkipIf(shapeSchemeId() == nil, "环境里没装形码方案，跳过回落用例")
        let shapeId = try XCTUnwrap(shapeSchemeId())
        try withRestoredState {
            KeyboardModeStore.shared.mode = .heEr
            runtime.setInputMode(.heEr)
            runtime.activateScheme(id: shapeId)

            XCTAssertEqual(runtime.availableKeyboardModes, [.pinyin26])
            XCTAssertEqual(KeyboardModeStore.shared.mode, .pinyin26,
                           "形态不被方案链撑起来时必须回落 26 键")
            XCTAssertEqual(runtime.inputMode, .pinyin26, "解析用的规则要跟着回落")
        }
    }

    /// 合法的历史选择一个字节都不该改（对账放在高频的 reloadSettings 里，不能误伤）
    func testLegalKeyboardModeIsNotTouched() throws {
        let pinyinId = try XCTUnwrap(fullPinyinSchemeId(), "环境里没有全拼方案")
        try withRestoredState {
            runtime.activateScheme(id: pinyinId)
            KeyboardModeStore.shared.mode = .heEr
            runtime.setInputMode(.heEr)
            runtime.reloadSettings()

            XCTAssertEqual(KeyboardModeStore.shared.mode, .heEr, "全拼方案下双拼合法，不该被动")
            XCTAssertEqual(runtime.inputMode, .heEr)
        }
    }

    /// 拼音主 + 形码参与：旧 settings.json 里存着这种非法组合时，运行时过滤掉而不是改写磁盘
    func testIllegalMixConfigDoesNotEnterChain() throws {
        let pinyinId = try XCTUnwrap(fullPinyinSchemeId(), "环境里没有全拼方案")
        try withRestoredState {
            runtime.activateScheme(id: pinyinId)
            var settings = runtime.settings
            settings.mixInputEnabled = true
            settings.mixInputSchemes = [
                MixSchemeConfig(id: pinyinId, isEnabled: true, candidateColor: "#007AFF", priority: 0),
                MixSchemeConfig(id: shapeSchemeId() ?? "ghost",
                                isEnabled: true, candidateColor: "#FF0000", priority: 1),
            ]
            runtime.updateSettings(settings)

            XCTAssertEqual(runtime.activeChain.profiles.map { $0.id }, [pinyinId],
                           "主方案不是纯形码时混打整个不生效")
            XCTAssertEqual(runtime.availableKeyboardModes, KeyboardMode.allCases)
            // 混打被判非法后走单方案路径，查询本身一点不受影响
            runtime.setInputMode(.pinyin26)
            type("nihao", mode: .pinyin26)
            XCTAssertEqual(runtime.candidates.first?.text, "你好")
        }
    }

    /// 形码主 + 全拼参与：唯一合法方向。参与方只贡献候选，不扩展形态 —— 双拼仍然不可用
    func testLegalMixDoesNotWidenKeyboardModesOnShapePrimary() throws {
        try XCTSkipIf(shapeSchemeId() == nil || fullPinyinSchemeId() == nil,
                      "环境里没装形码方案，跳过合法混打用例")
        let shapeId = try XCTUnwrap(shapeSchemeId())
        let pinyinId = try XCTUnwrap(fullPinyinSchemeId())
        try withRestoredState {
            runtime.activateScheme(id: shapeId)
            XCTAssertEqual(runtime.availableKeyboardModes, [.pinyin26], "未开混打时形码方案只有 26 键")

            var settings = runtime.settings
            settings.mixInputEnabled = true
            settings.mixInputSchemes = [
                MixSchemeConfig(id: shapeId, isEnabled: true, candidateColor: "#007AFF", priority: 0),
                MixSchemeConfig(id: pinyinId, isEnabled: true, candidateColor: "#FF0000", priority: 1),
            ]
            runtime.updateSettings(settings)

            // 混打链组装正确：主方案 + 全拼参与方
            XCTAssertEqual(runtime.activeChain.profiles.map { $0.id }, [shapeId, pinyinId])
            // 参与方不扩展形态：形码主方案开混打后依旧只有 26 键，双拼不可用
            XCTAssertEqual(runtime.availableKeyboardModes, [.pinyin26],
                           "混打参与方只贡献候选，不复活双拼键盘")
        }
    }

    func testIsIdentityDecodingFollowsModeAndScheme() throws {
        let pinyinId = try XCTUnwrap(fullPinyinSchemeId(), "环境里没有全拼方案")
        try withRestoredState {
            runtime.activateScheme(id: pinyinId)
            runtime.setInputMode(.pinyin26)
            XCTAssertTrue(runtime.isIdentityDecoding)
            runtime.setInputMode(.heEr)
            XCTAssertFalse(runtime.isIdentityDecoding, "全拼方案上双拼码要先还原成全拼")
        }
    }

    /// 音形码（快码）的「i + 拼音」反查必须真的出字：i 是引导符，去 i 后的拼音
    /// 借已安装的音码方案查。
    /// 这条链路此前只有「满码即上豁免」的回归（AutoCommitPolicyTests），查询本身没人守：
    /// 引导符剥离、isPhonoShape 判定、借用哪个音码方案，任何一处改错都会让反查静默失效。
    func testReversePinyinLookupOnPhonoShapeScheme() throws {
        try XCTSkipIf(phonoShapeSchemeId() == nil || fullPinyinSchemeId() == nil,
                      "环境里没装音形码方案或可借用的全拼方案，跳过反查用例")
        let phonoShapeId = try XCTUnwrap(phonoShapeSchemeId())
        try withRestoredState {
            runtime.activateScheme(id: phonoShapeId)
            runtime.setInputMode(.pinyin26)

            type("ichun", mode: .pinyin26)
            let reversed = runtime.candidates.map(\.text)
            XCTAssertTrue(reversed.contains("春"),
                          "i+chun 反查应查到「春」，实际：\(reversed.prefix(8))")
            // 反查串不是主方案整码：满码（4 码）顶字不能把它拦腰截断
            XCTAssertEqual(runtime.inputBuffer, "ichun",
                           "反查输入应完整留在缓冲区，不该被自动上屏截断")

            // 反查必须把该字在主方案里的编码一并给出来：用户反查就是为了学这个字怎么拼，
            // 只给字不给码等于把答案问了一半（候选来自音码方案，本身不带快码编码）
            let spring = try XCTUnwrap(runtime.candidates.first { $0.text == "春" })
            let shapeCode = try XCTUnwrap(spring.candidate.annotation,
                                          "反查候选应带出「春」的快码编码当注释")
            // 闭环验证：把给出的编码当正常编码再查一次主方案，这个字必须还在候选里
            //（不看它等于只验“有东西”，而不验“给的是对的码”）。
            // 用 queryCandidates 而不是再 type 一遍：快码是满码即上的方案，直接敲这个码会触发
            // 自动上屏、清掉缓冲区，把要验的东西先弄没了；queryCandidates 是同一查词路径的只读入口
            let back = runtime.queryCandidates(input: shapeCode, schemeId: phonoShapeId, limit: 40)
            XCTAssertTrue(back.map(\.text).contains("春"),
                          "反查给出的编码「\(shapeCode)」回到快码里应能打得出「春」，"
                              + "实际：\(back.map(\.text).prefix(8))")

            // 单上 i 仍走快码自己的码表（i = 以），不能进反查路径
            type("i", mode: .pinyin26)
            XCTAssertTrue(runtime.candidates.map(\.text).contains("以"),
                          "单独 i 是快码真码（以），不该被当反查引导符处理")
        }
    }

    // MARK: - 辅助
    
    /// 打开智能预测（App Group 里的设置可能被上一次运行改过）
    private func enablePrediction() {
        guard !runtime.settings.showPrediction else { return }
        var settings = runtime.settings
        settings.showPrediction = true
        runtime.updateSettings(settings)
    }
    
    private func type(_ text: String, mode: KeyboardMode) {
        runtime.clearInput()
        for ch in text {
            runtime.appendInput(String(ch), mode: mode)
        }
    }
}
