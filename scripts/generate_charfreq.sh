#!/bin/bash
# 通用汉字字频表生成器
#
# 从内置雾凇拼音词库 8105.dict.yaml（《通用规范汉字表》8105 字，字频取自
# 北京语言大学「25 亿字语料汉字字频表」）提取「单字 → 字频」，按字频降序
# 生成 Shared/Models/CharFrequency.swift。
#
# 该 Swift 文件是编译期「零词频码表字频叠加」的唯一数据源（见 DictCompiler
# 的 overlayFrequency）。请勿手改生成结果；数据要变就改源词库后重跑本脚本。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/Packages/BundledSchemes/oime-ice-pinyin.bundle/dictionaries/8105.dict.yaml"
OUT="$ROOT/Shared/Models/CharFrequency.swift"

[ -f "$SRC" ] || { echo "缺少字频源：$SRC" >&2; exit 1; }

python3 - "$SRC" "$OUT" <<'PY'
import io, sys

src, out = sys.argv[1], sys.argv[2]
best, started = {}, False
for line in io.open(src, encoding="utf-8"):
    line = line.rstrip("\n")
    if line.strip() == "...":
        started = True
        continue
    if not started or not line or line.lstrip().startswith("#"):
        continue
    parts = line.split("\t")
    # 只收单字行（char \t pinyin \t weight）；多字 / 缺列 / 非数字权重一律跳过
    if len(parts) < 3 or len(parts[0]) != 1:
        continue
    try:
        weight = int(parts[2].strip())
    except ValueError:
        continue
    ch = parts[0]
    if ch not in best or weight > best[ch]:   # 多音字同字取最高频
        best[ch] = weight

order = [c for c, _ in sorted(best.items(), key=lambda kv: kv[1], reverse=True)]
text = "".join(order)

def esc(chunk):
    return chunk.replace("\\", "\\\\").replace('"', '\\"')

chunks = [esc(text[i:i + 48]) for i in range(0, len(text), 48)]
literal = " +\n        ".join('"%s"' % c for c in chunks)

template = '''// CharFrequency.swift —— 通用汉字字频表（自动生成，请勿手改）
//
// 由 scripts/generate_charfreq.sh 从内置雾凇拼音词库
// Packages/BundledSchemes/oime-ice-pinyin.bundle/dictionaries/8105.dict.yaml 提取：
// 该表是《通用规范汉字表》8105 字，字频取自「25 亿字语料汉字字频表」（北京语言大学）。
// order 按字频从高到低排列，名次即索引；score(of:) = 表长 - 名次，越大越常用。
//
// 用途：形码 / 音形码码表（如超强快码 cqkm）常全库 weight 恒定、词频毫无区分度，
// 运行时 top-N 会退化成按编码字母序，常用字被大量长码冷门字挤出候选。
// 编译期用这张表给「零词频码表」叠加真实字频，让常用字（好、的、是…）靠前。
// 只服务于零词频码表：拼音 / 双拼、以及自带真实权重的码表（虎码）都不查这张表。

import Foundation

public enum CharFrequency {

    /// 按语料字频降序排列的汉字，索引即名次（0 = 最常用）
    static let order: String =
        __ORDER__

    private static let rank: [Character: Int] = {
        var dict = [Character: Int](minimumCapacity: order.count)
        for (index, char) in order.enumerated() where dict[char] == nil {
            dict[char] = index
        }
        return dict
    }()

    /// 收录的字数
    public static var count: Int { order.count }

    /// 字频表是否为空（生成失败时的防御：为空则编译期不叠加，逐字节保持原样）
    public static var isEmpty: Bool { order.isEmpty }

    /// 常用度打分：命中返回 1...count（越大越常用），未收录返回 0
    public static func score(of char: Character) -> Int {
        guard let r = rank[char] else { return 0 }
        return count - r
    }
}
'''

io.open(out, "w", encoding="utf-8").write(template.replace("__ORDER__", literal))
print("生成 %s：%d 字，最高频「%s」，末位「%s」"
      % (out, len(order), order[0] if order else "?", order[-1] if order else "?"))
PY
