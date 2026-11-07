import CoreGraphics

// MARK: - 26 键 / 小鹤双拼 网格几何
//
// 为什么放在 Shared：键盘扩展里真正画键盘的 KeyboardMetrics、以及主 App 设置页里的
// 键盘实时预览，必须用同一份推导 —— 否则「设置页看到的键盘」和「真正弹出的键盘」
// 两套比例各算各的，用户调一次参数就会发现预览在骗人。
//
// 布局准则：除了下面这几个设计比例（相对可用宽度 / 键格，天然随设备缩放）之外，
// 不出现任何写死的点数：
//   字母键宽 = 可用宽度扣掉两侧留白与 9 个键间距后 10 等分（横向恒定，随屏宽自适应）
//   字母键高 = 键宽乘高度系数：系数 1.0（默认）时严格正方形，用户调高 / 调低时变矩形
//   其余按键按「键格 = 键宽 + 键间距」的倍数分配：第三行两个功能键平分剩余宽度，
//     行内正好铺满、右边缘与底行回车键对齐
//   键盘高度由键高 + 行距 + 上下留白推出，不另外定一个数
public struct KeyboardGridGeometry {

    // 设计比例（全部相对可用宽度 / 键格）
    /// 键盘最外层左右留白 / 可用宽度
    public static let screenEdgePaddingRatio: CGFloat = 0.008
    /// 第一行字母键数：正方形边长的分母
    public static let topRowLetterCount = 10
    /// 字母键边长上限 / 可用宽度：大屏（iPad）上按键不会无限放大
    public static let maxLetterKeyWidthRatio: CGFloat = 0.145
    /// 字母键边长上限 / 屏幕高度：横屏时屏幕矮，4 行正方形键不能把整个屏幕吃掉
    public static let maxLetterKeyHeightRatio: CGFloat = 0.115
    /// 第二行缩进 / 一个键格 —— 9 键行在 10 键行里居中
    public static let secondRowIndentRatio: CGFloat = 0.5
    /// 键盘上下留白 / 键间距
    public static let verticalEdgePaddingRatio: CGFloat = 0.5

    // 字号比例（全部相对键高，用户改字号、换屏幕都不会失衡）
    /// 功能键字号（123 / 地球 / 回车「字符上屏」）/ 键高
    public static let funcFontRatio: CGFloat = 0.38
    /// 键面图标字号 / 功能键字号 —— 图标的视觉重心比文字小，需比文字再大一点
    /// （原有实现是「功能键字号 + 3pt」，这里相对化，换屏幕不再走形）
    public static let iconFontRatio: CGFloat = 1.25
    /// 回车键图标字号 / 功能键字号，与原有 ReturnKey 的「功能键字号乘 1.4」一致
    public static let returnIconFontRatio: CGFloat = 1.4

    // 推导结果
    public let keySpacing: CGFloat
    /// 字母键宽（横向恒定，按屏宽 10 等分；默认高度系数下 = 键高，正方形）
    public let letterKeyWidth: CGFloat
    public let keyHeight: CGFloat
    /// 一行按键区的净宽（不含左右留白），第三行 / 底行都按它铺满
    public let rowWidth: CGFloat
    /// 最外层左右留白（大屏 / 横屏时边长被上限截住，多出来的宽度平分到两侧居中）
    public let hPad: CGFloat
    public let row2Indent: CGFloat
    /// 行首尾功能键宽（Shift / 退格 / 123）：第三行剩余宽度平分给两侧
    public let funcKeyWidth: CGFloat
    /// 底行两端的角键宽（左下 123 / 地球、右下回车）：= 一个功能键宽 + 一个键间距 + 一个字母键宽。
    /// 这个宽度让底行左下键的右缘正好对齐第三行 z 键的右缘、右下回车键的左缘正好对齐 m 键的左缘
    ///（第三行 = Shift + z…m + 退格，两端功能键同宽 funcKeyWidth，故左右对称）。
    /// 中英键下线后底行只剩「左下角键 + 弹性空格 + 回车」，两端各占这一格宽，空格吸收中段。
    public let bottomCornerKeyWidth: CGFloat
    /// 小鹤双拼第三行没有首功能键，退格键吃下整段剩余宽度
    public let heErBackspaceWidth: CGFloat
    public let topBotPad: CGFloat
    public let rowSpacing: CGFloat
    /// 键盘体净高（4 行键 + 3 行间距 + 上下留白）
    public let bodyHeight: CGFloat

