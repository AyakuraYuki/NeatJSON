#!/bin/bash
# 生成 Xcode 工程（如需）并构建 NeatJSON.app
set -euo pipefail
cd "$(dirname "$0")/.."

if [ ! -d NeatJSON.xcodeproj ] || [ project.yml -nt NeatJSON.xcodeproj/project.pbxproj ]; then
    echo "==> Running xcodegen"
    xcodegen generate
fi

echo "==> Building"
xcodebuild -project NeatJSON.xcodeproj -scheme NeatJSON -configuration Debug build \
    -derivedDataPath "$PWD/.build/dd" \
    CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" CODE_SIGN_ENTITLEMENTS=""

APP="$(find "$PWD/.build/dd/Build/Products/Debug" -name 'NeatJSON.app' -maxdepth 1 | head -1)"
echo "==> Built: $APP"
