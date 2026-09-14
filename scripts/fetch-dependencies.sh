#!/usr/bin/env bash
# 拉取本地转写引擎依赖：
#   - whisper.cpp  v1.8.7      （源码，随后由 make-app.sh 用 cmake 编译为静态库）
#   - sherpa-onnx  v1.13.8     （官方预编译动态库，含 onnxruntime）
# 同时可下载模型：./fetch-dependencies.sh --models
set -euo pipefail
cd "$(dirname "$0")/.."

WHISPER_TAG="v1.8.7"
SHERPA_TAG="v1.13.8"
SHERPA_LIB_PKG="sherpa-onnx-${SHERPA_TAG}-osx-arm64-shared-no-tts-lib.tar.bz2"
SENSEVOICE_MODEL="sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2025-09-09.tar.bz2"
WHISPER_MODEL="ggml-large-v3-turbo.bin"

# HuggingFace 镜像：国内网络可 export HF_ENDPOINT=https://hf-mirror.com
HF_ENDPOINT="${HF_ENDPOINT:-https://huggingface.co}"

mkdir -p vendor

echo "==> [1/2] whisper.cpp ${WHISPER_TAG}"
if [ ! -d vendor/whisper.cpp ]; then
    git clone --depth 1 --branch "${WHISPER_TAG}" https://github.com/ggml-org/whisper.cpp vendor/whisper.cpp
else
    echo "    已存在，跳过"
fi

echo "==> [2/2] sherpa-onnx ${SHERPA_TAG} 预编译库"
if [ ! -d vendor/sherpa-onnx/lib ]; then
    TMP=$(mktemp -d)
    curl -L --fail -o "${TMP}/${SHERPA_LIB_PKG}" \
        "https://github.com/k2-fsa/sherpa-onnx/releases/download/${SHERPA_TAG}/${SHERPA_LIB_PKG}"
    mkdir -p vendor/sherpa-onnx
    tar -xjf "${TMP}/${SHERPA_LIB_PKG}" -C "${TMP}"
    # 把包内 lib/ 与 include/ 拷入 vendor/sherpa-onnx
    SRC_DIR=$(find "${TMP}" -maxdepth 2 -type d -name lib | head -1)
    ROOT_DIR=$(dirname "${SRC_DIR}")
    cp -R "${ROOT_DIR}/lib" vendor/sherpa-onnx/lib
    # 预编译包不含头文件，从源码仓库拉取同版本 c-api.h
    mkdir -p vendor/sherpa-onnx/include/sherpa-onnx/c-api
    curl -L --fail -o vendor/sherpa-onnx/include/sherpa-onnx/c-api/c-api.h \
        "https://raw.githubusercontent.com/k2-fsa/sherpa-onnx/${SHERPA_TAG}/sherpa-onnx/c-api/c-api.h"
    rm -rf "${TMP}"
    ls vendor/sherpa-onnx/lib | head -20
else
    echo "    已存在，跳过"
fi

if [ "${1:-}" = "--models" ]; then
    MODELS_DIR="${HOME}/Library/Application Support/EchoTrans/models"
    mkdir -p "${MODELS_DIR}/sensevoice"
    echo "==> 模型目录: ${MODELS_DIR}"

    echo "==> [模型] whisper ${WHISPER_MODEL} (~1.6GB)"
    if [ ! -f "${MODELS_DIR}/${WHISPER_MODEL}" ]; then
        curl -L --fail --progress-bar \
            -o "${MODELS_DIR}/${WHISPER_MODEL}" \
            "${HF_ENDPOINT}/ggerganov/whisper.cpp/resolve/main/${WHISPER_MODEL}"
    else
        echo "    已存在，跳过"
    fi

    echo "==> [模型] sensevoice int8 (~230MB)"
    if [ ! -f "${MODELS_DIR}/sensevoice/model.int8.onnx" ]; then
        TMP=$(mktemp -d)
        curl -L --fail --progress-bar \
            -o "${TMP}/${SENSEVOICE_MODEL}" \
            "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/${SENSEVOICE_MODEL}"
        tar -xjf "${TMP}/${SENSEVOICE_MODEL}" -C "${TMP}"
        PKG_DIR=$(find "${TMP}" -maxdepth 1 -type d -name "sherpa-onnx-sense-voice*" | head -1)
        cp "${PKG_DIR}/model.int8.onnx" "${MODELS_DIR}/sensevoice/model.int8.onnx"
        cp "${PKG_DIR}/tokens.txt" "${MODELS_DIR}/sensevoice/tokens.txt"
        rm -rf "${TMP}"
    else
        echo "    已存在，跳过"
    fi
    echo "==> 模型就绪 ✅"
fi

echo "==> 依赖就绪 ✅"
