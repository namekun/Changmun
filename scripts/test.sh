#!/bin/bash
# With only the Command Line Tools selected, SwiftPM can't find Testing.framework on its own.
set -euo pipefail
cd "$(dirname "$0")/.."
CLT=/Library/Developer/CommandLineTools/Library/Developer
if [[ "$(xcode-select -p 2>/dev/null || true)" == /Library/Developer/CommandLineTools && -d "$CLT/Frameworks/Testing.framework" ]]; then
    exec swift test -Xswiftc -F"$CLT/Frameworks" \
        -Xlinker -rpath -Xlinker "$CLT/Frameworks" -Xlinker -rpath -Xlinker "$CLT/usr/lib" "$@"
fi
exec swift test "$@"
