#!/usr/bin/env python3
"""The Sparkle feed docs/appcast.xml (see appcast.sh and release.sh). Standard library only, Python 3.9.

  appcast.py add FEED --version V --build N --url U --length L --signature S --notes FILE --min-os 14.0 [--date D] [--keep 10]
  appcast.py check FEED --version V --build N --url U --length L --signature S
  appcast.py max-build FEED       the highest sparkle:version in the feed, 0 when it has no item
  appcast.py pubkey KEYFILE       the public key (Info.plist's SUPublicEDKey) of a Sparkle private key file
"""
import argparse
import base64
import hashlib
import re
import sys
import time
import xml.etree.ElementTree as ET

SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", SPARKLE)
S = f"{{{SPARKLE}}}"
SITE = "https://namekun.github.io/Changmun/"
RELEASES = "https://github.com/namekun/Changmun/releases/tag/v"


class Invalid(ValueError):
    pass


def validate(version, build, url, length, signature):
    if not re.fullmatch(r"\d+\.\d+\.\d+", version):
        raise Invalid(f"version {version!r} isn't like 1.2.3")
    # Sparkle compares sparkle:version with the running app's CFBundleVersion.
    if not re.fullmatch(r"[1-9]\d*", build):
        raise Invalid(f"build {build!r} isn't a plain number")
    if not (url.startswith("https://") or url.startswith("http://127.0.0.1:")):
        raise Invalid(f"url {url!r} isn't https")
    if not re.fullmatch(r"[1-9]\d*", str(length)):
        raise Invalid(f"length {length!r} isn't a size")
    try:
        if len(base64.b64decode(signature, validate=True)) != 64:
            raise Invalid("the signature isn't 64 bytes")
    except ValueError as error:
        raise Invalid(f"the signature isn't base64: {error}")


def min_os(value):
    parts = value.split(".")
    if not all(p.isdigit() for p in parts) or not 1 <= len(parts) <= 3:
        raise Invalid(f"minimum macOS {value!r}")
    return ".".join(parts + ["0"] * (3 - len(parts)))


def load(path):
    """The feed's channel; an empty one when the file has none yet."""
    try:
        root = ET.parse(path).getroot()
    except FileNotFoundError:
        root = ET.Element("rss", {"version": "2.0"})
    channel = root.find("channel")
    if channel is None:
        channel = ET.SubElement(root, "channel")
        ET.SubElement(channel, "title").text = "Changmun"
        ET.SubElement(channel, "link").text = SITE
        ET.SubElement(channel, "description").text = "Changmun updates"
        ET.SubElement(channel, "language").text = "en"
    return root, channel


def write(root, path):
    ET.indent(root, space="  ")
    ET.ElementTree(root).write(path, encoding="utf-8", xml_declaration=True)
    with open(path, "a", encoding="utf-8") as feed:
        feed.write("\n")


def add(path, version, build, url, length, signature, notes, os_version, date, keep):
    """Puts this release's item first. An item of the same build is replaced, and only the newest `keep` stay."""
    validate(version, build, url, length, signature)
    root, channel = load(path)
    for old in [i for i in channel.findall("item") if i.findtext(f"{S}version") == build]:
        channel.remove(old)
    item = ET.Element("item")
    ET.SubElement(item, "title").text = version
    ET.SubElement(item, "pubDate").text = date or time.strftime("%a, %d %b %Y %H:%M:%S +0000", time.gmtime())
    ET.SubElement(item, f"{S}version").text = build
    ET.SubElement(item, f"{S}shortVersionString").text = version
    ET.SubElement(item, f"{S}minimumSystemVersion").text = min_os(os_version)
    ET.SubElement(item, f"{S}hardwareRequirements").text = "arm64"
    ET.SubElement(item, f"{S}fullReleaseNotesLink").text = RELEASES + version
    ET.SubElement(item, "description", {f"{S}format": "markdown"}).text = notes.strip()
    ET.SubElement(item, "enclosure", {"url": url, "length": str(length), "type": "application/octet-stream", f"{S}edSignature": signature})
    first = next((i for i, child in enumerate(channel) if child.tag == "item"), len(channel))
    channel.insert(first, item)
    for stale in channel.findall("item")[keep:]:
        channel.remove(stale)
    write(root, path)


