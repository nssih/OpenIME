import XCTest
@testable import OpenIMECore

/// emoji 候选：映射表加载 + postProcess 紧跟原词追加变体的纯函数行为
final class EmojiCandidateTests: XCTestCase {

    // MARK: - 映射表加载

    /// emoji_word.txt 随 OpenIMECore framework bundle 分发，应能被解析出条目
    func testEmojiTableLoadsFromBundle() {
        XCTAssertGreaterThan(EmojiTable.shared.count, 0, "映射表应从核心库 bundle 解析出条目")
    }

    /// 常见词应有映射，值形如「词 + 空格 + 至少一个 emoji」。
    /// 不写死具体 emoji：映射表由多份数据合并而成、将来可能再扩充，测行为而非某一版数据
    func testReplacementForKnownWord() {
        for w in ["地球", "你好"] {
            guard let v = EmojiTable.shared.replacement(for: w) else {
                return XCTFail("\(w) 应有 emoji 映射")
            }
            XCTAssertTrue(v.hasPrefix(w + " "), "\(w) 的值应以「词 + 空格」开头，实际 \(v)")
            XCTAssertGreaterThan(v.count, w.count + 1, "\(w) 的值应含 emoji")
        }
    }

    /// 不在表里的词 / 空串返回 nil
    func testReplacementForUnknownWord() {
        XCTAssertNil(EmojiTable.shared.replacement(for: ""))
        XCTAssertNil(EmojiTable.shared.replacement(for: "这是一个不存在的词"))
    }

    /// 数据策略：每词 emoji 数有上限（避免「动物 / 颜色」等调色板类词把候选格撑爆）。
    /// 锁定生成期的截断上限 6，将来重新合并数据忘了截断会被这里拦住
    func testNoValueExceedsEmojiCap() {
        for w in ["动物", "颜色", "水果", "运动", "车"] {
            guard let v = EmojiTable.shared.replacement(for: w) else { continue }
            let emojiCount = v.split(separator: " ").count - 1   // 减去开头的词本身
            XCTAssertLessThanOrEqual(emojiCount, 6, "\(w) 的 emoji 数应被截断到 ≤6，实际 \(emojiCount)")
        }
    }

    // MARK: - 追加变体（纯函数）

    private func word(_ text: String, scheme: String = "s", colorHex: String? = nil) -> MixCandidate {
        MixCandidate(candidate: Candidate(text: text, code: "c", annotation: nil,
                                          freq: 1, sourceSchemeId: scheme),
                     colorHex: colorHex)
    }

    /// 命中映射的词，变体紧跟原词插入（原词 → 变体 → 下一个词）
    func testVariantInsertedRightAfterOriginal() {
        let helloVar = EmojiTable.shared.replacement(for: "你好")!
        let earthVar = EmojiTable.shared.replacement(for: "地球")!
        let input = [word("你好"), word("地球"), word("不存在词")]
        let out = IMERuntime.appendEmojiVariants(input)
        XCTAssertEqual(out.map { $0.text },
                       ["你好", helloVar, "地球", earthVar, "不存在词"])
    }

    /// 变体候选带 _emoji 来源标识 + emojiBase 原词，且 code 为空（不参与调频 / 精确匹配计数）
    func testVariantCandidateMetadata() {
        let earthVar = EmojiTable.shared.replacement(for: "地球")!
        let out = IMERuntime.appendEmojiVariants([word("地球")])
        let variant = out.first { $0.candidate.isEmoji }
        XCTAssertNotNil(variant)
        XCTAssertEqual(variant?.text, earthVar)
        XCTAssertEqual(variant?.candidate.emojiBase, "地球")
        XCTAssertEqual(variant?.code, "")
        XCTAssertEqual(variant?.candidate.sourceSchemeId, Candidate.emojiSchemeId)
    }

    /// 不命中映射的词不产生变体，列表原样返回
    func testNoVariantForUnmappedWords() {
        let input = [word("甲"), word("乙")]
        let out = IMERuntime.appendEmojiVariants(input)
        XCTAssertEqual(out.map { $0.text }, ["甲", "乙"])
        XCTAssertFalse(out.contains { $0.candidate.isEmoji })
    }

    /// 变体自身不会再命中映射（避免「地球 🌍」又嵌套追加一层）：只喂一条 emoji 变体，输出原样、不膨胀
    func testVariantIsNotReprocessed() {
        let variant = MixCandidate(
            candidate: Candidate(text: "地球 🌍 🌎 🌏", code: "", annotation: nil, freq: 0,
                                 sourceSchemeId: Candidate.emojiSchemeId, emojiBase: "地球"),
            colorHex: nil)
        let out = IMERuntime.appendEmojiVariants([variant])
        XCTAssertEqual(out.map { $0.text }, ["地球 🌍 🌎 🌏"])
        XCTAssertEqual(out.count, 1)
    }

    /// 变体沿用原词的混打配色，视觉上归属同一个词
    func testVariantInheritsColor() {
        let out = IMERuntime.appendEmojiVariants([word("地球", colorHex: "#FF0000")])
        XCTAssertEqual(out.first { $0.candidate.isEmoji }?.colorHex, "#FF0000")
    }

    /// 空列表进空列表出，不崩
    func testEmptyInput() {
        XCTAssertTrue(IMERuntime.appendEmojiVariants([]).isEmpty)
    }
}
