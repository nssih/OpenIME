import SwiftUI
import OpenIMECore

// MARK: - 副键盘布局模块：数字 / 符号副键盘
//
// 主键盘点击 123 进入本副键盘：
//   数字页：五列竖读 —— 左列 ，。？！、中间三列竖读 1-9、右列 ABC/#+=/退格/回车，
//     底行 ！；0@ 回车（符号页键在 ABC 正下方；功能行无网格手势，成对符号在这里退化为普通点按键）
//   符号页：中英文符号合并到同一键位，点按跟随中/英模式上屏（英文半角、中文全角），
//     键面字形也随模式变；长按成对符号不松手、在键上方气泡里跟手滑动选半/全角，松手直接上屏；
//     符号多到一屏放不下，横向滑动翻屏，功能行中格的圆点指示当前屏
//   每页底部都是固定功能行：数字页 ！/；/0/@/回车，符号页 123/ABC/翻页圆点/退格/回车
//
// 键盘形态切换（26 键 / 双拼）不再占用副键盘键位，走候选栏左端切换标志
// 打开的快捷面板键盘分区，所以这里没有单独的切换菜单，键位全部还给数字 / 符号。
//
// 布局数据全部来自 Shared/InputModes/NumericKeypadLayout.swift（纯数据模型），
// 本视图只负责渲染；「半角/全角取哪个」由 KeypadKeySpec.glyph(isEnglish:) 纯函数决定。
//
// 交互：轻点输入；长按成对符号滑动选半/全角（松手上屏）。副键盘已无空格键，
//       长按空格进光标模式的入口随之取消（光标模式仍在主键盘的空格/字母键上）。
//
// 翻屏用自绘 offset（不用 UIScrollView / TabView 分页）：点按零延迟；
// 网格区触摸状态机是单个 DragGesture：点按上屏、长按成对符号弹气泡滑动选、
// 横滑翻屏三者按位移/时长判定互不干扰，符合「运行效率高、无阻塞」的设计初衷。

struct NumberKeyboardView: View {
    let metrics: KeyboardMetrics
    let appearanceSettings: KeyboardAppearanceSettings
    /// 当前是否处于英文输入模式：决定符号键点按 / 键面取半角还是全角
    let isEnglishActive: Bool
    let hasInput: Bool

    let onInsert: (String) -> Void
    let onBackspace: () -> Void
    let onReturn: () -> Void
    let onSwitchToLetters: () -> Void
    let onCursorModeStart: () -> Void
    let onCursorModeEnd: () -> Void
    let onMoveCursor: (Int) -> Void

    /// 当前副键盘页面（0=数字页，1=符号页）
    @State private var pageIndex = NumericKeypadLayout.numberPageIndex

    /// 光标模式（键盘级共享：激活后整个键盘区域的按键都不再上屏）
    @State private var isCursorMode = false
    /// 长按符号键不松手时待选半/全角的键（nil = 不显示气泡）
    @State private var pendingSymbol: KeypadKeySpec?
    /// 气泡锚点（手指按下位置，命名坐标系内）：气泡浮在该点正上方
    @State private var popupAnchor: CGPoint = .zero
    /// 气泡当前高亮格：0=半角 1=全角
    @State private var widthSelection = 0
    /// 网格区按下的键（符号键按压反馈 + 松手时判定用途）；nil = 无触摸
    @State private var touchKeySpec: KeypadKeySpec?
    /// 符号键长按计时器：到时弹气泡（沿用 CursorSpaceKey 的 Timer 路子，避开手势组合坑）
    @State private var widthTimer: Timer?
    /// 符号页当前停留的屏（翻屏圆点 + offset 用）
    @State private var currentScreen = 0
    /// 本次触摸已被判成翻屏（位移已过最小触发距离）。
    /// 一旦置位，本触摸不再回到「点按」或「长按选半/全角」—— 否则手指斜着滑过键面时，
    /// 长按计时会先抢掉这次手势，看起来就是「滑不动 / 要抬起来重按才能翻页」
    @State private var pageSwipeIntent = false
    /// 翻屏拖拽的实时位移：独立于 body 观察（见 `PageDragTracker` 注释）
    @StateObject private var pageDrag = PageDragTracker()

