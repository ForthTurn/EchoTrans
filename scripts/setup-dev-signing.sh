#!/usr/bin/env bash
# 创建并导入自签名开发证书（稳定签名身份）
#
# 作用：ad-hoc 签名每次重编译都会变，macOS 会把新版当"新 App"，
# 导致屏幕录制等授权反复失效。使用固定的自签名证书后，
# 授权跨构建版本保持有效（重编译后无需再授权）。
set -euo pipefail
cd "$(dirname "$0")/.."

IDENTITY="EchoTrans Dev"
DIR="Support/signing"
mkdir -p "$DIR"

if security find-identity -v -p codesigning 2>/dev/null | grep -q "${IDENTITY}"; then
    echo "证书已存在: ${IDENTITY} OK"
    exit 0
fi

command -v openssl > /dev/null || { echo "缺少 openssl"; exit 1; }

echo "==> 生成自签名代码签名证书（${IDENTITY}，10 年有效期）"
openssl req -x509 -newkey rsa:2048 \
    -keyout "${DIR}/dev.key" -out "${DIR}/dev.crt" \
    -days 3650 -nodes \
    -subj "/CN=${IDENTITY}" \
    -addext "keyUsage=digitalSignature" \
    -addext "extendedKeyUsage=codeSigning" 2>/dev/null

openssl pkcs12 -export -legacy \
    -out "${DIR}/dev.p12" \
    -inkey "${DIR}/dev.key" -in "${DIR}/dev.crt" \
    -passout pass:echotrans-dev

echo "==> 导入登录钥匙串"
security import "${DIR}/dev.p12" \
    -k "${HOME}/Library/Keychains/login.keychain-db" \
    -P echotrans-dev \
    -T /usr/bin/codesign

# 清理中间文件（证书已在钥匙串中）
rm -f "${DIR}/dev.key" "${DIR}/dev.crt" "${DIR}/dev.p12"

echo
echo "完成 OK 之后 make-app.sh 会自动用该证书签名。"
echo "若首次签名时系统弹窗询问钥匙串访问权限，请点「始终允许」。"