    // 功能键文字字号跟「键宽」而非「键高」：调高键盘时键宽不变，文字若跟着键高变大会横向溢出；
    // 且字母字号是用户独立设置的绝对值、不随高度系数变，功能键文字与之保持一致才协调。
    public var funcFontSize: CGFloat { letterKeyWidth * Self.funcFontRatio }
    public var iconFontSize: CGFloat { funcFontSize * Self.iconFontRatio }
    public var returnIconFontSize: CGFloat { funcFontSize * Self.returnIconFontRatio }

    /// 键面图标字号（Shift / 退格等）：由键高直接推导，单个键视图也能用
    public static func iconFontSize(forKeyHeight keyHeight: CGFloat) -> CGFloat {
        keyHeight * funcFontRatio * iconFontRatio
    }

    /// - Parameters:
    ///   - availableWidth: 键盘（或预览容器）可用宽度
    ///   - screenHeight: 屏幕高度，用于横屏时限高；传 0 表示不限高
    ///   - keySpacing: 用户设置的键间距
    ///   - rowSpacingRatio: 用户设置的行间距比例（行距 / 键高）
    ///   - heightRatio: 键盘高度系数，1.0 = 正方形（默认）；键高 = 边长乘此系数，键宽不受影响
    public init(availableWidth: CGFloat,
                screenHeight: CGFloat = 0,
                keySpacing: CGFloat,
                rowSpacingRatio: CGFloat,
                heightRatio: CGFloat = 1.0) {
        let usable = Swift.max(availableWidth, 0)
        let edge = usable * Self.screenEdgePaddingRatio
        let columns = CGFloat(Self.topRowLetterCount)
        self.keySpacing = keySpacing

        // 正方形边长：10 等分，再用「屏宽 / 屏高」两个上限兜底
        let fitSide = (usable - edge * 2 - keySpacing * (columns - 1)) / columns
        var maxSide = usable * Self.maxLetterKeyWidthRatio
        if screenHeight > 0 {
            maxSide = Swift.min(maxSide, screenHeight * Self.maxLetterKeyHeightRatio)
        }
        let side = Swift.max(Swift.min(fitSide, maxSide), 0)

        letterKeyWidth = side
        // 键高与键宽解耦：默认系数 1.0 时 keyHeight == side（正方形，与历史逐字节一致）；
        // 用户调高 / 调低时键高 = 边长乘系数，键宽不变（仍按屏宽 10 等分自适应）。
        // 竖屏空间充裕，系数完全生效；横屏等受限场景用「屏高乘上限」兜底，键高最多回到正方形尺寸，绝不溢出屏幕。
        var scaledKeyHeight = side * heightRatio
        if screenHeight > 0 {
            scaledKeyHeight = Swift.min(scaledKeyHeight, screenHeight * Self.maxLetterKeyHeightRatio)
        }
        keyHeight = Swift.max(scaledKeyHeight, 0)
        rowWidth = side * columns + keySpacing * (columns - 1)
        hPad = edge + Swift.max((usable - rowWidth - edge * 2) / 2, 0)
        row2Indent = (side + keySpacing) * Self.secondRowIndentRatio

        // 第三行 = 1 个首功能键 + 7 个字母 + 1 个尾功能键（8 个间距）
        funcKeyWidth = Swift.max((rowWidth - side * 7 - keySpacing * 8) / 2, side)
        // 小鹤双拼第三行 = 7 个字母 + 1 个退格（7 个间距）
        heErBackspaceWidth = Swift.max(rowWidth - side * 7 - keySpacing * 7, funcKeyWidth)
        // 底行角键 = 功能键宽 + 一个键间距 + 一个字母键宽（对齐第三行 z 右缘 / m 左缘，见属性注释）
        bottomCornerKeyWidth = funcKeyWidth + keySpacing + side
        topBotPad = keySpacing * Self.verticalEdgePaddingRatio

        // 行距由用户的行间距比例直接给出，体高是推导结果
        rowSpacing = keyHeight * rowSpacingRatio
        bodyHeight = keyHeight * 4 + rowSpacing * 3 + topBotPad * 2
    }
}
