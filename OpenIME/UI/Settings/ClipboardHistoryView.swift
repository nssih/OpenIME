import OpenIMECore
import SwiftUI
import UIKit

// MARK: - 剪贴板历史管理页（词典 Tab 下的剪贴板历史）
//
// 记录开关 / 保留条数存 ClipboardSettingsStore（不在 UserSettings 里），改完 setter 自带 Darwin 广播，
// 键盘扩展立即同步；历史内容存 ClipboardHistoryStore（与键盘、分享扩展同一份）。

struct ClipboardHistoryView: View {

    @State private var isEnabled = ClipboardSettingsStore.shared.isEnabled
    @State private var maxCountValue = Double(ClipboardSettingsStore.shared.maxCount)
    @State private var items: [ClipboardItem] = []
    @State private var showClearConfirm = false
    /// 编辑态：历史区改成框内滚动后，List 的左滑 / EditButton 删除管不到这些行了，
    /// 逐条删除改由编辑态里每行前面的红圈承担（与系统「编辑 → 逐条删除」同一套交互）
    @State private var isEditing = false

    private let store = ClipboardHistoryStore.shared

    /// 历史区固定高度占屏比：条目再多也只在这个框里上下滚，
    /// 「记录设置」与底部「清空全部」的位置不随条数变化
    private static let historyHeightRatio: CGFloat = 0.42
    /// 框内行的垂直内边距（行原本由 List 给，自绘后需自己补）
    private static let rowVerticalPadding: CGFloat = 10
    /// 框内行的水平内边距：滚动区已铺满卡片（listRowInsets 置零），
    /// 取系统分组列表惯用的 16pt，保证文字与卡片边缘的距离和其他页一致
    private static let rowHorizontalPadding: CGFloat = 16

    private var historyBoxHeight: CGFloat {
        UIScreen.main.bounds.height * Self.historyHeightRatio
    }

    /// 保留条数滑块区间：直接由 Store 的合法区间推导，不写死点数
    private var maxCountSliderRange: ClosedRange<Double> {
        Double(ClipboardSettingsStore.maxCountRange.lowerBound)...Double(ClipboardSettingsStore.maxCountRange.upperBound)
    }

