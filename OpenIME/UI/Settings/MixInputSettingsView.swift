import OpenIMECore
import SwiftUI

// MARK: - 混打 Tab（测试区 + 设置区）

struct MixInputSettingsView: View {
    @EnvironmentObject private var runtime: IMERuntime
    @State private var localSettings: UserSettings = UserSettings()
    @State private var showClearPredictionConfirm = false
    @State private var showClearFrequencyConfirm = false

    var body: some View {
        NavigationStack {
            // 打字测试区固定在顶部、不随下方设置滚动：把它移出滚动区当作常驻页头，下方只留 List 自己滚
            //（List 本就是可滚动容器）—— 单层滚动，用户上下滑动设置项时打字测试区始终停在顶部可见。
            // 用 VStack 常驻页头而非 safeAreaInset 悬浮页头：悬浮页头会盖住 List 顶部行，被滚到顶部的设置项
            // 落在页头底下不可点（UI 测试 requireOnScreen 只向上滚、够不到被遮挡的行而失败，还会连累 tab 导航）；
            // VStack 让 List 拿到页头下方的独立高度、内容不被遮挡。与键盘外观页固定预览同一套结构。
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("打字测试")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                    TypingTestView()
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 10)
                .background(Color(.systemGroupedBackground))

                Divider()

                List {
                    // 注释显示
                    Section {
                        Toggle(isOn: $localSettings.showAnnotation) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("显示候选注释")
                                Text("在候选词上方显示注音、拆字等附加信息")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .onChange(of: localSettings.showAnnotation) { _ in save() }
                    } header: {
                        Text("候选注释")
                    } footer: {
                        Text("开启后，词库中的拆字部件、编码提示等信息将显示在候选词上方")
                    }

                    // emoji 候选
                    Section {
                        Toggle(isOn: $localSettings.showEmoji) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("emoji 候选")
                                Text("打出某些词时，紧跟原词多给一个带 emoji 的候选（如“地球 🌍”）")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .onChange(of: localSettings.showEmoji) { _ in save() }
                    } header: {
                        Text("emoji 候选")
                    } footer: {
                        Text("对拼音 / 形码 / 双拼所有方案生效（按候选文字匹配，与输入码无关）。选带 emoji 的候选时，emoji 会一同上屏。")
                    }

                    // 智能预测
                    Section {
                        Toggle(isOn: $localSettings.showPrediction) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("智能预测")
                                Text("根据上一个上屏的词自动预测下一个词，越用越准")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .onChange(of: localSettings.showPrediction) { _ in save() }

                        Button(role: .destructive) {
                            showClearPredictionConfirm = true
                        } label: {
                            HStack {
                                Image(systemName: "trash")
                                Text("清除预测记录")
                            }
                            .foregroundColor(ClearActionStyle.foreground)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, ClearActionStyle.verticalPadding)
                            .background(ClearActionStyle.background)
                            .cornerRadius(ClearActionStyle.cornerRadius)
                        }
                        .alert("清除预测记录", isPresented: $showClearPredictionConfirm) {
                            Button("清除", role: .destructive) { runtime.clearPrediction() }
                            Button("取消", role: .cancel) {}
                        } message: {
                            Text("将清除所有已学习的词语搭配记录，此操作不可恢复。")
                        }
                    } header: {
                        Text("智能预测")
                    } footer: {
                        Text("手动选词时自动学习词语搭配，连续多次选择同一预测词后会逐渐前移至第 2 候选位置。\"字符上屏\"不参与学习。")
                    }

                    // 拼音动态调频
                    Section {
                        Toggle(isOn: $localSettings.dynamicFreqEnabled) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("拼音动态调频")
                                Text("同一个拼音常选哪个词，那个词就逐渐排到前面")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .onChange(of: localSettings.dynamicFreqEnabled) { _ in save() }

                        Button(role: .destructive) {
                            showClearFrequencyConfirm = true
                        } label: {
                            HStack {
                                Image(systemName: "trash")
                                Text("清除调频记录")
                            }
                            .foregroundColor(ClearActionStyle.foreground)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, ClearActionStyle.verticalPadding)
                            .background(ClearActionStyle.background)
                            .cornerRadius(ClearActionStyle.cornerRadius)
                        }
                        .alert("清除调频记录", isPresented: $showClearFrequencyConfirm) {
                            Button("清除", role: .destructive) { runtime.clearFrequency() }
                            Button("取消", role: .cancel) {}
                        } message: {
                            Text("将清除所有拼音选词学习记录，此操作不可恢复。")
                        }
                    } header: {
                        Text("拼音动态调频")
                    } footer: {
                        Text("仅对拼音生效（形码 / 音形码一码对一字，无需猜你想打哪个）。反复手选同一个码下的某个词，它会逐渐升至首位；改选别的词后旧词会回落。与智能预测互不影响。")
                    }

