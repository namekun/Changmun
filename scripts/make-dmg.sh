#!/bin/bash
# Builds a release app and packages it as build/Changmun-<version>.dmg. With a Developer ID in the keychain the DMG
# is signed, notarized and stapled too. With RELEASE=1 (release.sh sets it) that is required: no Developer ID or SKIP_NOTARIZE fails.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/env.sh

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

IDENTITY="$(developer_id)"
if [[ -n "${RELEASE:-}" && ( -z "$IDENTITY" || -n "${SKIP_NOTARIZE:-}" ) ]]; then
    echo "✘ A release needs a Developer ID and notarization (no Developer ID in the keychain, or SKIP_NOTARIZE is set)" >&2
    exit 1
fi
if [[ -n "$IDENTITY" ]]; then
    codesign --force --timestamp --sign "$IDENTITY" "$DMG"
    if [[ -n "${SKIP_NOTARIZE:-}" ]]; then
        echo "▸ Signed with $IDENTITY; not notarized (SKIP_NOTARIZE)" >&2
        echo "$DMG"
        exit 0
    fi
    echo "▸ Notarizing (this takes a few minutes)" >&2
    RESULT="$(xcrun notarytool submit "$DMG" "${NOTARY_AUTH[@]}" --wait --output-format json)"
    STATUS="$(python3 -I -c 'import json, sys; print(json.load(sys.stdin).get("status", ""))' <<<"$RESULT")"
    if [[ "$STATUS" != "Accepted" ]]; then
        ID="$(python3 -I -c 'import json, sys; print(json.load(sys.stdin).get("id", ""))' <<<"$RESULT")"
        [[ -n "$ID" ]] && xcrun notarytool log "$ID" "${NOTARY_AUTH[@]}" >&2
        echo "✘ Notarization: ${STATUS:-no answer}" >&2
        exit 1
    fi
    xcrun stapler staple -q "$DMG"
    echo "✔ Signed with $IDENTITY and notarized" >&2
else
    echo "▸ No Developer ID in the keychain: ad-hoc signed, not notarized" >&2
fi
echo "$DMG"
