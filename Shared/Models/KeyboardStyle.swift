import SwiftUI
import UIKit

// MARK: - 键面样式（键盘扩展与主 App 设置页预览共用同一份推导）

public enum KeyboardKeyStyle {

    /// 副标注（小鹤韵母）字号下限，键高很小时保证可读
    public static let annotationMinFontSize: CGFloat = 7
    /// 副标注文字过长时允许的最小缩放比例
    public static let annotationMinScale: CGFloat = 0.6
    /// 小鹤韵母标注的左右留白：长韵母（iang/uang）缩放后也不贴键边，缓解「挤」
    public static let heErFinalHorizontalPadding: CGFloat = 2
    /// 主字母与副标注之间的行间距
    public static let labelLineSpacing: CGFloat = 1
    /// 空格等次级文字相对 m.letterFontSize 的下调量
    /// —— 与原有 SpaceKey 的 `fontSize: m.letterFontSize - 1` 一致
    public static let secondaryTextFontDelta: CGFloat = 1
    /// 键面副标注文字的透明度
    public static let secondaryTextOpacity: Double = 0.45
    /// 带主色调底色的按键（键盘切换菜单）的填充透明度
    public static let tintedKeyFillOpacity: Double = 0.12
    /// 无 Button 的纯键面按键的按压反馈缩放 —— 与 PressStyle 视觉同源，
    /// 副键盘成对符号键（手势收在网格区统一处理、不用 Button）复用同一套按压观感
    public static let pressScale: CGFloat = 0.94
    /// 无 Button 的纯键面按键的按压反馈亮度 —— 与 PressStyle 视觉同源
    public static let pressBrightness: Double = -0.08
    /// 无 Button 的纯键面按键的按压反馈动画时长（秒） —— 与 PressStyle 视觉同源
    public static let pressAnimationDuration: Double = 0.08

    /// 副标注字号：不超过用户在「外观设置」里定的注释字号，按键高缩放并保底
    public static func annotationFontSize(keyHeight: CGFloat,
                                          annotationSetting: CGFloat,
                                          ratio: CGFloat) -> CGFloat {
        Swift.min(annotationSetting, Swift.max(annotationMinFontSize, keyHeight * ratio))
    }

    /// 空格等次级文字字号：跟随主字母字号下调一档（与原有 SpaceKey 一致）
    public static func secondaryTextFontSize(letterFontSize: CGFloat) -> CGFloat {
        letterFontSize - secondaryTextFontDelta
    }
}

// MARK: - 三排字母键位（双拼键盘与设置页预览共用）

public enum KeyboardLetterRows {
    public static let rows: [[Character]] = [
        Array("qwertyuiop"),
        Array("asdfghjkl"),
        Array("zxcvbnm"),
    ]
}

// MARK: - 主副分层键面配色（双拼键面）
//
// 三段式色彩语义：物理字母弱化、声母强调、韵母次强调。
// 只取观感参数、不用任何第三方素材；颜色为固定值以保证键面可读性，
// 不随主题主色变化（主题主色仍用于选中态 / 功能高亮）。

public enum LayeredKeycapStyle {

    /// 物理字母的弱化透明度（灰）
    public static let keyLetterDim: Double = 0.35
    /// 声母强调色（红）
    public static let initialColor = Color(red: 0.85, green: 0.20, blue: 0.16)
    /// 韵母次强调色（蓝）
    public static let finalColor = Color(red: 0.12, green: 0.46, blue: 0.91)
    /// 双拼顶行（灰字母+红声母）字号 / 键面字母字号
    public static let heErTopRowRatio: CGFloat = 0.85
    /// 双拼顶行行高 / 键高（剩下全给韵母）
    public static let heErTopRowHeightRatio: CGFloat = 0.40
    /// 双拼单行韵母字号 / 键面字母字号
    public static let heErFinalOneLineRatio: CGFloat = 0.66
    /// 双拼两行韵母每行字号 / 键面字母字号
    public static let heErFinalTwoLineRatio: CGFloat = 0.52
    /// 双拼顶行灰字母与红声母的间距（pt）
    public static let heErInitialGap: CGFloat = 2
    /// 双拼韵母最多渲染行数（键面高度只容得下两行）
    public static let heErMaxFinalLines = 2
    /// 双拼顶行左右各留的内边距（pt）——与韵母行同量级，不让文字贴到键帽边
    public static let heErTopRowHorizontalPadding: CGFloat = 2
    /// 顶行字号不得低于键面字母字号的这个比例
    /// —— 再小就没法认了；窄屏 + 大字号撞到下限时宁可留一点余地，也不让字变成省略号
    public static let heErTopRowMinRatio: CGFloat = 0.40
    /// 韵母字号不得低于键面字母字号的这个比例（与顶行同调）
    public static let heErFinalMinRatio: CGFloat = 0.30

