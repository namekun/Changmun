# Sourced by release.sh (and tested by test-scripts.sh): the decisions of a release that can be checked on their own.

# Succeeds when $1 is a higher X.Y.Z than $2.
semver_gt() {
    local IFS=.
    local -a a=($1) b=($2)
    local i
    for i in 0 1 2; do
        (( 10#${a[i]:-0} > 10#${b[i]:-0} )) && return 0
        (( 10#${a[i]:-0} < 10#${b[i]:-0} )) && return 1
    done
    return 1
}

# Succeeds, and says why, when the release has to be refused: without a Developer ID (an expired or locked keychain looks
# like this) or with SKIP_NOTARIZE the DMG is ad-hoc signed or not notarized, and Gatekeeper rejects it on every other Mac
# once it is on GitHub, in the cask and in the Sparkle feed. ALLOW_UNSIGNED_RELEASE=1 is the explicit way past.
#   unsigned_release_refusal <developer id> <SKIP_NOTARIZE> <ALLOW_UNSIGNED_RELEASE>
unsigned_release_refusal() {
    [[ -n "$3" ]] && return 1
    if [[ -z "$1" ]]; then
        echo "No Developer ID Application identity in the keychain (expired, or the keychain is locked?): the DMG would be ad-hoc signed and not notarized. Fix the keychain, or set ALLOW_UNSIGNED_RELEASE=1 to release it anyway."
        return 0
    fi
    if [[ -n "$2" ]]; then
        echo "SKIP_NOTARIZE is set: the DMG would not be notarized. Unset it, or set ALLOW_UNSIGNED_RELEASE=1 to release it anyway."
        return 0
    fi
    return 1
}

# Puts a failed release back as it was before the commit and the tag, which are local until the tag is pushed. The tag goes
# when this script made it; the commit only when it is the one this script made ("Version X" on top of where it started).
#   revert_release <version> <HEAD before the commit> <1 if tagged> <1 if committed>
revert_release() {
    local version="$1" start="$2" tagged="$3" committed="$4"
    if [[ "$tagged" == 1 ]]; then git tag -d "v$version" >/dev/null 2>&1 || true; fi
    if [[ "$committed" == 1 ]]; then
        if [[ "$(git log -1 --format=%s)" == "Version $version" && "$(git rev-parse -q --verify 'HEAD^' || true)" == "$start" ]]; then
            git reset -q --hard "$start"
        else
            echo "HEAD isn't the \"Version $version\" commit this script made; it is left alone" >&2
        fi
    fi
}
