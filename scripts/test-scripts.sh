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
UI_DIRS=(Sources/Changmun/Views Sources/Changmun/PageCard Sources/Changmun/Sidebar Sources/Changmun/Settings Sources/Changmun/DesignSystem Sources/Changmun/StartPage)
check "the UI folders exist" test -d "${UI_DIRS[0]}" -a -d "${UI_DIRS[1]}" -a -d "${UI_DIRS[2]}" -a -d "${UI_DIRS[3]}" -a -d "${UI_DIRS[4]}" -a -d "${UI_DIRS[5]}"
mkdir -p "$WORK/guard"
printf 'browser.tabs = []\nbrowser.tabs.append(tab)\nstore.isRunning=true\nchat.items.removeAll()\n' >"$WORK/guard/writes.swift"
printf 'if browser.activeID == tab.id {}\nlet n = browser.tabs.count\nif store.items != other {}\nif a.groups <= b {}\n// browser.tabs = []\n' >"$WORK/guard/reads.swift"
check "the guard sees assignments and mutations" test "$(state_writes "$WORK/guard/writes.swift" | wc -l)" -eq 4
check "the guard lets reads and comparisons be" refuses test -n "$(state_writes "$WORK/guard/reads.swift")"
state_writes "${UI_DIRS[@]}" >"$WORK/state-writes.txt"
check "the UI folders don't change Browser, Tab or ChatStore state directly" test ! -s "$WORK/state-writes.txt"
[[ -s "$WORK/state-writes.txt" ]] && cat "$WORK/state-writes.txt" >&2

echo "core guard"
# ChangmunCore is the layer under the app: the compiler already refuses an import of the app; this keeps it free of the UI frameworks too.
UI_IMPORT='^[[:space:]]*(@[A-Za-z]+[[:space:]]+)?import[[:space:]]+((struct|class|enum|protocol|func|var|let|typealias)[[:space:]]+)?(AppKit|SwiftUI|WebKit|UIKit)\b'
core_ui_imports() { grep -rnE "$UI_IMPORT" "$@"; }
check "the core folder exists" test -d Sources/ChangmunCore
printf 'import AppKit\n@preconcurrency import WebKit\n  import SwiftUI\nimport struct SwiftUI.Color\n' >"$WORK/guard/ui.swift"
printf 'import Foundation\nimport SQLite3\n// import AppKit\nlet WebKitName = 1\n' >"$WORK/guard/foundation.swift"
check "the guard sees the UI frameworks imported" test "$(core_ui_imports "$WORK/guard/ui.swift" | wc -l)" -eq 4
check "the guard lets Foundation and comments be" refuses test -n "$(core_ui_imports "$WORK/guard/foundation.swift")"
core_ui_imports Sources/ChangmunCore >"$WORK/core-ui.txt"
check "ChangmunCore imports no UI framework" test ! -s "$WORK/core-ui.txt"
[[ -s "$WORK/core-ui.txt" ]] && cat "$WORK/core-ui.txt" >&2

echo "layer guard"
# The model and storage folders don't know the view layer: a tab reaches whatever shows its page through the PageHost protocol.
MODEL_DIRS=(Sources/Changmun/Tabs Sources/Changmun/Browser Sources/Changmun/Storage Sources/ChangmunCore)
VIEW_NAMES='\b(WebViewHost|PassiveHost|HeldPagesHost|PageCard)\b'
check "the model folders exist" test -d "${MODEL_DIRS[0]}" -a -d "${MODEL_DIRS[1]}" -a -d "${MODEL_DIRS[2]}" -a -d "${MODEL_DIRS[3]}"
printf 'var x = PageOwner<WebViewHost.Container>()\n' >"$WORK/guard/view.swift"
printf 'var x = PageOwner<any PageHost>()\n' >"$WORK/guard/model.swift"
check "the layer guard sees a view type" grep -qE "$VIEW_NAMES" "$WORK/guard/view.swift"
check "the layer guard lets the protocol be" refuses grep -qE "$VIEW_NAMES" "$WORK/guard/model.swift"
grep -rnE "$VIEW_NAMES" "${MODEL_DIRS[@]}" >"$WORK/layer.txt"
check "the model folders don't mention the view layer" test ! -s "$WORK/layer.txt"
[[ -s "$WORK/layer.txt" ]] && cat "$WORK/layer.txt" >&2