    var body: some View {
        let m = metrics
        let a = appearanceSettings
        let page = NumericKeypadLayout.pages[pageIndex]
        // 网格区 screenRowCount 行 + 固定功能行 1 行，共 4 行等高（键尺寸与原三页时代一致）
        let totalRows = NumericKeypadLayout.screenRowCount + 1

        // 行高由「实际可用高度」均分得出：进副键盘时按键跟着变高铺满，
        // 不会在底部留一条空白（也不写死 4 行乘键高）
        GeometryReader { geo in
            let rowH = rowHeight(total: geo.size.height, rowCount: totalRows, metrics: m)
            let gridH = rowH * CGFloat(NumericKeypadLayout.screenRowCount)
                + m.rowSpacing * CGFloat(NumericKeypadLayout.screenRowCount - 1)

            VStack(spacing: m.rowSpacing) {
                // 网格区：点按上屏 / 长按气泡滑动选 / 横滑翻屏全部收在 gridGesture
                gridArea(page, rowH: rowH, gridH: gridH, metrics: m, appearance: a)
                    .contentShape(Rectangle())
                    .gesture(gridGesture(page, rowH: rowH,
                                         gridWidth: geo.size.width - m.hPad * 2,
                                         metrics: m))
                functionRow(page.functionRow, screenCount: page.screens.count,
                            rowH: rowH, metrics: m, appearance: a)
            }
            .padding(.top, m.topBotPad)
            .padding(.horizontal, m.hPad)
        }
        .overlay { widthPopupLayer }
        .onChange(of: pageIndex) { _ in
            pendingSymbol = nil
            currentScreen = 0
            pageSwipeIntent = false
            pageDrag.settle()
        }
        .onChange(of: currentScreen) { _ in pendingSymbol = nil }
    }

    // MARK: - 网格区（单屏 / 翻屏）

    /// 网格区：数字页单屏直铺；符号页横向翻屏（翻屏手势收在 gridGesture）
    @ViewBuilder
    private func gridArea(_ page: KeypadPageSpec, rowH: CGFloat, gridH: CGFloat,
                          metrics m: KeyboardMetrics,
                          appearance a: KeyboardAppearanceSettings) -> some View {
        if page.screens.count <= 1 {
            screenRows(page.screens[0], rowH: rowH, metrics: m, appearance: a)
        } else {
            pagedGrid(page, rowH: rowH, gridH: gridH, metrics: m, appearance: a)
        }
    }

