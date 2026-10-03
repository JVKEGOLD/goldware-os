"""The Office: who is working on this Mac right now, and how to talk to them.

Python 3.9 stdlib only. Detects Hermes chats, Claude Code, Codex and Ollama, reads their
terminals, and (only on an explicit request) types a line into one of them.

Safety rules, the same ones the dashboard relies on:
  * Reads never write anything. Hermes state is opened read-only.
  * Send and focus only ever act on a tty that belongs to an agent found in a fresh
    process snapshot taken for that request. The tty never comes from the browser,
    and it must look like ttysNNN before it is turned into a /dev path.
  * The text travels to osascript as an argument, never as AppleScript source, so
    nothing typed can become a script. Control characters are stripped, the length is
    capped, and one line per 2 seconds is allowed per agent.
  * GOLDWARE_OFFICE_DRY_RUN=1 builds the osascript command and records it in DRY_LOG
    without running it. Tests use only that mode.
  * Dismiss (close an agent's terminal) acts only on the tty of an agent found in a fresh
    snapshot, never signals pid 1, this server, its parent or a login process, never runs
    while the agent works, and in dry-run mode records the planned signals in DISMISS_LOG
    instead of sending them.
"""
import datetime
import json
import os
import re
import shutil
import signal
import sqlite3
import subprocess
import threading
import time
import urllib.error
import urllib.request
import uuid

YOUR_TURN_FOR = 45 * 60          # an unanswered reply turns into "asleep" after this long
SUBAGENT_FRESH = 3 * 60
SUBAGENT_IN_TOOL = 15 * 60       # a helper mid tool call stays this long without a new message
SCREEN_LINES = 60
MAX_TEXT = 2000
OSA_TIMEOUT = 4
SEND_GAP = 2.0                   # seconds between lines typed into the same agent

CLAUDE_TOOLS = {
    "typing": ["Bash", "BashOutput", "KillShell"],
    "writing": ["Edit", "MultiEdit", "Write", "NotebookEdit", "TodoWrite"],
    "reading": ["Read", "Grep", "Glob", "LS", "ToolSearch"],
    "browsing": ["WebSearch", "WebFetch"],
    "delegating": ["Task", "Agent"],
}

# Tool name -> what the character is doing at the desk.
ACTIVITIES = {
    "typing": ["terminal", "execute_code", "process_manage"],
    "writing": ["write_file", "patch", "skill_manage", "memory", "context_notes", "todo_list"],
    "reading": ["read_file", "search_files", "session_search", "skill_view", "skills_list",
                "chat_history_lookup", "tool_search", "tool_describe"],
    "browsing": ["web_search", "web_extract", "browser_exec", "browser_vault_list", "browser_vault_fill"],
    "looking": ["vision_analyze", "image_generate"],
    "delegating": ["delegate_task"],
    "asking": ["clarify"],
}

# The cast of the Office (dashboard/office-cast.js), in the order agents sit down. Past the list
# an agent is "Agent N" and is drawn as a plain blob.
NAMES = "Bolt Mocha Pixel Latte Sprout Ember Beans Frost Wisp Biscuit".split()


class TerminalError(Exception):
    """A terminal could not be reached (iTerm not allowed, hung on a dialog, ...)."""


class OfficeError(Exception):
    """A request that is wrong: shown to the user as is."""
    def __init__(self, msg, status=422):
        Exception.__init__(self, msg)
        self.status = status


# ---------- where things live ----------

def hermes_home():
    return os.path.expanduser(os.environ.get("GOLDWARE_HERMES_HOME") or os.environ.get("HERMES_HOME") or "~/.hermes")


def claude_home():
    return os.path.expanduser(os.environ.get("CLAUDE_CONFIG_DIR") or "~/.claude")


def codex_home():
    return os.path.expanduser(os.environ.get("CODEX_HOME") or "~/.codex")


def dry_run():
    return os.environ.get("GOLDWARE_OFFICE_DRY_RUN") == "1"


def forced_empty():
    return os.environ.get("GOLDWARE_OFFICE_EMPTY") == "1"


# ---------- small helpers ----------

def one_line(text, max_len):
    t = re.sub(r"\s+", " ", str(text if text is not None else "")).strip()
    return t[:max_len - 1] + "\u2026" if len(t) > max_len else t


def tool_activity(name):
    bare = re.sub(r"^mcp__", "", str(name or ""))
    for act, tools in ACTIVITIES.items():
        if bare in tools or (bare.startswith("browser") and "browser_exec" in tools):
            return act
    return "working"


def first_call(raw):
    if not raw:
        return None
    try:
        calls = json.loads(raw)
        call = calls[0] if isinstance(calls, list) and calls else None
        if isinstance(call, dict):
            return (call.get("function") or {}).get("name") or call.get("name")
        return None
    except ValueError:
        # The snapshot query truncates long arguments; the name comes first.
        m = re.search(r'"name":\s*"([^"]+)"', str(raw))
        return m.group(1) if m else None


def hermes_activity(last, working, now):
    """State of one Hermes chat from its turn lease and last message.
    last: {'role', 'tool_name', 'tool_calls', 'timestamp'} or None."""
    idle = now - float(last["timestamp"] or 0) if last else 0
    tool = None
    if last and last.get("role") == "tool":
        tool = last.get("tool_name")
    elif last and last.get("role") == "assistant":
        tool = first_call(last.get("tool_calls"))
    if working:
        if not tool:
            return "thinking"
        act = tool_activity(tool)
        return "your_turn" if act == "asking" else act
    if not last:
        return "idle"
    if last.get("role") == "assistant" and tool is None and idle < YOUR_TURN_FOR:
        return "your_turn"
    if tool and tool_activity(tool) == "asking" and idle < YOUR_TURN_FOR:
        return "your_turn"
    return "idle" if idle < YOUR_TURN_FOR else "asleep"


def waiting_on_helpers(activity, helpers):
    return "helpers" if helpers and activity in ("your_turn", "idle", "asleep") else activity


def helper_activity(last, now):
    """A helper's state, or None when it is done or went quiet."""
    if not last or last.get("timestamp") is None:
        return None
    age = now - float(last["timestamp"] or 0)
    call = first_call(last.get("tool_calls")) if last.get("role") == "assistant" else None
    if call:
        if age > SUBAGENT_IN_TOOL:
            return None
        a = tool_activity(call)
        return "thinking" if a == "asking" else a
    if last.get("role") == "assistant" or age > SUBAGENT_FRESH:
        return None
    return "thinking"


def pretty_model(model):
    m = str(model or "")
    if not m.startswith("claude-"):
        return m
    parts = m[len("claude-"):].split("-")
    version = ".".join(p for p in parts[1:] if re.fullmatch(r"\d+", p))
    return " ".join(x for x in [parts[0].capitalize(), version] if x)


def etime(text):
    days, clock = (text.split("-", 1) if "-" in text else ("0", text))
    secs = 0
    for part in clock.split(":"):
        secs = secs * 60 + int(part or 0)
    return secs + int(days) * 86400


def parse_ps(text):
    """`ps -axo pid=,ppid=,tty=,pcpu=,etime=,comm=` rows."""
    out = []
    for line in str(text).splitlines():
        f = line.strip().split(None, 5)
        if len(f) != 6 or not f[0].isdigit():
            continue
        try:
            out.append({"pid": int(f[0]), "ppid": int(f[1]), "tty": f[2], "cpu": float(f[3]),
                        "seconds": etime(f[4]), "name": os.path.basename(f[5])})
        except ValueError:
            continue
    return out


def run(cmd, timeout=6):
    try:
        return subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                              universal_newlines=True, timeout=timeout).stdout
    except Exception:
        return ""


def read_ps():
    path = os.environ.get("GOLDWARE_OFFICE_PS_FILE")
    if path:  # a fixture for tests and screenshots
        try:
            with open(path, "r", encoding="utf-8") as f:
                return f.read()
        except OSError:
            return ""
    return run(["ps", "-axo", "pid=,ppid=,tty=,pcpu=,etime=,comm="])


# ---------- Hermes state.db (read only) ----------

def sqlite_rows(db, sql, params=()):
    if not os.path.isfile(db):
        return []
    try:
        con = sqlite3.connect("file:%s?mode=ro" % db.replace("?", "%3f").replace("#", "%23"), uri=True, timeout=1.5)
        try:
            con.row_factory = sqlite3.Row
            return [dict(r) for r in con.execute(sql, params).fetchall()]
        finally:
            con.close()
    except Exception:
        return []


def _marks(n):
    return ",".join("?" * n)


