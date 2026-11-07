#!/usr/bin/env python3
# 生成内置形码方案包：虎码（oime-tiger）与超强快码（oime-cqkm）。
#
# 为什么需要这个脚本：内置包里的词库不是上游原生文件的逐字节拷贝，而是按 OpenIME 的
# 收录规则做过三处归一（都是「不改变词条语义」的格式层处理）：
#   1. 去 BOM、CRLF → LF。DictCompiler 已在解析入口容忍 CRLF，但内置包作为长期资产
#      保持 LF 更干净，也避免任何老读取路径踩行尾。
#   2. 超强快码的 extended 表只保留头部（encoder 派生规则），删掉原生自带的
#      demo 示例行（春眠不觉晓 / date / addr / mail / tel），否则它们会变成真候选。
#   3. 同上表原生的 exclude_patterns（'^[iuv].*$|[ao]$'）整段不采用：
#      - '[ao]$' 那半条在上游实现里挂在 encoder 下只约束「派生码」（该表无无码行、派生为 0），
#        而 OpenIME 的 exclude_patterns 是全局过滤，照搬会把 4709 条以 a/o 结尾的合法快码杀掉；
#      - '^[iuv].*$' 那半条滤掉的不是垃圾，而是快码的几项正式功能：I/U/V 三个一级简码
#        （以/有/这）、U 键特简 17 个、V 键引导符号（VA=～ VQ=‰ VS=运算符号…），
#        以及 i 引导的临时拼音与形码反查（i+全形 IUDB、i+全拼 IRUI，共 2 万余条，
#        注释列 stem 就是反查出来的形码）。上游靠 reverse_lookup_translator /
#        recognizer 分层把它们与主码表隔开，OpenIME 没有那套分层，让条目进主码表
#        走前缀直查是这些功能可用的唯一途径；i/u/v 都不是快码的合法声母首码，
#        进主码表不会污染正常输入。
#
# 收录范围（一个不拉）：
#   虎码   = tiger.dict.yaml（单字全码 + 一/二/三简）+ tigress_ci.dict.yaml（词组）
#            + tigress_simp_ci.dict.yaml（简词）
#   快码   = cqkm_cm.dict.yaml（单字 + 词组全码）+ cqkm_cm.extended.dict.yaml（头部规则）
#
# 用法：python3 scripts/prepare_bundled_shape_schemes.py <虎码目录> <快码 SharedSupport 目录>
# 两个上游包的本机位置不写进仓库（各人下载位置不同，且绝对路径含用户名），必须传参。

import os
import sys
import shutil

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "Packages", "BundledSchemes")

if len(sys.argv) < 3:
    sys.exit("用法：prepare_bundled_shape_schemes.py <虎码目录> <快码 SharedSupport 目录>")
TIGER_SRC = sys.argv[1]
CQKM_SRC = sys.argv[2]

# 内置词库文件头署名：让词库文件自身也带上作者信息（与 README「内置词库来源与署名」一致）。
# 以 # 注释形式加在头部，DictHeaderParser 会跳过 # 行，不影响解析。
_TIGER_ATTR = (
    "# 作者 / 来源：虎码团队（https://tiger-code.com）\n"
    "# OpenIME 仅内置其词库数据（经作者许可），按收录规则做格式归一，未改动词条语义。\n"
)
TIGER_HEADERS = {
    "tiger.dict.yaml":          "# 虎码（Tiger）形码输入方案 · 词库\n" + _TIGER_ATTR,
    "tigress_ci.dict.yaml":     "# 虎码（Tiger）形码输入方案 · 官方词组表\n" + _TIGER_ATTR,
    "tigress_simp_ci.dict.yaml": "# 虎码（Tiger）形码输入方案 · 简词表\n" + _TIGER_ATTR,
}
CQKM_EXTENDED_HEADER = (
    "# 超强快码 · extended 派生规则表（encoder）\n"
    "# 著作权人：付东升【辽宁中医药大学附属第二医院】\n"
    "# OpenIME 仅内置其词库数据（经作者许可）；本表只保留 encoder 派生规则，原生 demo 示例行已删。\n"
)


def normalize(text: str) -> str:
    if text.startswith("\ufeff"):
        text = text[1:]
    text = text.replace("\r\n", "\n").replace("\r", "\n")
    if not text.endswith("\n"):
        text += "\n"
    return text


