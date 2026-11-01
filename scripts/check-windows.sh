#!/bin/bash
# Every window the app makes is an AppWindow (Sources/Changmun/DesignSystem/AppWindow.swift), which a headless copy keeps off every screen.
# Fails for an NSWindow or NSPanel made, or subclassed, anywhere else in the given folder (default: Sources).
#
#   scripts/check-windows.sh [folder]
set -uo pipefail
cd "$(dirname "$0")/.."
FOLDER="${1:-Sources}"
FOUND="$(grep -rnE '\bNS(Window|Panel)\(|\bclass[[:space:]]+[A-Za-z_]+[[:space:]]*:[[:space:]]*NS(Window|Panel)\b' "$FOLDER" --include='*.swift' | grep -v '/AppWindow\.swift:' | grep -vE '^[^:]+:[0-9]+:[[:space:]]*//' || true)"
if [[ -n "$FOUND" ]]; then
    echo "A window must be an AppWindow, so that a headless copy keeps it off screen:" >&2
    echo "$FOUND" >&2
    exit 1
fi