def closing(text):
    """The closing statement or question of a reply: its last paragraph without markdown.
    A long last paragraph keeps its final sentences (its last question, if it asks one)."""
    paras = []
    for p in re.split(r"\n\s*\n", str(text or "").strip()):
        p = re.sub(r"\*\*|__|`", "", p)
        p = re.sub(r"(?m)^\s*(#+|>+)\s*", "", p)
        p = re.sub(r"(?m)^\s*[-\u2022*]\s+", "", p)
        p = re.sub(r"\s+", " ", p).strip()
        if p:
            paras.append(p)
    if not paras:
        return None
    para = paras[-1]
    if len(para) > 320:
        sentences = [s.strip() for s in re.split(r"(?:(?<=[.!?])|(?<=[.!?][\"')\]]))\s+", para) if s.strip()]
        q = None
        for i in range(len(sentences) - 1, -1, -1):
            if re.search(r"\?[\"')\]]*$", sentences[i]):
                q = i
                break
        picked = [sentences[q]] if q is not None else []
        if q is None:
            for s in reversed(sentences):
                if len(" ".join(picked) + s) > 300:
                    break
                picked.insert(0, s)
        para = " ".join(picked)
        if len(para) > 320:
            para = para[-320:]
    return {"text": para, "question": bool(re.search(r"\?[\"')\]]*(\s|$)", para))}


STATUSES = {"completed": "done", "in_progress": "doing", "pending": "todo", "cancelled": "dropped"}


def ask_line(text):
    """Your last message as one line: the /queue prefix and markdown stripped, capped at 220."""
    t = re.sub(r"\*\*|__|`", "", re.sub(r"^\s*/queue\s+", "", str(text or "")))
    t = one_line(t, 220)
    return t or None


def parse_todos(raw):
    try:
        data = json.loads(raw) if isinstance(raw, str) else raw
        lst = data.get("todos")
    except Exception:
        return []
    if not isinstance(lst, list):
        return []
    out = []
    for x in lst:
        if isinstance(x, dict) and str(x.get("content", "")).strip():
            out.append({"text": one_line(x["content"], 200), "status": STATUSES.get(str(x.get("status")), "todo")})
    return out[:20]


def hermes_agents(home, by_pid, now):
    try:
        with open(os.path.join(home, "runtime", "active_sessions.json"), "r", encoding="utf-8") as f:
            registry = json.load(f)
        entries = registry.get("entries") or []
    except Exception:
        return []
    live = [e for e in entries if isinstance(e, dict) and str(e.get("pid", "")).isdigit() and int(e["pid"]) in by_pid]
    ids = sorted({str(e.get("session_id")) for e in live if e.get("session_id")})
    if not ids:
        return []
    db = os.path.join(home, "state.db")
    q = _marks(len(ids))
    sessions = {r["id"]: r for r in sqlite_rows(db, """
        SELECT id, source, coalesce(title,'') AS title, coalesce(model,'') AS model,
               coalesce(billing_provider,'') AS provider, message_count, input_tokens, output_tokens,
               cache_read_tokens, started_at, cwd FROM sessions WHERE id IN (%s)""" % q, ids)}
    children = sqlite_rows(db, """
        WITH RECURSIVE tree(id, root, depth) AS (
          SELECT id, parent_session_id, 1 FROM sessions WHERE parent_session_id IN (%s) AND ended_at IS NULL
          UNION ALL
          SELECT s.id, tree.root, tree.depth + 1 FROM sessions s JOIN tree ON s.parent_session_id = tree.id
          WHERE s.ended_at IS NULL AND tree.depth < 4)
        SELECT tree.id, tree.root AS parent, s.parent_session_id AS boss, tree.depth, coalesce(s.title,'') AS title,
               coalesce(s.model,'') AS model, s.started_at, s.message_count,
               (SELECT substr(g.content, 1, 400) FROM messages g WHERE g.session_id = tree.id AND g.role = 'user' ORDER BY g.id LIMIT 1) AS goal,
               m.role, m.tool_name, substr(m.tool_calls, 1, 300) AS tool_calls, m.timestamp
        FROM tree JOIN sessions s ON s.id = tree.id
        LEFT JOIN (SELECT session_id, role, tool_name, tool_calls, timestamp,
                          row_number() OVER (PARTITION BY session_id ORDER BY id DESC) AS rn
                   FROM messages WHERE session_id IN (SELECT id FROM tree) AND active = 1) m
          ON m.session_id = tree.id AND m.rn = 1""" % q, ids)
    last = {r["session_id"]: r for r in sqlite_rows(db, """
        SELECT session_id, role, tool_name, substr(tool_calls, 1, 300) AS tool_calls, timestamp FROM (
          SELECT session_id, role, tool_name, tool_calls, timestamp,
                 row_number() OVER (PARTITION BY session_id ORDER BY id DESC) AS rn
          FROM messages WHERE session_id IN (%s) AND active = 1) WHERE rn = 1""" % q, ids)}
    leases = {r["conversation_id"] for r in sqlite_rows(
        db, "SELECT conversation_id FROM session_turn_leases WHERE expires_at > ? AND conversation_id IN (%s)" % q,
        [now] + ids)}
    replies = {r["session_id"]: closing(r["content"]) for r in sqlite_rows(db, """
        SELECT session_id, content FROM (
          SELECT session_id, substr(content, -2000) AS content,
                 row_number() OVER (PARTITION BY session_id ORDER BY id DESC) AS rn
          FROM messages WHERE session_id IN (%s) AND role = 'assistant' AND active = 1
                AND length(trim(coalesce(content, ''))) > 0) WHERE rn = 1""" % q, ids)}
    asks = {r["session_id"]: ask_line(r["content"]) for r in sqlite_rows(db, """
        SELECT session_id, content FROM (
          SELECT session_id, substr(content, 1, 600) AS content,
                 row_number() OVER (PARTITION BY session_id ORDER BY id DESC) AS rn
          FROM messages WHERE session_id IN (%s) AND role = 'user' AND active = 1
                AND length(trim(coalesce(content, ''))) > 0) WHERE rn = 1""" % q, ids)}
    todo_lists = {r["session_id"]: parse_todos(r["content"]) for r in sqlite_rows(db, """
        SELECT session_id, content FROM (
          SELECT session_id, substr(content, 1, 12000) AS content,
                 row_number() OVER (PARTITION BY session_id ORDER BY id DESC) AS rn
          FROM messages WHERE session_id IN (%s) AND role = 'tool' AND tool_name = 'todo_list'
                AND content LIKE '{"todos"%%') WHERE rn = 1""" % q, ids)}
    out = []
    for entry in live:
        sid = str(entry.get("session_id"))
        s = sessions.get(sid, {})
        proc = by_pid[int(entry["pid"])]
        l = last.get(sid)
        working = sid in leases
        helpers = []
        for c in children:
            if c.get("parent") != sid:
                continue
            act = helper_activity(c if c.get("timestamp") is not None else None, now)
            if not act:
                continue
            helpers.append({
                "id": c["id"], "kind": "hermes", "title": re.sub(r"^Subagent:\s*", "", c.get("title") or ""),
                "activity": act, "model": pretty_model(c.get("model")), "depth": int(c.get("depth") or 1),
                "parent": c.get("boss"),
                "tool": c.get("tool_name") if c.get("role") == "tool" else first_call(c.get("tool_calls")),
                "goal": one_line(c.get("goal"), 240), "messages": int(c.get("message_count") or 0),
                "started_at": float(c.get("started_at") or 0), "last_at": float(c.get("timestamp") or 0)})
        helpers.sort(key=lambda h: (h["depth"], h["id"]))
        model = s.get("model") or ""
        provider = s.get("provider") or ("anthropic" if model.startswith("claude") else "")
        out.append({
            "id": sid, "kind": "hermes", "surface": entry.get("surface") or s.get("source"),
            "title": s.get("title") or "New chat", "model": pretty_model(model), "provider": provider,
            "activity": waiting_on_helpers(hermes_activity(l, working, now), helpers), "working": working,
            "tool": (l["tool_name"] if l["role"] == "tool" else first_call(l.get("tool_calls"))) if l else None,
            "messages": int(s.get("message_count") or 0),
            "tokens_in": int(s.get("input_tokens") or 0) + int(s.get("cache_read_tokens") or 0),
            "tokens_out": int(s.get("output_tokens") or 0),
            "started_at": float(s.get("started_at") or entry.get("started_at") or 0),
            "last_at": float(l["timestamp"]) if l and l.get("timestamp") is not None else float(entry.get("started_at") or 0),
            "tty": None if proc["tty"] == "??" else proc["tty"], "cwd": s.get("cwd"), "pid": proc["pid"],
            "helpers": helpers, "todos": todo_lists.get(sid, []), "closing": replies.get(sid), "ask": asks.get(sid)})
    out.sort(key=lambda a: a["started_at"])
    return out


# ---------- Claude Code and Codex ----------

def tail_lines(path, size=65536):
    try:
        with open(path, "rb") as f:
            f.seek(0, os.SEEK_END)
            end = f.tell()
            f.seek(max(end - size, 0))
            chunk = f.read().decode("utf-8", "replace")
        lines = [l.strip() for l in chunk.splitlines() if l.strip()]
        return lines[1:] if end > size else lines
    except OSError:
        return []


def _birth(path):
    st = os.stat(path)
    return getattr(st, "st_birthtime", st.st_mtime)


