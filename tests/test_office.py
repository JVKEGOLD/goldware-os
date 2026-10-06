import json
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
from unittest import mock
import urllib.error
import urllib.request

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(REPO, "server"))
os.environ["GOLDWARE_OFFICE_DRY_RUN"] = "1"   # no test ever runs osascript
import office  # noqa: E402
import office_launch  # noqa: E402
import office_boss  # noqa: E402

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


def make_hermes(home, pid, sid="sess-1", title="Plan the launch", cwd="/tmp/x"):
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
                (sid, "cli", title, "claude-opus-5-5", "anthropic", 4, 10, 20, 5, NOW - 600, cwd, None, None))
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
        self.assertEqual(sorted(a["name"] for a in s["agents"]), ["Bolt", "Mocha"])
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

    def test_the_subject_skips_agent_reports(self):
        # An agent's report to the boss is a user message too, but the user did not ask it.
        home = os.path.join(self.tmp, "hermes")
        make_hermes(home, 200)
        con = sqlite3.connect(os.path.join(home, "state.db"))
        for at, text in ((NOW - 50, "/queue Fix the shelf please"),
                         (NOW - 40, 'Report from Mocha (id g9, "Lane", in /home/a/x): done.'),
                         (NOW - 35, '/queue Report from Bolt (id g8, "Lane", in /home/a/x): done too.')):
            con.execute("INSERT INTO messages (session_id, role, content, timestamp, active) VALUES ('sess-1','user',?,?,1)", (text, at))
        con.commit()
        con.close()
        h = [a for a in self.snap(PS_MIXED, home=home)["agents"] if a["kind"] == "hermes"][0]
        self.assertEqual(h["ask"], "Fix the shelf please")

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

    def test_names_come_from_the_cast_then_agent_n(self):
        ids = ["a%d" % i for i in range(12)]
        names = office.name_agents(self.tmp, ids)
        self.assertEqual([names[i] for i in ids[:10]], office.NAMES)
        self.assertEqual([names[i] for i in ids[10:]], ["Agent 11", "Agent 12"])

    def test_a_table_only_sends_to_its_own_agents(self):
        agents = [{"id": "a", "tty": "ttys001", "cwd": "/work/one"}, {"id": "b", "tty": "ttys002", "cwd": "/work/two"},
                  {"id": "c", "tty": "ttys003", "cwd": None}]
        self.assertEqual([a["id"] for a in office.table_agents(agents, {"group": "/work/two"})], ["b"])
        self.assertEqual([a["id"] for a in office.table_agents(agents, {})], ["c"])

    def test_chat_turns_fold_tool_calls(self):
        rows = [{"role": "user", "text": "Fix it"},
                {"role": "assistant", "text": "", "tools": ["terminal", "terminal", "patch"]},
                {"role": "assistant", "text": "Done.", "tools": []}]
        self.assertEqual(office.chat_turns(rows), [{"kind": "you", "text": "Fix it"},
                                                    {"kind": "did", "text": "Ran 2 commands, edited 1 file"},
                                                    {"kind": "said", "text": "Done."}])


CLARIFY_CALL = json.dumps([{"type": "function", "function": {"name": "clarify", "arguments": json.dumps(
    {"questions": [{"question": "Who should do the gym?", "choices": ["Me", "Bolt"]},
                   {"question": "Which rooms?", "choices": ["Floor", "Desk", "Wall"], "multi_select": True}]})}}])
PANEL = """\
╭─ Hermes Agent needs your input ────────────────╮
│ 2 questions                                    │
│ ▸ Who should do the gym?                       │
│   ❯ 1. Me                                      │
╰────────────────────────────────────────────────╯
"""


class Clarify(unittest.TestCase):
    """An agent's multiple-choice question shows in the chat as an ask, and is answered by typing keys."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        del office.DRY_LOG[:]
        self.home = os.path.join(self.tmp, "hermes")
        make_hermes(self.home, 200)
        self.kw = dict(now=NOW, home=self.home, ps_text=PS_MIXED, chome="/nonexistent", ollama_url="off",
                       cwd_fn=lambda pid: "/work/shop", gateway=False)
        self.db = os.path.join(self.home, "state.db")

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def add(self, role, content="", calls=None):
        con = sqlite3.connect(self.db)
        con.execute("INSERT INTO messages (session_id, role, content, tool_calls, timestamp, active) VALUES ('sess-1',?,?,?,?,1)",
                    (role, content, calls, NOW))
        con.commit()
        con.close()

    def test_a_clarify_question_shows_in_the_chat_and_closes_when_answered(self):
        asks = office.clarify_asks(CLARIFY_CALL)
        self.assertEqual([(q["question"], q["choices"], q["multi"]) for q in asks],
                         [("Who should do the gym?", ["Me", "Bolt"], False), ("Which rooms?", ["Floor", "Desk", "Wall"], True)])
        self.assertEqual(office.clarify_asks('[{"function":{"name":"terminal","arguments":"{}"}}]'), [])
        self.assertEqual(office.clarify_asks(CLARIFY_CALL[:60]), [], "a call cut off by the length limit is ignored")
        self.assertEqual(office.clarify_asks(CLARIFY_CALL.replace('"clarify"', '"mcp__clarify"'))[0]["question"], "Who should do the gym?")
        answer = office.clarify_answer_row({"timestamp": 5, "content": json.dumps({"outcome": "submitted", "responses": [
            {"question": "Who should do the gym?", "status": "answered", "user_response": "Bolt"},
            {"question": "Which rooms?", "status": "answered", "user_response": '["Floor", "Wall"]'}]})})
        self.assertEqual([x["answer"] for x in answer["answers"]], ["Bolt", "Floor, Wall"])
        rows = [{"role": "user", "text": "Make it a gym"}, {"role": "assistant", "text": "", "tools": ["clarify"], "asks": asks}]
        turns = office.chat_turns(rows)
        self.assertEqual([t["kind"] for t in turns], ["you", "ask"])
        self.assertTrue(turns[-1]["open"], "an unanswered question is open")
        turns = office.chat_turns(rows + [answer])
        self.assertEqual([t["kind"] for t in turns], ["you", "ask", "answered"])
        self.assertFalse(turns[1]["open"], "answering closes it")
        self.assertEqual(turns[2]["answers"][1]["answer"], "Floor, Wall")

    def test_the_chat_view_reads_the_question_and_its_answer_from_the_database(self):
        self.add("assistant", "", CLARIFY_CALL)
        kinds = [t["kind"] for t in office.chat_turns(office.hermes_chat_rows("sess-1", self.home))]
        self.assertEqual(kinds[-2:], ["said", "ask"])
        self.add("tool", json.dumps({"responses": [{"question": "Who should do the gym?", "user_response": "Me"}], "outcome": "submitted"}))
        self.add("tool", "plain output that is not an answer")
        turns = office.chat_turns(office.hermes_chat_rows("sess-1", self.home))
        self.assertEqual([t["kind"] for t in turns][-2:], ["ask", "answered"])
        self.assertFalse(turns[-2]["open"])

    def test_answers_become_the_keys_its_terminal_expects(self):
        asks = [{"question": "Who?", "choices": ["Me", "Bolt"], "multi": False},
                {"question": "Which rooms?", "choices": ["Floor", "Desk", "Wall"], "multi": True},
                {"question": "Anything else?", "choices": [], "multi": False}]
        e = office.ENTER
        self.assertEqual(office.clarify_keys(asks, [{"picks": [1]}, {"picks": [2, 0]}, {"other": "Paint it\nred"}]),
                         ["2", "1", "3", e, "Paint it red", e])
        self.assertEqual(office.clarify_keys(asks, [{"other": "Neither"}, {"picks": [], "other": "Roof"}, {"other": "x"}]),
                         ["3", "Neither", e, "4", e, "Roof", e, "x", e], "Other is the number after the last choice, then the typed answer")
        for bad in ([{"picks": [0, 1]}, {"picks": [0]}, {"other": "x"}],      # two picks on a single choice
                    [{"picks": [5]}, {"picks": [0]}, {"other": "x"}],         # not on the list
                    [{"picks": [0]}, {"picks": []}, {"other": "x"}],          # nothing ticked
                    [{"picks": [0]}, {"picks": [0]}, {}],                     # no typed answer
                    [{"picks": [0]}]):                                        # a question left out
            with self.assertRaises(office.OfficeError, msg=bad):
                office.clarify_keys(asks, bad)
        with self.assertRaises(office.OfficeError):
            office.clarify_keys([], [])

    def test_the_question_panel_is_recognised_on_screen_even_when_wrapped(self):
        panel = """\
