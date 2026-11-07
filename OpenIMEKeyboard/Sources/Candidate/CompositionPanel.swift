import SwiftUI
import OpenIMECore

// MARK: - 手动组句面板
//
// 长串自动词图只给「它认为最好」的整句，用户想自己定夺「由哪些字 / 词组成」时无从下手。
// 组句面板把选择权交回用户：顶部显示「已组句子 + 剩余编码」，中部列出下一段能切的全部词
// （数据来自 IMERuntime.compositionOptions → CandidateEngine.leadingOptions，与词图同源），
// 点一个词就消费对应的码长并接到句尾，全部码组完后底部「完成」——学习整句 + 上屏 + 清空。
// 拼音 / 形码 / 音形码通用（三套分段器）。形态沿用 CandidateExpandedPanel 的设计语言
// （WrapLayout 网格 + 底部操作栏 + KeyboardTheme 配色），面板高度由调用方按 panelTotalHeight 定死。
struct CompositionPanel: View {
    @EnvironmentObject private var runtime: IMERuntime
    let appearance: KeyboardAppearanceSettings
    let bottomBarHeight: CGFloat
    /// 完成：把组好的整句上屏（runtime 内部已学习 + 清空），调用方插入文本并收起面板
    let onFinish: (String) -> Void
    /// 取消 / 关闭：非破坏性退出组句（runtime 侧中间态由调用方 exitComposition 丢弃）
    let onCancel: () -> Void

    /// 中部选项一次最多渲染的词数：WrapLayout 非懒布局，一次铺开上千 cell 会卡。
    /// 选项按词频全局降序展平（常用词 / 字在前、生僻在后），取前一批即最常用的；组句是低频用户交互，够用。
    private static let maxOptions = 200

    // 布局常量（与 CandidateExpandedPanel 同源的观感基准，本面板私有）
    private let outerHPadding: CGFloat = 10
    private let itemHSpacing: CGFloat = 4
    private let itemVSpacing: CGFloat = 6
    private let cellVPadding: CGFloat = 6
    private let cellHPadding: CGFloat = 10

    // 组句态不是 @Published（避免每步变动都广播整个 runtime），面板自持一份 @State，
    // 每次调 runtime 的组句方法后 refresh() 把最新预览 / 选项 / 可完成态读回来驱动重绘。
    @State private var composed = ""
    @State private var remainingCode = ""
    @State private var options: [(end: Int, words: [CodeLattice.Word])] = []
    @State private var canFinish = false

    /// 把 runtime 组句态读回本地 @State
    private func refresh() {
        let preview = runtime.compositionPreview
        composed = preview.composed
        remainingCode = preview.remainingCode
        options = runtime.compositionOptions()
        canFinish = runtime.canFinishComposition
    }

    /// 展平的可选词：交给 CandidateEngine.orderedCompositionChoices 按词频全局降序排——
    /// 常用词 / 字排在前、生僻冷门沉到后，同文本去重后最多 maxOptions 条
    private var flatOptions: [(text: String, spanLen: Int)] {
        CandidateEngine.orderedCompositionChoices(options, limit: Self.maxOptions)
    }

    var body: some View {
        let keyText = KeyboardTheme.keyText(appearance)
        let flat = flatOptions
        VStack(spacing: 0) {
            previewHeader(keyText: keyText)
            Divider()

            ScrollView(.vertical, showsIndicators: false) {
                if flat.isEmpty {
                    // 剩余码切不出词：要么已组完（提示点完成），要么卡住（提示撤销 / 取消）
                    emptyHint(keyText: keyText)
                } else {
                    WrapLayout(hSpacing: itemHSpacing, vSpacing: itemVSpacing) {
                        ForEach(0..<flat.count, id: \.self) { idx in
                            let option = flat[idx]
                            Button {
                                runtime.pickCompositionWord(text: option.text, spanLen: option.spanLen)
                                refresh()
                            } label: {
                                CandidateBodyText(text: option.text,
                                                  size: appearance.candidateFontSize,
                                                  bold: appearance.candidateFontBold,
                                                  color: keyText)
                                    .lineLimit(1)
                                    .fixedSize(horizontal: true, vertical: false)
                                    .padding(.vertical, cellVPadding)
                                    .padding(.horizontal, cellHPadding)
                                    .background(KeyboardTheme.keyFill(appearance))
                                    .cornerRadius(CGFloat(appearance.keyCornerRadius))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, outerHPadding)
                    .padding(.vertical, itemVSpacing)
                }
            }

            Divider()
            bottomBar(keyText: keyText)
        }
        .background(KeyboardTheme.background(appearance))
        .onAppear { refresh() }
    }

    // MARK: - 顶部预览

    @ViewBuilder
    private func previewHeader(keyText: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text("已组")
                    .font(.system(size: appearance.annotationFontSize + 8))
                    .foregroundColor(keyText.opacity(CandidateBarStyle.annotationOpacity))
                if composed.isEmpty {
                    Text("依次点下方词组句")
                        .font(.system(size: appearance.candidateFontSize))
                        .foregroundColor(keyText.opacity(CandidateBarStyle.slotIconDimOpacity))
                } else {
                    CandidateBodyText(text: composed,
                                      size: appearance.candidateFontSize,
                                      bold: appearance.candidateFontBold,
                                      color: KeyboardTheme.primaryColor(appearance))
                }
            }
            .lineLimit(1)
            if !remainingCode.isEmpty {
                Text("剩余码 \(remainingCode)")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(keyText.opacity(CandidateBarStyle.annotationOpacity))
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, outerHPadding)
        .padding(.vertical, cellVPadding)
    }

    @ViewBuilder
    private func emptyHint(keyText: Color) -> some View {
        Text(canFinish ? "整句已组完，点「完成」上屏并记住" : "剩余码切不出词，请撤销一段或取消")
            .font(.system(size: appearance.candidateFontSize))
            .foregroundColor(keyText.opacity(CandidateBarStyle.slotIconDimOpacity))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, outerHPadding)
    }

    // MARK: - 底部操作栏

    @ViewBuilder
    private func bottomBar(keyText: Color) -> some View {
        HStack(spacing: 0) {
            barButton(icon: "arrow.uturn.backward", label: "撤销", tint: keyText, disabled: composed.isEmpty) {
                runtime.undoComposition()
                refresh()
            }
            Divider()
            barButton(icon: "xmark", label: "取消", tint: keyText, disabled: false) {
                onCancel()
            }
            Divider()
            barButton(icon: "checkmark", label: "完成",
                      tint: canFinish ? KeyboardTheme.primaryColor(appearance) : keyText,
                      disabled: !canFinish) {
                if let text = runtime.finishComposition() {
                    onFinish(text)
                } else {
                    onCancel()
                }
            }
        }
        .frame(height: bottomBarHeight)
        .background(KeyboardTheme.background(appearance))
    }

    @ViewBuilder
    private func barButton(icon: String, label: String, tint: Color,
                           disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                Text(label)
                    .font(.system(size: 11))
            }
            .foregroundColor(disabled ? tint.opacity(CandidateBarStyle.slotIconDimOpacity) : tint)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }
}
