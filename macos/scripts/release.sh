#!/bin/zsh
# Builds, signs, notarizes and packages a Mobdev release into build/dist:
#   Mobdev.dmg                the download at mobdev.sh/download
#   Mobdev-<version>.zip      the Sparkle update archive
#   appcast.xml               the Sparkle feed served at mobdev.sh/appcast.xml
# and the release notes into build/notes (see scripts/release-notes.py).
#
# Required environment:
#   MOBDEV_VERSION, MOBDEV_BUILD     e.g. 0.2.14 and 14 (the build number must only grow)
#   CODESIGN_IDENTITY                a "Developer ID Application" identity in the keychain
#   SPARKLE_PRIVATE_KEY              base64 EdDSA key (generate_keys --account mobdev -x)
#   APPLE_API_KEY_PATH, APPLE_API_KEY_ID, APPLE_API_ISSUER_ID   App Store Connect API key
#   RELEASE_URL                      where the release assets will be downloadable
# SKIP_NOTARIZE=1 packages without notarizing (local checks only; Gatekeeper will refuse it).
set -euo pipefail
cd "$(dirname "$0")/.."
: "${MOBDEV_VERSION:?}" "${MOBDEV_BUILD:?}" "${CODESIGN_IDENTITY:?}" "${SPARKLE_PRIVATE_KEY:?}" "${RELEASE_URL:?}"
if [[ "${SKIP_NOTARIZE:-0}" != "1" ]]; then
  : "${APPLE_API_KEY_PATH:?}" "${APPLE_API_KEY_ID:?}" "${APPLE_API_ISSUER_ID:?}"
fi

SPARKLE_VERSION=2.10.0
export MOBDEV_VERSION MOBDEV_BUILD CODESIGN_IDENTITY
export MOBDEV_UPDATE_FEED="${MOBDEV_UPDATE_FEED:-https://mobdev.sh/appcast.xml}"
MOBDEV_VARIANT=release UNIVERSAL=1 scripts/build-app.sh

DIST=build/dist
NOTES=build/notes
rm -rf "$DIST" "$NOTES"
mkdir -p "$DIST" "$NOTES"
# What's new, from the Release-Note lines of the commits since the last release. The update window
# shows the HTML; the GitHub release gets the Markdown.
scripts/release-notes.py "$MOBDEV_VERSION" "$NOTES/release-notes.html" "$NOTES/release-notes.md"

notarize() {
  if [[ "${SKIP_NOTARIZE:-0}" == "1" ]]; then
    echo "Skipping notarization of $1"
    return
  fi
  xcrun notarytool submit "$1" --key "$APPLE_API_KEY_PATH" --key-id "$APPLE_API_KEY_ID" \
    --issuer "$APPLE_API_ISSUER_ID" --wait --timeout 30m
  xcrun stapler staple "$2"
}

# 1. Notarize the app and staple the ticket, so it also opens offline.
ditto -c -k --keepParent build/Mobdev.app build/notarize.zip
notarize build/notarize.zip build/Mobdev.app
rm -f build/notarize.zip

# 2. The update archive Sparkle downloads.
ZIP="$DIST/Mobdev-$MOBDEV_VERSION.zip"
ditto -c -k --keepParent build/Mobdev.app "$ZIP"

# 3. The disk image people download: the app and a shortcut to Applications, laid out on the designed
#    background (scripts/dmg-settings.py; the art comes from scripts/make-dmg-background.swift).
DMGBUILD=build/dmgbuild
if [[ ! -x "$DMGBUILD/bin/dmgbuild" ]]; then
  python3 -m venv "$DMGBUILD"
  "$DMGBUILD/bin/pip" install --quiet dmgbuild==1.6.7
fi
"$DMGBUILD/bin/dmgbuild" -s scripts/dmg-settings.py -D app=build/Mobdev.app \
  -D background=Resources/DMGBackground.png Mobdev "$DIST/Mobdev.dmg"
# dmgbuild does not stop when copying the app fails, so check the copy in the image.
MOUNT="$(mktemp -d)"
hdiutil attach -quiet -nobrowse -readonly -mountpoint "$MOUNT" "$DIST/Mobdev.dmg"
codesign --verify --deep --strict "$MOUNT/Mobdev.app"
if [[ "${SKIP_NOTARIZE:-0}" != "1" ]]; then xcrun stapler validate -q "$MOUNT/Mobdev.app"; fi
hdiutil detach -quiet "$MOUNT"
codesign --force --timestamp --sign "$CODESIGN_IDENTITY" "$DIST/Mobdev.dmg"
notarize "$DIST/Mobdev.dmg" "$DIST/Mobdev.dmg"

# 4. Sign the update and write the feed.
TOOLS=build/sparkle-tools
if [[ ! -x "$TOOLS/bin/sign_update" ]]; then
  mkdir -p "$TOOLS"
  curl -fsSL "https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz" \
    | tar -xJ -C "$TOOLS"
fi
KEYFILE="$(mktemp)"
print -rn -- "$SPARKLE_PRIVATE_KEY" > "$KEYFILE"
SIGNATURE="$("$TOOLS/bin/sign_update" --ed-key-file "$KEYFILE" "$ZIP")"
rm -f "$KEYFILE"
"$TOOLS/bin/sign_update" --verify "$ZIP" "$(sed -E 's/.*edSignature="([^"]+)".*/\1/' <<<"$SIGNATURE")" \
  --ed-key-file <(print -rn -- "$SPARKLE_PRIVATE_KEY") >/dev/null

cat > "$DIST/appcast.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Mobdev</title>
    <link>https://mobdev.sh/appcast.xml</link>
    <item>
      <title>Mobdev $MOBDEV_VERSION</title>
      <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
      <sparkle:version>$MOBDEV_BUILD</sparkle:version>
      <sparkle:shortVersionString>$MOBDEV_VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>26.0</sparkle:minimumSystemVersion>
      <description><![CDATA[$(cat "$NOTES/release-notes.html")]]></description>
      <enclosure url="$RELEASE_URL/Mobdev-$MOBDEV_VERSION.zip" type="application/octet-stream" $SIGNATURE />
    </item>
  </channel>
</rss>
XML
ls -lh "$DIST"