    // MARK: 顶行 / 韵母行的宽度实测
    //
    // 以前两个字号只按 heErTopRowRatio / heErFinal*Ratio 跟着「键面字母字号」算，
    // 完全不查键宽 —— 于是用户把按键字号调大后，「V zh」这种两个字符的声母在一把
    // 33pt 宽的键上根本摆不下：顶行没有 lineLimit，它就地拆成两行，而顶行行高只给了
    // 键高的 40%，第二行直接被切掉半截；韵母行那边有 lineLimit(1)，挤不下就缩到
    // minimumScaleFactor 下限还是不行，于是变成省略号。两条都是「显示不全」。
    // 现在按实测宽度反推字号：能放下就用首选字号，放不下就降到刚好放下（再钉一个下限）。
    // 字宽只在进程里量一次最宽的那一组，之后按字号线性缩放
    // —— 小字号下 SF 宽度近似线性，误差远小于取整粒度。

    /// 测量用的参考字号 —— 只用于量出「单位字号需要多宽」，不参与布局
    private static let heErMeasurementFontSize: CGFloat = 100

    /// 顶行最宽组合（大写物理字母 + 间距 + 红声母）的单位字号宽度
    /// —— 取全键盘最挤的那一把键，所有键共用一个字号：既不会个别键挤断行，
    ///    也不会让相邻键的字母大小不一样
    private static let heErTopRowWidthPerPoint: CGFloat = {
        func width(_ text: String, weight: UIFont.Weight) -> CGFloat {
            let font = UIFont.systemFont(ofSize: heErMeasurementFontSize, weight: weight)
            return (text as NSString).size(withAttributes: [.font: font]).width
        }
        var widest: CGFloat = 0
        for (key, initial) in HeErDoublePinyin.keyInitials {
            let row = width(String(key).uppercased(), weight: .regular)
                + heErInitialGap
                + width(initial, weight: .semibold)
            widest = Swift.max(widest, row)
        }
        return widest / heErMeasurementFontSize
    }()

    /// 最长一行韵母的单位字号宽度（蓝色韵母用 medium，与渲染字重一致）
    private static let heErFinalWidthPerPoint: CGFloat = {
        let font = UIFont.systemFont(ofSize: heErMeasurementFontSize, weight: .medium)
        var widest: CGFloat = 0
        for label in HeErDoublePinyin.shared.keyLabels.values {
            for line in label.finals.split(separator: "/") {
                let w = (String(line) as NSString).size(withAttributes: [.font: font]).width
                widest = Swift.max(widest, w)
            }
        }
        return widest / heErMeasurementFontSize
    }()

    /// 双拼顶行字号（灰字母与红声母共用）
    /// - Parameters:
    ///   - letterFontSize: 键面字母字号（用户可调）
    ///   - keyWidth: 一把字母键的宽度
    public static func heErTopRowFontSize(letterFontSize: CGFloat, keyWidth: CGFloat) -> CGFloat {
        let preferred = letterFontSize * heErTopRowRatio
        let available = keyWidth - heErTopRowHorizontalPadding * 2
        let fitting = heErTopRowWidthPerPoint > 0
            ? available / heErTopRowWidthPerPoint : preferred
        return Swift.max(Swift.min(preferred, fitting), letterFontSize * heErTopRowMinRatio)
    }

    /// 双拼韵母行字号（单行与两行各自的首选比例，再按键宽回退）
    public static func heErFinalFontSize(letterFontSize: CGFloat, keyWidth: CGFloat,
                                         lineCount: Int) -> CGFloat {
        let preferred = letterFontSize *
            (lineCount > 1 ? heErFinalTwoLineRatio : heErFinalOneLineRatio)
        let available = keyWidth - KeyboardKeyStyle.heErFinalHorizontalPadding * 2
        let fitting = heErFinalWidthPerPoint > 0
            ? available / heErFinalWidthPerPoint : preferred
        return Swift.max(Swift.min(preferred, fitting), letterFontSize * heErFinalMinRatio)
    }
}

