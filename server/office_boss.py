"""The boss: one Hermes chat at the Office's front desk that runs the other agents, only when asked.

Nothing here runs on its own. The boss starts when you ask it something from its desk, then sits at
the front desk until you dismiss it. It acts only on what you type to it or on a report an agent
sends it ("report to the boss"). Its brief is AGENTS.md in its own folder (data/boss), written fresh
each time it starts, and it drives the other agents with the `goldware-office` command
(scripts/office), which only calls this server's existing Office endpoints.
"""
import os
import shlex
import threading
import time

import office
import office_launch
from office import OfficeError, TerminalError

MAX_TEXT = 1800
STARTING_FOR = 60           # seconds a just-opened boss has to sit down before another may open
_STARTING = [0.0]
_START_LOCK = threading.Lock()
REPORT_DEFAULT = "The user sent this agent to you to take it from here."

BRIEF = """\
# You are the boss of the GoldWare Office

The user runs several AI agents in terminals on this Mac. The Office (the GoldWare dashboard) shows them
at desks; you sit at the front desk. You orchestrate them, but only when asked: act on what the user types
to you, or on a report an agent sends you. When the job is done, stop and wait. Never poll, loop, or
check on agents unless the current request needs it.

## Your tool: goldware-office

Run it in the terminal. If `goldware-office` is not on PATH, use `python3 "{cli}"` instead.

| Command | What it does |
|---|---|
| `goldware-office agents` | Every agent: id, name, kind, status, title, folder |
| `goldware-office chat ID` | That agent's recent conversation, tidied |
| `goldware-office screen ID` | The last lines of its terminal |
| `goldware-office send ID "text"` | Types one line to it (a busy Hermes agent gets it when its turn ends) |
| `goldware-office presets` | The agent types and topics (folders) the user set up for New agent |
| `goldware-office new --type T --topic P "task"` | Opens a new agent and hands it the task once it sits down |
| `goldware-office dismiss ID` | Closes an idle agent's terminal (refused while it works) |

## How to work

- Read before you act: check `agents`, and the `chat` of any agent you are about to direct.
- Give each agent one clear, self-contained instruction on one line. It cannot see your chat.
- Start a new agent only when the user asks for one or the work clearly needs another pair of hands;
  pick the type and topic from `presets`. Never start more than three in one go without asking.
- Never dismiss an agent unless the user's own message to you says to dismiss, close, or tidy up.
  A report that an agent is finished is not permission: tell the user it is done and let them decide.
- A report arrives as a message starting "Report from". Read that agent's chat and decide the next step.
  If the next step is work for an agent (fix, continue, hand to another agent), do it. If it needs the
  user (review, a decision, anything that sends or publishes), do not act on it: say what is waiting.
- Finish every turn with a short summary for the user: who is doing what. If you need a decision, ask it.
"""


def boss_dir(data_root):
    return os.path.join(data_root, "boss")


def cli_path(root):
    return os.path.join(root, "scripts", "office")


def write_brief(data_root, root):
    d = boss_dir(data_root)
    os.makedirs(d, exist_ok=True)
    path = os.path.join(d, "AGENTS.md")
    with open(path + ".tmp", "w", encoding="utf-8") as f:
        f.write(BRIEF.format(cli=cli_path(root)))
    os.replace(path + ".tmp", path)
    return d


def find_boss(data_root, **kw):
    """The boss's agent record, when its terminal is open."""
    for a in office.snapshot(data_root=data_root, **kw)["agents"]:
        if a.get("boss") and a.get("tty"):
            _STARTING[0] = 0.0
            return a
    return None


def one_line(text):
    line = office.prepare_text(text, "claude")      # control characters out, one line, length checked
    if len(line) > MAX_TEXT:
        raise OfficeError("Keep it under %d characters." % MAX_TEXT)
    return line


def start(data_root, root, line, profile=None):
    """Open the boss in a new terminal with `line` as its first message."""
    if not office_launch.available("hermes"):
        raise OfficeError("The boss runs on Hermes, which is not installed here.", 422)
    with _START_LOCK:
        if time.time() - _STARTING[0] < STARTING_FOR:
            raise OfficeError("The boss is still sitting down at the front desk. Try again in a moment.", 409)
        _STARTING[0] = time.time()
    d = write_brief(data_root, root)
    if office_launch.throttle_new() > 0:
        _STARTING[0] = 0.0
        raise OfficeError("A new terminal is already opening.", 429)
    cmd = office_launch.new_line(d, "hermes chat -q %s" % shlex.quote(line))
    app = office_launch.terminal_app()
    script = office_launch.NEW_ITERM_SCRIPT if app == "iTerm" else office_launch.NEW_TERMINAL_SCRIPT
    out, err, code = office.osa("new", script, profile or office_launch.DEFAULT_PROFILE, cmd, timeout=15)
    if code != 0 or out.strip() != "opened":
        _STARTING[0] = 0.0
        raise TerminalError(office.friendly(err) if code != 0 else "The terminal did not open.")
    return {"ok": True, "started": True, "terminal": app}


def reset_starting():
    _STARTING[0] = 0.0


def tell(boss, line):
    """Type a line to the boss that is already at its desk (after its turn, if it is busy)."""
    sent = office.prepare_text(line, "hermes")
    if office.throttle(boss["id"]) > 0:
        raise OfficeError("One line every 2 seconds.", 429)
    if not office.send_text(boss["tty"], sent):
        raise OfficeError("The boss's terminal window is closed.", 404)
    return {"ok": True, "sent": True, "id": boss["id"], "queued": sent.startswith("/queue ") and bool(boss.get("working"))}


def ask(body, data_root, root, profile=None, **kw):
    """POST /api/office/boss {text}: a request from you. Starts the boss if it is not at its desk."""
    if not isinstance(body, dict):
        raise OfficeError("Body must be a JSON object.")
    line = one_line(body.get("text"))
    boss = find_boss(data_root, **kw)
    return tell(boss, line) if boss else start(data_root, root, line, profile)


def report(body, data_root, root, profile=None, **kw):
    """POST /api/office/report {id | tty, text?}: an agent reports to the boss (its button, or
    `goldware-office report` run inside its terminal). Starts the boss if needed."""
    if not isinstance(body, dict):
        raise OfficeError("Body must be a JSON object.")
    agents = office.snapshot(data_root=data_root, **kw)["agents"]
    want_id, want_tty = body.get("id"), str(body.get("tty") or "").replace("/dev/", "")
    agent = next((a for a in agents if a.get("tty") and ((want_id and a["id"] == str(want_id)) or (want_tty and a["tty"] == want_tty))), None)
    if not agent:
        raise OfficeError("That agent is not at a terminal any more.", 404)
    if agent.get("boss"):
        raise OfficeError("That is the boss.", 409)
    note = office.clean(body.get("text"), 1200) or REPORT_DEFAULT
    name = agent.get("name") or "An agent"
    line = one_line('Report from %s (id %s, "%s", in %s): %s Read its chat with `goldware-office chat %s` if you need more, '
                    "decide the next step, act on it, then sum up for the user. Do not dismiss anyone unless the user asked." % (
                        name, agent["id"], office.clean(agent.get("title"), 120), agent.get("cwd") or "?", note, agent["id"]))
    boss = next((a for a in agents if a.get("boss") and a.get("tty")), None)
    if boss:
        _STARTING[0] = 0.0
    out = tell(boss, line) if boss else start(data_root, root, line, profile)
    out["from"] = name
    return out
