#!/bin/bash
# Builds PhotoShuffle.app (Intel + Apple Silicon) and packs it into dist/PhotoShuffle.zip
set -euo pipefail

cd "$(dirname "$0")/.."

ARCHS=(--arch arm64 --arch x86_64)
swift build -c release "${ARCHS[@]}"
BIN_DIR="$(swift build -c release "${ARCHS[@]}" --show-bin-path)"
if [ ! -f "$BIN_DIR/PhotoShuffle" ]; then
  BIN_DIR=".build/apple/Products/Release"
fi

APP="dist/PhotoShuffle.app"
rm -rf dist build/AppIcon.iconset
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build/AppIcon.iconset

cp "$BIN_DIR/PhotoShuffle" "$APP/Contents/MacOS/PhotoShuffle"
sed "s/BUILD_NUMBER/${GITHUB_RUN_NUMBER:-1}/" Support/Info.plist > "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

if [ -f Support/AppIcon.png ]; then
  for size in 16 32 128 256 512; do
    sips -z $size $size Support/AppIcon.png --out "build/AppIcon.iconset/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z $double $double Support/AppIcon.png --out "build/AppIcon.iconset/icon_${size}x${size}@2x.png" >/dev/null
  done
  iconutil -c icns build/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
fi

codesign --force --deep --sign - "$APP"
ditto -c -k --sequesterRsrc --keepParent "$APP" dist/PhotoShuffle.zip

lipo -info "$APP/Contents/MacOS/PhotoShuffle"
echo "Done: dist/PhotoShuffle.zip"
