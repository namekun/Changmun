#!/bin/bash
# Releases a new version: runs every check (scripts/preflight.sh), bumps the version (Info.plist and the website,
# docs/index.html), builds the DMG and checks it (scripts/check-dmg.sh), and only then commits, tags, publishes the
# GitHub release and updates the Homebrew tap. The DMG is attached twice, as Changmun-<version>.dmg and as Changmun.dmg,
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

./scripts/preflight.sh

# Until the version commit is pushed, a failure puts the bumped files back.
PUSHED=0
STABLE="$(mktemp -d)"
trap 'rm -rf "$STABLE"; (( PUSHED )) || git checkout -q -- "$PLIST" "$PAGE"' EXIT

CURRENT="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")"
# The first release ships the version already in Info.plist; later ones bump it.
if [[ "$CURRENT" != "$VERSION" ]] || git rev-parse -q --verify "refs/tags/v$CURRENT" >/dev/null; then
    BUILD=$(( BUILD + 1 ))
fi
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" -c "Set :CFBundleVersion $BUILD" "$PLIST"
# Every place the page shows the version is <span data-version>X</span>.
sed -i '' -e "s|<span data-version>[0-9.]*</span>|<span data-version>$VERSION</span>|g" "$PAGE"
grep -q "<span data-version>$VERSION</span>" "$PAGE" || { echo "$PAGE has no <span data-version> to update" >&2; exit 1; }

DMG="$(./scripts/make-dmg.sh)"
./scripts/check-dmg.sh "$DMG" "$VERSION"

git diff --quiet -- "$PLIST" "$PAGE" || { git add "$PLIST" "$PAGE"; git commit -q -m "Version $VERSION"; }
git tag "v$VERSION"
git push -q origin main "v$VERSION"
PUSHED=1

cp "$DMG" "$STABLE/Changmun.dmg"
gh release create "v$VERSION" "$DMG" "$STABLE/Changmun.dmg" --title "v$VERSION" --notes-file "$NOTES_FILE"

SHA="$(shasum -a 256 "$DMG" | cut -d' ' -f1)"
git -C "$TAP_DIR" pull -q --ff-only
sed -i '' -e "s/version \"[0-9.]*\"/version \"$VERSION\"/" -e "s/sha256 \"[0-9a-f]*\"/sha256 \"$SHA\"/" "$CASK"
grep -q "version \"$VERSION\"" "$CASK" && grep -q "sha256 \"$SHA\"" "$CASK" \
    || { echo "The cask wasn't updated; fix $CASK by hand" >&2; exit 1; }
git -C "$TAP_DIR" add Casks/changmun.rb
git -C "$TAP_DIR" commit -qm "changmun $VERSION"
git -C "$TAP_DIR" push -q

# The download must match what the cask promises.
PUBLISHED="$(curl -sL "https://github.com/namekun/Changmun/releases/download/v$VERSION/$(basename "$DMG")" | shasum -a 256 | cut -d' ' -f1)"
[[ "$PUBLISHED" == "$SHA" ]] || { echo "Published DMG checksum $PUBLISHED does not match $SHA" >&2; exit 1; }
echo "Released v$VERSION ($DMG, sha256 $SHA)"