// MARK: - 候选栏（两种键盘形态共用原有 CandidateBarView；设置页预览同源）

public enum CandidateBarStyle {

    /// 候选文字高度 = 候选字号 + 该余量 —— 与原有 CandidateBarView 一致
    public static let candidateTextExtraHeight: CGFloat = 4
    /// 注释与候选文字的行间距 —— 与原有 CandidateBarView 一致
    public static let lineSpacing: CGFloat = 1
    /// 注释文字透明度 —— 与原有 CandidateBarView 一致
    public static let annotationOpacity: Double = 0.7
    /// 注释与候选文字之间的分隔线宽度 —— 与原有 CandidateBarView 一致
    public static let dividerWidth: CGFloat = 0.5

    // 候选栏两端的「字母键同尺寸」槽位
    // 空态时左侧是 logo、右侧是主动收起键；有候选时右侧是展开列表键。
    // 三者尺寸一律取「字母键边长」（q / p 键的实际尺寸，由调用方传进来），
    // 不写死点数 —— 换屏幕、改键间距、改按键字号时跟着键面一起缩放。

    /// 槽位内图标字号 / 槽位边长
    /// —— 原实现把展开键图标写死 13pt，对应 393pt 屏上字母键边长 33.27pt（≈0.39），
    ///    改成比例后大小屏都不会走形
    public static let barFuncIconSizeRatio: CGFloat = 0.39
    /// 槽位图标（收起 / 展开 / 空态快捷功能）未高亮时的文字透明度
    /// —— 两端固定槽位与中段快捷图标共用同一值，整条候选栏视觉一致
    public static let slotIconDimOpacity: Double = 0.4
    /// 空态左侧标志的 SF Symbol 名（快捷面板入口）
    /// 它不是 App 图标，而是一个切换标志：两条平行直线、两端各带箭头，
    ///    语义上正对应点开后快捷面板的功能（切换输入方案 / 切换键盘）。
    ///    它是 SF Symbols 普通符号（Apple 授权在自家 App 内使用），不像 applelogo 那样是
    ///    受限商标，也无黑莓七点徽标（注册商标 "EMBLEM Design"）的侵权风险。
    ///    最终标志若需调整，改 preferredLogoSymbolName 即可，其余代码与尺寸推导一律不用动。
    public static let logoSymbolName: String =
        UIImage(systemName: preferredLogoSymbolName) != nil
            ? preferredLogoSymbolName
            : fallbackLogoSymbolName
    /// 首选标志：双直线箭头的切换符号（无商标风险）
    private static let preferredLogoSymbolName = "arrow.left.arrow.right"
    /// 回落标志：系统上没有首选符号时用三横线菜单，保证入口不会变成一块空白
    private static let fallbackLogoSymbolName = "line.3.horizontal"
    /// 空态标志距候选栏左边缘的内边距 / 标志边长
    /// 与候选词横滑区原有的 4pt 水平内边距同量级（33.27 乘 0.12 约等于 4）
    public static let logoLeadingPaddingRatio: CGFloat = 0.12
    /// 空态标志与相邻内容之间的分隔线透明度 —— 与展开键分隔线一致
    public static let slotDividerOpacity: Double = 0.2
    /// 快捷功能图标「激活」态颜色：绿（激活用绿、未激活用灰）
    public static let shortcutOnColor = Color(UIColor.systemGreen)
    /// 快捷功能图标「未激活」态颜色：灰
    public static let shortcutOffColor = Color(UIColor.systemGray)

    // 有候选态左侧的「组句」入口（输入达词图长度时出现在展开键左边，点开手动组句面板）。
    // 用文案而非图标：这是需要用户主动发现的新入口，「组句」两字比抽象图标更直白；
    // 尺寸仍引用字母键边长，与两端槽位同源缩放。

    /// 「组句」入口按钮的文案
    public static let composeLabel = "组句"
    /// 「组句」入口文案字号 / 槽位边长（两个字要比单图标小一档才放得下、又不挤）
    public static let composeFontRatio: CGFloat = 0.40

