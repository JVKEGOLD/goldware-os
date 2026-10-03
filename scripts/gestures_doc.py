#!/usr/bin/env python3
"""Writes docs/GESTURES.md from the gesture catalog in dashboard/gestures.js, so the docs, the
dashboard demos, and onboarding all describe the same gestures.

    python3 scripts/gestures_doc.py           write docs/GESTURES.md
    python3 scripts/gestures_doc.py --check   exit 1 if docs/GESTURES.md is out of date
"""
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
JS = os.path.join(ROOT, "dashboard", "gestures.js")
DOC = os.path.join(ROOT, "docs", "GESTURES.md")

# The order the catalog groups gestures in, by mode.
GROUPS = [
    ("Pointer", "Vision Mode's pointer style: move and click with one hand."),
    ("Quadrants", "Dictate into any corner of the screen."),
    ("Pointer and Quadrants", "Work in both styles, after a hand dictation."),
    ("Any style", "Work whenever Vision Mode is on."),
    ("Locked", "Vision Mode starts locked, so a hand passing by never acts."),
    ("Mirror scan", "No unlock needed. Open the mirror behind the notch and hold something up."),
]


def catalog():
    with open(JS, encoding="utf-8") as f:
        src = f.read()
    m = re.search(r"/\*GESTURE-DATA-BEGIN\*/(.*?)/\*GESTURE-DATA-END\*/", src, re.S)
    if not m:
        raise SystemExit("gestures.js: GESTURE-DATA markers not found")
    return json.loads(m.group(1))


def hold(ms):
    if not ms:
        return ""
    return ("%.2f" % (ms / 1000.0)).rstrip("0").rstrip(".") + " s"


def render(data):
    out = [
        "# Vision gestures",
        "",
        "Every hand gesture GoldWare Vision understands. This file is generated from the catalog in",
        "`dashboard/gestures.js` by `python3 scripts/gestures_doc.py`; edit the catalog, not this file.",
        "The same catalog drives the animated demos: open `/dashboard/gestures.html` on the local",
        "dashboard server to watch each one.",
        "",
        "Vision Mode starts locked every time it turns on. Your unlock gesture is private: it is never",
        "drawn, named, or described anywhere in GoldWare.",
        "",
    ]
    known = [g for g, _ in GROUPS]
    for mode, blurb in GROUPS:
        items = [g for g in data if g["mode"] == mode]
        if not items:
            continue
        out += ["## " + mode, "", blurb, "", "| Gesture | How | Hold | Does |", "|---|---|---|---|"]
        for g in items:
            cells = [g["name"], g["how"], hold(g["holdMs"]), g["does"]]
            out.append("| " + " | ".join(c.replace("|", "\\|") for c in cells) + " |")
        out.append("")
    stray = [g["id"] for g in data if g["mode"] not in known]
    if stray:
        raise SystemExit("gestures.js: unknown mode for " + ", ".join(stray))
    out += [
        "## For developers",
        "",
        "`dashboard/gestures.js` has no dependencies. Include it with `dashboard/gestures.css`, then:",
        "",
        "```js",
        "GoldWareGestures.list()   // [{id, name, mode, does, how, holdMs}]",
        "GoldWareGestures.render(el, id, {loop: true, size: 'm'})   // size 's', 'm' or 'l'",
        "```",
        "",
        "`render` returns `{play, pause, step(n), destroy}`. Each demo is keyboard reachable (Space plays",
        "or pauses, the arrow keys step), and with reduced motion it shows one still per step instead of",
        "playing. `tests/test_gestures.py` fails when the Swift app recognises a gesture with no demo.",
        "",
    ]
    return "\n".join(out)


def main():
    text = render(catalog())
    if "--check" in sys.argv:
        try:
            with open(DOC, encoding="utf-8") as f:
                same = f.read() == text
        except OSError:
            same = False
        if not same:
            print("docs/GESTURES.md is out of date: run python3 scripts/gestures_doc.py")
            return 1
        print("docs/GESTURES.md is up to date")
        return 0
    with open(DOC, "w", encoding="utf-8") as f:
        f.write(text)
    print("wrote docs/GESTURES.md")
    return 0


if __name__ == "__main__":
    sys.exit(main())
