#!/bin/bash
# Is every control of Changmun named for VoiceOver? Puts Changmun Headless.app (English, off screen) into the states a VoiceOver or Full
# Keyboard Access user meets: the sidebar layout and the tabs-on-top layout (with the sidebar over the page), the command bar with
# suggestions, the find bar, the AI panel with a conversation, a waiting question and the chat history, every page of Settings, and the
# warning for a certificate that can't be verified. In each it reads the accessibility tree in the app's own process and fails for a
# button, check box, text field, menu button, link, image or pressable row without a name (scripts/audit-accessibility.py has the rules and the
# list of known exceptions). It checks names, not how a screen reader reads them: that takes a real VoiceOver session.
#
#   scripts/audit-accessibility.sh [state ...]    state: sidebar, top, command, find, flash, ai, settings, trust (all by default)
#   AUDIT_DUMP=folder scripts/audit-accessibility.sh    also keeps each state's whole tree as JSON in that folder
#
# Starts the headless app if it isn't running (and stops it again then; one that is already running keeps its language). Take a fresh
# bundle first: rm -rf build/Changmun.app && scripts/bundle.sh
set -uo pipefail
cd "$(dirname "$0")/.."
export ENDPOINT="${CHANGMUN_HEADLESS_ENDPOINT:-$HOME/Library/Application Support/Changmun Headless/control.json}"
STARTED=""

cleanup() { [[ -z "$STARTED" ]] || scripts/headless.sh stop >/dev/null; }
trap cleanup EXIT

if pgrep -f "^/.*/Changmun Headless[.]app/Contents/MacOS/Changmun" >/dev/null && [[ ! -f "$ENDPOINT" ]]; then echo "another Changmun Headless is running without an endpoint" >&2; exit 2; fi
if ! scripts/headless.sh call list_tabs >/dev/null 2>&1; then
    CHANGMUN_HEADLESS_ARGS='-AppleLanguages (en) -AppleLocale en_US' scripts/headless.sh start >/dev/null || exit 1
    STARTED=1
fi
python3 -I -B scripts/audit-accessibility.py "$@"
