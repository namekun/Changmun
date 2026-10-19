#!/bin/bash
# Builds the Swift package and wraps the binary in an .app bundle at build/Changmun.app.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/env.sh

CONFIG="${1:-debug}"
swift build "${SCRATCH[@]}" -c "$CONFIG"
BIN_DIR="$(swift build "${SCRATCH[@]}" -c "$CONFIG" --show-bin-path)"

# Assemble and sign outside the project folder: a synced folder (iCloud Desktop) keeps adding
# Finder info to the bundle, which codesign rejects.
WORK="$(mktemp -d)"
APP="$WORK/Changmun.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Changmun" "$APP/Contents/MacOS/Changmun"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp -R Resources/*.lproj Resources/AppIcon.icns Resources/changmun "$APP/Contents/Resources/"
xattr -cr "$APP"
codesign --force --sign - "$APP" >/dev/null
rm -rf build/Changmun.app
mkdir -p build
ditto "$APP" build/Changmun.app
rm -rf "$WORK"
echo build/Changmun.app
