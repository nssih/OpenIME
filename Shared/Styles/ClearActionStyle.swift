import SwiftUI
import UIKit

// MARK: - 清除类操作的统一语义样式
//
// 所有「清除 / 清空」按钮共用：浅红底 + 红字，明确表达"这是清除操作、且始终可点击"。
// 主 App 与键盘扩展均 import OpenIMECore 复用本常量，避免各处写死颜色魔法值。
//
// 约定：清除按钮不允许 disabled（空列表时点击也应真实执行清除逻辑，只是无内容可清），
// 杜绝"看起来灰掉点不动 / 点了没反应"的假按钮观感。

public enum ClearActionStyle {
    /// 前景（图标 / 文字）红
    public static let foreground = Color(UIColor.systemRed)
    /// 浅红背景
    public static let background = Color(UIColor.systemRed).opacity(0.12)
    /// 圆角
    public static let cornerRadius: CGFloat = 8
    /// 垂直内边距
    public static let verticalPadding: CGFloat = 8
}
