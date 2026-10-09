#!/bin/bash
# 构建并签名 build/Bowerbird.app。
# 必须用固定证书签名：辅助功能权限绑定签名身份，临时签名每次重编译都会失效。
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
