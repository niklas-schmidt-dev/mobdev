#!/bin/bash
# Builds MobdevFixture.app for the iOS Simulator (Apple silicon) next to this script and signs it
# ad hoc. Needs only Xcode: no project, no signing team.
set -euo pipefail
cd "$(dirname "$0")"
rm -rf MobdevFixture.app
mkdir -p MobdevFixture.app
xcrun -sdk iphonesimulator swiftc -parse-as-library -target arm64-apple-ios18.0-simulator -O \
  main.swift -o MobdevFixture.app/MobdevFixture
cp Info.plist MobdevFixture.app/Info.plist
codesign --force --sign - MobdevFixture.app
echo "$(pwd)/MobdevFixture.app"