echo "grid guard"
# Spacing is 0, 4 and multiples of 8 (4 only for tight gaps inside a component); scripts/check-grid.py reads .padding(...), spacing: and Spacer(minLength:.
grid() { python3 -I -B scripts/check-grid.py "$@"; }
printf '.padding(.horizontal, 12)\n' >"$WORK/guard/grid-padding.swift"
printf 'VStack(spacing: 6) {\n' >"$WORK/guard/grid-spacing.swift"
printf 'Spacer(minLength: 90)\n' >"$WORK/guard/grid-spacer.swift"
printf 'Grid(horizontalSpacing: 14, verticalSpacing: 8) {\n' >"$WORK/guard/grid-axis.swift"
printf 'Text("a").padding(.leading, CGFloat(depth) * 14)\n' >"$WORK/guard/grid-nested.swift"
printf '.padding(.leading, Metrics.inset + 3)\n' >"$WORK/guard/grid-mixed.swift"
printf '.padding(.leading, 1) // grid-exempt: optical nudge\n' >"$WORK/guard/grid-marked.swift"
printf '// .padding(12)\n.padding(8)\n.padding(.top, 0)\nVStack(spacing: 4)\nHStack(spacing: Metrics.rowGap)\n.padding(.top, Metrics.section - 2 * Metrics.rowGap)\n.padding(.leading, 2 * Metrics.inset)\n.padding(.horizontal, min(64, max(16, (w - 480) / 2)))\nSpacer(minLength: 40)\nGridItem(.adaptive(minimum: 40), spacing: 4)\n.frame(width: 12).font(.system(size: 13))\n' >"$WORK/guard/grid-fine.swift"
check "the guard fails a padding of 12" refuses grid "$WORK/guard/grid-padding.swift"
check "the guard fails a spacing of 6" refuses grid "$WORK/guard/grid-spacing.swift"
check "the guard fails a Spacer's minimum length of 90" refuses grid "$WORK/guard/grid-spacer.swift"
check "the guard fails a grid's horizontalSpacing of 14" refuses grid "$WORK/guard/grid-axis.swift"
check "the guard fails a value after a call inside the padding" refuses grid "$WORK/guard/grid-nested.swift"
check "the guard fails a literal beside a Metrics token" refuses grid "$WORK/guard/grid-mixed.swift"
check "the guard names the file, the line and the value" bash -c 'python3 -I -B scripts/check-grid.py "$1" 2>&1 | grep -q "grid-padding.swift:1: 12 is not on the 8-point grid"' _ "$WORK/guard/grid-padding.swift"
check "the guard lets a line marked grid-exempt be" grid "$WORK/guard/grid-marked.swift"
check "the guard lets 0, 4, multiples of 8, Metrics tokens, counts and divisors be" grid "$WORK/guard/grid-fine.swift"
check "the guard reads a folder" refuses grid "$WORK/guard"
grid >"$WORK/grid.txt" 2>&1
check "the spacing in Sources/Changmun is on the grid" test $? -eq 0
[[ -s "$WORK/grid.txt" ]] && cat "$WORK/grid.txt" >&2
echo "design guard"
# Type comes from the Font tokens, corners are 4, 8, 12 or 16, shadows are e1, e2 or e3; scripts/check-design.py reads .system(size:, cornerRadius:, radius: and .shadow(.
design() { python3 -I -B scripts/check-design.py "$@"; }
mkdir -p "$WORK/design/DesignSystem"
printf 'Text("a").font(.system(size: 13, weight: .semibold))\n' >"$WORK/design/design-font.swift"
printf 'Image(systemName: "xmark").font(.system(size: 8, weight: .bold))\n' >"$WORK/design/design-glyph.swift"
printf 'RoundedRectangle(cornerRadius: 10, style: .continuous)\n' >"$WORK/design/design-corner.swift"
printf 'RoundedRectangle(cornerRadius: 2.5)\n' >"$WORK/design/design-fraction.swift"
printf '.startPlate(radius: 14, fill: Theme.field)\n' >"$WORK/design/design-plate.swift"
printf 'content.shadow(color: .black, radius: 3)\n' >"$WORK/design/design-shadow.swift"
printf 'Text("a").font(.system(size: 8)) // design-exempt: a badge inside an icon\nRoundedRectangle(cornerRadius: 7) // design-exempt: a scaled-down tile\n' >"$WORK/design/design-marked.swift"
printf '// .system(size: 13)\n/// cornerRadius: 10\n.font(.body)\n.font(.symbolInline)\nRoundedRectangle(cornerRadius: 4)\nRoundedRectangle(cornerRadius: 8, style: .continuous)\nRoundedRectangle(cornerRadius: Metrics.cardRadius)\nRoundedRectangle(cornerRadius: size * 0.24)\n.floatingPanel(radius: 16)\n.startPlate(radius: Metrics.cardRadius)\n.e2()\n.blur(radius: 24)\nstyle="border-radius: 6px"\nhost.attachShadow(mode)\n' >"$WORK/design/design-fine.swift"
printf 'func e2() -> some View { shadow(color: .clear, radius: 12, y: 4) }\n.font(.system(size: 28, weight: .semibold))\n' >"$WORK/design/DesignSystem/Theme.swift"
printf 'func e2() -> some View { shadow(color: .clear, radius: 12, y: 4) }\n' >"$WORK/design/DesignSystem/Controls.swift"
check "the design guard fails a font size literal" refuses design "$WORK/design/design-font.swift"
check "the design guard fails a symbol size literal" refuses design "$WORK/design/design-glyph.swift"
check "the design guard fails a corner radius of 10" refuses design "$WORK/design/design-corner.swift"
check "the design guard fails a fractional corner radius" refuses design "$WORK/design/design-fraction.swift"
check "the design guard fails a plate's radius of 14" refuses design "$WORK/design/design-plate.swift"
check "the design guard fails a shadow outside the design system" refuses design "$WORK/design/design-shadow.swift"
check "the design guard names the file, the line and the value" bash -c 'python3 -I -B scripts/check-design.py "$1" 2>&1 | grep -q "design-corner.swift:1: a corner radius of 10"' _ "$WORK/design/design-corner.swift"
check "the design guard lets a line marked design-exempt be" design "$WORK/design/design-marked.swift"
check "the design guard lets tokens, 4, 8, 12, 16, shares of a plate, comments and web text be" design "$WORK/design/design-fine.swift"
check "the design guard lets the design system define the tokens and the shadows" design "$WORK/design/DesignSystem"
check "the design guard reads a folder" refuses design "$WORK/design"
design >"$WORK/design.txt" 2>&1
check "the type, corners and shadows in Sources/Changmun come from the tokens" test $? -eq 0
[[ -s "$WORK/design.txt" ]] && cat "$WORK/design.txt" >&2
echo "spacing grid guard"
# The homepage's spacing sits on an 8 grid with a 4 half-step: every px in a padding, margin or gap (the CSS and style="" attributes) is a multiple of 8, or 4.
# Exempt: the -1px hairline overlap of .sr, and the middle (fluid) argument of clamp(), which may carry any px term; its bounds are checked.
off_grid_spacing() {
    { sed -n '/<style>/,/<\/style>/p' "$1"; grep -oE 'style="[^"]*"' "$1"; } \
        | grep -oE '(^|[;{ "])((padding|margin)[a-z-]*|(row-|column-)?gap|--gap|--pad-sec):[^;}"]*' \
        | sed -E 's/clamp\(([^,)]*),[^,)]*,/clamp(\1,/g; s/env\([^)]*\)//g' \
        | grep -oE '(^|[^0-9.])-?[0-9.]+px' | grep -oE '\-?[0-9.]+px' | grep -vx -e '-1px' \
        | awk '{ v = $0; sub(/px$/, "", v); if (v % 8 != 0 && v != 4) print $0 }'
}
cat >"$WORK/guard/grid-bad.html" <<'HTML'
<style>
.a { padding: 6px 16px; margin: clamp(10px, 2vw, 24px) auto 0; }
.b { gap: 12px 8px; }
</style>
<p style="margin-top:20px">
HTML
cat >"$WORK/guard/grid-ok.html" <<'HTML'
<style>
.a { padding: 0 16px 4px; margin: -1px; gap: clamp(16px, .9vw + 11px, 24px); }
.b { padding: 24px 0 max(32px, env(safe-area-inset-bottom)); --pad-sec: clamp(112px, 5.6vw + 88px, 168px); }
.c { width: 22px; font-size: 13px; top: 6px; }
</style>
<p style="margin:clamp(16px,2vw,24px) auto 0;width:92%">
HTML
check "the guard sees values off the grid" test "$(off_grid_spacing "$WORK/guard/grid-bad.html" | tr '\n' ' ')" = "6px 10px 12px 20px "
check "the guard lets the grid, hairlines, fluid middles and env() be" refuses test -n "$(off_grid_spacing "$WORK/guard/grid-ok.html")"
check "the homepage exists" test -f docs/index.html
off_grid_spacing docs/index.html >"$WORK/grid.txt"
check "the homepage's spacing is on the 8 grid" test ! -s "$WORK/grid.txt"
[[ -s "$WORK/grid.txt" ]] && { echo "off the grid:" >&2; cat "$WORK/grid.txt" >&2; }

(( FAILED )) && { echo "✘ script tests failed" >&2; exit 1; }
# The test scripts leave the user's screen alone: AppleScript needs the Mac's automation permission, whose prompt would land on it.
if grep -l 'osascript' scripts/*.sh scripts/*.py 2>/dev/null | grep -v '^scripts/test-scripts.sh$' | grep -q .; then
    echo "scripts must not use osascript" >&2
    exit 1
fi
echo "  ok: no script uses AppleScript"

echo "✔ script tests passed"
