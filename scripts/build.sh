#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

VERSION="1.0.0"
BUILD_DIR="$ROOT_DIR/build"
APP_BUNDLE="$BUILD_DIR/ClipV.app"
DMG_STAGING="$BUILD_DIR/dmg-staging"
DMG_PATH="$BUILD_DIR/ClipV-${VERSION}-macOS-Universal.dmg"
ZIP_PATH="$BUILD_DIR/ClipV-${VERSION}-macOS-Universal.zip"

rm -rf "$BUILD_DIR"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"

echo "==> Generating macOS AppIcon.icns..."
swift "$ROOT_DIR/scripts/generate_icon.swift" "$BUILD_DIR/AppIcon.iconset"
iconutil -c icns "$BUILD_DIR/AppIcon.iconset" -o "$ROOT_DIR/Resources/AppIcon.icns"
cp "$ROOT_DIR/Resources/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
cp "$ROOT_DIR/Resources/Info.plist" "$APP_BUNDLE/Contents/Info.plist"

echo "==> Compiling arm64 binary..."
swiftc -parse-as-library -Osize -whole-module-optimization \
  -target arm64-apple-macosx14.0 \
  "$ROOT_DIR/Sources/ClipV.swift" \
  -framework Cocoa -framework SwiftUI -framework Carbon -framework ApplicationServices \
  -o "$BUILD_DIR/ClipV-arm64"

echo "==> Compiling x86_64 binary..."
swiftc -parse-as-library -Osize -whole-module-optimization \
  -target x86_64-apple-macosx14.0 \
  "$ROOT_DIR/Sources/ClipV.swift" \
  -framework Cocoa -framework SwiftUI -framework Carbon -framework ApplicationServices \
  -o "$BUILD_DIR/ClipV-x86_64"

echo "==> Creating Universal binary..."
lipo -create "$BUILD_DIR/ClipV-arm64" "$BUILD_DIR/ClipV-x86_64" -output "$APP_BUNDLE/Contents/MacOS/ClipV"
strip -u -r "$APP_BUNDLE/Contents/MacOS/ClipV"
codesign --force --deep --sign - "$APP_BUNDLE"

echo "==> Packaging ZIP..."
ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "$ZIP_PATH"

echo "==> Packaging DMG..."
mkdir -p "$DMG_STAGING"
cp -R "$APP_BUNDLE" "$DMG_STAGING/"
ln -s /Applications "$DMG_STAGING/Applications"
hdiutil create -volname "ClipV" \
  -srcfolder "$DMG_STAGING" \
  -ov -format UDZO \
  "$DMG_PATH" >/dev/null

echo "==> Build complete:"
ls -lh "$APP_BUNDLE/Contents/MacOS/ClipV" "$ZIP_PATH" "$DMG_PATH"
du -sh "$APP_BUNDLE"
