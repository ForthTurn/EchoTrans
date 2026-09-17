#!/usr/bin/env bash
# 生成拖拽安装的 DMG 安装包（EchoTrans.app + /Applications 软链）
#
# 用法:
#   ./scripts/make-dmg.sh
#   依赖 build/EchoTrans.app；不存在时会自动调用 make-app.sh 构建。
set -euo pipefail
cd "$(dirname "$0")/.."

if [ ! -d build/EchoTrans.app ]; then
    echo "==> 未找到 build/EchoTrans.app，先构建"
    ./scripts/make-app.sh "$@"
fi

APP="build/EchoTrans.app"
if [ -d "$APP/Contents/Resources/models" ]; then
    echo "错误：当前 App 包含本地模型。发布 DMG 默认不应内置模型；请先运行 ./scripts/make-app.sh release 再生成 DMG。" >&2
    exit 1
fi
VER=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
DMG="build/EchoTrans-$VER.dmg"

STAGING=$(mktemp -d)
trap 'rm -rf "$STAGING"' EXIT

echo "==> 拷贝 App 到暂存目录"
ditto "$APP" "$STAGING/EchoTrans.app"
ln -s /Applications "$STAGING/Applications"

echo "==> 生成 DMG（轻量安装包，模型由用户在 App 设置中下载）"
rm -f "$DMG"
hdiutil create -volname "EchoTrans $VER" \
    -srcfolder "$STAGING" \
    -format ULMO \
    -ov \
    "$DMG" > /dev/null

SIZE=$(du -h "$DMG" | cut -f1)
echo
echo "完成 ✅  $DMG ($SIZE)"
echo "分发: 把 DMG 发给别人，双击打开后把 EchoTrans 拖进 Applications 即可"