    // MARK: - 组句键 / 下拉展开键对齐 o·p 的几何（纯函数，禁写死点数，可单测）
    //
    // 顶行 10 个字母键均匀排布（o = index 8、p = index 9），候选栏横跨整宽、无水平内边距。
    // 以「距屏幕右缘的距离」度量（lk = letterKeyWidth、ks = keySpacing、hPad = 键盘左右留白）：
    //   - p 键右缘 = hPad、左缘 = hPad + lk；
    //   - o 键右缘 = hPad + lk + ks、左缘 = hPad + 2*lk + ks；
    //   - o、p 之间那段 keySpacing 的中点 D_mid = hPad + lk + 0.5*ks（正落两键间隙中央）。
    // 有组句时组句单元格左缘齐 o 键左缘、组句↔下拉键的分隔线正中落 D_mid；
    // 无组句时下拉展开键左缘也落 D_mid。

    /// o、p 两键间隙中点距候选栏右缘的距离（= hPad + lk + 0.5*ks）。
    /// 组句↔下拉键的分隔线、以及无组句时下拉键的左缘，都对齐到这条竖线上。
    public static func opMidpointInsetFromTrailing(letterKeyWidth: CGFloat,
                                                   keySpacing: CGFloat,
                                                   hPad: CGFloat) -> CGFloat {
        hPad + letterKeyWidth + 0.5 * keySpacing
    }

    /// 下拉展开键的 trailing 回缩量：让展开键左缘落在正确位置。
    /// - 有组句（hasCompose=true）：组句↔下拉键的分隔线居中占 D_mid，展开键左缘接分隔线右半线宽处，
    ///   故左缘在 D_mid - dividerWidth/2；展开键宽 slotSize，trailing 回缩 = D_mid - slotSize - dividerWidth/2。
    /// - 无组句（hasCompose=false）：只剩这一颗下拉键，让它左缘正落 D_mid，trailing 回缩 = D_mid - slotSize。
    public static func expandTrailingInset(letterKeyWidth: CGFloat,
                                           keySpacing: CGFloat,
                                           hPad: CGFloat,
                                           slotSize: CGFloat,
                                           hasCompose: Bool) -> CGFloat {
        let opMidpoint = opMidpointInsetFromTrailing(letterKeyWidth: letterKeyWidth,
                                                     keySpacing: keySpacing, hPad: hPad)
        return opMidpoint - slotSize - (hasCompose ? dividerWidth / 2 : 0)
    }

    /// 组句单元格的宽度：左缘落 o 键左缘（hPad + 2*lk + ks）、右缘接居中于 D_mid 的分隔线左边
    /// （D_mid + dividerWidth/2），故宽 = (hPad + 2*lk + ks) - (hPad + lk + 0.5*ks + dividerWidth/2)
    ///         = lk + 0.5*ks - dividerWidth/2。与 hPad 无关（两端同减掉），只随键宽 / 键间距 / 分隔线宽缩放。
    public static func composeCellWidth(letterKeyWidth: CGFloat,
                                        keySpacing: CGFloat) -> CGFloat {
        letterKeyWidth + 0.5 * keySpacing - dividerWidth / 2
    }
}

// MARK: - 主题

public enum KeyboardTheme {

    // 浅色形态的键面三层灰度：展板最暗，功能灰键（funcKeyFill，保持系统灰不动）居中，
    // 普通键最亮但不纯白，三层互相拉开，键帽与展板靠颜色本身区分而不是只剩投影。
    // 灰度值是无量纲观感参数，不来自任何可回溯数据源，按惯例具名单源在这里，
    // 深色形态本来就有灰层对比（0.18/0.26/0.32），保持原样不动。

    /// 浅色展板式底衬的白度（最暗一层）
    private static let lightBoardLevel: CGFloat = 0.80
    /// 浅色普通键帽的白度（最亮一层；用户反馈 0.93 仍偏白，再压一档到明显带灰）
    private static let lightKeyLevel: CGFloat = 0.88

