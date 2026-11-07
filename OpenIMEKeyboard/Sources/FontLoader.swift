import CoreText
import SwiftUI
import UIKit

enum CJKFont {
    // 候选正文 / 注释渲染字体：文津宋体三平面（官方 OTF/CFF，SIL OFL 1.1，中国大陆字形标准）。
    //
    // 为什么是三份而不是一份：单个 OpenType 字体最多 65,535 个字形（maxp.numGlyphs 是
    // uint16），而候选需要的「汉字 + 偏旁部首 + 拼音注音 + 标点」全集约 10.6 万码位，
    // 物理上装不进一个字体——这正是作者按 Unicode 平面拆成 P0/P2/P3 的原因（每份 <65,535）。
    // 因此这里三份都注册，渲染时按码位所在平面选字体；三份同字族同设计同度量，
    // 跨平面分段拼接视觉无缝，从而彻底不再依赖苹方回退（旧方案常见字走苹方、
    // 生僻字走明朝体，混排观感割裂）。
    //   P0 第一平面：常用字 / 偏旁部首 / 笔画 / 拼音注音 / ASCII / 标点
    //   P2 第二平面：扩展 B~F、扩展 I、兼容增补 等生僻字
    //   P3 第三平面：扩展 G / H / J
    private static let planeNames = [
        "WenJinMinchoP0-Regular",
        "WenJinMinchoP2-Regular",
        "WenJinMinchoP3-Regular",
    ]

    // P0 同步注册：它覆盖 99.98% 的候选（全部第一平面），且 17.5MB 比旧 OpenIMEExt(31MB) 更小，
    // 键盘首帧注册负担反而下降。P2/P3 只服务罕用生僻字，放后台异步注册——
    // 等用户真打到扩 B+ 的字时（必然晚于首帧数秒）早已就绪，不拖首弹。
    static let registeredP0: Bool = register(planeNames[0])

    private static func register(_ name: String) -> Bool {
        let bundle = Bundle(for: CJKFontBundleAnchor.self)
        guard let url = bundle.url(forResource: name, withExtension: "otf") else {
            return false
        }
        var cfError: Unmanaged<CFError>?
        if CTFontManagerRegisterFontsForURL(url as CFURL, .process, &cfError) {
            return true
        }
        // 注册失败：区分"已注册（正常）"和"真实错误"
        if let err = cfError?.takeRetainedValue() {
            if CFErrorGetCode(err) == 105 {
                // kCTFontManagerErrorAlreadyRegistered — 重复注册，字体可用
                return true
            }
        }
        return false
    }

    // 在 viewDidLoad 里调用：P0 立即就绪，P2/P3 转后台，避免大字体解析阻塞首帧
    static func warmUp() {
        _ = registeredP0
        DispatchQueue.global(qos: .userInitiated).async {
            _ = register(planeNames[1])
            _ = register(planeNames[2])
        }
    }

    // 码位 -> 平面下标（纯算术，运行期零字体 I/O）：
    //   <U+10000 第一平面；U+10000~U+2FFFF 第二平面；>=U+30000 第三平面
    static func planeIndex(for scalar: Unicode.Scalar) -> Int {
        let v = scalar.value
        if v < 0x10000 { return 0 }
        if v < 0x30000 { return 1 }
        return 2
    }

    static func planeFont(_ plane: Int, size: CGFloat) -> Font {
        Font.custom(planeNames[plane], size: size)
    }

    /// 按码位所在平面把字符串切成连续段（同段同平面），供选字与拼接复用
    private static func planeRuns(_ s: String) -> [(text: String, plane: Int)] {
        var runs: [(text: String, plane: Int)] = []
        for scalar in s.unicodeScalars {
            let p = planeIndex(for: scalar)
            if runs.last?.plane == p {
                runs[runs.count - 1].text.append(Character(scalar))
            } else {
                runs.append((String(Character(scalar)), p))
            }
        }
        return runs
    }

