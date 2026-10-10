"""The Office phone (dashboard/office-phone.js) and Hand to the boss on a whiteboard: the board action with
the boss stubbed, the boss's brief and command line, and what the shipped page may contain. The phone's
behaviour in a real browser is driven by tests/office_phone_cdp.mjs when Chrome and Node are installed."""
import os
import re
import shutil
import sys
import tempfile
import unittest

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(REPO, "server"))
os.environ["GOLDWARE_OFFICE_DRY_RUN"] = "1"   # no test ever runs osascript
import office  # noqa: E402
import office_boss  # noqa: E402


def read(*parts):
    with open(os.path.join(REPO, *parts), encoding="utf-8") as f:
        return f.read()


class HandToBoss(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.table = os.path.join(self.tmp, "shop")
        os.makedirs(self.table)
        for title in ("Order cups", "Fix the menu", "Call the roaster"):
            office.board_action(self.tmp, {"action": "add", "title": title, "group": self.table})
        office.board_action(self.tmp, {"action": "add", "title": "Elsewhere", "group": os.path.join(self.tmp, "other")})

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_one_line_to_the_boss_and_the_waiting_cards_are_tagged(self):
        lines = []
        out = office.hand_to_boss(self.tmp, self.table, "Shop", lambda line: lines.append(line) or {"ok": True, "sent": True})
        self.assertEqual(out["count"], 3)
        self.assertEqual(len(lines), 1)
        self.assertIn("Shop whiteboard", lines[0])
        self.assertIn("goldware-office board", lines[0])
        self.assertIn("goldware-office give TASK AGENT", lines[0])
        self.assertIn("waits for the user", lines[0])
        self.assertNotIn("\n", lines[0])
        tagged = [t["title"] for t in office.board_view(self.tmp)["tasks"] if t.get("boss")]
        self.assertEqual(sorted(tagged), ["Call the roaster", "Fix the menu", "Order cups"])

    def test_a_table_path_with_spaces_is_quoted_for_the_shell(self):
        spaced = os.path.join(self.tmp, "my shop")
        office.board_action(self.tmp, {"action": "add", "title": "Paint", "group": spaced})
        lines = []
        office.hand_to_boss(self.tmp, spaced, "", lambda line: lines.append(line) or {"ok": True})
        self.assertIn("'%s'" % spaced, lines[0])

    def test_nothing_waiting_is_refused_and_nothing_is_sent(self):
        lines = []
        with self.assertRaises(office.OfficeError):
            office.hand_to_boss(self.tmp, os.path.join(self.tmp, "empty"), "Empty", lambda line: lines.append(line) or {})
        self.assertEqual(lines, [])

    def test_assigning_a_card_clears_the_boss_tag(self):
        office.hand_to_boss(self.tmp, self.table, "Shop", lambda line: {"ok": True})
        tid = next(t["id"] for t in office.board_view(self.tmp)["tasks"] if t["title"] == "Order cups")
        agent = {"id": "a1", "tty": "ttys001", "kind": "hermes", "title": "Shop work", "cwd": self.table, "activity": "idle", "started_at": 1}
        office._assign(self.tmp, {"id": tid, "agent": "a1"}, agents=[agent], sender=lambda tty, line: True)
        t = next(t for t in office.board_view(self.tmp)["tasks"] if t["id"] == tid)
        self.assertEqual(t["status"], "assigned")
        self.assertNotIn("boss", t)


class BossBriefAndCli(unittest.TestCase):
    def test_the_brief_lists_the_board_commands(self):
        brief = office_boss.BRIEF if hasattr(office_boss, "BRIEF") else read("server", "office_boss.py")
        for cmd in ("goldware-office board", "goldware-office give TASK AGENT", "goldware-office done TASK"):
            self.assertIn(cmd, brief)
        self.assertIn("When the user hands you a whiteboard", brief)

    def test_the_cli_has_board_give_done(self):
        cli = read("scripts", "office")
        for cmd in ('cmd == "board"', 'cmd == "give"', 'cmd == "done"'):
            self.assertIn(cmd, cli)

    def test_the_server_routes_the_boss_action(self):
        src = read("server", "goldware_server.py")
        self.assertIn('body.get("action") == "boss"', src)
        self.assertIn("office.hand_to_boss(", src)


class PhonePage(unittest.TestCase):
    def setUp(self):
        self.js = read("dashboard", "office-phone.js")
        self.css = read("dashboard", "office-phone.css")
        self.html = read("dashboard", "index.html")

    def test_mounted_once_on_the_stage_with_a_demo_that_never_posts(self):
        self.assertIn('<link rel="stylesheet" href="/dashboard/office-phone.css">', self.html)
        self.assertEqual(self.html.count("mountOfficePhone(document.getElementById('office-stage')"), 1)
        self.assertIn("fetchJson: mountOfficePhone.demoFetch", self.html)
        self.assertIn("mountOfficePhone.demoFetch = (url, opts = {}) => (opts.method === 'POST' ? Promise.resolve(", self.js)

    def test_uses_the_office_endpoints_and_the_boss(self):
        for url in ("'/api/office/send'", "'/api/office/agents'", "'/api/office/chat?id='", "'/api/office/boss'"):
            self.assertIn(url, self.js)
        self.assertIn("const BOSS = /^(the )?boss$/i;", self.js)

    def test_reachable_everywhere_p_opens_esc_closes_first(self):
        self.assertIn("document.body.appendChild(corner);", self.js)
        self.assertIn("(e.key === 'p' || e.key === 'P')", self.js)
        self.assertIn("open && e.key === 'Escape' && !panel.contains(e.target)", self.js)
        self.assertNotRegex(self.css, r"wb-zooming|ow-walking|ow-out")
        self.assertIn("left: max(6.2%, 66px)", read("dashboard", "office-music.css"))

    def test_speaks_of_the_boss_and_this_dashboard(self):
        # Personal names are kept out by scripts/check_private.sh; here, only GoldWare's own words.
        for text in (self.js, self.css):
            self.assertIsNone(re.search(r"command center|template", text, re.I))
        self.assertIn("<h3>Boss</h3>", self.js)

    def test_routing_rule_in_node_when_available(self):
        node = shutil.which("node")
        if not node:
            self.skipTest("Node is not installed")
        import subprocess
        prog = ("global.window={};global.document={};require(%r);const r=window.mountOfficePhone.route;"
                "const a=[{id:'b1',name:'Bolt'},{id:'p1',name:'Pip'},{id:'x',name:'Boss',boss:true}];"
                "const o=[r('Bolt, run the tests',a),r('@Pip report',a),r('the boss, plan the week',a),r('Run the tests',a)].map(x=>x.to+'|'+x.text);"
                "console.log(JSON.stringify(o));") % os.path.join(REPO, "dashboard", "office-phone.js")
        out = subprocess.run([node, "-e", prog], capture_output=True, text=True, timeout=30)
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertEqual(out.stdout.strip(), '["b1|run the tests","p1|report","boss|plan the week","boss|Run the tests"]')

    def test_cdp_script_present(self):
        self.assertTrue(os.path.isfile(os.path.join(REPO, "tests", "office_phone_cdp.mjs")))


if __name__ == "__main__":
    unittest.main()
