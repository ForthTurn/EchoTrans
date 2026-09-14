#!/usr/bin/env bash
# 构建并打包 EchoTrans.app（含本地转写引擎 whisper.cpp + sherpa-onnx）
#
# 前置：./scripts/fetch-dependencies.sh（拉取 whisper.cpp 源码与 sherpa-onnx 预编译库）
# 本脚本会自动用 cmake 编译 whisper.cpp 静态库。
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
ROOT="$(pwd)"

if [ ! -d vendor/whisper.cpp ] || [ ! -d vendor/sherpa-onnx/lib ]; then
    echo "==> 缺少依赖，先执行 fetch-dependencies.sh"
    ./scripts/fetch-dependencies.sh
fi

# ── 1. whisper.cpp 静态库（Metal 嵌入，无外部依赖）────────────────────
if [ ! -f vendor/whisper-build/src/libwhisper.a ]; then
    echo "==> cmake 编译 whisper.cpp（首次约 1-3 分钟）"
    cmake -S vendor/whisper.cpp -B vendor/whisper-build \
        -DCMAKE_BUILD_TYPE=Release \
        -DBUILD_SHARED_LIBS=OFF \
        -DGGML_METAL_EMBED_LIBRARY=ON \
        -DWHISPER_BUILD_TESTS=OFF \
        -DWHISPER_BUILD_EXAMPLES=OFF \
        -DWHISPER_BUILD_SERVER=OFF > /dev/null
    cmake --build vendor/whisper-build -j "$(sysctl -n hw.ncpu)" > /dev/null
fi

# ── 2. C 桥接层 ─────────────────────────────────────────────────────
echo "==> 编译 C 桥接层"
mkdir -p build/direct
cc -c Bridge/EchoTransBridge.c -o build/direct/bridge.o \
    -I vendor/whisper.cpp/include \
    -I vendor/whisper.cpp/ggml/include \
    -I vendor/sherpa-onnx/include

# ── 3. Swift 主程序 ────────────────────────────────────────────────
echo "==> swiftc 编译主程序 ($CONFIG)"
SOURCES=$(find Sources/EchoTrans -name "*.swift" | sort)
LINK_FLAGS=(
    -L vendor/whisper-build/src
    -L vendor/whisper-build/ggml/src
    -L vendor/whisper-build/ggml/src/ggml-metal
    -L vendor/whisper-build/ggml/src/ggml-blas
    -L vendor/sherpa-onnx/lib
    -lwhisper -lggml -lggml-base -lggml-cpu -lggml-metal -lggml-blas
    -lsherpa-onnx-c-api -lc++
    -framework Accelerate -framework Metal -framework Foundation
    -Xlinker -rpath -Xlinker "@executable_path/../Frameworks"
)
if [ "$CONFIG" = "debug" ]; then
    swiftc -swift-version 5 -parse-as-library -g $SOURCES build/direct/bridge.o \
        -import-objc-header Bridge/EchoTransBridge.h \
        -I vendor/whisper.cpp/include -I vendor/whisper.cpp/ggml/include -I vendor/sherpa-onnx/include \
        "${LINK_FLAGS[@]}" -o build/direct/EchoTrans
else
    swiftc -swift-version 5 -parse-as-library -O $SOURCES build/direct/bridge.o \
        -import-objc-header Bridge/EchoTransBridge.h \
        -I vendor/whisper.cpp/include -I vendor/whisper.cpp/ggml/include -I vendor/sherpa-onnx/include \
        "${LINK_FLAGS[@]}" -o build/direct/EchoTrans
fi

# ── 4. 组装 .app ───────────────────────────────────────────────────
echo "==> 组装 build/EchoTrans.app"
APP="build/EchoTrans.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources"
cp Support/Info.plist "$APP/Contents/Info.plist"
cp build/direct/EchoTrans "$APP/Contents/MacOS/EchoTrans"

# sherpa-onnx / onnxruntime 动态库打进 Frameworks（install name 均为 @rpath）
cp vendor/sherpa-onnx/lib/*.dylib "$APP/Contents/Frameworks/"

echo "==> ad-hoc 签名"
codesign --force -s - "$APP/Contents/Frameworks/"*.dylib
codesign --force -s - "$APP"

echo
echo "完成 ✅  $APP"
echo "运行: open \"$APP\""
