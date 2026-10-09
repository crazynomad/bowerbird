#!/bin/bash
# 构建并签名 build/Bowerbird.app。
#   --install  安装到 /Applications 并重新启动（日常使用：开机自动启动登记的是 App 所在路径）
#   --release  构建 Apple 芯片 + Intel 通用版本，打包为 dist/Bowerbird-<版本>.zip
# 必须用固定证书签名：辅助功能权限绑定签名身份，临时签名每次重编译都会失效。
set -euo pipefail
cd "$(dirname "$0")/.."

IDENTITY="${CODESIGN_IDENTITY:-Apple Development}"
APP=build/Bowerbird.app
MODE="${1:-}"

if [[ "$MODE" == "--release" ]]; then
    swift build -c release --arch arm64 --arch x86_64
    BINARY=.build/apple/Products/Release/Bowerbird
else
    swift build -c release
    BINARY=.build/release/Bowerbird
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BINARY" "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"
codesign --force --sign "$IDENTITY" "$APP"
echo "✓ ${APP}（签名：${IDENTITY}，架构：$(lipo -archs "$APP/Contents/MacOS/Bowerbird")）"

case "$MODE" in
--install)
    pkill -x Bowerbird || true
    rm -rf /Applications/Bowerbird.app
    cp -R "$APP" /Applications/
    open /Applications/Bowerbird.app
    echo "✓ 已安装到 /Applications/Bowerbird.app 并启动"
    ;;
--release)
    VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
    ZIP="dist/Bowerbird-${VERSION}.zip"
    mkdir -p dist
    rm -f "$ZIP"
    # ditto 保留签名所需的扩展属性，比 zip 命令可靠
    ditto -c -k --keepParent "$APP" "$ZIP"
    echo "✓ ${ZIP}"
    shasum -a 256 "$ZIP"
    ;;
esac
