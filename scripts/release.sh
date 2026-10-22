#!/bin/bash
# Releases a new version: runs every check (scripts/preflight.sh), bumps the version (Info.plist and the website,
# docs/index.html), builds the DMG and checks it (scripts/check-dmg.sh), signs it for Sparkle and adds it to the feed
# (scripts/appcast.sh, docs/appcast.xml), and only then commits, tags, publishes the GitHub release, checks the published
# DMG, updates the Homebrew tap and, last, pushes the feed live. The DMG is attached twice, as Changmun-<version>.dmg and as Changmun.dmg,
# so that the site's .../releases/latest/download/Changmun.dmg link always gives the newest.
#
#   scripts/release.sh <version> [notes-file]
#
# Notes come from the file, or from $EDITOR when no file is given. The tap repo is expected at
# ../homebrew-tap (override with TAP_DIR).
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: scripts/release.sh <version> [notes-file]}"
NOTES_FILE="${2:-}"
TAP_DIR="${TAP_DIR:-../homebrew-tap}"
CASK="$TAP_DIR/Casks/changmun.rb"
PLIST="Resources/Info.plist"
PAGE="docs/index.html"
APPCAST="docs/appcast.xml"

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Version must look like 1.2.3" >&2; exit 1; }
[[ "$(git branch --show-current)" == "main" ]] || { echo "Release from main" >&2; exit 1; }
[[ -z "$(git status --porcelain)" ]] || { echo "Working tree is not clean" >&2; exit 1; }
git rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null && { echo "v$VERSION already exists" >&2; exit 1; }
[[ -f "$CASK" ]] || { echo "Homebrew tap not found at $TAP_DIR" >&2; exit 1; }

if [[ -z "$NOTES_FILE" ]]; then
    NOTES_FILE="$(mktemp)"
    "${EDITOR:-vi}" "$NOTES_FILE"
fi
[[ -s "$NOTES_FILE" ]] || { echo "Release notes are empty" >&2; exit 1; }

# Notarizing comes after the checks and the build, so find out first whether the credentials are there.
source scripts/env.sh
if [[ -z "${SKIP_NOTARIZE:-}" && -n "$(developer_id)" ]] && ! xcrun notarytool history "${NOTARY_AUTH[@]}" >/dev/null 2>&1; then
    echo "The notarytool credentials don't work: add an API key in ~/.config/changmun/notary.env or run xcrun notarytool store-credentials $NOTARY_PROFILE" >&2
    exit 1
fi

# The key that signs updates must be there, and be the one the app trusts, or no installed copy would take the update.
[[ -f "${SPARKLE_KEY_FILE:-}" ]] || { echo "No Sparkle key file: name it in ~/.config/changmun/sparkle.env (SPARKLE_KEY_FILE)" >&2; exit 1; }
[[ "$(python3 -I scripts/appcast.py pubkey "$SPARKLE_KEY_FILE")" == "$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$PLIST")" ]] \
    || { echo "The key in $SPARKLE_KEY_FILE isn't the SUPublicEDKey in $PLIST" >&2; exit 1; }

./scripts/preflight.sh

# Until the tag is pushed, a failure puts the bumped files back. After it, nothing can be undone: STAGE says which
# step was under way, and a failure prints the steps still to do by hand.
PUSHED=0
STAGE=0
STABLE="$(mktemp -d)"
finish() {
    local status=$?
    rm -rf "$STABLE"
    if (( ! PUSHED )); then
        git checkout -q -- "$PLIST" "$PAGE" "$APPCAST"
    elif (( status != 0 )); then
        {
            echo "Release v$VERSION failed after its tag was pushed. Still to do, in this order:"
            if (( STAGE <= 1 )); then echo "  1. gh release create v$VERSION $DMG (also as Changmun.dmg) --title v$VERSION --notes-file $NOTES_FILE"; fi
            if (( STAGE <= 2 )); then echo "  2. check that the downloaded release DMG has the sha256 of $DMG"; fi
            if (( STAGE <= 3 )); then echo "  3. set version and sha256 in $CASK, then commit and push the tap"; fi
            if (( STAGE <= 4 )); then echo "  4. git push origin main (this puts the feed live: only after 1 and 2)"; fi
        } >&2
    fi
}
trap finish EXIT

CURRENT="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")"
# The first release ships the version already in Info.plist; later ones bump it.
if [[ "$CURRENT" != "$VERSION" ]] || git rev-parse -q --verify "refs/tags/v$CURRENT" >/dev/null; then
    BUILD=$(( BUILD + 1 ))
