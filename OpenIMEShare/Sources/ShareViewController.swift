import OpenIMECore
import UIKit

// MARK: - 分享扩展「存到 聿·输入法」
//
// 唯一能可靠覆盖「键盘收起时在别处复制」的入口：用户在系统分享菜单里显式点「存到 聿·输入法」，
// 把文本 / 链接 / 图片 / 文件路径存进与键盘、主 App 同一份剪贴板历史（App Group 共享磁盘）。
//
// 与自动抓取的区别：
//   - 分享保存是用户显式动作，即使「记录剪贴板历史」开关关闭也允许保存（仍受 maxCount trim）；
//   - 来源不是剪贴板，故不写 lastChangeCount / lastSignature（不干扰键盘抓取的去重记忆）。

final class ShareViewController: UIViewController {

    /// 保存结果在界面上停留的时长，让用户看清「已存到 聿·输入法」再自动关闭
    private static let resultDisplayDuration: TimeInterval = 0.8

    private let store = ClipboardHistoryStore.shared
    private let statusLabel = UILabel()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        setupStatusLabel()
        saveSharedItems()
    }

    // MARK: - UI

    private func setupStatusLabel() {
        statusLabel.text = "正在保存…"
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0
        statusLabel.textColor = .secondaryLabel
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(statusLabel)
        NSLayoutConstraint.activate([
            statusLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            statusLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            statusLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24),
        ])
    }

    // MARK: - 保存

    private func saveSharedItems() {
        guard let inputItems = extensionContext?.inputItems as? [NSExtensionItem], !inputItems.isEmpty else {
            finish(saved: false, message: "没有可保存的内容")
            return
        }

        let group = DispatchGroup()
        // loadItem 回调在后台线程，savedAny 用串行队列保护
        let stateQueue = DispatchQueue(label: "com.openime.share.state")
        var savedAny = false

        for inputItem in inputItems {
            for provider in inputItem.attachments ?? [] {
                guard let typeID = provider.registeredTypeIdentifiers.first else { continue }
                group.enter()
                provider.loadItem(forTypeIdentifier: typeID, options: nil) { [weak self] object, _ in
                    guard let self else { group.leave(); return }
                    // NSItemProvider 加载出的对象（NSString / NSURL / UIImage / NSData）
                    // 交给与键盘抓取同一套纯转换逻辑
                    if let captured = ClipboardCapture.makeItem(from: object) {
                        self.store.append(captured.item, imageData: captured.imageData)
                        stateQueue.sync { savedAny = true }
                    }
                    group.leave()
                }
            }
        }

        group.notify(queue: .main) { [weak self] in
            guard let self else { return }
            // 三进程共享同一份磁盘存储：确保所有 append 落盘后再关闭扩展，
            // 否则系统可能在写盘完成前回收进程，导致「分享了却没存进去」
            self.store.flush()
            let didSave = stateQueue.sync { savedAny }
            self.finish(saved: didSave, message: didSave ? "已存到 聿·输入法" : "没有可保存的内容")
        }
    }

    private func finish(saved: Bool, message: String) {
        statusLabel.text = message
        statusLabel.textColor = saved ? .label : .secondaryLabel
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.resultDisplayDuration) { [weak self] in
            self?.extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
        }
    }
}
