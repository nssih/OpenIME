import SwiftUI

// MARK: - 关于页

struct AboutView: View {
    var body: some View {
        NavigationStack {
            List {
                appHeaderSection
                usageSection
                bundledSchemesSection
                storageSection
                featuresSection
                keyboardParamsSection
                schemePackageSection
                moreSection
            }
            .navigationTitle("关于")
            // 全站标题风格统一：导航标题一律 inline 常驻导航栏、不随内容滚动折叠（与键盘外观 / 混合页一致）
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    // MARK: - App 信息头

    var appHeaderSection: some View {
        Section {
            HStack(spacing: 16) {
                Image(systemName: "keyboard.fill")
                    .font(.system(size: 40))
                    .foregroundColor(.accentColor)
                    .frame(width: 64, height: 64)
                    .background(Color.accentColor.opacity(0.1))
                    .cornerRadius(14)

                VStack(alignment: .leading, spacing: 4) {
                    Text("聿·输入法")
                        .font(.title2.bold())
                    Text("免费开源自定义输入方案平台")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Text("版本 \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.vertical, 8)
        }
    }

    // MARK: - 使用教程

    var usageSection: some View {
        Section {
            InfoRow(step: "1", title: "安装键盘", detail: "前往「系统设置 → 通用 → 键盘 → 键盘 → 添加新键盘」，选择「聿·输入法」。首次安装后需开启「完全访问权限」。")
            InfoRow(step: "2", title: "等方案编译好", detail: "首次打开 App 时，内置的雾凇拼音、虎码、超强快码会在后台自动编译成可用词库，视机型大约需 1～3 分钟。这期间键盘可能打不出候选，请让 App 停在前台，直到「方案」页三套方案都出现再开始用。要装别的方案，进「方案」页点「导入方案包（ZIP / YAML）」选文件；用不到的内置方案也能在那里删除腾空间。")
            InfoRow(step: "3", title: "激活方案", detail: "在「方案」页点击方案右侧「激活」按钮，将其设为当前使用的输入方案。")
            InfoRow(step: "4", title: "开始打字", detail: "在任意输入框内长按地球仪图标，切换至「聿·输入法」，即可开始输入。")
            InfoRow(step: "5", title: "选择候选词", detail: "候选栏左右滑动查看更多候选词；点击右端「∨」按钮全屏展示候选词，点面板右端「∧」或下滑可关闭。")
        } header: {
            Text("使用教程")
        }
    }

    // MARK: - 内置方案（运行时枚举只读 bundle + 实测体积，不写死名单与大小）

    var bundledSchemesSection: some View {
        Section {
            ForEach(BundledSchemeCatalog.schemes) { scheme in
                ParamRow(name: scheme.name, range: scheme.sizeText, detail: scheme.detail)
            }
        } header: {
            Text("内置方案（开箱即用）")
        } footer: {
            Text("以上方案随 App 内置，首次打开时自动编译后即可使用（编译约需 1～3 分钟，详见上方「使用教程」第 2 步）；体积为词库源数据的实测大小。用不到的可在「方案」页删除腾空间。")
        }
    }

    // MARK: - 存储空间与体积（告诉用户 App 为什么这么大）

    var storageSection: some View {
        Section {
            ParamRow(name: "候选渲染字体", range: "约 43 MB",
                     detail: "覆盖汉字全集与偏旁部首，让候选里的极生僻字、扩展区汉字与拆字部件都能正常显示、且与常用字观感一致。为保证候选可见，这部分无法删除。")
            ParamRow(name: "内置三套词库方案", range: BundledSchemeCatalog.totalSizeText,
                     detail: "词库源数据，不需要的方案可在「方案」页删除以释放空间（详见上方「内置方案」）。")
            ParamRow(name: "引擎与界面代码", range: "约 2–3 MB",
                     detail: "输入引擎、键盘界面与各扩展的全部程序代码——App 体积里代码只占很小一部分。")
        } header: {
            Text("存储空间与体积")
        } footer: {
            Text("App 之所以较大，绝大部分来自「字体 + 词库」这些数据文件，程序代码本身很小。删掉用不到的内置方案可省下对应词库空间；字体是候选文字显示的依赖，无法移除。")
        }
    }

    // MARK: - 功能列表

    var featuresSection: some View {
        Section {
            FeatureRow(title: "智能预测", detail: "默认开启。根据上一个上屏的词自动预测下一个词，越用越准，可在设置页随时关闭或清除记录。")
            FeatureRow(title: "拼音动态调频", detail: "默认开启。同一个拼音下你常选哪个词，它就逐渐排到前面，仅对拼音生效，可在设置页开关并清除记录。")
            FeatureRow(title: "按键声音与震动", detail: "敲键时播放 iOS 标准键盘点击音并伴一下轻触感；声音默认开、震动默认关，两项可在键盘快捷面板分别开关。")
            FeatureRow(title: "多方案管理", detail: "导入、激活、卸载输入方案，支持单个 YAML、裸 ZIP 词库与标准 ZIP 方案包等多种导入方式。")
            FeatureRow(title: "方案混合输入", detail: "默认关闭。开启后形码作主方案、全拼作为兜底方案一起出候选，可选用不同颜色区分。")
            FeatureRow(title: "打字测试", detail: "「混合输入」页顶部常驻打字测试区，手打编码即可当场验证候选、注释与各项开关的效果。")
            FeatureRow(title: "自定义词典", detail: "手动添加任意词条（词 + 编码），全局生效，常选的自定义词会逐渐前移但不占首选。")
            FeatureRow(title: "键盘外观调整", detail: "支持亮色 / 暗色 / 跟随系统主题，可调主色调、键间距、字号、圆角、键盘高度、行间距与背景透明度。")
            FeatureRow(title: "候选注释", detail: "默认开启。在候选词上方显示注音、拆字、编码等信息，可全局或按方案开关。")
            FeatureRow(title: "生僻字与部件显示", detail: "偏旁部首和生僻字在候选区正常显示，无需设置，常用字与生僻字观感一致；「键盘外观」设有候选加粗选项。")
            FeatureRow(title: "两种键盘形态", detail: "全拼 26 键与小鹤双拼 26 键，点候选栏左端「⇄」在快捷面板里切换，可用哪种由当前方案码制决定。")
            FeatureRow(title: "中英切换与大写锁定", detail: "快捷功能栏「En」键切换英文输入（标点自动随模式），双击 Shift 锁定大写、再单击解锁。")
            FeatureRow(title: "快捷面板", detail: "点候选栏左端「⇄」展开，可直接切换方案 / 键盘形态、开关各项功能、查看剪贴板历史、切换深浅色，无需回主 App。")
            FeatureRow(title: "候选栏快捷功能条", detail: "候选栏空态可自定义一排常用功能图标（剪贴板、123、中英、注释、预测、调频），在「键盘外观」页配置并拖动排序，绿=开、灰=关。")
            FeatureRow(title: "剪贴板历史", detail: "默认关闭。记录你复制过的文本 / 网址 / 图片，在键盘里点一下即可重新粘贴，可在主 App 或快捷面板开启并设置保留条数，内容只存本机。")
            FeatureRow(title: "分享扩展「存到 聿·输入法」", detail: "在任意 App 的分享菜单选「存到 聿·输入法」，把文本 / 网址 / 图片 / 文件直接存进剪贴板历史。")
            FeatureRow(title: "数字 / 符号副键盘", detail: "主键盘底行「123」点击进入副键盘，含数字、符号两页，符号页可滑动翻屏、中英文符号同键（长按滑动选半角 / 全角）。")
            FeatureRow(title: "键盘布局选项", detail: "键盘高度、行间距、空格键标签可调，改动在「键盘」页预览区实时可见。")
            FeatureRow(title: "形码满码连打", detail: "形码 / 音形码方案敲满码长、首选精确命中且无重码时立即上屏接着打，省一次按键，可在方案设置页选「跟随方案 / 开启 / 关闭」。")
            FeatureRow(title: "单字优先", detail: "默认关闭。开启后把单字候选整体提到最前（组内仍按词频），适合逐字打词，按方案分别配置。")
            FeatureRow(title: "字符上屏", detail: "输入框有内容时回车键变「字符上屏」，点一下把正在打的这串字符原样上屏、不走候选也不参与预测学习。")
            FeatureRow(title: "退格加速删除", detail: "长按退格连续删除，向左滑动可动态加速，向右或大幅偏移则停止。")
            FeatureRow(title: "滑动移动光标", detail: "在空格或任意字母键上按住不放进入光标模式，左右滑动精确移动光标，松手恢复输入。")
            FeatureRow(title: "iPhone / iPad 适配", detail: "键盘尺寸随屏幕宽度自动缩放，适配各种设备无需手动调整。")
        } header: {
            Text("功能列表")
        }
    }

    // MARK: - 可调参数说明

    var keyboardParamsSection: some View {
        Section {
            ParamRow(name: "主色调", range: "任意 #RRGGBB 颜色", detail: "影响 Shift 键、回车键、功能键背景色及候选页主色调。")
            ParamRow(name: "键间距", range: "0 ~ 20 pt", detail: "按键之间的水平间距，值越大按键间隔越宽。")
            ParamRow(name: "字母大小", range: "8 ~ 32 pt", detail: "字母键上字母的字体大小。")
            ParamRow(name: "候选大小", range: "8 ~ 32 pt", detail: "候选词的字体大小，同时决定候选栏高度。")
            ParamRow(name: "候选加粗", range: "开 / 关", detail: "宋体只有一个字重，开启后由系统合成伪粗（描边加粗），让宋体细笔画在小字号下更清晰。默认关闭。")
            ParamRow(name: "注释大小", range: "2 ~ 24 pt", detail: "候选词上方注释文字的字体大小，开启注释后生效。")
            ParamRow(name: "圆角", range: "0 ~ 16 pt", detail: "所有按键的圆角半径，0 为直角，16 为圆润风格。")
            ParamRow(name: "背景透明度", range: "0.1 ~ 1.0", detail: "键盘背景的不透明度，低值可透出底部内容。")
            ParamRow(name: "行间距比例", range: "0.05 ~ 0.50", detail: "相对于按键高度的行间距比例，值越大行间距越大。")
            ParamRow(name: "键盘高度", range: "85% ~ 180%", detail: "在「键盘外观 → 键盘布局」调节，默认 132%。调高只让键高变大、键宽不变，行间距与上下留白同步重算，预览与真键盘一起跟随。")
            ParamRow(name: "自动上屏码长", range: "2 ~ 9（形码方案）", detail: "在方案设置页单独配置，敲满此码长、首选整码命中且无重码时立即上屏；有重码或非精确匹配则不自动上屏，继续打下一码会把首候选顶上去。")
        } header: {
            Text("可调参数（键盘外观）")
        } footer: {
            Text("所有参数均实时生效，可在「键盘」标签页的预览区域中即时查看效果。")
        }
    }

    // MARK: - 方案包制作说明

    var schemePackageSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 14) {

                // YAML 单文件方式（推荐）
                Text("方式一：YAML 单文件（推荐新手）")
                    .font(.callout.bold())
                Text("只需一个 .yaml 文件，App 自动构建并安装，无需手动打包。示例模版在「文件」App → 聿·输入法 → templates → 示例方案.yaml，直接修改后导入即可。")
                    .font(.caption).foregroundColor(.secondary)
                Text("格式：--- 之前写方案信息，--- 之后写词条（汉字/编码/权重/注释，Tab 分隔）：")
                    .font(.caption).foregroundColor(.secondary)
                CodeBlock("""
id: my-scheme
name: 我的方案
type: syllable

---
你好    nihao   1000    nǐ hǎo
世界    shijie  800     shì jiè
拼音    pinyin  900
""")
                Text("列与列之间在真实文件里用 Tab 分隔，示例为了对齐展示用的空格。注释列必须保留，内容可以留空。id 为空时自动用文件名代替。")
                    .font(.caption).foregroundColor(.secondary)

                // 裸 dict.yaml ZIP
                Divider().padding(.vertical, 2)
                Text("方式二：裸 dict.yaml ZIP（最简单的多文件方式）")
                    .font(.callout.bold())
                Text("将多个 .dict.yaml 文件直接放在 ZIP 根目录，无需 manifest.yaml / schema.yaml，App 自动提取方案名并合并编译为一个方案。本 App 格式和第三方词库格式的文件均支持，也可以混合放在同一个 ZIP 里。")
                    .font(.caption).foregroundColor(.secondary)
                CodeBlock("""
词库包.zip
├── main.dict.yaml
├── ext.dict.yaml
└── phrases.dict.yaml
""")
                Text("方案名从第一个文件的 name 字段提取，id 自动生成，类型由码制推断得出（可在方案设置页修改）。第三方词库文件里的 import_tables 递归导入、encoder 派生码、exclude_patterns 也都支持。")
                    .font(.caption).foregroundColor(.secondary)

                // ZIP 方式
                Divider().padding(.vertical, 2)
                Text("方式三：标准 ZIP 方案包")
                    .font(.callout.bold())
                Text("新建文件夹，包含以下文件，压缩为 .zip 导入（dictionaries/ 下可放多个词库文件，合并编译）：")
                    .font(.caption).foregroundColor(.secondary)
                CodeBlock("""
我的方案/
├── manifest.yaml
├── schema.yaml
└── dictionaries/
    └── 词库.dict.yaml
""")
                Text("也支持一个 ZIP 内含多个方案（schemes/ 子目录）或多个子 ZIP（ZIP-in-ZIP），一次批量安装。\n单个 YAML 文件同样可以直接导入，支持本 App 格式和第三方词库格式（虎码、雾凇等）。")
                    .font(.caption).foregroundColor(.secondary)

                // manifest.yaml
                Divider().padding(.vertical, 2)
                Text("manifest.yaml")
                    .font(.callout.bold())
                CodeBlock("""
# 方案唯一标识，只能用字母、数字、连字符
id: my-scheme

# 方案显示名称
name: 我的方案

# 作者名（可选）
author: 你的名字

# 方案简介（可选）
description: 这里写方案简介
""")

                // schema.yaml
                Divider().padding(.vertical, 2)
                Text("schema.yaml")
                    .font(.callout.bold())
                CodeBlock("""
# type 说编码怎么读怎么查，code_system 说输入逻辑属于哪一类
# （展开、分段、满码连打都按 code_system 走）
# type 取值：
#   direct           形码（虎码、五笔、仓颉等）或音形码（快码、二笔等）
#   syllable         音码（雾凇拼音、粤拼等）
#   double_syllable  双拼（小鹤双拼、自然码等）
type: direct

# code_system 取值（可选，不写时 App 抽样词库编码自动推断）：
#   shape        形码
#   phonetic     音码
#   phono_shape  音形码
# 音形码方案建议写明 code_system: phono_shape，
# 因为音码与形码特征并存时推断才判得出来，写明最稳妥
code_system: phono_shape
""")

                // 词库文件
                Divider().padding(.vertical, 2)
                Text("词库文件（.dict.yaml）")
                    .font(.callout.bold())
                Text("--- 和 ... 之间是文件头（声明列结构），... 之后是词条，每列用 Tab 分隔（下方示例为对齐展示用空格，真实文件列间必须写 Tab）：")
                    .font(.caption).foregroundColor(.secondary)
                CodeBlock("""
---
columns:
  - text
  - code
  - weight
  # 注释列，开启「候选注释」后显示在候选词上方
  - annotation
...
你好    nihao    1000    nǐ hǎo
世界    shijie   800     shì jiè
苹果    pingguo  600
""")

                // 方案包管理
                Divider().padding(.vertical, 2)
                Text("方案包文件管理")
                    .font(.callout.bold())
                Text("已安装的方案 zip 存放在「文件」App → 聿·输入法 → schemes，可直接分享给他人或删除（删除后 App 下次启动自动卸载对应方案）。")
                    .font(.caption).foregroundColor(.secondary)

                // 编译日志
                Divider().padding(.vertical, 2)
                Text("导入失败怎么排查")
                    .font(.callout.bold())
                Text("导入后可在「文件」App → 聿·输入法 → logs 里找到对应的日志文件（文件名：方案id_install_log.txt），里面记录了每个词库文件解析了多少条、哪些行被跳过及原因。")
                    .font(.caption).foregroundColor(.secondary)
                Text("常见原因：列之间用了空格而非 Tab；文件编码不是 UTF-8；--- 或 ... 行前后有多余空格；columns 顺序与数据列实际顺序不一致。")
                    .font(.caption).foregroundColor(.secondary).padding(.top, 2)
            }
            .padding(.vertical, 4)
        } header: {
            Text("方案包制作说明")
        }
    }

    // MARK: - 其他

    var moreSection: some View {
        Group {
            Section {
                HStack {
                    Text("开发者")
                    Spacer()
                    Text("OpenIME Team")
                        .foregroundColor(.secondary)
                }
                HStack {
                    Text("授权协议")
                    Spacer()
                    Text("GPL v3")
                        .foregroundColor(.secondary)
                }
                HStack {
                    Text("版权")
                    Spacer()
                    Text("© 2026 OpenIME Team")
                        .foregroundColor(.secondary)
                }
                HStack {
                    Text("QQ 交流群")
                    Spacer()
                    Text("1097191799")
                        .foregroundColor(.secondary)
                }
            } header: {
                Text("其他")
            } footer: {
                Text("本项目以 GNU GPL v3 协议开源：可免费使用、修改和分发，修改后的版本须同样开源并保留原始出处与版权声明。")
                    .font(.caption)
            }

            Section {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: "lock.shield")
                            .foregroundColor(.accentColor)
                        Text("完全本地运行，保护你的隐私")
                            .font(.body.bold())
                    }
                    Text("「聿·输入法」是免费开源的输入平台，支持导入用户自定义、符合本 App 词库格式要求的方案。所有输入内容、词库数据、用户设置均仅保存在本机，不访问网络，不收集、上传或分享用户信息。")
                        .font(.callout)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 4)
            } header: {
                Text("隐私声明")
            }
        }
    }
}

