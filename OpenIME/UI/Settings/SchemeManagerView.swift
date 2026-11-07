import OpenIMECore
import SwiftUI
import UniformTypeIdentifiers

// MARK: - 方案管理页

struct SchemeManagerView: View {
    @EnvironmentObject private var runtime: IMERuntime
    @State private var showImporter = false
    @State private var installing = false
    @State private var installError: String? = nil
    @State private var installSuccess: String? = nil
    @State private var partialFailure: String? = nil
    @State private var showDeleteConfirm: InstalledScheme? = nil
    @State private var schemeSearch = ""

    /// 搜索过滤：按方案名 / ID / 作者匹配（大小写不敏感）
    private var filteredSchemes: [InstalledScheme] {
        guard !schemeSearch.isEmpty else { return runtime.installedSchemes }
        let q = schemeSearch.lowercased()
        return runtime.installedSchemes.filter {
            $0.manifest.name.lowercased().contains(q) ||
            $0.id.lowercased().contains(q) ||
            $0.manifest.author.lowercased().contains(q)
        }
    }

    /// 分组展示阈值：内置三套方案时三个组各只有 1 个方案，结构噪音大过收敛价值；
    /// 批量导入把方案装多了，按码制分组才发挥得出作用（长列表收敛 + 同类相邻）。
    /// 属展示层排版行为参数（无法由数据源派生），具名常量单源。
    private static let groupedDisplaySchemeCountThreshold = 5

    /// 是否按码制分组：以已装方案总数为准，不随搜索命中条数翻转结构
    private var shouldGroupByCodeSystem: Bool {
        runtime.installedSchemes.count > Self.groupedDisplaySchemeCountThreshold
    }

    /// 方案少时的扁平列表：使用中置顶，其余保持 runtime.installedSchemes 原序
    /// （= scheme_order.json 持久化稳定插入序：内置规范序、新导入末尾 —— 首装即
    /// 雾凇、虎码、超强快码）。绝不再按名字排序：那会破坏既定的列表顺序产品约定。
    /// 排序也不参与任何激活判定 —— 默认激活/回落全部在 IMERuntime 层
    /// （defaultSchemeId 优先雾凇），本页从不写 settings.activeSchemeId。
    private var flatSchemes: [InstalledScheme] {
        let matches = filteredSchemes
        guard let index = matches.firstIndex(where: { $0.id == runtime.settings.activeSchemeId }),
              index != matches.startIndex
        else { return matches }
        // 把使用中那一行提到最前，其余相对顺序原样保留（稳定，不交给 sort 重排）
        return [matches[index]] + matches.prefix(upTo: index) + matches.suffix(from: matches.index(after: index))
    }

    /// 按码制分组：使用中方案所在组置顶，其余按 音码、形码、音形码；组内使用中优先、再按名字。
    /// 分组标题只用码制名（音码/形码/音形码），不含具体方案名，避免与列表行的名字匹配串味。
    private var groupedSchemes: [SchemeGroup] {
        let activeId = runtime.settings.activeSchemeId
        var buckets: [CodeSystem: [InstalledScheme]] = [:]
        for scheme in filteredSchemes {
            buckets[SchemeProfile(scheme: scheme).codeSystem, default: []].append(scheme)
        }
        var order: [CodeSystem] = [.phonetic, .shape, .phonoShape]
        if let activeSystem = filteredSchemes.first(where: { $0.id == activeId })
            .map({ SchemeProfile(scheme: $0).codeSystem }),
           order.first != activeSystem {
            order.removeAll { $0 == activeSystem }
            order.insert(activeSystem, at: 0)
        }
        return order.compactMap { system in
            guard let list = buckets[system], !list.isEmpty else { return nil }
            let sorted = list.sorted { a, b in
                let aActive = a.id == activeId, bActive = b.id == activeId
                if aActive != bActive { return aActive }
                return a.manifest.name < b.manifest.name
            }
            return SchemeGroup(system: system, title: system.displayName, schemes: sorted)
        }
    }

