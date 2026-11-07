import SwiftUI
import UIKit
import OpenIMECore

// MARK: - 剪贴板历史面板（键盘侧覆盖面板）
//
// 形态与 CandidateExpandedPanel / QuickPanelView 一致：上方可滚内容 + 底部操作栏 + 下拉收起，
// 覆盖「候选栏 + 键盘体」整块区域（高度由调用方传 panelTotalHeight）。
// 尺寸全部以「字母键边长」为基准按比例推导（见 ClipboardPanelStyle），不写死点数。
//
// 交互约束：
//   文本 / URL / 路径条目直接上屏并关面板
//   图片条目：iOS 键盘扩展无法把图片直接插入宿主 App，只能写回系统剪贴板，
//     关面板后由用户手动粘贴（长按输入框选粘贴）
//   空态：记录开着时只说「暂无剪贴板记录」；记录关着时再补一句去哪儿开启
//     （候选栏那枚图标颜色是灰的 = 没在记，用户点进来不能只看到一个空面板）

struct ClipboardHistoryPanel: View {

    let letterKeySize: CGFloat
    let appearance: KeyboardAppearanceSettings
    let bottomBarHeight: CGFloat
    /// 文本类条目上屏（不含关面板，关面板由本视图统一处理）
    let onInsertText: (String) -> Void
    let onClose: () -> Void

    @State private var items: [ClipboardItem] = []
    /// 清空的两阶段确认态：第一次点 trash 进入「确认清空」，再点才真执行
    @State private var confirmClear = false
    /// 清空结果的短暂反馈文字（显示 2 秒后消失）
    @State private var clearFeedback: String?

    private let store = ClipboardHistoryStore.shared

