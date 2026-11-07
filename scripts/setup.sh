#!/bin/bash
# OpenIME 开发环境一键初始化脚本
# Xcode 安装完成后运行：bash scripts/setup.sh

set -e

BLUE='\033[0;34m'
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[OK]${NC} $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
error()   { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

echo ""
echo "=========================================="
echo "  OpenIME 开发环境初始化"
echo "=========================================="
echo ""

# 1. 检查 Xcode
info "检查 Xcode..."
if ! xcode-select -p 2>/dev/null | grep -q "Xcode"; then
    error "未检测到 Xcode。请先从 App Store 安装 Xcode，然后再运行此脚本。"
fi
XCODE_VER=$(xcodebuild -version 2>/dev/null | head -1)
success "Xcode 已安装：$XCODE_VER"

# 2. 接受 Xcode 许可
info "接受 Xcode 许可协议..."
sudo xcodebuild -license accept 2>/dev/null || true
success "许可协议已接受"

# 3. 安装 iOS 模拟器运行时（如未安装）
info "检查 iOS 模拟器运行时..."
AVAILABLE=$(xcrun simctl list runtimes 2>/dev/null | grep "iOS" | head -1)
if [ -z "$AVAILABLE" ]; then
    info "正在下载 iOS 模拟器运行时（约 5GB，请耐心等待）..."
    xcodebuild -downloadPlatform iOS 2>&1 | grep -E "Download|Progress|Complete" || true
else
    success "iOS 模拟器已可用：$AVAILABLE"
fi

# 4. 切换 xcode-select 到完整 Xcode
info "配置开发者工具路径..."
XCODE_APP=$(ls /Applications/ | grep "Xcode" | head -1)
if [ -n "$XCODE_APP" ]; then
    sudo xcode-select -s "/Applications/$XCODE_APP/Contents/Developer"
    success "开发者路径已设置为 /Applications/$XCODE_APP"
fi

# 5. 创建 Xcode 项目
info "生成 Xcode 项目..."
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
bash "$SCRIPT_DIR/generate_project.sh" "$PROJECT_DIR"
success "Xcode 项目已生成"

# 6. 解析依赖
info "解析 Swift Package 依赖..."
cd "$PROJECT_DIR"
xcodebuild -resolvePackageDependencies \
    -project OpenIME.xcodeproj \
    -scheme OpenIME 2>&1 | grep -E "Fetching|Resolved|error:" || true
success "依赖解析完成"

# 7. 下载雾凇词库
info "下载雾凇拼音词库..."
bash "$SCRIPT_DIR/fetch_ice_dict.sh" "$PROJECT_DIR"
success "雾凇词库已就绪"

# 8. 首次编译验证
info "编译验证（模拟器）..."
SIMULATOR_ID=$(xcrun simctl list devices available 2>/dev/null | grep "iPhone 16" | head -1 | grep -oE '[A-F0-9-]{36}')
if [ -z "$SIMULATOR_ID" ]; then
    SIMULATOR_ID=$(xcrun simctl list devices available 2>/dev/null | grep "iPhone" | head -1 | grep -oE '[A-F0-9-]{36}')
fi

if [ -n "$SIMULATOR_ID" ]; then
    xcodebuild build \
        -project "$PROJECT_DIR/OpenIME.xcodeproj" \
        -scheme OpenIME \
        -destination "id=$SIMULATOR_ID" \
        -configuration Debug \
        CODE_SIGN_IDENTITY="" \
        CODE_SIGNING_REQUIRED=NO \
        2>&1 | xcbeautify
    success "编译成功"
else
    warn "未找到可用模拟器，跳过编译验证"
fi

echo ""
echo "=========================================="
success "初始化完成！"
echo ""
echo "接下来运行模拟器："
echo "  bash scripts/run_simulator.sh"
echo "=========================================="
