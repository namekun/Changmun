#!/bin/bash
# Tests of the release scripts' decisions, which no Swift test can reach: scripts/release-lib.sh's functions, check-dmg.sh's
# release mode against a made-up ad-hoc signed DMG, and headless.sh's check that a process ID is the headless app.
# Touches nothing outside a temporary folder. Run by scripts/preflight.sh, and on its own any time.
set -uo pipefail
cd "$(dirname "$0")/.."
source scripts/release-lib.sh
# release.sh runs this with RELEASE=1 (and maybe SKIP_NOTARIZE) set: each case says for itself which mode it is in.
unset RELEASE SKIP_NOTARIZE ALLOW_UNSIGNED_RELEASE

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
check "an identity that is not a Developer ID Application one is refused" unsigned_release_refusal "Apple Development: X (T)" "" ""
check "the override allows it" refuses unsigned_release_refusal "Apple Development: X (T)" "" 1
check "the refusal names the identity kind" bash -c 'source scripts/release-lib.sh; unsigned_release_refusal "3rd Party Mac Developer Application: X" "" "" 2>&1 | grep -q "Developer ID Application"'
check "the refusal says how to override" bash -c 'source scripts/release-lib.sh; unsigned_release_refusal "" "" "" 2>&1 | grep -q ALLOW_UNSIGNED_RELEASE'

echo "identity_name"
FOUND='  1) 0123456789ABCDEF0123456789ABCDEF01234567 "Developer ID Application: X (T)"
  2) 89ABCDEF0123456789ABCDEF0123456789ABCDEF "Apple Development: Y (U)"
     2 valid identities found'
check "a name is a name" test "$(identity_name "Developer ID Application: X (T)" "$FOUND")" = "Developer ID Application: X (T)"
check "a hash is looked up" test "$(identity_name 0123456789abcdef0123456789abcdef01234567 "$FOUND")" = "Developer ID Application: X (T)"
check "a hash of another kind is that kind" test "$(identity_name 89ABCDEF0123456789ABCDEF0123456789ABCDEF "$FOUND")" = "Apple Development: Y (U)"
check "an unknown hash gives nothing" test -z "$(identity_name FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF "$FOUND")"

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
# Edits made during the release survive the revert: --keep, not --hard.
R="$(repo unrelated)"
echo one >"$R/mine.txt"; echo base >"$R/plist.txt"
git -C "$R" add plist.txt mine.txt; git -C "$R" -c user.name=t -c user.email=t@t commit -q -m "Files"
START="$(git -C "$R" rev-parse HEAD)"
echo bumped >"$R/plist.txt"; git -C "$R" add plist.txt; git -C "$R" -c user.name=t -c user.email=t@t commit -q -m "Version 1.2.3"
git -C "$R" tag v1.2.3
echo "edited meanwhile" >"$R/mine.txt"
(cd "$R" && revert_release 1.2.3 "$START" 1 1) >/dev/null 2>&1
check "the version commit is gone, an unrelated edit stays" test "$(git -C "$R" rev-parse HEAD)" = "$START" -a "$(cat "$R/mine.txt")" = "edited meanwhile"
check "the bumped file is back" test "$(cat "$R/plist.txt")" = base
R="$(repo conflict)"
echo base >"$R/plist.txt"; git -C "$R" add plist.txt; git -C "$R" -c user.name=t -c user.email=t@t commit -q -m "Files"
START="$(git -C "$R" rev-parse HEAD)"
echo bumped >"$R/plist.txt"; git -C "$R" add plist.txt; git -C "$R" -c user.name=t -c user.email=t@t commit -q -m "Version 1.2.3"
VERSION_COMMIT="$(git -C "$R" rev-parse HEAD)"
echo "my edit" >"$R/plist.txt"
(cd "$R" && revert_release 1.2.3 "$START" 0 1) >"$WORK/conflict.txt" 2>&1
check "an edit in a file the commit changed is not overwritten" test "$(cat "$R/plist.txt")" = "my edit"
check "and the commit stays" test "$(git -C "$R" rev-parse HEAD)" = "$VERSION_COMMIT"
check "and it says what to do" grep -q "git reset --keep $START" "$WORK/conflict.txt"

echo "origin_has_tag"
R="$(repo withorigin)"
git init -q --bare "$WORK/origin.git"
git -C "$R" remote add origin "$WORK/origin.git"
git -C "$R" tag v1.2.3
check "no tag on origin: no" test "$(cd "$R" && origin_has_tag 1.2.3)" = no
git -C "$R" push -q origin v1.2.3
check "tag on origin: yes" test "$(cd "$R" && origin_has_tag 1.2.3)" = yes
git -C "$R" remote set-url origin "$WORK/not-there.git"
check "origin that can't be reached: unknown, not no" test "$(cd "$R" && origin_has_tag 1.2.3)" = unknown

