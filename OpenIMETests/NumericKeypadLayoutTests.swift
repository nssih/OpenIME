import XCTest
@testable import OpenIMECore

// MARK: - 副键盘布局模块：数字符号副键盘布局与输入测试
//
// 覆盖范围：
//   1. 两页：数字页（单屏数字阵 + 两侧成对符号）/ 符号页（多屏可翻，中英文符号合并）
//   2. 统一「网格区 screens + 固定功能行 functionRow」结构，5 列等宽、上下对齐
//   3. 成对符号：label 存半角 ASCII、fullWidth 存全角；glyph(isEnglish:) 随模式取形
//   4. 中文专用符（顿号、省略号等）没有半角形，两种模式同形，不弹半全角气泡
//   5. 每页功能行含退格 / 回车；符号页功能行第二格是 ABC（一键回主键盘）、中格是翻页圆点；页面互切可达
//   6. 按键标识唯一；模拟点击验证上屏字形

final class NumericKeypadLayoutTests: XCTestCase {

    private let numberPage = NumericKeypadLayout.numberPage
    private let symbolPage = NumericKeypadLayout.symbolPage

    /// 一页里所有按键（网格区各屏 + 功能行）
    private func allKeys(_ page: KeypadPageSpec) -> [KeypadKeySpec] {
        page.screens.flatMap { $0.flatMap { $0 } } + page.functionRow
    }

    // MARK: - 1. 页面基本结构

    func testTwoPagesExist() {
        XCTAssertEqual(NumericKeypadLayout.pages.count, 2)
        XCTAssertEqual(NumericKeypadLayout.pages[NumericKeypadLayout.numberPageIndex].id, "number")
        XCTAssertEqual(NumericKeypadLayout.pages[NumericKeypadLayout.symbolPageIndex].id, "symbol")
    }

    func testNumberPageHasSingleScreen() {
        XCTAssertEqual(numberPage.screens.count, 1, "数字页只有一屏，不翻页")
    }

    func testSymbolPageHasMultipleScreens() {
        XCTAssertGreaterThanOrEqual(symbolPage.screens.count, 2, "符号页应可横向翻屏容纳更多符号")
    }

    func testEveryScreenHasThreeRowsOfFiveColumns() {
        for page in NumericKeypadLayout.pages {
            for (si, screen) in page.screens.enumerated() {
                XCTAssertEqual(screen.count, NumericKeypadLayout.screenRowCount,
                               "\(page.name) 页第 \(si) 屏应为 \(NumericKeypadLayout.screenRowCount) 行")
                for (ri, row) in screen.enumerated() {
                    XCTAssertEqual(row.count, NumericKeypadLayout.columnCount,
                                   "\(page.name) 页第 \(si) 屏第 \(ri) 行应为 5 列")
                }
            }
        }
    }

    func testEveryFunctionRowHasFiveColumns() {
        for page in NumericKeypadLayout.pages {
            XCTAssertEqual(page.functionRow.count, NumericKeypadLayout.columnCount,
                           "\(page.name) 页功能行应为 5 列")
        }
    }

    // MARK: - 2. 数字区（数字页中间三列 + 第四列前三行）

    func testDigitsFillMiddleThreeColumnsOfFirstThreeRows() {
        let screen = numberPage.screens[0]
        for rowIndex in 0..<3 {
            let row = screen[rowIndex]
            for column in 1...3 {
                let key = row[column]
                XCTAssertTrue(key.isDigit, "第 \(rowIndex + 1) 行第 \(column + 1) 列应是数字键")
                XCTAssertEqual(key.label, String(rowIndex * 3 + column))
                XCTAssertEqual(key.action, .literal)
            }
        }
    }

    func testZeroIsInFunctionRowCenter() {
        XCTAssertEqual(numberPage.functionRow[2].label, "0")
        XCTAssertTrue(numberPage.functionRow[2].isDigit)
    }

    /// 五列竖读布局：逐行锁定键面字形（含功能行），防回归
    func testNumberPageColumnLayoutMatchesSpec() {
        let rows = numberPage.screens[0] + [numberPage.functionRow]
        let labels = rows.map { $0.map { $0.glyph(isEnglish: true) } }
        XCTAssertEqual(labels[0], [",", "1", "2", "3", "ABC"])
        XCTAssertEqual(labels[1], [".", "4", "5", "6", "#+="])
        XCTAssertEqual(labels[2], ["?", "7", "8", "9", ""])
        XCTAssertEqual(labels[3], ["!", ";", "0", "@", ""])
    }

    func testEveryDigitAppearsExactlyOnce() {
        let digits = allKeys(numberPage).filter { $0.isDigit }.map { $0.label }
        XCTAssertEqual(digits.count, 10)
        XCTAssertEqual(Set(digits), Set(["0", "1", "2", "3", "4", "5", "6", "7", "8", "9"]))
    }

    // MARK: - 3. 列对齐（5 列等宽网格）

