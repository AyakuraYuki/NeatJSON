#!/bin/bash
# 生成 NeatJSON 应用图标：
#   IconComposer 绘制 → 全尺寸 iconset → 拷入 xcassets（legacy 全尺寸表，
#   actool 会据此编译出 AppIcon.icns 并注入 CFBundleIconFile）
set -euo pipefail
cd "$(dirname "$0")/.."

BUILD_DIR=".build/icon-tools"
OUTPUT_DIR="$BUILD_DIR/AppIcon.iconset"
TARGET_DIR="NeatJSON/Resources/Assets.xcassets/AppIcon.appiconset"

echo "==> Building IconComposer"
swift build --product IconComposer --build-path "$BUILD_DIR" -c release

echo "==> Rendering iconset"
rm -rf "$OUTPUT_DIR"
"$BUILD_DIR/release/IconComposer" "$OUTPUT_DIR"

echo "==> Installing into asset catalog"
rm -rf "$TARGET_DIR"
mkdir -p "$TARGET_DIR"
cp "$OUTPUT_DIR"/*.png "$TARGET_DIR/"

cat > "$TARGET_DIR/Contents.json" <<'EOF'
{
  "images" : [
    {
      "filename" : "icon_16x16.png",
      "idiom" : "mac",
      "scale" : "1x",
      "size" : "16x16"
    },
    {
      "filename" : "icon_16x16@2x.png",
      "idiom" : "mac",
      "scale" : "2x",
      "size" : "16x16"
    },
    {
      "filename" : "icon_32x32.png",
      "idiom" : "mac",
      "scale" : "1x",
      "size" : "32x32"
    },
    {
      "filename" : "icon_32x32@2x.png",
      "idiom" : "mac",
      "scale" : "2x",
      "size" : "32x32"
    },
    {
      "filename" : "icon_128x128.png",
      "idiom" : "mac",
      "scale" : "1x",
      "size" : "128x128"
    },
    {
      "filename" : "icon_128x128@2x.png",
      "idiom" : "mac",
      "scale" : "2x",
      "size" : "128x128"
    },
    {
      "filename" : "icon_256x256.png",
      "idiom" : "mac",
      "scale" : "1x",
      "size" : "256x256"
    },
    {
      "filename" : "icon_256x256@2x.png",
      "idiom" : "mac",
      "scale" : "2x",
      "size" : "256x256"
    },
    {
      "filename" : "icon_512x512.png",
      "idiom" : "mac",
      "scale" : "1x",
      "size" : "512x512"
    },
    {
      "filename" : "icon_512x512@2x.png",
      "idiom" : "mac",
      "scale" : "2x",
      "size" : "512x512"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
EOF

echo "==> Done: $TARGET_DIR"
echo "    重建 app 后由 actool 编译生成 AppIcon.icns（无需手动 iconutil）"