    /// 空库态：一个方案都没装
    @ViewBuilder private var emptySchemesView: some View {
        if #available(iOS 17.0, *) {
            ContentUnavailableView(
                "暂无方案",
                systemImage: "square.stack.3d.down.all",
                description: Text("导入方案包（ZIP / YAML）开始使用")
            )
        } else {
            Text("暂无方案，导入方案包开始使用").foregroundColor(.secondary)
        }
    }

    /// 搜索无结果态：装了方案，但当前搜索词没匹配上
    @ViewBuilder private var noSchemeResultView: some View {
        if #available(iOS 17.0, *) {
            ContentUnavailableView.search(text: schemeSearch)
        } else {
            Text("没有匹配「\(schemeSearch)」的方案").foregroundColor(.secondary)
        }
    }

    /// 方案行（分组/扁平两种结构共用）：进详情 + 激活 + 滑动删除
    @ViewBuilder private func schemeRow(_ scheme: InstalledScheme) -> some View {
        NavigationLink {
            SchemeSettingsView(scheme: scheme)
                .environmentObject(runtime)
        } label: {
            SchemeRow(
                scheme: scheme,
                isActive: scheme.id == runtime.settings.activeSchemeId,
                onActivate: { runtime.activateScheme(id: scheme.id) },
                onDelete: { showDeleteConfirm = scheme }
            )
        }
    }

    var body: some View {
        NavigationStack {
            List {
                // 方案多时按码制分组展示（音码/形码/音形码），组内「使用中」置顶、其余按名字；
                // 方案少时（内置三套量级）扁平一条列表，使用中置顶、保持持久化稳定序，
                // 不再为每个只装了一个方案的码制立一节标题；
                // 配合搜索把长列表收敛到眼前这几条；空库与「搜索无结果」分别给出对应空态。
                if runtime.installedSchemes.isEmpty {
                    Section {
                        emptySchemesView
                    }
                } else if filteredSchemes.isEmpty {
                    Section {
                        noSchemeResultView
                    }
                } else if shouldGroupByCodeSystem {
                    ForEach(groupedSchemes) { group in
                        Section {
                            ForEach(group.schemes) { scheme in
                                schemeRow(scheme)
                            }
                        } header: {
                            Text("\(group.title)（\(group.schemes.count)）")
                        }
                    }
                } else {
                    Section {
                        ForEach(flatSchemes) { scheme in
                            schemeRow(scheme)
                        }
                    } header: {
                        // 标题只报数量不带方案名：测试用 CONTAINS 方案名定位行，
                        // 固定文案里出现「拼音/码」类子串会被误命中（见既有陷阱经验）
                        Text("已装方案（\(flatSchemes.count)）")
                    }
                }

                Section {
                    Button {
                        showImporter = true
                    } label: {
                        Label("导入方案包（ZIP / YAML）", systemImage: "plus.circle")
                    }
                } footer: {
                    Text("点击进入方案设置，滑动删除方案包。导入时没有自带词频的码表，会在安装编译期自动补全通用字/词频，高频词排前")
                }
            }
            .searchable(text: $schemeSearch, prompt: "搜索方案名 / ID / 作者")
            .navigationTitle("方案管理")
            // 全站标题风格统一：导航标题一律 inline 常驻导航栏、不随内容滚动折叠（与键盘外观 / 混合页一致）
            .navigationBarTitleDisplayMode(.inline)
            .overlay {
                if installing {
                    ProgressView("正在安装...")
                        .padding(24)
                        .background(Material.thick)
                        .cornerRadius(16)
                }
            }
            .alert("删除方案", isPresented: Binding(
                get: { showDeleteConfirm != nil },
                set: { if !$0 { showDeleteConfirm = nil } }
            )) {
                Button("删除", role: .destructive) {
                    if let scheme = showDeleteConfirm {
                        Task { try? await runtime.uninstallScheme(id: scheme.id) }
                    }
                    showDeleteConfirm = nil
                }
                Button("取消", role: .cancel) { showDeleteConfirm = nil }
            } message: {
                Text("确定删除「\(showDeleteConfirm?.manifest.name ?? "")」？删除后无法恢复。")
            }
            .alert("安装失败", isPresented: Binding(
                get: { installError != nil },
                set: { if !$0 { installError = nil } }
            )) {
                Button("好") { installError = nil }
            } message: {
                Text(installError ?? "")
            }
            .alert("安装成功", isPresented: Binding(
                get: { installSuccess != nil },
                set: { if !$0 { installSuccess = nil } }
            )) {
                Button("好") { installSuccess = nil }
            } message: {
                Text(installSuccess ?? "")
            }
            .alert("部分方案安装失败", isPresented: Binding(
                get: { partialFailure != nil },
                set: { if !$0 { partialFailure = nil } }
            )) {
                Button("好") { partialFailure = nil }
            } message: {
                Text(partialFailure ?? "")
            }
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [UTType.zip, UTType.yaml],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            let accessed = url.startAccessingSecurityScopedResource()
            Task {
                installing = true
                defer {
                    installing = false
                    if accessed { url.stopAccessingSecurityScopedResource() }
                }
                do {
                    let ext = url.pathExtension.lowercased()
                    let installResult: PackageInstaller.InstallResult
                    if ext == "yaml" || ext == "yml" {
                        installResult = try await runtime.installFromYAML(url: url)
                    } else {
                        installResult = try await runtime.installPackage(zipURL: url)
                    }
                    if !installResult.schemeId.isEmpty {
                        installSuccess = "「\(installResult.schemeName)」安装成功，共 \(installResult.dictEntryCount) 个词条"
                    }
                    if !installResult.partialFailures.isEmpty {
                        partialFailure = "以下方案安装失败：\n" + installResult.partialFailures.joined(separator: "\n")
                    }
                } catch {
                    installError = error.localizedDescription
                }
            }
        }
    }

}