def cwd_of(pid):
    out = run(["lsof", "-a", "-p", str(pid), "-d", "cwd", "-Fn"], timeout=4)
    m = re.search(r"^n(.+)$", out, re.M)
    return m.group(1) if m else None


def claude_sessions(procs, dirs, now, chome):
    """Pair each running claude with the transcript it is writing."""
    import glob
    out = {}
    groups = {}
    for p in procs:
        groups.setdefault(dirs.get(p["pid"]), []).append(p)
    for d, group in groups.items():
        if not d:
            continue
        folder = os.path.join(chome, "projects", re.sub(r"[^A-Za-z0-9-]", "-", d))
        started = min(now - p["seconds"] for p in group) - 60
        files = [f for f in glob.glob(os.path.join(folder, "*.jsonl")) if os.path.getmtime(f) >= started]
        if not files:
            continue
        group = sorted(group, key=lambda p: -p["seconds"])
        files = [max(files, key=os.path.getmtime)] if len(group) == 1 else sorted(files, key=_birth)
        for p, f in zip(group, files):
            out[p["pid"]] = re.sub(r"\.jsonl$", "", f)
    return out


def claude_activity(lines, age):
    entry = None
    for l in reversed(lines):
        try:
            e = json.loads(l)
        except ValueError:
            continue
        if isinstance(e, dict) and e.get("type") in ("assistant", "user"):
            entry = e
            break
    if not entry:
        return None
    content = (entry.get("message") or {}).get("content")
    content = content if isinstance(content, list) else []
    if entry["type"] == "assistant":
        call = next((c for c in reversed(content) if isinstance(c, dict) and c.get("type") == "tool_use"), None)
        if not call:
            return None
        for act, names in CLAUDE_TOOLS.items():
            if call.get("name") in names:
                return act
        return tool_activity(call["name"]) if str(call.get("name", "")).startswith("mcp__") else "working"
    return None if age > SUBAGENT_FRESH else "thinking"


ARG_KEYS = ["command", "cmd", "file_path", "path", "pattern", "query", "url", "goal", "description",
            "prompt", "question", "code"]


def arg_hint(args):
    if args is None:
        return ""
    if isinstance(args, str):
        try:
            parsed = json.loads(args)
            if isinstance(parsed, dict):
                return arg_hint(parsed)
        except ValueError:
            pass
        for k in ARG_KEYS:
            m = re.search(r'\\?"%s\\?"\s*:\s*\\?"([^"\\]{1,400})' % k, args)
            if m:
                return one_line(m.group(1), 140)
        return ""
    if not isinstance(args, dict):
        return ""
    for k in ARG_KEYS:
        if isinstance(args.get(k), str) and args[k]:
            return one_line(args[k], 140)
    return ""


def claude_steps(lines):
    out = []
    for l in lines:
        try:
            e = json.loads(l)
        except ValueError:
            continue
        if not isinstance(e, dict) or e.get("type") not in ("assistant", "user"):
            continue
        at = _parse_ts(e.get("timestamp"))
        content = (e.get("message") or {}).get("content")
        if e["type"] == "user":
            if isinstance(content, str) and not out:
                out.append({"at": at, "kind": "task", "text": one_line(content, 300)})
            continue
        for c in (content if isinstance(content, list) else []):
            if not isinstance(c, dict):
                continue
            if c.get("type") == "tool_use":
                out.append({"at": at, "kind": "tool", "tool": c.get("name"), "text": arg_hint(c.get("input"))})
            elif c.get("type") == "text" and str(c.get("text", "")).strip():
                out.append({"at": at, "kind": "said", "text": one_line(c["text"], 300)})
    return out


def _parse_ts(s):
    try:
        return datetime.datetime.fromisoformat(str(s).replace("Z", "+00:00")).timestamp()
    except Exception:
        return None


def claude_subagents(session, now):
    import glob
    helpers = []
    for f in glob.glob(os.path.join(session, "subagents", "agent-*.jsonl")):
        try:
            mtime = os.path.getmtime(f)
        except OSError:
            continue
        if now - mtime > SUBAGENT_IN_TOOL:
            continue
        lines = tail_lines(f)
        act = claude_activity(lines, now - mtime)
        if not act:
            continue
        try:
            with open(re.sub(r"\.jsonl$", ".meta.json", f), "r", encoding="utf-8") as mf:
                meta = json.load(mf)
        except Exception:
            meta = {}
        steps = claude_steps(lines)
        goal = None
        try:
            with open(f, "r", encoding="utf-8") as fh:
                first = json.loads(fh.readline())
            goal = (first.get("message") or {}).get("content")
            if isinstance(goal, list):
                goal = next((c.get("text") for c in goal if isinstance(c, dict) and c.get("type") == "text"), None)
        except Exception:
            pass
        tool = next((st.get("tool") for st in reversed(steps) if st.get("tool")), None)
        try:
            spawn = int(meta.get("spawnDepth") or 1)
        except (TypeError, ValueError):
            spawn = 1
        helpers.append({
            "id": "claude-" + os.path.basename(f)[:-len(".jsonl")], "kind": "claude",
            "title": meta.get("description") or meta.get("agentType") or "Subagent", "activity": act,
            "model": meta.get("agentType"), "depth": max(1, min(4, spawn)),
            "parent": os.path.basename(session), "tool": tool, "goal": one_line(goal, 240), "messages": None,
            "started_at": _birth(f), "last_at": mtime})
    helpers.sort(key=lambda h: h["id"])
    return helpers


def claude_todo_list(lines):
    for l in reversed(lines):
        if '"TodoWrite"' not in l:
            continue
        try:
            e = json.loads(l)
        except ValueError:
            continue
        content = (e.get("message") or {}).get("content")
        call = next((c for c in reversed(content if isinstance(content, list) else [])
                     if isinstance(c, dict) and c.get("type") == "tool_use" and c.get("name") == "TodoWrite"), None)
        if call:
            return parse_todos({"todos": (call.get("input") or {}).get("todos") or []})
    return []


def claude_last_text(lines):
    for l in reversed(lines):
        if '"assistant"' not in l:
            continue
        try:
            e = json.loads(l)
        except ValueError:
            continue
        if e.get("type") != "assistant":
            continue
        content = (e.get("message") or {}).get("content")
        txt = "\n\n".join(c.get("text", "") for c in (content if isinstance(content, list) else [])
                          if isinstance(c, dict) and c.get("type") == "text")
        if txt.strip():
            return txt
    return None


def cli_agents(procs, now, chome=None, cwd_fn=cwd_of):
    chome = chome or claude_home()
    lst = [p for p in procs if p["tty"] != "??" and p["name"] in ("claude", "codex")]
    dirs = {p["pid"]: cwd_fn(p["pid"]) for p in lst}
    sessions = claude_sessions([p for p in lst if p["name"] == "claude"], dirs, now, chome)
    helpers = {pid: claude_subagents(s, now) for pid, s in sessions.items()}
    tails = {pid: tail_lines(s + ".jsonl", 262144) for pid, s in sessions.items()}
    out = []
    for p in lst:
        d = dirs.get(p["pid"])
        label = "Claude Code" if p["name"] == "claude" else "Codex"
        busy = p["cpu"] >= 5
        lines = tails.get(p["pid"], [])
        out.append({
            "id": "%s-%d" % (p["name"], p["pid"]), "kind": p["name"], "surface": "cli",
            "title": "%s in %s" % (label, os.path.basename(d)) if d else label, "model": label,
            "activity": "typing" if busy else "idle", "working": busy, "tool": None, "messages": None,
            "started_at": now - p["seconds"], "last_at": now if busy else None, "tty": p["tty"], "cwd": d,
            "pid": p["pid"], "helpers": helpers.get(p["pid"], []),
            "todos": claude_todo_list(lines) if lines else [],
            "closing": closing(claude_last_text(lines)) if lines else None,
            "ask": ask_line(next((r["text"] for r in reversed(claude_chat_rows(lines)) if r["role"] == "user"), "")) if lines else None,
            "transcript": sessions[p["pid"]] + ".jsonl" if p["pid"] in sessions else None})
    return out


# ---------- Ollama and the rest of the rack ----------

def ollama_models(url=None):
    """Loaded models from Ollama's /api/ps, or None when it is not answering."""
    url = url or os.environ.get("GOLDWARE_OLLAMA_URL") or "http://127.0.0.1:11434"
    if url == "off":
        return None
    try:
        with urllib.request.urlopen(url.rstrip("/") + "/api/ps", timeout=1.5) as r:
            data = json.loads(r.read().decode("utf-8"))
        return [m for m in (data.get("models") or []) if isinstance(m, dict)]
    except Exception:
        return None


def rack(procs, ollama_url=None):
    models = ollama_models(ollama_url)
    ps_ollama = any(p["name"] in ("ollama", "llama-server") for p in procs)
    units = [{"name": m.get("name"), "kind": "ollama", "params": (m.get("details") or {}).get("parameter_size"),
              "until": m.get("expires_at")} for m in (models or [])]
    if any(p["name"] == "whisper-server" for p in procs):
        units.append({"name": "whisper", "kind": "whisper"})
    return {"ollama": models is not None or ps_ollama, "units": units}


