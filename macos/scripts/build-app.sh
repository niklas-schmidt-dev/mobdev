#!/bin/zsh
# Builds build/Mobdev.app. Bluetooth and camera access only work from a signed bundle whose
# Info.plist explains why; a bare binary is stopped by macOS privacy checks.
#
#   scripts/build-app.sh                         local build, ad hoc signature, no updates
#   CODESIGN_IDENTITY="Developer ID Application: …" scripts/build-app.sh
#   UNIVERSAL=1 scripts/build-app.sh             arm64 + x86_64
#
# Release builds (see scripts/release.sh) also set MOBDEV_VERSION, MOBDEV_BUILD and
# MOBDEV_UPDATE_FEED; only builds with a feed look for Sparkle updates.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-release}"
ARCH_FLAGS=()
if [[ "${UNIVERSAL:-0}" == "1" ]]; then ARCH_FLAGS=(--arch arm64 --arch x86_64); fi

swift build -c "$CONFIG" --product Mobdev "${ARCH_FLAGS[@]}"
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path "${ARCH_FLAGS[@]}")"

APP="build/Mobdev.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN_DIR/Mobdev" "$APP/Contents/MacOS/Mobdev"
strip -x "$APP/Contents/MacOS/Mobdev" 2>/dev/null || true
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/Mobdev"

PLIST="$APP/Contents/Info.plist"
cp Resources/Info.plist "$PLIST"
plist() { /usr/libexec/PlistBuddy -c "$1" "$PLIST"; }
plist "Set :CFBundleShortVersionString ${MOBDEV_VERSION:-0.1.0}"
plist "Set :CFBundleVersion ${MOBDEV_BUILD:-1}"
if [[ -n "${MOBDEV_UPDATE_FEED:-}" ]]; then plist "Add :SUFeedURL string $MOBDEV_UPDATE_FEED"; fi

# Sparkle, without what a non-sandboxed app does not need.
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
ditto "$BIN_DIR/Sparkle.framework" "$SPARKLE"
rm -rf "$SPARKLE/Versions/B/XPCServices" "$SPARKLE/Versions/B/Headers" "$SPARKLE/Versions/B/PrivateHeaders" \
  "$SPARKLE/Versions/B/Modules" "$SPARKLE/Headers" "$SPARKLE/PrivateHeaders" "$SPARKLE/Modules" "$SPARKLE/XPCServices"

ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  sips -z $size $size Resources/AppIcon.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  sips -z $((size * 2)) $((size * 2)) Resources/AppIcon.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$(dirname "$ICONSET")"

# Sign from the inside out. Real identities get the hardened runtime and a secure timestamp,
# which notarization needs. Ad hoc builds skip the hardened runtime: its library validation
# only loads frameworks with the same team ID, and ad hoc signatures have none.
IDENTITY="${CODESIGN_IDENTITY:--}"
SIGN_FLAGS=(--options runtime --timestamp)
if [[ "$IDENTITY" == "-" ]]; then SIGN_FLAGS=(--timestamp=none); fi
sign() { codesign --force "${SIGN_FLAGS[@]}" --sign "$IDENTITY" "$@"; }
sign "$SPARKLE/Versions/B/Autoupdate"
sign "$SPARKLE/Versions/B/Updater.app"
sign "$SPARKLE"
sign --entitlements Resources/Mobdev.entitlements "$APP"
codesign --verify --deep --strict "$APP"
echo "Built $APP ($(du -sh "$APP" | cut -f1), version ${MOBDEV_VERSION:-0.1.0} (${MOBDEV_BUILD:-1}), signed: $IDENTITY)"
