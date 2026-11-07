# OpenIME 项目结构

> 本文件记录仓库的**真实目录结构、Target 划分与模块职责**，供开发者与协作智能体快速接手。
> 修改工程结构（加文件 / 加 Target / 改资源）后请同步更新本文件。
> App 在手机上的显示名是「**聿·输入法**」（三个 plist 的 `CFBundleDisplayName`）；本文的路径 / Target / Bundle ID / 词库格式一律用项目名 **OpenIME**，只在描述用户在系统界面里看到什么时用聿·输入法。

## Target 架构总览

项目用 **XcodeGen**（`project.yml`）管理，共 6 个 Target：

| Target | 类型 | Bundle ID | 源码目录 | 说明 |
|---|---|---|---|---|
| `OpenIME` | application | `com.openime.app` | `OpenIME/UI` + `Packages/BundledSchemes` | 主 App（设置界面、方案管理），嵌入下面两个扩展 |
| `OpenIMECore` | framework | `com.openime.core` | `OpenIME/Sources` + `Shared` | **共享核心库**：引擎 + 数据模型 + 全部共享逻辑都编译进这里 |
| `OpenIMEKeyboard` | app-extension | `com.openime.app.keyboard` | `OpenIMEKeyboard/Sources` | 键盘扩展（两种键盘形态 + 候选栏 + 快捷/剪贴板面板） |
| `OpenIMEShare` | app-extension | `com.openime.app.share` | `OpenIMEShare/Sources` | 分享扩展「存到 聿·输入法」（把分享内容写入剪贴板历史） |
| `OpenIMETests` | bundle.unit-test | `com.openime.tests` | `OpenIMETests` | 单元测试（依赖 `OpenIMECore`） |
| `OpenIMEUITests` | bundle.ui-testing | `com.openime.uitests` | `OpenIMEUITests` | UI 测试（依赖 `OpenIME`） |

**关键约定**：`OpenIME/Sources`（引擎）与 `Shared`（共享代码）虽然分处两个目录，但都编译进 **同一个 `OpenIMECore` framework**。主 App / 键盘扩展 / 分享扩展 / 单元测试都 `import OpenIMECore` 复用同一份逻辑，不存在「各 Target 各编一份 Shared」。给 `Shared` 或 `OpenIME/Sources` 加文件后无需改 `project.yml`（目录 glob 自动纳入），但仍需跑一次 `xcodegen generate`。

App Group：`group.com.openime.shared`（主 App / 键盘扩展 / 分享扩展三者共享，用于设置、词库、剪贴板历史等跨进程数据）。

## 目录树

