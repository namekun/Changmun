#!/bin/bash
# Signs a finished DMG for Sparkle and adds its item to the signed feed (docs/appcast.xml, which GitHub Pages serves). Uploads
# nothing. Run it after make-dmg.sh: stapling changes the DMG's bytes, and the signature is of the bytes users download.
#
#   scripts/appcast.sh <dmg> <version> <build> <notes-file> [feed]
#
# The EdDSA key is the file SPARKLE_KEY_FILE names (~/.config/changmun/sparkle.env), the public half of which is
# Info.plist's SUPublicEDKey.
set -euo pipefail
DMG="${1:?usage: scripts/appcast.sh <dmg> <version> <build> <notes-file> [feed]}"
VERSION="${2:?}" BUILD="${3:?}" NOTES="${4:?}" FEED="${5:-docs/appcast.xml}"
cd "$(dirname "$0")/.."
source scripts/env.sh

[[ -x "$SPARKLE_BIN/sign_update" ]] || { echo "Sparkle's sign_update is not in $SPARKLE_BIN: swift package ${SCRATCH[*]} resolve" >&2; exit 1; }
[[ -f "${SPARKLE_KEY_FILE:-}" ]] || { echo "No Sparkle key file: name it in ~/.config/changmun/sparkle.env (SPARKLE_KEY_FILE)" >&2; exit 1; }
PLIST=Resources/Info.plist
[[ "$(python3 -I scripts/appcast.py pubkey "$SPARKLE_KEY_FILE")" == "$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$PLIST")" ]] \
    || { echo "The key in $SPARKLE_KEY_FILE isn't the SUPublicEDKey in $PLIST, so installed copies would refuse this update" >&2; exit 1; }
sign() { "$SPARKLE_BIN/sign_update" --ed-key-file "$SPARKLE_KEY_FILE" "$@"; }

SIGNATURE="$(sign -p "$DMG")"
LENGTH="$(stat -f %z "$DMG")"
URL="https://github.com/namekun/Changmun/releases/download/v$VERSION/$(basename "$DMG")"
python3 -I scripts/appcast.py add "$FEED" --version "$VERSION" --build "$BUILD" --url "$URL" --length "$LENGTH" \
    --signature "$SIGNATURE" --notes "$NOTES" --min-os "$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$PLIST")"
# Info.plist asks for a signed feed (SURequireSignedFeed): sign_update puts the signature into the file.
sign --disable-signing-warning "$FEED" >/dev/null
sign --verify "$FEED" >/dev/null || { echo "The feed's signature doesn't verify" >&2; exit 1; }
sign --verify "$DMG" "$SIGNATURE" >/dev/null || { echo "The DMG's signature doesn't verify" >&2; exit 1; }
python3 -I scripts/appcast.py check "$FEED" --version "$VERSION" --build "$BUILD" --url "$URL" --length "$LENGTH" --signature "$SIGNATURE"
echo "$FEED"