    public static func background(_ a: KeyboardAppearanceSettings) -> Color {
        switch a.theme {
        case .light:        return Color(white: lightBoardLevel)
        case .dark:         return Color(white: 0.18)
        case .followSystem: return Color(UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor.systemGroupedBackground
                : UIColor(white: lightBoardLevel, alpha: 1)
        })
        }
    }

    /// 与 background(_:) 同源同色的 UIKit 版本：键盘扩展在 viewDidLoad 期就把它铺到根视图上，
    /// 早于 SwiftUI 内容渲染，消除「切换 / 过渡期透出系统占位底色」的屏闪。底衬只在这一层铺
    ///（SwiftUI 侧不再重复铺背景，避免两层叠加把半透明背景压得更实）；背景透明度由调用方
    /// 用 withAlphaComponent 叠加。followSystem 用动态 UIColor 跟随浅 / 深色，与 SwiftUI 版一致。
    public static func backgroundUIColor(_ a: KeyboardAppearanceSettings) -> UIColor {
        switch a.theme {
        case .light:        return UIColor(white: lightBoardLevel, alpha: 1)
        case .dark:         return UIColor(white: 0.18, alpha: 1)
        case .followSystem: return UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor.systemGroupedBackground
                : UIColor(white: lightBoardLevel, alpha: 1)
        }
        }
    }
    public static func keyFill(_ a: KeyboardAppearanceSettings) -> Color {
        switch a.theme {
        case .light:        return Color(white: lightKeyLevel)
        case .dark:         return Color(white: 0.32)
        case .followSystem: return Color(UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor.systemBackground
                : UIColor(white: lightKeyLevel, alpha: 1)
        })
        }
    }
    public static func funcKeyFill(_ a: KeyboardAppearanceSettings) -> Color {
        switch a.theme {
        case .light:        return Color(.systemGray4)
        case .dark:         return Color(white: 0.26)
        case .followSystem: return Color(.systemGray3)
        }
    }
    public static func keyText(_ a: KeyboardAppearanceSettings) -> Color {
        switch a.theme {
        case .dark: return Color.white
        default:    return Color.primary
        }
    }
    public static func primaryColor(_ a: KeyboardAppearanceSettings) -> Color {
        Color(hex: a.primaryColor) ?? Color.accentColor
    }
    public static let keyShadow = Color.black.opacity(0.3)

    /// 回车键的语义色（淡蓝）：与退格键「淡红底 + 红图标」同一套 tintedKeyFill 设计语言——
    /// 淡底 = tintedKeyFill(tint: 语义色.opacity(KeyboardKeyStyle.tintedKeyFillOpacity))，图标 / 文字用同一语义色。
    /// 取系统语义色（随浅 / 深色自适应），单源在此，真键盘与设置页预览共用。
    public static let returnKeyTint = Color(.systemBlue)
    /// Shift 键的语义色（淡绿），用法同 returnKeyTint
    public static let shiftKeyTint = Color(.systemGreen)

    /// 键帽底部微投影的向下偏移（pt）：黑色硬投影（radius 0）只往下方错开这一点点，
    /// 让下底边与两个下圆角各带一条极细阴影、键帽浮出立体感。
    /// 无量纲观感参数，具名单源在此，设置页预览与真键盘共用，保证两处观感完全一致。
    public static let keyCapShadowY: CGFloat = 1

    /// 淡底 tint 键（退格 / 功能键）的实体底：先铺一层不透明展板色，再叠上淡色 tint。
    /// 合成像素与「tint 直接压在展板上」完全一致（键身后本就是这块展板色），观感不变；
    /// 但键身因此变成不透明，底部投影不再随底色透明而变淡，退格 / 123 这些淡底键
    /// 也能有和字母键一样清楚的立体感。
    public static func tintedKeyFill(_ a: KeyboardAppearanceSettings, tint: Color) -> some View {
        background(a).overlay(tint)
    }
}

// MARK: - 键帽立体感（投影单源：预览与真键盘共用同一个修饰符）

public extension View {
    /// 给键帽加底部微投影。须接在 `.cornerRadius` 或圆角背景之后，投影才跟随圆角形状；
    /// 设置页预览与真键盘都走这里，观感同源、不会再各写一份跑偏。
    func keyCapDepth() -> some View {
        shadow(color: KeyboardTheme.keyShadow, radius: 0, x: 0, y: KeyboardTheme.keyCapShadowY)
    }
}

// MARK: - Color hex 解析（全仓唯一一份）

public extension Color {
    init?(hex: String) {
        let h = hex.trimmingCharacters(in: .init(charactersIn: "#"))
        guard h.count == 6, let val = UInt64(h, radix: 16) else { return nil }
        self.init(
            red:   Double((val >> 16) & 0xFF) / 255,
            green: Double((val >> 8)  & 0xFF) / 255,
            blue:  Double( val        & 0xFF) / 255
        )
    }
}