```
OpenIME/
│
├── project.yml                            # XcodeGen 工程配置（改结构后运行 xcodegen generate）
├── README.md / PROJECT_STRUCTURE.md / LICENSE
│
├── OpenIME/                               # 主 App Target（仅 UI；核心逻辑在 OpenIMECore）
│   ├── Info.plist / OpenIME.entitlements
│   ├── Assets.xcassets/                   # App 图标
│   ├── Sources/                           # ┐ 编译进 OpenIMECore framework
│   │   ├── Runtime/IMERuntime.swift       # │ Runtime 核心：统一入口，协调所有模块、输入模式路由、
│   │   │                                  # │   满码连打（满码即上只看唯一精确命中+顶字兜底）、i+拼音反查、剩余整码
│   │   │                                  # │   方案重载两道关口：reloadedSchemeList「此刻读不到≠已卸载」保留旧记录 + purgedActiveSchemeId 确证卸载才回落（防用户方案被顶成默认拼音）
│   │   ├── PackageManager/PackageInstaller.swift  # │ ZIP 安装/卸载、YAML 解析、编译调用、单文件导入
│   │   │                                  # │   安装不往源目录写一个字：内置方案直接编 App Bundle 里的 .bundle，而真机包体只读
│   │   │                                  # │   （编译产物进临时 scratch）；新包先在 .<id>-staging-* 里搭好、全部写成功才换掉旧包
│   │   ├── PackageManager/SchemaParser.swift      # │ 外部 *.schema.yaml 嵌套读取（只取需要的键，读不懂忽略而不报错）
│   │   ├── PackageManager/CodeSystemInference.swift # │ 码制推断（音码/形码/音形码 + 要不要去空格）+ 生成 schema.yaml
│   │   ├── DictionaryEngine/DictHeader.swift      # │ 外部词库头部解析（front matter 三形态 / columns / import_tables / encoder）
│   │   ├── DictionaryEngine/DictCompiler.swift    # │ YAML → .bin 编译器（外部词库四变体 / OpenIME 单文件；零词频码表编译期叠加通用字 / 词频，三档尺度：单字 > 命中语料词组 > 兜底词组）
│   │   ├── DictionaryEngine/WordFrequencyCorpus.swift # │ 通用词频语料流式读取器：编译期从随包雾凇 base.dict.yaml（55 万词）里只捞当前方案出现的多字词真实词频；FileHandle 分块扫描不常驻内存，按 columns 列名映射，异常降级空字典
│   │   ├── DictionaryEngine/DictReader.swift      # │ .bin mmap 查询引擎（偏移表二分定位前缀命中区间 + 区间顺序扫，freq 小顶堆只留前 limit 条；大区间走 dict.ptn.bin 侧车取预排偏移，单字符前缀结果另缓存）
│   │   │                                          # │   shortestCodes：文字→最短编码，按字记忆（连「查不到」也记空串），只给「i+拼音」反查补编码用；queryTable：码表补全，同词频时码短者优先
│   │   ├── DictionaryEngine/CharBigram.swift      # │ 字级二元语法只读侧车（dict.lm.bin，mmap 就地二分）：给长串词图判「相邻字搭配」，
│   │   │                                          # │   文件缺失/损坏即退老行为；配套 CharBigramBuilder 在编译期从多字词导出侧车
│   │   ├── DictionaryEngine/ExtrasIndex.swift     # │ 反查/码元提示/简码可选侧车（dict.extras.bin）只读访问，定长记录直接二分；
│   │   │                                          # │   配套 ExtrasIndexBuilder 编译期写盘，无 extras 则删侧车、老词库走老路
│   │   ├── CandidateEngine/CandidateEngine.swift  # │ 单方案查询 + 音节切分 + 用户自定义词融合
│   │   ├── CandidateEngine/QueryStrategy.swift    # │ 按方案画像分派的四套检索策略（前缀直查/音节/双拼/音形码；码表走 tableCandidates 整码精确优先+补全码短优先）
│   │   ├── CandidateEngine/CandidateScoring.swift # │ 候选打分与去重纯函数（uniquifier / 单字优先）
│   │   └── MixInputEngine/MixInputEngine.swift    # ┘ 多方案并行查询 + 候选融合去重
│   └── UI/
│       ├── App/OpenIMEApp.swift           # App 入口 + TabView（方案/键盘/混合/词典/关于）+ 前台抓剪贴板
│       └── Settings/
│           ├── SchemeManagerView.swift    # 方案管理页（导入/激活/删除/详情；自适应列表：≤5 扁平持持久化稳定序、>5 按码制分组；行内码制/版本/作者副标题 + 使用中绿胶囊）
│           ├── KeyboardSettingsView.swift # 键盘外观页（主题/尺寸/样式/背景/布局）+ KeyboardPreviewView
│           │                              # 预览按当前键盘形态（KeyboardModeStore 同源）画两形态，
│           │                              # 几何/键面配色与真键盘同源（Shared/KeyboardMetrics+KeyboardStyle）
│           ├── CandidateBarShortcutSettingsView.swift  # 候选栏快捷功能配置子页（拖动排序/增删）
│           ├── MixInputSettingsView.swift # 混合输入设置页（方案排序/颜色/顶字/清除预测）
│           ├── UserWordsView.swift        # 词典页（自定义词条 + 剪贴板历史入口）
│           ├── ClipboardHistoryView.swift # 剪贴板历史页（开关/条数上限/清空/列表）
│           └── AboutView.swift            # 关于页（使用教程/功能列表/参数说明/方案包制作）
│
├── Shared/                                # ┐ 全部编译进 OpenIMECore framework
│   ├── AppGroup/AppGroupContainer.swift   # │ App Group 共享容器（设置/自定义词/方案顺序/方案路径 + 已装清单跳过安装暂存目录 + 跨进程「设置已变更」广播名单一源）
│   ├── Models/SchemePackage.swift         # │ 方案包数据模型（SchemeManifest/InstalledScheme/Candidate…）
│   ├── Models/SchemeExtras.swift          # │ 可选附加表（反查/码元提示/简码）值类型，老包不写即 nil
│   ├── Models/CharFrequency.swift         # │ 通用汉字字频表（自动生成、勿手改）：《通用规范汉字表》8105 字按
│   │                                      # │   25 亿字语料字频降序；编译期给零词频码表叠加真实「单字」字频的数据源
│   │                                      # │   （多字词词频另由 WordFrequencyCorpus 流式读雾凇 base.dict.yaml 提供，二者天然分工）
│   ├── Models/UserSettings.swift          # │ 用户设置模型（混打/顶字/外观/布局/标点/预测）
│   ├── Models/KeyboardStyle.swift         # │ 键面通用样式单一源：KeyboardKeyStyle/
│   │   │                                  # │   LayeredKeycapStyle/CandidateBarStyle/
│   │   │                                  # │   KeyboardTheme/KeyboardLetterRows/Color hex 解析，
│   │   │                                  # │   键盘扩展与设置页预览共用同一份，禁止各写一套
│   ├── Models/KeyboardMetrics.swift       # │ 键盘几何单一源（26 键/双拼全尺寸推导，两种形态同构、不再随形态分支），
│   │   │                                  # │   键盘扩展与设置页预览共用同一份
│   ├── SchemeProfile.swift                # │ 方案画像：把「该怎么输入」一次算成只读值（码制/alphabet/分隔符/顶字清屏），
│   │                                      # │   字段缺失时按 SchemeType 回落，旧包安全
│   ├── SchemeCapability.swift             # │ 方案能力模型：编码空间求交集推导键盘形态可用性 + 混打合法方向
│   │                                      # │   （形码主 + 全拼参与），纯函数无 IO，UI 显隐与运行时门控共问这一份
│   ├── Prediction/PredictionEngine.swift  # │ 词语搭配预测引擎（串行队列线程安全，最多 1 万词对）
│   ├── Frequency/FrequencyAdjustEngine.swift # │ 拼音动态调频引擎：主线程活表 O(1) 读 + 后台串行队列值类型快照落盘；
│   │                                      # │   有界抬升/竞争衰减可回退/容错解码；容量上限从进程内存预算单调棘轮派生
│   │                                      # │   （无限制环境回退物理内存）；清除走广播+App Group 标记双层跨进程防复活；仅音码生效
│   ├── Keyboard/KeyboardGridGeometry.swift# │ 26 键/双拼正方形按键几何（键盘扩展与设置页预览共用同一份推导；行距由用户比例直接给出）
│   ├── InputModes/                        # │ 输入形态与编码展开（纯数据，无 SwiftUI 依赖，可单测）
│   │   ├── KeyboardMode.swift             # │   KeyboardMode(全拼26/双拼) + KeyboardModeStore
│   │   │                                  # │   （历史存档里的 "t9" 自动回落 26 键并写回磁盘）
│   │   │                                  # │   + EnglishModeStore
│   │   ├── InputCodeExpander.swift        # │   输入码展开统一入口（26 键恒等 / 双拼；双拼类方案配双拼键盘也是恒等直通）
│   │   ├── HeErDoublePinyin.swift         # │   小鹤双拼声韵母映射 + 双拼 → 全拼展开（键帽多韵母显示序对齐小鹤官方键位图 officialFinalOrder）
│   │   ├── PinyinSyllables.swift          # │   拼音音节表
│   │   ├── CodeLattice.swift              # │   长串词图切分：音码按音节连写 / 形码按码长滑窗 / 音形码交替，束搜索选整句
│   │   │                                  # │   （纯计算，词表与二元语法由调用方注入）
│   │   └── NumericKeypadLayout.swift      # │   副键盘两页布局数据（数字/符号；中文标点并入符号页，符号页可横向翻屏，半/全角合并同键位）
│   │                                      # │   半角→全角对照表 fullWidthVariant 是全站唯一源（副键盘符号页也从这里取形）
│   ├── Clipboard/                         # │ 剪贴板历史（跨主 App/键盘/分享扩展三进程）
│   │   ├── ClipboardItem.swift            # │   条目模型（文本/URL/路径/图片）+ FNV-1a 去重签名
│   │   ├── ClipboardHistoryStore.swift    # │   历史读写（「读盘-改-写盘」保证跨进程一致，非内存缓存）
│   │   ├── ClipboardSettingsStore.swift   # │   开关/条数上限(0…1000)/抓取内部状态（App Group UserDefaults）
│   │   └── ClipboardCapture.swift         # │   抓取入口 + NSItemProvider → ClipboardItem 纯函数
│   ├── Shortcuts/                         # │ 候选栏空态快捷功能条
│   │   ├── CandidateBarShortcut.swift     # │   功能目录（10 项枚举）+ resolve 纯函数；收录项都状态可着色（reflectsState：开关型 + 剪贴板颜色跟记录开关）
│   │   └── CandidateBarShortcutStore.swift# │   有序 id 持久化（App Group UserDefaults）
│   └── Styles/                            # │ 跨主 App / 键盘扩展复用的语义样式（编译进 OpenIMECore）
│       ├── ClearActionStyle.swift         # │   清除类按钮统一浅红底 + 红字，约定不允许 disabled（避免假按钮观感）
│       └── ToastStyle.swift               # ┘   执行结果 toast 统一样式（只对「看不出是否生效」的动作补提示）
│
├── OpenIMEKeyboard/                       # 键盘扩展 Target
│   ├── Info.plist / OpenIMEKeyboard.entitlements
│   ├── Sources/
│   │   ├── Keyboard/
│   │   │   ├── KeyboardViewController.swift   # UIInputViewController 入口（Darwin 通知跨进程同步 + 高度约束）
│   │   │   ├── IMEKeyboardView.swift          # SwiftUI 键盘根视图（形态路由/状态协调）+ 末尾 QuickPanelView 快捷面板
│   │   │   ├── KeyboardRowsView.swift         # 全拼 26 键行布局（退格加速/光标滑动手势）
│   │   │   ├── HeErKeyboardView.swift         # 小鹤双拼 26 键键盘
│   │   │   ├── NumberKeyboardView.swift       # 数字/符号副键盘（纯数据驱动；符号页自绘横向翻屏 + 长按滑动选半/全角气泡）
│   │   │   ├── CursorSpaceKey.swift           # 空格/字母键长按光标模式手势
│   │   │   └── KeyboardKeyStyle.swift         # 键盘扩展专用常量（副键盘翻屏/长按阈值、Shift 大写锁定、
│   │   │                                      # 光标模式、快捷/剪贴板面板比例）；
│   │   │                                      # 键面通用样式已下沉 Shared/Models/KeyboardStyle.swift
│   │   ├── Candidate/
│   │   │   ├── CandidateBarView.swift         # 候选栏（横向滚动/注释行/两端槽位/空态快捷功能条）
│   │   │   └── CandidateExpandedPanel.swift   # 候选词全屏展开面板
│   │   ├── Clipboard/ClipboardHistoryPanel.swift  # 键盘内剪贴板历史面板
│   │   └── FontLoader.swift                   # 候选字体注册与选字（文津宋体三平面，按码位平面选字 + 跨平面无缝拼接 + 合成伪粗）
│   └── Resources/                             # 候选正文渲染字体（键盘扩展打包）
│       ├── WenJinMinchoP0-Regular.otf         # 第一平面：常用字 / 偏旁部首 / 笔画 / 拼音注音 / ASCII / 标点（约 17.5 MB，覆盖 99.98% 候选，首帧同步注册）
│       ├── WenJinMinchoP2-Regular.otf         # 第二平面：扩展 B~F / 扩展 I / 兼容增补等生僻字（约 21 MB，后台异步注册）
│       └── WenJinMinchoP3-Regular.otf         # 第三平面：扩展 G / H / J（约 4.4 MB，后台异步注册）
│
├── OpenIMEShare/                          # 分享扩展 Target
│   ├── Info.plist / OpenIMEShare.entitlements
│   └── Sources/ShareViewController.swift  # 系统分享菜单 → 存入剪贴板历史（completeRequest 前 flush 落盘）
│
├── OpenIMETests/                          # 单元测试 Target（@testable import OpenIMECore）
│   ├── DictCompilerTests.swift            # 编译器：外部格式/列顺序/跳过/边界/v2 头部与老文件附加区兼容 + 通用字/词频叠加（零词频检测、门控只看权重无区分度不看码制、三档尺度单字>covered>uncovered、无语料时回退几何均值逐字节一致）+ 反查最短编码（同字多码取最短、记忆幂等、清缓存后一致、记忆撑满上限时清空重建）
│   ├── WordFrequencyCorpusTests.swift     # 通用词频语料流式读取：只返回 needed 命中的多字词、同词取最大、按 columns 列名映射、空 needed/缺文件安全返回空字典
│   ├── DictHeaderTests.swift              # 词库头部：columns 乱序/未知列/stem 注释/CRLF/import_tables 递归与展开
│   ├── EncoderDerivationTests.swift       # encoder 派生码：length_equal / length_in_range / 三种 formula / exclude_patterns
│   ├── DuplicateEntryTests.swift          # 重复词条：同词同码首现胜出，同词不同码全保留
│   ├── SchemeProfileTests.swift           # 方案画像与码制推断：雾凇⇒音码、虎码⇒形码、旧包回落、抽样额度平分
│   ├── SchemeCapabilityTests.swift        # 能力矩阵：type×codeSystem 全组合的形态可用性/混打方向/链感知/非法配置过滤 + 运行时形态回落钳制（形码×双拼回落 26 键）
│   ├── SpellerExpansionTests.swift        # 拼写展开：alphabet 过滤/分隔符分段/简拼第二路/恒等直通/profile=nil 行为不变
│   ├── QueryStrategyTests.swift           # 四套检索策略分派 + uniquifier 去重 + 双拼长串切分 + 码表同词频截词回归（简码不被长码按字母序挤出）+ 零词频码表叠加真实词频后同前缀常用词组排在生僻词组之前（端到端）
│   ├── CodeLatticeTests.swift             # 长串词图切分：词表/二元语法手搓注入不依赖真词库，复现「纯一元把 nihaoma 判成你好那」并证明加二元语法后判对；形码按码长滑窗切回整句
│   ├── AutoCommitPolicyTests.swift        # 顶字上屏：用户设置的 autoSelectLength 优先覆盖画像默认 + 满码即上要求精确命中唯一（重码留码、补全长码不计入重码）+ 混打/反查串×满码即上豁免的组合自洽；方案重载关口：瞬时读不到保留旧记录、确证卸载才回落、没判定依据时绝不改用户激活选择
│   ├── DictReaderEquivalenceTests.swift   # 索引查询与朴素全表扫描的候选/词频等价性回归（含单字母简码、整码不被高频补全挡掉）+ 码表路径字节级快筛与朴素参照同序同调（小 limit 等于全量结果截断前 k 条）
│   ├── CharBigramTests.swift              # 字级二元语法侧车：缺文件即空表、只有单字词时删侧车、常见搭配分数高于未见搭配、重复构建字节一致（幂等）
│   ├── ExtrasIndexTests.swift             # 反查/码元提示/简码侧车：缺文件即空表、空 extras 删侧车、往返读写、定长记录二分、简码条数上限与顺序、重建幂等
│   ├── PackageInstallerTests.swift        # 安装目录写入边界：源目录只读（= 真机的 App Bundle）也必须装成功、源目录不留任何编译产物、覆盖安装中途失败旧包原样可用、泄漏的暂存目录不被当成已装方案；另拿真实内置包（只读副本）跑一遍首装路径
│   ├── YAMLParserTests.swift              # YAML 解析 + 单文件导入（含外部格式）
│   ├── CandidateEngineTests.swift         # 候选引擎 + 混打引擎
│   ├── PredictionEngineTests.swift        # 预测引擎：position/持久化/线程安全/上限裁剪
│   ├── FrequencyAdjustEngineTests.swift   # 动态调频引擎：抬升饱和/竞争衰减回退/裁剪偏好/值类型快照线程安全/容错解码/容量派生纯函数/跨进程清除双层防护
│   ├── ShowAnnotationRowTests.swift       # 注释行显示逻辑：全局开关/单方案/混打（只算生效中的参与方案）
│   ├── UserSettingsTests.swift            # 用户设置：默认值/JSON 序列化/边界
│   ├── HeErDoublePinyinTests.swift        # 小鹤双拼声韵母展开
│   ├── NumericKeypadLayoutTests.swift     # 副键盘两页布局（数字/符号；半/全角合并、glyph 随模式、翻屏结构）
│   ├── KeyboardGridGeometryTests.swift    # 键盘高度可调几何：默认 1.0 严格正方形与历史逐字节一致、键宽不变、屏高护栏不溢出、功能键字号跟键宽，另涵盖总高随高度系数变化与横屏夹取
│   ├── IMERuntimeModeTests.swift          # Runtime 形态路由/输入模式切换/能力门控（形态回落、非法混打不进链）+ 音形码「i+拼音」反查闭环（出字且带出主方案编码）
│   ├── ClipboardHistoryStoreTests.swift   # 剪贴板存储/抓取纯函数/上限裁剪（3 个测试类）
│   └── CandidateBarShortcutTests.swift    # 快捷功能目录/resolve 映射 + 开关与着色分类（能进候选栏的必须状态可着色）
│
├── OpenIMEUITests/OpenIMEUITests.swift    # UI 测试：五 Tab Smoke + 键盘外观布局 + 方案能力收敛 + 类 Playwright 真实用户模拟（打字选词闭环/开关与二次确认/外观交互/词典增删查/Safari 真键盘逐键打字端到端/候选格点选槽位顺序）
│
├── Packages/BundledSchemes/
│   ├── oime-ice-pinyin.bundle/            # 预装拼音词库（基于雾凇拼音整理，约 16.7 MB）
│   │   ├── manifest.yaml / schema.yaml
│   │   └── dictionaries/                  # base / 8105 / others 词库文件
│   ├── oime-tiger.bundle/                 # 预装虎码形码（单字全码 + 词组 + 简词，25 万条）
│   └── oime-cqkm.bundle/                  # 预装超强快码音形码（cqkm_cm 全码表，12 万条）
│
├── scripts/                               # 开发辅助脚本
│   ├── setup.sh                           # 开发环境一键初始化（会调用 generate_project.sh）
│   ├── generate_project.sh                # 装 xcodegen + 读根 project.yml 生成工程（不内嵌配置副本）
│   ├── prepare_bundled_shape_schemes.py   # 从上游原生方案归一生成 oime-tiger / oime-cqkm 内置包（头注记录三处归一理由）
│   ├── generate_charfreq.sh               # 从内置 8105.dict.yaml 提取字频生成 Shared/Models/CharFrequency.swift（零词频码表叠加用）
│   ├── fetch_ice_dict.sh                  # 下载雾凇拼音词库
│   └── run_simulator.sh                   # 构建并安装到模拟器
│
└── .github/workflows/build.yml            # CI：推送/tag 时自动编译并生成 IPA
```