╭─ Hermes Agent needs your input ────────────────╮
│ 2 questions                                    │
│ ▸ I cleared 7 items where I had proof they     │
│   were finished or replaced. These next ones   │
│   ❯ 1. Apple (Recommended)                     │
╰────────────────────────────────────────────────╯
"""
        asks = [{"question": "I cleared 7 items where I had proof they were finished or replaced.", "choices": ["A", "B"]}]
        self.assertTrue(office.clarify_on_screen(panel, asks))
        self.assertFalse(office.clarify_on_screen(panel.replace("needs your input", "is done"), asks), "no panel, no keys")
        self.assertFalse(office.clarify_on_screen(panel, [{"question": "Something else entirely", "choices": []}]))

    def test_only_a_still_waiting_question_is_answered_and_the_keys_go_to_its_tty(self):
        self.add("assistant", "", CLARIFY_CALL)
        self.assertEqual([q["question"] for q in office.pending_clarify("sess-1", home=self.home)], ["Who should do the gym?", "Which rooms?"])
        body = {"id": "sess-1", "answers": [{"picks": [1]}, {"picks": [0, 2]}]}
        with mock.patch.object(office, "screen", return_value="nothing to see"):
            with self.assertRaises(office.OfficeError) as cm:
                office.answer_clarify(body, **self.kw)
        self.assertIn("not showing that question", str(cm.exception))
        self.assertEqual([n for n, _ in office.DRY_LOG if n == "keys"], [], "nothing is typed when the panel is not up")
        with mock.patch.object(office, "screen", return_value=PANEL):
            self.assertEqual(office.answer_clarify(body, **self.kw), {"ok": True, "keys": 4})
        name, argv = office.DRY_LOG[-1]
        self.assertEqual(name, "keys")
        self.assertEqual(argv[3:], ["/dev/ttys001", "2", "1", "3", "GW-ENTER"])
        self.assertIn("GW-ENTER", office.KEYS_SCRIPT)
        # Answered in the terminal meanwhile: nothing is waiting, nothing is typed.
        self.add("tool", json.dumps({"responses": []}))
        self.assertEqual(office.pending_clarify("sess-1", home=self.home), [])
        with self.assertRaises(office.OfficeError) as cm:
            office.answer_clarify(body, **self.kw)
        self.assertIn("Nothing is waiting", str(cm.exception))

    def test_only_hermes_questions_and_known_agents(self):
        with self.assertRaises(office.OfficeError) as cm:
            office.answer_clarify({"id": "nobody", "answers": []}, **self.kw)
        self.assertEqual(cm.exception.status, 404)
        with self.assertRaises(office.OfficeError) as cm:
            office.answer_clarify({"id": "claude-300", "answers": []}, **self.kw)
        self.assertIn("Only Hermes", str(cm.exception))
        with self.assertRaises(office.OfficeError):
            office.answer_clarify([], **self.kw)


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
        office.board_action(self.tmp, {"action": "add", "title": "Write the readme", "group": "/work/shop"}, **self.kw)
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

    def test_regroup_sorts_one_whiteboard_and_keeps_every_task(self):
        home = "/home/a"
        add = lambda title, group=None: office.board_action(self.tmp, {"action": "add", "title": title, "group": group})["result"]
        a, b, c = add("Shop: fix menu", "/home/a/proj"), add("Decide: logo", "/home/a/proj"), add("Order beans", "/home/a/proj")
        other = add("Elsewhere")
        calls = []
        reply = json.dumps({"groups": [{"name": "Your call", "needs_user": True, "ids": [b["id"], other["id"], "bogus"]},
                                       {"name": "Shop", "ids": [a["id"], b["id"]]}, {"name": "Empty", "ids": []}]})

        def spawner(argv, out, err):
            calls.append(argv)
            with open(out, "w") as f:
                f.write("Sure.\n" + reply)
            return 2 ** 22 + 1
        office.start_lab(self.tmp, "regroup", spawner=spawner, table="/home/a/proj", home=home)
        prompt = open([os.path.join(self.tmp, "lab", n) for n in os.listdir(os.path.join(self.tmp, "lab")) if n.endswith(".prompt")][0]).read()
        self.assertIn(a["id"], prompt)
        self.assertNotIn("Elsewhere", prompt)
        self.assertIn("--oneshot", calls[0])
        b_ = office.board_view(self.tmp)
        groups = b_["groupings"]["/home/a/proj"]["groups"]
        self.assertEqual([[g["name"], g["needs_user"], g["ids"]] for g in groups],
                         [["Your call", True, [b["id"]]], ["Shop", False, [a["id"]]], ["Everything else", False, [c["id"]]]])
        self.assertEqual(b_["runs"]["regroup"]["status"], "done")
        office.board_action(self.tmp, {"action": "ungroup", "table": "/home/a/proj"})
        self.assertNotIn("/home/a/proj", office.board_view(self.tmp)["groupings"])
        with self.assertRaises(office.OfficeError):
            office.start_lab(self.tmp, "regroup", spawner=spawner, table="/home/a/empty", home=home)
        with self.assertRaises(office.OfficeError):
            office.board_action(self.tmp, {"action": "lab", "kind": "regroup"})
        self.assertEqual(office.parse_regroup("no json", [a["id"]]), [])

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


class Launch(unittest.TestCase):
    """New agent: ids in, a quoted cd line out, and settings that only touch office.topics and office.presets."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.root = os.path.join(self.tmp, "root")
        os.makedirs(self.root)
        self.default = os.path.join(self.root, "goldware.default.json")
        self.user = os.path.join(self.root, "goldware.json")
        self.odd = os.path.join(self.tmp, "my app's \"dir\"")        # a space, a quote and a double quote
        self.plain = os.path.join(self.tmp, "plain")
        os.makedirs(self.odd)
        os.makedirs(self.plain)
        with open(self.default, "w") as f:
            json.dump({"assistantName": "GoldWare", "accentColor": "#C9A24A",
                       "office": {"topics": [{"id": "home", "label": "Home", "dir": "~"}],
                                  "presets": [{"id": "echo", "label": "Echo", "command": "echo hi"},
                                              {"id": "ghost", "label": "Ghost", "command": "no-such-agent-binary --x"}]}}, f)
        del office.DRY_LOG[:]
        office_launch.reset_throttle()
        self._env = os.environ.get("GOLDWARE_OFFICE_TERMINAL")
        os.environ["GOLDWARE_OFFICE_TERMINAL"] = "iTerm"

    def tearDown(self):
        if self._env is None:
            os.environ.pop("GOLDWARE_OFFICE_TERMINAL", None)
        else:
            os.environ["GOLDWARE_OFFICE_TERMINAL"] = self._env
        shutil.rmtree(self.tmp, ignore_errors=True)

    def write_user(self, topics, presets, extra=None):
        cfg = {"office": {"topics": topics, "presets": presets}}
        cfg.update(extra or {})
        with open(self.user, "w") as f:
            json.dump(cfg, f)

    def new(self, body):
        return office_launch.new_agent(body, self.default, self.user)

    def test_defaults_when_goldware_json_is_absent(self):
        r = self.new({"type": "echo", "topic": "home"})
        self.assertTrue(r["ok"])
        name, argv = office.DRY_LOG[-1]
        self.assertEqual(name, "new")
        self.assertEqual(argv[:2], ["osascript", "-e"])
        self.assertEqual(argv[2], office_launch.NEW_ITERM_SCRIPT)
        self.assertEqual(argv[4], "cd %s && echo hi" % os.path.expanduser("~"))

    def test_folder_with_space_and_quotes_is_shell_quoted(self):
        import shlex
        self.write_user([{"id": "odd", "label": "Odd", "dir": self.odd}], [{"id": "e", "label": "E", "command": "echo \"a b\" 'c'"}])
        self.new({"type": "e", "topic": "odd"})
        argv = office.DRY_LOG[-1][1]
        line = argv[4]
        self.assertEqual(shlex.split(line), ["cd", self.odd, "&&", "echo", "a b", "c"])   # round-trips through a shell parser
        self.assertEqual(argv[2], office_launch.NEW_ITERM_SCRIPT)                        # the script never contains the line
        self.assertNotIn(self.odd, argv[2])
        self.assertNotIn("echo", argv[2])

    def test_terminal_fallback_script(self):
        os.environ["GOLDWARE_OFFICE_TERMINAL"] = "Terminal"
        r = self.new({"type": "echo", "topic": "home"})
        self.assertEqual(r["terminal"], "Terminal")
        self.assertEqual(office.DRY_LOG[-1][1][2], office_launch.NEW_TERMINAL_SCRIPT)

    def test_unknown_ids_are_422(self):
        for body in ({"type": "nope", "topic": "home"}, {"type": "echo", "topic": "nope"}, {"type": 5, "topic": "home"},
                     {"type": ["echo"], "topic": "home"}, {"type": "echo", "topic": {"dir": "/tmp"}}):
            office_launch.reset_throttle()
            with self.assertRaises(office.OfficeError) as cm:
                self.new(body)
            self.assertEqual(cm.exception.status, 422, body)
        self.assertEqual(office.DRY_LOG, [])

    def test_request_cannot_supply_a_folder_or_command(self):
        self.new({"type": "echo", "topic": "home", "dir": "/etc", "command": "rm -rf /", "cmd": "x"})
        line = office.DRY_LOG[-1][1][4]
        self.assertTrue(line.endswith("&& echo hi"))
        self.assertNotIn("/etc", line)

    def test_missing_folder_says_so(self):
        gone = os.path.join(self.tmp, "gone")
        self.write_user([{"id": "gone", "label": "Gone", "dir": gone}], [{"id": "e", "label": "E", "command": "echo hi"}])
        with self.assertRaises(office.OfficeError) as cm:
            self.new({"type": "e", "topic": "gone"})
        self.assertIn("folder for Gone is missing", str(cm.exception))
        self.assertEqual(office.DRY_LOG, [])

    def test_choose_folder_returns_the_picked_folder_with_tilde(self):
        r = office_launch.choose_folder()
        self.assertEqual(r, {"dir": "~/Projects/Bakery Site", "name": "Bakery Site"})
        name, argv = office.DRY_LOG[-1]
        self.assertEqual(name, "choose")
        self.assertEqual(argv[2], office_launch.CHOOSE_FOLDER_SCRIPT)
        self.assertNotIn(os.path.expanduser("~"), argv[2])            # the script holds no path
        before = open(self.default).read()
        self.assertFalse(os.path.exists(self.user))                    # picking never saves
        self.assertEqual(open(self.default).read(), before)

    def test_tilde_and_cancel(self):
        self.assertEqual(office_launch.tilde("/home/a/", "/home/a"), "~")
        self.assertEqual(office_launch.tilde("/home/a/x y/", "/home/a"), "~/x y")
        self.assertEqual(office_launch.tilde("/Volumes/Drive/site/", "/home/a"), "/Volumes/Drive/site")
        self.assertEqual(office_launch.tilde("/home/ab/c", "/home/a"), "/home/ab/c")   # a lookalike prefix stays whole
        orig = office.osa
        try:
            office.osa = lambda *a, **k: ("CANCELLED\n", "", 0)
            self.assertEqual(office_launch.choose_folder(), {"cancelled": True})
            office.osa = lambda *a, **k: ("/x/\x07bad/\n", "", 0)
            with self.assertRaises(office.OfficeError):
                office_launch.choose_folder()
        finally:
            office.osa = orig

    def test_only_one_picker_at_a_time(self):
        office_launch._CHOOSING.acquire()
        try:
            with self.assertRaises(office.OfficeError) as cm:
                office_launch.choose_folder()
            self.assertEqual(cm.exception.status, 409)
        finally:
            office_launch._CHOOSING.release()

    def test_unavailable_binary_is_refused_and_flagged(self):
        with self.assertRaises(office.OfficeError) as cm:
            self.new({"type": "ghost", "topic": "home"})
        self.assertEqual(cm.exception.status, 422)
        self.assertIn("not installed", str(cm.exception))
        v = office_launch.view(self.default, self.user)
        self.assertEqual({p["id"]: p["available"] for p in v["presets"]}, {"echo": True, "ghost": False})

    def test_rate_limit_one_window_per_gap(self):
        self.new({"type": "echo", "topic": "home"})
        with self.assertRaises(office.OfficeError) as cm:
            self.new({"type": "echo", "topic": "home"})
        self.assertEqual(cm.exception.status, 429)
        self.assertEqual(len(office.DRY_LOG), 1)

    def good(self):
        return {"topics": [{"label": "Plain", "dir": self.plain}, {"label": "Home", "dir": "~"}],
                "presets": [{"label": "My agent", "command": "echo hello"}]}

    def test_save_validation(self):
        long_label = "x" * 41
        bad = [
            ({"topics": [{"label": "A", "dir": "relative/path"}]}, "start with"),
            ({"topics": [{"label": "A", "dir": os.path.join(self.tmp, "nope")}]}, "does not exist"),
            ({"topics": [{"label": "A", "dir": self.plain + "\nx"}]}, "one line"),
            ({"topics": [{"label": long_label, "dir": self.plain}]}, "1 to 40"),
            ({"topics": [{"label": "", "dir": self.plain}]}, "1 to 40"),
            ({"topics": [{"label": "A\x07", "dir": self.plain}]}, "control"),
            ({"topics": []}, "between 1 and 20"),
            ({"topics": [{"label": "T%d" % i, "dir": self.plain} for i in range(21)]}, "between 1 and 20"),
            ({"presets": [{"label": "P%d" % i, "command": "echo"} for i in range(21)]}, "between 1 and 20"),
            ({"presets": [{"label": "A", "command": "echo\nrm -rf /"}]}, "one line"),
            ({"presets": [{"label": "A", "command": "echo \x1b[31m"}]}, "one line"),
            ({"presets": [{"label": "A", "command": "x" * 200}]}, "under 200"),
            ({"presets": [{"label": "A", "command": 5}]}, "needs a command"),
            ({"presets": [{"label": long_label, "command": "echo"}]}, "1 to 40"),
            ({"presets": "echo"}, "between 1 and 20"),
            ({}, "Send topics"),
        ]
        for body, word in bad:
            with self.assertRaises(office.OfficeError, msg=str(body)[:60]) as cm:
                office_launch.save(body, self.default, self.user)
            self.assertEqual(cm.exception.status, 422)
            self.assertIn(word, str(cm.exception))
        self.assertFalse(os.path.exists(self.user))          # nothing was written by any failed save

    def test_save_creates_from_defaults_and_makes_slug_ids(self):
        body = self.good()
        body["topics"].append({"label": "Plain", "dir": self.plain})      # duplicate label -> unique id
        out = office_launch.save(body, self.default, self.user)
        with open(self.user) as f:
            cfg = json.load(f)
        self.assertEqual(cfg["assistantName"], "GoldWare")                # created from the defaults
        self.assertEqual([t["id"] for t in cfg["office"]["topics"]], ["plain", "home", "plain-2"])
        self.assertEqual(cfg["office"]["presets"], [{"id": "my-agent", "label": "My agent", "command": "echo hello"}])
        self.assertEqual([t["id"] for t in out["topics"]], ["plain", "home", "plain-2"])
        self.assertEqual(os.listdir(self.root).count("goldware.json"), 1)
        self.assertFalse([n for n in os.listdir(self.root) if n.endswith(".tmp")])

    def test_save_preserves_other_keys_and_only_replaces_what_was_sent(self):
        orig = {"assistantName": "Mine", "accentColor": "#112233", "custom": {"keep": [1, 2]},
                "office": {"other": "stay", "topics": [{"id": "x", "label": "X", "dir": "~"}],
                           "presets": [{"id": "y", "label": "Y", "command": "echo y"}]}}
        with open(self.user, "w") as f:
            json.dump(orig, f)
        office_launch.save({"presets": [{"label": "Z", "command": "echo z"}]}, self.default, self.user)
        with open(self.user) as f:
            cfg = json.load(f)
        self.assertEqual(cfg["assistantName"], "Mine")
        self.assertEqual(cfg["custom"], {"keep": [1, 2]})
        self.assertEqual(cfg["office"]["other"], "stay")
        self.assertEqual(cfg["office"]["topics"], orig["office"]["topics"])
        self.assertEqual(cfg["office"]["presets"], [{"id": "z", "label": "Z", "command": "echo z"}])

    def test_save_is_atomic(self):
        orig = json.dumps({"office": {"topics": [{"id": "x", "label": "X", "dir": "~"}], "presets": [{"id": "y", "label": "Y", "command": "echo y"}]}})
        with open(self.user, "w") as f:
            f.write(orig)
        real = os.replace
        calls = []

        def boom(src, dst):
            calls.append((src, dst))
            raise OSError("disk full")
        office_launch.os.replace = boom
        try:
            with self.assertRaises(OSError):
                office_launch.save(self.good(), self.default, self.user)
        finally:
            office_launch.os.replace = real
        with open(self.user) as f:
            self.assertEqual(f.read(), orig)                              # untouched
        self.assertEqual(calls[0][1], self.user)                          # it went through a rename
        self.assertNotEqual(calls[0][0], self.user)
        self.assertEqual(os.path.dirname(calls[0][0]), self.root)         # temp file in the same folder
        self.assertFalse([n for n in os.listdir(self.root) if n.endswith(".tmp")])   # and was cleaned up

    def test_broken_goldware_json_is_not_overwritten(self):
        with open(self.user, "w") as f:
            f.write("{ not json")
        with self.assertRaises(office.OfficeError) as cm:
            office_launch.save(self.good(), self.default, self.user)
        self.assertEqual(cm.exception.status, 409)
        with open(self.user) as f:
            self.assertEqual(f.read(), "{ not json")

    def test_saved_lists_are_used_by_new_agent(self):
        office_launch.save(self.good(), self.default, self.user)
        self.new({"type": "my-agent", "topic": "plain"})
        self.assertEqual(office.DRY_LOG[-1][1][4], "cd %s && echo hello" % self.plain)