def check(path, version, build, url, length, signature):
    """The newest item, read back from the file about to be published, is the release being made."""
    items = load(path)[1].findall("item")
    if not items:
        raise Invalid("the feed has no item")
    item, enclosure = items[0], items[0].find("enclosure")
    actual = {
        "version": item.findtext(f"{S}shortVersionString"),
        "build": item.findtext(f"{S}version"),
        "url": enclosure.get("url") if enclosure is not None else None,
        "length": enclosure.get("length") if enclosure is not None else None,
        "signature": enclosure.get(f"{S}edSignature") if enclosure is not None else None,
    }
    expected = {"version": version, "build": build, "url": url, "length": str(length), "signature": signature}
    wrong = [f"{key} is {actual[key]!r}, expected {value!r}" for key, value in expected.items() if actual[key] != value]
    if wrong:
        raise Invalid("; ".join(wrong))


def max_build(path):
    builds = [i.findtext(f"{S}version") or "" for i in load(path)[1].findall("item")]
    return max([int(b) for b in builds if b.isdigit()], default=0)


def pubkey(path):
    """Ed25519 (RFC 8032): the public key of the 32 byte seed in a file Sparkle's generate_keys -x wrote."""
    seed = base64.b64decode(open(path).read().strip(), validate=True)
    if len(seed) != 32:
        raise Invalid(f"{path} isn't a Sparkle private key file")
    p = 2**255 - 19
    d = -121665 * pow(121666, p - 2, p) % p
    def add_points(P, Q):
        a = (P[1] - P[0]) * (Q[1] - Q[0]) % p
        b = (P[1] + P[0]) * (Q[1] + Q[0]) % p
        c = 2 * P[3] * Q[3] * d % p
        e = 2 * P[2] * Q[2] % p
        e1, f, g, h = b - a, e - c, e + c, b + a
        return (e1 * f % p, g * h % p, f * g % p, e1 * h % p)
    y = 4 * pow(5, p - 2, p) % p
    x = pow((y * y - 1) * pow(d * y * y + 1, p - 2, p) % p, (p + 3) // 8, p)
    if (x * x - (y * y - 1) * pow(d * y * y + 1, p - 2, p)) % p:
        x = x * pow(2, (p - 1) // 4, p) % p
    if x & 1:
        x = p - x
    point, result = (x, y, 1, x * y % p), (0, 1, 1, 0)
    h = bytearray(hashlib.sha512(seed).digest()[:32])
    h[0] &= 248
    h[31] = (h[31] & 127) | 64
    for bit in bin(int.from_bytes(h, "little"))[2:]:
        result = add_points(result, result)
        if bit == "1":
            result = add_points(result, point)
    zinv = pow(result[2], p - 2, p)
    ax, ay = result[0] * zinv % p, result[1] * zinv % p
    return base64.b64encode((ay | (ax & 1) << 255).to_bytes(32, "little")).decode()


def main(argv):
    parser = argparse.ArgumentParser(prog="appcast.py")
    commands = parser.add_subparsers(dest="command", required=True)
    for name in ("add", "check"):
        command = commands.add_parser(name)
        command.add_argument("feed")
        for option in ("--version", "--build", "--url", "--length", "--signature"):
            command.add_argument(option, required=True)
        if name == "add":
            command.add_argument("--notes", required=True)
            command.add_argument("--min-os", required=True)
            command.add_argument("--date")
            command.add_argument("--keep", type=int, default=10)
    commands.add_parser("max-build").add_argument("feed")
    commands.add_parser("pubkey").add_argument("keyfile")
    args = parser.parse_args(argv)
    try:
        if args.command == "add":
            with open(args.notes, encoding="utf-8") as notes:
                add(args.feed, args.version, args.build, args.url, args.length, args.signature, notes.read(), args.min_os, args.date, args.keep)
        elif args.command == "check":
            check(args.feed, args.version, args.build, args.url, args.length, args.signature)
        elif args.command == "max-build":
            print(max_build(args.feed))
        else:
            print(pubkey(args.keyfile))
    except (Invalid, ET.ParseError, ValueError) as error:
        print(f"appcast.py: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