// MARK: - 码制中文口径（本文件单源：分组标题与行副标题共用，不另发明叫法）
fileprivate extension CodeSystem {
    var displayName: String {
        switch self {
        case .phonetic:   return "音码"
        case .shape:      return "形码"
        case .phonoShape: return "音形码"
        }
    }
}

/// 方案分组（按码制）：id 用码制，供 ForEach 直接消费
private struct SchemeGroup: Identifiable {
    let id: CodeSystem
    let title: String
    let schemes: [InstalledScheme]
    init(system: CodeSystem, title: String, schemes: [InstalledScheme]) {
        self.id = system
        self.title = title
        self.schemes = schemes
    }
}

// MARK: - 方案级设置页

struct SchemeSettingsView: View {
    @EnvironmentObject private var runtime: IMERuntime
    let scheme: InstalledScheme

    /// 满码连打三态：跟随方案（auto_select 声明）/ 强制开启（自选码长）/ 关闭（不自动上屏，长串交给整句候选）
    private enum AutoSelectMode: String, CaseIterable, Identifiable {
        case scheme, on, off
        var id: String { rawValue }
        var label: String {
            switch self {
            case .scheme: return "跟随方案"
            case .on:     return "开启"
            case .off:    return "关闭"
            }
        }
    }

    @State private var autoSelectMode: AutoSelectMode = .scheme
    @State private var autoSelectLength: Int = 4
    @State private var singleCharFirst: Bool = false
    @State private var showAnnotation: Bool = true

    private func loadConfig() {
        let cfg = runtime.settings.schemeConfigs[scheme.id] ?? SchemeUserConfig()
        if cfg.autoSelectEnabled == false {
            autoSelectMode = .off
        } else if cfg.autoSelectEnabled == true || cfg.autoSelectLength != nil {
            // 旧设置只有码长没有开关：手填过码长就是用户主动要开，归入「开启」
            autoSelectMode = .on
        } else {
            autoSelectMode = .scheme
        }
        // 没手填过码长时，把方案自己声明的码长摆上来当默认值（虎码就是 4）
        autoSelectLength  = cfg.autoSelectLength ?? scheme.definition.maxCodeLength ?? 4
        singleCharFirst   = cfg.singleCharFirst ?? false
        showAnnotation    = cfg.showAnnotation ?? true
    }