def gateway_running(procs):
    if not any("hermes" in p["name"] or p["name"].startswith("python") for p in procs):
        return False
    return any("hermes" in l and "gateway run" in l and "osascript" not in l
               for l in run(["ps", "-axo", "args="]).splitlines())


def empty_snapshot(now):
    return {"generated_at": datetime.datetime.utcfromtimestamp(now).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "home": os.path.expanduser("~"), "agents": [], "gateway": {"running": False}, "rack": {"ollama": False, "units": []}}


def snapshot(now=None, home=None, ps_text=None, chome=None, ollama_url=None, data_root=None, cwd_fn=cwd_of,
             gateway=True):
    now = time.time() if now is None else now
    if forced_empty() and ps_text is None:
        return empty_snapshot(now)
    procs = parse_ps(ps_text if ps_text is not None else read_ps())
    by_pid = {p["pid"]: p for p in procs}
    agents = hermes_agents(home or hermes_home(), by_pid, now) + cli_agents(procs, now, chome, cwd_fn)
    if data_root:
        # The boss (server/office_boss.py) is the Hermes chat working in data/boss: it sits at the
        # front desk, not at a desk, and does not take a name from the cast.
        boss_home = os.path.realpath(os.path.join(data_root, "boss"))
        for a in agents:
            if a["kind"] == "hermes" and a.get("cwd") and os.path.realpath(a["cwd"]) == boss_home:
                a["boss"] = True
        names = name_agents(data_root, [a["id"] for a in agents if not a.get("boss")])
        for a in agents:
            a["name"] = "Boss" if a.get("boss") else names.get(a["id"])
    return {"generated_at": datetime.datetime.utcfromtimestamp(now).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "home": os.path.expanduser("~"), "agents": agents,
            "gateway": {"running": bool(gateway and agents and gateway_running(procs))},
            "rack": rack(procs, ollama_url)}


def find_agent(agent_id, **kw):
    for a in snapshot(**kw)["agents"]:
        if a["id"] == str(agent_id) and a.get("tty"):
            return a
    return None


# ---------- helper detail ----------

def hermes_steps(sid, home):
    db = os.path.join(home, "state.db")
    rows = sqlite_rows(db, """
        SELECT role, tool_name, substr(tool_calls, 1, 1200) AS tool_calls, substr(content, 1, 400) AS content, timestamp FROM (
          SELECT id, role, tool_name, tool_calls, content, timestamp FROM messages
          WHERE session_id = ? AND active = 1 AND role IN ('user', 'assistant') ORDER BY id DESC LIMIT 40)
        ORDER BY timestamp""", [sid])
    goal = sqlite_rows(db, "SELECT substr(content, 1, 300) AS content, timestamp FROM messages "
                           "WHERE session_id = ? AND role = 'user' ORDER BY id LIMIT 1", [sid])
    steps = [{"at": float(goal[0]["timestamp"] or 0), "kind": "task", "text": one_line(goal[0]["content"], 300)}] if goal else []
    for r in rows:
        if r["role"] == "user":
            continue
        at = float(r["timestamp"] or 0)
        try:
            calls = json.loads(r["tool_calls"] or "")
        except ValueError:
            calls = None
        if isinstance(calls, list) and calls:
            for c in calls:
                fn = c.get("function") or {}
                steps.append({"at": at, "kind": "tool", "tool": fn.get("name") or c.get("name"),
                              "text": arg_hint(fn.get("arguments") or c.get("arguments"))})
        else:
            name = first_call(r["tool_calls"])
            if name:
                steps.append({"at": at, "kind": "tool", "tool": name, "text": arg_hint(r["tool_calls"])})
        if str(r["content"] or "").strip():
            steps.append({"at": at, "kind": "said", "text": one_line(r["content"], 300)})
    return steps


def helper_detail(hid, **kw):
    import glob
    snap = snapshot(**kw)
    hid = str(hid)
    for owner in snap["agents"]:
        helper = next((h for h in owner.get("helpers", []) if h["id"] == hid), None)
        if not helper:
            continue
        if helper["kind"] == "claude":
            name = re.sub(r"^claude-", "", hid)
            if not re.fullmatch(r"agent-[A-Za-z0-9_-]+", name):
                return None
            hits = glob.glob(os.path.join(kw.get("chome") or claude_home(), "projects", "*", "*", "subagents", name + ".jsonl"))
            steps = claude_steps(tail_lines(hits[0], 262144)) if hits else []
        else:
            steps = hermes_steps(hid, kw.get("home") or hermes_home())
        return {"id": helper["id"], "owner": owner["id"], "owner_title": owner["title"],
                "helper": helper, "steps": steps[-14:]}
    return None


# ---------- talking to a terminal ----------

SCREEN_SCRIPT = """on run argv
  set target to item 1 of argv
  if application "iTerm" is running then
    tell application "iTerm"
      repeat with w in windows
        repeat with t in tabs of w
          repeat with s in sessions of t
            if tty of s is target then return contents of s
          end repeat
        end repeat
      end repeat
    end tell
  end if
  if application "Terminal" is running then
    tell application "Terminal"
      repeat with w in windows
        repeat with t in tabs of w
          if tty of t is target then return contents of t
        end repeat
      end repeat
    end tell
  end if
  return "GOLDWARE-OFFICE-NOTFOUND"
end run
"""

# Types the line, pauses, then sends Return on its own (text and Return together can land
# before the prompt is ready). Returns "sent" or "notfound".
SEND_SCRIPT = """on run argv
  set target to item 1 of argv
  set line_ to item 2 of argv
  if application "iTerm" is running then
    tell application "iTerm"
      repeat with w in windows
        repeat with t in tabs of w
          repeat with s in sessions of t
            if tty of s is target then
              tell s to write text line_ newline no
              delay 0.4
              tell s to write text ""
              return "sent"
            end if
          end repeat
        end repeat
      end repeat
    end tell
  end if
  if application "Terminal" is running then
    tell application "Terminal"
      repeat with w in windows
        repeat with t in tabs of w
          if tty of t is target then
            do script line_ in t
            return "sent"
          end if
        end repeat
      end repeat
    end tell
  end if
  return "notfound"
end run
"""

FOCUS_SCRIPT = """on run argv
  set target to item 1 of argv
  if application "iTerm" is running then
    tell application "iTerm"
      repeat with w in windows
        repeat with t in tabs of w
          repeat with s in sessions of t
            if tty of s is target then
              select w
              tell t to select
              tell s to select
              activate
              return "ok"
            end if
          end repeat
        end repeat
      end repeat
    end tell
  end if
  if application "Terminal" is running then
    tell application "Terminal"
      repeat with w in windows
        repeat with t in tabs of w
          if tty of t is target then
            set selected tab of w to t
            set index of w to 1
            activate
            return "ok"
          end if
        end repeat
      end repeat
    end tell
  end if
  return "notfound"
end run
"""

DRY_LOG = []          # (script_name, argv) of every dry-run call, newest last
_TTY = re.compile(r"^ttys\d{1,4}$")


def device_path(tty):
    """/dev/ttysNNN, or an OfficeError for anything else (this is what keeps a made-up tty out)."""
    if not isinstance(tty, str) or not _TTY.match(tty):
        raise OfficeError("That is not a terminal this office knows.", 422)
    return "/dev/" + tty


def osa(name, script, *args, timeout=OSA_TIMEOUT):
    """Run osascript with a deadline, text and tty as arguments (never as script source).
    A modal dialog in iTerm blocks AppleScript, so a hung call is killed."""
    argv = ["osascript", "-e", script] + list(args)
    if dry_run():
        DRY_LOG.append((name, argv))
        canned = {"screen": "dry run screen\n", "send": "sent\n", "focus": "ok\n", "new": "opened\n", "close": "closed\n",
                  "choose": os.path.expanduser("~") + "/Projects/Bakery Site/\n"}
        return canned.get(name, ""), "", 0
    try:
        proc = subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                universal_newlines=True)
    except OSError as e:
        raise TerminalError("osascript could not start: %s" % e)
    try:
        out, err = proc.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.communicate()
        raise TerminalError("The terminal did not answer. If it is showing a dialog, close it and try again.")
    return out, err, proc.returncode


def friendly(err):
    if "-1743" in err:
        return "Allow GoldWare OS to control iTerm in System Settings > Privacy & Security > Automation."
    return err.strip() or "The terminal could not be reached."


def focus(tty):
    out, err, code = osa("focus", FOCUS_SCRIPT, device_path(tty))
    if code != 0:
        raise TerminalError(friendly(err))
    return out.strip() == "ok"


