#!/bin/bash
# 生成 Xcode 项目（xcodeproj）
#
# 工程配置的唯一真相是仓库根目录的 project.yml，本脚本只负责「装 xcodegen + 跑生成」，
# 不再内嵌任何 YAML 副本，避免出现两份配置互相覆盖（历史上内嵌副本过时，
# 跑一次就会丢掉 OpenIMEShare / OpenIMETests 两个 Target）。

set -e

PROJECT_DIR="${1:-$(pwd)}"
cd "$PROJECT_DIR"

# 安装 xcodegen（如未安装）
if ! which xcodegen &>/dev/null; then
    echo "[INFO] 安装 xcodegen..."
    brew install xcodegen
fi

# 校验工程配置存在（缺失说明不是在仓库根目录运行）
if [ ! -f "$PROJECT_DIR/project.yml" ]; then
    echo "[ERROR] 未找到 $PROJECT_DIR/project.yml，请在仓库根目录运行本脚本。"
    exit 1
fi

echo "[INFO] 运行 xcodegen 生成项目..."
xcodegen generate --spec "$PROJECT_DIR/project.yml" --project "$PROJECT_DIR"
echo "[OK] OpenIME.xcodeproj 已生成"
