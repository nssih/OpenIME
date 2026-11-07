import SwiftUI
import OpenIMECore

// MARK: - 候选栏视图
// 两种键盘形态共用：这里只负责「候选词可横滑 + 展开面板」。
// 键盘体上也不再有左侧拼音选择列 —— 双拼键位一对一，一次输入只还原得出一条读音，没有可挑的东西。
//
// 两端槽位：
//   有候选时：右侧是「展开列表」键（行为与原来一致）
//   无候选 / 无输入时：右侧同位置换成「主动收起键盘」，左侧放一个菜单标志（点开快捷面板）
//   三个槽位的尺寸都引用「字母键边长」（= q / p 键尺寸），由调用方传入，本视图不写死点数。
struct CandidateBarView: View {
    @EnvironmentObject private var runtime: IMERuntime
    let candidates: [MixCandidate]
    let inputBuffer: String
    @Binding var isExpanded: Bool
    let onSelect: (MixCandidate) -> Void
    /// 点开手动组句面板（输入达词图长度时出现在展开键左边）
    let onEnterComposition: () -> Void
    /// 字母键边长（q / p 键的实际尺寸）：两端槽位的宽高都用它，不写死
    let letterKeySize: CGFloat
    /// 键盘最外层左右留白（= 字母行的 .padding(.horizontal, m.hPad)）：右端收起 / 展开键据此
    /// 回缩，让图标中心正对上排 p 键的中心。候选栏本身横跨整宽、无水平内边距，若右端槽位贴屏幕
    /// 右缘，图标中心会比 p 键中心右偏一个 hPad（用户反馈「收起键没居中 p 键、偏右」）。
    let hPad: CGFloat
    /// 顶行字母键之间的间距（= metrics.keySpacing）：算 o·p 两键间隙中点用，
    /// 组句键 / 下拉展开键据此对齐到 o 键左缘与 o·p 中点（见 CandidateBarStyle 的几何纯函数）。
    let keySpacing: CGFloat
    /// 主动收起键盘（空态时占据「展开列表」的位置）
    let onDismissKeyboard: () -> Void
    /// 点开快捷面板（空态时左侧的标志）
    let onOpenLogoPanel: () -> Void
    /// 空态中段的用户自定义快捷功能条（默认全选 6 个 bar-eligible 功能；用户删空后中段才留白）
    let barShortcuts: [CandidateBarShortcut]
    /// 某个快捷功能当前是否处于「开」状态（用于着色，口径见 CandidateBarShortcut.reflectsState）
    let shortcutOn: (CandidateBarShortcut) -> Bool
    /// 点击某个快捷功能
    let onShortcut: (CandidateBarShortcut) -> Void

    private var appearance: KeyboardAppearanceSettings { runtime.settings.keyboardAppearance }
    private var showAnnotation: Bool { runtime.settings.showAnnotation }
    private var schemeConfigs: [String: SchemeUserConfig] { runtime.settings.schemeConfigs }
    
    // 本批候选里是否「真的会画出注释」：只要有一条带非空注释、且该方案注释开关开着就算有。
    // 不能拿 runtime.showAnnotationRow（按方案有没有 annotation 列算）来门控——
    // 虎码这类形码方案没有 annotation 列、showAnnotationRow 为 false，但候选实际带了编码注释；
    // 若用它门控，无注释的候选就不会补占位行，文字底边会和有注释的候选错开。
    // 口径与展开面板（CandidateExpandedPanel.hasAnyAnnotation）保持一致：看实际有无注释。
    private var hasAnyAnno: Bool {
        candidates.contains { mixCand in
            let c = mixCand.candidate
            let annoEnabled = showAnnotation &&
                (schemeConfigs[c.sourceSchemeId]?.showAnnotation ?? true)
            return annoEnabled && c.annotation != nil && !c.annotation!.isEmpty
        }
    }
    
    // 永久固定为开启注释时的高度
    private var barH: CGFloat {
        CGFloat(appearance.candidateBarHeight(showAnnotation: true))
    }
    
    // 候选词行高度
    private var candidateTextH: CGFloat {
        CGFloat(appearance.candidateFontSize) + CandidateBarStyle.candidateTextExtraHeight
    }
    
