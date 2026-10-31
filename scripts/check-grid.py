#!/usr/bin/env python3
"""Is every spacing in the app on the grid? Spacing is 0, 4 and multiples of 8: the 4 only for tight gaps inside a component (an icon beside its
label, stacked label lines, a badge's padding), everything between components and every outer padding a multiple of 8.

Reads the Swift files under Sources/Changmun (or the files and folders named on the command line) and fails for a number that is not
on the grid in a `.padding(...)`, a `spacing:` (also `horizontalSpacing:` and `verticalSpacing:`) or a `Spacer(minLength:`. A number in a
`Metrics.` expression is left to the token (`Metrics.inset + 4` is checked for its 4 only), a count (`2 * x`) and a divisor (`x / 2`) are not
spacing. Not looked at: StartPageMiniature.swift (a scaled-down drawing of the page, in scale-model proportions) and a line that ends in a
`// grid-exempt: why` comment, for a value the system fixes (an inset to line up with) or one that is no gap (a 1 pt optical nudge, a share of an
icon's size). Run by scripts/test-scripts.sh.

    scripts/check-grid.py [file or folder ...]
"""
import os
import re
import sys

EXEMPT_FILES = {"StartPageMiniature.swift"}
MARKER = "// grid-exempt:"
NUMBER = re.compile(r"(?<![\w.])(\d+(?:\.\d+)?)(?![\w])")
CONTEXT = re.compile(r"\.padding\(|Spacer\(minLength:|\b[a-zA-Z]*[sS]pacing:")


def on_grid(value):
    return value == 0 or value == 4 or value % 8 == 0


def contexts(line):
    """The stretches of a line that are spacing: a call's arguments up to its closing parenthesis, a label's value up to its comma."""
    found = []
    for start in CONTEXT.finditer(line):
        call = start.group(0).endswith("(") or start.group(0).startswith("Spacer")
        i, depth = start.end(), 1 if call else 0
        while i < len(line):
            c = line[i]
            if c in "([":
                depth += 1
            elif c in ")]":
                depth -= 1
                if depth < 0 or (call and depth == 0):
                    break
            elif c == "," and depth == 0 and not call:
                break
            i += 1
        found.append((start.start(), i))
    return found


def violations(line):
    """The numbers of a line that are spacing and off the grid."""
    code = line.split("//")[0]
    found = {}
    for start, end in contexts(code):
        masked = re.sub(r"Metrics\.\w+", lambda m: "_" * len(m.group(0)), code[start:end])
        for number in NUMBER.finditer(masked):
            before, after = masked[:number.start()], masked[number.end():]
            if re.match(r"\s*\*", after) or re.search(r"/\s*$", before):
                continue
            if not on_grid(float(number.group(1))):
                found[start + number.start()] = number.group(1)
    return list(found.values())


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
                for value in violations(line):
                    print(f"{path}:{number}: {value} is not on the 8-point grid (0, 4, 8, 16, 24 ...): {line.strip()}")
                    failed += 1
    if failed:
        print(f"{failed} spacing value(s) off the grid. Use 0, 4 or a multiple of 8; a value the system fixes or that is no gap "
              f"gets a trailing `{MARKER} why`.", file=sys.stderr)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
