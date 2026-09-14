#!/usr/bin/env bash
# 创建并导入稳定的本地开发签名证书。
# 正式分发仍应使用 Apple Developer ID；该证书仅用于本机开发，
# 目的是让 macOS TCC 屏幕录制授权跨本地重编译保持稳定。
set -euo pipefail
cd "$(dirname "$0")/.."

IDENTITY="EchoTrans Dev"
P12_PASSWORD="EchoTransDevLocal"
KEYCHAIN="${HOME}/Library/Keychains/login.keychain-db"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

if security find-identity -v -p codesigning "${KEYCHAIN}" 2>/dev/null | grep -q "${IDENTITY}"; then
    echo "可用开发签名已存在: ${IDENTITY}"
    exit 0
fi

# 清理此前导入但不可用的同名证书
security delete-certificate -c "${IDENTITY}" "${KEYCHAIN}" >/dev/null 2>&1 || true

cat > "${TMP}/openssl.cnf" <<EOF
[req]
distinguished_name = req_distinguished_name
x509_extensions = v3_code_signing
prompt = no

[req_distinguished_name]
commonName = ${IDENTITY}

[v3_code_signing]
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid,issuer
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF

echo "==> 生成本地开发签名: ${IDENTITY}"
# 使用传统 RSA 密钥生成证书。最后通过 PKCS#12 一次性导入私钥和证书，
# 避免 security import 分开导入时出现“参数无效”且无法形成 identity。
openssl genrsa -traditional -out "${TMP}/dev.key" 2048 2>/dev/null
openssl req -x509 -key "${TMP}/dev.key" \
    -out "${TMP}/dev.crt" \
    -days 3650 \
    -config "${TMP}/openssl.cnf" 2>/dev/null

openssl pkcs12 -export \
    -inkey "${TMP}/dev.key" \
    -in "${TMP}/dev.crt" \
    -name "${IDENTITY}" \
    -passout "pass:${P12_PASSWORD}" \
    -out "${TMP}/dev.p12" 2>/dev/null

echo "==> 导入私钥和证书"
security import "${TMP}/dev.p12" \
    -k "${KEYCHAIN}" -f pkcs12 -P "${P12_PASSWORD}" -A -T /usr/bin/codesign >/dev/null

# 让 security find-identity / codesign 认可该本地开发根证书
security add-trusted-cert -d -r trustRoot \
    -k "${KEYCHAIN}" "${TMP}/dev.crt" >/dev/null

if ! security find-identity -v -p codesigning "${KEYCHAIN}" 2>/dev/null | grep -q "${IDENTITY}"; then
    echo "错误：证书已导入，但没有形成可用的 codesign identity。" >&2
    exit 1
fi

echo "开发签名就绪: ${IDENTITY}"
