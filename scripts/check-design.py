#!/usr/bin/env python3
"""Does the app draw from its tokens? Type comes from Font.caption, .secondary, .body, .title, .heading and .display (and the symbol sizes),
corners are 4, 8, 12 or 16 (the Metrics radii) or a capsule, and a shadow is e1, e2 or e3.

Reads the Swift files under Sources/Changmun (or the files and folders named on the command line) and fails for
  - a `.system(size:` literal: use a Font token (Theme.swift defines them),
  - a corner radius that is a number outside 4, 8, 12 and 16: `cornerRadius: 10`, or `radius: 10` of a plate, a panel or a button style,
  - a `.shadow(` outside DesignSystem/: use e1(), e2() or e3().
A number in an expression (`size * 0.24`, a share of a plate) is not a literal. Not looked at: StartPageMiniature.swift (a scaled-down drawing
of the page), Theme.swift for the font rule (it defines the tokens), and a line that ends in a `// design-exempt: why` comment, for a mark drawn
inside an icon, a size that is a share of its plate, a drawing that is a scaled-down model. Run by scripts/test-scripts.sh.

    scripts/check-design.py [file or folder ...]
"""
import os
import re
import sys

EXEMPT_FILES = {"StartPageMiniature.swift"}
FONT_FILES = {"Theme.swift"}
MARKER = "// design-exempt:"
RADII = {4, 8, 12, 16}
FONT = re.compile(r"\.system\(size:")
CORNER = re.compile(r"(?<![-\w])(?:cornerRadius|radius):\s*(\d+(?:\.\d+)?)(?![\w.]*\s*[*/+-])")
SHADOW = re.compile(r"(?<!\w)\.?shadow\(")


def violations(line, path):
    """What a line draws off the tokens: a list of messages."""
    code = line.split("//")[0]
    found = []
    if FONT.search(code) and os.path.basename(path) not in FONT_FILES:
        found.append("a `.system(size:` literal: use a Font token (caption, secondary, body, title, heading, display or a symbol size)")
    if not SHADOW.search(code) and "blur(" not in code:
        for number in CORNER.finditer(code):
            if float(number.group(1)) not in RADII:
                found.append(f"a corner radius of {number.group(1)}: use 4, 8, 12 or 16 (a Metrics radius)")
    if SHADOW.search(code) and "DesignSystem" not in path.split(os.sep):
        found.append("a `.shadow(` outside DesignSystem: use e1(), e2() or e3()")
    return found


def swift_files(paths):
    for path in paths:
        if os.path.isfile(path):
            yield path
            continue
        for folder, _, names in os.walk(path):
            for name in sorted(names):
                if name.endswith(".swift"):
                    yield os.path.join(folder, name)


def main():
    failed = 0
    for path in swift_files(sys.argv[1:] or ["Sources/Changmun"]):
        if os.path.basename(path) in EXEMPT_FILES:
            continue
        with open(path, encoding="utf-8") as source:
            for number, line in enumerate(source, 1):
                if MARKER in line or line.lstrip().startswith("//"):
                    continue
                for message in violations(line, path):
                    print(f"{path}:{number}: {message}: {line.strip()}")
                    failed += 1
    if failed:
        print(f"{failed} place(s) off the design tokens. A mark drawn inside an icon or a size that is a share of its plate "
              f"gets a trailing `{MARKER} why`.", file=sys.stderr)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