fi
# Sparkle compares builds, so this one must be above everything the feed already offers.
(( BUILD > $(python3 -I scripts/appcast.py max-build "$APPCAST") )) || { echo "Build $BUILD isn't above the feed's newest" >&2; exit 1; }
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" -c "Set :CFBundleVersion $BUILD" "$PLIST"
# Every place the page shows the version is <span data-version>X</span>.
sed -i '' -e "s|<span data-version>[0-9.]*</span>|<span data-version>$VERSION</span>|g" "$PAGE"
grep -q "<span data-version>$VERSION</span>" "$PAGE" || { echo "$PAGE has no <span data-version> to update" >&2; exit 1; }

DMG="$(./scripts/make-dmg.sh)"
./scripts/check-dmg.sh "$DMG" "$VERSION"
./scripts/appcast.sh "$DMG" "$VERSION" "$BUILD" "$NOTES_FILE" "$APPCAST" >/dev/null

git diff --quiet -- "$PLIST" "$PAGE" "$APPCAST" || { git add "$PLIST" "$PAGE" "$APPCAST"; git commit -q -m "Version $VERSION"; }
git tag "v$VERSION"
# The tag first: the feed goes live with main, and must not offer a DMG that isn't published yet.
git push -q origin "v$VERSION"
PUSHED=1

SHA="$(shasum -a 256 "$DMG" | cut -d' ' -f1)"
cp "$DMG" "$STABLE/Changmun.dmg"
STAGE=1
gh release create "v$VERSION" "$DMG" "$STABLE/Changmun.dmg" --title "v$VERSION" --notes-file "$NOTES_FILE"

# The download must match what the cask promises, and the feed must not go live before it does.
STAGE=2
PUBLISHED="$(curl -sL "https://github.com/namekun/Changmun/releases/download/v$VERSION/$(basename "$DMG")" | shasum -a 256 | cut -d' ' -f1)"
[[ "$PUBLISHED" == "$SHA" ]] || { echo "Published DMG checksum $PUBLISHED does not match $SHA" >&2; exit 1; }

STAGE=3
git -C "$TAP_DIR" pull -q --ff-only
sed -i '' -e "s/version \"[0-9.]*\"/version \"$VERSION\"/" -e "s/sha256 \"[0-9a-f]*\"/sha256 \"$SHA\"/" "$CASK"
grep -q "version \"$VERSION\"" "$CASK" && grep -q "sha256 \"$SHA\"" "$CASK" \
    || { echo "The cask wasn't updated; fix $CASK by hand" >&2; exit 1; }
git -C "$TAP_DIR" add Casks/changmun.rb
git -C "$TAP_DIR" commit -qm "changmun $VERSION"
git -C "$TAP_DIR" push -q

STAGE=4
git push -q origin main
STAGE=5
# GitHub Pages takes a minute or two to serve the new feed.
for _ in $(seq 36); do
    SERVED="$(curl -fsL -m 20 "https://namekun.github.io/Changmun/appcast.xml" || true)"
    [[ "$SERVED" == "$(cat "$APPCAST")" ]] && break
    sleep 5
done
[[ "$SERVED" == "$(cat "$APPCAST")" ]] || echo "⚠ https://namekun.github.io/Changmun/appcast.xml doesn't serve this release's feed yet; check it" >&2
echo "Released v$VERSION ($DMG, sha256 $SHA)"
