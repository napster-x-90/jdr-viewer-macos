#!/bin/bash
set -euo pipefail
app="${1:-build/블랙박스 뷰어.app}"
if [[ "$app" != /* ]]; then app="$PWD/$app"; fi
cd "$(dirname "$0")"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
xcrun swiftc -swift-version 5 -O -target "$(uname -m)-apple-macosx14.0" \
  App.swift Player.swift JDR.swift Movies.swift MP4Export.swift -o "$app/Contents/MacOS/JDRViewer"
cp Resources/AppIcon.icns "$app/Contents/Resources/"
cp Info.plist "$app/Contents/Info.plist"
codesign --force --sign - "$app"
codesign --verify --strict "$app"