## App 体积说明

| 内容 | 大小 | 说明 |
|---|---|---|
| 雾凇拼音词库 `oime-ice-pinyin` | 约 16.7 MB | 内置拼音词库（`base.dict.yaml` 55 万词），首次启动自动编译为 `.bin` 索引 |
| 虎码 / 超强快码词库 `oime-tiger` / `oime-cqkm` | 约 3.8 MB + 1.9 MB | 内置形码与音形码方案（上游原生词库归一收录），首次启动同样自动编译 |
| 候选渲染字体（文津宋体三平面） | 约 43 MB | 键盘扩展打包的 P0/P2/P3 三份官方 OTF（约 17.5 + 21 + 4.4 MB），逐码位核验覆盖候选所需的汉字、偏旁部首与拼音注音，全字集观感一致 |
| 其他代码与资源 | 约 2–3 MB | App 逻辑、UI、图标、分享扩展 |
| **未压缩资源合计** | **约 68 MB** | 字体约 43 MB + 词库约 22 MB + 代码约 3 MB；App Store 下载经压缩与瘦身后更小 |

> 体积绝大部分是「字体 + 词库」数据，代码只占很小一部分。App 内「关于 → 内置方案 / 存储空间与体积」运行时实测各 `*.bundle` 目录大小、读 `manifest.yaml` 的 name / description 展示（`AboutView.swift` 的 `BundledSchemeCatalog`），不写死方案名单与体积；字体在键盘扩展 bundle 内、主 App 测不到，以固定文案给出。

