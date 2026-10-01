import json
import os
import shutil
import socket
import sqlite3
import subprocess
import sys
import tempfile
import time
import unittest
import urllib.error
import urllib.request

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(REPO, "server"))
os.environ["GOLDWARE_OFFICE_DRY_RUN"] = "1"   # no test ever runs osascript
import office  # noqa: E402

NOW = 1_800_000_000.0

PS_MIXED = """\
  100     1 ??         0.0    01:00:00 /Applications/Ollama.app/Contents/Resources/ollama
  101   100 ??         0.0    01:00:00 /Applications/Ollama.app/Contents/Resources/llama-server
  200   150 ttys001    2.0    10:00 /opt/tools/hermes/bin/python3
  300   250 ttys002   31.5  1-02:03:04 /opt/tools/.local/bin/claude
  310   250 ttys003    0.1       05:00 /opt/homebrew/bin/codex
  320     1 ??         0.0       05:00 /opt/homebrew/bin/codex
  330   250 ttys004    0.0       05:00 /usr/bin/vim
  400     1 ??         0.0    09:00 /opt/homebrew/bin/whisper-server
garbage line that is not a process
"""


def make_hermes(home, pid, sid="sess-1", title="Plan the launch"):
    os.makedirs(os.path.join(home, "runtime"))
    with open(os.path.join(home, "runtime", "active_sessions.json"), "w") as f:
        json.dump({"entries": [{"pid": pid, "session_id": sid, "started_at": NOW - 600, "surface": "cli"}]}, f)
    con = sqlite3.connect(os.path.join(home, "state.db"))
    con.executescript("""
        CREATE TABLE sessions (id TEXT, source TEXT, title TEXT, model TEXT, billing_provider TEXT, message_count INT,
            input_tokens INT, output_tokens INT, cache_read_tokens INT, started_at REAL, cwd TEXT,
            parent_session_id TEXT, ended_at REAL);
        CREATE TABLE messages (id INTEGER PRIMARY KEY, session_id TEXT, role TEXT, tool_name TEXT, tool_calls TEXT,
            content TEXT, timestamp REAL, active INT);
        CREATE TABLE session_turn_leases (conversation_id TEXT, expires_at REAL);
    """)
    con.execute("INSERT INTO sessions VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)",
                (sid, "cli", title, "claude-opus-5-5", "anthropic", 4, 10, 20, 5, NOW - 600, "/tmp/x", None, None))
    con.execute("INSERT INTO messages (session_id, role, content, timestamp, active) VALUES (?,?,?,?,1)",
                (sid, "assistant", "All done.\n\nShould I ship it?", NOW - 30))
    con.commit()
    con.close()


class Parsing(unittest.TestCase):
    def test_parse_ps_fixture(self):
        procs = office.parse_ps(PS_MIXED)
        self.assertEqual(len(procs), 8)
        claude = [p for p in procs if p["name"] == "claude"][0]
        self.assertEqual((claude["pid"], claude["tty"], claude["cpu"]), (300, "ttys002", 31.5))
        self.assertEqual(claude["seconds"], 86400 + 2 * 3600 + 3 * 60 + 4)

    def test_etime(self):
        self.assertEqual(office.etime("05:07"), 307)
        self.assertEqual(office.etime("01:00:00"), 3600)
        self.assertEqual(office.etime("2-00:00:01"), 2 * 86400 + 1)

    def test_claude_and_codex_agents(self):
        procs = office.parse_ps(PS_MIXED)
        agents = office.cli_agents(procs, NOW, chome="/nonexistent", cwd_fn=lambda pid: "/work/shop")
        by_kind = {a["kind"]: a for a in agents}
        self.assertEqual(sorted(by_kind), ["claude", "codex"])      # vim and the tty-less codex are not agents
        self.assertEqual(len(agents), 2)
        self.assertEqual(by_kind["claude"]["title"], "Claude Code in shop")
        self.assertEqual(by_kind["claude"]["activity"], "typing")   # 31.5 percent CPU is busy
        self.assertTrue(by_kind["claude"]["working"])
        self.assertEqual(by_kind["codex"]["activity"], "idle")
        self.assertEqual(by_kind["codex"]["tty"], "ttys003")

    def test_rack_finds_ollama_and_whisper(self):
        procs = office.parse_ps(PS_MIXED)
        r = office.rack(procs, ollama_url="off")
        self.assertTrue(r["ollama"])
        self.assertEqual([u["kind"] for u in r["units"]], ["whisper"])

    def test_activity_rules(self):
        reply = {"role": "assistant", "tool_name": None, "tool_calls": None, "timestamp": NOW - 10}
        self.assertEqual(office.hermes_activity(reply, False, NOW), "your_turn")
        self.assertEqual(office.hermes_activity(reply, True, NOW), "thinking")
        tool = {"role": "tool", "tool_name": "terminal", "tool_calls": None, "timestamp": NOW}
        self.assertEqual(office.hermes_activity(tool, True, NOW), "typing")
        self.assertEqual(office.hermes_activity(None, False, NOW), "idle")
        old = dict(reply, timestamp=NOW - 3 * 3600)
        self.assertEqual(office.hermes_activity(old, False, NOW), "asleep")
        self.assertEqual(office.pretty_model("claude-opus-5-5"), "Opus 5.5")

    def test_closing_finds_the_question(self):
        c = office.closing("Did the thing.\n\n**Should** I ship it?")
        self.assertEqual(c, {"text": "Should I ship it?", "question": True})
        self.assertIsNone(office.closing("   "))


