#!/usr/bin/env bash
# 构建并打包 EchoTrans.app（含本地转写引擎 whisper.cpp + sherpa-onnx）
#
# 用法:
#   ./scripts/make-app.sh [release|debug] [--no-models] [--download-models]
#
# 默认会把本机模型目录（~/Library/Application Support/EchoTrans/models）中
# 已存在的模型打包进 App（Contents/Resources/models）；--no-models 跳过；
# --download-models 在模型缺失时自动先执行 fetch-dependencies.sh --models。
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="release"
BUNDLE_MODELS=1
DOWNLOAD_MODELS=0
for arg in "$@"; do
    case "$arg" in
        release|debug) CONFIG="$arg" ;;
        --no-models) BUNDLE_MODELS=0 ;;
        --download-models) DOWNLOAD_MODELS=1 ;;
        *) echo "未知参数: $arg"; exit 1 ;;
    esac
done

MODELS_DIR="${HOME}/Library/Application Support/EchoTrans/models"
WHISPER_MODEL="ggml-large-v3-turbo.bin"
SV_MODEL="sensevoice/model.int8.onnx"
SV_TOKENS="sensevoice/tokens.txt"

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
SWIFT_FLAGS=(-swift-version 5 -parse-as-library $SOURCES build/direct/bridge.o \
    -import-objc-header Bridge/EchoTransBridge.h \
    -I vendor/whisper.cpp/include -I vendor/whisper.cpp/ggml/include -I vendor/sherpa-onnx/include \
    "${LINK_FLAGS[@]}" -o build/direct/EchoTrans)
if [ "$CONFIG" = "debug" ]; then
    swiftc -g "${SWIFT_FLAGS[@]}"
else
    swiftc -O "${SWIFT_FLAGS[@]}"
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

# ── 5. 内置模型 ────────────────────────────────────────────────────
if [ "$BUNDLE_MODELS" = 1 ]; then
    if [ "$DOWNLOAD_MODELS" = 1 ]; then
        MISSING=0
        [ -f "$MODELS_DIR/$WHISPER_MODEL" ] || MISSING=1
        [ -f "$MODELS_DIR/$SV_MODEL" ] || MISSING=1
        if [ "$MISSING" = 1 ]; then
            ./scripts/fetch-dependencies.sh --models
        fi
    fi
    echo "==> 打包内置模型"
    RES_MODELS="$APP/Contents/Resources/models"
    mkdir -p "$RES_MODELS/sensevoice"
    if [ -f "$MODELS_DIR/$WHISPER_MODEL" ]; then
        cp "$MODELS_DIR/$WHISPER_MODEL" "$RES_MODELS/"
        echo "    ✓ whisper large-v3-turbo"
    else
        echo "    ⚠️  缺少 whisper 模型（可用 --download-models 或 fetch-dependencies.sh --models 下载）"
    fi
    if [ -f "$MODELS_DIR/$SV_MODEL" ] && [ -f "$MODELS_DIR/$SV_TOKENS" ]; then
        cp "$MODELS_DIR/$SV_MODEL" "$MODELS_DIR/$SV_TOKENS" "$RES_MODELS/sensevoice/"
        echo "    ✓ sensevoice int8"
    else
        echo "    ⚠️  缺少 sensevoice 模型"
    fi
else
    echo "==> 跳过内置模型（--no-models）"
fi

# ── 6. ad-hoc 签名 ────────────────────────────────────────────────
echo "==> ad-hoc 签名"
codesign --force -s - "$APP/Contents/Frameworks/"*.dylib
codesign --force -s - "$APP"

echo
APP_SIZE=$(du -sh "$APP" | cut -f1)
echo "完成 ✅  $APP ($APP_SIZE)"
echo "运行: open \"$APP\""
echo "生成安装包: ./scripts/make-dmg.sh"