    /// 一屏 = screenRowCount 行乘 columnCount 列，每行用 GeometryReader 取宽算等宽列
    @ViewBuilder
    private func screenRows(_ rows: [[KeypadKeySpec]], rowH: CGFloat,
                            metrics m: KeyboardMetrics,
                            appearance a: KeyboardAppearanceSettings) -> some View {
        VStack(spacing: m.rowSpacing) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                GeometryReader { rowGeo in
                    let w = columnWidth(total: rowGeo.size.width, spacing: m.keySpacing)
                    HStack(spacing: m.keySpacing) {
                        ForEach(row) { spec in
                            keyView(spec, width: w, height: rowH, screenCount: 0,
                                    inFunctionRow: false, metrics: m, appearance: a)
                        }
                    }
                }
                .frame(height: rowH)
            }
        }
    }

    /// 符号页翻屏：所有屏横向排开，按 currentScreen + 实时拖拽位移整体 offset，外层裁到一屏宽。
    /// 每帧只改 `PageDragTracker.translation` 这一个值，offset 挂在独立的小 modifier 上 ——
    /// 拖拽期间只有那一层跟随重算，不把整个副键盘的 body（网格 + 功能行 + 各按键）拖着重建，
    /// 这是「左右滑动不顺畅」的第一成因：以前每帧要写两个 @State，body 逐帧全量重算。
    private func pagedGrid(_ page: KeypadPageSpec, rowH: CGFloat, gridH: CGFloat,
                           metrics m: KeyboardMetrics,
                           appearance a: KeyboardAppearanceSettings) -> some View {
        GeometryReader { gridGeo in
            let pageWidth = gridGeo.size.width
            HStack(spacing: 0) {
                ForEach(Array(page.screens.enumerated()), id: \.offset) { _, screen in
                    screenRows(screen, rowH: rowH, metrics: m, appearance: a)
                        .frame(width: pageWidth)
                }
            }
            // 先跟手平移，再裁到一屏宽：顺序反了就会把整条横排按自己坐标裁掉，翻不出下一页
            .modifier(PagedDragOffset(currentScreen: currentScreen,
                                      pageWidth: pageWidth,
                                      drag: pageDrag))
            .frame(width: pageWidth, height: gridH, alignment: .leading)
            .clipped()
        }
        .frame(height: gridH)
    }

    // MARK: - 网格区统一触摸状态机

    /// 网格区唯一手势：点按上屏 / 长按成对符号弹气泡滑动选 / 横滑翻屏，三者收在这里。
    /// 收成一个手势是为了避免子键手势与翻屏手势互吞：此前 highPriorityGesture 序列手势
    /// 会吞掉点按，且 DragGesture 不移动不回调导致长按气泡不自动出现。
    private func gridGesture(_ page: KeypadPageSpec, rowH: CGFloat, gridWidth: CGFloat,
                             metrics m: KeyboardMetrics) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard !isCursorMode else { return }
                if touchKeySpec == nil {
                    touchKeySpec = keySpec(at: value.startLocation, page: page,
                                           rowH: rowH, gridWidth: gridWidth, metrics: m)
                    pageDrag.begin()
                    // 气泡锚点：网格区原点 = 横/竖留白，由此换算到根坐标空间
                    popupAnchor = CGPoint(x: m.hPad + value.startLocation.x,
                                          y: m.topBotPad + value.startLocation.y)
                    if touchKeySpec?.hasWidthChoice == true {
                        startWidthTimer()
                    }
                }
                let dx = value.translation.width
                // 原始位移只存在 tracker 的非发布字段里：长按计时要拿它判「是不是翻屏」，
                // 但那个判定不必劳烦 body 重算
                pageDrag.record(dx: dx)
                // 气泡出现后横向滑动只切换高亮，不再驱动翻屏
                if pendingSymbol != nil {
                    updateWidthSelection(translation: dx,
                                         keyWidth: columnWidth(total: gridWidth,
                                                               spacing: m.keySpacing))
                    return
                }
                guard page.screens.count > 1 else { return }
                // 位移一过最小触发距离就给本次触摸上「翻屏」的锁，同时取消长按气泡计时；
                // 锁上之后本触摸不再回到点按 / 长按（斜着滑过键面不再被长按抢走手势）
                if !pageSwipeIntent, abs(dx) <= NumericKeypadStyle.pageDragMinDistance { return }
                if !pageSwipeIntent {
                    pageSwipeIntent = true
                    stopWidthTimer()
                }
                applyPageDrag(dx: dx, screenCount: page.screens.count)
            }
            .onEnded { value in
                stopWidthTimer()
                let dx = value.translation.width
                let isPageSwipe = pageSwipeIntent
                defer {
                    touchKeySpec = nil
                    pageSwipeIntent = false
                    pageDrag.end()
                }
                guard !isCursorMode else { return }
                if let symbol = pendingSymbol {
                    pendingSymbol = nil
                    // 显式滑动选择：插入原样字符，不再随中/英模式二次转换
                    onInsert(widthSelection == 1 ? (symbol.fullWidth ?? symbol.label) : symbol.label)
                } else if isPageSwipe {
                    finishPageDrag(dx: dx, velocity: value.velocity.width,
                                   screenCount: page.screens.count, pageWidth: gridWidth)
                } else if let symbol = touchKeySpec, symbol.hasWidthChoice {
                    // 成对符号键轻点（这些键不再是 Button，统一在这里上屏）
                    onInsert(symbol.glyph(isEnglish: isEnglishActive))
                }
            }
    }

    /// 长按计时：到时弹气泡；若已滑出翻屏距离则视为翻屏意图不弹。
    /// 沿用 CursorSpaceKey 的路子：Timer + 主线程回调，不做手势组合，点按/长按/滑动各走各路
    private func startWidthTimer() {
        stopWidthTimer()
        widthTimer = Timer.scheduledTimer(withTimeInterval: NumericKeypadStyle.symbolLongPressDuration,
                                          repeats: false) { _ in
            DispatchQueue.main.async {
                stopWidthTimer()
                guard pendingSymbol == nil,
                      !pageSwipeIntent,
                      abs(pageDrag.rawDx) <= NumericKeypadStyle.pageDragMinDistance,
                      let symbol = touchKeySpec, symbol.hasWidthChoice else { return }
                pendingSymbol = symbol
                widthSelection = defaultWidthIndex
                Haptics.confirm()
            }
        }
    }

    private func stopWidthTimer() {
        widthTimer?.invalidate()
        widthTimer = nil
    }

    /// 由触摸位置反查键（网格等距 3 行乘 5 列，直接除算）；落在间隙/越界返回 nil
    private func keySpec(at point: CGPoint, page: KeypadPageSpec, rowH: CGFloat,
                         gridWidth: CGFloat, metrics m: KeyboardMetrics) -> KeypadKeySpec? {
        let colW = columnWidth(total: gridWidth, spacing: m.keySpacing)
        let col = Int(point.x / (colW + m.keySpacing))
        let row = Int(point.y / (rowH + m.rowSpacing))
        guard col >= 0, col < NumericKeypadLayout.columnCount,
              row >= 0, row < NumericKeypadLayout.screenRowCount else { return nil }
        let screen = page.screens[Swift.min(currentScreen, page.screens.count - 1)]
        return screen[row][col]
    }

    /// 翻屏跟手：把拖拽位移（首/末屏再往外拖有阻尼）写给 tracker，由 offset 层自行跟随
    private func applyPageDrag(dx: CGFloat, screenCount: Int) {
        var d = dx
        let atLeadingEdge = currentScreen == 0 && d > 0
        let atTrailingEdge = currentScreen == screenCount - 1 && d < 0
        if atLeadingEdge || atTrailingEdge { d *= NumericKeypadStyle.pageEdgeDamping }
        pageDrag.follow(dx: d)
    }

    /// 翻屏松手：位移过阈值，或位移不够但松手速度很快（按速度外推的落点过阈值）都算翻页。
    /// 外推是分页的通行做法（UIScrollView 就是把惯性末端位置当判定位置）：
    /// 只比位移阈值时，一个干脆的快甩（手指只走了十几 pt）会被弹回原屏，
    /// 用户手里的感受就是「滑动要特别用力才能翻页」
    private func finishPageDrag(dx: CGFloat, velocity: CGFloat,
                                screenCount: Int, pageWidth: CGFloat) {
        let threshold = pageWidth * NumericKeypadStyle.pageSwipeThresholdRatio
        let flinging = NumericKeypadStyle.pageSwipeFlingVelocity
        var target = currentScreen
        if (dx < -threshold) || (velocity < -flinging && dx < 0) {
            target += 1
        } else if (dx > threshold) || (velocity > flinging && dx > 0) {
            target -= 1
        }
        target = Swift.min(Swift.max(target, 0), screenCount - 1)
        withAnimation(.easeOut(duration: KeyboardAnimation.transitionDuration)) {
            currentScreen = target
            pageDrag.settle()
        }
    }

    // MARK: - 固定功能行

    @ViewBuilder
    private func functionRow(_ row: [KeypadKeySpec], screenCount: Int, rowH: CGFloat,
                             metrics m: KeyboardMetrics,
                             appearance a: KeyboardAppearanceSettings) -> some View {
        GeometryReader { rowGeo in
            let w = columnWidth(total: rowGeo.size.width, spacing: m.keySpacing)
            HStack(spacing: m.keySpacing) {
                ForEach(row) { spec in
                    keyView(spec, width: w, height: rowH, screenCount: screenCount,
                            inFunctionRow: true, metrics: m, appearance: a)
                }
            }
        }
        .frame(height: rowH)
    }

    // MARK: - 按键渲染

    @ViewBuilder
    private func keyView(_ spec: KeypadKeySpec,
                         width: CGFloat,
                         height: CGFloat,
                         screenCount: Int,
                         inFunctionRow: Bool,
                         metrics m: KeyboardMetrics,
                         appearance a: KeyboardAppearanceSettings) -> some View {
        switch spec.action {
        case .literal:
            literalKey(spec, width: width, height: height,
                       inFunctionRow: inFunctionRow, metrics: m, appearance: a)

        case .space:
            // 空格键：轻点上屏空格，长按进入全键盘光标模式
            CursorSpaceKey(
                width: width,
                height: height,
                fontSize: m.letterFontSize,
                keyCorner: m.keyCorner,
                appearance: a,
                cursorStepPoints: m.letterKeyWidth * CursorModeConfig.moveStepRatio,
                isCursorMode: $isCursorMode,
                onCursorModeStart: onCursorModeStart,
                onCursorModeEnd: onCursorModeEnd,
                onMoveCursor: onMoveCursor,
                onTap: { onInsert(" ") }
            ) {
                Text("空格")
                    .font(.system(size: KeyboardKeyStyle.secondaryTextFontSize(
                        letterFontSize: m.letterFontSize)))
                    .foregroundColor(KeyboardTheme.keyText(a))
            }

        case .backspace:
            // 图标基准传 letterKeyWidth（键宽、高度无关）而非 rowH：副键盘行高 rowH 在 26 键 / 双拼下
            // == keyHeight，会随用户调高键盘被拉粗、显得很重；改跟键宽后退格图标恒定不变粗，与主键盘
            // 同一修法，也与本副键盘的数字 / 符号字形（走绝对 letterFontSize、不随高度变）协调一致。
            // 默认系数下 rowH == letterKeyWidth，逐字节零回归。
            BackspaceKey(height: height, iconHeight: m.letterKeyWidth, keyCorner: m.keyCorner,
                         appearance: a, onTap: onBackspace)
                .frame(width: width)

        case .returnKey:
            ReturnKey(hasInput: hasInput, fontSize: m.funcFontSize,
                      height: height, keyCorner: m.keyCorner,
                      appearance: a, onTap: onReturn)
                .frame(width: width)

        case .toLetters:
            FuncKey(label: spec.label,
                    fontSize: m.funcFontSize, height: height,
                    keyCorner: m.keyCorner, appearance: a, onTap: onSwitchToLetters)
                .frame(width: width)

        case .switchPage(let index):
            FuncKey(label: spec.label,
                    fontSize: m.funcFontSize, height: height,
                    keyCorner: m.keyCorner, appearance: a,
                    onTap: { pageIndex = index })
                .frame(width: width)

        case .pageIndicator:
            pageDots(count: screenCount, appearance: a)
                .frame(width: width, height: height)
        }
    }

    /// 字面键（数字 / 符号）：键面与上屏都取「当前中/英模式对应的字形」。
    /// 成对符号键不用 Button（子 Button 会吞掉网格区统一手势的长按/滑动），
    /// 点按/长按/滑动全由 gridGesture 判定；按压反馈与 PressStyle 同源
    @ViewBuilder
    private func literalKey(_ spec: KeypadKeySpec, width: CGFloat, height: CGFloat,
                            inFunctionRow: Bool,
                            metrics m: KeyboardMetrics,
                            appearance a: KeyboardAppearanceSettings) -> some View {
        let glyph = spec.glyph(isEnglish: isEnglishActive)
        if spec.hasWidthChoice {
            if inFunctionRow {
                // 功能行没有网格统一手势：成对符号在这里退化为普通点按键（仍跟随中/英模式取形）
                Button {
                    guard !isCursorMode else { return }
                    onInsert(glyph)
                } label: {
                    Text(glyph)
                        .font(.system(size: KeyboardKeyStyle.secondaryTextFontSize(
                            letterFontSize: m.letterFontSize)))
                        .foregroundColor(KeyboardTheme.keyText(a))
                        .frame(width: width, height: height)
                        .background(KeyboardTheme.keyFill(a))
                        .cornerRadius(m.keyCorner)
                        .keyCapDepth()
                }
                .buttonStyle(PressStyle())
            } else {
                let pressed = touchKeySpec?.id == spec.id && pendingSymbol == nil
                Text(glyph)
                    .font(.system(size: KeyboardKeyStyle.secondaryTextFontSize(
                        letterFontSize: m.letterFontSize)))
                    .foregroundColor(KeyboardTheme.keyText(a))
                    .frame(width: width, height: height)
                    // 符号键不给灰色功能键底色，与数字键同用普通键底色
                    .background(KeyboardTheme.keyFill(a))
                    .cornerRadius(m.keyCorner)
                    .keyCapDepth()
                    .scaleEffect(pressed ? KeyboardKeyStyle.pressScale : 1.0)
                    .brightness(pressed ? KeyboardKeyStyle.pressBrightness : 0)
                    .animation(.easeInOut(duration: KeyboardKeyStyle.pressAnimationDuration),
                               value: pressed)
            }
        } else {
            Button {
                // 光标模式激活后，整个键盘区域不再上屏
                guard !isCursorMode else { return }
                onInsert(glyph)
            } label: {
                Text(glyph)
                    .font(.system(size: spec.isDigit
                                  ? m.letterFontSize
                                  : KeyboardKeyStyle.secondaryTextFontSize(
                                        letterFontSize: m.letterFontSize)))
                    .foregroundColor(KeyboardTheme.keyText(a))
                    .frame(width: width)
                    .frame(height: height)
                    // 统一普通键底色（符号键不再用灰色功能键底色）
                    .background(KeyboardTheme.keyFill(a))
                    .cornerRadius(m.keyCorner)
                    .keyCapDepth()
            }
            .buttonStyle(PressStyle())
        }
    }

    /// 翻屏圆点：当前屏主色调实心，其余淡显；非交互，仅指示位置
    @ViewBuilder
    private func pageDots(count: Int, appearance a: KeyboardAppearanceSettings) -> some View {
        HStack(spacing: NumericKeypadStyle.pageDotSpacing) {
            ForEach(0..<Swift.max(count, 0), id: \.self) { i in
                Circle()
                    .fill(i == currentScreen
                          ? KeyboardTheme.primaryColor(a)
                          : KeyboardTheme.keyText(a).opacity(NumericKeypadStyle.pageDotDimOpacity))
                    .frame(width: NumericKeypadStyle.pageDotSize,
                           height: NumericKeypadStyle.pageDotSize)
            }
        }
    }

    // MARK: - 半角/全角滑动选择气泡

    /// 长按不松手时浮在被按键上方的气泡：跟手滑动高亮半角/全角，松手直接上屏高亮项。
    /// 挂在 body 最外层 overlay（不在翻屏的 clipped 容器里），任何一行键的气泡都不会被裁。
    @ViewBuilder
    private var widthPopupLayer: some View {
        if let spec = pendingSymbol, let full = spec.fullWidth {
            GeometryReader { geo in
                let m = metrics
                let rowH = rowHeight(total: geo.size.height,
                                     rowCount: NumericKeypadLayout.screenRowCount + 1,
                                     metrics: m)
                let colW = columnWidth(total: geo.size.width - m.hPad * 2, spacing: m.keySpacing)
                let cellW = colW * NumericKeypadStyle.widthPopupCellWidthRatio
                let bubbleW = cellW * 2
                let bubbleH = rowH * NumericKeypadStyle.widthPopupHeightRatio
                // 水平夹在键盘内（边缘列的气泡不越界），垂直贴在被按键的正上方
                let x = Swift.min(Swift.max(popupAnchor.x, bubbleW / 2 + m.hPad),
                                  geo.size.width - bubbleW / 2 - m.hPad)
                let y = Swift.max(popupAnchor.y - rowH / 2
                                  - NumericKeypadStyle.widthPopupGap - bubbleH / 2,
                                  bubbleH / 2)
                widthPopup(half: spec.label, full: full, cellW: cellW, bubbleH: bubbleH,
                           metrics: m, appearance: appearanceSettings)
                    .position(x: x, y: y)
            }
            .allowsHitTesting(false)
        }
    }

    /// 气泡本体：左半角 / 右全角两格，每格符号下带「半角/全角」标注防混淆，
    /// 高亮格主色调底 + 白字
    private func widthPopup(half: String, full: String, cellW: CGFloat, bubbleH: CGFloat,
                            metrics m: KeyboardMetrics,
                            appearance a: KeyboardAppearanceSettings) -> some View {
        HStack(spacing: 0) {
            widthPopupCell(text: half, label: "半角", selected: widthSelection == 0,
                           cellW: cellW, bubbleH: bubbleH, metrics: m, appearance: a)
            widthPopupCell(text: full, label: "全角", selected: widthSelection == 1,
                           cellW: cellW, bubbleH: bubbleH, metrics: m, appearance: a)
        }
        .background(KeyboardTheme.funcKeyFill(a))
        .cornerRadius(m.keyCorner)
    }

    private func widthPopupCell(text: String, label: String, selected: Bool,
                                cellW: CGFloat, bubbleH: CGFloat,
                                metrics m: KeyboardMetrics,
                                appearance a: KeyboardAppearanceSettings) -> some View {
        VStack(spacing: NumericKeypadStyle.widthPopupGlyphLabelSpacing) {
            Text(text)
                .font(.system(size: m.letterFontSize, weight: selected ? .semibold : .regular))
                .foregroundColor(selected ? .white : KeyboardTheme.keyText(a))
            Text(label)
                .font(.system(size: bubbleH * NumericKeypadStyle.widthPopupLabelTextRatio))
                .foregroundColor(selected
                                 ? .white.opacity(NumericKeypadStyle.widthPopupLabelSelectedOpacity)
                                 : KeyboardTheme.keyText(a)
                                     .opacity(KeyboardKeyStyle.secondaryTextOpacity))
        }
        .frame(width: cellW, height: bubbleH)
        .background(selected ? KeyboardTheme.primaryColor(a) : Color.clear)
        .cornerRadius(m.keyCorner)
    }

    /// 跟手滑动切换高亮：越过阈值取对应格，回到死区恢复「点按会上的那个」（跟随中/英模式）；
    /// 切换时轻震一下，盲滑也能数清停在哪格
    private func updateWidthSelection(translation: CGFloat, keyWidth: CGFloat) {
        let threshold = keyWidth * NumericKeypadStyle.widthSlideThresholdRatio
        let target: Int
        if translation > threshold {
            target = 1
        } else if translation < -threshold {
            target = 0
        } else {
            target = defaultWidthIndex
        }
        guard target != widthSelection else { return }
        widthSelection = target
        Haptics.step()
    }

    /// 点按会上屏的那一格：英文半角(0) / 中文全角(1)，气泡初始高亮与键面字形一致
    private var defaultWidthIndex: Int { isEnglishActive ? 0 : 1 }

    // MARK: - 工具

    /// 统一的列宽：(可用宽度 - 列间距) / 列数，保证所有行、所有键尺寸完全一致
    private func columnWidth(total: CGFloat, spacing: CGFloat) -> CGFloat {
        let columns = CGFloat(NumericKeypadLayout.columnCount)
        return Swift.max((total - spacing * (columns - 1)) / columns, 0)
    }

    /// 统一的列高：可用高度扣掉上下留白与行间距后均分给每一行
    private func rowHeight(total: CGFloat, rowCount: Int, metrics m: KeyboardMetrics) -> CGFloat {
        let rows = CGFloat(Swift.max(rowCount, 1))
        let usable = total - m.topBotPad * 2 - m.rowSpacing * (rows - 1)
        return Swift.max(usable / rows, 0)
    }
}

