#!/bin/bash
# Checks the DMG that is about to ship: the app inside has this version, runs on Apple silicon, has an intact
# signature and every language, and starts. It starts as Changmun Headless (off screen, its own profile), so a
# running Changmun and its data are left alone.
#
#   scripts/check-dmg.sh build/Changmun-<version>.dmg <version>
set -euo pipefail
cd "$(dirname "$0")/.."

DMG="${1:?usage: scripts/check-dmg.sh <dmg> <version>}"
VERSION="${2:?usage: scripts/check-dmg.sh <dmg> <version>}"
step() { echo "▸ $*" >&2; }
fail() { echo "✘ $*" >&2; exit 1; }

ENDPOINT="$HOME/Library/Application Support/Changmun Headless/control.json"
field() { python3 -I -c 'import json, sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$ENDPOINT" "$1"; }
if [[ -f "$ENDPOINT" ]] && kill -0 "$(field pid)" 2>/dev/null; then
    fail "Changmun Headless is running; scripts/headless.sh stop first"
fi

WORK="$(mktemp -d)"
MOUNT="$WORK/mount"
PID=""
cleanup() {
    [[ -n "$PID" ]] && kill "$PID" 2>/dev/null || true
    hdiutil detach -quiet "$MOUNT" 2>/dev/null || true
    rm -rf "$WORK"
}
trap cleanup EXIT

step "Mount"
mkdir -p "$MOUNT"
hdiutil attach -quiet -nobrowse -readonly -mountpoint "$MOUNT" "$DMG"
APP="$MOUNT/Changmun.app"
[[ -d "$APP" ]] || fail "No Changmun.app in the DMG"
[[ -L "$MOUNT/Applications" ]] || fail "No Applications link in the DMG"

step "Version $VERSION"
SHIPPED="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
[[ "$SHIPPED" == "$VERSION" ]] || fail "The app says $SHIPPED"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")" == "io.github.namekun.Changmun" ]] \
    || fail "Unexpected bundle identifier"

step "Apple silicon"
lipo "$APP/Contents/MacOS/Changmun" -verify_arch arm64 || fail "The app is $(lipo -archs "$APP/Contents/MacOS/Changmun")"

step "Signature"
codesign --verify --deep --strict "$APP" || fail "Signature is broken"
# Read codesign's output whole: grep -q quits at the first match, and under pipefail the cut-off codesign fails the test.
SIGNING="$(codesign -dvv "$APP" 2>&1)"
if grep -q "^Authority=Developer ID Application" <<<"$SIGNING"; then
    step "Developer ID, hardened runtime, notarized"
    grep -q "flags=.*runtime" <<<"$SIGNING" || fail "The hardened runtime is off"
    grep -q "com.apple.security.device.camera" <<<"$(codesign -d --entitlements - "$APP" 2>/dev/null)" \
        || fail "The camera entitlement is missing, so sites couldn't use the camera"
    xcrun stapler validate -q "$DMG" || fail "The DMG has no notarization ticket"
    spctl --assess --type open --context context:primary-signature "$DMG" 2>/dev/null || fail "Gatekeeper rejects the DMG"
    spctl --assess --type execute "$APP" 2>/dev/null || fail "Gatekeeper rejects the app"
fi

step "Resources"
for item in AppIcon.icns {en,ko,ja,zh-Hans,es,de,fr}.lproj/InfoPlist.strings {ko,ja,zh-Hans,es,de,fr}.lproj/Localizable.strings; do
    [[ -e "$APP/Contents/Resources/$item" ]] || fail "Missing $item"
done

step "It starts and its tools answer"
HEADLESS="$WORK/Changmun Headless.app"
ditto "$APP" "$HEADLESS"
plutil -replace CFBundleIdentifier -string io.github.namekun.Changmun.headless "$HEADLESS/Contents/Info.plist"
plutil -replace LSBackgroundOnly -bool true "$HEADLESS/Contents/Info.plist"
codesign --force --sign - "$HEADLESS" >/dev/null
rm -f "$ENDPOINT"
"$HEADLESS/Contents/MacOS/Changmun" >"$WORK/run.log" 2>&1 &
PID=$!
for _ in $(seq 60); do [[ -f "$ENDPOINT" ]] && break; sleep 0.25; done
[[ -f "$ENDPOINT" ]] || { tail -20 "$WORK/run.log" >&2; fail "It didn't start its control server"; }
sleep 2
kill -0 "$PID" 2>/dev/null || { tail -20 "$WORK/run.log" >&2; fail "It quit after starting"; }
TABS="$(curl -sf -m 5 -X POST "http://127.0.0.1:$(field port)/call" -H "Authorization: Bearer $(field token)" \
    -H "X-Changmun-Caller: check-dmg.sh" -H "Content-Type: application/json" --data-binary '{"name": "list_tabs", "arguments": {}}')" \
    || fail "list_tabs didn't answer"
[[ -n "$TABS" ]] || fail "list_tabs answered nothing"
kill "$PID"; wait "$PID" 2>/dev/null || true
PID=""

echo "✔ $DMG is ready to ship" >&2
