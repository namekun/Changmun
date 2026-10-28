#!/usr/bin/env python3
"""The accessibility audit behind scripts/audit-accessibility.sh: puts Changmun Headless.app into the states VoiceOver users meet, reads
its accessibility tree in the app's own process (POST /accessibility, see AccessibilityDump.swift) and fails when a control has no name.

A control needs a label when its role is a button, check box, radio button, menu button, pop-up button, text field, link, slider,
disclosure triangle or tab, when it is an image (an image that VoiceOver should skip is hidden from the tree), or when it takes a press
(a row that is only a tap gesture shows as a group with AXPress). A label is the element's description or its title.

Run through scripts/audit-accessibility.sh, which starts the headless app (in English) and stops it again.
"""
import json
import os
import re
import subprocess
import sys
import time
import urllib.request

ENDPOINT = os.environ["ENDPOINT"]
TREES = os.environ.get("AUDIT_DUMP")  # a folder to keep each state's tree in, for looking at

NEEDS_LABEL = {
    "AXButton", "AXCheckBox", "AXRadioButton", "AXMenuButton", "AXPopUpButton", "AXTextField", "AXTextArea", "AXSearchField", "AXComboBox",
    "AXLink", "AXSlider", "AXDisclosureTriangle", "AXTab", "AXImage", "AXIncrementor", "AXMenuItem",
}

# Known exceptions: [state, role, a regular expression the element's class must match or None, why].
ALLOWED = [
    ("*", "AXButton", r"NSAccessibilityScrollerPart", "the parts of a scroll bar (arrows, knob): AppKit's, and a screen reader skips them"),
]


def endpoint():
    return json.load(open(ENDPOINT))


def post(path, body=None):
    info = endpoint()
    request = urllib.request.Request(f"http://127.0.0.1:{info['port']}{path}", data=json.dumps(body or {}).encode(), method="POST",
                                     headers={"Authorization": "Bearer " + info["token"], "Content-Type": "application/json", "X-Changmun-Caller": "audit-accessibility.py"})
    with urllib.request.urlopen(request, timeout=60) as reply:
        return json.loads(reply.read() or b"{}")


def call(name, arguments=None):
    return post("/call", {"name": name, "arguments": arguments or {}})


def ui(**fields):
    return post("/ui", fields)


def key(chars, code=0):
    post("/window-key", {"chars": chars, "keyCode": code})


def flatten(node, path=()):
    yield node, path
    for child in node.get("children", []):
        yield from flatten(child, path + (node,))


def named(node):
    # A text field says what it is for in its placeholder when nothing else names it, which VoiceOver reads.
    placeholder = node.get("placeholder") if node.get("role") in ("AXTextField", "AXSearchField", "AXComboBox") else None
    return bool(any((node.get(key) or "").strip() for key in ("label", "title", "titleElement")) or (placeholder or "").strip())


def needs_label(node):
    role = node.get("role")
    return role in NEEDS_LABEL or (role in ("AXGroup", "AXUnknown", "AXStaticText", "AXCell", "AXRow") and "AXPress" in node.get("actions", []))


def allowed(state, node):
    return any(s in ("*", state) and node.get("role") == r and (c is None or re.search(c, node.get("class", ""))) for s, r, c, _ in ALLOWED)


def describe(node):
    parts = [node.get("role", "?")]
    for field in ("class", "help", "value", "placeholder"):
        if node.get(field):
            parts.append(f"{field}={node[field]!r}")
    return " ".join(parts) + (f" at {node['frame']}" if node.get("frame") else "")


failures = []
checked = 0
states = 0
reply = {}


def audit(state, window="front", expect=None):
    """Reads the tree after a moment for the views to settle, and checks every control in it (and the popovers and sheets over it)."""
    global checked, states
    time.sleep(0.8)
    global reply
    reply = post("/accessibility", {"window": window, **(expect or {})})
    trees = reply["trees"]
    states += 1
    if TREES:
        os.makedirs(TREES, exist_ok=True)
        json.dump(trees, open(os.path.join(TREES, re.sub(r"\W+", "-", state) + ".json"), "w"), indent=1, ensure_ascii=False)
    nodes = [(n, p) for tree in trees for n, p in flatten(tree["root"])]
    mine = 0
    for node, _ in nodes:
        if not needs_label(node):
            continue
        mine += 1
        if not named(node) and not allowed(state, node):
            failures.append((state, describe(node)))
    checked += mine
    print(f"  {state}: {len(nodes)} elements, {mine} controls", flush=True)
    return nodes