    /// 所有行（含功能行）按键数一致，视图层用统一列宽渲染时上下严格对齐、按键尺寸一致
    func testAllRowsShareTheSameColumnGrid() {
        for page in NumericKeypadLayout.pages {
            var counts = Set(page.screens.flatMap { $0 }.map { $0.count })
            counts.insert(page.functionRow.count)
            XCTAssertEqual(counts, [NumericKeypadLayout.columnCount],
                           "\(page.name) 页存在按键数不同的行，会导致列错位、按键大小不一")
        }
    }

    // MARK: - 4. 数字页左列整列 + 功能行 ！；@ 是成对符号

    /// 竖读布局下的成对符号键位：左列 ，。？、功能行 ！；@
    private func numberPageSideKeys() -> [KeypadKeySpec] {
        let screen = numberPage.screens[0]
        return [screen[0][0], screen[1][0], screen[2][0],
                numberPage.functionRow[0], numberPage.functionRow[1],
                numberPage.functionRow[3]]
    }

    func testNumberPageSidesArePairedSymbols() {
        for key in numberPageSideKeys() {
            XCTAssertTrue(key.isSymbol, "\(key.id) 应为符号键")
            XCTAssertEqual(key.action, .literal)
            XCTAssertTrue(key.hasWidthChoice, "\(key.id) 应为可长按切半/全角的成对符号")
        }
        // 右列第二格（ABC 正下方）是 #+= 切页键
        XCTAssertEqual(numberPage.screens[0][1][4].action,
                       .switchPage(NumericKeypadLayout.symbolPageIndex))
    }

    func testNumberPageSideSymbolsCoverSentencePunctuation() {
        let fullForms = numberPageSideKeys().map { $0.glyph(isEnglish: false) }
        for expected in ["！", "。", "，", "？", "；"] {
            XCTAssertTrue(fullForms.contains(expected), "数字页缺少句末标点 \(expected)")
        }
    }

    // MARK: - 5. 符号页：中英文符号合并、全为符号键

    func testSymbolPageScreensAreAllLiteralSymbols() {
        for (si, screen) in symbolPage.screens.enumerated() {
            for (ri, row) in screen.enumerated() {
                for key in row {
                    XCTAssertTrue(key.isSymbol, "符号页第 \(si) 屏第 \(ri) 行 \(key.id) 应是符号键")
                    XCTAssertEqual(key.action, .literal)
                }
            }
        }
    }

    /// 合并后常见中英文标点都能在同一页打到（半角形 + 全角形）
    func testSymbolPageCoversCommonPunctuation() {
        let fullForms = Set(allKeys(symbolPage).map { $0.glyph(isEnglish: false) })
        for expected in ["，", "。", "？", "！", "；", "：", "、", "…", "～",
                         "《", "》", "「", "」", "“", "‘"] {
            XCTAssertTrue(fullForms.contains(expected), "符号页缺少中文标点 \(expected)")
        }
        let halfForms = Set(allKeys(symbolPage).map { $0.glyph(isEnglish: true) })
        for expected in [",", ".", "?", "!", ";", ":", "@", "#", "$", "%", "&", "*",
                         "+", "-", "=", "/", "\\"] {
            XCTAssertTrue(halfForms.contains(expected), "符号页缺少半角符号 \(expected)")
        }
    }

    // MARK: - 6. 成对符号的半 / 全角形态

    func testPairedSymbolHalfIsAsciiAndFullIsNot() {
        for page in NumericKeypadLayout.pages {
            for key in allKeys(page) where key.hasWidthChoice {
                XCTAssertTrue(key.label.allSatisfy { $0.isASCII },
                              "\(key.id) 的半角形 \(key.label) 应为 ASCII")
                let full = key.fullWidth!
                XCTAssertFalse(full.allSatisfy { $0.isASCII },
                               "\(key.id) 的全角形 \(full) 应为全角（非 ASCII）")
            }
        }
    }

    func testGlyphFollowsLanguageMode() {
        // 逗号键：英文模式出半角 ,，中文模式出全角 ，
        let comma = allKeys(symbolPage).first { $0.id == "sym-comma" }
        XCTAssertNotNil(comma)
        XCTAssertEqual(comma?.glyph(isEnglish: true), ",")
        XCTAssertEqual(comma?.glyph(isEnglish: false), "，")
    }

    func testChineseOnlySymbolsAreSameInBothModes() {
        // 顿号、省略号等中文专用符无半角形，两模式同形、不弹半全角气泡
        let dunhao = allKeys(symbolPage).first { $0.id == "sym-dunhao" }
        XCTAssertNotNil(dunhao)
        XCTAssertFalse(dunhao!.hasWidthChoice)
        XCTAssertEqual(dunhao!.glyph(isEnglish: true), "、")
        XCTAssertEqual(dunhao!.glyph(isEnglish: false), "、")
    }

