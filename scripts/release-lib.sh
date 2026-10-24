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

# The name of a signing identity: a SHA-1 hash (which codesign takes as well) is looked up in the output of
# `security find-identity -v -p codesigning`; anything else is a name already.
#   identity_name <identity> <find-identity output>
identity_name() {
    if [[ "$1" =~ ^[0-9A-Fa-f]{40}$ ]]; then
        printf '%s\n' "$2" | grep -i -F "$1" | sed -nE 's/.*"([^"]+)".*/\1/p' | head -1
    else
        echo "$1"
    fi
}

# Succeeds, and says why, when the release has to be refused: without a Developer ID (an expired or locked keychain looks
# like this) or with SKIP_NOTARIZE the DMG is ad-hoc signed or not notarized, and Gatekeeper rejects it on every other Mac
# once it is on GitHub, in the cask and in the Sparkle feed. The same for an identity that is not a Developer ID Application one
# (a wrong SIGN_IDENTITY), which would only fail after the build. ALLOW_UNSIGNED_RELEASE=1 is the explicit way past.
#   unsigned_release_refusal <developer id> <SKIP_NOTARIZE> <ALLOW_UNSIGNED_RELEASE>
unsigned_release_refusal() {
    [[ -n "$3" ]] && return 1
    if [[ -z "$1" ]]; then
        echo "No Developer ID Application identity in the keychain (expired, or the keychain is locked?): the DMG would be ad-hoc signed and not notarized. Fix the keychain, or set ALLOW_UNSIGNED_RELEASE=1 to release it anyway."
        return 0
    fi
    if [[ "$1" != "Developer ID Application: "* ]]; then
        echo "The signing identity \"$1\" (SIGN_IDENTITY?) is not a \"Developer ID Application\" identity: Gatekeeper rejects a DMG signed with anything else on every other Mac. Use the Developer ID Application certificate, or set ALLOW_UNSIGNED_RELEASE=1 to release it anyway."
        return 0
    fi
    if [[ -n "$2" ]]; then
        echo "SKIP_NOTARIZE is set: the DMG would not be notarized. Unset it, or set ALLOW_UNSIGNED_RELEASE=1 to release it anyway."
        return 0
    fi
    return 1
}

# Whether origin has the tag v$1: "yes", "no", or "unknown" when origin couldn't be asked (no network): a tag that may have
# been pushed must not be taken for one that wasn't. (ls-remote --exit-code answers 2 for "reachable, no such ref".)
#   origin_has_tag <version>
origin_has_tag() {
    git ls-remote --exit-code --tags origin "refs/tags/v$1" >/dev/null 2>&1
    case $? in
        0) echo yes ;;
        2) echo no ;;
        *) echo unknown ;;
    esac
}

# Puts a failed release back as it was before the commit and the tag, which are local until the tag is pushed. The tag goes
# when this script made it; the commit only when it is the one this script made ("Version X" on top of where it started).
# The commit goes with `reset --keep`, which leaves the edits made meanwhile in the working tree alone and refuses, rather
# than overwrites, when one of them is in a file the commit changed: then it is left, with what to do said.
#   revert_release <version> <HEAD before the commit> <1 if tagged> <1 if committed>
revert_release() {
    local version="$1" start="$2" tagged="$3" committed="$4"
    if [[ "$tagged" == 1 ]]; then git tag -d "v$version" >/dev/null 2>&1 || true; fi
    if [[ "$committed" == 1 ]]; then
        if [[ "$(git log -1 --format=%s)" == "Version $version" && "$(git rev-parse -q --verify 'HEAD^' || true)" == "$start" ]]; then
            git reset -q --keep "$start" 2>/dev/null || {
                echo "The \"Version $version\" commit is left in place: undoing it would overwrite changes you made in the working tree meanwhile." >&2
                echo "Save or stash those changes, then run: git reset --keep $start" >&2
            }
        else
            echo "HEAD isn't the \"Version $version\" commit this script made; it is left alone" >&2
        fi
    fi
}