    // 本批没有任何注释时，把候选词往下推到视觉居中；
    // 本批有注释时不推（注释行贴顶、各候选文字底边靠占位行对齐）
    private var topInset: CGFloat {
        if hasAnyAnno {
            return 0
        } else {
            let diff = Swift.max(0, barH - candidateTextH)
            return diff * 0.5
        }
    }
    
    var body: some View {
        let barBg = KeyboardTheme.background(appearance)
        let defaultTextColor = KeyboardTheme.keyText(appearance)
        let hasContent = !inputBuffer.isEmpty && !candidates.isEmpty
        // 「组句」入口只在有候选、且输入长度落入词图区间时出现：太短的串常规候选就够了，
        // 长串才需要用户手动定夺「由哪些字 / 词组成」。isLatticeLength 只是长度区间判定，每键调极廉价。
        let canCompose = hasContent && CandidateEngine.isLatticeLength(inputBuffer.count)
        // 两端槽位的边长：与字母键（q / p）同尺寸，并保证不超出候选栏高度
        let slotSize = Swift.min(letterKeySize, barH)
        // 右端槽位图标的 trailing 回缩量：让图标中心对齐上排 p 键中心。
        // p 键右缘距屏幕右缘 hPad、宽 letterKeySize；图标宽 slotSize（可能被 barH 截小），
        // 故回缩 = hPad + 两者半宽之差；slotSize == letterKeySize（竖屏常态）时即回缩 hPad。
        let slotTrailingInset = hPad + (letterKeySize - slotSize) / 2
        // hasAnyAnno 要遍历全部候选，而下面 ForEach 里每个候选 cell 都读它一次；直接读计算属性的话
        // 80 个候选会把它算 80 遍 = O(n²)，每键重绘白白拖慢候选栏。顶部算一次存成局部常量，
        // ForEach 里复用这个局部值，渲染回到 O(n)。（局部 hasAnyAnno 在 body 内遮蔽同名计算属性）
        let hasAnyAnno = self.hasAnyAnno

        HStack(spacing: 0) {
            if !hasContent {
                // 空态左侧的菜单标志，尺寸引用字母键边长
                logoSlot(size: slotSize)
            }

            GeometryReader { geo in
                ScrollView(.horizontal, showsIndicators: false) {
                    if hasContent {
                        // LazyHStack：每键只渲染可见的十来格，候选总数（candidateLimit 已提到 300）上涨
                        // 不再增加每键渲染成本 —— 这是「候选多又不卡」的前提（普通 HStack 会一次建全部子视图）
                        LazyHStack(spacing: 2) {
                            ForEach(Array(candidates.enumerated()), id: \.offset) { idx, mixCand in
                                let c = mixCand.candidate
                                let annoEnabled = showAnnotation &&
                                    (schemeConfigs[c.sourceSchemeId]?.showAnnotation ?? true)
                                let textColor: Color = mixCand.colorHex.flatMap { Color(hex: $0) } ?? defaultTextColor
                                Button { onSelect(mixCand) } label: {
                                    candidateLabel(c: c, textColor: textColor, annoEnabled: annoEnabled, hasAnyAnno: hasAnyAnno)
                                }
                                .buttonStyle(.plain)
                                // 候选槽位标识（与主 App 打字区的 mixCandidate-N 同一套约定）：
                                // 宿主 App 自己也可能有同字文本的行（如 Safari 搜索建议），
                                // 按文字在全 app 范围找会先命中它们，按槽位标识找才是键盘里的候选
                                .accessibilityIdentifier("candidate-\(idx)")
                            }
                        }
                        .padding(.horizontal, 4)
                    } else {
                        // 空态：中段横向区改渲染用户自定义的快捷功能图标（溢出天然可横滑），
                        // 两端固定槽位（左切换标志、右收起键）不受影响。
                        // 排列方向：从右往左，最早添加的贴右端（靠近收起键），
                        // 后加的按添加顺序依次往左排；故显示时把 store 顺序反转（reversed）再交给从左往右的 HStack。
                        // 右锚的关键：横向 ScrollView 对内容给的是无界宽提案，单用 maxWidth:.infinity 会塌成
                        // 内容理想宽、trailing 无多余空间可用（图标仍贴左）；必须用 minWidth 撑到可视宽
                        // （geo.size.width）再 trailing，图标少时才真正贴右端。
                        HStack(spacing: 2) {
                            ForEach(barShortcuts.reversed()) { shortcut in
                                Button { onShortcut(shortcut) } label: {
                                    shortcutIcon(shortcut, size: slotSize, tint: shortcutTint(shortcut))
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(shortcut.title)
                                .accessibilityIdentifier("barShortcut-\(shortcut.id)")
                            }
                        }
                        .padding(.horizontal, 4)
                        .frame(minWidth: geo.size.width, maxWidth: .infinity, alignment: .trailing)
                    }
                }
            }
            .frame(maxHeight: .infinity)
            // 上边距只为「有候选」时把候选词推到视觉居中；空态快捷图标自身已垂直居中，
            // 不能再套这个 inset，否则整排图标会偏下
            .padding(.top, hasContent ? topInset : 0)
            .padding(.bottom, 0)

            // 分隔线只保留在「有候选」态（展开键左侧，原始设计）；
            // 空态收起键左侧不再画线，免得那条竖线显得多余
            if hasContent {
                slotDivider(color: defaultTextColor)
            }

            if canCompose {
                // 「组句」入口：手动挑字 / 词组成长句（点开组句面板），尺寸与两端槽位同源
                Button(action: onEnterComposition) {
                    Text(CandidateBarStyle.composeLabel)
                        .font(.system(size: slotSize * CandidateBarStyle.composeFontRatio, weight: .medium))
                        .foregroundColor(KeyboardTheme.primaryColor(appearance))
                        .frame(width: CandidateBarStyle.composeCellWidth(letterKeyWidth: letterKeySize,
                                                                         keySpacing: keySpacing),
                               height: slotSize)
                        .frame(maxHeight: .infinity)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(CandidateBarStyle.composeLabel)
                .accessibilityIdentifier("composeKey")
                slotDivider(color: defaultTextColor)
            }

            if hasContent {
                // 展开列表：尺寸引用字母键边长（原实现是图标 + 左右 12pt 内边距）
                Button {
                    // 不用 withAnimation：展开面板高度 panelTotalHeight == candidateH + bodyHeight，
                    // 与候选栏 + 键盘体的总高完全相同，展开根本不改键盘高度，无需动画。
                    // 包在 withAnimation 里只会触发 SwiftUI 对 if/else 结构切换的默认 opacity
                    // 交叉浡入（旧键盘体淡出 + 面板淡入），表现为用户看到的「键盘残影」。
                    // 瞬切无动画 = 无交叉浡入 = 无残影。
                    isExpanded.toggle()
                } label: {
                    slotIcon(isExpanded ? "chevron.up" : "chevron.down", size: slotSize)
                }
                .buttonStyle(.plain)
                .padding(.trailing, CandidateBarStyle.expandTrailingInset(letterKeyWidth: letterKeySize,
                                                                          keySpacing: keySpacing,
                                                                          hPad: hPad,
                                                                          slotSize: slotSize,
                                                                          hasCompose: canCompose))
                .accessibilityIdentifier("expandCandidatesKey")
            } else {
                // 没有候选时，同一位置换成主动收起键盘
                Button(action: onDismissKeyboard) {
                    slotIcon("chevron.down", size: slotSize)
                }
                .buttonStyle(.plain)
                .padding(.trailing, slotTrailingInset)
                .accessibilityIdentifier("dismissKeyboardKey")
            }
        }
        .frame(height: barH, alignment: .top)
        .background(barBg)
        .onChange(of: inputBuffer) { buf in
            if buf.isEmpty { isExpanded = false }
        }
    }

    // MARK: - 两端槽位（尺寸全部引用字母键边长）

    /// 槽位分隔线：与原有展开键左侧的分隔线完全一致
    @ViewBuilder
    private func slotDivider(color: Color) -> some View {
        Divider()
            .background(color.opacity(CandidateBarStyle.slotDividerOpacity))
            .frame(width: CandidateBarStyle.dividerWidth)
            .frame(maxHeight: .infinity)
    }

    /// 槽位图标：视觉尺寸 = 字母键边长的正方形，
    /// 点击区域仍撑满整个候选栏高度（不缩小原有的可点范围）
    @ViewBuilder
    private func slotIcon(_ name: String, size: CGFloat, tint: Color? = nil) -> some View {
        Image(systemName: name)
            .font(.system(size: size * CandidateBarStyle.barFuncIconSizeRatio, weight: .regular))
            .foregroundColor(tint ?? KeyboardTheme.keyText(appearance).opacity(CandidateBarStyle.slotIconDimOpacity))
            .frame(width: size, height: size)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
    }

    /// 快捷功能图标：有 iconText（如中/英的「En」）用文字，否则用 SF Symbol；
    /// 尺寸 / 点击区与两端槽位图标同一套基准
    @ViewBuilder
    private func shortcutIcon(_ shortcut: CandidateBarShortcut, size: CGFloat, tint: Color) -> some View {
        if let text = shortcut.iconText {
            Text(text)
                .font(.system(size: size * CandidateBarStyle.barFuncIconSizeRatio, weight: .semibold))
                .foregroundColor(tint)
                .frame(width: size, height: size)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
        } else {
            slotIcon(shortcut.symbolName, size: size, tint: tint)
        }
    }

    /// 快捷功能图标的着色：状态可反映的功能（开关型 + 剪贴板这类「颜色跟开关走」的入口）
    /// 当前为「开」用绿色（激活），其余用灰色（未激活）
    private func shortcutTint(_ shortcut: CandidateBarShortcut) -> Color {
        if shortcut.reflectsState && shortcutOn(shortcut) {
            return CandidateBarStyle.shortcutOnColor
        }
        return CandidateBarStyle.shortcutOffColor
    }

    /// 空态左侧的标志，点开覆盖键盘区的快捷面板
    /// —— 它是一个「菜单标志」（同类于 command 键上的花形符号），不是 App 图标；
    ///    图形与颜色全部从 CandidateBarStyle / 主题设置推导；
    ///    图标字号与收起键盘 / 展开候选列表两个槽位图标共用 barFuncIconSizeRatio，
    ///    三者尺寸引用同一来源，视觉大小一致
    @ViewBuilder
    private func logoSlot(size: CGFloat) -> some View {
        Button(action: onOpenLogoPanel) {
            Image(systemName: CandidateBarStyle.logoSymbolName)
                .font(.system(size: size * CandidateBarStyle.barFuncIconSizeRatio, weight: .regular))
                .foregroundColor(KeyboardTheme.primaryColor(appearance))
                .frame(width: size, height: size)
                .frame(maxHeight: .infinity)
                .padding(.leading, size * CandidateBarStyle.logoLeadingPaddingRatio)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("快捷面板")
        .accessibilityIdentifier("candidateBarLogo")
    }
    
    @ViewBuilder
    private func candidateLabel(c: Candidate, textColor: Color, annoEnabled: Bool, hasAnyAnno: Bool) -> some View {
        let hasThisAnno = annoEnabled && c.annotation != nil && !c.annotation!.isEmpty
        // 形码 / 音形码：候选词右边紧跟「还没打完的剩余整码」（输 jaf 出「今天m」）
        let suffix = runtime.remainingCode(for: c, input: inputBuffer)
        
        VStack(alignment: .center, spacing: CandidateBarStyle.lineSpacing) {
            if hasThisAnno {
                Text(c.annotation!)
                    .font(CJKFont.annotation(size: appearance.annotationFontSize))
                    .foregroundColor(textColor.opacity(CandidateBarStyle.annotationOpacity))
            } else if hasAnyAnno {
                Text(" ")
                    .font(CJKFont.annotation(size: appearance.annotationFontSize))
                    .opacity(0)
            }
            
            HStack(spacing: 1) {
                CandidateBodyText(text: c.text, size: appearance.candidateFontSize, bold: appearance.candidateFontBold, color: textColor)
                if !suffix.isEmpty {
                    // 尾码与正文同字号：两者本就在同一行，字号不同会让尾码看着像另一个元素。
                    // 层级只靠 annotationOpacity 的淡色区分；尾码恒为 ASCII 字母（第一平面），
                    // 所以仍走 annotation 的单字体路径，不必按平面分段
                    Text(suffix)
                        .font(CJKFont.annotation(size: appearance.candidateFontSize))
                        .foregroundColor(textColor.opacity(CandidateBarStyle.annotationOpacity))
                }
            }
        }
        .frame(minHeight: candidateTextH, maxHeight: .infinity, alignment: .center)
        .frame(minWidth: CGFloat(appearance.candidateFontSize) * 2)
        .padding(.horizontal, 8)
    }
}