    func testHasWidthChoiceOnlyForPairedSymbols() {
        for page in NumericKeypadLayout.pages {
            for key in allKeys(page) {
                let expected = key.isSymbol && key.fullWidth != nil
                XCTAssertEqual(key.hasWidthChoice, expected, "\(key.id) 的长按选择资格判定异常")
            }
        }
    }

    // MARK: - 7. 功能行与页面互切

    func testBackToLettersKeyExists() {
        // 竖读布局下 ABC 在网格区右列首格
        XCTAssertEqual(numberPage.screens[0][0][4].action, .toLetters)
        XCTAssertEqual(numberPage.screens[0][0][4].label, "ABC")
    }

    func testPageSwitchKeysAreReciprocal() {
        // 数字页切到符号页：右列第二格（ABC 正下方）的切页键
        XCTAssertEqual(numberPage.screens[0][1][4].action,
                       .switchPage(NumericKeypadLayout.symbolPageIndex))
        XCTAssertEqual(numberPage.screens[0][1][4].label, "#+=")
        // 符号页切回数字页：功能行最左的 123
        XCTAssertEqual(symbolPage.functionRow[0].action,
                       .switchPage(NumericKeypadLayout.numberPageIndex))
        XCTAssertEqual(symbolPage.functionRow[0].label, "123")
    }

    func testFunctionRowsCarryBackspaceAndReturn() {
        // 竖读布局下数字页的退格在网格区第 3 行最右格、回车在功能行末格：按整页键位校验
        for page in NumericKeypadLayout.pages {
            let actions = allKeys(page).map { $0.action }
            XCTAssertTrue(actions.contains(.backspace), "\(page.name) 页缺少退格键")
            XCTAssertTrue(actions.contains(.returnKey), "\(page.name) 页缺少回车键")
        }
        // 空格键已退出副键盘：符号页功能行第二格改为 ABC（一键回主键盘）
        XCTAssertEqual(symbolPage.functionRow[1].action, .toLetters)
        XCTAssertEqual(symbolPage.functionRow[1].label, "ABC")
        for page in NumericKeypadLayout.pages {
            XCTAssertFalse(allKeys(page).map { $0.action }.contains(.space),
                           "\(page.name) 页不应再有空格键")
        }
    }

    func testSymbolPageFunctionRowHasPageIndicator() {
        XCTAssertEqual(symbolPage.functionRow[2].action, .pageIndicator,
                       "符号页功能行中格应是翻页圆点指示（原「中文」键位）")
        // 数字页单屏不翻页，中格是数字 0，不应有圆点
        XCTAssertFalse(numberPage.functionRow.contains { $0.action == .pageIndicator })
    }

    // MARK: - 8. 标识唯一

    func testIdsAreUniquePerPage() {
        for page in NumericKeypadLayout.pages {
            let ids = allKeys(page).map { $0.id }
            XCTAssertEqual(ids.count, Set(ids).count, "\(page.name) 页存在重复按键 id")
        }
    }

    // MARK: - 9. 输入模拟

    /// 按视觉顺序点击数字键（网格 1-9 + 功能行 0），验证上屏为 1~0
    func testTappingDigitsInOrderProducesSequentialDigits() {
        var output = ""
        for row in numberPage.screens[0] {
            for key in row where key.isDigit {
                output += key.label
            }
        }
        output += numberPage.functionRow.filter { $0.isDigit }.map { $0.label }.joined()
        XCTAssertEqual(output, "1234567890")
    }

    /// 数字页标点键：中文模式上屏全角、英文模式上屏半角（竖读布局下的键位顺序）
    func testTappingNumberPageSideSymbolsFollowsMode() {
        let sides = numberPageSideKeys()
        let chinese = sides.map { $0.glyph(isEnglish: false) }.joined()
        let english = sides.map { $0.glyph(isEnglish: true) }.joined()
        XCTAssertEqual(chinese, "，。？！；＠")
        XCTAssertEqual(english, ",.?!;@")
    }
}

// MARK: - 中英切换模块：英文模式下的标点取形
//
// 副键盘每个符号键自带半/全角双形态，由 glyph(isEnglish:) 就地取形，
// 这里只锁定「有半角形的成对符号，其 label 必须是 ASCII」这条不变式。

final class KeypadHalfWidthFormTests: XCTestCase {

    /// 副键盘上所有「有半角形」的成对符号，其半角形必须是 ASCII
    /// 保证英文模式下点按这些键上屏的是半角；中文专用符没有半角形，单独校验
    func testEveryPairedSymbolHalfFormIsAscii() {
        for page in NumericKeypadLayout.pages {
            for row in page.screens.flatMap({ $0 }) + [page.functionRow] {
                for key in row where key.hasWidthChoice {
                    XCTAssertTrue(key.label.allSatisfy { $0.isASCII },
                                  "\(page.name) 页的 \(key.id) 半角形应上屏 ASCII，实际是 \(key.label)")
                }
            }
        }
    }
}
