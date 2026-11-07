import Foundation

// MARK: - 副键盘布局模块：数字符号副键盘布局模型
//
// 设计目标：
//   数字页：五列竖读布局 —— 第 1 列句末标点（，。？！），第 2-4 列竖读 1-9（1/4/7、2/5/8、3/6/9），
//     第 5 列自上而下 ABC/#+=/退格/回车（符号页键在 ABC 正下方），底行 ！；0@ 回车（；在 0 左、@ 在 0 右）
//   符号页：中英文符号合并到同一键位，每个符号键携带半角与全角两种形态，
//     点按跟随中/英模式上屏（英文出半角、中文出全角），长按不松手滑动选另一种；
//     符号多到一屏放不下时横向滑动翻屏（每屏 5 列 3 行），底部圆点指示当前屏
//   每页底部都是固定功能行：数字页是 ！/；/0/@/回车，符号页是 123/ABC/翻页圆点/退格/回车
//
// 键盘形态切换（26 键 / 双拼）不在副键盘上占键位，走候选栏左端切换标志
// 打开的快捷面板「键盘」分区（QuickPanelView），副键盘因此不再有单独的切换菜单，
// 腾出的键位全部还给符号 / 数字。
//
// 半角 / 全角单一真源：所有成对符号的全角形都来自 fullWidthMap（见下），
// pairedSymbol(half:) 据它派生，避免半角/全角两处各写一套而对不上。
//
// 对齐保证：使用固定的 5 列等宽网格 —— 每一行都是 5 个同宽按键，
// 因此上下行严格对齐、所有按键尺寸一致，中间三列（含 0 键）自然居中。
//
// 纯数据模型，方便单元测试直接校验布局，不依赖 SwiftUI。

public struct KeypadKeySpec: Equatable, Identifiable {

    /// 键的角色：数字 / 符号 / 功能键
    public enum Role: String {
        case digit
        case symbol
        case function
    }

    /// 按键行为
    public enum Action: Equatable {
        case literal            // 直接上屏（符号键按当前中/英模式取半角或全角）
        case space
        case backspace
        case returnKey
        case toLetters          // 回到字母键盘
        case switchPage(Int)    // 切换副键盘页面（0=数字页，1=符号页）
        case pageIndicator      // 符号页功能行中格：非交互的翻页圆点指示
    }

    public let id: String
    /// 数字 / 功能键：显示即上屏的文本；符号键：半角 ASCII 规范形
    public let label: String
    public let role: Role
    public let action: Action
    /// 符号键的全角形；无半/全角之分的（数字、功能键、中文专用符）为 nil
    public let fullWidth: String?

    public init(id: String,
                label: String,
                role: Role,
                action: Action,
                fullWidth: String? = nil) {
        self.id = id
        self.label = label
        self.role = role
        self.action = action
        self.fullWidth = fullWidth
    }

    public var isDigit: Bool { role == .digit }
    public var isSymbol: Bool { role == .symbol }

    /// 点按上屏 / 键面显示用的字形：英文模式取半角，中文模式取全角（无全角则退回半角）
    /// —— 数字、功能键、中文专用符两模式同形
    public func glyph(isEnglish: Bool) -> String {
        guard role == .symbol else { return label }
        return isEnglish ? label : (fullWidth ?? label)
    }

    /// 是否支持长按弹「半角 / 全角」气泡：仅成对符号键（有独立全角形）才弹
    public var hasWidthChoice: Bool { role == .symbol && fullWidth != nil }
}

public struct KeypadPageSpec: Identifiable, Equatable {
    public let id: String
    public let name: String
    /// 可横向翻屏的网格区：每屏 = screenRowCount 行乘 columnCount 列
    /// —— 数字页只 1 屏（不翻页），符号页多屏（横向滑动翻页）
    public let screens: [[[KeypadKeySpec]]]
    /// 固定底行（columnCount 格）：不随翻屏滚动
    public let functionRow: [KeypadKeySpec]

    public init(id: String,
                name: String,
                screens: [[[KeypadKeySpec]]],
                functionRow: [KeypadKeySpec]) {
        self.id = id
        self.name = name
        self.screens = screens
        self.functionRow = functionRow
    }
}

public enum NumericKeypadLayout {

    /// 数字页下标 / 符号页下标
    public static let numberPageIndex = 0
    public static let symbolPageIndex = 1

    /// 每行按键数量（5 列等宽：两侧符号 + 中间三列数字）
    public static let columnCount = 5

    /// 每屏网格行数（不含固定功能行）—— 数字页与符号页每屏都是 3 行
    public static let screenRowCount = 3

