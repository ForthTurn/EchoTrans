#!/usr/bin/env bash
# 构建并打包 EchoTrans.app
#
# 优先使用 swiftc 直接编译（零依赖项目，无需 SwiftPM 解析 manifest）。
# 说明：某些 CommandLineTools 安装的 SwiftPM ManifestAPI 存在损坏问题，
# 导致 `swift build` 无法解析 Package.swift；本脚本不依赖它。
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"

echo "==> swiftc 编译 ($CONFIG)"
mkdir -p build/direct
SOURCES=$(find Sources/EchoTrans -name "*.swift" | sort)
if [ "$CONFIG" = "debug" ]; then
    swiftc -swift-version 5 -parse-as-library -g $SOURCES -o build/direct/EchoTrans
else
    swiftc -swift-version 5 -parse-as-library -O $SOURCES -o build/direct/EchoTrans
fi

BIN="build/direct/EchoTrans"
APP="build/EchoTrans.app"

echo "==> 组装 $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Support/Info.plist "$APP/Contents/Info.plist"
cp "$BIN" "$APP/Contents/MacOS/EchoTrans"

echo "==> ad-hoc 签名"
codesign --force -s - "$APP"

echo
echo "完成 ✅  $APP"
echo "运行: open \"$APP\""
