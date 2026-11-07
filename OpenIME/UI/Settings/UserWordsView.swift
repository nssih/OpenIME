import OpenIMECore
import SwiftUI

// MARK: - 自定义词典

struct UserWordsView: View {
    @State private var words: [CustomWord] = []
    @State private var searchText = ""
    @State private var showAddSheet = false
    @State private var saveError: String? = nil
    /// 「剪贴板历史」入口的副标题：开关状态 + 当前条数（onAppear 刷新，从子页返回时更新）
    @State private var clipboardSummary = ""
    /// 同上，但只取开关本身：入口行首图标靠它着色（开=绿、关=灰）
    @State private var clipboardEnabled = ClipboardSettingsStore.shared.isEnabled
    /// 正在编辑的词条（点按或右滑词条进入）；nil 表示未在编辑
    @State private var editingWord: CustomWord? = nil
    /// 多选编辑态（EditButton）下点按是勾选而非打开编辑，避免两者打架
    @Environment(\.editMode) private var editMode

    private var filtered: [CustomWord] {
        if searchText.isEmpty { return words }
        return words.filter { $0.text.contains(searchText) || $0.code.contains(searchText) }
    }

    /// 词条区右侧计数：常态报总数，搜索时报「匹配 M / N」，内容多时让用户对规模心里有数。
    /// 数字摆在标题右侧的小字里而不是嵌进标题本身：与「历史记录 / N 条」「参与方案 / 拖动排序」
    /// 同一套 section 标题范式，也省得标题带上数字后被 UI 测试的 CONTAINS 定位误命中。
    private var wordsCountText: String {
        if searchText.isEmpty { return "\(words.count) 条" }
        return "匹配 \(filtered.count) / \(words.count) 条"
    }

    /// 空库态：还没有任何自定义词条
    @ViewBuilder private var emptyWordsView: some View {
        if #available(iOS 17.0, *) {
            ContentUnavailableView(
                "暂无自定义词条",
                systemImage: "plus.circle",
                description: Text("点下方「添加词条」或右上角 +；打字敲到编码前缀即进入候选，越常选越靠前")
            )
        } else {
            Text("暂无自定义词条").foregroundColor(.secondary)
        }
    }

    /// 搜索无结果态：库里有词，但当前搜索词没匹配上（与空库态区分，避免误导）
    @ViewBuilder private var noWordResultView: some View {
        if #available(iOS 17.0, *) {
            ContentUnavailableView.search(text: searchText)
        } else {
            Text("没有匹配「\(searchText)」的词条").foregroundColor(.secondary)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                // 常驻入口：剪贴板历史（与自定义词典同属「词典」Tab，仅新增一个 Section）
                Section {
                    NavigationLink {
                        ClipboardHistoryView()
                    } label: {
                        HStack(spacing: 12) {
                            // 开关状态直接写在图标颜色上：绿=正在记录，灰=没开。
                            // 复用候选栏快捷图标那对开关状态色，两处「开/关」的绿灰不再各自发展
                            Image(systemName: "doc.on.clipboard")
                                .foregroundColor(clipboardEnabled
                                                 ? CandidateBarStyle.shortcutOnColor
                                                 : CandidateBarStyle.shortcutOffColor)
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("剪贴板历史")
                                Text(clipboardSummary)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }

                // 词条区：带计数标题，内容多时靠搜索收敛；空库与「搜索无结果」分别给出对应空态。
                // 点按或右滑词条进入编辑（此前只能增删、改不了既有词条），左滑删除。
                Section {
                    if filtered.isEmpty {
                        if words.isEmpty {
                            emptyWordsView
                            // 空库时把「添加」也摆进行列：只剩右上角一个加号时，新用户对着
                            // 一整页空白不知道该动手，这里直接给一个明确的下一步（与方案页导入行同范式）
                            Button {
                                showAddSheet = true
                            } label: {
                                Label("添加词条", systemImage: "plus.circle")
                            }
                        } else {
                            noWordResultView
                        }
                    } else {
                        ForEach(filtered) { word in
                            CustomWordRow(word: word)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    if editMode?.wrappedValue != .active { editingWord = word }
                                }
                                .swipeActions(edge: .leading) {
                                    Button {
                                        editingWord = word
                                    } label: {
                                        Label("编辑", systemImage: "pencil")
                                    }
                                }
                        }
                        .onDelete { indexSet in
                            deleteWords(at: indexSet)
                        }
                    }
                } header: {
                    HStack {
                        Text("自定义词条")
                        Spacer()
                        Text(wordsCountText)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                } footer: {
                    Text("词条只存在本机，不用改方案包；打字时只要敲到它编码的前缀，这个词就会进入本方案候选。新词从第 5 位起，每主动点选一次上升一位，最高升到第 2 位（不占首选，免得顶掉形码的一简二简三简）；改选同码其它候选后会逐步回落。点按或右滑词条可编辑，左滑删除。")
                }
            }
            .searchable(text: $searchText, prompt: "搜索词或编码")
            .navigationTitle("词典")
            // 全站标题风格统一：导航标题一律 inline 常驻导航栏、不随内容滚动折叠（与键盘外观 / 混合页一致）
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack {
                        // 一个词条都没有时不摆「编辑」：没有可编辑的行，点下去毫无反应像个坏按钮
                        if !words.isEmpty {
                            EditButton()
                        }
                        Button {
                            showAddSheet = true
                        } label: {
                            Image(systemName: "plus")
                        }
                    }
                }
            }
            .sheet(isPresented: $showAddSheet) {
                AddCustomWordView { newWord in
                    words.append(newWord)
                    saveAndNotify()
                }
            }
            .onAppear {
                loadWords()
                refreshClipboardSummary()
            }
            .alert("保存失败", isPresented: Binding(
                get: { saveError != nil },
                set: { if !$0 { saveError = nil } }
            )) {
                Button("好") { saveError = nil }
            } message: {
                Text(saveError ?? "")
            }
        }
        // 编辑 sheet 挂在外层 NavigationStack（与「添加」sheet 分属不同视图，两个 sheet 才能并存）
        .sheet(item: $editingWord) { word in
            AddCustomWordView(initial: word) { updated in
                if let idx = words.firstIndex(where: { $0.id == updated.id }) {
                    words[idx] = updated
                }
                saveAndNotify()
            }
        }
    }

    private func loadWords() {
        words = AppGroupContainer.shared.loadCustomWords()
            .sorted { $0.createdAt > $1.createdAt }
    }

    /// 刷新「剪贴板历史」入口的开关状态与副标题（行首图标着色也由此决定）
    private func refreshClipboardSummary() {
        clipboardEnabled = ClipboardSettingsStore.shared.isEnabled
        if clipboardEnabled {
            clipboardSummary = "已开启 · \(ClipboardHistoryStore.shared.count) 条记录"
        } else {
            clipboardSummary = "未开启"
        }
    }

    private func deleteWords(at offsets: IndexSet) {
        let toDelete = Set(offsets.map { filtered[$0].id })
        words.removeAll { toDelete.contains($0.id) }
        saveAndNotify()
    }

    private func saveAndNotify() {
        do {
            try AppGroupContainer.shared.saveCustomWords(words)
            CFNotificationCenterPostNotification(
                CFNotificationCenterGetDarwinNotifyCenter(),
                CFNotificationName(AppGroupContainer.settingsChangedNotification as CFString),
                nil, nil, true
            )
        } catch {
            saveError = error.localizedDescription
        }
    }
}

