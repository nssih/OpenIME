import XCTest
@testable import OpenIMECore

// MARK: - 小鹤双拼模块：小鹤双拼引擎测试
//
// 覆盖范围：
//   1. 声母 / 韵母键位表（zh=v、ch=i、sh=u，an=j、ang=h、ing=k …）
//   2. 全拼音节转双拼码（约 410 个音节全部可编码）
//   3. 双拼码展开成全拼前缀（单音节、多音节、末尾残码、非法码）
//   4. 26 键键面标注（声母 / 韵母与引擎同源）

final class HeErDoublePinyinTests: XCTestCase {

    private let engine = HeErDoublePinyin.shared

    // MARK: - 1. 键位表

    func testInitialKeyMap() {
        XCTAssertEqual(HeErDoublePinyin.initialKeyMap["zh"], Character("v"))
        XCTAssertEqual(HeErDoublePinyin.initialKeyMap["ch"], Character("i"))
        XCTAssertEqual(HeErDoublePinyin.initialKeyMap["sh"], Character("u"))
        XCTAssertEqual(HeErDoublePinyin.initialKeyMap["b"], Character("b"))
        XCTAssertEqual(HeErDoublePinyin.initialKeyMap["y"], Character("y"))
        XCTAssertEqual(HeErDoublePinyin.initialKeyMap.count, 23)
    }

    func testFinalKeyMap() {
        XCTAssertEqual(HeErDoublePinyin.finalKeyMap["an"], Character("j"))
        XCTAssertEqual(HeErDoublePinyin.finalKeyMap["ang"], Character("h"))
        XCTAssertEqual(HeErDoublePinyin.finalKeyMap["ing"], Character("k"))
        XCTAssertEqual(HeErDoublePinyin.finalKeyMap["uang"], Character("l"))
        XCTAssertEqual(HeErDoublePinyin.finalKeyMap["ui"], Character("v"))
        XCTAssertEqual(HeErDoublePinyin.finalKeyMap["uan"], Character("r"))
        XCTAssertEqual(HeErDoublePinyin.finalKeyMap["ue"], Character("t"))
        XCTAssertEqual(HeErDoublePinyin.finalKeyMap["ong"], Character("s"))
        XCTAssertEqual(HeErDoublePinyin.finalKeyMap["ao"], Character("c"))
        XCTAssertEqual(HeErDoublePinyin.finalKeyMap["ai"], Character("d"))
    }

    // MARK: - 2. 编码

    func testCodeForCommonSyllables() {
        XCTAssertEqual(HeErDoublePinyin.code(for: "ni"), "ni")
        XCTAssertEqual(HeErDoublePinyin.code(for: "hao"), "hc")
        XCTAssertEqual(HeErDoublePinyin.code(for: "zhi"), "vi")
        XCTAssertEqual(HeErDoublePinyin.code(for: "chi"), "ii")
        XCTAssertEqual(HeErDoublePinyin.code(for: "shi"), "ui")
        XCTAssertEqual(HeErDoublePinyin.code(for: "zhui"), "vv")
        XCTAssertEqual(HeErDoublePinyin.code(for: "juan"), "jr")
        XCTAssertEqual(HeErDoublePinyin.code(for: "yao"), "yc")
        XCTAssertEqual(HeErDoublePinyin.code(for: "zhuang"), "vl")
    }

    func testZeroInitialCodes() {
        XCTAssertEqual(HeErDoublePinyin.code(for: "a"), "aa")
        XCTAssertEqual(HeErDoublePinyin.code(for: "o"), "oo")
        XCTAssertEqual(HeErDoublePinyin.code(for: "e"), "ee")
        XCTAssertEqual(HeErDoublePinyin.code(for: "ai"), "ai")
        XCTAssertEqual(HeErDoublePinyin.code(for: "an"), "an")
        XCTAssertEqual(HeErDoublePinyin.code(for: "ang"), "ah")
        XCTAssertEqual(HeErDoublePinyin.code(for: "eng"), "eg")
        XCTAssertEqual(HeErDoublePinyin.code(for: "er"), "er")
    }

    func testEverySyllableIsEncodableWithTwoKeys() {
        for syllable in PinyinSyllables.all {
            guard let code = HeErDoublePinyin.code(for: syllable) else {
                XCTFail("音节 \(syllable) 无法编码")
                continue
            }
            XCTAssertEqual(code.count, 2, "\(syllable) 的码 \(code) 不是两键")
            XCTAssertTrue(code.allSatisfy { $0.isLowercase && $0.isLetter },
                          "\(syllable) 的码 \(code) 含非法字符")
        }
    }

    func testSplitHandlesZhChSh() {
        XCTAssertEqual(HeErDoublePinyin.split("zhuang")?.initial, "zh")
        XCTAssertEqual(HeErDoublePinyin.split("zhuang")?.final, "uang")
        XCTAssertEqual(HeErDoublePinyin.split("chi")?.initial, "ch")
        XCTAssertEqual(HeErDoublePinyin.split("shi")?.final, "i")
        XCTAssertEqual(HeErDoublePinyin.split("a")?.initial, "")
    }

    func testDisplayFinal() {
        XCTAssertEqual(HeErDoublePinyin.displayFinal("v"), "ü")
        XCTAssertEqual(HeErDoublePinyin.displayFinal("uan"), "uan")
    }