// MARK: - 辅助组件

struct InfoRow: View {
    let step: String
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(step)
                    .font(.caption.bold())
                    .foregroundColor(.white)
                    .frame(width: 20, height: 20)
                    .background(Color.accentColor)
                    .clipShape(Circle())
                Text(title)
                    .font(.body.bold())
            }
            Text(detail)
                .font(.callout)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
    }
}

struct FeatureRow: View {
    let title: String
    let detail: String

    // 不再配图标：找不到真正对得上的图形时，错配的图标比没图标更干扰阅读，标题加粗已足够分隔
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.body.bold())
            Text(detail).font(.callout).foregroundColor(.secondary)
        }
        .padding(.vertical, 2)
    }
}

struct ParamRow: View {
    let name: String
    let range: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(name).font(.body.bold())
                Spacer()
                Text(range)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            Text(detail).font(.callout).foregroundColor(.secondary)
        }
        .padding(.vertical, 2)
    }
}

struct CodeBlock: View {
    let code: String
    init(_ code: String) { self.code = code }

    var body: some View {
        Text(code)
            .font(.system(.caption, design: .monospaced))
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.systemGray6))
            .cornerRadius(8)
    }
}

// MARK: - 内置方案清单（运行时实测，避免文案写死后过时）
//
// 单一事实来源是各 .bundle 里的 manifest.yaml（name / description）+ 目录实测大小，
// About 页不另存一份方案名或体积文案：改词库、加/删内置方案都会自动跟随。
// manifest 标量读取与 IMERuntime.manifestField 同源口径（此处为展示层独立只读小工具）。
private struct BundledScheme: Identifiable {
    let id: String
    let name: String
    let detail: String
    let bytes: Int64
    var sizeText: String { BundledSchemeCatalog.sizeText(bytes) }
}