def screen(tty):
    """The last lines of what that terminal shows, trailing blank lines dropped. None when closed."""
    out, err, code = osa("screen", SCREEN_SCRIPT, device_path(tty))
    if code != 0:
        raise TerminalError(friendly(err))
    if out.strip() == "GOLDWARE-OFFICE-NOTFOUND":
        return None
    lines = [l.rstrip() for l in re.sub(r"\r\n?", "\n", out).split("\n")]
    while lines and not lines[-1]:
        lines.pop()
    return "\n".join(lines[-SCREEN_LINES:])


def prepare_text(text, kind):
    """One line of text, control characters removed. Hermes chats get /queue so a busy agent
    finishes its turn first (a bare message would interrupt it); a slash command goes as is."""
    line = re.sub(r"[\r\n\t]+", " ", str(text if text is not None else ""))
    line = re.sub(r"[\x00-\x1f\x7f-\x9f]", "", line).strip()
    if not line:
        raise OfficeError("Type something to send.")
    if len(line) > MAX_TEXT:
        raise OfficeError("Keep it under %d characters." % MAX_TEXT)
    return "/queue " + line if kind == "hermes" and not line.startswith("/") else line


def send_text(tty, line):
    out, err, code = osa("send", SEND_SCRIPT, device_path(tty), line)
    if code != 0:
        raise TerminalError(friendly(err))
    return out.strip() == "sent"


_SENT = {}
_SENT_LOCK = threading.Lock()


def throttle(agent_id, now=None):
    """Seconds left to wait before another line may go to this agent (0 and the slot is taken)."""
    now = time.time() if now is None else now
    with _SENT_LOCK:
        last = _SENT.get(agent_id)
        left = SEND_GAP - (now - last) if last else 0
        if left <= 0:
            _SENT[agent_id] = now
        return max(0, left)


def send_to_agent(body, **kw):
    """The whole send action: find the agent in a fresh snapshot, check, type. Returns the JSON reply."""
    if not isinstance(body, dict):
        raise OfficeError("Body must be a JSON object.")
    agent = find_agent(body.get("id"), **kw)
    if not agent:
        raise OfficeError("That agent is not at a terminal any more.", 404)
    line = prepare_text(body.get("text"), agent["kind"])
    if throttle(agent["id"]) > 0:
        raise OfficeError("One line every 2 seconds.", 429)
    if not send_text(agent["tty"], line):
        raise OfficeError("Its terminal window is closed.", 404)
    return {"ok": True, "sent": line, "queued": line.startswith("/queue ") and bool(agent.get("working"))}


# ---------- dismiss: ask, then close the terminal ----------

DISMISS_ASK = "Anything else before we dismiss you? If not, just say you're all set."
DISMISS_BUSY = ("typing", "writing", "reading", "browsing", "looking", "delegating", "thinking", "working", "helpers")
DISMISS_CPU = 3.0                # a claude or codex on the tty at this much CPU is working
DISMISS_GAP = 0.8                # seconds between HUP, TERM and KILL

# Closes only the iTerm session or Terminal window whose tty matches. Never quits the app.
CLOSE_SCRIPT = """on run argv
  set target to item 1 of argv
  if application "iTerm" is running then
    tell application "iTerm"
      repeat with w in windows
        repeat with t in tabs of w
          repeat with s in sessions of t
            if tty of s is target then
              try
                close s
              end try
              return "closed"
            end if
          end repeat
        end repeat
      end repeat
    end tell
  end if
  if application "Terminal" is running then
    tell application "Terminal"
      repeat with w in windows
        repeat with t in tabs of w
          if tty of t is target then
            try
              close w
            end try
            return "closed"
          end if
        end repeat
      end repeat
    end tell
  end if
  return "notfound"
end run
"""

DISMISS_LOG = []      # dry run: {"tty", "signal", "pids"} for each planned signal, newest last


def tty_procs(tty, ps_text=None):
    """The processes on one tty, from a fresh `ps` (or the test fixture)."""
    text = ps_text if ps_text is not None else read_ps()
    return [p for p in parse_ps(text) if p["tty"] == tty]


def dismiss_blocker(agent, ps_rows):
    """Why this agent cannot be closed right now, or None. ps_rows: 'pcpu comm' lines for its tty."""
    if not agent or not agent.get("tty"):
        return "It is not at a terminal."
    name = agent.get("name") or "It"
    if agent.get("working") or agent.get("activity") in DISMISS_BUSY:
        return "%s is working. Wait for it to finish, then close." % name
    if agent.get("helpers"):
        return "%s still has helpers out." % name
    for line in str(ps_rows or "").splitlines():
        parts = line.strip().split(None, 1)
        if len(parts) == 2 and re.search(r"(^|/)(claude|codex)$", parts[1]):
            try:
                if float(parts[0]) >= DISMISS_CPU:
                    return "%s is working. Wait for it to finish, then close." % name
            except ValueError:
                pass
    return None


def blocker_for(agent, ps_text=None):
    rows = "\n".join("%s %s" % (p["cpu"], p["name"]) for p in tty_procs(agent.get("tty"), ps_text)) if agent and agent.get("tty") else ""
    return dismiss_blocker(agent, rows)


def signal_targets(tty, ps_text=None):
    """Pids on the tty that may be signalled: never pid 1, this server, its parent, or a login."""
    skip = {0, 1, os.getpid(), os.getppid()}
    return [p["pid"] for p in tty_procs(tty, ps_text) if p["pid"] not in skip and not p["name"].endswith("login")]


def dismiss(agent, sleep=time.sleep, **kw):
    """Hang up what runs on the agent's tty (HUP, TERM, KILL), then close just that session.
    The agent is checked against a fresh snapshot. Returns True when the session was closed."""
    tty = agent.get("tty") if isinstance(agent, dict) else None
    device_path(tty)              # raises unless it looks like ttysNNN
    fresh = find_agent(agent.get("id"), **kw)
    if not fresh or fresh.get("tty") != tty:
        raise OfficeError("That agent is not at a terminal any more.", 404)
    ps_text = kw.get("ps_text")
    if os.environ.get("GOLDWARE_OFFICE_PS_FILE") and not dry_run():
        raise TerminalError("A process fixture is in use, so nothing was closed.")
    reason = blocker_for(fresh, ps_text)
    if reason:
        raise OfficeError(reason, 409)
    for sig in ("HUP", "TERM", "KILL"):
        pids = signal_targets(tty, ps_text)
        if not pids:
            break
        if dry_run():
            DISMISS_LOG.append({"tty": tty, "signal": sig, "pids": pids})
            continue
        for pid in pids:
            try:
                os.kill(pid, getattr(signal, "SIG" + sig))
            except (ProcessLookupError, PermissionError):
                pass
        sleep(DISMISS_GAP)
    out, err, code = osa("close", CLOSE_SCRIPT, device_path(tty))
    if code != 0:
        raise TerminalError(friendly(err))
    return out.strip() == "closed"


def dismiss_agent(body, **kw):
    """POST /api/office/dismiss: step check, ask (types the question) or close (re-checks, then closes)."""
    if not isinstance(body, dict):
        raise OfficeError("Body must be a JSON object.")
    agent = find_agent(body.get("id"), **kw)
    if not agent:
        raise OfficeError("That agent is not at a terminal any more.", 404)
    step = body.get("step")
    if step == "check":
        reason = blocker_for(agent, kw.get("ps_text"))
        if reason:
            raise OfficeError(reason, 409)
        return {"ok": True}
    if step == "ask":
        line = prepare_text(DISMISS_ASK, agent["kind"])
        if throttle(agent["id"]) > 0:
            raise OfficeError("One line every 2 seconds.", 429)
        if not send_text(agent["tty"], line):
            raise OfficeError("Its terminal window is closed.", 404)
        return {"ok": True, "asked": True, "queued": line.startswith("/queue ") and bool(agent.get("working"))}
    if step == "close":
        reason = blocker_for(agent, kw.get("ps_text"))
        if reason:
            raise OfficeError(reason, 409)
        dismiss(agent, **kw)
        return {"ok": True, "closed": True}
    raise OfficeError("Say ask or close.")


def focus_agent(body, **kw):
    if not isinstance(body, dict):
        raise OfficeError("Body must be a JSON object.")
    agent = find_agent(body.get("id"), **kw)
    if not agent or not focus(agent["tty"]):
        raise OfficeError("Its terminal window is closed.", 404)
    return {"ok": True}


def screen_of_agent(agent_id, **kw):
    agent = find_agent(agent_id, **kw)
    if not agent:
        raise OfficeError("That agent is not at a terminal any more.", 404)
    text = screen(agent["tty"])
    if text is None:
        raise OfficeError("Its terminal window is closed.", 404)
    return {"id": agent["id"], "tty": agent["tty"], "activity": agent["activity"], "screen": text}


# ---------- the Chat view: the latest turns in plain words ----------

CHAT_VERBS = {
    "typing": ("Ran", "command", "commands"), "writing": ("Edited", "file", "files"),
    "reading": ("Read or searched", "time", "times"), "browsing": ("Used the web", "time", "times"),
    "looking": ("Looked at", "image", "images"), "delegating": ("Sent out", "helper", "helpers"),
    "working": ("Used", "other tool", "other tools"),
}
PLAN_TOOLS = ("todo_list", "TodoWrite")