# Mounting a DMG fails now and then for no reason of ours (hdiutil busy, Spotlight): these cases run once more if they fail, and
# what they printed is shown when they fail twice. Only a pass of the second try counts when the first did not.
dmg_cases() {
    FAILED=0
    if command -v clang >/dev/null && command -v hdiutil >/dev/null; then
        rm -rf "$WORK/dmg" "$WORK/Fake.dmg"
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
        hdiutil create -quiet -volname Changmun -srcfolder "$WORK/dmg" -format UDZO "$WORK/Fake.dmg" || bad "hdiutil could not make the test DMG"
        export CHANGMUN_ENDPOINT="$WORK/no-control.json"
        RELEASE=1 scripts/check-dmg.sh "$WORK/Fake.dmg" 9.9.9 >"$WORK/release.txt" 2>&1
        check "an ad-hoc DMG fails in release mode" test $? -ne 0
        check "and says it needs a Developer ID" grep -q "Developer ID" "$WORK/release.txt"
        check "before it looks at Sparkle" refuses grep -q "Sparkle" "$WORK/release.txt"
        scripts/check-dmg.sh "$WORK/Fake.dmg" 9.9.9 >"$WORK/plain.txt" 2>&1
        check "without release mode an ad-hoc DMG gets past the signature" grep -q "Sparkle" "$WORK/plain.txt"
        RELEASE=1 SKIP_NOTARIZE=1 scripts/check-dmg.sh "$WORK/Fake.dmg" 9.9.9 >"$WORK/skip.txt" 2>&1
        check "SKIP_NOTARIZE doesn't loosen release mode" test $? -ne 0
        if (( FAILED )); then
            local file
            for file in release plain skip; do echo "--- check-dmg.sh ($file) said:" >&2; cat "$WORK/$file.txt" >&2; done
        fi
    else
        bad "clang and hdiutil are needed for the check-dmg tests"
    fi
}
echo "check-dmg.sh release mode"
EARLIER_FAILURES=$FAILED
dmg_cases >"$WORK/dmg-first.txt" 2>&1
if (( FAILED )); then
    dmg_cases >"$WORK/dmg-second.txt" 2>&1
    if (( FAILED )); then
        echo "--- first try:" >&2; cat "$WORK/dmg-first.txt" >&2
        echo "--- second try:" >&2; cat "$WORK/dmg-second.txt" >&2
    else
        cat "$WORK/dmg-second.txt"
        echo "  (the first try failed and the second passed: a mount that failed for no reason of ours)"
    fi
else
    cat "$WORK/dmg-first.txt"
fi
(( EARLIER_FAILURES )) && FAILED=1

echo "headless.sh process check"
source scripts/headless-lib.sh
sleep 30 & OTHER=$!
check "a live process that isn't the headless app is not it" refuses is_headless_pid "$OTHER"
check "a dead process isn't it" refuses is_headless_pid 99999999
kill "$OTHER"; wait "$OTHER" 2>/dev/null
check "a process whose command is the headless app is it" is_headless_command "/x/build/Changmun Headless.app/Contents/MacOS/Changmun"
check "the user's agent copy is not the test copy" refuses is_headless_command "/x/Changmun Agent.app/Contents/MacOS/Changmun"
check "the installed app is not it" refuses is_headless_command "/Applications/Changmun.app/Contents/MacOS/Changmun"

echo "headless.sh stop"
STOPDIR="$WORK/stop/Changmun Headless.app/Contents/MacOS"
mkdir -p "$STOPDIR"
printf '#!/bin/bash\ntrap "" TERM\nwhile true; do sleep 1; done\n' >"$STOPDIR/Changmun"
chmod +x "$STOPDIR/Changmun"
"$STOPDIR/Changmun" >/dev/null 2>&1 &
STUCK=$!
sleep 0.3
printf '{"port": 1, "token": "t", "pid": %s}' "$STUCK" >"$WORK/stuck.json"
CHANGMUN_HEADLESS_ENDPOINT="$WORK/stuck.json" CHANGMUN_STOP_WAIT=1 scripts/headless.sh stop >"$WORK/stop.txt" 2>&1
check "a process that ignores the request makes stop fail" test $? -ne 0
check "and says so" grep -q "did not exit" "$WORK/stop.txt"
check "its control.json is kept" test -f "$WORK/stuck.json"
kill -9 "$STUCK" 2>/dev/null; wait "$STUCK" 2>/dev/null
CHANGMUN_HEADLESS_ENDPOINT="$WORK/stuck.json" CHANGMUN_STOP_WAIT=1 scripts/headless.sh stop >"$WORK/stop2.txt" 2>&1
check "once it is gone, stop clears the file" test ! -f "$WORK/stuck.json"

echo "state guard"
# Browser, Tab and ChatStore state is changed by their own methods and extensions; the UI folders only read it.
STATE_WRITE='\.(tabs|activeID|spaceID|groups|peek|closedTabs|items|isRunning|sessionID)[[:space:]]*(=[^=]|\+=|\.append|\.remove|\.insert)'
state_writes() { grep -rnE "$STATE_WRITE" "$@" | grep -vE '^[^:]+:[0-9]+:[[:space:]]*//'; }
UI_DIRS=(Sources/Changmun/Views Sources/Changmun/PageCard Sources/Changmun/Sidebar Sources/Changmun/Settings Sources/Changmun/DesignSystem)
check "the UI folders exist" test -d "${UI_DIRS[0]}" -a -d "${UI_DIRS[1]}" -a -d "${UI_DIRS[2]}" -a -d "${UI_DIRS[3]}" -a -d "${UI_DIRS[4]}"
mkdir -p "$WORK/guard"
printf 'browser.tabs = []\nbrowser.tabs.append(tab)\nstore.isRunning=true\nchat.items.removeAll()\n' >"$WORK/guard/writes.swift"
printf 'if browser.activeID == tab.id {}\nlet n = browser.tabs.count\nif store.items != other {}\nif a.groups <= b {}\n// browser.tabs = []\n' >"$WORK/guard/reads.swift"
check "the guard sees assignments and mutations" test "$(state_writes "$WORK/guard/writes.swift" | wc -l)" -eq 4
check "the guard lets reads and comparisons be" refuses test -n "$(state_writes "$WORK/guard/reads.swift")"
state_writes "${UI_DIRS[@]}" >"$WORK/state-writes.txt"
check "the UI folders don't change Browser, Tab or ChatStore state directly" test ! -s "$WORK/state-writes.txt"
[[ -s "$WORK/state-writes.txt" ]] && cat "$WORK/state-writes.txt" >&2

(( FAILED )) && { echo "✘ script tests failed" >&2; exit 1; }
echo "✔ script tests passed"
