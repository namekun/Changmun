#!/bin/bash
# With only the Command Line Tools selected, SwiftPM can't find Testing.framework on its own.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/env.sh
CLT=/Library/Developer/CommandLineTools/Library/Developer
if [[ "$(xcode-select -p 2>/dev/null || true)" == /Library/Developer/CommandLineTools && -d "$CLT/Frameworks/Testing.framework" ]]; then
    # Newer Command Line Tools keep the Testing macros in their own plugin folder.
    PLUGINS=()
    [[ -d "$CLT_ROOT/usr/lib/swift/host/plugins/testing" ]] && PLUGINS=(-Xswiftc -plugin-path -Xswiftc "$CLT_ROOT/usr/lib/swift/host/plugins/testing")
    exec swift test "${SCRATCH[@]}" -Xswiftc -F"$CLT/Frameworks" "${PLUGINS[@]}" \
        -Xlinker -rpath -Xlinker "$CLT/Frameworks" -Xlinker -rpath -Xlinker "$CLT/usr/lib" "$@"
fi
exec swift test "${SCRATCH[@]}" "$@"