def chat_kind(name):
    if name in PLAN_TOOLS:
        return "planning"
    for act, names in CLAUDE_TOOLS.items():
        if name in names:
            return act
    return tool_activity(name)


def tools_summary(names):
    counts = {}
    for n in names:
        k = chat_kind(n)
        if k != "asking":
            counts[k] = counts.get(k, 0) + 1
    parts = []
    for k, c in counts.items():
        if k == "planning":
            parts.append("updated its plan")
            continue
        verb, one, many = CHAT_VERBS.get(k, CHAT_VERBS["working"])
        parts.append("%s %d %s" % (verb.lower(), c, one if c == 1 else many))
    if not parts:
        return None
    text = ", ".join(parts)
    return text[0].upper() + text[1:]


def chat_turns(rows, limit=16):
    """rows: [{role: user|assistant, text, tools: [names]}], oldest first.
    Returns the last `limit` of {kind: you|did|said, text}; tool calls fold into one "did" line."""
    out, pending = [], []

    def flush():
        line = tools_summary(pending)
        if line:
            out.append({"kind": "did", "text": line})
        del pending[:]

    for r in rows:
        text = str(r.get("text") or "").strip()
        if r.get("role") == "user":
            flush()
            if text:
                out.append({"kind": "you", "text": text[:1500]})
        else:
            pending.extend(r.get("tools") or [])
            if not text:
                continue
            flush()
            out.append({"kind": "said", "text": text[:6000]})
    flush()
    return out[-limit:]


def hermes_chat_rows(sid, home=None):
    db = os.path.join(home or hermes_home(), "state.db")
    rows = sqlite_rows(db, """
        SELECT role, substr(coalesce(content, ''), 1, 6000) AS content, substr(coalesce(tool_calls, ''), 1, 4000) AS tool_calls
        FROM messages WHERE session_id = ? AND active = 1 AND role IN ('user', 'assistant') ORDER BY id DESC LIMIT 80""", (sid,))
    return [{"role": r["role"], "text": r["content"],
             "tools": re.findall(r'(?<!\\)"name":\s*"([^"\\]+)"', r["tool_calls"] or "")} for r in reversed(rows)]


def claude_chat_rows(lines):
    out = []
    for l in lines:
        try:
            e = json.loads(l)
        except ValueError:
            continue
        if not isinstance(e, dict) or e.get("type") not in ("user", "assistant"):
            continue
        content = (e.get("message") or {}).get("content")
        if e["type"] == "user":
            if isinstance(content, str):
                text = content
            else:
                text = "\n".join(c.get("text", "") for c in (content or []) if isinstance(c, dict) and c.get("type") == "text")
            if not text.strip() or text.startswith(("<command-", "<local-command", "Caveat:")):
                continue
            out.append({"role": "user", "text": text})
        else:
            parts = [c for c in (content if isinstance(content, list) else []) if isinstance(c, dict)]
            out.append({"role": "assistant",
                        "text": "\n\n".join(c.get("text", "") for c in parts if c.get("type") == "text"),
                        "tools": [c.get("name") for c in parts if c.get("type") == "tool_use"]})
    return out


def chat_view(agent, home=None):
    """The turns for one agent, or None when it keeps no readable transcript (Codex)."""
    if agent.get("kind") == "hermes":
        return chat_turns(hermes_chat_rows(agent["id"], home))
    if agent.get("kind") == "claude" and agent.get("transcript"):
        return chat_turns(claude_chat_rows(tail_lines(agent["transcript"], 400000)))
    return None


def chat_of_agent(agent_id, **kw):
    agent = find_agent(agent_id, **kw)
    if not agent:
        raise OfficeError("That agent is not at a terminal any more.", 404)
    return {"id": agent["id"], "turns": chat_view(agent, kw.get("home"))}


# ---------- the board: names, project, tasks, ideas, the lab ----------

BOARD_MAX = {"tasks": 200, "ideas": 40, "suggestions": 30}
BOARD_LOCK = threading.RLock()
LAB = {
    "brainstorm": {"toolsets": "todo", "turns": "2", "budget": "180"},
    "research": {"toolsets": "web", "turns": "16", "budget": "420"},
    "regroup": {"toolsets": "todo", "turns": "2", "budget": "120"},
}


def board_path(data_root):
    return os.path.join(data_root, "office-board.json")


def blank_board():
    return {"project": {"name": "", "about": ""}, "tasks": [], "ideas": [], "suggestions": [], "runs": {}, "groupings": {}}


def load_board(data_root):
    try:
        with open(board_path(data_root), "r", encoding="utf-8") as f:
            state = json.load(f)
        if isinstance(state, dict):
            b = blank_board()
            b.update(state)
            return b
    except Exception:
        pass
    return blank_board()


def save_board(data_root, state):
    os.makedirs(data_root, exist_ok=True)
    path = board_path(data_root)
    tmp = "%s.%d.%s.tmp" % (path, os.getpid(), uuid.uuid4().hex[:6])
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(state, f, indent=2)
    os.replace(tmp, path)


def clean(text, max_len):
    t = re.sub(r"[\x00-\x1f\x7f-\x9f]+", " ", str(text if text is not None else ""))
    t = re.sub(r"\s+", " ", t).strip()
    return t[:max_len]


def name_agents(data_root, ids):
    """Every agent gets a name from the cast the moment it sits down, kept while it stays. A name
    freed by an agent that left goes to the next one that sits down."""
    with BOARD_LOCK:
        before = load_board(data_root)
        s = json.loads(json.dumps(before))
        s.pop("retired", None)
        names = s.setdefault("names", {})
        for i in list(names):
            if i not in ids or not (names[i] in NAMES or str(names[i]).startswith("Agent ")):
                names.pop(i)
        taken = list(names.values())
        for i in ids:
            if i in names:
                continue
            pick = next((n for n in NAMES if n not in taken), None)
            if pick is None:
                k = len(NAMES) + 1
                while "Agent %d" % k in taken:
                    k += 1
                pick = "Agent %d" % k
            names[i] = pick
            taken.append(pick)
        if s != before and (ids or before.get("names")):
            try:
                save_board(data_root, s)
            except OSError:
                pass
        return {i: names[i] for i in ids if i in names}


def _alive(pid):
    try:
        os.kill(int(pid), 0)
        return True
    except ProcessLookupError:
        return False
    except (PermissionError, TypeError, ValueError):
        return True


def board_view(data_root, now=None):
    now = time.time() if now is None else now
    with BOARD_LOCK:
        s = load_board(data_root)
        if settle_runs(s, now):
            save_board(data_root, s)
    tasks = s["tasks"]
    s = dict(s)
    s.pop("names", None)
    s.pop("retired", None)
    s["progress"] = {"done": sum(1 for t in tasks if t.get("status") == "done"), "total": len(tasks)}
    return s


def _find(state, lst, item_id):
    for x in state[lst]:
        if x.get("id") == str(item_id):
            return x
    raise OfficeError("That card is gone.")


RANK = {"idle": 0, "asleep": 0, "your_turn": 1}


def pick_agent(agents, tasks):
    """An agent with nothing pending first, then one waiting on you, then a busy one;
    fewest open board tasks breaks ties."""
    open_n = {}
    for t in tasks:
        if t.get("status") == "assigned":
            open_n[t.get("agent")] = open_n.get(t.get("agent"), 0) + 1
    cand = [a for a in agents if a.get("tty")]
    return min(cand, key=lambda a: (RANK.get(a["activity"], 2), open_n.get(a["id"], 0), a.get("started_at") or 0)) if cand else None


def task_message(task, project):
    name = (project or {}).get("name")
    head = "Task from the Office board for %s" % name if name else "Task from the Office board"
    parts = [head + ": " + task["title"] + ".", task.get("notes") or None, 'Say "done" when it is finished.']
    return " ".join(p for p in parts if p)


def lab_prompt(kind, state):
    p = state["project"]
    name = p.get("name") or "an unnamed product"
    open_t = ["- " + t["title"] for t in [t for t in state["tasks"] if t.get("status") != "done"][-15:]]
    done_t = ["- " + t["title"] for t in [t for t in state["tasks"] if t.get("status") == "done"][-10:]]
    seen = ["- " + x["title"] for x in (state["ideas"] + state["suggestions"])[-20:]]
    ctx = "\n".join([
        "The project: %s. %s" % (name, p.get("about", "")),
        "Open tasks:", "\n".join(open_t) or "- none yet",
        "Done so far:", "\n".join(done_t) or "- nothing yet",
        "Already on the boards (do not repeat):", "\n".join(seen) or "- nothing yet"])
    if kind == "brainstorm":
        return ("You are the brainstorming agent in the user's office. They are taking a product from start to finish.\n"
                + ctx + "\nGive 5 fresh, concrete, distinct ideas that move this product forward from where it is now:\n"
                "features, launch moves, ways to get first users, ways to make it more fun. Each must be\n"
                "something an agent could start on today. Do not use any tools.\n"
                'Reply with only JSON, no prose: {"ideas": [{"title": "at most 9 words", "why": "one sentence"}]}\n')
    return ("You are the researcher in the user's lab. They are taking a product from start to finish.\n"
            + ctx + "\nSearch the web for what similar products, competitors, and people who launched something\n"
            "like this have learned. Read a few real sources. Then give 3 or 4 pieces of advice for this\n"
            "project, each grounded in one source you actually read. Do not edit any files.\n"
            'Reply with only JSON, no prose:\n'
            '{"suggestions": [{"title": "at most 9 words", "advice": "two sentences", '
            '"source_title": "...", "source_url": "https://..."}]}\n')