                    // 混打开关 / 参与方案 / 添加方案
                    // 主方案不是纯形码时整块不渲染，换成一段说明：混打只有一个合法方向，
                    // 与其留一个勾了也没反应的开关，不如直接讲清入口为什么不见了
                    if canMix {
                        Section {
                            Toggle("选中方案参与混合输入", isOn: $localSettings.mixInputEnabled)
                                .onChange(of: localSettings.mixInputEnabled) { _ in save() }
                        } header: {
                            Text("混合输入")
                        } footer: {
                            Text("开启后，多个方案同时参与候选生成，主方案候选永远优先显示")
                        }

                        if localSettings.mixInputEnabled {
                            Section {
                                ForEach($localSettings.mixInputSchemes) { $config in
                                    MixSchemeRow(
                                        config: $config,
                                        schemeName: runtime.installedSchemes
                                            .first { $0.id == config.id }?.manifest.name ?? config.id,
                                        isMain: config.id == localSettings.activeSchemeId,
                                        onChange: { save() }
                                    )
                                }
                                .onMove { from, to in
                                    localSettings.mixInputSchemes.move(fromOffsets: from, toOffset: to)
                                    for (i, _) in localSettings.mixInputSchemes.enumerated() {
                                        localSettings.mixInputSchemes[i].priority = i
                                    }
                                    save()
                                }
                            } header: {
                                HStack {
                                    Text("参与方案")
                                    Spacer()
                                    Text("拖动排序").font(.caption).foregroundColor(.secondary)
                                }
                            } footer: {
                                Text("排序越靠前，候选优先级越高。主方案始终排第一且无法关闭。")
                            }

                            Section {
                                let notInMix = participatableSchemes.filter { scheme in
                                    !localSettings.mixInputSchemes.contains { $0.id == scheme.id }
                                }
                                if notInMix.isEmpty {
                                    Text("没有可混入的全拼词库")
                                        .foregroundColor(.secondary).font(.callout)
                                } else {
                                    ForEach(notInMix) { scheme in
                                        Button {
                                            let newConfig = MixSchemeConfig(
                                                id: scheme.id, isEnabled: true,
                                                candidateColor: defaultColor(for: localSettings.mixInputSchemes.count),
                                                priority: localSettings.mixInputSchemes.count
                                            )
                                            localSettings.mixInputSchemes.append(newConfig)
                                            save()
                                        } label: {
                                            Label("添加「\(scheme.manifest.name)」", systemImage: "plus.circle")
                                        }
                                    }
                                }
                            } header: {
                                Text("添加方案到混打")
                            } footer: {
                                Text("这里只列全拼词库：双拼 / 形码 / 音形码词库与形码主方案的编码空间不同源，混入只会产生噪声候选")
                            }
                        }
                    } else {
                        Section {
                            Text("只有纯形码方案可以混入拼音词库；当前主方案「\(activeSchemeName)」不支持混合输入")
                                .foregroundColor(.secondary).font(.callout)
                        } header: {
                            Text("混合输入")
                        } footer: {
                            Text("混打只有一个合法方向：形码主方案 + 全拼参与方案（想不起字根时整字打拼音）。反方向会让任意拼音串在形码词库里凑出大量短码噪声，压过主方案候选")
                        }
                    }
                }
                .scrollDismissesKeyboard(.immediately)
                // 显式标识主设置列表：打字测试区固定为页头后，页头里的横向候选 ScrollView 也是
                // collectionView 且排在 List 之前，UI 测试的 scrollableContainer 靠 firstMatch 会误取到它
                //（对它 swipeUp 不滚动设置项），故给纵向设置 List 一个稳定标识供测试精确锁定。
                .accessibilityIdentifier("mixSettingsList")
            }
            .navigationTitle("混合输入")
            // 打字测试区已固定为常驻页头：导航标题改用 inline（小标题常驻导航栏、不随内容滚动），
            // 否则 large 大标题会随下方 List 滚动折叠上移，与固定住的打字区脱节、看着像标题在漂。
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) { EditButton() }
            }
            .onAppear { refreshFromRuntime() }
            // 主方案可能在别处变化（键盘快捷面板激活后，经 App 侧 Darwin 观察者 reloadSettings 传回），
            // localSettings 是 @State 快照，必须显式跟随，否则参与方案区停留在旧主方案。
            // 必须延后到本次视图更新事务之外再同步：onChange 是在更新事务中途回调的，
            // 而下方 ForEach($localSettings.mixInputSchemes) 正拿着旧下标渲染参与方案行，
            // 事务内同步增删它背后的数组会让 SwiftUI 用越界下标取绑定（Index out of range 崩溃）。
            // 键盘同屏切方案即此路径：页面活着、行已渲染、主方案一变数组长度就变。
            .onChange(of: runtime.settings.activeSchemeId) { _ in
                DispatchQueue.main.async { refreshFromRuntime() }
            }
        }
    }

    /// 从 runtime 重新同步本页状态：刷新 localSettings 快照、剔除失效与不合格参与方案、
    /// 把当前主方案归位到参与方案首位并落盘。onAppear 与主方案变化共用同一条同步链路
    private func refreshFromRuntime() {
        localSettings = runtime.settings
        // 过滤掉已不存在的方案
        let validIds = Set(runtime.installedSchemes.map { $0.id })
        localSettings.mixInputSchemes.removeAll { !validIds.contains($0.id) }
        purgeIneligibleParticipants()
        syncMainScheme()
        save()
    }

    // MARK: - 能力判定（规则在 SchemeCapability，这里只取结果）

    /// 主方案画像；取不到（未安装 / 方案列表还没加载完）时一律按「不可混打」处理
    private var primaryProfile: SchemeProfile? { profile(of: localSettings.activeSchemeId) }

    /// 主方案能否开混打：只有纯形码可以
    private var canMix: Bool {
        primaryProfile.map { SchemeCapability.canMix(primary: $0) } ?? false
    }

    /// 「添加方案到混打」的候选：通过 `canParticipate` 的方案（实际上只有全拼词库）
    private var participatableSchemes: [InstalledScheme] {
        guard let primary = primaryProfile else { return [] }
        return runtime.installedSchemes.filter { scheme in
            SchemeCapability.canParticipate(primary: primary, participant: SchemeProfile(scheme: scheme))
        }
    }

    /// 当前主方案的显示名，取不到时给个中性占位（避免文案里出现裸 id）
    private var activeSchemeName: String {
        runtime.installedSchemes
            .first { $0.id == localSettings.activeSchemeId }?.manifest.name ?? "当前方案"
    }

    private func profile(of id: String) -> SchemeProfile? {
        guard !id.isEmpty,
              let scheme = runtime.installedSchemes.first(where: { $0.id == id }) else { return nil }
        return SchemeProfile(scheme: scheme)
    }

    /// 策略清洗：剔掉不可能生效的参与方案（双拼 / 形码 / 音形码词库）
    ///
    /// 只清「编码空间对不上」的，不按主方案是否可混打清 —— 主方案换成拼音时参与配置只是暂时不生效，
    /// 换回形码就该原样恢复，抹掉等于让用户重配一遍。被禁用但保留着颜色/次序的行也不动。
    /// 主方案画像取不到时整个清洗跳过，避免方案列表还没加载完就把配置误清成空
    private func purgeIneligibleParticipants() {
        guard let primary = primaryProfile else { return }
        let mainId = localSettings.activeSchemeId
        localSettings.mixInputSchemes.removeAll { config in
            guard config.id != mainId, let participant = profile(of: config.id) else { return false }
            return !SchemeCapability.canParticipate(primary: primary, participant: participant)
        }
    }

    private func syncMainScheme() {
        let mainId = localSettings.activeSchemeId
        // 没有激活方案，不插入主方案
        guard !mainId.isEmpty else { return }
        // 激活方案必须是实际已安装的方案
        guard runtime.installedSchemes.contains(where: { $0.id == mainId }) else { return }
        if let idx = localSettings.mixInputSchemes.firstIndex(where: { $0.id == mainId }) {
            if idx != 0 { localSettings.mixInputSchemes.move(fromOffsets: IndexSet([idx]), toOffset: 0) }
        } else {
            let mainConfig = MixSchemeConfig(id: mainId, isEnabled: true, candidateColor: "#007AFF", priority: 0)
            localSettings.mixInputSchemes.insert(mainConfig, at: 0)
        }
    }

    private func save() {
        // 只更新本页管理的字段，不覆盖其他页面（键盘外观等）已保存的设置
        var merged = runtime.settings
        merged.showAnnotation    = localSettings.showAnnotation
        merged.schemeConfigs     = localSettings.schemeConfigs
        merged.mixInputEnabled   = localSettings.mixInputEnabled
        merged.mixInputSchemes   = localSettings.mixInputSchemes
        merged.activeSchemeId    = localSettings.activeSchemeId
        merged.showPrediction    = localSettings.showPrediction
        merged.showEmoji         = localSettings.showEmoji
        merged.dynamicFreqEnabled = localSettings.dynamicFreqEnabled
        runtime.updateSettings(merged)
    }

    private func defaultColor(for index: Int) -> String {
        let colors = ["#34C759","#FF9500","#AF52DE","#FF3B30","#00C7BE","#8E8E93"]
        return colors[index % colors.count]
    }
}

