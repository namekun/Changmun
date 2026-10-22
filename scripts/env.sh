# Sourced by the build scripts.

# The Command Line Tools' macOS 27 SDK makes SwiftUI's @State a macro whose plugin only Xcode ships, so with the
# Command Line Tools selected, build against the macOS 26 SDK when it is there.
CLT_ROOT=/Library/Developer/CommandLineTools
if [[ -z "${SDKROOT:-}" && "$(xcode-select -p 2>/dev/null || true)" == "$CLT_ROOT" && -d "$CLT_ROOT/SDKs/MacOSX26.sdk" ]]; then
    export SDKROOT="$CLT_ROOT/SDKs/MacOSX26.sdk"
fi

# Build products live outside the project: a synced folder (iCloud Desktop) adds Finder info that codesign rejects.
SCRATCH=(--scratch-path "${CHANGMUN_SCRATCH:-$HOME/Library/Caches/Changmun/build}")

# Release builds are signed with the Developer ID in the keychain (or $SIGN_IDENTITY) under the hardened runtime,
# and the DMG is notarized with the notarytool profile $NOTARY_PROFILE. Without a Developer ID, and for debug
# builds, everything is ad-hoc signed as before.
NOTARY_PROFILE="${NOTARY_PROFILE:-changmun}"
# An App Store Connect API key named in ~/.config/changmun/notary.env (NOTARY_KEY, NOTARY_KEY_ID, NOTARY_ISSUER) is used
# instead of the keychain profile when it is there.
[[ -f "$HOME/.config/changmun/notary.env" ]] && source "$HOME/.config/changmun/notary.env"
if [[ -n "${NOTARY_KEY:-}" ]]; then
    NOTARY_AUTH=(--key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER")
else
    NOTARY_AUTH=(--keychain-profile "$NOTARY_PROFILE")
fi
developer_id() {
    if [[ -n "${SIGN_IDENTITY:-}" ]]; then echo "$SIGN_IDENTITY"; return; fi
    security find-identity -v -p codesigning 2>/dev/null | sed -nE 's/.*"(Developer ID Application: [^"]+)".*/\1/p' | head -1
}
