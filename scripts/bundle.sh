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
# Without a feed Sparkle stays off (Updates.swift), so a development build is never offered the release in its place.
[[ "$CONFIG" == release ]] || plutil -remove SUFeedURL "$APP/Contents/Info.plist"
cp -R Resources/*.lproj Resources/AppIcon.icns Resources/changmun "$APP/Contents/Resources/"
# Sparkle brings the updates; ditto keeps the framework's symlinks.
FW="$APP/Contents/Frameworks/Sparkle.framework"
[[ -d "$BIN_DIR/Sparkle.framework" ]] || { echo "No Sparkle.framework in $BIN_DIR" >&2; exit 1; }
mkdir -p "$APP/Contents/Frameworks"
ditto "$BIN_DIR/Sparkle.framework" "$FW"
# Its XPC services are for sandboxed apps, which Changmun isn't. Removed before signing: after, it would break the seal.
rm -rf "$FW/Versions/B/XPCServices" "$FW/XPCServices"
# SwiftPM doesn't point the executable at Contents/Frameworks. Read into a variable first: under pipefail, grep -q
# stopping early would fail otool with a broken pipe.
LOADS="$(otool -l "$APP/Contents/MacOS/Changmun")"
grep -q "@executable_path/../Frameworks" <<<"$LOADS" \
    || install_name_tool -add_rpath @executable_path/../Frameworks "$APP/Contents/MacOS/Changmun" \
    || { echo "add_rpath failed" >&2; exit 1; }
xattr -cr "$APP"
IDENTITY=""
[[ "$CONFIG" == release ]] && IDENTITY="$(developer_id)"
# Inside out and never --deep, as Sparkle's documentation has it: the updater inside the framework, the framework, the
# app. Under a Developer ID everything has the same team, which the hardened runtime's library validation needs to load
# the framework, and a secure timestamp, which notarization needs.
if [[ -n "$IDENTITY" ]]; then
    SIGN=(codesign --force --options runtime --timestamp --sign "$IDENTITY")
    APP_SIGN=("${SIGN[@]}" --entitlements Resources/Changmun.entitlements)
else
    SIGN=(codesign --force --sign -)
    APP_SIGN=("${SIGN[@]}")
fi
for part in "$FW/Versions/B/Autoupdate" "$FW/Versions/B/Updater.app" "$FW"; do "${SIGN[@]}" "$part" >/dev/null; done
"${APP_SIGN[@]}" "$APP" >/dev/null
rm -rf build/Changmun.app
mkdir -p build
ditto "$APP" build/Changmun.app
rm -rf "$WORK"
echo build/Changmun.app
