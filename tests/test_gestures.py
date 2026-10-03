"""The gesture demos (dashboard/gestures.js) cover every gesture the Swift app recognises.

The app's gestures are read from the Swift sources: the gesture recognisers in VisionControl.swift
(every struct with a `feed`), the hand shapes in VisionCamera.swift (HandGesture cases and its `is...`
tests), the pointer poses (HandControl.Pose), the scan actions (performScan), and the callbacks the
drivers fire (`var onX: ...`). Each one maps to a demo below. A new gesture in Swift with no entry here
fails the test, so it cannot ship without a demo.
"""
import json
import os
import re
import subprocess
import sys
import unittest

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(REPO, "app", "Sources", "GoldWareOS")
JS = os.path.join(REPO, "dashboard", "gestures.js")

# Swift name -> the demo ids that show it. None: not a gesture of its own (say why).
SWIFT_TO_DEMO = {
    # Recognisers (structs with `mutating func feed`)
    "TwoHandGesture": ["unlock"],
    "SwipeSend": ["swipe-send"],
    "LockGesture": ["lock"],
    "ThumbPull": ["lets-work"],
    "OpenToFists": ["lock-up", "clear-out"],
    "VisionLock": ["lock", "unlock"],
    "MirrorToggle": ["ok-mirror"],
    # Hand shapes
    "HandGesture.count": ["scan-copy", "quadrant-dictate"],
    "HandGesture.thumbsUp": ["scan-file"],
    "HandGesture.fist": ["scan-discard", "quadrant-rest", "rest"],
    "HandGesture.isOpenHand": ["open-pointer"],
    "HandGesture.isPinky": ["pinky-clear"],
    "HandGesture.isOK": ["ok-mirror"],
    # Pointer poses (HandControl.Pose)
    "Pose.none": None,          # no hand in view
    "Pose.track": ["point"],
    "Pose.pinch": ["pinch-click"],
    "Pose.scroll": ["pinch-scroll"],
    "Pose.open": ["rest"],
    "Pose.other": ["rest"],
    "Pose.switching": ["four-quadrants"],
    "Pose.letsWork": ["lets-work"],
    "Pose.lockUp": ["lock-up", "clear-out"],
    "Pose.clear": ["pinky-clear"],
    "Pose.swipe": ["swipe-send"],
    # Scan actions
    "scan.thumbsUp": ["scan-file"],
    "scan.count(2)": ["scan-copy"],
    "scan.fist": ["scan-discard"],
    # Callbacks the drivers fire
    "onSend": ["swipe-send"],
    "onClear": ["pinky-clear"],
    "onLetsWork": ["lets-work"],
    "onLockUp": ["lock-up"],
    "onClearOut": ["clear-out"],
    "onSwitchStyle": ["four-quadrants", "open-pointer"],
    "onDictate": ["quadrant-dictate"],
    "onRaise": ["quadrant-dictate"],
    "onIdleTimeout": None,      # a timer, not a gesture
    "onScanDone": ["scan-hold"],
    "onActiveChange": None,     # the scan card resizing the mirror
}

# Words that would give the private unlock gesture away.
UNLOCK_GIVEAWAYS = ["diamond", "index tips", "thumb tips", "tips touching", "tips let go", "palms spread",
                    "prayer, then", "heart"]


def read(name):
    with open(os.path.join(SRC, name), encoding="utf-8") as f:
        return f.read()


def catalog():
    with open(JS, encoding="utf-8") as f:
        src = f.read()
    m = re.search(r"/\*GESTURE-DATA-BEGIN\*/(.*?)/\*GESTURE-DATA-END\*/", src, re.S)
    assert m, "gestures.js: GESTURE-DATA markers not found"
    return src, json.loads(m.group(1))


def swift_gestures():
    found = set()
    control = read("VisionControl.swift")
    for m in re.finditer(r"^struct (\w+)\s*\{(.*?)^\}", control, re.S | re.M):
        if "mutating func feed" in m.group(2):
            found.add(m.group(1))
    camera = read("VisionCamera.swift")
    cases = re.search(r"enum HandGesture: Equatable \{\s*case ([^\n]+)", camera).group(1)
    for c in cases.split(","):
        found.add("HandGesture." + re.sub(r"\(.*", "", c.strip()))
    for m in re.finditer(r"static func (is[A-Z]\w*)\(", camera):
        found.add("HandGesture." + m.group(1))
    pose = re.search(r"enum Pose: String \{(.*?)\}", control, re.S).group(1)
    for m in re.finditer(r"(\w+) = \"", pose):
        found.add("Pose." + m.group(1))
    panel = read("VisionScanPanel.swift")
    body = re.search(r"func performScan\((.*?)\n    \}\n", panel, re.S).group(1)
    for m in re.finditer(r"case \(\.\w+(?:\(let \w+\))?, \.(\w+(?:\(\d\))?)\)", body):
        found.add("scan." + m.group(1))
    for name in ("VisionControl.swift", "VisionQuadrants.swift", "VisionScanPanel.swift"):
        for m in re.finditer(r"^\s+var (on[A-Z]\w*): \(", read(name), re.M):
            found.add(m.group(1))
    return found