// MARK: - 翻屏拖拽的实时状态

/// 符号页翻屏的跟手位移。单独做成观察对象而不是一个 `@State var dragTranslation`：
/// 副键盘的 body 里有 GeometryReader + 三行网格 + 功能行共几十个视图，
/// 而原先每次 move 都要往 @State 写一次位移，等于把整棵键面树重建一遍 ——
/// 拖拽就在和重建抢主线程时间，这就是「左右滑动不顺畅」的成因。
/// 现在 body 不读它，只有挂 offset 的那一层观察，每帧重算的只有那一个 offset。
final class PageDragTracker: ObservableObject {

    /// 参与渲染的跟手位移（已过首/末屏阻尼）
    @Published var translation: CGFloat = 0

    /// 未经阻尼的原始横向位移。长按计时用它判「这次触摸是不是翻屏」，
    /// 而那个读取不该把整个副键盘拖下水，所以故意不加 @Published
    private(set) var rawDx: CGFloat = 0

    /// 一次触摸开始
    func begin() {
        rawDx = 0
        translation = 0
    }

    /// 记录本次触摸的原始位移（不触发重绘）
    func record(dx: CGFloat) { rawDx = dx }

    /// 跟手：只在值真变了时发布，省掉「位移回到同一点」这类空重算
    func follow(dx: CGFloat) {
        guard translation != dx else { return }
        translation = dx
    }

    /// 一次触摸结束
    func end() { rawDx = 0 }

    /// 吸附到目标屏：跟手位移归零（由调用方的 withAnimation 带动画）
    func settle() {
        guard translation != 0 else { return }
        translation = 0
    }
}

/// 翻屏 offset：整个副键盘里唯一观察 `PageDragTracker` 的一层
struct PagedDragOffset: ViewModifier {
    let currentScreen: Int
    let pageWidth: CGFloat
    @ObservedObject var drag: PageDragTracker

    func body(content: Content) -> some View {
        content.offset(x: -CGFloat(currentScreen) * pageWidth + drag.translation)
    }
}
