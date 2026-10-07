#!/bin/zsh
# Builds the Mac app. Bluetooth and camera access only work from a signed bundle whose
# Info.plist explains why; a bare binary is stopped by macOS privacy checks.
#
#   scripts/build-app.sh                         build/Mobdev Dev.app, ad hoc signature, no updates
#   MOBDEV_VARIANT=release scripts/build-app.sh  build/Mobdev.app, the app people install
#   CODESIGN_IDENTITY="Developer ID Application: …" scripts/build-app.sh
#   UNIVERSAL=1 scripts/build-app.sh             arm64 + x86_64
#
# "Mobdev Dev" (dev.mobdev.mac.dev) is a separate app: its own settings, secrets, port (4687),
# URL scheme (mobdev-dev://), MCP name and amber icon, so it runs next to an installed Mobdev
# without changing it. Both share the Mac's Bluetooth, so quit one before testing touch.
#
# Release builds (see scripts/release.sh) also set MOBDEV_VERSION, MOBDEV_BUILD and
# MOBDEV_UPDATE_FEED; only builds with a feed look for Sparkle updates.
set -euo pipefail
cd "$(dirname "$0")/.."

case "${MOBDEV_VARIANT:-dev}" in
  release) NAME="Mobdev" BUNDLE_ID="dev.mobdev.mac" SCHEME="mobdev" ICON="Resources/AppIcon.png" ;;
  dev) NAME="Mobdev Dev" BUNDLE_ID="dev.mobdev.mac.dev" SCHEME="mobdev-dev" ICON="Resources/AppIconDev.png" ;;
  *) echo "MOBDEV_VARIANT must be dev or release" >&2; exit 1 ;;
esac

CONFIG="${CONFIG:-release}"
ARCH_FLAGS=()
if [[ "${UNIVERSAL:-0}" == "1" ]]; then ARCH_FLAGS=(--arch arm64 --arch x86_64); fi

swift build -c "$CONFIG" --product Mobdev "${ARCH_FLAGS[@]}"
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path "${ARCH_FLAGS[@]}")"

APP="build/$NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN_DIR/Mobdev" "$APP/Contents/MacOS/Mobdev"
strip -x "$APP/Contents/MacOS/Mobdev" 2>/dev/null || true
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/Mobdev"

PLIST="$APP/Contents/Info.plist"
cp Resources/Info.plist "$PLIST"
plist() { /usr/libexec/PlistBuddy -c "$1" "$PLIST"; }
plist "Set :CFBundleIdentifier $BUNDLE_ID"
plist "Set :CFBundleName $NAME"
plist "Set :CFBundleDisplayName $NAME"
plist "Set :CFBundleURLTypes:0:CFBundleURLName $BUNDLE_ID.connect"
plist "Set :CFBundleURLTypes:0:CFBundleURLSchemes:0 $SCHEME"
plist "Set :CFBundleShortVersionString ${MOBDEV_VERSION:-0.1.0}"
plist "Set :CFBundleVersion ${MOBDEV_BUILD:-1}"
if [[ -n "${MOBDEV_UPDATE_FEED:-}" ]]; then plist "Add :SUFeedURL string $MOBDEV_UPDATE_FEED"; fi

# Mobdev Runner's Xcode project (a few KB of sources), which the app builds with Xcode for the UI
# tree on iPhones. Xcode's per-user state stays out.
rsync -a --exclude xcuserdata --exclude project.xcworkspace --exclude .DS_Store --exclude .gitignore Runner/ "$APP/Contents/Resources/Runner/"

# scrcpy's server (Apache-2.0, about 90 KB), which Mobdev runs on Android devices for a video stream
# and input. Downloaded once into .build and checked; keep both values in step with
# Sources/MobdevCore/Emulators/ScrcpyServer.swift (a test compares them).
SCRCPY_VERSION="3.3.4"
SCRCPY_SHA256="8588238c9a5a00aa542906b6ec7e6d5541d9ffb9b5d0f6e1bc0e365e2303079e"
SCRCPY_SERVER=".build/scrcpy-server-v$SCRCPY_VERSION"
scrcpy_intact() { [[ -f "$1" ]] && [[ "$(shasum -a 256 "$1" | cut -d ' ' -f 1)" == "$SCRCPY_SHA256" ]]; }
if ! scrcpy_intact "$SCRCPY_SERVER"; then
  mkdir -p .build
  curl -fsSL --retry 3 -o "$SCRCPY_SERVER.download" \
    "https://github.com/Genymobile/scrcpy/releases/download/v$SCRCPY_VERSION/scrcpy-server-v$SCRCPY_VERSION"
  if ! scrcpy_intact "$SCRCPY_SERVER.download"; then
    echo "scrcpy-server-v$SCRCPY_VERSION does not match its SHA-256" >&2
    rm -f "$SCRCPY_SERVER.download"
    exit 1
  fi
  mv "$SCRCPY_SERVER.download" "$SCRCPY_SERVER"
fi
cp "$SCRCPY_SERVER" "$APP/Contents/Resources/"
cp Resources/scrcpy-LICENSE "$APP/Contents/Resources/"

# Sparkle, without what a non-sandboxed app does not need.
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
ditto "$BIN_DIR/Sparkle.framework" "$SPARKLE"
rm -rf "$SPARKLE/Versions/B/XPCServices" "$SPARKLE/Versions/B/Headers" "$SPARKLE/Versions/B/PrivateHeaders" \
  "$SPARKLE/Versions/B/Modules" "$SPARKLE/Headers" "$SPARKLE/PrivateHeaders" "$SPARKLE/Modules" "$SPARKLE/XPCServices"

ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  sips -z $size $size "$ICON" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  sips -z $((size * 2)) $((size * 2)) "$ICON" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
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