    /// 数字页：五列竖读 —— 左列句末标点、中间三列竖读 1-9、右列 ABC/#+=/退格/回车；
    /// 网格 3 行 + 功能行 1 行共 4 行；符号页键在 ABC 正下方，底行 ！；0@ 回车（；左 @ 右）
    public static let numberPage: KeypadPageSpec = {
        let screens: [[[KeypadKeySpec]]] = [
            [
                // 第 0 行：， | 1 | 2 | 3 | ABC（回字母键盘，右列首格）
                [
                    pairedSymbol(id: "num-sym-comma", half: ","),
                    digit("1"),
                    digit("2"),
                    digit("3"),
                    KeypadKeySpec(id: "num-to-letters", label: "ABC", role: .function,
                                  action: .toLetters),
                ],
                // 第 1 行：。 | 4 | 5 | 6 | #+=（切到符号页，在 ABC 正下方）
                [
                    pairedSymbol(id: "num-sym-period", half: "."),
                    digit("4"),
                    digit("5"),
                    digit("6"),
                    KeypadKeySpec(id: "num-to-symbol", label: "#+=", role: .function,
                                  action: .switchPage(symbolPageIndex)),
                ],
                // 第 2 行：？ | 7 | 8 | 9 | 退格
                [
                    pairedSymbol(id: "num-sym-question", half: "?"),
                    digit("7"),
                    digit("8"),
                    digit("9"),
                    KeypadKeySpec(id: "num-backspace", label: "", role: .function,
                                  action: .backspace),
                ],
            ]
        ]
        // 功能行：！ | ；（0 左）| 0（正中）| @（0 右）| 回车
        let functionRow: [KeypadKeySpec] = [
            pairedSymbol(id: "num-sym-bang", half: "!"),
            pairedSymbol(id: "num-sym-semicolon", half: ";"),
            digit("0"),
            pairedSymbol(id: "num-sym-at", half: "@"),
            KeypadKeySpec(id: "num-return", label: "", role: .function,
                          action: .returnKey),
        ]
        return KeypadPageSpec(id: "number", name: "数字",
                              screens: screens, functionRow: functionRow)
    }()

