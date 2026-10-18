# Sourced by the build scripts.

# The Command Line Tools' macOS 27 SDK makes SwiftUI's @State a macro whose plugin only Xcode ships, so with the
# Command Line Tools selected, build against the macOS 26 SDK when it is there.
CLT_ROOT=/Library/Developer/CommandLineTools
if [[ -z "${SDKROOT:-}" && "$(xcode-select -p 2>/dev/null || true)" == "$CLT_ROOT" && -d "$CLT_ROOT/SDKs/MacOSX26.sdk" ]]; then
    export SDKROOT="$CLT_ROOT/SDKs/MacOSX26.sdk"
fi

# Build products live outside the project: a synced folder (iCloud Desktop) adds Finder info that codesign rejects.
SCRATCH=(--scratch-path "$HOME/Library/Caches/Changmun/build")