def labels(nodes):
    return [n.get("label") or n.get("title") or "" for n, _ in nodes]


def expect_label(state, nodes, wanted):
    """The control called `wanted` must be there: the audit also checks that the names are the right ones, not only that there is one."""
    if not any(wanted == (n.get("label") or n.get("title") or "") for n, _ in nodes):
        failures.append((state, f"no control named {wanted!r} (names: {sorted(set(filter(None, labels(nodes))))[:40]})"))


PRESSABLE = {"AXButton", "AXCheckBox", "AXRadioButton", "AXMenuButton", "AXPopUpButton", "AXLink", "AXDisclosureTriangle", "AXTab"}


def expect_controls(state, nodes, wanted):
    """What the state shows has to be reachable as a control that takes a press (a button, or anything with the press action), by the name given."""
    for text in wanted:
        found = [n for n, _ in nodes if text in (n.get("label") or n.get("title") or "")
                 and (n.get("role") in PRESSABLE or "AXPress" in n.get("actions", []) or n.get("canPress"))]
        if not found:
            failures.append((state, f"no pressable control named {text!r}"))


def find(nodes, label):
    return [n for n, _ in nodes if (n.get("label") or n.get("title") or "") == label]


def expect_value(state, nodes, label, value):
    if not any(value in (n.get("value") or "") for n in find(nodes, label)):
        failures.append((state, f"the control {label!r} should have the value {value!r} (it has {[n.get('value') for n in find(nodes, label)]})"))


def expect_selected(state, nodes, label):
    if not any(n.get("selected") for n in find(nodes, label)):
        failures.append((state, f"the control {label!r} should be selected"))


def expect_actions(state, nodes, label, actions):
    have = {a for n in find(nodes, label) for a in n.get("customActions", [])}
    for action in actions:
        if action not in have:
            failures.append((state, f"the control {label!r} should offer the action {action!r} (it offers {sorted(have)})"))


def expect_announced(state, text):
    if not any(text in said for said in reply.get("announcements", [])):
        failures.append((state, f"nothing announced with {text!r} (announced: {reply.get('announcements', [])[-6:]})"))


def page(title):
    return f"data:text/html,<title>{title}</title><p>{title}</p>"


TABS = ["Alpha", "Bravo", "Charlie", "Delta"]


def seed():
    """Four tabs (the last two in a group), two favorites, and a pinned, opened folder, from a window without any other tab."""
    for tab in ui()["tabs"]:
        call("close_tab", {"tab_id": tab["id"]})
    for name in TABS:
        # Nothing answers at this address: the tab is quick to fail, and its name is the one given here.
        call("open_tab", {"url": "http://127.0.0.1:9/"})
        ui(rename=name)
    ids = [t["id"] for t in ui()["tabs"]]
    ui(group={"ids": ids[-2:], "name": "Audit group"})
    ui(folder={"name": "", "pages": [[page("Fav one"), "Fav one"], [page("Fav two"), "Fav two"]]})
    ui(folder={"name": "AuditFolder", "pages": [[page("Mark one"), "Mark one"], [page("Mark two"), "Mark two"]], "pin": True, "open": True})
    call("switch_tab", {"tab_id": ids[0]})
    return ids


def unseed():
    ui(command="none", find=False, overlay=False, downloads=False)
    ui(folder={"name": "", "remove": True, "pages": [[page("Fav one"), "Fav one"], [page("Fav two"), "Fav two"]]})
    ui(folder={"name": "AuditFolder", "remove": True, "pages": [[page("Mark one"), "Mark one"], [page("Mark two"), "Mark two"]]})
    post("/ai-chat", {"clearHistory": True})
    post("/approvals", {"newChat": True})
    post("/accessibility", {"approval": False})
    post("/panel", {"open": False})
    ui(tabs="sidebar", toolbar="sidebar", sidebar=True, appearance="system")


