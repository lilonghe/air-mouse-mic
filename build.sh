#!/bin/bash
# 构建并打包成菜单栏 App（ad-hoc 签名）
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP="build/air-mouse-mic.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp ".build/release/amm" "$APP/Contents/MacOS/amm"
cp "Info.plist" "$APP/Contents/Info.plist"

codesign --force --sign - "$APP"
echo "已生成 $APP"
