import SwiftUI
import OpenIMECore

struct CandidateExpandedPanel: View {
    @EnvironmentObject private var runtime: IMERuntime
    /// 顶部候选栏当前那批候选（受 candidateLimit / ptn 侧车上限约束）：全量查询算完前先用它占位渲染
    let candidates: [MixCandidate]
    /// 当前键盘形态：全量查询要与击键时的展开走同一个 mode，否则双拼还原口径会不一致
    let mode: KeyboardMode
    let appearance: KeyboardAppearanceSettings
    let bottomBarHeight: CGFloat
    let onSelect: (MixCandidate) -> Void
    let onDismiss: () -> Void
    let onDeleteRaw: () -> Void
    
    // 从CandidateBarView提取固定布局常量，和顶部候选栏保持同源
    private let barContentHorizontalPadding: CGFloat = 8
    private let barItemHStackSpacing: CGFloat = 2
    private let barCellInnerHorizontalPadding: CGFloat = 8

    /// cell 内部 VStack / HStack 的间距（与下方 candidateCell 渲染用的 spacing 同源，供预估换行）
    private static let cellInnerSpacing: CGFloat = 1
    /// 加粗候选用负描边合成伪粗、字形略宽：估宽时按此系数放大，避免加粗行横向溢出
    private static let boldWidthFactor: CGFloat = 1.05
    /// 每个 cell 估宽的安全余量（pt）：测量与渲染字体的细微度量差、取整误差都可能让估宽偏小，
    /// 偏小会导致一行塞不下而横向溢出。宁可每个 cell 多留一点、让行略早换（多几 pt 留白），也绝不溢出
    private static let cellWidthSafetyMargin: CGFloat = 2

    /// 展开时按需算出的「绕过 ptn top-N 侧车」的全量候选；nil = 还没算好，先用 candidates 占位
    @State private var fullCandidates: [MixCandidate]? = nil

    /// 实际展示的候选：全量算完用它，否则用顶部栏占位那批
    private var displayCandidates: [MixCandidate] { fullCandidates ?? candidates }

    private var hasAnyAnnotation: Bool {
        displayCandidates.contains { mixCand in
            guard let anno = mixCand.candidate.annotation else { return false }
            return !anno.isEmpty
        }
    }

    /// 展开时算一次全量候选：先让占位（顶部栏那批）上屏，再在 Task 里补齐绕过 ptn 上限的全部候选。
    /// 全量扫描已在 allCandidatesForCurrentInput 内部移到后台队列，主线程不被阻塞，展开动画不会被冻住。
    /// 落空时 allCandidatesForCurrentInput 会退回 candidates 本身，无需替换。
    private func loadFullCandidates() {
        guard fullCandidates == nil else { return }
        let placeholderCount = candidates.count
        let queryMode = mode
        Task { @MainActor in
            let full = await runtime.allCandidatesForCurrentInput(mode: queryMode)
            guard full.count > placeholderCount else { return }
            fullCandidates = full
        }
    }

    /// 输入变化（如展开态点删除）时重置：丢弃旧的全量结果，按新输入重新算
    private func resetAndReload() {
        fullCandidates = nil
        loadFullCandidates()
    }

    // MARK: - 懒加载分行与 cell 渲染
    //
    // 内存根治：非懒的 WrapLayout 会把传入的每个 cell 都建视图并常驻（滚到底 600 个 cell 实测把
    // foot 顶到 65MB、濒临 jetsam）。改为「预分行 + LazyVStack」：先按可用宽度把全部候选分成行
    //（只算下标与预估宽度、不建视图），再交给 LazyVStack 只渲染可见的几行、滚出屏幕的行自动回收。
    // 渲染的 cell 数恒定在「可见的几十个」，与候选总数彻底解耦，一路滚到底内存也平稳。

    /// 按可用宽度把候选预估分行，返回每行的候选下标。估宽用与渲染同一套文津宋体平面字体（CJKFont.measureWidth）
    /// 并留安全余量，贪心换行规则与非懒 WrapLayout 的 computeRows 等价，只是作用在下标+预估宽度上、不建视图
    private func wrapRows(_ cands: [MixCandidate], maxWidth: CGFloat, hSpacing: CGFloat,
                          cellInnerHPadding: CGFloat) -> [[Int]] {
        let candSize = CGFloat(appearance.candidateFontSize)
        let annoSize = CGFloat(appearance.annotationFontSize)
        let bold = appearance.candidateFontBold
        let input = runtime.inputBuffer
        var rows: [[Int]] = []
        var current: [Int] = []
        var rowWidth: CGFloat = 0
        for (i, mc) in cands.enumerated() {
            let w = cellWidth(mc, candSize: candSize, annoSize: annoSize, bold: bold,
                              cellInnerHPadding: cellInnerHPadding, input: input)
            let addWidth = current.isEmpty ? w : w + hSpacing
            // 与 WrapLayout 同规则：放得下就并入当前行，放不下另起一行；
            // 单个 cell 比整行还宽时（current 为空）也独占一行，不无限循环
            if rowWidth + addWidth <= maxWidth || current.isEmpty {
                current.append(i)
                rowWidth += addWidth
            } else {
                rows.append(current)
                current = [i]
                rowWidth = w
            }
        }
        if !current.isEmpty { rows.append(current) }
        return rows
    }

