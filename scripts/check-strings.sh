#!/bin/bash
# Checks that every string the code looks up is in every language's Localizable.strings, and that no table keeps
# a string the code no longer uses. The compiler lists the lookups, so strings in any form are caught. Strings with
# no words in them ("%lld", "") need no translation.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/env.sh

OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
swift build --scratch-path "$HOME/Library/Caches/Changmun/strings" \
    -Xswiftc -emit-localized-strings -Xswiftc -emit-localized-strings-path -Xswiftc "$OUT" >/dev/null

python3 - "$OUT" Resources <<'EOF'
import glob, json, os, re, subprocess, sys

out, resources = sys.argv[1:]
used = {}
for path in glob.glob(os.path.join(out, "*.stringsdata")):
    data = json.load(open(path))
    for entry in data["tables"].get("Localizable", []):
        if re.search(r"[^\W\d_]", re.sub(r"%(?:\d+\$)?(?:lld|ld|d|@|lf|f|%)", "", entry["key"])):
            used.setdefault(entry["key"], f"{os.path.basename(data['source'])}:{entry['location']['startingLine']}")

def specifiers(text):
    return sorted(re.sub(r"%\d+\$", "%", s) for s in re.findall(r"%(?:\d+\$)?(?:lld|ld|d|@|lf|f)", text))

failed = False
for table in sorted(glob.glob(os.path.join(resources, "*.lproj", "Localizable.strings"))):
    language = os.path.basename(os.path.dirname(table)).removesuffix(".lproj")
    strings = json.loads(subprocess.check_output(["plutil", "-convert", "json", "-o", "-", table]))
    for key in sorted(set(used) - set(strings)):
        print(f"{language}: missing \"{key}\" ({used[key]})"); failed = True
    for key in sorted(set(strings) - set(used)):
        print(f"{language}: unused \"{key}\""); failed = True
    for key, text in strings.items():
        if not text.strip():
            print(f"{language}: empty \"{key}\""); failed = True
        elif specifiers(key) != specifiers(text):
            print(f"{language}: \"{key}\" and \"{text}\" differ in placeholders"); failed = True
if failed:
    sys.exit(1)
print(f"{len(used)} strings, all translated")
EOF
