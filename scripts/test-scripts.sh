#!/bin/bash
# Tests of the release scripts' decisions, which no Swift test can reach: scripts/release-lib.sh's functions, check-dmg.sh's
# release mode against a made-up ad-hoc signed DMG, and headless.sh's check that a process ID is the headless app.
# Touches nothing outside a temporary folder. Run by scripts/preflight.sh, and on its own any time.
set -uo pipefail
cd "$(dirname "$0")/.."
source scripts/release-lib.sh

FAILED=0
ok() { echo "  ok: $1"; }
bad() { echo "  FAIL: $1" >&2; FAILED=1; }
check() { local what="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$what"; else bad "$what"; fi }
refuses() { ! "$@"; }
WORK="$(mktemp -d)"
trap '[[ -n "${KEEP:-}" ]] || rm -rf "$WORK"' EXIT

echo "semver_gt"
check "0.7.5 > 0.7.4" semver_gt 0.7.5 0.7.4
check "0.10.0 > 0.9.9" semver_gt 0.10.0 0.9.9
check "1.0.0 > 0.99.99" semver_gt 1.0.0 0.99.99
check "0.7.4 is not > 0.7.4" refuses semver_gt 0.7.4 0.7.4
check "0.7.3 is not > 0.7.4" refuses semver_gt 0.7.3 0.7.4
check "0.9.0 is not > 0.10.0" refuses semver_gt 0.9.0 0.10.0

echo "unsigned_release_refusal"
check "a Developer ID release passes" refuses unsigned_release_refusal "Developer ID Application: X (T)" "" ""
check "no Developer ID is refused" unsigned_release_refusal "" "" ""
check "SKIP_NOTARIZE is refused" unsigned_release_refusal "Developer ID Application: X (T)" 1 ""
check "the override allows no Developer ID" refuses unsigned_release_refusal "" "" 1
check "the override allows SKIP_NOTARIZE" refuses unsigned_release_refusal "Developer ID Application: X (T)" 1 1
check "the refusal says how to override" bash -c 'source scripts/release-lib.sh; unsigned_release_refusal "" "" "" 2>&1 | grep -q ALLOW_UNSIGNED_RELEASE'

echo "revert_release"
repo() {
    local dir="$WORK/$1"
    git init -q "$dir"
    git -C "$dir" -c user.name=t -c user.email=t@t commit -q --allow-empty -m "Before"
    echo "$dir"
}
commit() { git -C "$1" -c user.name=t -c user.email=t@t commit -q --allow-empty -m "$2"; }
R="$(repo made)"
START="$(git -C "$R" rev-parse HEAD)"
commit "$R" "Version 1.2.3"
git -C "$R" tag v1.2.3
(cd "$R" && revert_release 1.2.3 "$START" 1 1) >/dev/null 2>&1
check "the version commit is gone" test "$(git -C "$R" rev-parse HEAD)" = "$START"
check "the tag is gone" refuses git -C "$R" rev-parse -q --verify refs/tags/v1.2.3
R="$(repo foreign)"
START="$(git -C "$R" rev-parse HEAD)"
commit "$R" "Something else"
OTHER="$(git -C "$R" rev-parse HEAD)"
git -C "$R" tag v1.2.3
(cd "$R" && revert_release 1.2.3 "$START" 1 1) >/dev/null 2>&1
check "a commit the script didn't make is kept" test "$(git -C "$R" rev-parse HEAD)" = "$OTHER"
check "its tag is still removed" refuses git -C "$R" rev-parse -q --verify refs/tags/v1.2.3
R="$(repo tagonly)"
START="$(git -C "$R" rev-parse HEAD)"
git -C "$R" tag v1.2.3
(cd "$R" && revert_release 1.2.3 "$START" 1 0) >/dev/null 2>&1
check "a tag without a commit of ours: HEAD stays" test "$(git -C "$R" rev-parse HEAD)" = "$START"
check "a tag without a commit of ours: tag removed" refuses git -C "$R" rev-parse -q --verify refs/tags/v1.2.3
R="$(repo nothing)"
START="$(git -C "$R" rev-parse HEAD)"
git -C "$R" tag v1.2.3
(cd "$R" && revert_release 1.2.3 "$START" 0 0) >/dev/null 2>&1
check "nothing made, nothing undone" git -C "$R" rev-parse -q --verify refs/tags/v1.2.3 >/dev/null

echo "check-dmg.sh release mode"
if command -v clang >/dev/null && command -v hdiutil >/dev/null; then
    APP="$WORK/dmg/Changmun.app"
    mkdir -p "$APP/Contents/MacOS"
    echo 'int main(void) { return 0; }' >"$WORK/main.c"
    clang -arch arm64 -o "$APP/Contents/MacOS/Changmun" "$WORK/main.c"
    cat >"$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>io.github.namekun.Changmun</string>
<key>CFBundleShortVersionString</key><string>9.9.9</string>
<key>CFBundleExecutable</key><string>Changmun</string>
</dict></plist>
PLIST
    codesign --force --sign - "$APP" >/dev/null 2>&1
    ln -s /Applications "$WORK/dmg/Applications"
    hdiutil create -quiet -volname Changmun -srcfolder "$WORK/dmg" -format UDZO "$WORK/Fake.dmg"
    export CHANGMUN_ENDPOINT="$WORK/no-control.json"
    RELEASE=1 scripts/check-dmg.sh "$WORK/Fake.dmg" 9.9.9 >"$WORK/release.txt" 2>&1
    check "an ad-hoc DMG fails in release mode" test $? -ne 0
    check "and says it needs a Developer ID" grep -q "Developer ID" "$WORK/release.txt"
    check "before it looks at Sparkle" refuses grep -q "Sparkle" "$WORK/release.txt"
    scripts/check-dmg.sh "$WORK/Fake.dmg" 9.9.9 >"$WORK/plain.txt" 2>&1
    check "without release mode an ad-hoc DMG gets past the signature" grep -q "Sparkle" "$WORK/plain.txt"
    RELEASE=1 SKIP_NOTARIZE=1 scripts/check-dmg.sh "$WORK/Fake.dmg" 9.9.9 >"$WORK/skip.txt" 2>&1
    check "SKIP_NOTARIZE doesn't loosen release mode" test $? -ne 0
    (( FAILED )) && { echo "--- release mode said:" >&2; cat "$WORK/release.txt" >&2; echo "--- plain mode said:" >&2; cat "$WORK/plain.txt" >&2; }
else
    bad "clang and hdiutil are needed for the check-dmg tests"
fi

echo "headless.sh process check"
source scripts/headless-lib.sh
sleep 30 & OTHER=$!
check "a live process that isn't the headless app is not it" refuses is_headless_pid "$OTHER"
check "a dead process isn't it" refuses is_headless_pid 99999999
kill "$OTHER"; wait "$OTHER" 2>/dev/null
check "a process whose command is the headless app is it" is_headless_command "/x/build/Changmun Headless.app/Contents/MacOS/Changmun"
check "the user's agent copy is not the test copy" refuses is_headless_command "/x/Changmun Agent.app/Contents/MacOS/Changmun"
check "the installed app is not it" refuses is_headless_command "/Applications/Changmun.app/Contents/MacOS/Changmun"

(( FAILED )) && { echo "✘ script tests failed" >&2; exit 1; }
echo "✔ script tests passed"
