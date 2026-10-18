#!/bin/bash
# Everything that must pass before a release: run by release.sh first, and on its own any time.
#
#   scripts/preflight.sh            all checks
#   scripts/preflight.sh --local    skip the check that main is pushed
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/env.sh

LOCAL=0
[[ "${1:-}" == "--local" ]] && LOCAL=1
LOG="$(mktemp -d)"
step() { echo "▸ $*" >&2; }
fail() { echo "✘ $*" >&2; exit 1; }

if (( ! LOCAL )); then
    step "main, clean and the same as origin/main"
    [[ "$(git branch --show-current)" == "main" ]] || fail "Not on main"
    [[ -z "$(git status --porcelain)" ]] || fail "Working tree is not clean"
    git fetch -q origin main
    [[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] || fail "main is not origin/main; pull or push first"
fi

step "A clean release build has no warnings"
swift build -c release --scratch-path "$LOG/build" >"$LOG/build.txt" 2>&1 || { tail -30 "$LOG/build.txt" >&2; fail "Build failed"; }
# With only the Command Line Tools, SwiftPM hands the linker their Developer folders, which they don't have.
grep "warning:" "$LOG/build.txt" | grep -v "ld: warning: search path '/Library/Developer/CommandLineTools/Developer/.*' not found" \
    | sort -u >"$LOG/warnings.txt" || true
if [[ -s "$LOG/warnings.txt" ]]; then
    cat "$LOG/warnings.txt" >&2
    fail "Fix the warnings above"
fi

step "Tests"
./scripts/test.sh >"$LOG/test.txt" 2>&1 || { grep -E "✘|error:" "$LOG/test.txt" | head -40 >&2; fail "Tests failed"; }
grep -E "Test run with" "$LOG/test.txt" >&2

step "Every string is translated"
./scripts/check-strings.sh >&2 || fail "Translations are missing"

rm -rf "$LOG"
echo "✔ Preflight passed" >&2
