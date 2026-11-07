import SwiftUI
import OpenIMECore

// MARK: - 新增键盘通用命名常量
//
// 原则（按项目规范）：
//   1. 能复用 KeyboardMetrics / KeyboardAppearanceSettings 已算好的值就直接复用，不重复定义；
//   2. 能由已有尺寸动态计算（如 keyHeight 乘比例）就不写死；
//   3. 确实需要新固定值时，在此处命名并注明来源，业务代码里不出现裸数值。
// 说明：标「与原有实现一致」的值，取自原 26 键全拼键盘（KeyboardRowsView / CandidateBarView）
// 已经在用的取值，新老视图共用同一份定义，避免两处各写一个数。

// 键面通用样式（KeyboardKeyStyle / LayeredKeycapStyle /
// KeyboardTheme）与键盘几何（KeyboardMetrics）已下沉到
// Shared/Models/KeyboardStyle.swift 与 Shared/Models/KeyboardMetrics.swift：
// 主 App 设置页的键盘预览与真键盘共用同一份推导，不再各算一套。
// 本文件只保留键盘扩展专用的命名常量。

// MARK: - 副键盘符号页（长按半/全角选择 + 横向翻屏圆点）

enum NumericKeypadStyle {

    /// 符号键长按弹「半角 / 全角」气泡的阈值（秒）—— 沿用原副键盘实现的取值
    static let symbolLongPressDuration: Double = 0.35
    /// 翻屏圆点直径
    static let pageDotSize: CGFloat = 6
    /// 翻屏圆点之间的间距
    static let pageDotSpacing: CGFloat = 7
    /// 非当前屏圆点的透明度（当前屏用主色调实心，其余用键面文字色淡显）
    static let pageDotDimOpacity: Double = 0.3
    /// 横向翻屏手势的最小触发距离（pt）—— 小于它当作点按，交给按键，不抢点击
    static let pageDragMinDistance: CGFloat = 12
    /// 松手后判定「翻到上/下一屏」的位移阈值 / 屏宽
    static let pageSwipeThresholdRatio: CGFloat = 0.2
    /// 快甩翻页的松手速度阈值（pt/s）：位移没到阈值但外推落点过了也算翻一页
    /// —— 拇指翻页通常是「短推 + 快松」，只比位移会把这种干脆的手势弹回去
    static let pageSwipeFlingVelocity: CGFloat = 250
    /// 首屏再往右 / 末屏再往左拖时的阻尼系数（提示已到边）
    static let pageEdgeDamping: CGFloat = 0.35
    /// 半/全角气泡单格宽度 / 列宽
    static let widthPopupCellWidthRatio: CGFloat = 0.72
    /// 半/全角气泡高度 / 行高（含符号下方的半角/全角标注行）
    static let widthPopupHeightRatio: CGFloat = 1.0
    /// 气泡内符号与下方半角/全角标注的间距
    static let widthPopupGlyphLabelSpacing: CGFloat = 1
    /// 气泡内半角/全角标注字号 / 气泡高
    static let widthPopupLabelTextRatio: CGFloat = 0.25
    /// 气泡内高亮格标注文字透明度（白字略淡于符号，主次分明）
    static let widthPopupLabelSelectedOpacity: Double = 0.8
    /// 气泡底边与被按键顶边的间距
    static let widthPopupGap: CGFloat = 6
    /// 滑动切换气泡高亮格的位移阈值 / 键宽（死区内保持初始高亮，防手抖误切）
    static let widthSlideThresholdRatio: CGFloat = 0.3
}

// MARK: - Shift / 大写锁定

enum ShiftKeyConfig {

    /// 双击判定间隔（秒）：两次点击间隔小于它才算「双击锁大写」，否则是两次独立单击
    /// —— 取 iOS 系统多选双击的常用阈值量级，再放宽一点照顾拇指连点
    static let doubleTapLockInterval: TimeInterval = 0.35
}

// MARK: - 长按空格进入光标模式

enum CursorModeConfig {

    /// 长按触发时长（秒）——「非点按即长按」：只要按下不立即松开就算长按、立即激活对应功能
    ///（空格/字母键进光标模式、退格键连删）。工程上必须留一个「能与点按区分」的极短窗口：
    /// DragGesture(minimumDistance:0) 结构下若阈值取 0，每次点按都会先进光标模式，导致 onTap
    /// 不再触发、空格/字母打不出来。0.18s 主观即「按下不放立刻生效」，而正常点按接触 <0.1s，
    /// 不会误触。（成熟输入法如 Universe 用 0.3~0.5s 标准阈值，这里为求「立即」响应取更短值。）
    static let longPressDuration: TimeInterval = 0.18
    /// 「一滑就立即进光标模式」的横向位移阈值 = 每格步长（cursorStepPoints）× 此比例。
    /// 长按定时器（longPressDuration）仍作兜底，但空格键上只要手指横向滑过这个阈值就立刻
    /// 切入光标模式，不必死等长按时长 —— 对齐用户「只要在空格上滑动就立即移光标」的诉求。
    /// 取 0.8：390pt 屏下每格步长≈18pt → 阈值≈14pt（= 0.4×字母键宽），仍严格小于一格（Int(14/18)=0）、触发瞬间不跳格；
    /// 又足够大以区分「点按」（正常敲键的横向微动一般 <10pt）与「有意滑动」，防误触比早先的 7pt/10pt 更稳。
    /// 阈值有个硬上限：必须 < 一格步长（cursorStepPoints），否则触发瞬间会按 Int(dx/step) 跳格；故取接近但不超上限的 0.8。
    /// 空格键与字母键一致：只要横向滑过阈值就立即进光标模式，14pt 主观上仍是「一滑就到」、不牺牲立即感。
    static let slideTriggerRatio: CGFloat = 0.8
    /// 横向滑动移动一格光标的位移 = 字母键边长 × 此比例（不写死绝对点数，随屏幕/键宽缩放）。
    /// 取 0.5：390pt 屏下字母键边长≈36pt → 每格≈18pt，比原先写死的 12pt 更慢、更易对准，
    /// 消除「速度太快调不准还光飘」。实际步长由各键盘形态用 metrics.letterKeyWidth 算好注入手势组件。
    static let moveStepRatio: CGFloat = 0.5
    /// 光标模式提示文字（进入光标模式后顶替空格键标签）
    /// —— 直接沿用原有 26 键空格键的提示文字，新老键盘视觉一致
    static let indicatorText = "◀  ▶"
}