def read(path: str) -> str:
    with open(path, encoding="utf-8") as f:
        return normalize(f.read())


def data_rows(text: str) -> int:
    n = 0
    seen = False
    for line in text.split("\n"):
        if line.strip() == "...":
            seen = True
            continue
        if not seen:
            continue
        if line and not line.startswith("#") and "\t" in line:
            n += 1
    return n


def copy_table(src: str, dst: str, header: str = "") -> int:
    text = read(src)
    if header:
        text = header + text
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    with open(dst, "w", encoding="utf-8") as f:
        f.write(text)
    return data_rows(text)


def write_cqkm_extended(src: str, dst: str) -> int:
    """只保留头部规则：删 demo 数据行 + 删掉原生的 exclude_patterns（见文件头注释）。"""
    text = read(src)
    head, _, _ = text.partition("...\n")
    head = head + "...\n"
    old = "  exclude_patterns:\n    - '^[iuv].*$|[ao]$'\n"
    assert old in head, "快码 extended 的 exclude_patterns 写法变了，请人工确认后更新脚本"
    head = head.replace(old, "")
    head = CQKM_EXTENDED_HEADER + head
    head += (
        "# OpenIME 内置归一：原生 demo 示例行（诗句 / date / addr / mail / tel）已删除，\n"
        "# 否则它们会作为真候选进入词库；原生的 exclude_patterns（'^[iuv].*$|[ao]$'）整段不采用，\n"
        "# 理由见 scripts/prepare_bundled_shape_schemes.py 头注。\n"
    )
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    with open(dst, "w", encoding="utf-8") as f:
        f.write(head)
    return 0


def write(path: str, content: str) -> None:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        f.write(content)


def build_tiger() -> None:
    bundle = os.path.join(OUT, "oime-tiger.bundle")
    shutil.rmtree(bundle, ignore_errors=True)
    total = 0
    for name in ("tiger.dict.yaml", "tigress_ci.dict.yaml", "tigress_simp_ci.dict.yaml"):
        total += copy_table(os.path.join(TIGER_SRC, name),
                            os.path.join(bundle, "dictionaries", name),
                            header=TIGER_HEADERS[name])
    write(os.path.join(bundle, "manifest.yaml"),
          "id: oime-tiger\n"
          "name: 虎码\n"
          "version: 2026.08.14\n"
          "author: 虎码团队 / 聿·输入法 移植\n"
          "description: 虎码形码输入方案：单字全码表（含一/二/三简）+ 官方词组表 + 简词表，开箱即用\n")
    write(os.path.join(bundle, "schema.yaml"),
          "type: direct\n"
          "max_code_length: 4\n"
          "auto_select: false\n"
          "enable_sentence: false\n"
          "code_system: shape\n")
    print(f"[ok] oime-tiger  词条 {total}")


def build_cqkm() -> None:
    bundle = os.path.join(OUT, "oime-cqkm.bundle")
    shutil.rmtree(bundle, ignore_errors=True)
    total = copy_table(os.path.join(CQKM_SRC, "cqkm_cm.dict.yaml"),
                       os.path.join(bundle, "dictionaries", "cqkm_cm.dict.yaml"))
    write_cqkm_extended(os.path.join(CQKM_SRC, "cqkm_cm.extended.dict.yaml"),
                        os.path.join(bundle, "dictionaries", "cqkm_cm.extended.dict.yaml"))
    write(os.path.join(bundle, "manifest.yaml"),
          "id: oime-cqkm\n"
          "name: 超强快码\n"
          "version: 9.5.1\n"
          "author: 付东升 / 聿·输入法 移植\n"
          "description: 超强快码音形输入方案：单字与词组全码表，开箱即用\n")
    write(os.path.join(bundle, "schema.yaml"),
          "type: direct\n"
          "max_code_length: 4\n"
          "auto_select: true\n"
          "auto_clear: max_length\n"
          "enable_sentence: false\n"
          "code_system: phono_shape\n")
    print(f"[ok] oime-cqkm  词条 {total}")


if __name__ == "__main__":
    build_tiger()
    build_cqkm()
    print(f"[done] 内置包已写入 {OUT}")