def main():
    only = set(sys.argv[1:])

    def wanted(name):
        return not only or name in only

    ui(appearance="light", tabs="sidebar", toolbar="sidebar", sidebar=True, command="none", find=False)
    ids = seed()
    ui(progress=0.4)
    toolbar = ["Sidebar", "Back", "Forward", "Stop", "Bookmarks", "Downloads", "AI Panel", "Address"]
    rows = [*TABS, "Audit group", "Fav one", "Fav two", "Mark one", "AuditFolder", "New Tab"]

    if wanted("sidebar"):
        print("sidebar layout")
        state = "sidebar, toolbar in the sidebar"
        nodes = audit(state)
        expect_controls(state, nodes, toolbar + rows)
        expect_selected(state, nodes, "Alpha")
        expect_value(state, nodes, "Alpha", "Loading")
        expect_value(state, nodes, "Audit group", "Expanded, 2 tabs")
        expect_value(state, nodes, "Charlie", "In group Audit group")
        expect_value(state, nodes, "Fav one", "Not open")
        expect_value(state, nodes, "AuditFolder", "Expanded, 2 bookmarks")
        expect_value(state, nodes, "Sidebar", "Shown")
        expect_value(state, nodes, "Loading", "40 percent")
        expect_value(state, nodes, "Address", "")
        expect_actions(state, nodes, "Bravo", ["Close Tab", "Rename", "Reload"])
        expect_actions(state, nodes, "Audit group", ["Collapse", "Rename"])
        expect_actions(state, nodes, "AuditFolder", ["Collapse", "Rename"])
        expect_actions(state, nodes, "Mark one", ["Rename"])
        state = "sidebar, toolbar over the page"
        ui(toolbar="page")
        nodes = audit(state)
        expect_controls(state, nodes, ["Sidebar", "Back", "Forward", "Address", "AI Panel", *rows])
        ui(toolbar="sidebar")

    if wanted("top"):
        print("tabs on top")
        ui(tabs="top", overlay=False)
        state = "tabs on top"
        nodes = audit(state)
        expect_controls(state, nodes, [*TABS, "Audit group", "Fav one", "New Tab", "Sidebar", "Back", "Forward", "Address", "Downloads", "AI Panel"])
        expect_selected(state, nodes, "Alpha")
        expect_value(state, nodes, "Sidebar", "Hidden")
        expect_value(state, nodes, "Audit group", "Expanded, 2 tabs")
        expect_actions(state, nodes, "Bravo", ["Close Tab", "Rename"])
        ui(overlay=True)
        state = "tabs on top, sidebar over the page"
        nodes = audit(state)
        expect_value(state, nodes, "Sidebar", "Shown")
        expect_controls(state, nodes, ["Bookmarks", "AuditFolder", "Mark one"])
        ui(overlay=False, tabs="sidebar")

    if wanted("command"):
        print("command bar")
        ui(command="newTab")
        time.sleep(0.5)
        key("exam", 0)
        time.sleep(1.2)
        state = "command bar open"
        nodes = audit(state)
        expect_controls(state, nodes, ["Search for exam", "Ask AI: exam"])
        expect_label(state, nodes, "Search, enter an address or ask AI")
        expect_selected(state, nodes, "Search for exam")
        expect_announced(state, "suggestions")
        ui(command="none")
        time.sleep(0.8)
        state = "command bar closed"
        audit(state)
        if "WebView" not in reply.get("firstResponder", ""):
            failures.append((state, f"the keyboard should be back on the page, it is on {reply.get('firstResponder')}"))

    if wanted("find"):
        print("find bar")
        ui(find=True, findText="Alpha")
        time.sleep(1.2)
        state = "find bar"
        nodes = audit(state)
        expect_controls(state, nodes, ["Previous", "Next", "Close"])
        expect_label(state, nodes, "Find on Page")
        ui(find=False)

    if wanted("flash"):
        print("announcements")
        post("/accessibility", {"flash": "Address copied", "undo": "Closed 1 tab"})
        audit("a status message and an undo notice")
        expect_announced("a status message and an undo notice", "Address copied")
        expect_announced("a status message and an undo notice", "Closed 1 tab. Undo is available in the sidebar.")

    if wanted("ai"):
        print("AI panel")
        post("/ai-tools", {"state": "ready"})
        post("/ai-chat", {"items": [
            {"kind": "user", "text": "Summarize this page"},
            {"kind": "tool", "text": "Reading the page", "symbol": "doc.text", "tool": "read_page", "outcome": "ok"},
            {"kind": "tool", "text": "Clicking a button", "symbol": "cursorarrow.click", "tool": "click", "outcome": "failed"},
            {"kind": "assistant", "text": "The page says **Alpha**."},
        ], "running": 12, "step": "Reading the page", "context": {"used": 40000, "window": 200000}})
        post("/panel", {"open": True})
        state = "AI panel, a conversation"
        nodes = audit(state)
        expect_controls(state, nodes, ["New Chat", "Open in its own window", "Close", "Dictate", "Stop"])
        expect_label(state, nodes, "AI said")
        expect_label(state, nodes, "Working")
        if not any((n.get("value") or "") == "You said: Summarize this page" for n, _ in nodes):
            failures.append((state, "the user's message should be read as 'You said: …'"))
        expect_value(state, nodes, "Working", "Reading the page")
        expect_value(state, nodes, "AI Panel", "Turned on")
        post("/accessibility", {"approval": True})
        state = "AI panel, a question waiting"
        nodes = audit(state)
        expect_controls(state, nodes, ["Don’t Allow", "Allow Once", "Allow on example.com for This Chat"])
        expect_label(state, nodes, "Approval needed")
        expect_announced(state, "Approval needed: Let the AI type into this page?")
        post("/accessibility", {"approval": False})
        post("/ai-chat", {"showHistory": True})
        audit("AI panel, chat history")
        post("/ai-chat", {"items": []})
        post("/panel", {"open": False})

    if wanted("settings"):
        print("settings window")
        for name in ("general", "appearance", "tabs", "privacy", "extensions", "ai", "advanced"):
            post("/settings-image", {"page": name})
            audit(f"settings, {name}", window="settings")

    if wanted("trust"):
        print("trust warning")
        trust()

    unseed()


