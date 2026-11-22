#!/bin/zsh
# 重新生成应用图标（F-52）：Scripts/make-icon.swift 画 1024 的 PNG，写进 App/Assets.xcassets（iPadOS 只要这一张，别的尺寸系统缩）。
set -euo pipefail

cd "${0:A:h}/.."
iconset=App/Assets.xcassets/AppIcon.appiconset
mkdir -p $iconset
swift Scripts/make-icon.swift $iconset/AppIcon.png >/dev/null
print '{"info":{"author":"xcode","version":1}}' > App/Assets.xcassets/Contents.json
cat > $iconset/Contents.json <<'JSON'
{
  "images" : [
    {
      "filename" : "AppIcon.png",
      "idiom" : "universal",
      "platform" : "ios",
      "size" : "1024x1024"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
JSON
print "▸ $iconset/AppIcon.png"
