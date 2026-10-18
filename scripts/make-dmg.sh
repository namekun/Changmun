#!/bin/bash
# Builds a release app and packages it as build/Changmun-<version>.dmg.
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/bundle.sh release >/dev/null
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
STAGE="$(mktemp -d)"
cp -R build/Changmun.app "$STAGE/"
xattr -cr "$STAGE/Changmun.app"
codesign --verify --deep --strict "$STAGE/Changmun.app"
ln -s /Applications "$STAGE/Applications"
DMG="build/Changmun-$VERSION.dmg"
rm -f "$DMG"
hdiutil create -volname "Changmun" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"
echo "$DMG"