def hermes_bin():
    return os.environ.get("GOLDWARE_HERMES_BIN") or shutil.which("hermes")


def spawn_detached(argv, out, err):
    with open(out, "wb") as o, open(err, "wb") as e:
        p = subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=o, stderr=e, start_new_session=True,
                             cwd=os.path.expanduser("~"))
    return p.pid


def home_table():
    return os.path.expanduser("~")


def open_at(state, table, home):
    """Open tasks on one whiteboard (a task with no group belongs to the home table)."""
    return [t for t in state["tasks"] if t.get("status") != "done" and (t.get("group") or home) == table]


def regroup_prompt(state, table, home):
    lines = []
    for t in open_at(state, table, home):
        notes = clean(t.get("notes"), 160)
        lines.append("- %s: %s%s" % (t["id"], t.get("title", ""), " (%s)" % notes if notes else ""))
    return (
        "You sort the user's to-do whiteboard into groups so it is easy to read at a glance.\n"
        "The tasks, as id: title (notes):\n" + "\n".join(lines) + "\n"
        "Group them so each group makes sense on its own: by client or project, or by kind of work when\n"
        "that reads better. Use 3 to 7 groups, each named in 1 to 4 plain words. Put every task in exactly\n"
        "one group, using its id. Order the groups by what the user should look at first. Mark a group\n"
        "\"needs_user\": true only when its tasks wait on the user's own decision or action. Do not use any tools.\n"
        "Reply with only JSON, no prose:\n"
        '{"groups": [{"name": "...", "needs_user": false, "ids": ["t..."]}]}\n')


def parse_regroup(text, open_ids):
    """Keeps only real open task ids at that table, each once; anything the model left out goes to
    "Everything else", so no task can vanish from the board."""
    m = re.search(r"\{.*\}", text or "", re.S)
    try:
        data = json.loads(m.group(0)) if m else None
    except ValueError:
        data = None
    if not isinstance(data, dict) or not isinstance(data.get("groups"), list):
        return []
    seen, groups = set(), []
    for g in data["groups"][:8]:
        if not isinstance(g, dict):
            continue
        ids = []
        for i in g.get("ids") or []:
            i = str(i)
            if i in open_ids and i not in seen:
                seen.add(i)
                ids.append(i)
        name = clean(g.get("name"), 40)
        if ids and name:
            groups.append({"name": name, "needs_user": g.get("needs_user") is True, "ids": ids})
    if not groups:
        return []
    rest = [i for i in open_ids if i not in seen]
    if rest:
        groups.append({"name": "Everything else", "needs_user": False, "ids": rest})
    return groups


def start_lab(data_root, kind, now=None, spawner=None, hermes=None, table=None, home=None):
    cfg = LAB.get(kind)
    if not cfg:
        raise OfficeError("Unknown lab job.")
    now = time.time() if now is None else now
    binary = hermes or hermes_bin()
    if not binary and not spawner:
        raise OfficeError("Hermes is not installed, so the lab has nobody to run. Install Hermes to use it.")
    with BOARD_LOCK:
        s = load_board(data_root)
        run_ = s["runs"].get(kind)
        if run_ and run_.get("status") == "running" and _alive(run_.get("pid")):
            raise OfficeError("Already working on it.")
        if kind == "regroup":
            home = home or home_table()
            table = clean(table, 400) or home
            if len(open_at(s, table, home)) < 2:
                raise OfficeError("Add a few tasks to this whiteboard first.")
        lab_dir = os.path.join(data_root, "lab")
        os.makedirs(lab_dir, exist_ok=True)
        base = os.path.join(lab_dir, "%s-%d" % (kind, int(now)))
        with open(base + ".prompt", "w", encoding="utf-8") as f:
            f.write(regroup_prompt(s, table, home) if kind == "regroup" else lab_prompt(kind, s))
        extra = os.environ.get("GOLDWARE_LAB_ARGS", "").split()
        argv = [binary or "hermes", "chat", "-Q", "--oneshot", "--source", "tool"] + extra + [
            "-t", cfg["toolsets"], "--max-turns", cfg["turns"], "--run-budget", cfg["budget"],
            "--query-file", base + ".prompt"]
        pid = (spawner or spawn_detached)(argv, base + ".out", base + ".err")
        s["runs"][kind] = {"status": "running", "pid": pid, "started_at": now, "base": base}
        if kind == "regroup":
            s["runs"][kind]["table"] = table
        save_board(data_root, s)
        return s["runs"][kind]


def parse_lab(kind, text):
    m = re.search(r"\{.*\}", text or "", re.S)
    try:
        data = json.loads(m.group(0)) if m else None
    except ValueError:
        data = None
    if not isinstance(data, dict):
        return []
    cards = []
    if kind == "brainstorm":
        for i in data.get("ideas") or []:
            if isinstance(i, dict):
                cards.append({"title": clean(i.get("title"), 90), "why": clean(i.get("why"), 300)})
    else:
        for i in data.get("suggestions") or []:
            if not isinstance(i, dict):
                continue
            url = str(i.get("source_url") or "")
            cards.append({"title": clean(i.get("title"), 90), "advice": clean(i.get("advice"), 500),
                          "source_title": clean(i.get("source_title"), 120),
                          "source_url": url[:500] if re.fullmatch(r'https?://[^\s"<>]+', url) else None})
    return [c for c in cards if c["title"]][:6]


def settle_runs(state, now):
    """Finished lab runs post their cards. True when something changed."""
    changed = False
    for kind, run_ in state["runs"].items():
        if run_.get("status") != "running":
            continue
        budget = int(LAB.get(kind, {}).get("budget", 300))
        if _alive(run_.get("pid")) and now - float(run_.get("started_at") or 0) < budget + 60:
            continue
        try:
            with open(run_["base"] + ".out", "r", encoding="utf-8", errors="replace") as f:
                text = f.read()
        except Exception:
            text = ""
        if kind == "regroup":
            table = str(run_.get("table") or "")
            ids = [t["id"] for t in open_at(state, table, home_table())]
            groups = parse_regroup(text, ids)
            if not groups:
                run_.update({"status": "failed", "ended_at": now, "error": "The regroup came back without anything usable."})
            else:
                state.setdefault("groupings", {})[table] = {"at": now, "groups": groups}
                run_.update({"status": "done", "ended_at": now, "count": len(groups)})
            changed = True
            continue
        cards = parse_lab(kind, text)
        if not cards:
            run_.update({"status": "failed", "ended_at": now, "error": "It came back without anything usable."})
        else:
            lst = "ideas" if kind == "brainstorm" else "suggestions"
            for c in cards:
                c.update({"id": lst[0] + uuid.uuid4().hex[:10], "at": now, "new": True})
            state[lst] = (cards + state[lst])[:BOARD_MAX[lst]]
            run_.update({"status": "done", "ended_at": now, "count": len(cards)})
        changed = True
    return changed