private enum BundledSchemeCatalog {
    /// 按体积从大到小排列（用户最关心谁占地方）；启动后首次进关于页时算一次
    static let schemes: [BundledScheme] = load()

    static var totalBytes: Int64 { schemes.reduce(0) { $0 + $1.bytes } }
    static var totalSizeText: String { sizeText(totalBytes) }

    static func sizeText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private static func load() -> [BundledScheme] {
        guard let root = Bundle.main.url(forResource: "BundledSchemes", withExtension: nil),
              let items = try? FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: [.isDirectoryKey])
        else { return [] }
        return items
            .filter { $0.pathExtension == "bundle" }
            .map { url -> BundledScheme in
                let fallback = url.deletingPathExtension().lastPathComponent
                return BundledScheme(
                    id: manifestField(of: url, key: "id") ?? fallback,
                    name: manifestField(of: url, key: "name") ?? fallback,
                    detail: manifestField(of: url, key: "description") ?? "",
                    bytes: directorySize(url))
            }
            .sorted { $0.bytes > $1.bytes }
    }

    /// manifest.yaml 里的标量字段（id / name / description；读不到返回 nil）
    private static func manifestField(of bundleURL: URL, key: String) -> String? {
        let url = bundleURL.appendingPathComponent("manifest.yaml")
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let prefix = key + ":"
        return content.components(separatedBy: .newlines).compactMap { line -> String? in
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix(prefix) else { return nil }
            return String(t.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        }.first
    }

    /// 目录内所有文件的逻辑大小之和（只读文件属性，不把内容读进内存）
    private static func directorySize(_ url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles])
        else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += Int64(size)
            }
        }
        return total
    }
}
