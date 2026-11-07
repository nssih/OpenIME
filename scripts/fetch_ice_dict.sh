#!/bin/bash
# 下载雾凇拼音词库并放入内置方案包目录。
#
# 上游仓库名与其 zip 解压出的目录名是外部事实（下载 URL 和路径必须照写才拉得下来），
# 本脚本只取用 cn_dicts/ 下的词库数据，不引入上游的方案配置文件。

PROJECT_DIR="${1:-$(pwd)}"
DICT_DIR="$PROJECT_DIR/Packages/BundledSchemes/oime-ice-pinyin.bundle/dictionaries"
DICT_URL="https://github.com/iDvel/rime-ice/archive/refs/heads/main.zip"
TEMP_ZIP="/tmp/ice-dict-main.zip"
# 解压目录名由上游 zip 内部结构决定，不是可自定义的名字
TEMP_DIR="/tmp/ice-dict-extract"
EXTRACTED="$TEMP_DIR/rime-ice-main"

mkdir -p "$DICT_DIR"

# 如果词库已存在就跳过
if ls "$DICT_DIR"/*.yaml 2>/dev/null | head -1 | grep -q yaml; then
    echo "[OK] 词库已存在，跳过下载"
    exit 0
fi

echo "[INFO] 正在下载雾凇词库（约 30MB）..."
# 用 aria2c 多线程加速下载
if which aria2c &>/dev/null; then
    aria2c -x 8 -s 8 -o "$TEMP_ZIP" "$DICT_URL"
else
    curl -L -o "$TEMP_ZIP" "$DICT_URL"
fi

echo "[INFO] 解压词库..."
rm -rf "$TEMP_DIR"
mkdir -p "$TEMP_DIR"
unzip -q "$TEMP_ZIP" -d "$TEMP_DIR"

# 只复制内置包实际收录的三张表（其余方案配置文件不要）
DICT_FILES=(
    "cn_dicts/8105.dict.yaml"
    "cn_dicts/base.dict.yaml"
    "cn_dicts/others.dict.yaml"
)

echo "[INFO] 复制词库文件..."
for f in "${DICT_FILES[@]}"; do
    src="$EXTRACTED/$f"
    if [ -f "$src" ]; then
        cp "$src" "$DICT_DIR/$(basename $f)"
        echo "  ✓ $(basename $f)"
    fi
done

# 如果上面的路径不对，尝试直接找所有 dict.yaml（排除其它码制的表）
if ! ls "$DICT_DIR"/*.yaml 2>/dev/null | grep -q yaml; then
    echo "[INFO] 尝试备用路径..."
    find "$EXTRACTED" -name "*.dict.yaml" | grep -v "luna\|stroke\|cangjie\|wubi\|wugniu\|jyut" | while read f; do
        cp "$f" "$DICT_DIR/$(basename $f)"
        echo "  ✓ $(basename $f)"
    done
fi

# 清理
rm -rf "$TEMP_ZIP" "$TEMP_DIR"

COUNT=$(ls "$DICT_DIR"/*.yaml 2>/dev/null | wc -l | tr -d ' ')
echo "[OK] 词库下载完成，共 $COUNT 个文件"