def board_action(data_root, body, **kw):
    """One board edit. Returns {ok, result, board}. Assigning types into an agent's terminal."""
    if not isinstance(body, dict):
        raise OfficeError("Body must be a JSON object.")
    action = body.get("action")
    now = time.time()
    result = True
    if action == "project":
        with BOARD_LOCK:
            s = load_board(data_root)
            s["project"] = {"name": clean(body.get("name"), 80), "about": clean(body.get("about"), 400)}
            save_board(data_root, s)
    elif action == "add":
        title = clean(body.get("title"), 140)
        if not title:
            raise OfficeError("A task needs a title.")
        with BOARD_LOCK:
            s = load_board(data_root)
            if len(s["tasks"]) >= BOARD_MAX["tasks"]:
                raise OfficeError("The task board is full.")
            frm = body.get("from")
            result = {"id": "t" + uuid.uuid4().hex[:10], "title": title, "notes": clean(body.get("notes"), 600),
                      "status": "todo", "agent": None, "agent_title": None,
                      "from": frm if isinstance(frm, str) and len(frm) <= 40 else None, "created_at": now}
            group = clean(body.get("group"), 400)
            if group:
                result["group"] = group
            s["tasks"].append(result)
            save_board(data_root, s)
    elif action == "assign":
        result = _assign(data_root, body, **kw)
    elif action in ("done", "reopen"):
        with BOARD_LOCK:
            s = load_board(data_root)
            t = _find(s, "tasks", body.get("id"))
            if action == "done":
                if t.get("status") != "done":
                    t["status"] = "done"
                    t["done_at"] = now
            else:
                t["status"] = "assigned" if t.get("agent") else "todo"
                t.pop("done_at", None)
            save_board(data_root, s)
            result = t
    elif action == "remove":
        lst = str(body.get("list"))
        if lst not in BOARD_MAX:
            raise OfficeError("Unknown board.")
        with BOARD_LOCK:
            s = load_board(data_root)
            s[lst] = [x for x in s[lst] if x.get("id") != str(body.get("id"))]
            save_board(data_root, s)
    elif action == "lab":
        if body.get("kind") == "regroup":
            raise OfficeError("Unknown lab job.")
        result = start_lab(data_root, str(body.get("kind")))
    elif action == "regroup":
        result = start_lab(data_root, "regroup", table=str(body.get("table") or ""))
    elif action == "ungroup":
        with BOARD_LOCK:
            s = load_board(data_root)
            s.setdefault("groupings", {}).pop(clean(body.get("table"), 400), None)
            save_board(data_root, s)
    elif action == "seen":
        lst = "ideas" if body.get("list") == "ideas" else "suggestions"
        with BOARD_LOCK:
            s = load_board(data_root)
            for c in s[lst]:
                c.pop("new", None)
            save_board(data_root, s)
    else:
        raise OfficeError("Unknown action.")
    return {"ok": True, "result": result, "board": board_view(data_root)}


def table_agents(agents, task):
    """The agents at a task's table. Desks group by working folder; a task with no table belongs to
    the home folder's table (tasks from before the tables)."""
    home = os.path.expanduser("~")
    want = task.get("group") or home
    return [a for a in agents if (a.get("cwd") or home) == want]


def _assign(data_root, body, agents=None, sender=None, **kw):
    s = load_board(data_root)
    task = _find(s, "tasks", body.get("id"))
    if agents is None:
        agents = snapshot(**kw)["agents"]
    want = str(body.get("agent") or "auto")
    agent = pick_agent(table_agents(agents, task), s["tasks"]) if want == "auto" else next(
        (a for a in agents if a["id"] == want and a.get("tty")), None)
    if not agent:
        raise OfficeError("Nobody at this table is at a terminal to take it." if want == "auto" else "Nobody is at a terminal to take it.")
    line = prepare_text(task_message(task, s["project"]), agent["kind"])
    if not (sender or send_text)(agent["tty"], line):
        raise OfficeError("Its terminal window is closed.")
    with BOARD_LOCK:
        s = load_board(data_root)
        t = _find(s, "tasks", body.get("id"))
        t.update({"status": "assigned", "agent": agent["id"], "agent_title": agent["title"], "assigned_at": time.time()})
        save_board(data_root, s)
        return t


# ---------- plan usage ----------

USAGE_CACHE_FOR = 120
_USAGE_LOCK = threading.Lock()
_USAGE = {"at": 0, "plans": None}


def parse_claude(body):
    try:
        d = json.loads(body)
    except ValueError:
        return None
    if not isinstance(d, dict):
        return None
    wins = []
    for label, key in (("5H", "five_hour"), ("WEEK", "seven_day")):
        w = d.get(key)
        if isinstance(w, dict) and isinstance(w.get("utilization"), (int, float)) and not isinstance(w["utilization"], bool):
            wins.append({"label": label, "percent": round(float(w["utilization"]), 1),
                         "resets_at": _parse_ts(w.get("resets_at"))})
    return wins or None


def parse_codex(body):
    try:
        d = json.loads(body)
    except ValueError:
        return None
    rl = d.get("rate_limit") if isinstance(d, dict) else None
    if not isinstance(rl, dict):
        return None
    wins = []
    for w in (rl.get("primary_window"), rl.get("secondary_window")):
        if isinstance(w, dict) and isinstance(w.get("used_percent"), (int, float)):
            secs = int(w.get("limit_window_seconds") or 0)
            label = "WEEK" if secs >= 86400 * 2 else "%dH" % round(secs / 3600.0) if secs > 0 else "LIMIT"
            ra = w.get("reset_at")
            wins.append({"label": label, "percent": round(float(w["used_percent"]), 1),
                         "resets_at": float(ra) if isinstance(ra, (int, float)) else None})
    wins.sort(key=lambda w: 1 if w["label"] == "WEEK" else 0)
    return wins or None


def _http_get(url, headers):
    req = urllib.request.Request(url, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            return r.status, r.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        return e.code, ""


def plan(pid, name, windows, error):
    top = max(windows, key=lambda w: w["percent"]) if windows else None
    outs = [w for w in (windows or []) if w["percent"] >= 100]
    out = max(outs, key=lambda w: w.get("resets_at") or 0) if outs else None
    return {"id": pid, "name": name, "windows": windows or [], "error": None if windows else error,
            "out": out is not None, "back_at": out.get("resets_at") if out else None,
            "top": top["percent"] if top else None}


def _claude_token():
    try:
        with open(os.path.join(claude_home(), ".credentials.json"), "r", encoding="utf-8") as f:
            return (json.load(f).get("claudeAiOauth") or {}).get("accessToken")
    except Exception:
        pass
    raw = run(["/usr/bin/security", "find-generic-password", "-s", "Claude Code-credentials", "-w"], timeout=4)
    try:
        return (json.loads(raw).get("claudeAiOauth") or {}).get("accessToken")
    except Exception:
        return None


def claude_plan():
    token = _claude_token()
    if not token:
        return plan("claude", "Claude", None, "Not signed in to Claude Code")
    try:
        code, body = _http_get("https://api.anthropic.com/api/oauth/usage",
                               {"Authorization": "Bearer " + token, "anthropic-beta": "oauth-2025-04-20",
                                "User-Agent": "claude-code/2.1"})
    except Exception:
        return plan("claude", "Claude", None, "Couldn't reach Claude")
    if code in (401, 403):
        return plan("claude", "Claude", None, "Sign-in expired, open claude once")
    return plan("claude", "Claude", parse_claude(body) if code == 200 else None, "Couldn't read usage")


def codex_plan():
    try:
        with open(os.path.join(codex_home(), "auth.json"), "r", encoding="utf-8") as f:
            tokens = json.load(f).get("tokens") or {}
    except Exception:
        tokens = {}
    if not tokens.get("access_token"):
        return plan("codex", "Codex", None, "Not signed in to Codex")
    headers = {"Authorization": "Bearer " + tokens["access_token"], "User-Agent": "codex_cli_rs"}
    if tokens.get("account_id"):
        headers["ChatGPT-Account-Id"] = str(tokens["account_id"])
    try:
        code, body = _http_get("https://chatgpt.com/backend-api/wham/usage", headers)
    except Exception:
        return plan("codex", "Codex", None, "Couldn't reach Codex")
    if code in (401, 403):
        return plan("codex", "Codex", None, "Sign-in expired, open codex once")
    return plan("codex", "Codex", parse_codex(body) if code == 200 else None, "Couldn't read usage")


def hourly(now, home=None):
    """Tokens per hour for the last 24 hours by plan, from Hermes's own usage records (empty without it)."""
    since = int(now - 24 * 3600)
    rows = sqlite_rows(os.path.join(home or hermes_home(), "state.db"), """
        SELECT CAST((coalesce(last_seen, first_seen) - ?) / 3600 AS INTEGER) AS slot, billing_provider AS provider,
               sum(input_tokens + output_tokens + cache_write_tokens) AS tokens
        FROM session_model_usage WHERE coalesce(last_seen, first_seen) >= ? GROUP BY slot, provider""", [since, since])
    out = []
    for i in range(24):
        slot = [r for r in rows if int(r["slot"] or 0) == i]

        def pick(rx):
            return sum(int(r["tokens"] or 0) for r in slot if re.search(rx, str(r["provider"] or "")))
        total = sum(int(r["tokens"] or 0) for r in slot)
        out.append({"at": since + i * 3600, "claude": pick("anthropic"), "codex": pick("codex|openai"),
                    "other": total - pick("anthropic|codex|openai")})
    return out


def usage_snapshot(now=None, fetcher=None, home=None):
    now = time.time() if now is None else now
    if forced_empty() and fetcher is None:
        return {"plans": [], "hours": [], "checked_at": now}
    with _USAGE_LOCK:
        if _USAGE["plans"] is None or now - _USAGE["at"] > USAGE_CACHE_FOR:
            _USAGE["plans"] = fetcher() if fetcher else [claude_plan(), codex_plan()]
            _USAGE["at"] = now
        plans, at = _USAGE["plans"], _USAGE["at"]
    return {"plans": plans, "hours": hourly(now, home), "checked_at": at}


def reset_usage_cache():
    with _USAGE_LOCK:
        _USAGE["plans"] = None
        _USAGE["at"] = 0