    var body: some View {
        List {
            settingsSection
            historySection
            clearSection
        }
        .navigationTitle("剪贴板历史")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(isEditing ? "完成" : "编辑") {
                    isEditing.toggle()
                }
            }
        }
        .onAppear {
            isEnabled = ClipboardSettingsStore.shared.isEnabled
            maxCountValue = Double(ClipboardSettingsStore.shared.maxCount)
            reload()
        }
    }

    // MARK: - 记录设置

    private var settingsSection: some View {
        Section {
            Toggle(isOn: $isEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("记录剪贴板历史")
                    Text("开启后，键盘弹出、主 App 打开时自动记录复制的内容")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .onChange(of: isEnabled) { newValue in
                // setter 自带 Darwin 广播，键盘扩展立即同步
                ClipboardSettingsStore.shared.isEnabled = newValue
            }

            LabeledSlider(title: "保留条数",
                          value: $maxCountValue,
                          range: maxCountSliderRange,
                          unit: " 条")
                .onChange(of: maxCountValue) { newValue in
                    ClipboardSettingsStore.shared.maxCount = Int(newValue)
                    // 调小上限后立即修剪，连带删除多余条目的图片文件
                    store.trimToLimit()
                    reload()
                }
        } header: {
            Text("记录设置")
        } footer: {
            Text("iOS 限制：无法在后台监听剪贴板。仅在键盘弹出 / 主 App 打开时抓取，或用系统分享菜单「存到 聿·输入法」手动保存。图片无法由键盘直接插入宿主 App，点图片条目会复制回剪贴板，请手动粘贴。")
        }
    }

    // MARK: - 历史列表

    private var historySection: some View {
        Section {
            if items.isEmpty {
                Text("暂无剪贴板记录")
                    .foregroundColor(.secondary)
            } else {
                // 固定高度的内部滚动区：条数再多也只在这个框里滚，
                // 页面本身不再跟着无限往下拉长
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(items) { item in
                            historyRow(item, isLast: item.id == items.last?.id)
                        }
                    }
                }
                .frame(height: historyBoxHeight)
                .clipped()
                // 铺满卡片宽度：否则滚动区两侧留 List 默认内边距，分隔线与点击区会缩进去一块
                .listRowInsets(EdgeInsets())
            }
        } header: {
            HStack {
                Text("历史记录")
                Spacer()
                Text("\(items.count) 条")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: - 清空

    private var clearSection: some View {
        Section {
            Button(role: .destructive) {
                showClearConfirm = true
            } label: {
                HStack {
                    Image(systemName: "trash")
                    Text("清空全部")
                }
                .foregroundColor(ClearActionStyle.foreground)
                .frame(maxWidth: .infinity)
                .padding(.vertical, ClearActionStyle.verticalPadding)
                .background(ClearActionStyle.background)
                .cornerRadius(ClearActionStyle.cornerRadius)
            }
            .alert("清空剪贴板历史", isPresented: $showClearConfirm) {
                Button("清空", role: .destructive) { clearAll() }
                Button("取消", role: .cancel) {}
            } message: {
                Text("将删除所有已记录的剪贴板内容与图片文件，此操作不可恢复。")
            }
        }
    }

    // MARK: - 数据操作

    /// 框内单行：编辑态前置红圈删除；行间自绘分隔线（List 的分隔线画不进滚动区）
    private func historyRow(_ item: ClipboardItem, isLast: Bool) -> some View {
        HStack(spacing: ClipboardHistoryRow.contentSpacing) {
            if isEditing {
                Button {
                    deleteItem(item)
                } label: {
                    Image(systemName: "minus.circle.fill")
                        .foregroundColor(ClearActionStyle.foreground)
                        .padding(4)          // 热区比符号本身大一圈
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                // UI 用例靠它锁定这条删除通道：历史区改成框内滚动后，List 的左滑删除已不存在，
                // 逐条删除全压在编辑态这个红圈上（见 OpenIMEUITests.testClipboardEditDeleteFlow）
                .accessibilityIdentifier("clipboardDeleteButton")
            }
            ClipboardHistoryRow(item: item)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Self.rowHorizontalPadding)
        .padding(.vertical, Self.rowVerticalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) {
            if !isLast {
                Divider()
                    .padding(.leading, Self.rowHorizontalPadding + ClipboardHistoryRow.iconWidth
                                     + ClipboardHistoryRow.contentSpacing)
            }
        }
    }

    private func reload() {
        items = store.load()
    }

    private func deleteItem(_ item: ClipboardItem) {
        store.delete(id: item.id)
        // 删除后重置抓取去重记忆：之后再复制同样内容应能重新入库
        ClipboardSettingsStore.shared.lastSignature = nil
        reload()
    }

    private func clearAll() {
        store.clearAll()
        ClipboardSettingsStore.shared.lastSignature = nil
        reload()
    }
}

// MARK: - 单行历史条目

private struct ClipboardHistoryRow: View {

    let item: ClipboardItem

    @State private var thumbnail: UIImage?

    /// 缩略图边长（列表行内的小方图）
    private static let thumbSide: CGFloat = 40
    /// 非图片条目的类型图标占位宽度
    static let iconWidth: CGFloat = 28
    /// 图标与文字的间距（外层自绘行也按它对齐分隔线）
    static let contentSpacing: CGFloat = 12

    var body: some View {
        HStack(spacing: Self.contentSpacing) {
            if item.kind == .image {
                thumbView
            } else {
                Image(systemName: kindSymbolName)
                    .foregroundColor(.secondary)
                    .frame(width: Self.iconWidth)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(item.previewText)
                    .font(.body)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(item.createdAt, format: .dateTime)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .onAppear(perform: loadThumbIfNeeded)
    }

    @ViewBuilder
    private var thumbView: some View {
        Group {
            if let thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "photo")
                    .foregroundColor(.secondary)
            }
        }
        .frame(width: Self.thumbSide, height: Self.thumbSide)
        .clipped()
        .cornerRadius(6)
    }

    /// 按类型给一个前导图标：文本 / 链接 / 文件路径（均为 SF Symbols 基础符号）
    private var kindSymbolName: String {
        switch item.kind {
        case .text:    return "doc.text"
        case .url:     return "link"
        case .fileURL: return "folder"
        case .image:   return "photo"
        }
    }

    /// 懒加载缩略图：只在滚到可见时后台读盘解码，避免一次性把整份历史的图片全 load 进内存
    private func loadThumbIfNeeded() {
        guard item.kind == .image, thumbnail == nil else { return }
        let store = ClipboardHistoryStore.shared
        let target = item
        DispatchQueue.global(qos: .userInitiated).async {
            let data = store.imageData(for: target)
            let decoded = data.flatMap { UIImage(data: $0) }
            DispatchQueue.main.async { thumbnail = decoded }
        }
    }
}
