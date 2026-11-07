import SwiftUI

// MARK: - 执行结果 toast 的统一样式
//
// 动作型 / 开关型按钮点击后，顶部短暂弹一句「执行结果」提示，
// 让用户确认这个动作真的触发了背后的代码逻辑（而不是"点了没反应、不知道生效没有"）。
//
// 约定：只对「点了之后看不出是否真的生效」的按钮补 toast；
// 已有天然反馈的动作（按键上屏、开关变状态高亮、面板展开、系统确认框）不重复叠加，
// 否则每敲一个字母都弹提示会非常吵。
//
// 编译进 OpenIMECore，键盘扩展与主 App 均可复用，避免各处写死颜色 / 尺寸魔法值。

public enum ToastStyle {
    /// 半透明黑底：不跟随键盘主题，深浅色下都有足够对比
    public static let background = Color.black.opacity(0.8)
    /// 提示文字色
    public static let foreground = Color.white
    /// 文字字号
    public static let fontSize: CGFloat = 13
    /// 圆角
    public static let cornerRadius: CGFloat = 16
    /// 水平内边距
    public static let horizontalPadding: CGFloat = 14
    /// 垂直内边距
    public static let verticalPadding: CGFloat = 8
    /// 距顶部的留白
    public static let topOffset: CGFloat = 6
    /// 展示时长（秒）：够一眼扫清一句短提示即可，停太久会遮住候选栏、连着切换时显得碍眼
    public static let displayDuration: TimeInterval = 0.2
}