    private func saveConfig() {
        var s = runtime.settings
        var cfg = s.schemeConfigs[scheme.id] ?? SchemeUserConfig()
        cfg.autoSelectEnabled = autoSelectMode == .scheme ? nil : (autoSelectMode == .on)
        cfg.autoSelectLength  = autoSelectMode == .on ? autoSelectLength : nil
        cfg.singleCharFirst   = singleCharFirst
        cfg.showAnnotation    = showAnnotation
        s.schemeConfigs[scheme.id] = cfg
        runtime.updateSettings(s)
    }

    // MARK: - 方案能力（只读展示，判定规则在 SchemeCapability）

    /// 这个方案撑得起的键盘形态：键盘快捷面板里消失的入口，在这里能看到原因
    private var capabilityModes: [KeyboardMode] {
        SchemeCapability.availableKeyboardModes(chain: capabilityChain)
    }

    /// 判定用的输入链：正在使用的方案按实际链算（含生效中的混打参与方案，
    /// 形码主 + 全拼参与时双拼还原出的拼音由参与方接住）；未激活的方案只能按它自己算
    private var capabilityChain: SchemeChain {
        if scheme.id == runtime.settings.activeSchemeId, !runtime.activeChain.isEmpty {
            return runtime.activeChain
        }
        return SchemeChain(primary: SchemeProfile(scheme: scheme))
    }

    private var canMix: Bool {
        SchemeCapability.canMix(primary: SchemeProfile(scheme: scheme))
    }

    var body: some View {
        Form {
            Section {
                HStack {
                    Text("方案 ID")
                    Spacer()
                    Text(scheme.id).foregroundColor(.secondary).font(.caption)
                }
                HStack {
                    Text("版本")
                    Spacer()
                    Text("v\(scheme.manifest.version)").foregroundColor(.secondary)
                }
                HStack {
                    Text("作者")
                    Spacer()
                    Text(scheme.manifest.author).foregroundColor(.secondary)
                }
                if !scheme.manifest.description.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("简介")
                        Text(scheme.manifest.description)
                            .font(.callout)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 2)
                }
            } header: {
                Text("基本信息")
            }

            Section {
                if runtime.settings.activeSchemeId != scheme.id {
                    Button("激活此方案") { runtime.activateScheme(id: scheme.id) }
                } else {
                    Label("当前使用中", systemImage: "checkmark.circle.fill")
                        .foregroundColor(.accentColor)
                }
            } header: {
                Text("激活")
            }

            // 方案能力：只读。键盘快捷面板与混打设置页会按能力灰显用不了的入口，
            // 这里把结论摆出来，用户才知道入口不是丢了而是这个方案用不上
            Section {
                ForEach(KeyboardMode.allCases) { mode in
                    HStack {
                        Text(mode.displayName)
                        Spacer()
                        // 绿色 = 能用、灰色 = 这个方案用不上：灰是「不适用」而不是「出错」，
                        // 出错才用强调色，这里点上去只会提示不可用的原因；混打行同口径
                        if capabilityModes.contains(mode) {
                            Text("可用").foregroundColor(Color(uiColor: .systemGreen)).font(.caption)
                        } else {
                            Text("不可用").foregroundColor(.secondary).font(.caption)
                        }
                    }
                }
                HStack(alignment: .top) {
                    Text("混合输入")
                    Spacer()
                    Text(canMix ? "可混入全拼词库" : "不支持（仅纯形码方案可混打）")
                        .foregroundColor(canMix ? Color(uiColor: .systemGreen) : .secondary)
                        .font(.caption)
                        .multilineTextAlignment(.trailing)
                }
            } header: {
                Text("方案能力")
            } footer: {
                Text("形态可用性由编码空间推导：小鹤双拼键盘把双拼码还原成全拼音节、双拼方案则直接拿双拼码查库，对不上此方案词库的编码就不可能出现候选，因此不可用。26 键原样透传字母，对任何码制都能做前缀查询，恒可用。混打参与方只贡献候选，不扩展键盘形态可用性。")
            }