    /// 符号页：中英文符号合并，每键半/全角双形态；3 屏横向翻页，底部固定功能行
    ///
    /// 取字原则：覆盖主键盘打不出、又是中英文写作高频的符号
    ///   屏 1：常用标点（句末四件套、引号、括号、书名号、省略号、顿号）
    ///   屏 2：数学与括号（运算符号、竖线、下划线、方括号、花括号、脱字符）
    ///   屏 3：货币与中文专用（at、井号、美元、人民币、反引号、间隔号、破折号、直角引号、尖括号）
    /// 有半全角之分的用 pairedSymbol（长按可切换），中文专用符（顿号、省略号等）用
    /// chineseOnly（两模式同形、不弹半全角气泡）。
    public static let symbolPage: KeypadPageSpec = {
        let screens: [[[KeypadKeySpec]]] = [
            // 屏 1：常用标点
            [
                [
                    pairedSymbol(id: "sym-comma", half: ","),
                    pairedSymbol(id: "sym-period", half: "."),
                    pairedSymbol(id: "sym-question", half: "?"),
                    pairedSymbol(id: "sym-bang", half: "!"),
                    pairedSymbol(id: "sym-semicolon", half: ";"),
                ],
                [
                    pairedSymbol(id: "sym-colon", half: ":"),
                    pairedSymbol(id: "sym-squote", half: "'"),
                    pairedSymbol(id: "sym-dquote", half: "\""),
                    pairedSymbol(id: "sym-tilde", half: "~"),
                    chineseOnly(id: "sym-ellipsis", "…"),
                ],
                [
                    chineseOnly(id: "sym-dunhao", "、"),
                    pairedSymbol(id: "sym-lparen", half: "("),
                    pairedSymbol(id: "sym-rparen", half: ")"),
                    pairedSymbol(id: "sym-lt", half: "<"),
                    pairedSymbol(id: "sym-gt", half: ">"),
                ],
            ],
            // 屏 2：数学与括号
            [
                [
                    pairedSymbol(id: "sym-plus", half: "+"),
                    pairedSymbol(id: "sym-minus", half: "-"),
                    pairedSymbol(id: "sym-equal", half: "="),
                    pairedSymbol(id: "sym-star", half: "*"),
                    pairedSymbol(id: "sym-slash", half: "/"),
                ],
                [
                    pairedSymbol(id: "sym-backslash", half: "\\"),
                    pairedSymbol(id: "sym-percent", half: "%"),
                    pairedSymbol(id: "sym-amp", half: "&"),
                    pairedSymbol(id: "sym-vbar", half: "|"),
                    pairedSymbol(id: "sym-underscore", half: "_"),
                ],
                [
                    pairedSymbol(id: "sym-lbracket", half: "["),
                    pairedSymbol(id: "sym-rbracket", half: "]"),
                    pairedSymbol(id: "sym-lbrace", half: "{"),
                    pairedSymbol(id: "sym-rbrace", half: "}"),
                    pairedSymbol(id: "sym-caret", half: "^"),
                ],
            ],
            // 屏 3：货币与中文专用
            [
                [
                    pairedSymbol(id: "sym-at", half: "@"),
                    pairedSymbol(id: "sym-hash", half: "#"),
                    pairedSymbol(id: "sym-dollar", half: "$"),
                    pairedSymbol(id: "sym-grave", half: "`"),
                    chineseOnly(id: "sym-yen", "¥"),
                ],
                [
                    chineseOnly(id: "sym-middot", "·"),
                    chineseOnly(id: "sym-dash", "—"),
                    chineseOnly(id: "sym-lcorner", "「"),
                    chineseOnly(id: "sym-rcorner", "」"),
                    chineseOnly(id: "sym-lwhitecorner", "『"),
                ],
                [
                    chineseOnly(id: "sym-rwhitecorner", "』"),
                    chineseOnly(id: "sym-langle", "〈"),
                    chineseOnly(id: "sym-rangle", "〉"),
                    chineseOnly(id: "sym-ltortoise", "〔"),
                    chineseOnly(id: "sym-rtortoise", "〕"),
                ],
            ],
        ]
        // 功能行：123（回数字页）| ABC（一键回字母主键盘）| 翻页圆点 | 退格 | 回车
        // —— 原「中文」键位（切到中文标点页）随该页并入符号页而改为翻页指示；
        //    原空格键改为 ABC：副键盘不再需要空格，一键返回主键盘更顺手
        let functionRow: [KeypadKeySpec] = [
            KeypadKeySpec(id: "sym-to-number", label: "123", role: .function,
                          action: .switchPage(numberPageIndex)),
            KeypadKeySpec(id: "sym-to-letters", label: "ABC", role: .function,
                          action: .toLetters),
            KeypadKeySpec(id: "sym-page-indicator", label: "", role: .function,
                          action: .pageIndicator),
            KeypadKeySpec(id: "sym-backspace", label: "", role: .function,
                          action: .backspace),
            KeypadKeySpec(id: "sym-return", label: "", role: .function,
                          action: .returnKey),
        ]
        return KeypadPageSpec(id: "symbol", name: "符号",
                              screens: screens, functionRow: functionRow)
    }()

    public static var pages: [KeypadPageSpec] { [numberPage, symbolPage] }

    // MARK: - 半角 / 全角对照（成对符号的唯一数据源）

    /// 半角符号到全角（全宽）的对应；无对应返回 nil（该键不弹气泡）
    public static func fullWidthVariant(of halfWidth: String) -> String? {
        fullWidthMap[halfWidth]
    }

    private static let fullWidthMap: [String: String] = [
        "(": "（", ")": "）", ",": "，", ".": "。", ":": "：", ";": "；",
        "!": "！", "?": "？", "\"": "“", "'": "‘", "<": "《", ">": "》",
        "@": "＠", "#": "＃", "$": "＄", "%": "％", "&": "＆", "*": "＊",
        "+": "＋", "=": "＝", "-": "－", "/": "／", "\\": "＼",
        // 合并符号页新增的成对符号
        "~": "～", "_": "＿", "|": "｜", "^": "＾", "`": "｀",
        "[": "【", "]": "】", "{": "｛", "}": "｝",
    ]

    // MARK: - 工具

    private static func digit(_ value: String) -> KeypadKeySpec {
        KeypadKeySpec(id: "num-digit-\(value)", label: value, role: .digit,
                      action: .literal)
    }

    /// 成对符号键：label 存半角规范形，全角形从 fullWidthMap 派生（长按可在两者间选择）
    private static func pairedSymbol(id: String, half: String) -> KeypadKeySpec {
        KeypadKeySpec(id: id, label: half, role: .symbol, action: .literal,
                      fullWidth: fullWidthVariant(of: half))
    }

    /// 中文专用符：无半角形，两模式同形、不弹半全角气泡（label 即全角字符，fullWidth 留 nil）
    private static func chineseOnly(id: String, _ char: String) -> KeypadKeySpec {
        KeypadKeySpec(id: id, label: char, role: .symbol, action: .literal,
                      fullWidth: nil)
    }
}
