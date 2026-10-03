"""The first-run tour: /api/onboarding, where its progress lives, and the rules its page must keep.
There is no Node in make test, so the page itself is checked by reading its source here; the
headless Chrome pass (tests/tour_cdp.mjs) drives it for real when Chrome and Node are installed."""
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
import urllib.error
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from test_server import REPO, SERVER, free_port  # noqa: E402

DASH = os.path.join(REPO, "dashboard")


def read(*parts):
    with open(os.path.join(REPO, *parts), encoding="utf-8") as f:
        return f.read()


class TourServer(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.mkdtemp()
        cls.root = os.path.join(cls.tmp, "root")
        os.makedirs(cls.root)
        shutil.copy(os.path.join(REPO, "goldware.default.json"), cls.root)
        cls.data = os.path.join(cls.tmp, "data")
        cls.appdata = os.path.join(cls.tmp, "appdata")
        os.makedirs(cls.appdata)
        cls.port = free_port()
        cls.base = "http://127.0.0.1:%d" % cls.port
        env = dict(os.environ, GOLDWARE_ROOT=cls.root, GOLDWARE_DATA_ROOT=cls.data, GOLDWARE_DATA=cls.appdata,
                   GOLDWARE_OFFICE_EMPTY="1", GOLDWARE_OFFICE_DRY_RUN="1")
        cls.proc = subprocess.Popen([sys.executable, SERVER, "--port", str(cls.port)], env=env,
                                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        for _ in range(100):
            try:
                urllib.request.urlopen(cls.base + "/api/onboarding", timeout=1)
                break
            except Exception:
                time.sleep(0.1)

    @classmethod
    def tearDownClass(cls):
        cls.proc.terminate()
        cls.proc.wait(5)
        shutil.rmtree(cls.tmp, ignore_errors=True)

    def req(self, path, body=None, headers=None):
        h = {"Content-Type": "application/json"}
        h.update(headers or {})
        data = json.dumps(body).encode() if body is not None else None
        r = urllib.request.Request(self.base + path, data=data, headers=h)
        try:
            resp = urllib.request.urlopen(r, timeout=10)
        except urllib.error.HTTPError as e:
            resp = e
        return resp.code, json.loads(resp.read() or b"{}")

    def setUp(self):
        for p in (os.path.join(self.data, "onboarding.json"), os.path.join(self.appdata, "status.json")):
            if os.path.exists(p):
                os.remove(p)

    def test_new_install_starts_new(self):
        code, j = self.req("/api/onboarding")
        self.assertEqual(code, 200)
        self.assertEqual(j["state"]["status"], "new")
        self.assertEqual(j["state"]["chapter"], "welcome")
        self.assertEqual(j["chapters"], ["welcome", "permissions", "voice", "vision", "office", "reshape", "help"])
        self.assertIsNone(j["permissions"], "no app report yet")

    def test_progress_saves_to_data_not_tracked_files(self):
        code, j = self.req("/api/onboarding", {"status": "open", "chapter": "voice", "seen": ["welcome", "voice"], "checks": ["prompt-copied"]})
        self.assertEqual(code, 200)
        self.assertEqual(j["state"]["chapter"], "voice")
        path = os.path.join(self.data, "onboarding.json")
        self.assertTrue(os.path.isfile(path))
        with open(path) as f:
            saved = json.load(f)
        self.assertEqual(saved["seen"], ["welcome", "voice"])
        # merges, never duplicates
        self.req("/api/onboarding", {"seen": ["voice", "vision"], "status": "done"})
        st = self.req("/api/onboarding")[1]["state"]
        self.assertEqual(st["seen"], ["welcome", "voice", "vision"])
        self.assertEqual(st["status"], "done")
        # reset starts over
        st = self.req("/api/onboarding", {"reset": True})[1]["state"]
        self.assertEqual((st["status"], st["seen"]), ("new", []))
        # nothing was written next to the code or the config
        self.assertFalse(os.path.exists(os.path.join(self.root, "goldware.json")))

    def test_data_folder_is_git_ignored(self):
        self.assertIn("/data/", read(".gitignore").split())

    def test_bad_input_rejected(self):
        for body in ({"status": "finished"}, {"chapter": "nope"}, {"seen": "welcome"}, {"seen": ["Bad Id!"]},
                     {"checks": ["x" * 41]}, {"checks": ["a"] * 51}, ["not", "an", "object"]):
            self.assertEqual(self.req("/api/onboarding", body)[0], 400, body)

    def test_cross_site_post_refused(self):
        code, _ = self.req("/api/onboarding", {"status": "done"}, {"Origin": "http://evil.example"})
        self.assertEqual(code, 403)

    def test_corrupt_file_is_quarantined(self):
        os.makedirs(self.data, exist_ok=True)
        with open(os.path.join(self.data, "onboarding.json"), "w") as f:
            f.write("{not json")
        code, j = self.req("/api/onboarding")
        self.assertEqual(code, 200)
        self.assertEqual(j["state"]["status"], "new")
        self.assertTrue(any(n.startswith("onboarding.json.corrupt-") for n in os.listdir(self.data)))

    def test_permissions_come_from_the_app_report(self):
        with open(os.path.join(self.appdata, "status.json"), "w") as f:
            json.dump({"microphone": "granted", "accessibility": "not granted", "camera": "not asked yet", "speech": "granted",
                       "calendar": "denied", "automation": "iterm closed", "updated": "2026-10-03T10:00:00Z",
                       "root": "/secret/path", "last_event": "private", "milestones": {"lets-work": "2026-10-03T10:00:00Z", "Bad Key": "x"}}, f)
        p = self.req("/api/onboarding")[1]["permissions"]
        self.assertEqual(p["microphone"], "granted")
        self.assertEqual(p["accessibility"], "not granted")
        self.assertEqual(p["automation"], "iterm closed")
        self.assertEqual(p["milestones"], ["lets-work"])
        # only the permission fields cross over; nothing else from the diagnostics file
        self.assertNotIn("root", p)
        self.assertNotIn("last_event", p)

    def test_page_and_assets_are_served(self):
        for name in ("tour.js", "tour.css", "gestures.js", "gestures.css"):
            r = urllib.request.urlopen(self.base + "/dashboard/" + name, timeout=5)
            self.assertEqual(r.status, 200, name)


class TourPage(unittest.TestCase):
    """Rules for the tour page that do not need a browser."""

    @classmethod
    def setUpClass(cls):
        cls.js = read("dashboard", "tour.js")
        cls.css = read("dashboard", "tour.css")
        cls.html = read("dashboard", "index.html")
        cls.lib = read("dashboard", "gestures.js")

    def test_loaded_by_the_dashboard(self):
        self.assertIn('<link rel="stylesheet" href="/dashboard/tour.css">', self.html)
        self.assertIn('<script src="/dashboard/tour.js"></script>', self.html)
        # the gesture library loads before the tour that uses it; the old stand-in is gone
        lib = '<script src="/dashboard/gestures.js"></script>'
        self.assertIn(lib, self.html)
        self.assertIn('<link rel="stylesheet" href="/dashboard/gestures.css">', self.html)
        self.assertNotIn("gestures-stub", self.html)
        self.assertFalse(os.path.exists(os.path.join(DASH, "gestures-stub.js")))
        self.assertLess(self.html.index(lib), self.html.index('<script src="/dashboard/tour.js"></script>'))

    def test_every_chapter(self):
        ids = re.findall(r'\{ id: "([a-z]+)", title: "[^"]+", body: ', self.js)
        self.assertEqual(ids, ["welcome", "permissions", "voice", "vision", "office", "reshape", "help"])
        for word in ("Microphone", "Accessibility", "Speech Recognition", "Camera", "Automation", "Calendar"):
            self.assertIn('"' + word, self.js, word)
        for word in ("Right Option", "Right Command", "Quadrants", "Let\\u2019s work", "Lock up", "Clear out", "Office Voice", "make doctor"):
            self.assertIn(word, self.js, word)

    def test_uses_the_gesture_api_exactly(self):
        self.assertIn("G.list()", self.js)
        self.assertIn('G.render(cell, g.id, { loop: true, size: "m" })', self.js)
        self.assertIn("window.GoldWareGestures = { list: list, render: render }", self.lib)

    def test_unlock_gesture_is_never_shown(self):
        self.assertIn("Set or use your unlock gesture.", self.js)
        # the library's unlock entry is filtered out before render
        self.assertIn("!isUnlock(g)", self.js)
        banned = r"(?i)diamond|index tips stay|thumb tips stay|palms spread|palms flat|let go of the tips|tips let go"
        self.assertNotRegex(self.js, banned)
        # the library lists the unlock gesture (as a private placeholder); the tour's filter catches it
        self.assertIn('"id": "unlock"', self.lib)
        self.assertIn("function isUnlock(g) { return /unlock|passcode/", self.js)

    def test_runs_once_skippable_replayable(self):
        self.assertIn('if (S.state && S.state.status === "new") open("welcome");', self.js)
        self.assertIn('close("skipped")', self.js)
        self.assertIn("Replay the tour", self.js)
        self.assertIn('id: "tour-btn"', self.js)
        self.assertIn(".card.welcome .card-body", self.js)

    def test_accessible(self):
        for attr in ('role: "dialog"', '"aria-modal": "true"', '"aria-labelledby": "tour-title"', '"aria-current", "step"',
                     'role: "progressbar"', '"aria-live": "polite"', 'e.key === "Escape"', 'e.key !== "Tab"'):
            self.assertIn(attr, self.js, attr)
        self.assertIn("prefers-reduced-motion: reduce", self.css)

    def test_no_external_assets_and_house_style(self):
        for name, text in (("tour.js", self.js), ("tour.css", self.css)):
            urls = [u for u in re.findall(r"https?://[^\s\"')]+", text) if not u.startswith("http://www.w3.org/")
                    and not u.startswith("https://github.com/JVKEGOLD/goldware-os")]
            self.assertEqual(urls, [], name)
            self.assertNotIn("\u2014", text, name)
            self.assertNotRegex(text, r"@import|url\((?!#)", name)
        self.assertIn("var(--accent)", self.css)

    def test_cdp_script_present(self):
        self.assertTrue(os.path.isfile(os.path.join(REPO, "tests", "tour_cdp.mjs")))


if __name__ == "__main__":
    unittest.main()
