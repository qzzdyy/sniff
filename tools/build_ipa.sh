#!/bin/bash
# 本地 macOS 一键构建未签名 IPA（不需要开发者账号）
# 用法: bash tools/build_ipa.sh
set -euo pipefail
cd "$(dirname "$0")/.."

echo "==> Archive（不签名）"
xcodebuild archive \
  -project Sniff.xcodeproj \
  -scheme Sniff \
  -configuration Release \
  -archivePath "$PWD/build/Sniff.xcarchive" \
  -destination 'generic/platform=iOS' \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO \
  DEVELOPMENT_TEAM=""

echo "==> 打包 IPA"
rm -rf Payload Sniff-unsigned.ipa
mkdir -p Payload
cp -R "build/Sniff.xcarchive/Products/Applications/Sniff.app" Payload/
zip -qry Sniff-unsigned.ipa Payload
rm -rf Payload

echo "==> 完成: Sniff-unsigned.ipa"
ls -lh Sniff-unsigned.ipa