    /// 候选正文（不加粗）：整条落在单一平面时直接用该平面字体（99.98% 的候选走这条快路径，零额外开销）；
    /// 极少数跨平面词条按连续码位分段、每段用对应平面字体拼接（同字族同度量，视觉无缝）。
    static func candidateText(_ s: String, size: CGFloat) -> Text {
        let runs = planeRuns(s)
        guard let first = runs.first else { return Text("") }
        var result = Text(first.text).font(planeFont(first.plane, size: size))
        for run in runs.dropFirst() {
            result = result + Text(run.text).font(planeFont(run.plane, size: size))
        }
        return result
    }

    /// 候选加粗的伪粗描边宽度（相对字号的百分比，负值 = 填充 + 描边 = 实心加粗）。
    /// 文津宋体仅 Regular 一字重；iOS/SwiftUI 对无粗体字面的自定义字体不会合成伪粗（与浏览器不同），
    /// 只有 CoreText 的负 strokeWidth 能可靠加粗，而 SwiftUI 的 Text/AttributedString 不渲染该属性，
    /// 故加粗时用 UILabel 承载（见 CandidateBodyText）。
    private static let fauxBoldStrokeWidth: CGFloat = -3.0

    /// 加粗候选正文：按平面给每段配 UIFont，用负 strokeWidth 描边合成实心伪粗（供 UILabel 渲染）
    static func boldAttributedCandidate(_ s: String, size: CGFloat, color: UIColor) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for run in planeRuns(s) {
            let font = UIFont(name: planeNames[run.plane], size: size) ?? UIFont.systemFont(ofSize: size)
            result.append(NSAttributedString(string: run.text, attributes: [
                .font: font,
                .foregroundColor: color,
                .strokeWidth: fauxBoldStrokeWidth,
                .strokeColor: color,
            ]))
        }
        return result
    }

    /// 注释（拼音 / 拆字部首 / 剩余整码）：全部位于第一平面，单字体即可
    static func annotation(size: CGFloat) -> Font {
        planeFont(0, size: size)
    }

    /// 按平面分段测量字符串的渲染宽度（pt）：与 candidateText 走同一套平面字体，
    /// 逐段用对应平面的 UIFont 量宽再求和，供懒加载分行在渲染前预估每个 cell 宽度。
    /// 用真实渲染字体测量（而非系统字体近似）才能让预估换行位置与实际渲染对齐、不溢出。
    static func measureWidth(_ s: String, size: CGFloat) -> CGFloat {
        guard !s.isEmpty else { return 0 }
        var total: CGFloat = 0
        for run in planeRuns(s) {
            let font = UIFont(name: planeNames[run.plane], size: size) ?? UIFont.systemFont(ofSize: size)
            total += (run.text as NSString).size(withAttributes: [.font: font]).width
        }
        return total
    }
}

// 用于定位扩展自身 bundle 的锚点类
private final class CJKFontBundleAnchor {}

/// 候选正文渲染视图：加粗与否走不同渲染路径（原因见 CJKFont.boldAttributedCandidate 注释）。
/// - 不加粗：SwiftUI Text（多平面拼接，与历史实现一致，零回归、零额外开销）
/// - 加粗：UILabel + NSAttributedString 负描边（SwiftUI 无法对单字重自定义字体合成伪粗）
struct CandidateBodyText: View {
    let text: String
    let size: CGFloat
    let bold: Bool
    let color: Color

    var body: some View {
        if bold {
            BoldCandidateLabel(text: text, size: size, color: UIColor(color))
        } else {
            CJKFont.candidateText(text, size: size)
                .foregroundColor(color)
        }
    }
}

/// 加粗候选的 UILabel 承载：用负 strokeWidth 描边把单字重宋体合成实心伪粗
private struct BoldCandidateLabel: UIViewRepresentable {
    let text: String
    let size: CGFloat
    let color: UIColor

    func makeUIView(context: Context) -> UILabel {
        let label = UILabel()
        label.numberOfLines = 1
        label.lineBreakMode = .byClipping
        label.backgroundColor = .clear
        // 候选格按文字实际宽度占位，不被拉伸也不被压缩（与 SwiftUI Text 的 fixedSize 行为对齐）
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        return label
    }

    func updateUIView(_ label: UILabel, context: Context) {
        label.attributedText = CJKFont.boldAttributedCandidate(text, size: size, color: color)
    }
}