def trust():
    """A page whose certificate can't be verified, served by a local openssl server with a self-signed certificate."""
    import socket
    import tempfile
    with tempfile.TemporaryDirectory() as work:
        key_file, cert_file = os.path.join(work, "k.pem"), os.path.join(work, "c.pem")
        subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", key_file, "-out", cert_file, "-days", "2", "-subj", "/CN=localhost",
                        "-addext", "subjectAltName=DNS:localhost", "-addext", "extendedKeyUsage=serverAuth"], check=True, capture_output=True)
        sock = socket.socket()
        sock.bind(("127.0.0.1", 0))
        port = sock.getsockname()[1]
        sock.close()
        server = subprocess.Popen(["openssl", "s_server", "-accept", str(port), "-cert", cert_file, "-key", key_file, "-www"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            time.sleep(1)
            reply = post("/server-trust", {"open": f"https://localhost:{port}/", "wait": 3500})
            if not reply.get("failure"):
                failures.append(("trust warning", "the warning did not come up"))
            nodes = audit("trust warning")
            expect_label("trust warning", nodes, "Certificate warning")
            expect_controls("trust warning", nodes, ["Go Back"])
            expect_announced("trust warning", "This connection isn’t private")
            post("/server-trust", {"exceptions": "clear", "action": "back", "wait": 500})
        finally:
            server.kill()


if __name__ == "__main__":
    main()
    print(f"{states} states, {checked} controls checked")
    shown = {}
    for state, text in failures:
        # The same problem in many rows is told once with its count; the frames are in the dump (AUDIT_DUMP).
        short = re.sub(r" at \[.*\]$", "", text)
        shown.setdefault(state, {}).setdefault(short, 0)
        shown[state][short] += 1
    for state, problems in shown.items():
        print(f"FAIL: {state}: {sum(problems.values())} problems", file=sys.stderr)
        for text, count in list(problems.items())[:int(os.environ.get("AUDIT_LINES", "12"))]:
            print(f"    {count}x {text}", file=sys.stderr)
    print("no control lacks a name" if not failures else f"{len(failures)} problems")
    sys.exit(1 if failures else 0)
