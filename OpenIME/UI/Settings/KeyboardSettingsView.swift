import OpenIMECore
import SwiftUI

// MARK: - 键盘外观设置页（含实时预览）

struct KeyboardSettingsView: View {
    @EnvironmentObject private var runtime: IMERuntime
    @State private var appearance: KeyboardAppearanceSettings = KeyboardAppearanceSettings()
    @State private var layout: KeyboardLayoutSettings = KeyboardLayoutSettings()
    /// 「候选栏快捷功能」配置页呈现开关。入口放导航栏按钮而不是往 Form 里加 Section：
    /// 它是一个独立的导航动作，放导航栏语义更清晰，也不占下方 Form 的滚动高度。
    @State private var showShortcutSettings = false
    @FocusState private var isTextFieldFocused: Bool

    var body: some View {
        NavigationStack {
            // 页面宽度由 GeometryReader 直接给出（这里一定是确定值），
            // 预览按「页面宽度 − 页面左右留白」绘制，不读屏幕尺寸、不依赖测量回传
            GeometryReader { page in
                let previewWidth = Swift.max(page.size.width - Self.pageHorizontalPadding * 2, 0)
                // 预览固定在顶部、不随下方设置滚动：把预览移出滚动区当作常驻页头，
                // 下方只留 Form 自己滚（Form 本就是可滚动容器）—— 单层滚动，
                // 用户上下滑动设置项时预览键盘样式始终停在顶部可见。
                VStack(spacing: 0) {
                    KeyboardPreviewView(appearance: appearance, layout: layout, containerWidth: previewWidth)
                        .padding(.horizontal, Self.pageHorizontalPadding)
                        .padding(.vertical, 12)

                    Divider()

                    Form {
                        themeSection
                        sizeSection
                        styleSection
                        backgroundSection
                        layoutSection
                    }
                    .scrollDismissesKeyboard(.immediately)
                }
                .navigationTitle("键盘外观")
                // 预览已固定为常驻页头：导航标题改用 inline（小标题常驻导航栏、不随内容滚动），
                // 否则 large 大标题会随下方 Form 滚动折叠上移，与固定住的预览脱节、看着像标题在漂。
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button {
                            showShortcutSettings = true
                        } label: {
                            Image(systemName: "square.grid.2x2")
                        }
                        .accessibilityLabel("候选栏快捷功能")
                    }
                }
                .navigationDestination(isPresented: $showShortcutSettings) {
                    CandidateBarShortcutSettingsView()
                }
                .onChange(of: appearance) { _ in save() }
                .onChange(of: layout) { _ in save() }
                .onAppear {
                    appearance = runtime.settings.keyboardAppearance
                    layout = runtime.settings.keyboardLayout
                }
            }
        }
    }

    /// 页面左右留白（预览与表单同一份，改一处两边一起变）
    private static let pageHorizontalPadding: CGFloat = 16

    // MARK: - 主题

    var themeSection: some View {
        Section("主题") {
            Picker("模式", selection: $appearance.theme) {
                Text("浅色").tag(ThemeMode.light)
                Text("深色").tag(ThemeMode.dark)
                Text("跟随系统").tag(ThemeMode.followSystem)
            }
            .pickerStyle(.segmented)
        }
    }

    // MARK: - 尺寸

    var sizeSection: some View {
        Section("尺寸") {
            LabeledSlider(title: "键间距", value: $appearance.keySpacing,
                          range: 0...20, unit: "pt")
            LabeledSlider(title: "字母大小", value: $appearance.keyFontSize,
                          range: 8...32, unit: "pt")
            // 候选加粗：文津宋体仅一个字重，开启后系统合成伪粗，宋体细笔画在小字号下更清晰
            Toggle("候选加粗", isOn: $appearance.candidateFontBold)
                .accessibilityIdentifier("candidateFontBoldToggle")
            LabeledSlider(title: "候选大小", value: $appearance.candidateFontSize,
                          range: 8...32, unit: "pt")
            LabeledSlider(title: "注释大小", value: $appearance.annotationFontSize,
                          range: 2...24, unit: "pt")
        }
    }

    // MARK: - 样式

    var styleSection: some View {
        Section("样式") {
            LabeledSlider(title: "圆角", value: $appearance.keyCornerRadius,
                          range: 0...16, unit: "pt")

            ColorPickerRow(title: "主色调", hex: $appearance.primaryColor)
        }
    }

    // MARK: - 背景

    var backgroundSection: some View {
        Section("背景") {
            LabeledSlider(title: "背景透明度", value: $appearance.backgroundOpacity,
                          range: 0.1...1.0, unit: "")
        }
    }

    private func save() {
        var settings = runtime.settings
        settings.keyboardAppearance = appearance
        settings.keyboardLayout = layout
        runtime.updateSettings(settings)
    }

    // MARK: - 键盘布局

    var layoutSection: some View {
        Section("键盘布局") {
            // 键盘高度：滑杆按整数百分比走（85%–180%），100% = 默认正方形；
            // 底层存的是比例（0.85–1.80），几何会重算键高、键宽不变，预览与真键盘同源跟随。
            // 上限 180%：竖屏下键高远未触到「屏高乘 maxLetterKeyHeightRatio(0.115)」护栏（那要 ~290%），
            // 系数完全生效、真实变高；横屏由同一护栏自动兜底不溢出。
            LabeledSlider(title: "键盘高度",
                          value: Binding(
                            get: { layout.keyboardHeightRatio * 100 },
                            set: { layout.keyboardHeightRatio = $0 / 100 }),
                          range: 85...180, unit: "%")

            LabeledSlider(title: "行间距比例", value: $layout.rowSpacingRatio,
                          range: 0.05...0.50, unit: "")

            HStack {
                Text("空格键标签")
                Spacer()
                TextField("space", text: $layout.spaceBarLabel)
                    .multilineTextAlignment(.trailing)
                    .foregroundColor(.secondary)
                    .frame(width: 120)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .focused($isTextFieldFocused)
                    .onSubmit { isTextFieldFocused = false }
            }
        }
    }
}