PS_DISMISS = """\
  500   450 ttys005    0.2       05:00 /opt/homebrew/bin/codex
  501   500 ttys005    0.0       05:00 /bin/zsh
  502     1 ttys005    0.0       05:00 /usr/bin/login
  503   502 ttys005    0.0       05:00 -zsh
  600   450 ttys006    0.1       05:00 /opt/homebrew/bin/codex
  601   600 ttys006    0.0       05:00 /bin/zsh
"""


class Dismiss(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        del office.DRY_LOG[:]
        del office.DISMISS_LOG[:]
        office._SENT.clear()
        self.kw = dict(now=NOW, home=os.path.join(self.tmp, "no-hermes"), ps_text=PS_DISMISS, chome="/nonexistent",
                       ollama_url="off", cwd_fn=lambda pid: "/work/shop", gateway=False)

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    idle = {"tty": "ttys005", "working": False, "activity": "idle", "helpers": [], "name": "Bolt"}

    def test_blocker_cases(self):
        b = office.dismiss_blocker
        self.assertIsNone(b(self.idle, " 0.0 -zsh\n 0.1 hermes\n"))
        self.assertIn("not at a terminal", b(dict(self.idle, tty=None), ""))
        self.assertIn("not at a terminal", b(None, ""))
        self.assertIn("working", b(dict(self.idle, working=True), ""))
        for act in office.DISMISS_BUSY:
            self.assertIn("working", b(dict(self.idle, activity=act), ""), act)
        for act in ("idle", "asleep", "your_turn", "done"):
            self.assertIsNone(b(dict(self.idle, activity=act), ""), act)
        self.assertIn("helpers", b(dict(self.idle, helpers=[{"id": "h"}]), ""))
        self.assertIn("working", b(self.idle, " 4.2 /opt/bin/claude\n"))
        self.assertIn("working", b(self.idle, " 3.0 codex\n"))
        self.assertIsNone(b(self.idle, " 1.0 claude\n 2.9 /x/codex\n"))

    def test_bad_tty_refused(self):
        for bad in ("ttys005; rm -rf", "../etc", "/dev/ttys005", "tty", None, "ttys"):
            with self.assertRaises(office.OfficeError):
                office.dismiss({"id": "codex-500", "tty": bad}, **self.kw)
        self.assertEqual(office.DRY_LOG, [])
        self.assertEqual(office.DISMISS_LOG, [])

    def test_unknown_agent_404_and_not_an_agent_tty(self):
        with self.assertRaises(office.OfficeError) as cm:
            office.dismiss_agent({"id": "codex-999", "step": "check"}, **self.kw)
        self.assertEqual(cm.exception.status, 404)
        with self.assertRaises(office.OfficeError) as cm:
            office.dismiss({"id": "ttys005", "tty": "ttys005"}, **self.kw)     # a tty is not an agent id
        self.assertEqual(cm.exception.status, 404)
        # a forged agent dict with a real-looking tty but an id that is not detected
        with self.assertRaises(office.OfficeError):
            office.dismiss({"id": "claude-1", "tty": "ttys005"}, **self.kw)
        self.assertEqual(office.DISMISS_LOG, [])

    def test_bad_step_422(self):
        for step in (None, "", "nope", "ASK", 5):
            with self.assertRaises(office.OfficeError) as cm:
                office.dismiss_agent({"id": "codex-500", "step": step}, **self.kw)
            self.assertEqual(cm.exception.status, 422)
        with self.assertRaises(office.OfficeError) as cm:
            office.dismiss_agent("x", **self.kw)
        self.assertEqual(cm.exception.status, 422)

    def test_check_step(self):
        self.assertEqual(office.dismiss_agent({"id": "codex-500", "step": "check"}, **self.kw), {"ok": True})
        busy = "  700   450 ttys007   12.0       05:00 /opt/homebrew/bin/codex\n"
        kw = dict(self.kw, ps_text=PS_DISMISS + busy)
        with self.assertRaises(office.OfficeError) as cm:
            office.dismiss_agent({"id": "codex-700", "step": "check"}, **kw)
        self.assertEqual(cm.exception.status, 409)
        with self.assertRaises(office.OfficeError) as cm:
            office.dismiss_agent({"id": "codex-700", "step": "close"}, **kw)
        self.assertEqual(cm.exception.status, 409)
        self.assertEqual(office.DISMISS_LOG, [])

    def test_ask_uses_the_send_path(self):
        r = office.dismiss_agent({"id": "codex-500", "step": "ask"}, **self.kw)
        self.assertEqual(r, {"ok": True, "asked": True, "queued": False})
        name, argv = office.DRY_LOG[-1]
        self.assertEqual(name, "send")
        self.assertEqual(argv[2], office.SEND_SCRIPT)
        self.assertEqual(argv[3:], ["/dev/ttys005", office.DISMISS_ASK])
        self.assertEqual(office.DISMISS_LOG, [])

    def test_close_plans_signals_for_that_tty_only(self):
        r = office.dismiss_agent({"id": "codex-500", "step": "close"}, **self.kw)
        self.assertEqual(r, {"ok": True, "closed": True})
        self.assertEqual([(e["signal"], e["tty"]) for e in office.DISMISS_LOG],
                         [("HUP", "ttys005"), ("TERM", "ttys005"), ("KILL", "ttys005")])
        for e in office.DISMISS_LOG:
            self.assertEqual(sorted(e["pids"]), [500, 501, 503])        # not 502 (login), not ttys006
        name, argv = office.DRY_LOG[-1]
        self.assertEqual(name, "close")
        self.assertEqual(argv[:2], ["osascript", "-e"])
        self.assertEqual(argv[2], office.CLOSE_SCRIPT)
        self.assertEqual(argv[3:], ["/dev/ttys005"])
        self.assertNotIn("ttys005", argv[2])

    def test_never_signals_pid_one_self_or_parent(self):
        me, parent = os.getpid(), os.getppid()
        ps = PS_DISMISS + "    1     0 ttys005    0.0       05:00 /sbin/launchd\n%5d %5d ttys005    0.0 05:00 /bin/zsh\n%5d     1 ttys005    0.0 05:00 /bin/zsh\n" % (me, 1, parent)
        pids = office.signal_targets("ttys005", ps)
        for bad in (1, me, parent, 502):
            self.assertNotIn(bad, pids)
        self.assertIn(500, pids)

    def test_dry_run_sends_no_signal(self):
        calls = []
        real = os.kill
        os.kill = lambda *a: calls.append(a)
        try:
            office.dismiss_agent({"id": "codex-500", "step": "close"}, **self.kw)
        finally:
            os.kill = real
        self.assertEqual(calls, [])

    def test_live_mode_signals_in_order_with_a_fake_kill(self):
        # A fake os.kill and sleep: the real send path with nothing real behind it.
        sent, naps = [], []
        real_kill, real_dry = os.kill, os.environ.get("GOLDWARE_OFFICE_DRY_RUN")
        real_osa = office.osa
        os.environ["GOLDWARE_OFFICE_DRY_RUN"] = "0"
        os.kill = lambda pid, sig: sent.append((pid, sig))
        office.osa = lambda name, script, *a, **k: ("closed\n", "", 0)
        try:
            agent = office.find_agent("codex-500", **self.kw)
            self.assertTrue(office.dismiss(agent, sleep=naps.append, **self.kw))
        finally:
            os.kill = real_kill
            office.osa = real_osa
            os.environ["GOLDWARE_OFFICE_DRY_RUN"] = real_dry or "1"
        import signal
        self.assertEqual([s for _, s in sent[::3]], [signal.SIGHUP, signal.SIGTERM, signal.SIGKILL])
        self.assertEqual({p for p, _ in sent}, {500, 501, 503})
        self.assertEqual(naps, [office.DISMISS_GAP] * 3)


class Boss(unittest.TestCase):
    """The boss at the front desk: a Hermes chat in data/boss, started or told only when asked."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.data = os.path.join(self.tmp, "data")
        del office.DRY_LOG[:]
        office._SENT.clear()
        office_launch.reset_throttle()
        office_boss.reset_starting()
        self.home = os.path.join(self.tmp, "hermes")
        self.kw = dict(now=NOW, ps_text=PS_MIXED, chome="/nonexistent", ollama_url="off",
                       cwd_fn=lambda pid: "/work/shop", gateway=False)
        self._avail = office_launch.available
        office_launch.available = lambda cmd: True       # no real hermes needed

    def tearDown(self):
        office_launch.available = self._avail
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_a_hermes_chat_in_data_boss_is_the_boss_and_takes_no_cast_name(self):
        make_hermes(self.home, 200, cwd=os.path.join(self.data, "boss"))
        s = office.snapshot(home=self.home, data_root=self.data, **self.kw)
        boss = [a for a in s["agents"] if a.get("boss")]
        self.assertEqual(len(boss), 1)
        self.assertEqual(boss[0]["name"], "Boss")
        self.assertEqual(sorted(a["name"] for a in s["agents"] if not a.get("boss")), ["Bolt", "Mocha"])

    def test_ask_with_no_boss_starts_one_in_its_folder_with_the_brief(self):
        r = office_boss.ask({"text": "Start two agents on the site; say \"hi\" $(x)"}, self.data, REPO,
                            home=os.path.join(self.tmp, "none"), **self.kw)
        self.assertTrue(r["started"])
        name, argv = office.DRY_LOG[-1]
        self.assertEqual(name, "new")
        cmd = argv[-1]
        boss_dir = os.path.join(self.data, "boss")
        self.assertTrue(cmd.startswith("cd %s && hermes chat -q '" % boss_dir), cmd)
        self.assertIn("$(x)", cmd)                         # quoted as data, never run
        self.assertNotIn("\n", cmd)
        brief = open(os.path.join(boss_dir, "AGENTS.md")).read()
        self.assertIn("goldware-office", brief)
        self.assertIn(os.path.join(REPO, "scripts", "office"), brief)

    def test_a_second_ask_while_the_boss_sits_down_does_not_open_another(self):
        none = os.path.join(self.tmp, "none")
        office_boss.ask({"text": "first"}, self.data, REPO, home=none, **self.kw)
        office_launch.reset_throttle()
        with self.assertRaises(office.OfficeError) as cm:
            office_boss.ask({"text": "second"}, self.data, REPO, home=none, **self.kw)
        self.assertEqual(cm.exception.status, 409)
        self.assertEqual([n for n, _ in office.DRY_LOG], ["new"])

    def test_ask_with_a_boss_at_its_desk_types_to_it(self):
        make_hermes(self.home, 200, cwd=os.path.join(self.data, "boss"))
        r = office_boss.ask({"text": "How is everyone doing?"}, self.data, REPO, home=self.home, **self.kw)
        self.assertTrue(r["sent"])
        name, argv = office.DRY_LOG[-1]
        self.assertEqual((name, argv[3], argv[4]), ("send", "/dev/ttys001", "/queue How is everyone doing?"))

    def test_report_names_the_agent_and_goes_to_the_boss(self):
        make_hermes(self.home, 200, cwd=os.path.join(self.data, "boss"))
        r = office_boss.report({"id": "claude-300", "text": "Form done; tests pass."}, self.data, REPO, home=self.home, **self.kw)
        self.assertTrue(r["sent"])
        line = office.DRY_LOG[-1][1][4]
        self.assertTrue(line.startswith("/queue Report from "), line)
        self.assertIn("claude-300", line)
        self.assertIn("Form done; tests pass.", line)
        # by tty too (what `goldware-office report` sends from inside an agent)
        office._SENT.clear()
        office_boss.report({"tty": "/dev/ttys003"}, self.data, REPO, home=self.home, **self.kw)
        self.assertIn("codex-310", office.DRY_LOG[-1][1][4])

    def test_report_refuses_unknown_agents_and_the_boss_itself(self):
        make_hermes(self.home, 200, cwd=os.path.join(self.data, "boss"))
        with self.assertRaises(office.OfficeError) as cm:
            office_boss.report({"id": "nobody"}, self.data, REPO, home=self.home, **self.kw)
        self.assertEqual(cm.exception.status, 404)
        with self.assertRaises(office.OfficeError) as cm:
            office_boss.report({"id": "sess-1"}, self.data, REPO, home=self.home, **self.kw)
        self.assertEqual(cm.exception.status, 409)

    def test_empty_ask_is_refused(self):
        with self.assertRaises(office.OfficeError):
            office_boss.ask({"text": "   "}, self.data, REPO, home=self.home, **self.kw)
        self.assertEqual(office.DRY_LOG, [])


def add_session(con, sid, parent, title, started, ended=None):
    con.execute("INSERT INTO sessions VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)",
                (sid, "subagent", title, "m", None, 1, 0, 0, 0, started, "/home/a/x", parent, ended))


def add_msg(con, sid, role, content=None, at=NOW, tool_name=None, tool_calls=None):
    con.execute("INSERT INTO messages (session_id, role, tool_name, tool_calls, content, timestamp, active) VALUES (?,?,?,?,?,?,1)",
                (sid, role, tool_name, tool_calls, content, at))


class GroupChat(unittest.TestCase):
    """The Chat view as a group chat: helpers and agents the boss typed to answer as themselves."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.home = os.path.join(self.tmp, "hermes")

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def db(self):
        con = sqlite3.connect(os.path.join(self.home, "state.db"))
        self.addCleanup(con.close)
        return con

    def test_office_agents_talk_in_the_boss_chat(self):
        call = json.dumps([{"function": {"name": "terminal", "arguments": json.dumps(
            {"command": 'AO="python3 x/office"; $AO send a1 "Fix the \\"form\\" now"; goldware-office new --type sonnet --topic home \'Write copy\''})}}])
        self.assertEqual(office.office_sends(call), [{"to": "a1", "text": 'Fix the "form" now'}, {"to": None, "text": "Write copy"}])
        self.assertEqual(office.office_sends(call[:60]), [])
        self.assertEqual(office.office_sends(json.dumps([{"function": {"name": "web_search", "arguments": "{}"}}])), [])
        os.makedirs(self.home)
        con = self.db()
        con.executescript("""
            CREATE TABLE messages (id INTEGER PRIMARY KEY, session_id TEXT, role TEXT, content TEXT, timestamp REAL, active INT DEFAULT 1);
            CREATE TABLE session_turn_leases (conversation_id TEXT, expires_at REAL);
        """)
        for sid, role, text, at in (("a1", "user", "/queue Fix the form now", NOW - 99), ("a1", "assistant", "Looking.", NOW - 98),
                                    ("a1", "assistant", "Form fixed.", NOW - 90), ("a1", "user", "Something else", NOW - 50),
                                    ("b2", "user", "Check it", NOW - 9), ("b2", "assistant", "", NOW - 8)):
            con.execute("INSERT INTO messages (session_id, role, content, timestamp) VALUES (?,?,?,?)", (sid, role, text, at))
        con.execute("INSERT INTO session_turn_leases VALUES ('b2', ?)", (NOW + 60,))
        con.commit()
        rows = [{"role": "user", "text": "Get it done", "at": NOW - 200},
                {"role": "assistant", "text": "", "tools": ["terminal"], "at": NOW - 100,
                 "sends": [{"to": "a1", "text": "Fix the form"}, {"to": "b2", "text": "Check it"}]},
                {"role": "user", "text": 'Report from Gengar (id c3, "Lane x", in /home/a/x): All done.\n\nNotes.', "at": NOW - 20}]
        out = office.office_rows(rows, home=self.home, now=NOW, board_names={"a1": "Bolt"})
        self.assertEqual([r["role"] for r in out], ["user", "assistant", "send", "send", "agent", "agent", "agent"])
        self.assertEqual([(r["to"], r["name"]) for r in out if r["role"] == "send"], [("a1", "Bolt"), ("b2", None)])
        self.assertEqual([(r["from"], r["name"]) for r in out if r["role"] == "agent"], [("a1", "Bolt"), ("c3", "Gengar"), ("b2", None)])
        self.assertEqual(out[4]["text"], "Form fixed.")
        self.assertEqual((out[5]["text"], out[5]["report"]), ("All done.\n\nNotes.", True))
        self.assertEqual((out[6]["working"], out[6]["text"]), (True, ""))
        self.assertNotIn("sends", out[1])
        turns = office.chat_turns(out)
        self.assertEqual([t["kind"] for t in turns], ["you", "did", "send", "send", "agent", "agent", "agent"])
        self.assertNotIn("at", turns[2])
        # An agent that reported back after the send is not also quoted from its own chat.
        rows.append({"role": "user", "at": NOW - 10, "text": 'Report from Bolt (id a1, "t", in /home/a/x): Reported. '
                     "Read its chat with `goldware-office chat a1` if you need more, decide the next step, act on it."})
        out = office.office_rows(rows, home=self.home, now=NOW, board_names={})
        self.assertEqual([r["text"] for r in out if r.get("from") == "a1"], ["Reported."])
        self.assertEqual([r["name"] for r in out if r["role"] == "send" and r["to"] == "a1"], ["Bolt"])

    def helper_fixture(self):
        make_hermes(self.home, 200, sid="s1")
        con = self.db()
        add_session(con, "q1", "s1", "Subagent: Quiet", NOW - 900)
        add_msg(con, "q1", "tool", tool_name="read_file", at=NOW - 800)
        add_session(con, "d1", "s1", "Done already", NOW - 90, NOW - 20)
        add_msg(con, "d1", "user", "Fix the shelf", NOW - 89)
        add_msg(con, "d1", "assistant", '{"summary":"Shelf **fixed**."}', NOW - 21)
        add_session(con, "c1", "s1", "Subagent: Check   one fact", NOW - 30)
        add_msg(con, "c1", "user", "Find   sources", NOW - 29)
        add_msg(con, "c1", "assistant", tool_calls=json.dumps([{"function": {"name": "web_extract", "arguments": "{}"}}]), at=NOW - 15)
        add_session(con, "deep", "c1", "Grandchild", NOW - 10)
        con.commit()

    def test_helpers_are_numbered_in_start_order_and_answer_as_themselves(self):
        self.helper_fixture()
        rows = office.hermes_helper_rows("s1", now=NOW, home=self.home)
        self.assertEqual([(r["role"], r["helper"], r["n"]) for r in rows],
                         [("handoff", "q1", 1), ("helper", "q1", 1), ("handoff", "d1", 2), ("helper", "d1", 2),
                          ("handoff", "c1", 3), ("helper", "c1", 3)])
        self.assertEqual((rows[3]["text"], rows[3]["working"]), ("Shelf **fixed**.", False))
        self.assertEqual(rows[1]["text"], "Finished without a written answer.")
        self.assertEqual((rows[5]["working"], rows[5]["activity"], rows[5]["tool"]), (True, "browsing", "web_extract"))
        self.assertEqual((rows[4]["text"], rows[4]["title"]), ("Find   sources", "Check one fact"))
        self.assertEqual(office.hermes_helper_rows("s1", since=NOW, now=NOW, home=self.home), [])

    def test_helpers_join_the_chat_in_time_order(self):
        own = [{"role": "user", "text": "Split it up", "at": 1},
               {"role": "assistant", "text": "", "tools": ["delegate_task", "terminal"], "at": 2},
               {"role": "assistant", "text": "Both are back.", "tools": [], "at": 9}]
        helpers = [{"role": "handoff", "helper": "h1", "n": 1, "title": "Copy", "text": "Write copy", "at": 3},
                   {"role": "helper", "helper": "h1", "n": 1, "title": "Copy", "text": "Copy done", "working": False, "at": 8}]
        turns = office.chat_turns(office.merge_helper_rows(own, helpers))
        self.assertEqual([t["kind"] for t in turns], ["you", "did", "handoff", "helper", "said"])
        self.assertEqual(turns[1]["text"], "Ran 1 command")
        self.assertEqual([turns[3][k] for k in ("helper", "n", "title", "working")], ["h1", 1, "Copy", False])
        self.assertNotIn("at", turns[3])
        self.assertEqual(office.merge_helper_rows(own, []), own)

    def test_the_hermes_chat_view_carries_the_group_chat(self):
        self.helper_fixture()
        con = self.db()
        add_msg(con, "s1", "user", "Split it up", NOW - 100)
        add_msg(con, "s1", "assistant", "Both are back.", NOW - 5)
        con.commit()
        turns = office.chat_view({"kind": "hermes", "id": "s1"}, home=self.home)
        kinds = [t["kind"] for t in turns]
        self.assertEqual(kinds.count("handoff"), kinds.count("helper"))
        self.assertIn("handoff", kinds)
        self.assertEqual(kinds[-1], "said")

    def test_helper_answers_read_as_messages(self):
        self.assertEqual(office.helper_answer('{"summary":"Done.","files":["a"]}'), "Done.")
        self.assertEqual(office.helper_answer('{"clean":"/home/a/a.mp4","caption":"Hi","n":[1]}'), "- clean: /home/a/a.mp4\n- caption: Hi")
        self.assertEqual(office.helper_answer('{"summary":"Line one\\nand two'), "Line one\nand two\u2026")
        self.assertEqual(office.helper_answer(" Plain answer "), "Plain answer")


class GroupChatPage(unittest.TestCase):
    """The page has no Node in make test, so its source is checked here; tests/office_chat_cdp.mjs drives it
    in headless Chrome against a fixture."""

    @classmethod
    def setUpClass(cls):
        with open(os.path.join(REPO, "dashboard", "office.js"), encoding="utf-8") as f:
            cls.js = f.read()
        with open(os.path.join(REPO, "dashboard", "office.css"), encoding="utf-8") as f:
            cls.css = f.read()

    def test_the_chat_view_is_a_group_chat(self):
        for name in ("chatFace", "avatarSpan", "paintChatAvatars", "typingDots", "chatHtml"):
            self.assertIn("function %s(" % name if name != "typingDots" else "const typingDots", self.js)
        for kind in ("handoff", "helper", "send", "agent"):
            self.assertIn("t.kind === '%s'" % kind, self.js)
        # A helper is a blob in the colour the floor gives it.
        self.assertIn("{ color: assign(t.helper), blob: true }", self.js)
        # Same messages still repaint the pictures.
        self.assertIn("if (html === lastChat) { paintChatAvatars(box, faces); return; }", self.js)
        self.assertIn("clamp.classList.toggle('open')", self.js)

    def test_the_chat_styles_exist_and_do_not_reuse_the_console_header_class(self):
        for sel in (".oc-row", ".oc-av", ".oc-av.blob", ".oc-from", ".oc-at", ".oc-hand", ".oc-clamp", ".oc-typing"):
            self.assertIn("\n" + sel + " ", self.css, sel)
        self.assertNotIn("oc-who", self.js[self.js.index("function chatHtml("):self.js.index("function renderChat(")])
        self.assertNotIn("\n.oc-who-", self.css[self.css.index(".oc-row {"):])

    def test_browser_script_present(self):
        self.assertTrue(os.path.isfile(os.path.join(REPO, "tests", "office_chat_cdp.mjs")))


class PageFunctions(unittest.TestCase):
    """The pure functions of the page, run in a sandbox by tests/office_ui.mjs when Node is installed."""

    def test_pure_page_functions(self):
        node = shutil.which("node")
        if not node:
            self.skipTest("Node is not installed")
        r = subprocess.run([node, os.path.join(REPO, "tests", "office_ui.mjs")], capture_output=True, text=True, timeout=60)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("Office task board cards", r.stdout)
        self.assertIn("Office parked whiteboards", r.stdout)


class TaskBoardPage(unittest.TestCase):
    """A zoomed whiteboard is a task board; tests/office_chat_cdp.mjs drives it in headless Chrome."""

    @classmethod
    def setUpClass(cls):
        with open(os.path.join(REPO, "dashboard", "office.js"), encoding="utf-8") as f:
            cls.js = f.read()
        with open(os.path.join(REPO, "dashboard", "office.css"), encoding="utf-8") as f:
            cls.css = f.read()

    def test_the_board_has_its_parts(self):
        for name in ("renderTableBoard(force)", "taskBits(t, drop)", "taskFlags(t)", "taskLane(t)", "taskMatches(t, q, filter, shown)",
                     "paintWbzAvatars()", "applyWbzFilter()", "finishTask(id, el)"):
            self.assertIn("function " + name, self.js)
        for frag in ('class="tb-lanes"', 'data-wact="give"', 'data-wact="undo"', 'data-wact="reopen"', "wbzEl.addEventListener('drop'",
                     'class="tb-team"', 'placeholder="Search tasks', 'data-wact="details"', 'data-view="list"'):
            self.assertIn(frag, self.js)
        # The same picture the chat uses, from the cast.
        self.assertIn("cast.url(a.name)", self.js[self.js.index("function paintWbzAvatars"):self.js.index("function applyWbzFilter")])

    def test_slash_and_n_and_escape(self):
        self.assertIn("e.key === '/' ? '.tb-search input'", self.js)
        self.assertIn("e.target.matches('.tb-search input') && e.target.value", self.js)

    def test_up_and_down_scroll_the_console_and_left_right_still_switch_agents(self):
        self.assertIn("const emptyConsoleBox = el =>", self.js)
        self.assertIn("(e.key === 'ArrowUp' || e.key === 'ArrowDown') && consoleFor", self.js)
        self.assertIn("emptyConsoleBox(e.target) ||", self.js)
        self.assertIn(".oc-chat, .oc-screen, .oc-plan", self.js)
        self.assertIn("e.key !== 'ArrowLeft' && e.key !== 'ArrowRight'", self.js)

    def test_board_styles_use_the_arcade_skin(self):
        for sel in (".tb-board", ".tb-lane", ".tb-card", ".tb-flag.you", ".tb-team", ".tb-mate.drop-on", ".tb-add"):
            self.assertIn("#tab-office " + sel + " ", self.css, sel)
        board = self.css[self.css.index("Whiteboard task board"):]
        self.assertIn("var(--px-night)", board)
        self.assertNotIn("--pk-", board)


class QuestionPage(unittest.TestCase):
    """The chat shows an agent's multiple-choice question and answers it; the app opens an agent in the Office.
    tests/office_chat_cdp.mjs drives the page in headless Chrome."""

    @classmethod
    def setUpClass(cls):
        def read(*parts):
            with open(os.path.join(REPO, *parts), encoding="utf-8") as f:
                return f.read()
        cls.js, cls.css = read("dashboard", "office.js"), read("dashboard", "office.css")
        src = os.path.join("app", "Sources", "GoldWareOS")
        cls.hud, cls.dash, cls.delegate, cls.main = (read(src, n) for n in ("HUD.swift", "DashboardWindow.swift", "AppDelegate.swift", "main.swift"))

    def test_the_chat_draws_and_answers_questions(self):
        for frag in ("function askHtml(t, a, live)", "function answeredHtml(t)", "function askClick(b)", "async function sendAnswer(t, b)",
                     "'/api/office/answer'", 'class="oc-choices"', "t.kind === 'ask'", "t.kind === 'answered'", "const askPicks = new Map()"):
            self.assertIn(frag, self.js)
        # Only the agent's open question, still the newest turn, on a Hermes chat showing clarify, has buttons.
        self.assertIn("a.kind === 'hermes' && a.tool === 'clarify' && i === turns.length - 1", self.js)
        # A half-typed Something else answer is not wiped by a repaint.
        self.assertIn("document.activeElement.classList.contains('oc-other') && box.contains(document.activeElement) && lastChat) return;", self.js)

    def test_the_app_can_open_an_agent_through_the_page(self):
        self.assertIn("window.goldwareOffice = {", self.js)
        self.assertIn("if (openWanted && agentById(openWanted)) window.goldwareOffice.open(openWanted);", self.js)

    def test_question_styles_use_the_arcade_skin(self):
        css = self.css[self.css.index("Multiple-choice questions in the console chat"):]
        for sel in (".oc-choices", ".oc-choice", ".oc-choice.on", ".oc-choice.other", ".oc-other", ".oc-ask-send"):
            self.assertIn(".office-console " + sel + " ", css, sel)
        self.assertIn("var(--px-", css)

    def test_a_click_on_an_agent_beside_the_orb_opens_the_office_not_the_terminal(self):
        self.assertIn("var onOpenAgent: (AgentPeek) -> Void", self.hud)
        self.assertIn("WorkData.focus(tty:", self.hud[self.hud.index("var onOpenAgent"):self.hud.index("private var activeAction")])
        self.assertIn("pillView.onAgentClick = { [weak self] agent in self?.onOpenAgent(agent) }", self.hud)
        self.assertIn("hud.onOpenAgent = { [weak self] agent in self?.dashboard.openAgent(id: agent.id) }", self.delegate)
        self.assertIn("func openAgent(id: String)", self.dash)
        self.assertIn("if loaded { web.evaluateJavaScript(js) } else { pendingScript = js }", self.dash)
        self.assertIn("if let js = pendingScript { pendingScript = nil; webView.evaluateJavaScript(js) }", self.dash)
        self.assertIn("window.goldwareOffice", self.dash)
        self.assertIn("hud.pillViewForTests.onAgentClick", self.main)


class ParkedBoardsPage(unittest.TestCase):
    """Whiteboards nobody is working on park on the left and roll to the table when an agent sits down.
    The pure parts run in tests/office_ui.mjs; tests/office_chat_cdp.mjs watches the board roll in headless Chrome."""

    @classmethod
    def setUpClass(cls):
        with open(os.path.join(REPO, "dashboard", "office.js"), encoding="utf-8") as f:
            cls.js = f.read()

    def test_the_room_makes_space_for_parked_boards(self):
        for frag in ("function parkedKeys(taskList, tableKeys, nameOf)", "const parkCols = (n, top, bottom)", "function roomSize(sizes, cols, park = 0)",
                     "function chooseLayout(sizes, aw, ah, park = 0)", "const PARK_W = WB + 6, PARK_H = WBH + 26, PARK_TOP = 72;",
                     "ox += pw;", "parked: true", "geo = chooseLayout(sizes, aw, ah, parked.length ? 1 : 0);"):
            self.assertIn(frag, self.js)
        # The layout is redone when the parking or what is parked changes.
        self.assertIn("geo.sig + ':' + parked.length !== seatCount(agents)", self.js)
        self.assertIn("(geo.park || 0) + ':' + parkedKeys(", self.js)

    def test_boards_roll_over_time_and_snap_on_resize(self):
        for frag in ("function rollBoards()", "snap = still || wbRoomKey !== room", "Math.exp(-Math.min(400, t - (wbRollAt || t)) / 220)",
                     "const wbAt = tb =>", "const wbStyle = tb =>", "tables.forEach(tb => whiteboard(wbAt(tb)));"):
            self.assertIn(frag, self.js)
        self.assertIn("class=\"office-hit wb${tb.parked ? ' parked' : ''}\"", self.js)
        self.assertIn("Parked: no agent is working in this group", self.js)


class GoldwareOfficeCli(unittest.TestCase):
    def test_help_and_unknown_command(self):
        cli = os.path.join(REPO, "scripts", "office")
        r = subprocess.run([sys.executable, cli, "--help"], capture_output=True, text=True, timeout=10)
        self.assertEqual(r.returncode, 0)
        for word in ("agents", "send", "new", "dismiss", "report", "boss"):
            self.assertIn(word, r.stdout)
        r = subprocess.run([sys.executable, cli, "fly"], capture_output=True, text=True, timeout=10)
        self.assertNotEqual(r.returncode, 0)


class OfficeHttp(unittest.TestCase):
    """The real server on an empty fixture: JSON everywhere, and POSTs only from the dashboard itself."""

    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.mkdtemp()
        root = cls.root = os.path.join(cls.tmp, "root")
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
        for path in ("/api/office/send", "/api/office/focus", "/api/office/answer", "/api/office/board", "/api/office/dismiss",
                     "/api/office/boss", "/api/office/report"):
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

    def test_answer_endpoint_is_guarded_and_says_when_nobody_is_there(self):
        code, _ = self.call("/api/office/answer", {"id": "sess-1", "answers": []})
        self.assertEqual(code, 403)
        code, j = self.call("/api/office/answer", {"id": "sess-1", "answers": []}, {"Origin": self.base})
        self.assertEqual((code, j["error"]), (404, "That agent is not at a terminal any more."))
        code, _ = self.call("/api/office/answer", b"id=1", {"Origin": self.base}, ctype="text/plain")
        self.assertEqual(code, 415)

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
        code, j = self.call("/api/office/dismiss", {"id": "claude-1", "step": "check"}, origin)
        self.assertEqual(code, 404)
        code, j = self.call("/api/office/dismiss", {"id": "claude-1", "step": "bogus"}, origin)
        self.assertEqual(code, 404)           # the agent is looked up first
        code, j = self.call("/api/office/board", {"action": "add", "title": "Hello"}, origin)
        self.assertEqual((code, j["board"]["tasks"][0]["title"]), (200, "Hello"))
        code, j = self.call("/api/office/board", {"action": "bogus"}, origin)
        self.assertEqual(code, 422)

    def test_new_and_settings_posts_need_same_origin(self):
        for path in ("/api/office/new", "/api/office/settings"):
            self.assertEqual(self.call(path, {"type": "echo"})[0], 403, path)
            self.assertEqual(self.call(path, {"type": "echo"}, {"Origin": "http://evil.example"})[0], 403, path)
            self.assertEqual(self.call(path, {"type": "echo"}, {"Origin": self.base, "Sec-Fetch-Site": "cross-site"})[0], 403, path)
            self.assertEqual(self.call(path, b"type=x", {"Origin": self.base}, ctype="text/plain")[0], 415, path)

    def test_new_over_http_uses_ids_only(self):
        origin = {"Origin": self.base}
        code, j = self.call("/api/office/new", {"type": "nope", "topic": "home"}, origin)
        self.assertEqual(code, 422)
        code, j = self.call("/api/office/new", {"type": "hermes", "topic": "nope"}, origin)
        self.assertEqual(code, 422)
        code, j = self.call("/api/office/settings")
        self.assertEqual(code, 200)
        self.assertEqual([t["id"] for t in j["topics"]], ["home"])
        self.assertEqual([p["id"] for p in j["presets"]], ["hermes", "claude-code", "codex"])

    def test_settings_save_over_http(self):
        origin = {"Origin": self.base}
        code, j = self.call("/api/office/settings", {"topics": [{"label": "Tmp", "dir": "/tmp"}]}, origin)
        self.assertEqual(code, 200)
        self.assertEqual(j["topics"][0]["id"], "tmp")
        code, j = self.call("/api/office/settings", {"topics": [{"label": "Bad", "dir": "relative"}]}, origin)
        self.assertEqual(code, 422)
        code, j = self.call("/api/office/settings")
        self.assertEqual([t["id"] for t in j["topics"]], ["tmp"])
        cfg = self.call("/api/config")[1]["config"]
        self.assertEqual(cfg["office"]["topics"], [{"id": "tmp", "label": "Tmp", "dir": "/tmp"}])
        self.assertIn("presets", cfg["office"])
        self.assertEqual(cfg["assistantName"], "GoldWare")
        os.remove(os.path.join(self.root, "goldware.json"))            # leave the fixture as it was

    def test_custom_css_is_served_when_present_and_404_when_not(self):
        code, _ = self.call("/custom/office.css")
        self.assertEqual(code, 404)
        os.makedirs(os.path.join(self.root, "custom"))
        with open(os.path.join(self.root, "custom", "office.css"), "w") as f:
            f.write(".oh-brand { color: red; }\n")
        r = urllib.request.urlopen(self.base + "/custom/office.css", timeout=5)
        self.assertEqual(r.status, 200)
        self.assertIn("text/css", r.headers["Content-Type"])
        self.assertIn("color: red", r.read().decode())
        # nothing else under /custom/ is served, and no way out of it
        with open(os.path.join(self.root, "custom", "secret.txt"), "w") as f:
            f.write("nope")
        for path in ("/custom/secret.txt", "/custom/", "/custom/../goldware.default.json", "/custom/%2e%2e/goldware.default.json",
                     "/custom/office.css/../../goldware.default.json", "/custom/..%2fgoldware.default.json", "/custom/office.css%00.txt"):
            code, body = self.call(path)
            self.assertEqual(code, 404, path)
            self.assertNotIn(b"assistantName", body if isinstance(body, bytes) else json.dumps(body).encode())

    def test_custom_cast_is_served_when_present_and_404_when_not(self):
        self.assertEqual(self.call("/custom/office-cast.js")[0], 404)
        os.makedirs(os.path.join(self.root, "custom"), exist_ok=True)
        with open(os.path.join(self.root, "custom", "office-cast.js"), "w") as f:
            f.write("OfficeCast.customize({ Bolt: { color: '#ff0000' } });")
        r = urllib.request.urlopen(self.base + "/custom/office-cast.js", timeout=5)
        self.assertIn("javascript", r.headers["Content-Type"])
        self.assertIn(b"customize", r.read())
        shutil.rmtree(os.path.join(self.root, "custom"))   # the tests share one root

    def test_custom_css_symlink_out_of_custom_is_refused(self):
        outside = os.path.join(self.tmp, "outside.css")
        with open(outside, "w") as f:
            f.write("a { color: blue }")
        os.makedirs(os.path.join(self.root, "custom"), exist_ok=True)
        link = os.path.join(self.root, "custom", "office.css")
        if os.path.lexists(link):
            os.unlink(link)
        os.symlink(outside, link)
        self.assertEqual(self.call("/custom/office.css")[0], 404)

    def test_wrong_host_header_is_refused(self):
        r = urllib.request.Request(self.base + "/api/office/agents", headers={"Host": "evil.example"})
        with self.assertRaises(urllib.error.HTTPError) as cm:
            urllib.request.urlopen(r, timeout=5)
        self.assertEqual(cm.exception.code, 403)


if __name__ == "__main__":
    unittest.main()
