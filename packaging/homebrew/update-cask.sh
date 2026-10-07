#!/bin/bash
# Sets version and sha256 in mobdev.rb to a release's: downloads that release's DMG from GitHub
# and hashes it. Usage: packaging/homebrew/update-cask.sh 0.2.35 (or mac-v0.2.35)
set -euo pipefail

version="${1:-}"
version="${version#mac-v}"
if [[ ! "$version" =~ ^[0-9]+(\.[0-9]+)+$ ]]; then
  echo "Usage: $0 <version>, e.g. $0 0.2.35" >&2
  exit 2
fi
cask="$(cd "$(dirname "$0")" && pwd)/mobdev.rb"
url="https://github.com/niklas-schmidt-dev/mobdev/releases/download/mac-v$version/Mobdev.dmg"
dmg="$(mktemp)"
trap 'rm -f "$dmg"' EXIT

echo "Downloading $url"
curl -fsSL --retry 3 -o "$dmg" "$url"
sha256="$(shasum -a 256 "$dmg" | cut -d ' ' -f 1)"

# perl rather than sed -i, which takes different arguments on macOS and Linux.
VERSION="$version" SHA256="$sha256" perl -pi -e '
  s/^(\s*version )"[^"]*"/$1"$ENV{VERSION}"/;
  s/^(\s*sha256 )"[^"]*"/$1"$ENV{SHA256}"/;
' "$cask"
grep -E '^\s*(version|sha256) ' "$cask"
