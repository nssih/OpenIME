#!/bin/bash
# 启动 iOS 模拟器并运行 OpenIME
# 用法：bash scripts/run_simulator.sh [iPhone型号]
# 例：bash scripts/run_simulator.sh "iPhone 16"

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DEVICE_NAME="${1:-iPhone 16}"

BLUE='\033[0;34m'
GREEN='\033[0;32m'
NC='\033[0m'

info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[OK]${NC} $1"; }

# 找目标模拟器
info "查找模拟器：$DEVICE_NAME..."
SIM_ID=$(xcrun simctl list devices available 2>/dev/null \
    | grep "$DEVICE_NAME" \
    | head -1 \
    | grep -oE '[A-F0-9-]{36}')

if [ -z "$SIM_ID" ]; then
    info "未找到 '$DEVICE_NAME'，列出所有可用 iPhone 模拟器："
    xcrun simctl list devices available | grep "iPhone"
    echo ""
    echo "请用上面的设备名重新运行，例如："
    echo "  bash scripts/run_simulator.sh \"iPhone 15\""
    exit 1
fi

info "目标模拟器 ID：$SIM_ID"

# 启动模拟器
info "启动模拟器..."
xcrun simctl boot "$SIM_ID" 2>/dev/null || true
open -a Simulator

# 等待模拟器就绪
info "等待模拟器启动..."
for i in {1..30}; do
    STATE=$(xcrun simctl list devices 2>/dev/null | grep "$SIM_ID" | grep -oE "Booted|Shutdown")
    if [ "$STATE" = "Booted" ]; then
        break
    fi
    sleep 1
done
success "模拟器已启动"

# 编译并安装
info "编译 OpenIME（Debug）..."
xcodebuild build \
    -project "$PROJECT_DIR/OpenIME.xcodeproj" \
    -scheme OpenIME \
    -destination "id=$SIM_ID" \
    -configuration Debug \
    CODE_SIGN_IDENTITY="" \
    CODE_SIGNING_REQUIRED=NO \
    ONLY_ACTIVE_ARCH=YES \
    2>&1 | xcbeautify

# 找到编译产物
APP_PATH=$(find ~/Library/Developer/Xcode/DerivedData -name "OpenIME.app" \
    -path "*/Debug-iphonesimulator/*" 2>/dev/null | head -1)

if [ -z "$APP_PATH" ]; then
    echo "[ERROR] 未找到编译产物，请检查编译错误"
    exit 1
fi

# 安装到模拟器
info "安装到模拟器..."
xcrun simctl install "$SIM_ID" "$APP_PATH"
success "安装完成"

# 启动 App
info "启动 OpenIME..."
xcrun simctl launch "$SIM_ID" com.openime.app
success "OpenIME 已在模拟器中启动"

echo ""
echo "模拟器已运行，你可以："
echo "  • 在模拟器里操作，效果和真机完全一致"
echo "  • 修改代码后重新运行此脚本热更新"
echo "  • 要在真机测试，见 README「本地开发与真机测试」第五步（先在 Xcode 里配好自己的签名 Team）"
