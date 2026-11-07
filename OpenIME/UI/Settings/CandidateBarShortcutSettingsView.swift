import OpenIMECore
import SwiftUI

// MARK: - 候选栏快捷功能配置页（键盘外观里的候选栏快捷功能）
//
// 单层 List（照 MixInputSettingsView 的 EditButton + onMove 范式）：已选可拖动排序 / 左滑移除，
// 未选可点击添加。改动写回 CandidateBarShortcutStore（自带 Darwin 广播），键盘扩展空态立即
// 反映新的图标与顺序，无需重新部署 —— 满足「任何自定义设定立即生效」的约定。
//
// 为什么单独开一页而不直接塞进 KeyboardSettingsView 的 Form：那一页是「外层 ScrollView +
// 内层 Form(minHeight)」两层滚动，放带 EditButton + onMove/onDelete 的可编辑大列表会打乱滚动。

struct CandidateBarShortcutSettingsView: View {

    /// 开关型功能的当前开 / 关状态存在 UserSettings 里，与键盘候选栏读同一份数据
    @EnvironmentObject private var runtime: IMERuntime

    /// 镜像 Store 里已选并排序的快捷功能；本页所有增删 / 排序都改这个数组再写回
    @State private var barShortcuts: [CandidateBarShortcut] = CandidateBarShortcutStore.shared.shortcuts

    var body: some View {
        List {
            selectedSection
            addSection
        }
        .navigationTitle("候选栏快捷功能")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) { EditButton() }
        }
        .onAppear {
            barShortcuts = CandidateBarShortcutStore.shared.shortcuts
        }
    }

    // MARK: - 已添加（可拖动排序 / 左滑移除）

    @ViewBuilder
    private var selectedSection: some View {
        Section {
            if barShortcuts.isEmpty {
                Text("未添加快捷功能")
                    .foregroundColor(.secondary)
                    .font(.callout)
            } else {
                ForEach(barShortcuts) { shortcut in
                    HStack(spacing: 12) {
                        let tint = shortcutTint(shortcut)
                        if let iconText = shortcut.iconText {
                            Text(iconText)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(tint)
                                .frame(width: 24)
                        } else {
                            Image(systemName: shortcut.symbolName)
                                .foregroundColor(tint)
                                .frame(width: 24)
                        }
                        Text(shortcut.title)
                    }
                }
                .onMove { from, to in
                    barShortcuts.move(fromOffsets: from, toOffset: to)
                    save()
                }
                .onDelete { indexSet in
                    barShortcuts.remove(atOffsets: indexSet)
                    save()
                }
            }
        } header: {
            HStack {
                Text("已添加")
                Spacer()
                Text("拖动排序").font(.caption).foregroundColor(.secondary)
            }
        } footer: {
            Text("候选栏为空（没有输入）时，中段会按此顺序显示快捷图标；左右两端的切换 / 收起键固定不变，图标过多时可横向滑动。\n图标绿色表示该功能当前开着，灰色表示没开，开关型点一下就翻状态；只有「123」是键盘当次会话里的临时状态（进页时不保留），在这页始终为灰。剪贴板图标点一下直接打开复制过的历史，颜色跟着快捷面板里「记录剪贴板」的开关走：绿 = 在记，灰 = 不记。")
        }
    }

    // MARK: - 未添加（点击加入）

    @ViewBuilder
    private var addSection: some View {
        Section {
            let notAdded = CandidateBarShortcut.allCases.filter { $0.isBarEligible && !barShortcuts.contains($0) }
            if notAdded.isEmpty {
                Text("所有快捷功能均已添加")
                    .foregroundColor(.secondary)
                    .font(.callout)
            } else {
                ForEach(notAdded) { shortcut in
                    Button {
                        barShortcuts.append(shortcut)
                        save()
                    } label: {
                        if let iconText = shortcut.iconText {
                            Label {
                                Text(shortcut.title)
                            } icon: {
                                Text(iconText)
                            }
                        } else {
                            Label(shortcut.title, systemImage: shortcut.symbolName)
                        }
                    }
                }
            }
        } header: {
            Text("添加快捷功能")
        } footer: {
            Text("仅收录点一下立即生效的功能；需要进快捷面板再选择的（键盘形态、输入方案）不在此列。")
        }
    }

    /// 写回 Store（自带 Darwin 广播）：键盘空态立即反映新的图标与顺序
    private func save() {
        CandidateBarShortcutStore.shared.orderedIDs = barShortcuts.map(\.rawValue)
    }

    /// 图标着色：直接复用键盘候选栏那对颜色（CandidateBarStyle），保证
    /// 「配置页看到的颜色」与「候选栏实际看到的颜色」不会各自发展。
    /// 能进候选栏的都是状态可着色的（开关型 + 剪贴板这类颜色跟开关走的入口，
    /// 见 reflectsState）；瞬态的「123」存在键盘视图的
    /// @State 里，主 App 拿不到也不该猜，在这一页始终为灰色（= 未开启）
    private func shortcutTint(_ shortcut: CandidateBarShortcut) -> Color {
        shortcutIsOn(shortcut) ? CandidateBarStyle.shortcutOnColor : CandidateBarStyle.shortcutOffColor
    }

    /// 该功能当前是不是「开」：与键盘侧 IMEKeyboardView.isShortcutOn 同口径，
    /// 但只取主 App 能读到的持久项（英文模式存 EnglishModeStore、剪贴板记录开关存
    /// ClipboardSettingsStore，都是 App Group 里的那一份；showingNumbers 是键盘视图的
    /// @State，主 App 拿不到也不该猜）
    private func shortcutIsOn(_ shortcut: CandidateBarShortcut) -> Bool {
        switch shortcut {
        case .clipboardHistory:  return ClipboardSettingsStore.shared.isEnabled
        case .toggleEnglish:     return EnglishModeStore.shared.isEnglish
        case .toggleAnnotation:  return runtime.settings.showAnnotation
        case .togglePrediction:  return runtime.settings.showPrediction
        case .toggleDynamicFreq: return runtime.settings.dynamicFreqEnabled
        default: return false
        }
    }
}