// MARK: - 打字测试组件

struct TypingTestView: View {
    @EnvironmentObject private var runtime: IMERuntime
    @State private var inputText: String = ""
    @State private var outputText: String = ""
    @State private var candidates: [MixCandidate] = []

    private var activeSchemeId: String { runtime.settings.activeSchemeId }

    var body: some View {
        VStack(spacing: 0) {
            // 已上屏文字显示区
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(.systemBackground))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(.systemGray4), lineWidth: 0.5))

                if outputText.isEmpty {
                    Text("选词后显示在此处...")
                        .foregroundColor(Color(.placeholderText))
                        .font(.body)
                        .padding(10)
                }
                Text(outputText)
                    .font(.body)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 52)
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .onTapGesture {
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    if inputText.isEmpty {
                        Text("输入编码查看候选词")
                            .foregroundColor(.secondary)
                            .font(.callout)
                            .padding(.horizontal, 4)
                    } else if candidates.isEmpty {
                        Text("无候选")
                            .foregroundColor(.secondary)
                            .font(.callout)
                            .padding(.horizontal, 4)
                    } else {
                        ForEach(Array(candidates.enumerated()), id: \.offset) { idx, c in
                            Button {
                                outputText += c.text
                                inputText = ""
                                candidates = []
                            } label: {
                                let textColor: Color = c.colorHex.flatMap { Color(hex: $0) } ?? .primary
                                VStack(spacing: 1) {
                                    // 只读取全局总开关，移除分项scheme判断
                                    let showAnno = runtime.settings.showAnnotation
                                    if showAnno, let anno = c.annotation, !anno.isEmpty {
                                        Text(anno)
                                            .font(.system(size: runtime.settings.keyboardAppearance.annotationFontSize))
                                            .foregroundColor(textColor.opacity(0.7))
                                    } else if !c.code.isEmpty && c.code != c.text {
                                        Text(c.code)
                                            .font(.system(size: runtime.settings.keyboardAppearance.annotationFontSize))
                                            .foregroundColor(textColor.opacity(0.7))
                                    }
                                    Text(c.text)
                                        .font(.system(size: 17))
                                        .foregroundColor(textColor)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(
                                    RoundedRectangle(cornerRadius: 7)
                                        .fill(idx == 0 ? Color.accentColor.opacity(0.12) : Color(.systemGray6))
                                )
                            }
                            .buttonStyle(.plain)
                            // 供 UI 测试稳定定位第 idx 个候选（聚合 label 会混入注释行，按下标取更可靠）
                            .accessibilityIdentifier("mixCandidate-\(idx)")
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
            .frame(height: 52)
            .background(Color(.secondarySystemGroupedBackground))

            // 编码输入框
            HStack(spacing: 8) {
                HStack {
                    Image(systemName: "keyboard")
                        .foregroundColor(.secondary)
                        .font(.caption)
                    TextField("输入编码（如 nihao / abcd）", text: $inputText)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .submitLabel(.done)
                        .onChange(of: inputText) { _ in refreshCandidates() }
                        .accessibilityIdentifier("mixCodeField")
                    if !inputText.isEmpty {
                        Button {
                            inputText = ""
                            candidates = []
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color(.systemBackground)))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(.systemGray4), lineWidth: 0.5))

                if !outputText.isEmpty {
                    Button {
                        outputText = ""
                    } label: {
                        Image(systemName: "trash")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 2)
        .padding(.vertical, 4)
        .onChange(of: activeSchemeId) { _ in refreshCandidates() }
    }

    @MainActor
    private func refreshCandidates() {
        guard !inputText.isEmpty, !activeSchemeId.isEmpty else {
            candidates = []
            return
        }
        candidates = runtime.queryCandidates(input: inputText, schemeId: activeSchemeId, limit: 20)
    }
}

// MARK: - 单个参与方案行

struct MixSchemeRow: View {
    @Binding var config: MixSchemeConfig
    let schemeName: String
    let isMain: Bool
    let onChange: () -> Void
    @State private var showColorPicker = false

    var body: some View {
        HStack {
            Image(systemName: "line.3.horizontal")
                .foregroundColor(.secondary).font(.caption)

            if !isMain {
                Toggle("", isOn: $config.isEnabled)
                    .labelsHidden()
                    .onChange(of: config.isEnabled) { _ in onChange() }
            }

            Text(schemeName).foregroundColor(isMain ? .secondary : .primary)

            if isMain {
                Text("主方案").font(.caption2).foregroundColor(.white)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.accentColor).cornerRadius(4)
            }

            Spacer()

            if !isMain {
                Button { showColorPicker = true } label: {
                    Circle().fill(Color(hex: config.candidateColor) ?? .blue)
                        .frame(width: 24, height: 24)
                        .overlay(Circle().stroke(Color(.systemGray4), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .sheet(isPresented: $showColorPicker) {
                    CandidateColorPickerView(selectedHex: $config.candidateColor) {
                        showColorPicker = false; onChange()
                    }
                }
            }
        }
    }
}

// MARK: - 候选颜色选择器

struct CandidateColorPickerView: View {
    @Binding var selectedHex: String
    let onDone: () -> Void

    private let presets = [
        ("#007AFF", "蓝"), ("#34C759", "绿"), ("#FF9500", "橙"),
        ("#AF52DE", "紫"), ("#FF3B30", "红"), ("#00C7BE", "青"), ("#8E8E93", "灰")
    ]
    @State private var customHex: String = ""
    @State private var hexError: Bool = false

    var body: some View {
        NavigationStack {
            Form {
                Section("预设颜色") {
                    LazyVGrid(columns: Array(repeating: .init(.flexible()), count: 4), spacing: 16) {
                        ForEach(presets, id: \.0) { (hex, name) in
                            Button {
                                selectedHex = hex; customHex = hex
                            } label: {
                                VStack(spacing: 4) {
                                    Circle().fill(Color(hex: hex) ?? .gray)
                                        .frame(width: 44, height: 44)
                                        .overlay {
                                            if selectedHex == hex {
                                                Image(systemName: "checkmark")
                                                    .foregroundColor(.white)
                                                    .font(.system(size: 16, weight: .bold))
                                            }
                                        }
                                    Text(name).font(.caption)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 8)
                }

                Section("自定义 #RRGGBB") {
                    HStack {
                        TextField("#007AFF", text: $customHex)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.characters)
                            .onChange(of: customHex) { val in
                                let hex = val.hasPrefix("#") ? val : "#" + val
                                if hex.count == 7, Color(hex: hex) != nil {
                                    selectedHex = hex; hexError = false
                                } else { hexError = hex.count > 1 }
                            }
                        if !selectedHex.isEmpty {
                            Circle().fill(Color(hex: selectedHex) ?? .gray)
                                .frame(width: 28, height: 28)
                        }
                    }
                    if hexError {
                        Text("格式不正确，请输入 #RRGGBB 格式")
                            .font(.caption).foregroundColor(.red)
                    }
                }
            }
            .navigationTitle("候选颜色")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成", action: onDone)
                }
            }
            .onAppear { customHex = selectedHex }
        }
    }
}