class Snapshots(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def snap(self, ps, home=None):
        return office.snapshot(now=NOW, home=home or os.path.join(self.tmp, "no-hermes"), ps_text=ps,
                               chome="/nonexistent", ollama_url="off", data_root=self.tmp,
                               cwd_fn=lambda pid: "/work/shop", gateway=False)

    def test_empty_machine(self):
        s = self.snap("")
        self.assertEqual(s["agents"], [])
        self.assertFalse(s["rack"]["ollama"])
        json.dumps(s)
        s = self.snap("  1     0 ??   0.0   01:00 /sbin/launchd\n")
        self.assertEqual(s["agents"], [])

    def test_hermes_absent_degrades(self):
        # Claude and Codex still show up with no ~/.hermes at all.
        s = self.snap(PS_MIXED)
        self.assertEqual(sorted(a["kind"] for a in s["agents"]), ["claude", "codex"])
        self.assertEqual(sorted(a["name"] for a in s["agents"]), ["Ada", "Bo"])
        self.assertEqual(office.hourly(NOW, home=os.path.join(self.tmp, "no-hermes"))[0]["claude"], 0)

    def test_hermes_present(self):
        home = os.path.join(self.tmp, "hermes")
        make_hermes(home, 200)
        s = self.snap(PS_MIXED, home=home)
        h = [a for a in s["agents"] if a["kind"] == "hermes"][0]
        self.assertEqual(h["title"], "Plan the launch")
        self.assertEqual(h["model"], "Opus 5.5")
        self.assertEqual(h["activity"], "your_turn")
        self.assertEqual(h["tty"], "ttys001")
        self.assertTrue(h["closing"]["question"])

    def test_dead_hermes_entry_is_ignored(self):
        home = os.path.join(self.tmp, "hermes")
        make_hermes(home, 99999)       # no such process in the list
        s = self.snap(PS_MIXED, home=home)
        self.assertEqual([a["kind"] for a in s["agents"] if a["kind"] == "hermes"], [])

    def test_names_are_stable_and_distinct(self):
        a = office.name_agents(self.tmp, ["x", "y"])
        b = office.name_agents(self.tmp, ["x", "y", "z"])
        self.assertEqual(a["x"], b["x"])
        self.assertEqual(len(set(b.values())), 3)


class Terminal(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        del office.DRY_LOG[:]
        office._SENT.clear()
        self.kw = dict(now=NOW, home=os.path.join(self.tmp, "no-hermes"), ps_text=PS_MIXED, chome="/nonexistent",
                       ollama_url="off", cwd_fn=lambda pid: "/work/shop", gateway=False)

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_send_rejected_for_unknown_agent_and_tty(self):
        with self.assertRaises(office.OfficeError) as cm:
            office.send_to_agent({"id": "claude-1", "text": "hi"}, **self.kw)
        self.assertEqual(cm.exception.status, 404)
        with self.assertRaises(office.OfficeError):
            office.send_to_agent({"id": "ttys099", "text": "hi"}, **self.kw)
        # vim sits on ttys004 but is not an agent
        with self.assertRaises(office.OfficeError):
            office.send_to_agent({"id": "ttys004", "text": "hi"}, **self.kw)
        self.assertEqual(office.DRY_LOG, [])      # nothing was even built

    def test_device_path_only_takes_real_ttys(self):
        for bad in ["../etc/passwd", "/dev/ttys001", "ttys001; rm", "tty", "??", None, "ttys"]:
            with self.assertRaises(office.OfficeError):
                office.device_path(bad)
        self.assertEqual(office.device_path("ttys012"), "/dev/ttys012")

    def test_send_builds_script_in_dry_run(self):
        r = office.send_to_agent({"id": "claude-300", "text": "run the tests"}, **self.kw)
        self.assertTrue(r["ok"])
        self.assertEqual(r["sent"], "run the tests")
        name, argv = office.DRY_LOG[-1]
        self.assertEqual(name, "send")
        self.assertEqual(argv[0:2], ["osascript", "-e"])
        self.assertEqual(argv[3:], ["/dev/ttys002", "run the tests"])
        self.assertIn("write text line_ newline no", argv[2])

    def test_escaping_text_is_an_argument_not_script(self):
        nasty = 'say "hi" \\ and \\n then\nnew line\ttab \x07bell` $(x) \'q\''
        r = office.send_to_agent({"id": "codex-310", "text": nasty}, **self.kw)
        name, argv = office.DRY_LOG[-1]
        # The script is the fixed template: no part of the typed text is inside it.
        self.assertEqual(argv[2], office.SEND_SCRIPT)
        self.assertNotIn("say", argv[2].replace("tell", ""))
        sent = argv[4]
        self.assertEqual(sent, r["sent"])
        self.assertNotIn("\n", sent)
        self.assertNotIn("\t", sent)
        self.assertNotIn("\x07", sent)
        self.assertIn('"hi"', sent)          # quotes survive untouched, as data
        self.assertIn("\\ and \\n", sent)    # backslashes survive untouched, as data

    def test_prepare_text_rules(self):
        self.assertEqual(office.prepare_text("hello", "hermes"), "/queue hello")
        self.assertEqual(office.prepare_text("/stop", "hermes"), "/stop")
        self.assertEqual(office.prepare_text("a\r\nb", "claude"), "a b")
        with self.assertRaises(office.OfficeError):
            office.prepare_text("  \n ", "claude")
        with self.assertRaises(office.OfficeError):
            office.prepare_text("x" * (office.MAX_TEXT + 1), "claude")
        self.assertEqual(len(office.prepare_text("x" * office.MAX_TEXT, "codex")), office.MAX_TEXT)

    def test_throttle_one_line_every_two_seconds(self):
        office.send_to_agent({"id": "claude-300", "text": "one"}, **self.kw)
        with self.assertRaises(office.OfficeError) as cm:
            office.send_to_agent({"id": "claude-300", "text": "two"}, **self.kw)
        self.assertEqual(cm.exception.status, 429)

    def test_focus_and_screen_dry_run(self):
        self.assertEqual(office.focus_agent({"id": "claude-300"}, **self.kw), {"ok": True})
        self.assertEqual(office.DRY_LOG[-1][1][3:], ["/dev/ttys002"])
        s = office.screen_of_agent("claude-300", **self.kw)
        self.assertEqual(s["tty"], "ttys002")
        self.assertIn("dry run", s["screen"])
        with self.assertRaises(office.OfficeError):
            office.focus_agent({"id": "nope"}, **self.kw)

    def test_assign_types_into_the_agents_terminal(self):
        office.board_action(self.tmp, {"action": "add", "title": "Write the readme"}, **self.kw)
        tid = office.board_view(self.tmp)["tasks"][0]["id"]
        out = office.board_action(self.tmp, {"action": "assign", "id": tid, "agent": "auto"}, **self.kw)
        t = out["board"]["tasks"][0]
        self.assertEqual(t["status"], "assigned")
        sent = office.DRY_LOG[-1][1][4]
        self.assertIn("Write the readme", sent)
        with self.assertRaises(office.OfficeError):
            office.board_action(self.tmp, {"action": "assign", "id": tid, "agent": "ttys004"}, **self.kw)


class Board(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_task_lifecycle_and_limits(self):
        r = office.board_action(self.tmp, {"action": "project", "name": "Shop", "about": "A coffee app"})
        self.assertEqual(r["board"]["project"]["name"], "Shop")
        office.board_action(self.tmp, {"action": "add", "title": "  Draft menu \n "})
        b = office.board_view(self.tmp)
        self.assertEqual(b["tasks"][0]["title"], "Draft menu")
        tid = b["tasks"][0]["id"]
        office.board_action(self.tmp, {"action": "done", "id": tid})
        self.assertEqual(office.board_view(self.tmp)["progress"], {"done": 1, "total": 1})
        office.board_action(self.tmp, {"action": "remove", "list": "tasks", "id": tid})
        self.assertEqual(office.board_view(self.tmp)["tasks"], [])
        with self.assertRaises(office.OfficeError):
            office.board_action(self.tmp, {"action": "add", "title": "   "})
        with self.assertRaises(office.OfficeError):
            office.board_action(self.tmp, {"action": "nope"})
        with self.assertRaises(office.OfficeError):
            office.board_action(self.tmp, {"action": "done", "id": "missing"})

    def test_lab_runs_through_a_fake_spawner_and_settles(self):
        calls = []

        def spawner(argv, out, err):
            calls.append(argv)
            with open(out, "w") as f:
                f.write('noise {"ideas": [{"title": "Loyalty stamps", "why": "People return."}]}')
            return 2 ** 22 + 1     # a pid that is not alive
        office.start_lab(self.tmp, "brainstorm", spawner=spawner)
        self.assertIn("--oneshot", calls[0])
        b = office.board_view(self.tmp)
        self.assertEqual(b["ideas"][0]["title"], "Loyalty stamps")
        self.assertEqual(b["runs"]["brainstorm"]["status"], "done")

    def test_lab_without_hermes_is_a_clear_error(self):
        old = os.environ.get("GOLDWARE_HERMES_BIN")
        path = os.environ.get("PATH")
        os.environ["PATH"] = self.tmp
        os.environ.pop("GOLDWARE_HERMES_BIN", None)
        try:
            with self.assertRaises(office.OfficeError) as cm:
                office.board_action(self.tmp, {"action": "lab", "kind": "research"})
            self.assertIn("Hermes", str(cm.exception))
        finally:
            os.environ["PATH"] = path
            if old:
                os.environ["GOLDWARE_HERMES_BIN"] = old


class Usage(unittest.TestCase):
    def test_parse_and_out(self):
        w = office.parse_claude(json.dumps({"five_hour": {"utilization": 100, "resets_at": "2026-10-01T12:00:00Z"},
                                            "seven_day": {"utilization": 40.04}}))
        self.assertEqual([x["label"] for x in w], ["5H", "WEEK"])
        p = office.plan("claude", "Claude", w, "x")
        self.assertTrue(p["out"])
        self.assertEqual(p["top"], 100)
        c = office.parse_codex(json.dumps({"rate_limit": {"primary_window": {"used_percent": 10, "limit_window_seconds": 18000},
                                                          "secondary_window": {"used_percent": 20, "limit_window_seconds": 604800}}}))
        self.assertEqual([x["label"] for x in c], ["5H", "WEEK"])
        self.assertIsNone(office.parse_claude("not json"))
        self.assertIsNone(office.parse_codex("{}"))

    def test_snapshot_uses_cache(self):
        office.reset_usage_cache()
        n = []
        fetch = lambda: n.append(1) or [office.plan("claude", "Claude", None, "Not signed in")]
        office.usage_snapshot(now=NOW, fetcher=fetch, home="/nonexistent")
        s = office.usage_snapshot(now=NOW + 10, fetcher=fetch, home="/nonexistent")
        self.assertEqual(len(n), 1)
        self.assertEqual(s["plans"][0]["error"], "Not signed in")
        self.assertEqual(len(s["hours"]), 24)
        office.reset_usage_cache()


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p


class OfficeHttp(unittest.TestCase):
    """The real server on an empty fixture: JSON everywhere, and POSTs only from the dashboard itself."""

    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.mkdtemp()
        root = os.path.join(cls.tmp, "root")
        os.makedirs(root)
        shutil.copy(os.path.join(REPO, "goldware.default.json"), root)
        cls.port = free_port()
        cls.base = "http://127.0.0.1:%d" % cls.port
        env = dict(os.environ, GOLDWARE_ROOT=root, GOLDWARE_DATA_ROOT=os.path.join(cls.tmp, "data"),
                   GOLDWARE_OFFICE_EMPTY="1", GOLDWARE_OFFICE_DRY_RUN="1")
        cls.proc = subprocess.Popen([sys.executable, os.path.join(REPO, "server", "goldware_server.py"),
                                     "--port", str(cls.port)], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        for _ in range(100):
            try:
                urllib.request.urlopen(cls.base + "/api/notes", timeout=1)
                break
            except Exception:
                time.sleep(0.1)

    @classmethod
    def tearDownClass(cls):
        cls.proc.terminate()
        cls.proc.wait(5)
        shutil.rmtree(cls.tmp, ignore_errors=True)

    def call(self, path, body=None, headers=None, ctype="application/json"):
        h = dict(headers or {})
        if body is not None:
            h["Content-Type"] = ctype
        data = body if isinstance(body, bytes) else (json.dumps(body).encode() if body is not None else None)
        try:
            r = urllib.request.urlopen(urllib.request.Request(self.base + path, data=data, headers=h), timeout=10)
        except urllib.error.HTTPError as e:
            r = e
        raw = r.read()
        try:
            return r.code, json.loads(raw)
        except ValueError:
            return r.code, raw

    def test_reads_are_valid_json_on_an_empty_machine(self):
        code, j = self.call("/api/office/agents")
        self.assertEqual((code, j["agents"]), (200, []))
        code, j = self.call("/api/office/board")
        self.assertEqual((code, j["tasks"], j["progress"]), (200, [], {"done": 0, "total": 0}))
        code, j = self.call("/api/office/usage")
        self.assertEqual((code, j["plans"]), (200, []))
        self.assertEqual(self.call("/api/office/screen?id=claude-1")[0], 404)
        self.assertEqual(self.call("/api/office/helper?id=x")[0], 404)
        self.assertEqual(self.call("/api/office/nothing")[0], 404)

    def test_post_without_same_origin_is_rejected(self):
        for path in ("/api/office/send", "/api/office/focus", "/api/office/board"):
            code, j = self.call(path, {"id": "claude-1", "text": "hi", "action": "add", "title": "x"})
            self.assertEqual(code, 403, path)           # no Origin or Referer at all
            code, _ = self.call(path, {"id": "x"}, {"Origin": "http://evil.example"})
            self.assertEqual(code, 403, path)
            code, _ = self.call(path, {"id": "x"}, {"Origin": "http://127.0.0.1:1"})
            self.assertEqual(code, 403, path)
            code, _ = self.call(path, {"id": "x"}, {"Referer": "http://evil.example/http://127.0.0.1:%d/" % self.port})
            self.assertEqual(code, 403, path)
            code, _ = self.call(path, {"id": "x"}, {"Origin": self.base, "Sec-Fetch-Site": "cross-site"})
            self.assertEqual(code, 403, path)

    def test_post_needs_json_content_type(self):
        code, _ = self.call("/api/office/send", b"id=1", {"Origin": self.base}, ctype="text/plain")
        self.assertEqual(code, 415)
        code, _ = self.call("/api/office/send", b"id=1", {"Origin": self.base}, ctype="application/x-www-form-urlencoded")
        self.assertEqual(code, 415)

    def test_same_origin_post_reaches_the_handlers(self):
        origin = {"Origin": self.base}
        code, j = self.call("/api/office/send", {"id": "claude-1", "text": "hi"}, origin)
        self.assertEqual(code, 404)           # allowed through, then: no such agent
        code, j = self.call("/api/office/focus", {"id": "claude-1"}, {"Referer": self.base + "/"})
        self.assertEqual(code, 404)
        code, j = self.call("/api/office/board", {"action": "add", "title": "Hello"}, origin)
        self.assertEqual((code, j["board"]["tasks"][0]["title"]), (200, "Hello"))
        code, j = self.call("/api/office/board", {"action": "bogus"}, origin)
        self.assertEqual(code, 422)

    def test_wrong_host_header_is_refused(self):
        r = urllib.request.Request(self.base + "/api/office/agents", headers={"Host": "evil.example"})
        with self.assertRaises(urllib.error.HTTPError) as cm:
            urllib.request.urlopen(r, timeout=5)
        self.assertEqual(cm.exception.code, 403)


if __name__ == "__main__":
    unittest.main()
