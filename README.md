# OpenIME · 聿·输入法

免费开源的 iOS 自定义输入方案平台，支持导入自定义词库，拼音、形码、音形码均可使用。

> App 在手机上的显示名是 **聿·输入法**，OpenIME 是项目名（仓库、工程、Target、词库格式）。本文档里：**聿·输入法** 指你在系统设置、文件 App、分享菜单里看到的名字，**OpenIME** 指代码与格式层面的项目。系统粘贴授权提示（「聿·输入法」想从「某 App」粘贴）取的也是显示名。

**本地离线运行** — 输入内容、词库数据、用户设置都只保存在本机，不访问网络，也不收集、上传或分享用户信息。源代码开放，可自行审查。

## 安装

### 第一步：下载 IPA 文件

前往 [Releases 页面](../../releases/latest)，下载最新版本的 `OpenIME-unsigned.ipa` 文件到电脑。

> IPA 为未签名版本，需要借助工具安装到 iPhone / iPad。

---

### 第二步：安装到手机

选择以下任意一种方式：

#### 方式一：AltStore（推荐，免费）

AltStore 是常用的免费侧载工具，装好后更新只需点一下。

1. 在电脑上安装 [AltServer](https://altstore.io)（Mac / Windows 均支持）
2. 用数据线将 iPhone / iPad 连接到电脑
3. 在电脑菜单栏找到 AltServer 图标，点击「Install AltStore」→ 选择你的设备
4. 手机上会出现 AltStore App，打开它，用 Apple ID 登录（**不需要付费开发者账号，普通 Apple ID 即可**）
5. 在 AltStore 里点右下角「+」，选择下载好的 `OpenIME-unsigned.ipa` 文件，等待安装完成

> **注意**：免费 Apple ID 安装的应用有效期 7 天，到期前用 AltStore 刷新一次即可续期。AltStore 支持自动后台刷新（需要电脑在线）。

#### 方式二：Sideloadly（免费）

1. 下载安装 [Sideloadly](https://sideloadly.io)（Mac / Windows）
2. 用数据线连接手机
3. 打开 Sideloadly，把 `OpenIME-unsigned.ipa` 拖入窗口
4. 填入 Apple ID，点击「Start」，等待安装完成
5. 手机上前往「设置 → 通用 → VPN与设备管理」，信任对应的开发者证书

---

### 第三步：启用键盘

1. 打开手机「**设置**」
2. 进入「**通用 → 键盘 → 键盘**」
3. 点击「**添加新键盘**」，找到并选择 **聿·输入法**
4. 点击「聿·输入法」，开启「**完全访问权限**」（输入法需要此权限才能读取词库）
5. 在任意输入框长按地球仪图标，切换到「聿·输入法」即可开始使用

---

## 功能

- **内置三套方案** — 开箱即得三种不同类型的输入方案，无需额外导入；不需要的可在「方案」页删除以释放空间，删除后不会随启动/升级自动装回：

  | 内置方案 | 类型 | 词库来源 | 体积 |
  |---|---|---|---|
  | 雾凇拼音（`oime-ice-pinyin`） | 全拼音码 | 基于雾凇拼音整理（`base.dict.yaml` 55 万词） | 约 16.7 MB |
  | 虎码（`oime-tiger`） | 形码 | 虎码秃版（单字全码含一/二/三简 + 官方词组表 + 简词表，25 万条） | 约 3.8 MB |
  | 超强快码（`oime-cqkm`） | 音形码 | 超强快码 `cqkm_cm` 全码表（12 万条，反查码不收录） | 约 1.9 MB |

  > 形码内置包由 `scripts/prepare_bundled_shape_schemes.py` 从上游原生方案归一生成（统一换行、删示例行、收窄 `exclude_patterns`，不改词条语义）

  > **App 体积构成**：安装包绝大部分是数据不是代码：候选渲染字体约 43 MB（文津宋体三份 OTF：`WenJinMinchoP0/P2/P3-Regular.otf`，随键盘扩展打包，是候选正文显示的依赖，无法删）+ 内置三套词库约 22 MB（源数据，首次启动编译成 `.bin` 索引，不用的可在「方案」页删除）+ 引擎与界面代码约 2–3 MB，未压缩合计约 68 MB（App Store 下载经压缩瘦身后更小）。App 内「关于 → 内置方案 / 存储空间与体积」运行时实测各 bundle 的 `manifest.yaml` + 目录大小并展示，不写死文案；逐项明细见 [PROJECT_STRUCTURE.md](PROJECT_STRUCTURE.md) 的「App 体积说明」。
- **两种键盘形态** — 全拼 26 键 / 小鹤双拼 26 键，随时切换（候选栏 ⇄ 标志展开的快捷面板）；双拼键面标注小鹤声韵母。**快捷面板始终列出两种形态**，当前主方案撑不起的灰显，点击气泡提示原因（不隐藏、不自动跳方案，方案为主键盘跟着走）；切方案后不合法的历史选择自动回落 26 键并气泡提醒：

  | 链上方案 | 全拼 26 键 | 小鹤双拼 |
  |---|---|---|
  | 全拼（`syllable` + 音码） | 可用 | 可用（双拼码还原成全拼） |
  | 双拼（`double_syllable`） | 可用 | 可用（键面码即词库码，恒等直通） |
  | 形码（`direct` + 形码） | 可用 | 不可用 |
  | 音形码（`direct` + `phono_shape`） | 可用 | 不可用 |
  | 形码主 + 全拼参与（混打生效） | 可用 | 不可用 |

  > 可用性由编码空间求交集推导得出（`Shared/SchemeCapability.swift`）：键盘形态决定击键被解码成什么，方案决定词库能被什么编码查到，有交集才出候选。26 键原样透传字母，对任何码制都能做前缀查询，因此恒可用。**形态只看主方案（链首），混打参与方只贡献候选、不扩展键盘形态可用性**。方案详情页的「方案能力」一节会列出这个结论。
- **智能预测** — 手动选词时自动学习词语搭配，根据上一个上屏词预测下一个词，越用越准；最多记录 10,000 条词对，可在「混合输入」设置页随时清除
- **拼音动态调频** — 同一个拼音下反复手选某个词，它会逐渐升到候选首位；改选别的词后旧词会回落（防回音室）。仅对拼音生效（形码 / 音形码一码对一字、无需猜），学习量以规范化全拼码为键，26 键 / 双拼 / 简拼共享同一份偏好；与智能预测相互独立、互不影响，可在设置页 / 键盘快捷面板 / 候选栏快捷条随时开关，在「混合输入」设置页随时清除
- **多方案管理** — 导入、激活、卸载输入方案；支持单 YAML 文件、裸 dict.yaml ZIP、单方案 ZIP、多方案目录 ZIP、ZIP-in-ZIP，一次导入可批量安装多个方案
- **灵活的词库导入** — 单文件（OpenIME 格式 / 外部格式均可直接导入）；多文件打成裸 ZIP（无需 manifest/schema，App 自动提取方案信息合并编译）；或按标准 ZIP 结构精确控制方案配置
- **方案包文件管理** — 已安装方案 zip 在「文件」App → 聿·输入法 → schemes 可见，可直接分享或删除，App 自动同步
- **多方案混合输入** — 形码主方案混入全拼词库（想不起字根时整字打拼音），候选词按方案颜色区分，主方案候选始终优先。混打只有一个合法方向：**纯形码为主 + 全拼词库参与**；拼音 / 双拼 / 音形码为主方案时，混打设置页不给开关（只留一段说明），旧 `settings.json` 里存着的非法组合也由运行时过滤掉、不会生效（不改写用户磁盘配置）
- **自定义词典** — 随时添加自定义词条，全局生效，优先于方案词库显示
- **候选注释** — 在候选词上方显示拆字、注音、编码等附加信息，可按方案单独配置；候选栏高度根据当前方案是否支持注释自动调整，规则如下：

  | 场景 | 候选栏高度 | 候选词位置 |
  |---|---|---|
  | 当前方案有注释列，且全局注释开关开启 | 高（含注释行） | 注释在上，候选词在下 |
  | 当前方案无注释列，或全局注释开关关闭 | 低（纯候选行） | 候选词垂直居中 |
  | 混合输入：主方案或**生效中的**参与方案至少一个有注释列 | 高（含注释行） | 有注释的候选显示注释，无注释的候选词居中 |
  | 混合输入：主方案与生效中的参与方案均无注释列 | 低（纯候选行） | 候选词垂直居中 |

  > 高度在开始打字前即已确定，不会因候选内容变化而跳动。
- **生僻字与部件显示** — 候选正文（含偏旁部首、笔画、CJK 基本区与扩展 A~J 全量生僻字）统一由键盘扩展内置的文津宋体三平面渲染，中国大陆字形标准，逐码位核验覆盖候选全集（10.6 万码位仅 1 个宗教符号走系统回退），常用字与生僻字观感一致；形码方案（五笔、虎码、快码等）的拆字注释开箱即用
- **主副分层键面** — 双拼键帽三段式：灰大写物理字母 + 红声母同行、蓝韵母在下方按行平分；声母 / 韵母标注按实测宽度回退字号，宁可显小也不缩成省略号
- **快码 i+拼音反查** — 音形码主方案下敲 i 后跟拼音，借已安装的音码方案按读音反查字（如 ini → 你 / 尼 / 泥）；反查候选上方同时给出这个字在主方案词库里的最短编码（走候选注释渲染，该开关默认开）；纯形码不接管 i（i 可能是其合法码元）；反查串不参与满码自动上屏
- **长串词图兜底** — 5～32 位长串常规检索落空时，用字级二元语法词图束搜索切分救场（拼音与形码都支持），生僻字切出后照样用内置字库渲染
- **剩余整码提示** — 形码 / 音形码候选词右侧显示已输前缀之后的剩余整码尾巴（输 jaf 出「今天m」），字号与候选正文一致、颜色稍淡，整码打完自动不显示
- **形码满码连打** — 满码后首选整码精确命中、**且这条码没有重码**才立即上屏（满码即上，对齐外部格式的 `auto_select_unique_candidate`）；有重码时编码留在候选栏等你选，继续打则下一键顶出首选（顶字兜底）；设置页提供「跟随方案 / 开启 / 关闭」三态开关与自填码长，改完立即生效
- **退格加速删除** — 长按退格键连续删除，向左滑动动态加速
- **滑动移动光标** — 在空格键或字母键上长按 1 秒进入光标模式，左右滑动精确移动光标
- **词库编译日志** — 导入时自动生成编译报告，存放在「文件」App → 聿·输入法 → logs
- **中英切换与大写锁定** — 中英切换走候选栏快捷功能条的「En」（键盘上不再有物理中 / 英键，布局里也无此开关）：英文模式下纯字母直接上屏、标点自动转 ASCII 等价符号；双击 Shift 锁定大写，再单击解锁
- **快捷面板** — 点候选栏左端 ⇄ 标志展开，直接切换输入方案 / 键盘形态（两种形态始终列出，主方案撑不起的灰显、点击提示原因）、开关候选注释·智能预测·emoji 候选·动态调频·按键声音·按键震动·记录剪贴板（历史列表也从这里查看）、切换主题，无需回主 App
- **候选栏快捷功能条** — 候选栏空态中段可自定义一排常用功能图标（剪贴板历史 / 123 / 中英 / 候选注释 / 智能预测 / 动态调频），在主 App「键盘外观」页右上角进入配置，支持拖动排序，溢出可横滑；收录的都是一键直达的功能，图标用绿 / 灰标出当前状态（开关型点一下翻状态；剪贴板那枚点一下展开历史，颜色跟着「记录剪贴板」开关走）
- **剪贴板历史** — 记录复制过的文本 / 网址 / 文件路径 / 图片，在键盘内一键回贴；默认关闭，可设保留条数上限（0–1000）并随时清空，数据只存本机。开关入口：主 App「词典」页与键盘快捷面板（候选栏快捷条上那枚图标是历史面板的入口，颜色随开关变绿 / 变灰，不承担开关）
- **分享扩展「存到 聿·输入法」** — 在任意 App 的系统分享菜单里把文本 / 网址 / 图片 / 文件直接存入剪贴板历史，弥补「键盘收起时在别处复制」抓不到的场景
- **副键盘两页** — 「123」副键盘含数字 / 符号两页（互切，中文标点已并入符号页，数字页左列另竖排句末标点）；中英文符号合并同一键位（点按跟随中/英模式上屏、长按滑动选半/全角），符号页可横向滑动翻屏放更多符号（跟手滑动、轻甩即可翻页），数字区三列居中布局
- **键盘外观定制** — 亮色 / 暗色 / 跟随系统；可调主色调、键间距、字母 / 候选 / 注释字号、候选加粗、圆角、背景透明度、行间距比例，并可自定义空格键标签；设置页实时预览按当前键盘形态（全拼 26 键 / 双拼）与真键盘同源绘制，改动当场可见
- **iPhone / iPad 适配** — 键盘尺寸随屏幕宽度自动缩放

## 兼容范围与输入管线

### 外部词库兼容到什么程度

导入时逐行解析外部词库，以下写法都装得进来（导入后可在「文件」App → 聿·输入法 → logs 看编译报告，跳过行、导入的表、派生的码、合并的重复条目都逐条列出）：

| 能力 | 说明 |
|---|---|
| front matter 三种形态 | `---` + `...`（雾凇拼音、仓颉五代）；无 `---` 直接从首行开始（虎码、tigress）；OpenIME 单文件 `---` 分隔 |
| Windows 换行（CRLF） | 逐行 trim 判等，`...` 后跟着 `\r` 也认得；文件头的行不计入「跳过」统计 |
| 自定义 `columns:` | 任意列序（text/weight/code/stem…）按名取用；`annotation` > `comment` > `stem` 作注释列；不认识的列忽略并记进报告 |
| `import_tables:` 递归导入 | 深度优先 + 去环，表名支持子路径与省略后缀（`cn_dicts/8105`）；依次在导入方目录、包根目录、`dictionaries/` 下找；**缺失只警告不卡死** |
| `encoder` 派生码 | 词组不写码时按 `length_equal` / `length_in_range` 匹配词长，再套 `AaAbBaBb` 这类 formula 从单字码拼出词码（`A`=第几字、`a`=第几位、`Z`/`z`=末字/末位）；缺字根则不派生并记进报告 |
| `exclude_patterns` | 对派生码与原有码都生效（超强快码靠它滤掉 `i`/`u`/`v` 开头的临时拼音与反查码，否则污染主码表） |
| 重复条目 | 同词同码首现胜出（外部格式「最上面的权重生效」），同词不同码全保留；合并条数进报告 |

**尚未实现**（字段已解析进画像，行为留待后续）：`speller/algebra` 完整规则引擎（模糊音 fuzz/derive、双拼 xform）、`use_preset_vocabulary` 预设词汇合并、opencc 繁简与 emoji（`switches`）。快码 `i` 键临时拼音反查已用自家管线实现（借已安装音码方案反查，见功能清单）。

**兼容的口径**：OpenIME 是主体，外部格式的 yaml 只是数据源。只提取自家管线用得到的字段（编码列与注释列、`import_tables`、`encoder`、`alphabet`、`delimiter`、`max_code_length`、`initial_quality`…），**行为旗标不照搬**：`translator/enable_sentence` 不当整句候选的开关（长串词图是 OpenIME 自家的兜底算法，只在常规检索落空时救场，虎码写 `false` 也照样兜），`speller/auto_clear: manual` 也不会留住编码（OpenIME 没有「留码续打」的状态机，上屏后一律清屏）。这类字段仍原样解析进画像，只为读回旧 `schema.json` 不丢信息、或在推断码制时作一次特征证据；`auto_select` / `max_code_length` 则只作满码连打的**默认值**，用户在设置页的选择优先于它。

### 从按下第一个字母到上屏

音码、形码、音形码的展开与检索规则差别很大，所以每一步都由**方案画像**（`SchemeProfile`）驱动，而不是在代码里写死某个方案：

| 步骤 | 做什么 |
|---|---|
| 1. 展开 | 按键盘形态（26 键 / 双拼）展开，再按画像过滤 `alphabet` 之外的非法键、按 `delimiter` 分段；音码与音形码额外挂一路简拼候选。**双拼类方案配小鹤双拼键盘是恒等直通**（词库里存的就是双拼码，不再还原全拼），与 26 键走同一条单条查询路径 |
| 2. 分段 | 音码按音节图切分，形码按画像码长滑窗，音形码「音码段 + 形码段」交替切分 |
| 3. 检索 | 四套策略按画像分派：前缀直查（形码/音形码）、音节检索（全拼）、双拼（全拼方案先还原全拼再走音节；双拼类方案直接拿双拼码查）、音形码交替切分；常规检索落空时才用长串词图兜底。**码表（形码/音形码）整码精确匹配优先，补全部分按词频降序**——超强快码这类全库权重恒为 1 的零词频码表，编译期已双源叠加真实字/词频：单字用内置通用字频表（CharFrequency，《通用规范汉字表》8105 字、源自 25 亿字语料），多字词组则流式复用随包的雾凇 `base.dict.yaml`（55 万词，THUOCL + 现代汉语常用词表 + 腾讯词向量），单字母 `h` 下「好」(hb) 这类高频简码不会被大量 `ha*` 长码按字母序挤出候选，常用词组也排在生僻词组之前；「同词频时码短者优先」降为词频相等时的决胜规则（与外部格式的 table translator + 预设词频语义一致）。**门控只看「全库权重有无区分度」、不看码制**——五笔/仓颉/无权重拼音等任何零词频方案都受益；只有自带真实权重的码表（虎码、雾凇拼音）不叠加，逐字节保持原有排序 |
| 4. 过滤 | 同词同码去重（uniquifier）、可选单字优先；自定义词典词条以最高权重前插 |
| 5. 打分 | 一个纯函数收拢（`CandidateScoring`）：词库词频 + 动态调频学到的用户偏好 + `initial_quality` + 预测；`max_phrase_length` 之外的超长词条不参与整句拼接 |
| 6. 上屏 | 满码连打：画像给出 `max_code_length` / `auto_select` 默认（虎码满 4 码即上、上屏即清屏），**用户在设置页选的「跟随方案 / 开启 / 关闭」与自填码长优先覆盖画像**，改完立即生效；满码即上只在整码精确命中且无重码时触发（`auto_select_unique_candidate` 口径）|

画像字段缺失时（老方案包）按词库检索类型回落，行为与从前一致。

### 码制怎么判出来

导入时按三级证据推断，写进安装日志（用户看得懂为什么这么判）：

1. **包里写明** `code_system` 或 `type`：不再猜；
2. **外部 schema 特征**：`speller` 里声母表 + 韵母表齐全、或 `algebra` 有音节派生规则 ⇒ 音码；`max_code_length` 在 3–6 且没开整句 ⇒ 形码；两者并存而编码又不是纯音节 ⇒ 音形码；
3. **码表统计**（地面真相，与 schema 打架时以它为准）：顺着 `import_tables` 展开后按文件平分额度抽样最多 2000 条编码，≥90% 能整段切成合法拼音音节 ⇒ 音码；含空格的编码过半 ⇒ 编译期去掉空格。

因此把雾凇的 `cn_dicts/*.dict.yaml` 直接拖进来会得到音节检索；音形码需要作者显式写 `code_system: phono_shape`，或音码与形码证据并存才判得出来——判不出来时保守落在形码，因为前缀直查对任何码表都成立，最坏只是查得笨一点，不会查不到。

## 项目结构

6 个 Target：主 App `OpenIME`、共享核心库 `OpenIMECore`（framework，聚合 `OpenIME/Sources` 引擎与全部 `Shared` 代码）、键盘扩展 `OpenIMEKeyboard`、分享扩展 `OpenIMEShare`、单元测试 `OpenIMETests`、UI 测试 `OpenIMEUITests`。

```
OpenIME/
├── OpenIME/               主 App：UI/Settings 各设置页 + Sources 引擎（编译进 OpenIMECore）
├── Shared/                共享代码（编译进 OpenIMECore）
│   ├── SchemeCapability.swift  方案能力模型：编码空间推导形态可用性、混打合法方向（UI 与运行时共问的唯一事实来源）
│   ├── AppGroup/ Models/ Prediction/    容器 / 数据模型（含键面样式与键盘几何单一源）/ 预测引擎
│   ├── Frequency/         拼音动态调频引擎（主线程活表 O(1) 读 + 后台快照落盘）
│   ├── Keyboard/          KeyboardGridGeometry（按键几何，键盘与设置页预览共用）
│   ├── InputModes/        两种键盘形态、双拼编码展开、长串词图切分、副键盘布局（含半/全角对照表）、中英状态存储
│   ├── Clipboard/         剪贴板历史（模型 / 存储 / 设置 / 抓取）
│   ├── Shortcuts/         候选栏快捷功能条（功能目录 / 有序持久化）
│   └── Styles/            跨主 App 与键盘复用的语义样式（清除类按钮 / 执行结果 toast）
├── OpenIMEKeyboard/       键盘扩展：Keyboard（各形态键盘）/ Candidate（候选栏）/ Clipboard（历史面板）
├── OpenIMEShare/          分享扩展「存到 聿·输入法」
├── OpenIMETests/          单元测试
├── OpenIMEUITests/        UI 测试
└── Packages/BundledSchemes/   预装三套方案：oime-ice-pinyin（雾凇拼音，约 16.7 MB）、oime-tiger（虎码，约 3.8 MB）、oime-cqkm（超强快码，约 1.9 MB）
```

> 完整的逐文件目录树、各模块职责与 Target 配置要点见 [PROJECT_STRUCTURE.md](PROJECT_STRUCTURE.md)。

## 制作方案包

### 方式一：YAML 单文件（推荐新手）

只需一个 `.yaml` 文件，在「方案」页点「导入方案包（ZIP / YAML）」选择，App 自动构建并安装，无需手动打包。

`---` 之前写方案信息，`---` 之后写词条（各列之间用 **Tab 键**分隔）：

```
# 方案唯一标识，只能用字母、数字、连字符，在 App 内必须唯一
id: my-scheme

# 方案显示名称
name: 我的方案

# 方案类型
# syllable        音码（雾凇拼音、粤拼等）
# direct          形码（虎码、五笔、仓颉等）或音形码（快码、二笔等）
# double_syllable 双拼（小鹤双拼、自然码等）
type: syllable

# 作者名（可选）
author:

# 方案简介（可选）
description:

# --- 下方开始填写词条，每行一个，各列之间用 Tab 键分隔（不能用空格）
# 格式：汉字[Tab]编码[Tab]权重[Tab]注释
# 权重：越大候选越靠前；注释：开启「候选注释」后显示在候选词上方
# 注释列必须保留，内容可以留空
---
你好	nihao	1000	nǐ hǎo
你们	nimen	950	
你好吗	nihaoma	900	nǐ hǎo ma
年级	nanji	800	
世界	shijie	1000	shì jiè
时间	shijian	950	
拼音	pinyin	1000	pīn yīn
苹果	pingguo	950	píng guǒ
朋友	pengyou	900	
中国	zhongguo	1000	zhōng guó
中文	zhongwen	950	
自然	ziran	900	
汉字	hanzi	900	
学习	xuexi	900	
生活	shenghuo	900	
工作	gongzuo	900	
```

**注意**：词条固定四列（汉字 / 编码 / 权重 / 注释），注释列必须保留，id 为空时用文件名代替。

**示例模版**已存放在「文件」App → 聿·输入法 → **templates** → `示例方案.yaml`（App 首次启动自动生成），直接修改后导入即可。

---

### 方式二：裸 dict.yaml ZIP（最简单）

将多个 `.dict.yaml` 文件**直接放在 ZIP 根目录**，无需 manifest.yaml / schema.yaml，App 自动提取方案名称并将所有文件合并编译为一个方案。

**OpenIME 格式**和 **外部格式**的文件均支持，也可以混合放在同一个 ZIP 里：

```
词库包.zip
├── main.dict.yaml        # OpenIME 格式或外部格式均可
├── ext.dict.yaml
└── phrases.dict.yaml
```

方案名从第一个文件里有效的 `name` 字段提取（OpenIME 格式取 `---` 之前的 `name:`，外部格式取 front matter 里的 `name:`），id 自动生成，类型由码制推断得出（见[兼容范围与输入管线](#兼容范围与输入管线)，可在方案设置页修改）。

外部格式额外支持以下文件形态：

| 形态 | 示例 |
|---|---|
| 注释行 + `---` front matter | 雾凇拼音、仓颉五代 |
| front matter 直接从第一行开始（无 `---`） | 虎码、tigress |
| 自定义 `columns:` 顺序（text/weight/code/stem 等任意顺序） | 均支持 |
| `normalize_code: strip_spaces`（拼音空格拼合） | 全拼方案 |
| `import_tables:` 递归导入其它词库 | 雾凇拼音（`cn_dicts/` 五张表）、tiger.extended |
| `encoder` 派生码 + `exclude_patterns` | 超强快码（`cqkm_cm.src`） |
| Windows 换行（CRLF） | 虎码 `tiger.dict.yaml`、`tigress_ci.dict.yaml` |

---

### 方式三：ZIP 方案包

新建一个文件夹，包含以下三个文件，压缩为 .zip 导入：

```
我的方案/
├── manifest.yaml        必须，方案基本信息
├── schema.yaml          必须，输入规则配置
└── dictionaries/
    └── 词库.dict.yaml   必须，至少一个词库文件
```

---

### manifest.yaml

```yaml
# 方案唯一标识，只能用字母、数字、连字符
id: my-scheme

# 方案显示名称
name: 我的方案

# 作者名（可选）
author: 你的名字

# 方案简介，显示在方案详情页（可选）
description: 这里写方案简介
```

---

### schema.yaml

`type` 决定引擎如何处理输入编码，其余参数在 App 的方案设置页调整即可，不必写在文件里。

```yaml
# direct          形码：五笔、仓颉、虎码、快码等
# syllable        拼音：全拼、粤拼等
# double_syllable 双拼：小鹤、自然码等
type: direct
```

---

### 词库文件（.dict.yaml）

`---` 和 `...` 之间是文件头（声明列结构），`...` 之后是词条，每列用 **Tab 键**分隔：

```
---
columns:
  - text
  - code
  - weight
  # 注释列，开启「候选注释」后显示在候选词上方
  - annotation
...
你好	nihao	1000	nǐ hǎo
世界	shijie	800	shì jiè
苹果	pingguo	600
```

- 列之间必须是 **Tab 键**，不能用空格
- 文件编码必须是 **UTF-8**

---

### 方式四：批量打包多个方案

**裸 dict.yaml ZIP** — 见「方式二」，OpenIME 格式和外部格式均支持，直接打 ZIP 无需配置文件。

**多方案目录 ZIP** — 一个 ZIP 里安装多个独立方案，每个子目录是一个完整方案：

```
Bundle.zip
└── schemes/
    ├── 方案A/
    │   ├── manifest.yaml
    │   ├── schema.yaml
    │   └── dictionaries/
    └── 方案B/
        ├── manifest.yaml
        ├── schema.yaml
        └── dictionaries/
```

**ZIP-in-ZIP**

```
Bundle.zip
├── 方案A.zip
├── 方案B.zip
└── 方案C.zip
```

---

### 方案包文件管理

已安装的方案 zip 存放在「文件」App → 聿·输入法 → **schemes**，可直接分享给他人或删除。删除 zip 后，下次打开 App 自动卸载对应方案并清理设置。

---

### 排查问题：编译日志

导入后在「文件」App → 聿·输入法 → **logs** → `方案id_install_log.txt` 查看编译报告。

| 现象 | 原因 | 修正 |
|---|---|---|
| 词条数为 0 | 列之间用了空格而非 Tab | 替换为 Tab 键 |
| 词条数为 0 | 文件编码不是 UTF-8 | 另存为 UTF-8 |
| 词条数为 0 | `...` 行缺失或位置不对 | 确认文件头以单独一行 `...` 结束 |
| 部分行跳过 | `columns` 顺序与数据列不一致 | 核对 `columns` 和实际列的对应关系 |
| 安装失败 | 缺少必要文件 | 确认 manifest.yaml、schema.yaml、dictionaries/ 都存在 |
| 外部词库导入后候选不分词 | 方案类型未设为拼音 | 在方案设置页将类型改为「syllable」或「double_syllable」 |

## 本地开发与真机测试

从零开始，把 OpenIME 编译并安装到 iPhone / iPad 进行真机测试。全程不需要付费开发者账号，普通 Apple ID 即可。

---

### 第一步：安装必要工具

**1. 安装 Xcode**

从 Mac App Store 搜索「Xcode」安装，或前往 [developer.apple.com/xcode](https://developer.apple.com/xcode/) 下载。

安装完成后打开一次 Xcode，同意许可协议，等待系统组件安装完毕。

> 需要 Xcode 16 或更高版本。

**2. 安装 Homebrew（如果还没有）**

打开终端，粘贴以下命令执行：

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

**3. 安装 xcodegen**

```bash
brew install xcodegen
```

---

### 第二步：获取源代码

**方式一：从 zip 包解压**

将收到的 zip 包解压到任意目录，例如桌面：

```
~/Desktop/OpenIME-main/
```

**方式二：从 GitHub 克隆**

```bash
git clone https://github.com/你的用户名/OpenIME.git
cd OpenIME
```

---

### 第三步：生成 Xcode 项目

进入项目目录，运行 xcodegen：

```bash
cd ~/Desktop/OpenIME-main   # 换成你实际的解压路径
xcodegen generate
```

成功后会看到：

```
Created project at .../OpenIME.xcodeproj
```

---

### 第四步：用 Xcode 打开项目

```bash
open OpenIME.xcodeproj
```

或者直接在 Finder 里双击 `OpenIME.xcodeproj`。

Xcode 打开后会自动联网拉取依赖（ZIPFoundation），等左上角旋转图标消失即完成，通常需要 1–2 分钟。

---

### 第五步：配置签名（真机必须）

> 模拟器不需要此步骤，可以跳过。

1. 用数据线将 iPhone / iPad 连接到 Mac
2. 手机上弹出「信任此电脑」，点「信任」
3. 在 Xcode 左侧项目导航里点击最顶部的 **OpenIME**（蓝色图标）
4. 选中 **OpenIME** Target → 点「Signing & Capabilities」标签
5. 勾选「Automatically manage signing」
6. 在「Team」下拉框里选择你的 Apple ID（没有的话点「Add an Account」登录）
7. 对 **OpenIMEKeyboard** 和 **OpenIMEShare** 两个扩展 Target 各重复第 4–6 步

> 用免费 Apple ID 签名的应用有效期 **7 天**，到期后重新连接 Mac 用 Xcode 编译一次即可续期。

---

### 第六步：选择目标设备并编译安装

1. 在 Xcode 顶部工具栏，点击设备选择器（显示「iPhone」或「Any iOS Device」的地方）
2. 在列表里选择你连接的真机
3. 点击左上角 ▶ 按钮（或按 `Cmd + R`）开始编译

编译成功后 App 会自动安装到手机并启动。

> **首次安装可能提示「不受信任的开发者」**：
> 前往手机「设置 → 通用 → VPN 与设备管理」，找到你的 Apple ID，点「信任」，然后重新打开 App。

---

### 第七步：启用键盘

1. 打开手机「**设置 → 通用 → 键盘 → 键盘 → 添加新键盘**」
2. 找到 **聿·输入法**，点击添加
3. 点击「聿·输入法」，开启「**完全访问权限**」（输入法读取词库必须）
4. 在任意输入框长按地球仪图标，切换到「聿·输入法」

---

### 常见问题

**编译报错"No such module"或大量红色错误**

通常是没有运行 xcodegen，或 xcodegen 版本过旧。执行：

```bash
xcodegen generate
```

然后在 Xcode 菜单选「Product → Clean Build Folder」再重新编译。

**依赖拉取失败**

在 Xcode 菜单选「File → Packages → Resolve Package Versions」，确保网络正常后重试。

**真机上 App 闪退**

检查 OpenIME、OpenIMEKeyboard、OpenIMEShare 三个 Target 是否都配置了签名（第五步），三者都需要配置。

**真机编译报「requires a provisioning profile」**

`project.yml` 里的签名默认是模拟器 / CI 口径（ad-hoc，不校验描述文件），真机需要自己的 Team。按第五步在 Xcode 里给三个 Target 选一次 Team 即可；Team 只写进生成物 `OpenIME.xcodeproj/project.pbxproj`，不入库。注意 `xcodegen generate` 会重写 pbxproj 并把 Team 清空，重跑之后需重新选一次。

**键盘切换不了 / 打字没有候选词**

确认已开启「完全访问权限」（第七步第 3 步）。如果开启后仍无效，在 App 内「方案」页确认有已激活的方案。

---

## 构建与测试

```bash
# 生成 / 更新 Xcode 工程（改了 project.yml 或新增源文件后必跑）
xcodegen generate --spec project.yml --project .

# 构建
xcodebuild -project OpenIME.xcodeproj -scheme OpenIME \
  -destination 'platform=iOS Simulator,name=iPhone 17' build

# 全量测试（单元 + UI）
xcodebuild -project OpenIME.xcodeproj -scheme OpenIME \
  -destination 'platform=iOS Simulator,name=iPhone 17' test
```

> 工程配置的唯一真相是根目录 `project.yml`；`OpenIME.xcodeproj` 是生成物，已在 `.gitignore` 中排除、不入库。`scripts/generate_project.sh` 只负责安装 xcodegen 并读取根 `project.yml` 生成工程（不再内嵌配置副本），`scripts/setup.sh` 可放心一键初始化。

## 发布流程

### 日常开发：直接推送代码

```bash
git add .
git commit -m "修复了某个问题"
git push
```

推送到 main 分支后，GitHub Actions **自动编译**并生成 IPA 文件。这个 IPA 存在 Actions 页面的 artifact 里，30 天后自动删除。适合自己测试用，不对外发布。

---

### 发布新版本给用户下载

在确认这次改动没问题、可以给用户用了，再执行：

```bash
git add .
git commit -m "发布 v1.0.1"
git push

git tag v1.0.1
git push origin v1.0.1
```

推送 tag 后，GitHub Actions 自动编译并在 **Releases 页面**发布新版本，用户可以直接下载 IPA。

**版本号规则**（随意，但建议遵循）：
- `v1.0.0` → `v1.0.1`：小修小改、bug 修复
- `v1.0.0` → `v1.1.0`：新增功能
- `v1.0.0` → `v2.0.0`：较大改动

---

### 后期上架 App Store（有开发者账号后）

需要在 `.github/workflows/build.yml` 里补充以下内容：
1. 在 GitHub 仓库 Settings → Secrets 里添加：
   - `CERTIFICATES_P12`：导出的 .p12 证书（Base64 编码）
   - `CERTIFICATES_PASSWORD`：证书密码
   - `PROVISIONING_PROFILE`：.mobileprovision 文件（Base64 编码）
   - `TEAM_ID`：开发者 Team ID
2. workflow 里在 archive 步骤填入真实签名参数
3. 新增 `xcrun altool` 或 `fastlane deliver` 上传 TestFlight 的步骤

届时可以找人协助配置，一次配好后同样全自动。

## 开源依赖

| 依赖 | 协议 | 用途 |
|---|---|---|
| [ZIPFoundation](https://github.com/weichsel/ZIPFoundation) | MIT | ZIP 文件解压与打包 |
| [文津宋体（WenJin Mincho）](https://github.com/takushun-wu/WenJinMincho) | SIL OFL 1.1 | 候选正文渲染字体，随键盘扩展打包三份官方平面 OTF：WenJinMinchoP0/P2/P3-Regular.otf（合计约 43 MB）。中国大陆字形标准，覆盖 Unicode 汉字全集（基本区 + 扩展 A~J）+ 偏旁部首 + 笔画 + 拼音注音，候选里的生僻字与部首均可显示，全字集观感一致 |

### 内置词库来源与署名

App 内置三套输入方案的**词库数据**（仅取用词库，非方案本体授权）。署名与授权状态如下：

| 内置词库 | 来源 / 作者 | 许可与授权状态 |
|---|---|---|
| 雾凇拼音（oime-ice-pinyin） | [iDvel / rime-ice](https://github.com/iDvel/rime-ice) | GPL-3.0，与本项目同协议兼容；仅取用其 `cn_dicts/*.dict.yaml` 词库（见 `scripts/fetch_ice_dict.sh`） |
| 虎码（oime-tiger） | 虎码团队 | 经作者许可内置；原词库无独立许可声明 |
| 超强快码（oime-cqkm） | 付东升 | 码表原文件头声明专有许可「不得修改和发布」；经作者许可内置 |

> **开发者须知**：内置方案超强快码词库与虎码词库均已获作者同意内置分发；雾凇拼音为 GPL-3.0。

### 字库字体方案

候选正文由**文津宋体三平面**渲染：

| 字体 | 协议 | 关键结论 |
|---|---|---|
| [文津宋体（WenJin Mincho）](https://github.com/takushun-wu/WenJinMincho) | SIL OFL 1.1 | 中国大陆字形标准；基于思源宋体（含全 ASCII + 标点）；v2.100（适配 Unicode 18.0）覆盖扩展 B–J 区；允许嵌入 / 捆绑进 iOS App 并商业分发 |

单个 OpenType 字体最多 65,535 个字形，而候选需要的「汉字 + 偏旁部首 + 拼音注音 + 标点」全集约 10.6 万码位，装不进一个字体，因此按 Unicode 平面拆成 P0 / P2 / P3 三份。三份同字族同度量，渲染时按码位所在平面选字体、跨平面分段拼接。

fontTools 逐码位核验：候选全集 103,693 码位，三份合并覆盖 105,831 码位，汉字本体（基本区 + 扩展 A~J）、偏旁部首 + 笔画（368 个）、IDS 拆字结构符（16 / 16）全部覆盖，仅 1 个宗教符号 ✝(U+271D) 走系统回退（正常显示）。

> 合计约 43 MB。P0（约 17.5 MB，覆盖 99.98% 候选）随键盘首帧同步注册，P2 / P3 后台异步注册。候选正文加粗可在「键盘外观」页开关（文津宋体只有 Regular 一字重，开启后由系统合成伪粗）。

## 许可

本项目基于 **GNU General Public License v3.0** 开源。

你可以自由地：
- 使用、复制、分发本项目
- 修改源代码并发布修改后的版本

但必须遵守以下条件：
- **署名来源**：保留原始版权声明，注明修改自 OpenIME
- **同协议分发**：修改后的版本必须同样以 GPL v3 开源，不可改为闭源
- **提供源码**：分发时必须提供或告知如何获取对应源代码

Copyright (c) 2026 OpenIME Team — [GPL v3 完整条款](LICENSE)