// MARK: - 键盘实时预览组件
//
// 按当前键盘形态绘制：几何与真键盘同源（Shared/KeyboardMetrics），
// 键面配色与真键盘同源（Shared/KeyboardStyle），设置页所见即真键盘所得。

struct KeyboardPreviewView: View {
    let appearance: KeyboardAppearanceSettings
    let layout: KeyboardLayoutSettings
    /// 预览可用宽度（由页面层级传入，本身不读屏幕宽度）
    let containerWidth: CGFloat

    /// 键盘形态与真键盘同源：读同一份持久化（App Group UserDefaults）
    private var mode: KeyboardMode { KeyboardModeStore.shared.mode }

    /// 与键盘扩展完全同源的几何（Shared/KeyboardMetrics）
    private var metrics: KeyboardMetrics {
        KeyboardMetrics(screenWidth: containerWidth,
                        screenHeight: UIScreen.main.bounds.height,
                        layoutSettings: layout,
                        appearanceSettings: appearance)
    }

    var body: some View {
        let m = metrics
        let a = appearance
        let cr = CGFloat(appearance.keyCornerRadius)

        VStack(spacing: 0) {
            // 候选栏（高度与实际一致：无注释时只显示候选词行高）
            HStack(spacing: 0) {
                ForEach(["你好", "你", "好的"], id: \.self) { word in
                    // 真键盘候选正文已改用文津宋体（衬线/宋体族）；预览若仍用默认黑体会与真键盘
                    // 观感不一致。这里用系统衬线设计（宋体）对齐字族，且不必为主 App 预览再内置一份字体
                    Text(word)
                        .font(.system(size: appearance.candidateFontSize, design: .serif))
                        .fontWeight(appearance.candidateFontBold ? .bold : .regular)
                        .foregroundColor(KeyboardTheme.keyText(a))
                        .padding(.horizontal, 12)
                }
                Spacer()
            }
            .frame(height: CGFloat(appearance.candidateBarHeight(showAnnotation: false)))
            .background(KeyboardTheme.background(a))

            // 键盘体：按当前键盘形态画对应布局
            Group {
                switch mode {
                case .pinyin26: pinyin26Body(m: m, cr: cr, a: a)
                case .heEr:     heErBody(m: m, cr: cr, a: a)
                }
            }
            .padding(.top, m.topBotPad)
            // 键盘体高度与实际键盘一致（含底部留白），预览比例不再凭感觉
            .frame(height: m.bodyHeight, alignment: .top)
            .background(KeyboardTheme.background(a))
            .opacity(appearance.backgroundOpacity)
        }
        .frame(maxWidth: .infinity)
        .cornerRadius(14)
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color(.systemGray4), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.08), radius: 6, x: 0, y: 2)
        // 预览里的字母 / 假候选只是示意图，不该被读屏逐字念出来：
        // 整块作为一个图形元素暴露，同时给 UI 测试一个稳定的标识
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("键盘外观预览")
        .accessibilityIdentifier("keyboardPreview")
    }

    // MARK: 全拼 26 键

    @ViewBuilder
    private func pinyin26Body(m: KeyboardMetrics, cr: CGFloat, a: KeyboardAppearanceSettings) -> some View {
        VStack(spacing: m.rowSpacing) {
            HStack(spacing: m.keySpacing) {
                ForEach(KeyboardLetterRows.rows[0], id: \.self) { key in
                    letterKey(String(key), m: m, cr: cr, a: a)
                }
            }
            .padding(.horizontal, m.hPad)

            // 第二行（缩进与实际一致）
            HStack(spacing: m.keySpacing) {
                ForEach(KeyboardLetterRows.rows[1], id: \.self) { key in
                    letterKey(String(key), m: m, cr: cr, a: a)
                }
            }
            .padding(.horizontal, m.hPad + m.row2Indent)

            // 第三行：Shift + 字母 + 退格（退格用红色，与实际一致）
            HStack(spacing: m.keySpacing) {
                iconKeyBox(icon: "shift", width: m.funcKeyWidth, height: m.keyHeight, m: m, cr: cr, a: a,
                           tint: KeyboardTheme.shiftKeyTint)
                ForEach(KeyboardLetterRows.rows[2], id: \.self) { key in
                    letterKey(String(key), m: m, cr: cr, a: a)
                }
                backspaceBox(height: m.keyHeight, iconHeight: m.letterKeyWidth, m: m, cr: cr, a: a)
            }
            .padding(.horizontal, m.hPad)

            bottomRow(m: m, cr: cr, a: a, height: m.keyHeight)
        }
    }

    // MARK: 小鹤双拼

    @ViewBuilder
    private func heErBody(m: KeyboardMetrics, cr: CGFloat, a: KeyboardAppearanceSettings) -> some View {
        VStack(spacing: m.rowSpacing) {
            HStack(spacing: m.keySpacing) {
                ForEach(KeyboardLetterRows.rows[0], id: \.self) { key in
                    heErKey(key, m: m, cr: cr, a: a)
                }
            }
            .padding(.horizontal, m.hPad)

            HStack(spacing: m.keySpacing) {
                ForEach(KeyboardLetterRows.rows[1], id: \.self) { key in
                    heErKey(key, m: m, cr: cr, a: a)
                }
            }
            .padding(.horizontal, m.hPad + m.row2Indent)

            HStack(spacing: m.keySpacing) {
                iconKeyBox(icon: "shift", width: m.funcKeyWidth, height: m.keyHeight, m: m, cr: cr, a: a,
                           tint: KeyboardTheme.shiftKeyTint)
                ForEach(KeyboardLetterRows.rows[2], id: \.self) { key in
                    heErKey(key, m: m, cr: cr, a: a)
                }
                backspaceBox(height: m.keyHeight, iconHeight: m.letterKeyWidth, m: m, cr: cr, a: a)
            }
            .padding(.horizontal, m.hPad)

            bottomRow(m: m, cr: cr, a: a, height: m.keyHeight)
        }
    }

    /// 双拼键面：与真键盘同一段排版代码的预览版——
    /// 灰大写物理字母 + 红声母同行，蓝色韵母按 / 拆行平分剩余键高
    @ViewBuilder
    private func heErKey(_ key: Character, m: KeyboardMetrics,
                         cr: CGFloat, a: KeyboardAppearanceSettings) -> some View {
        let label = HeErDoublePinyin.shared.keyLabels[key]
        let initial = HeErDoublePinyin.keyInitials[key]
        let finalLines = (label?.finals ?? "")
            .split(separator: "/")
            .prefix(LayeredKeycapStyle.heErMaxFinalLines)
            .map(String.init)
        let lineCount = Swift.max(1, finalLines.count)
        // 字号与真键盘同一推导（按键宽实测回退），预览才能真反映出「调大按键字号后声母会不会被挤」
        let topFont = LayeredKeycapStyle.heErTopRowFontSize(letterFontSize: m.letterFontSize,
                                                            keyWidth: m.letterKeyWidth)
        let finalsFont = LayeredKeycapStyle.heErFinalFontSize(letterFontSize: m.letterFontSize,
                                                              keyWidth: m.letterKeyWidth,
                                                              lineCount: lineCount)
        let letterLineH = m.keyHeight * LayeredKeycapStyle.heErTopRowHeightRatio
        let finalsAreaH = Swift.max(m.keyHeight - letterLineH
                                    - KeyboardKeyStyle.labelLineSpacing * CGFloat(lineCount), 0)
        let perFinalH = finalsAreaH / CGFloat(lineCount)

        VStack(spacing: KeyboardKeyStyle.labelLineSpacing) {
            HStack(spacing: LayeredKeycapStyle.heErInitialGap) {
                Text(String(key).uppercased())
                    .font(.system(size: topFont, weight: .regular))
                    .foregroundColor(KeyboardTheme.keyText(a)
                        .opacity(LayeredKeycapStyle.keyLetterDim))
                if let initial = initial, !initial.isEmpty {
                    Text(initial)
                        .font(.system(size: topFont, weight: .semibold))
                        .foregroundColor(LayeredKeycapStyle.initialColor)
                }
            }
            .lineLimit(1)
            .frame(height: letterLineH)

            ForEach(finalLines, id: \.self) { line in
                Text(line)
                    .font(.system(size: finalsFont, weight: .medium))
                    .foregroundColor(LayeredKeycapStyle.finalColor)
                    .lineLimit(1)
                    .minimumScaleFactor(KeyboardKeyStyle.annotationMinScale)
                    .padding(.horizontal, KeyboardKeyStyle.heErFinalHorizontalPadding)
                    .frame(height: perFinalH)
            }
        }
        .frame(width: m.letterKeyWidth)
        .frame(height: m.keyHeight)
        .background(RoundedRectangle(cornerRadius: cr).fill(KeyboardTheme.keyFill(a)))
        .keyCapDepth()
    }

    // MARK: 共用键位盒子

    /// 底行：左下角键（123 / 地球）+ 弹性空格 + 右下回车键，与真键盘同源渲染
    @ViewBuilder
    private func bottomRow(m: KeyboardMetrics, cr: CGFloat,
                           a: KeyboardAppearanceSettings, height: CGFloat) -> some View {
        HStack(spacing: m.keySpacing) {
            switch layout.leftBottomKey {
            case .nextKeyboard:
                iconKeyBox(icon: "globe", width: m.bottomCornerKeyWidth, height: height, m: m, cr: cr, a: a)
            case .number123:
                funcKeyBox(label: "123", width: m.bottomCornerKeyWidth, height: height, m: m, cr: cr, a: a)
            }

            // 空格键：标签跟随「空格键标签」设置
            Text(layout.spaceBarDisplayLabel)
                .font(.system(size: KeyboardKeyStyle.secondaryTextFontSize(
                    letterFontSize: m.letterFontSize)))
                .foregroundColor(KeyboardTheme.keyText(a))
                .frame(maxWidth: .infinity)
                .frame(height: height)
                .background(RoundedRectangle(cornerRadius: cr).fill(KeyboardTheme.keyFill(a)))
                .keyCapDepth()

            returnBox(height: height, m: m, cr: cr, a: a)
        }
        .padding(.horizontal, m.hPad)
    }

    private func letterKey(_ label: String, m: KeyboardMetrics,
                           cr: CGFloat, a: KeyboardAppearanceSettings) -> some View {
        Text(label)
            .font(.system(size: CGFloat(appearance.keyFontSize), weight: .regular))
            .foregroundColor(KeyboardTheme.keyText(a))
            // 正方形：宽 = 高，都是网格推导出来的边长（不再被行宽拉伸）
            .frame(width: m.letterKeyWidth, height: m.keyHeight)
            .background(RoundedRectangle(cornerRadius: cr).fill(KeyboardTheme.keyFill(a)))
            .keyCapDepth()
    }

    /// 主色调淡底文字功能键（123）
    private func funcKeyBox(label: String, width: CGFloat, height: CGFloat,
                            m: KeyboardMetrics, cr: CGFloat,
                            a: KeyboardAppearanceSettings) -> some View {
        Text(label)
            .font(.system(size: m.funcFontSize))
            .foregroundColor(KeyboardTheme.primaryColor(a))
            .frame(width: width, height: height)
            .background(KeyboardTheme.tintedKeyFill(a, tint: KeyboardTheme.primaryColor(a).opacity(KeyboardKeyStyle.tintedKeyFillOpacity)))
            .cornerRadius(cr)
            .keyCapDepth()
    }

    /// 淡底图标功能键（地球用主色、Shift 用淡绿）：tint 为 nil 时回落主色调
    private func iconKeyBox(icon: String, width: CGFloat, height: CGFloat,
                            m: KeyboardMetrics, cr: CGFloat,
                            a: KeyboardAppearanceSettings, tint: Color? = nil) -> some View {
        let keyTint = tint ?? KeyboardTheme.primaryColor(a)
        // 图标字号基准取 letterKeyWidth（高度无关）而非 height：调高键盘时预览里的 shift / 地球
        // 图标不随键高变粗，与真键盘同一修法；默认系数下 letterKeyWidth == keyHeight，逐字节一致
        return Image(systemName: icon)
            .font(.system(size: KeyboardGridGeometry.iconFontSize(forKeyHeight: m.letterKeyWidth),
                          weight: .medium))
            .foregroundColor(keyTint)
            .frame(width: width, height: height)
            .background(KeyboardTheme.tintedKeyFill(a, tint: keyTint.opacity(KeyboardKeyStyle.tintedKeyFillOpacity)))
            .cornerRadius(cr)
            .keyCapDepth()
    }

    /// 退格键：红色淡底；图标字号按传入的基准行高走（跨多行的退格键图标也不变粗，与真键盘同一修法）
    private func backspaceBox(height: CGFloat, iconHeight: CGFloat,
                              m: KeyboardMetrics, cr: CGFloat,
                              a: KeyboardAppearanceSettings) -> some View {
        Image(systemName: "delete.left")
            .font(.system(size: KeyboardGridGeometry.iconFontSize(forKeyHeight: iconHeight),
                          weight: .medium))
            .foregroundColor(Color(.systemRed))
            .frame(width: m.funcKeyWidth, height: height)
            .background(KeyboardTheme.tintedKeyFill(a, tint: Color(.systemRed).opacity(KeyboardKeyStyle.tintedKeyFillOpacity)))
            .cornerRadius(cr)
            .keyCapDepth()
    }

    /// 回车键：淡蓝底 + 蓝对勾（与真键盘 ReturnKey 同一套 tintedKeyFill 设计语言）
    private func returnBox(height: CGFloat, m: KeyboardMetrics,
                           cr: CGFloat, a: KeyboardAppearanceSettings) -> some View {
        Image(systemName: "checkmark")
            .font(.system(size: m.funcFontSize * KeyboardGridGeometry.returnIconFontRatio, weight: .semibold))
            .foregroundColor(KeyboardTheme.returnKeyTint)
            .frame(width: m.bottomCornerKeyWidth, height: height)
            .background(KeyboardTheme.tintedKeyFill(a, tint: KeyboardTheme.returnKeyTint.opacity(KeyboardKeyStyle.tintedKeyFillOpacity)))
            .cornerRadius(cr)
            .keyCapDepth()
    }
}