class TestGestureDemos(unittest.TestCase):
    def test_every_swift_gesture_has_a_demo(self):
        found = swift_gestures()
        # Sanity: the parser still sees the gestures it is meant to.
        for name in ("SwipeSend", "OpenToFists", "HandGesture.thumbsUp", "Pose.scroll", "scan.count(2)", "onClearOut"):
            self.assertIn(name, found)
        missing = sorted(found - set(SWIFT_TO_DEMO))
        self.assertEqual(missing, [], "Gestures in Swift with no demo. Add a demo to dashboard/gestures.js "
                                      "and map it in tests/test_gestures.py SWIFT_TO_DEMO: %s" % missing)
        _, data = catalog()
        ids = {g["id"] for g in data}
        for name, demos in SWIFT_TO_DEMO.items():
            for d in demos or []:
                self.assertIn(d, ids, "%s maps to demo %r, which gestures.js does not have" % (name, d))

    def test_every_demo_has_an_animation_and_the_api_shape(self):
        src, data = catalog()
        self.assertGreaterEqual(len(data), 20)
        ids = [g["id"] for g in data]
        self.assertEqual(len(ids), len(set(ids)), "duplicate gesture ids")
        for g in data:
            for k in ("id", "name", "mode", "does", "how", "holdMs", "steps"):
                self.assertIn(k, g, "%s is missing %s" % (g.get("id"), k))
            self.assertTrue(g["steps"], g["id"])
            if g["id"] != "unlock":
                self.assertIn('ANIM["%s"]' % g["id"], src, "no animation for " + g["id"])
        self.assertIn("window.GoldWareGestures = { list: list, render: render }", src)
        self.assertIn("prefers-reduced-motion", src)

    def test_hold_times_match_swift(self):
        _, data = catalog()
        hold = {g["id"]: g["holdMs"] for g in data}
        control = read("VisionControl.swift")
        held = int(float(re.search(r"struct HeldGesture \{.*?static let seconds = ([\d.]+)", control, re.S).group(1)) * 1000)
        for i in ("ok-mirror", "four-quadrants", "open-pointer", "pinky-clear", "lock"):
            self.assertEqual(hold[i], held, i)
        quad = int(float(re.search(r"private static let hold = ([\d.]+)", read("VisionQuadrants.swift")).group(1)) * 1000)
        self.assertEqual(hold["quadrant-dictate"], quad)
        panel = read("VisionScanPanel.swift")
        m = re.search(r"g == \.thumbsUp \? ([\d.]+) : ([\d.]+)", panel)
        self.assertEqual(hold["scan-file"], int(float(m.group(1)) * 1000))
        self.assertEqual(hold["scan-copy"], int(float(m.group(2)) * 1000))
        self.assertEqual(hold["scan-discard"], int(float(m.group(2)) * 1000))
        self.assertIn("(now - steadySince) / %s" % (hold["scan-hold"] / 1000.0), panel)

    def test_unlock_stays_private(self):
        src, data = catalog()
        unlock = [g for g in data if g["id"] == "unlock"][0]
        self.assertIsNone(unlock["holdMs"])
        text = json.dumps(unlock).lower()
        for w in UNLOCK_GIVEAWAYS:
            self.assertNotIn(w, text)
        self.assertNotIn('ANIM["unlock"]', src)
        for name in ("gestures.js", "gestures.html", "gestures.css"):
            with open(os.path.join(REPO, "dashboard", name), encoding="utf-8") as f:
                low = f.read().lower()
            for w in ("diamond", "tips let go", "palms spread"):
                self.assertNotIn(w, low, "%s describes the unlock (%r)" % (name, w))
        with open(os.path.join(REPO, "docs", "GESTURES.md"), encoding="utf-8") as f:
            row = [l for l in f.read().lower().splitlines() if l.startswith("| your unlock gesture")]
        self.assertEqual(len(row), 1)
        for w in UNLOCK_GIVEAWAYS:
            self.assertNotIn(w, row[0])

    def test_no_external_assets(self):
        for name in ("gestures.js", "gestures.css", "gestures.html"):
            with open(os.path.join(REPO, "dashboard", name), encoding="utf-8") as f:
                src = f.read()
            self.assertNotRegex(src, r"(?:src|href)=[\"']https?://", name)
            self.assertNotRegex(src, r"url\([\"']?https?://", name)
            self.assertNotIn("@import", src, name)
            self.assertNotRegex(src, r"<image\b|\.svg[\"')]", name)

    def test_docs_are_generated_from_the_catalog(self):
        r = subprocess.run([sys.executable, os.path.join(REPO, "scripts", "gestures_doc.py"), "--check"],
                           capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)


if __name__ == "__main__":
    unittest.main()
