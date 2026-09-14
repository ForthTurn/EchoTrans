#!/usr/bin/env bash
# 本地转写引擎 CLI 冒烟测试：不启动 GUI，直接用测试 WAV 验证 Whisper / SenseVoice 桥接
# 用法: ./scripts/test-engines.sh [wav文件]  （默认用 whisper.cpp 自带的 jfk.wav，11s 英文）
set -euo pipefail
cd "$(dirname "$0")/.."

WAV="${1:-vendor/whisper.cpp/samples/jfk.wav}"
ROOT="$(pwd)"
MODELS_DIR="${HOME}/Library/Application Support/EchoTrans/models"
mkdir -p build/test build/test-models

# ── 1. 依赖与静态库 ────────────────────────────────────────────────
if [ ! -d vendor/whisper.cpp ] || [ ! -d vendor/sherpa-onnx/lib ]; then
    ./scripts/fetch-dependencies.sh
fi
if [ ! -f vendor/whisper-build/src/libwhisper.a ]; then
    cmake -S vendor/whisper.cpp -B vendor/whisper-build \
        -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF \
        -DGGML_METAL_EMBED_LIBRARY=ON -DWHISPER_BUILD_TESTS=OFF \
        -DWHISPER_BUILD_EXAMPLES=OFF -DWHISPER_BUILD_SERVER=OFF > /dev/null
    cmake --build vendor/whisper-build -j "$(sysctl -n hw.ncpu)" > /dev/null
fi

# ── 2. 测试模型（whisper 用小体积 base；sensevoice 用正式 int8 模型）──
BASE_MODEL="build/test-models/ggml-base.bin"
if [ ! -f "$BASE_MODEL" ]; then
    echo "==> 下载 whisper base 测试模型 (~148MB)"
    HF_ENDPOINT="${HF_ENDPOINT:-https://huggingface.co}"
    curl -L --fail --progress-bar -o "$BASE_MODEL" \
        "${HF_ENDPOINT}/ggerganov/whisper.cpp/resolve/main/ggml-base.bin"
fi
if [ ! -f "$MODELS_DIR/sensevoice/model.int8.onnx" ]; then
    echo "==> 下载 sensevoice int8 模型 (~230MB)"
    TMP=$(mktemp -d)
    curl -L --fail --progress-bar -o "$TMP/sv.tar.bz2" \
        "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2025-09-09.tar.bz2"
    tar -xjf "$TMP/sv.tar.bz2" -C "$TMP"
    PKG=$(find "$TMP" -maxdepth 1 -type d -name "sherpa-onnx-sense-voice*" | head -1)
    mkdir -p "$MODELS_DIR/sensevoice"
    cp "$PKG/model.int8.onnx" "$MODELS_DIR/sensevoice/model.int8.onnx"
    cp "$PKG/tokens.txt" "$MODELS_DIR/sensevoice/tokens.txt"
    rm -rf "$TMP"
fi

# ── 3. 编译 CLI ────────────────────────────────────────────────────
echo "==> 编译 enginetest"
cc -c Bridge/EchoTransBridge.c -o build/test/bridge.o \
    -I vendor/whisper.cpp/include -I vendor/whisper.cpp/ggml/include -I vendor/sherpa-onnx/include
swiftc -swift-version 5 Tests/EngineCLITest/main.swift build/test/bridge.o -o build/test/enginetest \
    -import-objc-header Bridge/EchoTransBridge.h \
    -I vendor/whisper.cpp/include -I vendor/whisper.cpp/ggml/include -I vendor/sherpa-onnx/include \
    -L vendor/whisper-build/src -L vendor/whisper-build/ggml/src \
    -L vendor/whisper-build/ggml/src/ggml-metal -L vendor/whisper-build/ggml/src/ggml-blas \
    -L vendor/sherpa-onnx/lib \
    -lwhisper -lggml -lggml-base -lggml-cpu -lggml-metal -lggml-blas -lsherpa-onnx-c-api -lc++ \
    -framework Accelerate -framework Metal -framework Foundation \
    -Xlinker -rpath -Xlinker "$ROOT/vendor/sherpa-onnx/lib"

# ── 4. 运行 ────────────────────────────────────────────────────────
echo "===== [1/2] Whisper ====="
./build/test/enginetest whisper "$BASE_MODEL" - "$WAV"
echo
echo "===== [2/2] SenseVoice ====="
./build/test/enginetest sensevoice \
    "$MODELS_DIR/sensevoice/model.int8.onnx" "$MODELS_DIR/sensevoice/tokens.txt" "$WAV"
