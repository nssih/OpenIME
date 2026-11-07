import Foundation

// MARK: - 候选栏快捷功能目录
//
// 统一功能目录：凡用户可自定义、可固定到候选栏空态中段的功能都在此登记。
// 编译进 OpenIMECore，主 App（配置 UI）与键盘扩展（渲染 + 响应）共用同一份定义。
//
// 设计取舍：
//   - 纯数据枚举，不含任何行为闭包 —— 响应逻辑放键盘侧（IMEKeyboardView.onShortcut 的 switch），
//     避免把 UI 依赖塞进 Shared，也便于单测直接校验 allCases
//   - 所有 SF Symbol 名均已在当前 SDK 实测存在（项目既有约定：图标不可用会回落，但这里逐个核过）

/// 可固定到候选栏空态中段的快捷功能
public enum CandidateBarShortcut: String, Codable, CaseIterable, Identifiable {

    /// 剪贴板历史面板（点一下展开历史、查看并选择复制过的内容上屏；
    /// 图标颜色跟随「记录剪贴板」开关，开关本身在快捷面板分区四操作）
    case clipboardHistory
    /// 123 数字键盘（切换数字/符号页）
    case numberKeyboard
    /// 中 / 英输入模式切换
    case toggleEnglish
    /// 候选注释显隐
    case toggleAnnotation
    /// 智能预测开关
    case togglePrediction
    /// 拼音动态调频开关
    case toggleDynamicFreq
    /// 主题循环（浅、深、跟随系统）
    case theme
    /// 键盘形态（打开快捷面板）
    case keyboardMode
    /// 输入方案（打开快捷面板）
    case scheme
    /// 清空当前输入
    case clearInput

    public var id: String { rawValue }

    /// 图标（SF Symbol）；若 iconText 非 nil 则优先用文字呈现
    public var symbolName: String {
        switch self {
        case .clipboardHistory:  return "doc.on.clipboard"
        case .numberKeyboard:    return "number"
        case .toggleEnglish:     return "globe"
        case .toggleAnnotation:  return "book"
        case .togglePrediction:  return "wand.and.stars"
        case .toggleDynamicFreq: return "arrow.up.forward"
        case .theme:             return "circle.lefthalf.filled"
        case .keyboardMode:      return "keyboard"
        case .scheme:            return "books.vertical"
        case .clearInput:        return "xmark.circle"
        }
    }

    /// 用纯文字而非 SF Symbol 呈现图标时的文字（nil = 用 symbolName）。
    /// 中/英切换没有任何 SF Symbol 比「En」更直白（地球/字都易混），故用文字；
    /// 开关态仍靠高亮表达（英文开=主色高亮，中文=暗色）。
    public var iconText: String? {
        switch self {
        case .toggleEnglish: return "En"
        default: return nil
        }
    }

    /// 显示名称（主 App 配置列表 / 无障碍标签）
    /// 剪贴板叫「剪贴板历史」：点下去就是打开历史列表，名称与行为一致；
    /// 「记录剪贴板」那颗芯片在快捷面板分区四，负责开关，两者不撞名也不混职责
    public var title: String {
        switch self {
        case .clipboardHistory:  return "剪贴板历史"
        case .numberKeyboard:    return "123"
        case .toggleEnglish:     return "中 / 英"
        case .toggleAnnotation:  return "候选注释"
        case .togglePrediction:  return "智能预测"
        case .toggleDynamicFreq: return "动态调频"
        case .theme:             return "主题"
        case .keyboardMode:      return "键盘形态"
        case .scheme:            return "输入方案"
        case .clearInput:        return "清空输入"
        }
    }

    /// 是否为「开关型」功能：点一下就翻状态，动作本身即最终效果。
    /// 其余动作型（打开二级面板 / 清空 / 主题循环）不翻状态。
    public var isToggle: Bool {
        switch self {
        case .numberKeyboard, .toggleEnglish, .toggleAnnotation, .togglePrediction, .toggleDynamicFreq:
            return true
        case .clipboardHistory, .theme, .keyboardMode, .scheme, .clearInput:
            return false
        }
    }

    /// 图标着色是否由当前状态决定（开=绿，关=灰）。
    /// 开关型全集之外多剪贴板这一个特例：候选栏上的剪贴板图标点下去是「看历史」
    ///（动作型，本身翻不了任何状态），但颜色必须跟着「记录剪贴板」开关走——用户
    /// 在快捷面板里就地开关记录后，回键盘一眼就能从图标确认现在到底在不在记。
    /// 只影响颜色，不影响点击语义，也不改变 isToggle 的分类。
    public var reflectsState: Bool {
        isToggle || self == .clipboardHistory
    }

    // MARK: - 候选栏快捷入口收录资格（新增功能前必读）
    //
    // 候选栏快捷入口的可选池只收「点一下直达最终效果」的功能，
    // 具体哪些进候选栏由用户在设置页 / 快捷面板分区〇自行勾选（默认全选 6 个 bar-eligible 功能）：
    //   开关（123、中/英、候选注释、智能预测、动态调频）：点一下在开与关之间翻转；
    //   即用面板（剪贴板历史）：点一下直接展开历史，选了就能上屏，不再多一层入口。
    //   两者都必须在候选栏上用绿/灰把当前状态标出来（着色口径见 reflectsState）。
    //
    // 以下两类不收：
    //   1. 二级入口：键盘形态 / 输入方案——点一下只是打开快捷面板，还要再选一次才生效；
    //   2. 低频 / 非开关：主题（三态循环、视觉自明）、清空输入（退格可替代、场景弱）。
    //
    // 新增功能时先问自己：它能不能一键直达最终效果？
    //   能（开关、打开即用面板）：在这里返回 true，并补 symbolName 或 iconText / title，
    //     同时把两处状态口径对齐（键盘 IMEKeyboardView.isShortcutOn / 设置页 shortcutIsOn）；
    //   不能（需进子页面再配置、或只是元设置、二级入口）：返回 false，不要加进快捷栏。
    public var isBarEligible: Bool {
        switch self {
        case .clipboardHistory, .numberKeyboard, .toggleEnglish, .toggleAnnotation, .togglePrediction, .toggleDynamicFreq:
            return true
        case .theme, .clearInput, .keyboardMode, .scheme:
            return false
        }
    }

    // MARK: - id 到枚举的映射（纯函数，便于单测）

    /// 把有序 id 列表映射成枚举：保序、跳过未知项（版本回退时可能出现）、去重。
    /// CandidateBarShortcutStore.shortcuts 复用此逻辑；抽成纯函数以便单测不碰 App Group 单例。
    public static func resolve(_ ids: [String]) -> [CandidateBarShortcut] {
        var seen = Set<String>()
        return ids.compactMap { id in
            guard !seen.contains(id), let shortcut = CandidateBarShortcut(rawValue: id) else { return nil }
            seen.insert(id)
            return shortcut
        }
    }
}
