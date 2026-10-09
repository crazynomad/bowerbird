#!/bin/bash
# 构建并签名 build/Bowerbird.app；加 --install 则安装到 /Applications 并重新启动。
# 必须用固定证书签名：辅助功能权限绑定签名身份，临时签名每次重编译都会失效。
# 开机自动启动登记的是 App 所在路径，日常使用应从 /Applications 运行。
set -euo pipefail
cd "$(dirname "$0")/.."

IDENTITY="${CODESIGN_IDENTITY:-Apple Development}"
APP=build/Bowerbird.app

swift build -c release
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/Bowerbird "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"
codesign --force --sign "$IDENTITY" "$APP"
echo "✓ ${APP}（签名：${IDENTITY}）"

if [[ "${1:-}" == "--install" ]]; then
    pkill -x Bowerbird || true
    rm -rf /Applications/Bowerbird.app
    cp -R "$APP" /Applications/
    open /Applications/Bowerbird.app
    echo "✓ 已安装到 /Applications/Bowerbird.app 并启动"
fi