// MARK: - 退格键长按连续删除

enum BackspaceKeyConfig {

    /// 连删的最长时限（秒）：正常长按由松手的 onEnded 停表，但系统打断触摸时
    /// onEnded 不保证回调，repeats 计时器会无人喊停地删下去；超过此时限强制停。
    /// 正常人不可能按住退格超过半分钟，触发即视为异常，宁可停也不冒连删整段文本的险
    static let maxRepeatDuration: TimeInterval = 30
}

// MARK: - 快捷面板（点候选栏标志展开，覆盖整个键盘输入区）
//
// 与 CandidateExpandedPanel 同一形态：上方可滚内容 + 底部操作栏 + 下拉收起。
// 尺寸全部以「字母键边长」为基准按比例推导，不写死点数。

enum QuickPanelStyle {

    /// 分区标题字号 / 字母键边长
    static let sectionTitleSizeRatio: CGFloat = 0.36
    /// 选项文字字号 / 字母键边长
    static let itemTextSizeRatio: CGFloat = 0.42
    /// 选项图标字号 / 字母键边长
    static let itemIconSizeRatio: CGFloat = 0.45
    /// 选项内左右留白 / 字母键边长
    static let itemHorizontalPaddingRatio: CGFloat = 0.36
    /// 选项圆角 / 选项高度
    static let itemCornerRatio: CGFloat = 0.22
    /// 选项之间的横向 / 纵向间距 / 字母键边长
    static let itemHSpacingRatio: CGFloat = 0.24
    static let itemVSpacingRatio: CGFloat = 0.24
    /// 分区标题与选项、分区与分区之间的间距 / 字母键边长
    static let sectionSpacingRatio: CGFloat = 0.2
    static let sectionGroupSpacingRatio: CGFloat = 0.5
    /// 面板左右留白 / 字母键边长
    static let panelHorizontalPaddingRatio: CGFloat = 0.24
    /// 底部操作栏图标字号 / 栏高
    /// —— 与原有 CandidateExpandedPanel 的「14pt 图标 / 36.98pt 栏高」同比例
    static let bottomBarIconSizeRatio: CGFloat = 0.38
    /// 选中项的主色调底色透明度 —— 与键盘切换菜单键的 tintedKeyFillOpacity 同源思路，略深一点以示选中
    static let selectedItemFillOpacity: Double = 0.18
    /// 分区标题文字透明度
    static let sectionTitleOpacity: Double = 0.55
    /// 下拉关闭手势的触发距离 / 取消阈值（均以字母键边长为基准）
    /// —— 与原有 CandidateExpandedPanel 在 393pt 屏上的 20pt / 30pt 同量级
    static let dragMinDistanceRatio: CGFloat = 0.6
    static let dragDismissThresholdRatio: CGFloat = 0.9
}

// MARK: - 剪贴板历史面板（键盘侧覆盖面板）
//
// 与 QuickPanelView 同一形态，尺寸同样以「字母键边长」为基准按比例推导，不写死点数。

enum ClipboardPanelStyle {

    /// 图片缩略图边长 / 字母键边长（行高≈字母键边长，缩略图略小于行高留出上下内边距）
    static let thumbSideRatio: CGFloat = 0.78
    /// 缩略图圆角 / 缩略图边长
    static let thumbCornerRatio: CGFloat = 0.18
    /// 缩略图未加载时占位图标（photo）字号 / 缩略图边长
    static let thumbPlaceholderRatio: CGFloat = 0.5
    /// 占位图标透明度
    static let thumbPlaceholderOpacity: Double = 0.35
    /// 行内文字与缩略图的间距 / 字母键边长（同时用作行的左右内边距）
    static let rowInnerSpacingRatio: CGFloat = 0.24
    /// 单行文字字号 / 字母键边长
    static let rowTextSizeRatio: CGFloat = 0.42
    /// 空态主提示与次要提示的行间距 / 字母键边长
    static let emptyHintSpacingRatio: CGFloat = 0.12
    /// 次要提示字号 / 主提示字号（小一档，不抢「暂无记录」这句主文案）
    static let subHintSizeRatio: CGFloat = 0.85
    /// 次要提示透明度 / 主提示透明度
    static let subHintOpacityRatio: Double = 0.8
}

// MARK: - 动画时长

enum KeyboardAnimation {

    /// 键盘形态切换 / 候选面板展开收起的过渡时长 —— 与原有实现一致
    static let transitionDuration: Double = 0.15
}
