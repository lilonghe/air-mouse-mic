#!/bin/bash
# 构建并打包成菜单栏 App（ad-hoc 签名）
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP="build/AtvvMenu.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp ".build/release/AtvvMenu" "$APP/Contents/MacOS/AtvvMenu"
cp "Info.plist" "$APP/Contents/Info.plist"

codesign --force --sign - "$APP"
echo "已生成 $APP"
