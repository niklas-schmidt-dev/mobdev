#!/bin/zsh
# Builds build/Mobdev.app. Bluetooth and camera access only work from a signed bundle whose
# Info.plist explains why; a bare binary is stopped by macOS privacy checks.
#
#   scripts/build-app.sh                         ad hoc signature (local use)
#   CODESIGN_IDENTITY="Developer ID Application: …" scripts/build-app.sh
#   UNIVERSAL=1 scripts/build-app.sh             arm64 + x86_64
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-release}"
ARCH_FLAGS=()
if [[ "${UNIVERSAL:-0}" == "1" ]]; then ARCH_FLAGS=(--arch arm64 --arch x86_64); fi

swift build -c "$CONFIG" --product Mobdev "${ARCH_FLAGS[@]}"
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path "${ARCH_FLAGS[@]}")"

APP="build/Mobdev.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Mobdev" "$APP/Contents/MacOS/Mobdev"
strip -x "$APP/Contents/MacOS/Mobdev" 2>/dev/null || true
cp Resources/Info.plist "$APP/Contents/Info.plist"

ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  sips -z $size $size Resources/AppIcon.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  sips -z $((size * 2)) $((size * 2)) Resources/AppIcon.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$(dirname "$ICONSET")"

IDENTITY="${CODESIGN_IDENTITY:--}"
codesign --force --options runtime --timestamp=none \
  --entitlements Resources/Mobdev.entitlements --sign "$IDENTITY" "$APP"
codesign --verify --strict "$APP"
echo "Built $APP ($(du -sh "$APP" | cut -f1), signed: $IDENTITY)"