    // MARK: - 3. 双拼码展开

    func testExpandSingleSyllable() {
        XCTAssertEqual(engine.expand("hc"), ["hao"])
        XCTAssertEqual(engine.expand("vi"), ["zhi"])
        XCTAssertEqual(engine.expand("ui"), ["shi"])
        XCTAssertEqual(engine.expand("ii"), ["chi"])
        XCTAssertEqual(engine.expand("yc"), ["yao"])
        XCTAssertEqual(engine.expand("ah"), ["ang"])
        XCTAssertEqual(engine.expand("er"), ["er"])
        XCTAssertEqual(engine.expand("vv"), ["zhui"])
        XCTAssertEqual(engine.expand("jr"), ["juan"])
    }

    func testExpandMultipleSyllables() {
        // ni + hc = nihao
        XCTAssertTrue(engine.expand("nihc").contains("nihao"))
        // ni + hao + ma（ma = ma）
        XCTAssertTrue(engine.expand("nihcma").contains("nihaoma"))
        // 你好吗 的双拼码应与引擎编码结果一致
        XCTAssertEqual(HeErDoublePinyin.code(for: "ni").map { $0 + "hc" }, "nihc")
    }

    func testExpandTrailingSingleKeyKeepsPrefix() {
        // 末尾只剩一个键时，按可能的声母给出前缀（用户还没打完音节）
        XCTAssertEqual(engine.expand("nih"), ["nih"])
        XCTAssertTrue(engine.expand("v").contains("zh"))
        XCTAssertTrue(engine.expand("i").contains("ch"))
        XCTAssertTrue(engine.expand("u").contains("sh"))
    }

    func testExpandRejectsInvalidCode() {
        XCTAssertTrue(engine.expand("").isEmpty)
        XCTAssertTrue(engine.expand("1a").isEmpty)     // 非字母开头
        XCTAssertTrue(engine.expand("tt").isEmpty)      // t + t(ue) 不是存在的音节（ue 只在 j/q/x/y 后）
        XCTAssertTrue(engine.expand("hc", maxResults: 0).isEmpty)
        XCTAssertTrue(engine.expand("n1").isEmpty)      // 非字母
    }

    func testExpandIsPrefixQueryFriendly() {
        // 展开结果必须都是小写全拼前缀，词库可直接做前缀匹配
        for code in ["nihc", "vl", "shj", "vim"] {
            for text in engine.expand(code) {
                XCTAssertTrue(text.allSatisfy { $0.isLowercase && $0.isLetter },
                              "\(code) 展开出非法前缀 \(text)")
            }
        }
    }

    // MARK: - 4. 键面标注

    func testKeyLabelsCoverAllTwentySixKeys() {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz")
        XCTAssertEqual(engine.keyLabels.count, 26)
        for key in alphabet {
            let label = engine.keyLabels[key]
            XCTAssertNotNil(label, "键 \(key) 缺少标注")
            XCTAssertFalse(label?.finals.isEmpty ?? true, "键 \(key) 缺少韵母标注")
        }
    }

    func testOnlyZhChShKeysHaveInitialLabel() {
        let keysWithInitial = engine.keyLabels
            .filter { $0.value.initial != nil }
            .keys
            .sorted()
        XCTAssertEqual(keysWithInitial, [Character("i"), Character("u"), Character("v")])
        XCTAssertEqual(engine.keyLabels[Character("v")]?.initial, "zh")
        XCTAssertEqual(engine.keyLabels[Character("i")]?.initial, "ch")
        XCTAssertEqual(engine.keyLabels[Character("u")]?.initial, "sh")
    }

    func testRepresentativeFinalLabels() {
        // 与小鹤官方键位图对照（多个韵母用 / 分隔，顺序也跟官方键帽一致）
        XCTAssertEqual(engine.keyLabels[Character("v")]?.finals, "ui/ü")
        XCTAssertEqual(engine.keyLabels[Character("h")]?.finals, "ang")
        XCTAssertEqual(engine.keyLabels[Character("j")]?.finals, "an")
        XCTAssertEqual(engine.keyLabels[Character("k")]?.finals, "uai/ing")
        XCTAssertEqual(engine.keyLabels[Character("l")]?.finals, "iang/uang")
        XCTAssertEqual(engine.keyLabels[Character("s")]?.finals, "ong/iong")
        XCTAssertEqual(engine.keyLabels[Character("t")]?.finals, "ue/üe")
        XCTAssertEqual(engine.keyLabels[Character("o")]?.finals, "uo/o")
        XCTAssertEqual(engine.keyLabels[Character("x")]?.finals, "ia/ua")
        // er 为零声母特例：第二键落在 r 键
        XCTAssertEqual(engine.keyLabels[Character("r")]?.finals, "uan/er")
    }

    func testKeyLabelsAgreeWithKeyMaps() {
        // 每个键的韵母标注必须包含 finalKeyMap 中映射到该键的全部韵母
        for (final, key) in HeErDoublePinyin.finalKeyMap {
            let display = HeErDoublePinyin.displayFinal(final)
            let finals = engine.keyLabels[key]?.finals ?? ""
            XCTAssertTrue(finals.split(separator: "/").map(String.init).contains(display),
                          "键 \(key) 的标注 \(finals) 缺少韵母 \(display)")
        }
    }
}