    var body: some View {
        let textColor = KeyboardTheme.keyText(appearance)
        let vSpacing = letterKeySize * QuickPanelStyle.itemVSpacingRatio

        VStack(spacing: 0) {
            if items.isEmpty {
                Spacer(minLength: 0)
                VStack(spacing: letterKeySize * ClipboardPanelStyle.emptyHintSpacingRatio) {
                    emptyHint(clearFeedback ?? "暂无剪贴板记录",
                              tint: clearFeedback == nil ? nil : ClearActionStyle.foreground)
                    // 记录没开时补一句指路：候选栏那个图标是灰的，用户点进来看到空面板，
                    // 不该让他自己猜「为什么没东西、去哪儿开」——开关在快捷面板里
                    if clearFeedback == nil && !ClipboardSettingsStore.shared.isEnabled {
                        subHint("未开启记录，可在快捷面板「剪贴板」里开启")
                    }
                }
                Spacer(minLength: 0)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    // 条目之间用一条横线分隔，不再各自套带底色的单元格：
                    // spacing 归零，改在相邻两条之间插一条 Divider（首条前不插）
                    VStack(spacing: 0) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            if index > 0 {
                                Divider()
                            }
                            row(for: item, textColor: textColor)
                        }
                    }
                    .padding(.horizontal, letterKeySize * QuickPanelStyle.panelHorizontalPaddingRatio)
                    .padding(.vertical, vSpacing)
                }
            }

            // 底部操作栏：左 = 清空全部，右 = 关面板（与候选展开面板同结构）
            // 与上方列表之间补一条分隔线，与栏内竖直 Divider 同一观感
            Divider()
            HStack(spacing: 0) {
                clearButton()
                Divider()
                bottomBarItem("chevron.up",
                              identifier: "clipboardClose",
                              textColor: textColor,
                              action: onClose)
            }
            .frame(height: bottomBarHeight)
            .background(KeyboardTheme.background(appearance))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(KeyboardTheme.background(appearance))
        .accessibilityIdentifier("clipboardHistoryPanel")
        .onAppear { reload() }
        .gesture(
            DragGesture(minimumDistance: letterKeySize * QuickPanelStyle.dragMinDistanceRatio,
                        coordinateSpace: .local)
                .onEnded { value in
                    if value.translation.height > letterKeySize * QuickPanelStyle.dragDismissThresholdRatio {
                        onClose()
                    }
                }
        )
    }

    // MARK: - 数据

    private func reload() {
        items = store.load()
    }

    private func handleTap(_ item: ClipboardItem) {
        switch item.kind {
        case .image:
            // 图片无法直插宿主 App，回填剪贴板由用户手动粘贴
            if let data = store.imageData(for: item), let image = UIImage(data: data) {
                UIPasteboard.general.image = image
            }
            onClose()
        case .text, .url, .fileURL:
            if let text = item.text, !text.isEmpty {
                onInsertText(text)
            }
            onClose()
        }
    }

    // MARK: - 子视图

    @ViewBuilder
    private func row(for item: ClipboardItem, textColor: Color) -> some View {
        Button {
            handleTap(item)
        } label: {
            HStack(spacing: letterKeySize * ClipboardPanelStyle.rowInnerSpacingRatio) {
                if item.kind == .image {
                    ClipboardThumb(item: item,
                                   side: letterKeySize * ClipboardPanelStyle.thumbSideRatio,
                                   tint: textColor)
                }
                Text(item.previewText)
                    .font(.system(size: letterKeySize * ClipboardPanelStyle.rowTextSizeRatio))
                    .foregroundColor(textColor)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, letterKeySize * ClipboardPanelStyle.rowInnerSpacingRatio)
            .frame(height: letterKeySize)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .accessibilityIdentifier("clipboardItem-\(item.id.uuidString)")
    }

    @ViewBuilder
    private func bottomBarItem(_ icon: String,
                               identifier: String,
                               textColor: Color,
                               action: @escaping () -> Void) -> some View {
        VStack {
            Image(systemName: icon)
                .font(.system(size: bottomBarHeight * QuickPanelStyle.bottomBarIconSizeRatio,
                              weight: .semibold))
                .foregroundColor(textColor)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .accessibilityIdentifier(identifier)
    }

    /// 底部左格：清空全部（两阶段确认 + 结果反馈）
    /// 第一次点进入确认清空态（3 秒未确认自动取消），再点才真正 clearAll；
    ///    空列表点击给暂无记录可清空提示，杜绝点了没反应、不知道执行没有的观感
    @ViewBuilder
    private func clearButton() -> some View {
        VStack {
            if confirmClear {
                Text("确认清空")
                    .font(.system(size: bottomBarHeight * QuickPanelStyle.bottomBarIconSizeRatio * 0.7,
                                  weight: .semibold))
                    .foregroundColor(ClearActionStyle.foreground)
            } else {
                Image(systemName: "trash")
                    .font(.system(size: bottomBarHeight * QuickPanelStyle.bottomBarIconSizeRatio,
                                  weight: .semibold))
                    .foregroundColor(ClearActionStyle.foreground)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ClearActionStyle.background)
        .contentShape(Rectangle())
        .onTapGesture {
            if confirmClear {
                store.clearAll()
                // 清空后重置抓取去重记忆：用户之后再复制同样的内容应重新入库
                ClipboardSettingsStore.shared.lastSignature = nil
                reload()
                confirmClear = false
                flashFeedback("已清空全部记录")
            } else if items.isEmpty {
                flashFeedback("暂无剪贴板记录可清空")
            } else {
                confirmClear = true
                // 3 秒未确认自动取消，避免确认态长期停留误触
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    confirmClear = false
                }
            }
        }
        .accessibilityIdentifier("clipboardClearAll")
    }

    /// 短暂反馈文字：显示 2 秒后自动消失
    private func flashFeedback(_ text: String) {
        clearFeedback = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            clearFeedback = nil
        }
    }

    @ViewBuilder
    private func emptyHint(_ text: String, tint: Color? = nil) -> some View {
        Text(text)
            .font(.system(size: letterKeySize * QuickPanelStyle.itemTextSizeRatio))
            .foregroundColor(tint ?? KeyboardTheme.keyText(appearance)
                .opacity(QuickPanelStyle.sectionTitleOpacity))
            .multilineTextAlignment(.center)
    }

    /// 空态下的次要提示：比主提示小一档、更淡，不让它抢「暂无记录」这句主文案
    @ViewBuilder
    private func subHint(_ text: String) -> some View {
        Text(text)
            .font(.system(size: letterKeySize * QuickPanelStyle.itemTextSizeRatio
                                        * ClipboardPanelStyle.subHintSizeRatio))
            .foregroundColor(KeyboardTheme.keyText(appearance)
                .opacity(QuickPanelStyle.sectionTitleOpacity
                        * ClipboardPanelStyle.subHintOpacityRatio))
            .multilineTextAlignment(.center)
            .accessibilityIdentifier("clipboardEmptySubHint")
    }
}

// MARK: - 图片缩略图（懒加载）
//
// 只在滚到可见（onAppear）时后台读盘解码，避免一次性把整份历史的图片全load进内存。

private struct ClipboardThumb: View {
    let item: ClipboardItem
    let side: CGFloat
    let tint: Color

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "photo")
                    .font(.system(size: side * ClipboardPanelStyle.thumbPlaceholderRatio))
                    .foregroundColor(tint.opacity(ClipboardPanelStyle.thumbPlaceholderOpacity))
            }
        }
        .frame(width: side, height: side)
        .clipped()
        .cornerRadius(side * ClipboardPanelStyle.thumbCornerRatio)
        .onAppear(perform: loadIfNeeded)
    }

    private func loadIfNeeded() {
        guard image == nil else { return }
        let store = ClipboardHistoryStore.shared
        let target = item
        DispatchQueue.global(qos: .userInitiated).async {
            let data = store.imageData(for: target)
            let decoded = data.flatMap { UIImage(data: $0) }
            DispatchQueue.main.async { image = decoded }
        }
    }
}