## Xcode 工程配置要点

> 项目使用 **XcodeGen** 管理工程文件。修改工程结构（加文件、加资源、改 Target）时，
> 编辑根目录 `project.yml`，然后运行 `xcodegen generate` 重新生成 `.xcodeproj`。
> **不要直接修改 `project.pbxproj`**，它每次都由 xcodegen 覆盖生成。

### 工程再生成

```bash
# 用仓库根目录的 project.yml 生成（等价于 bash scripts/generate_project.sh）
xcodegen generate --spec project.yml --project .
```

> 工程配置只有根目录 `project.yml` 一份真相；`OpenIME.xcodeproj` 是生成物，已被 `.gitignore` 排除，
> 克隆仓库后必须先跑一次上面的命令才能用 Xcode 打开。
> `scripts/generate_project.sh` 只负责装 xcodegen 并读取根 `project.yml` 生成工程。

### 关键标识

1. 主 App Bundle ID：`com.openime.app`
2. 核心库 Bundle ID：`com.openime.core`（framework，聚合 `OpenIME/Sources` + `Shared`）
3. 键盘扩展 Bundle ID：`com.openime.app.keyboard`
4. 分享扩展 Bundle ID：`com.openime.app.share`
5. App Group ID：`group.com.openime.shared`（主 App / 键盘 / 分享扩展三个 Target 都要加 Capability）
6. 键盘扩展 Info.plist：`NSExtensionAttributes` → `RequestsOpenAccess = YES`（需完全访问权限）
7. 分享扩展 Info.plist：`NSExtensionPointIdentifier = com.apple.share-services`，`NSExtensionPrincipalClass = $(PRODUCT_MODULE_NAME).ShareViewController`
8. Swift Package 依赖：ZIPFoundation（在 `project.yml` 的 `packages:` 声明，`https://github.com/weichsel/ZIPFoundation.git`，`from: 0.9.19`）；
   工程不再有根 `Package.swift`（那份 manifest 的 target 路径只含 `OpenIME/Sources`、不含 `Shared`，`swift build` 已不可能成功，且与构建无关），依赖统一走 XcodeGen + `xcodebuild -resolvePackageDependencies`，
   解析结果锁在 `OpenIME.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`（构建/上传只认这一条路径）

### 构建与测试

```bash
# 构建（模拟器）
xcodebuild -project OpenIME.xcodeproj -scheme OpenIME \
  -destination 'platform=iOS Simulator,name=iPhone 17' build

# 全量测试（单元 + UI）
xcodebuild -project OpenIME.xcodeproj -scheme OpenIME \
  -destination 'platform=iOS Simulator,name=iPhone 17' test

# 只跑某个 UI 测试
xcodebuild ... test -only-testing:OpenIMEUITests/OpenIMEUITests/testKeyboardLayoutSettings
```

> 当前基线：BUILD SUCCEEDED，全部单元测试与 UI 测试通过（含多个类 Playwright 真实用户模拟用例）。
> Safari 真键盘逐键打字端到端用例在全套件里可能因键盘 / 宿主状态按设计 XCTSkip，单独跑则完整通过。
> 新增源文件后先 `xcodegen generate` 再构建，否则新文件不进 Target，会报「No such module / 找不到符号」。