// MARK: - 通用滑块行

struct LabeledSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let unit: String

    private var isIntRange: Bool { range.lowerBound == range.lowerBound.rounded() && range.upperBound == range.upperBound.rounded() && (range.upperBound - range.lowerBound) >= 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(isIntRange
                     ? (unit.isEmpty ? String(format: "%.0f", value) : String(format: "%.0f\(unit)", value))
                     : String(format: "%.2f", value))
                    .foregroundColor(.secondary)
                    .monospacedDigit()
            }
            if isIntRange {
                Slider(value: $value, in: range, step: 1)
            } else {
                Slider(value: $value, in: range)
            }
        }
    }
}

// MARK: - 颜色选择行

struct ColorPickerRow: View {
    let title: String
    @Binding var hex: String
    @State private var showPicker = false

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Button {
                showPicker = true
            } label: {
                HStack(spacing: 8) {
                    Text(hex).font(.system(.caption, design: .monospaced))
                        .foregroundColor(.secondary)
                    Circle()
                        .fill(Color(hex: hex) ?? .blue)
                        .frame(width: 24, height: 24)
                        .overlay(Circle().stroke(Color(.systemGray4), lineWidth: 1))
                }
            }
            .buttonStyle(.plain)
            .sheet(isPresented: $showPicker) {
                CandidateColorPickerView(selectedHex: $hex) {
                    showPicker = false
                }
            }
        }
    }
}

// MARK: - Color hex 扩展已下沉到 Shared/Models/KeyboardStyle.swift（全仓唯一一份）