struct CustomWordRow: View {
    let word: CustomWord

    var body: some View {
        HStack(spacing: 8) {
            // 词与编码都可能很长：各限一行截断（编码从中间截，保留首尾更好辨认），
            // 让日期始终靠右完整显示，内容多、机型窄时也不挤乱
            VStack(alignment: .leading, spacing: 2) {
                Text(word.text)
                    .font(.body)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(word.code)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(minWidth: 0, alignment: .leading)
            Spacer(minLength: 4)
            Text(word.createdAt, style: .date)
                .font(.caption2)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .fixedSize()
        }
    }
}

// MARK: - 添加词条 Sheet

struct AddCustomWordView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var code: String
    /// 非 nil 表示编辑既有词条：预填其词与编码，保存时沿用原 id 与创建时间（不打乱排序）
    private let editing: CustomWord?
    let onSave: (CustomWord) -> Void

    init(initial: CustomWord? = nil, onSave: @escaping (CustomWord) -> Void) {
        self.editing = initial
        _text = State(initialValue: initial?.text ?? "")
        _code = State(initialValue: initial?.code ?? "")
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    // 字段名写在占位符里而不是用 label + prompt：实测 label+prompt 写法下，
                    // 空字段只渲染 prompt（「词」/「编码」不显示），反而比原来更看不出谁是谁
                    TextField("词（如：你好世界）", text: $text)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    TextField("编码（如：nihaoshijie）", text: $code)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .keyboardType(.asciiCapable)
                } footer: {
                    Text("编码是打字时的输入码，词是对应的输出内容，两者都必须填写。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle(editing == nil ? "添加词条" : "编辑词条")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        let trimmedText = text.trimmingCharacters(in: .whitespaces)
                        let trimmedCode = code.trimmingCharacters(in: .whitespaces)
                        let word: CustomWord
                        if let editing {
                            word = CustomWord(id: editing.id, text: trimmedText,
                                              code: trimmedCode, createdAt: editing.createdAt)
                        } else {
                            word = CustomWord(text: trimmedText, code: trimmedCode)
                        }
                        onSave(word)
                        dismiss()
                    }
                    .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty ||
                              code.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
    }
}