    /// 预估单个候选 cell 的渲染宽度：正文（加粗按系数放大）+ 尾码，与注释取较宽者，再加左右内边距与安全余量。
    /// 只用于分行，宁可略大于实际（早换行、留白）也不能小于实际（溢出）
    private func cellWidth(_ mc: MixCandidate, candSize: CGFloat, annoSize: CGFloat, bold: Bool,
                           cellInnerHPadding: CGFloat, input: String) -> CGFloat {
        var textWidth = CJKFont.measureWidth(mc.candidate.text, size: candSize)
        if bold { textWidth *= Self.boldWidthFactor }
        let suffix = runtime.remainingCode(for: mc.candidate, input: input)
        var contentWidth = textWidth
        if !suffix.isEmpty {
            contentWidth += Self.cellInnerSpacing + CJKFont.measureWidth(suffix, size: candSize)
        }
        if let anno = mc.candidate.annotation, !anno.isEmpty {
            contentWidth = max(contentWidth, CJKFont.measureWidth(anno, size: annoSize))
        }
        return ceil(contentWidth) + 2 * cellInnerHPadding + Self.cellWidthSafetyMargin
    }

    /// 单个候选 cell（与原 WrapLayout 内的 cell 渲染逐属性一致，仅提取成方法供 LazyVStack 行内复用）
    @ViewBuilder
    private func candidateCell(_ mixCand: MixCandidate, hasAnyAnno: Bool,
                               cellInnerHPadding: CGFloat, cellVerticalPadding: CGFloat) -> some View {
        Button {
            onSelect(mixCand)
        } label: {
            let textColor: Color = mixCand.colorHex.flatMap { Color(hex: $0) } ?? KeyboardTheme.keyText(appearance)
            // 与顶部候选栏同源：形码 / 音形码候选后跟剩余整码
            let suffix = runtime.remainingCode(for: mixCand.candidate, input: runtime.inputBuffer)
            VStack(spacing: Self.cellInnerSpacing) {
                if let anno = mixCand.candidate.annotation, !anno.isEmpty {
                    Text(anno)
                        .font(CJKFont.annotation(size: appearance.annotationFontSize))
                        .foregroundColor(textColor.opacity(0.7))
                } else if hasAnyAnno {
                    Text(" ")
                        .font(CJKFont.annotation(size: appearance.annotationFontSize))
                        .opacity(0)
                }
                HStack(spacing: Self.cellInnerSpacing) {
                    CandidateBodyText(text: mixCand.candidate.text, size: appearance.candidateFontSize, bold: appearance.candidateFontBold, color: textColor)
                    if !suffix.isEmpty {
                        // 与顶部候选栏同源：尾码跟正文同字号，只靠淡色区分层级
                        Text(suffix)
                            .font(CJKFont.annotation(size: appearance.candidateFontSize))
                            .foregroundColor(textColor.opacity(0.7))
                    }
                }
            }
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.vertical, cellVerticalPadding)
            .padding(.horizontal, cellInnerHPadding)
        }
        .buttonStyle(.plain)
    }

    var body: some View {
        GeometryReader { geo in
            let panelWidth = geo.size.width
            let baseReferenceWidth: CGFloat = 430
            let scaleRatio = panelWidth / baseReferenceWidth
            let clampedScale = max(0.8, min(scaleRatio, 1.4))
            
            // 动态缩放，和顶部候选条保持一致
            let outerHozPadding = barContentHorizontalPadding * clampedScale
            let itemHSpace = barItemHStackSpacing * clampedScale
            let cellInnerHPadding = barCellInnerHorizontalPadding * clampedScale
            let vLineSpacing = itemHSpace * 2.0 // 行间距，可微调倍数
            
            let cellVerticalPadding: CGFloat = 6

            let refDragMinDistance: CGFloat = 20
            let refDragDismissThreshold: CGFloat = 30
            let dragMinDistance = refDragMinDistance * clampedScale
            let dragDismissThreshold = refDragDismissThreshold * clampedScale

            // 懒加载分行：预先按可用宽度把全部候选分成行（只算下标与预估宽度、不建视图），
            // 交给 LazyVStack 只渲染可见的几行、滚出屏幕的行自动回收。hasAnyAnno 在此算一次遮蔽
            // 同名计算属性，避免每个 cell 都遍历全量候选（O(n²)）——与顶部候选栏 hasAnyAnno 同一修法
            let hasAnyAnno = self.hasAnyAnnotation
            let availWidth = panelWidth - 2 * outerHozPadding
            let rows = wrapRows(displayCandidates, maxWidth: availWidth, hSpacing: itemHSpace,
                                cellInnerHPadding: cellInnerHPadding)

            VStack(spacing:0) {
                // 上方：候选滚动区域（LazyVStack 按行懒渲染，内存与候选总数解耦）
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: vLineSpacing) {
                        ForEach(rows.indices, id: \.self) { r in
                            HStack(spacing: itemHSpace) {
                                ForEach(rows[r], id: \.self) { idx in
                                    candidateCell(displayCandidates[idx], hasAnyAnno: hasAnyAnno,
                                                  cellInnerHPadding: cellInnerHPadding,
                                                  cellVerticalPadding: cellVerticalPadding)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, outerHozPadding)
                }
                .onAppear { loadFullCandidates() }
                .onChange(of: runtime.inputBuffer) { _ in resetAndReload() }

                // 底部操作栏与上方候选区之间补一条分隔线，与栏内按钮之间的竖直
                // Divider 同一观感（此前只有竖线、顶边无线，看着像缺了上边框）
                Divider()

                // 底部操作栏：改成VStack撑满 + 外层手势，整块区域点击生效
                HStack(spacing: 0) {
                    // 左侧删除整块区域
                    VStack {
                        Image(systemName: "delete.left")
                            .font(.system(size:14, weight:.semibold))
                            .foregroundColor(KeyboardTheme.keyText(appearance))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        onDeleteRaw()
                    }

                    Divider()

                    // 右侧收起整块区域
                    VStack {
                        Image(systemName: "chevron.up")
                            .font(.system(size:14, weight:.semibold))
                            .foregroundColor(KeyboardTheme.keyText(appearance))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        onDismiss()
                    }
                }
                .frame(height: bottomBarHeight)
                .background(KeyboardTheme.background(appearance))
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .background(KeyboardTheme.background(appearance))
            .gesture(
                DragGesture(minimumDistance: dragMinDistance, coordinateSpace: .local)
                    .onEnded { value in
                        if value.translation.height > dragDismissThreshold {
                            onDismiss()
                        }
                    }
            )
        }
    }
}

struct WrapLayout: Layout {
    var hSpacing: CGFloat
    var vSpacing: CGFloat
    
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = computeRows(proposal: proposal, subviews: subviews)
        return CGSize(width: proposal.width ?? .infinity, height: result.totalHeight)
    }
    
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = computeRows(proposal: proposal, subviews: subviews).rows
        var y = bounds.minY
        for row in rows {
            var x = bounds.minX
            let rowHeight = row.map{$0.size.height}.max() ?? 0
            for item in row {
                item.view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(item.size))
                x += item.size.width + hSpacing
            }
            y += rowHeight + vSpacing
        }
    }
    
    private func computeRows(proposal: ProposedViewSize, subviews: Subviews) -> (rows: [[(view: LayoutSubview, size: CGSize)]], totalHeight: CGFloat) {
        guard let maxWidth = proposal.width else {
            return ([],0)
        }
        var rows: [[(view: LayoutSubview, size: CGSize)]] = []
        var currentRow: [(view: LayoutSubview, size: CGSize)] = []
        var rowWidth: CGFloat = 0
        var totalHeight: CGFloat = 0
        
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            let addWidth = currentRow.isEmpty ? size.width : (size.width + hSpacing)
            if rowWidth + addWidth <= maxWidth {
                currentRow.append((view, size))
                rowWidth += addWidth
            } else {
                rows.append(currentRow)
                let rowH = currentRow.map{$0.size.height}.max() ?? 0
                totalHeight += rowH + vSpacing
                currentRow.removeAll()
                currentRow.append((view, size))
                rowWidth = size.width
            }
        }
        if !currentRow.isEmpty {
            rows.append(currentRow)
            let rowH = currentRow.map{$0.size.height}.max() ?? 0
            totalHeight += rowH
        }
        return (rows, totalHeight)
    }
}