            // 满码连打
            Section {
                Picker(selection: $autoSelectMode) {
                    ForEach(AutoSelectMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("满码连打")
                        Text("敲满码长、首选整码命中且没有重码，立即上屏接着打")
                            .font(.caption).foregroundColor(.secondary)
                    }
                }
                .onChange(of: autoSelectMode) { _ in saveConfig() }

                if autoSelectMode == .on {
                    Stepper("码长：\(autoSelectLength) 码", value: $autoSelectLength, in: 2...9)
                        .onChange(of: autoSelectLength) { _ in saveConfig() }
                }

                Toggle(isOn: $singleCharFirst) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("单字优先")
                        Text("把单字候选整体提到最前，组内仍按词频")
                            .font(.caption).foregroundColor(.secondary)
                    }
                }
                .onChange(of: singleCharFirst) { _ in saveConfig() }
            } header: {
                Text("输入行为")
            } footer: {
                Text("仅在混打未生效时启用，混打真正生效（形码主 + 全拼参与）时自动暂停。「跟随方案」沿用方案自己声明的规则（如虎码满 4 码即上）；「关闭」后不自动上屏，长串编码由整句候选兜底，空格一次上屏。同一个满码有重码时不会自动上屏，而是把编码留在候选栏等你选（不选也行，继续打下一码会把首选顶上去）。")
            }

            // 注释显示
            let hasAnno = scheme.availableColumns.contains(where: {
                ["annotation","stem","hint","comment"].contains($0)
            })
            if hasAnno {
                Section {
                    Toggle(isOn: $showAnnotation) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("显示候选注释")
                            let colNames = scheme.availableColumns
                                .filter { ["annotation","stem","hint","comment"].contains($0) }
                                .joined(separator: "、")
                            Text("此方案含 \(colNames) 列")
                                .font(.caption).foregroundColor(.secondary)
                        }
                    }
                    .onChange(of: showAnnotation) { _ in saveConfig() }
                } header: {
                    Text("候选注释")
                } footer: {
                    Text("全局注释开关关闭时，此设置不生效")
                }
            }
        }
        .navigationTitle(scheme.manifest.name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { loadConfig() }
    }
}

struct SchemeRow: View {
    let scheme: InstalledScheme
    let isActive: Bool
    let onActivate: () -> Void
    let onDelete: () -> Void

    /// 副标题：码制 · 版本 · 作者（版本/作者缺失时过滤空段，不留孤零零的分隔符）。
    /// 码制上行走：分组收起为扁平列表后，用户仍从每行看到装的是什么码。
    private var subtitleText: String {
        var parts: [String] = [SchemeProfile(scheme: scheme).codeSystem.displayName]
        if !scheme.manifest.version.isEmpty { parts.append("v\(scheme.manifest.version)") }
        if !scheme.manifest.author.isEmpty  { parts.append(scheme.manifest.author) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(scheme.manifest.name)
                    .font(.body)
                    .fontWeight(isActive ? .semibold : .regular)
                    .lineLimit(1)

                Text(subtitleText)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            .frame(minWidth: 0, alignment: .leading)

            Spacer(minLength: 8)

            if isActive {
                // 使用中：右侧实心绿胶囊，行里一眼锁定当前方案
                Text("使用中")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color(uiColor: .systemGreen)))
            } else {
                Button("激活") { onActivate() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive, action: onDelete) {
                Label("删除", systemImage: "trash")
            }
        }
    }
}
