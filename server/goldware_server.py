#!/usr/bin/env python3
"""GoldWare OS local server. Python 3.9 stdlib only, binds 127.0.0.1."""
import argparse
import copy
import datetime
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, unquote, urlparse

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import office  # noqa: E402  (the Office tab: agents at desks, console, board, usage)
import office_launch  # noqa: E402  (the New agent button and its topics and presets)
import office_boss  # noqa: E402  (the boss at the front desk: runs the other agents when asked)

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.environ.get("GOLDWARE_ROOT") or os.path.dirname(HERE))
DATA_ROOT = os.path.abspath(os.environ.get("GOLDWARE_DATA_ROOT") or os.path.join(ROOT, "data"))
# Static assets live next to the code, not in a test-only root copy.
CODE_ROOT = os.path.dirname(HERE)
DEFAULT_PORT = 4188
CARD_TYPES = ["welcome", "clock", "tasks", "notes", "links", "shortcuts", "system", "agents", "embed", "html"]
CARD_SIZES = ["s", "m", "l", "w"]
STATUSES = ["inbox", "ready", "doing", "done", "dropped"]
TASK_FIELDS = ["title", "context", "status", "due_on", "priority", "focus_on"]
# Re-entrant: readers and writers of the data files all take it.
LOCK = threading.RLock()
MAX_BODY = 1024 * 1024          # request bodies above this get 413
MAX_CARDS = 100
MAX_HTML = 200 * 1024           # options.html per card
MAX_TASKS = 10000
MAX_NOTES = 200
MAX_NOTE_TEXT = 200 * 1024
VERBOSE = os.environ.get("GOLDWARE_VERBOSE") == "1"

CONTENT_TYPES = {
    ".html": "text/html; charset=utf-8",
    ".css": "text/css; charset=utf-8",
    ".js": "application/javascript; charset=utf-8",
    ".json": "application/json; charset=utf-8",
    ".png": "image/png",
    ".ttf": "font/ttf",
    ".svg": "image/svg+xml",
    ".md": "text/plain; charset=utf-8",
    ".txt": "text/plain; charset=utf-8",
}


# ---------- config ----------

def default_path():
    return os.path.join(ROOT, "goldware.default.json")


def user_path():
    return os.path.join(ROOT, "goldware.json")


def _bad_url(u):
    """Card and link URLs: http(s) or a same-site path. No javascript:, data:, or //host."""
    return not isinstance(u, str) or len(u) > 2000 or not re.match(r"^(https?://|/(?!/))", u.strip(), re.I)


def validate_config(cfg):
    """Return None when valid, else a human message naming the field."""
    if not isinstance(cfg, dict):
        return "Config must be a JSON object."
    name = cfg.get("assistantName")
    if not isinstance(name, str) or not 1 <= len(name) <= 24:
        return "assistantName must be text between 1 and 24 characters."
    color = cfg.get("accentColor")
    if not isinstance(color, str) or not re.match(r"^#[0-9A-Fa-f]{6}$", color):
        return "accentColor must look like #RRGGBB, for example #C9A24A."
    if "port" in cfg:
        port = cfg["port"]
        if isinstance(port, bool) or not isinstance(port, int) or not 1024 <= port <= 65535:
            return "port must be a whole number between 1024 and 65535."
        if port == 4177:
            return "port must not be 4177, it is reserved."
    if "wakePhrase" in cfg and (not isinstance(cfg["wakePhrase"], str) or not 1 <= len(cfg["wakePhrase"].strip()) <= 100):
        return "wakePhrase must be text between 1 and 100 characters."
    if "wakeAliases" in cfg:
        al = cfg["wakeAliases"]
        if (not isinstance(al, list) or len(al) > 50
                or not all(isinstance(a, str) and len(a) <= 100 for a in al)):
            return "wakeAliases must be a list of up to 50 text values, each up to 100 characters."
    if "letsWork" in cfg:
        lw = cfg["letsWork"]
        if not isinstance(lw, dict):
            return "letsWork must be an object."
        cmd = lw.get("command", "")
        if not isinstance(cmd, str) or len(cmd) > 500 or re.search(r"[\r\n\x00]", cmd):
            return "letsWork.command must be one line of text up to 500 characters."
        if lw.get("terminal", "iTerm") != "iTerm":
            return "letsWork.terminal must be \"iTerm\"."
        prof = lw.get("profile", "")
        if not isinstance(prof, str) or len(prof) > 100 or re.search(r"[\r\n\x00]", prof):
            return "letsWork.profile must be text up to 100 characters."
    if "models" in cfg:
        models = cfg["models"]
        if not isinstance(models, dict):
            return "models must be an object."
        for k in ("local", "whisper"):
            v = models.get(k)
            if v is not None and (not isinstance(v, str) or not 1 <= len(v) <= 200):
                return "models.%s must be text up to 200 characters." % k
        w = models.get("whisper")
        if isinstance(w, str) and (re.search(r"[/\\\x00]", w) or ".." in w):
            return "models.whisper must be a file name, not a path."
        ka = models.get("keepAlive")
        if ka is not None and (not isinstance(ka, str) or not re.match(r"^-?[0-9]+[smh]?$", ka)):
            return "models.keepAlive must be text like \"5m\", \"0\" or \"-1\"."
    oerr = office_launch.validate_shape(cfg.get("office"))
    if oerr:
        return oerr
    dash = cfg.get("dashboard")
    if dash is not None:
        if not isinstance(dash, dict):
            return "dashboard must be an object."
        if "layout" in dash and (not isinstance(dash["layout"], str) or len(dash["layout"]) > 64):
            return "dashboard.layout must be text up to 64 characters."
        cards = dash.get("cards", [])
        if not isinstance(cards, list):
            return "dashboard.cards must be a list."
        if len(cards) > MAX_CARDS:
            return "dashboard.cards can hold at most %d cards." % MAX_CARDS
        seen = set()
        for i, card in enumerate(cards):
            where = "dashboard.cards[%d]" % i
            if not isinstance(card, dict):
                return where + " must be an object."
            cid = card.get("id")
            if not isinstance(cid, str) or not re.match(r"^[A-Za-z0-9_-]{1,64}$", cid):
                return where + ".id must be a slug of 1 to 64 letters, digits, dashes or underscores."
            if cid in seen:
                return where + ".id \"%s\" is used by more than one card." % cid
            seen.add(cid)
            if card.get("type") not in CARD_TYPES:
                return where + ".type must be one of: " + ", ".join(CARD_TYPES) + "."
            if card.get("size") not in CARD_SIZES:
                return where + ".size must be one of: s, m, l, w."
            if "title" in card and (not isinstance(card["title"], str) or len(card["title"]) > 100):
                return where + ".title must be text up to 100 characters."
            if "options" in card:
                opts = card["options"]
                if not isinstance(opts, dict):
                    return where + ".options must be an object."
                if "html" in opts and (not isinstance(opts["html"], str) or len(opts["html"]) > MAX_HTML):
                    return where + ".options.html must be text up to %d characters." % MAX_HTML
                if "url" in opts and opts["url"] not in (None, "") and _bad_url(opts["url"]):
                    return where + ".options.url must start with http://, https://, or /."
                if "links" in opts:
                    links = opts["links"]
                    if not isinstance(links, list) or len(links) > 50:
                        return where + ".options.links must be a list of up to 50 links."
                    for j, l in enumerate(links):
                        if (not isinstance(l, dict) or not isinstance(l.get("label"), str)
                                or len(l["label"]) > 100 or _bad_url(l.get("url"))):
                            return where + ".options.links[%d] needs a label and an http(s) or / url." % j
    return None


def _no_constants(name):
    raise ValueError("%s is not valid JSON" % name)


def parse_json(text):
    """json.loads that rejects NaN and Infinity, which the browser cannot parse back."""
    return json.loads(text, parse_constant=_no_constants)


def read_json(path):
    with open(path, "r", encoding="utf-8") as f:
        return parse_json(f.read())


def load_config():
    """Return (config, source, error)."""
    try:
        default = read_json(default_path())
    except Exception as e:
        default = {}
        default_err = "goldware.default.json could not be read: %s" % e
    else:
        default_err = None
        verr = validate_config(default)
        if verr:
            default_err = "goldware.default.json is invalid: %s" % verr
    up = user_path()
    if not os.path.exists(up):
        return default, "default", default_err
    try:
        cfg = read_json(up)
    except Exception as e:
        return default, "default", "goldware.json is not valid JSON (%s). Using defaults." % e
    err = validate_config(cfg)
    if err:
        return default, "default", "goldware.json is invalid: %s Using defaults." % err
    return cfg, "goldware.json", None


def config_port():
    cfg, _, _ = load_config()
    p = cfg.get("port", DEFAULT_PORT) if isinstance(cfg, dict) else DEFAULT_PORT
    return p if isinstance(p, int) and not isinstance(p, bool) else DEFAULT_PORT


def atomic_write(path, text):
    d = os.path.dirname(path)
    os.makedirs(d, exist_ok=True)
    # Unique temp file in the same folder, so concurrent writers never share one.
    fd, tmp = tempfile.mkstemp(prefix=os.path.basename(path) + ".", suffix=".tmp", dir=d)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(text)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def save_config(cfg):
    up = user_path()
    if os.path.exists(up):
        shutil.copyfile(up, up + ".bak")
    atomic_write(up, json.dumps(cfg, indent=2) + "\n")


# ---------- work ----------

def data_path(name):
    return os.path.join(DATA_ROOT, name)


def log(msg):
    sys.stderr.write("goldware: %s\n" % msg)
    sys.stderr.flush()


def quarantine(name, why):
    """Move a damaged data file aside so the next write starts fresh without destroying it."""
    src = data_path(name)
    dst = "%s.corrupt-%s" % (src, time.strftime("%Y%m%d-%H%M%S"))
    n = 0
    while os.path.exists(dst):
        n += 1
        dst = "%s.corrupt-%s-%d" % (src, time.strftime("%Y%m%d-%H%M%S"), n)
    try:
        os.replace(src, dst)
        log("%s is unusable (%s). Saved it as %s and starting fresh." % (name, why, os.path.basename(dst)))
    except OSError as e:
        log("%s is unusable (%s) and could not be moved aside: %s" % (name, why, e))


def load_data(name, fallback):
    with LOCK:
        path = data_path(name)
        if not os.path.exists(path):
            return fallback
        try:
            return read_json(path)
        except Exception as e:
            quarantine(name, "not valid JSON: %s" % e)
            return fallback


def revision_of(task):
    body = {k: v for k, v in task.items() if k != "revision"}
    canon = json.dumps(body, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
    return hashlib.sha256(canon.encode("utf-8")).hexdigest()[:12]


def today_str():
    return datetime.date.today().isoformat()


def stored_tasks():
    data = load_data("tasks.json", {"tasks": []})
    tasks = data.get("tasks") if isinstance(data, dict) else None
    if not isinstance(tasks, list) or not all(isinstance(t, dict) for t in tasks):
        if os.path.exists(data_path("tasks.json")):
            quarantine("tasks.json", "unexpected structure")
        return []
    return tasks


def with_revision(task):
    t = {k: task.get(k) for k in ["id"] + TASK_FIELDS}
    if t["context"] is None:
        t["context"] = ""
    t["revision"] = revision_of(t)
    return t


def save_tasks(tasks):
    clean = [{k: t.get(k) for k in ["id"] + TASK_FIELDS} for t in tasks]
    atomic_write(data_path("tasks.json"), json.dumps({"tasks": clean}, indent=2) + "\n")


def check_changes(changes, creating):
    """Return (clean, error)."""
    if not isinstance(changes, dict):
        return None, "changes must be an object."
    clean = {}
    for k, v in changes.items():
        if k not in TASK_FIELDS:
            return None, "Unknown field: %s." % k
        if k == "title":
            if not isinstance(v, str) or not v.strip():
                return None, "title must be non-empty text."
            v = v.strip()
            if len(v) > 500:
                return None, "title must be 500 characters or fewer."
        elif k == "context":
            if v is None:
                v = ""
            if not isinstance(v, str):
                return None, "context must be text."
            if len(v) > 20000:
                return None, "context must be 20000 characters or fewer."
        elif k == "status":
            if v not in STATUSES:
                return None, "status must be one of: " + ", ".join(STATUSES) + "."
        elif k in ("due_on", "focus_on"):
            if v is not None and (not isinstance(v, str) or not re.match(r"^\d{4}-\d{2}-\d{2}$", v)):
                return None, "%s must be YYYY-MM-DD or null." % k
        elif k == "priority":
            if v is not None and (isinstance(v, bool) or not isinstance(v, (int, str))):
                return None, "priority must be a number, text, or null."
            if isinstance(v, str) and len(v) > 50:
                return None, "priority text must be 50 characters or fewer."
        clean[k] = v
    if creating and "title" not in clean:
        return None, "title is required."
    return clean, None


def work_get():
    with LOCK:
        stored = stored_tasks()
    tasks = [with_revision(t) for t in stored]
    return 200, {"today": today_str(), "tasks": tasks}


def work_post(body):
    if not isinstance(body, dict):
        return 400, {"error": "Body must be a JSON object."}
    with LOCK:
        tasks = stored_tasks()
        if body.get("create") is True:
            rid = body.get("request_id")
            if not isinstance(rid, str) or not 1 <= len(rid) <= 200:
                return 400, {"error": "request_id is required to create a task (text up to 200 characters)."}
            changes, err = check_changes(body.get("changes"), True)
            if err:
                return 400, {"error": err}
            tid = "t-" + hashlib.sha256(rid.encode("utf-8")).hexdigest()[:12]
            for t in tasks:
                if t.get("id") == tid:
                    return 200, {"task": with_revision(t), "created": False}
            if len(tasks) >= MAX_TASKS:
                return 400, {"error": "Too many tasks (limit %d)." % MAX_TASKS}
            task = {"id": tid, "title": "", "status": "inbox", "context": "",
                    "due_on": None, "priority": None, "focus_on": None}
            task.update(changes)
            tasks.append(task)
            save_tasks(tasks)
            return 200, {"task": with_revision(task), "created": True}
        tid = body.get("id")
        if not isinstance(tid, str) or not tid:
            return 400, {"error": "id is required to update a task."}
        changes, err = check_changes(body.get("changes"), False)
        if err:
            return 400, {"error": err}
        based_on = body.get("based_on")
        if not isinstance(based_on, str) or not based_on:
            return 400, {"error": "based_on (the task revision) is required."}
        for t in tasks:
            if t.get("id") == tid:
                if with_revision(t)["revision"] != based_on:
                    return 409, {"error": "That task changed since you loaded it. Reload and try again."}
                t.update(changes)
                save_tasks(tasks)
                return 200, {"task": with_revision(t), "created": False}
        return 404, {"error": "No task with that id."}


# ---------- notes ----------

def notes_get():
    with LOCK:
        return _notes_get()


def _notes_get():
    data = load_data("notes.json", {"notes": {}})
    notes = data.get("notes") if isinstance(data, dict) else None
    if not isinstance(notes, dict) or not all(isinstance(v, str) for v in notes.values()):
        if os.path.exists(data_path("notes.json")):
            quarantine("notes.json", "unexpected structure")
        return {}
    return notes


def notes_post(body):
    if not isinstance(body, dict):
        return 400, {"error": "Body must be a JSON object."}
    cid, text = body.get("cardId"), body.get("text")
    if not isinstance(cid, str) or not 1 <= len(cid) <= 100:
        return 400, {"error": "cardId must be non-empty text up to 100 characters."}
    if not isinstance(text, str) or len(text) > MAX_NOTE_TEXT:
        return 400, {"error": "text must be text up to %d characters." % MAX_NOTE_TEXT}
    with LOCK:
        notes = notes_get()
        if cid not in notes and len(notes) >= MAX_NOTES:
            return 400, {"error": "Too many notes (limit %d)." % MAX_NOTES}
        notes[cid] = text
        atomic_write(data_path("notes.json"), json.dumps({"notes": notes}, indent=2) + "\n")
    return 200, {"notes": notes}


# ---------- first-run tour ----------
# Progress lives in data/onboarding.json (git-ignored, so make update keeps it). The permission
# states come from the app's own status.json in its data folder; the page never sees that file.

TOUR_CHAPTERS = ["welcome", "permissions", "voice", "vision", "office", "reshape", "help"]
TOUR_STATUSES = ["new", "open", "done", "skipped"]
PERMISSION_KEYS = ["microphone", "accessibility", "speech", "camera", "calendar", "automation"]


def app_data_dir():
    env = os.environ.get("GOLDWARE_DATA")
    if env:
        return os.path.abspath(env)
    return os.path.join(os.path.expanduser("~"), "Library", "Application Support", "GoldWare OS")


def app_permissions():
    """What the app last reported, or None when it has not run (or wrote something unreadable)."""
    path = os.path.join(app_data_dir(), "status.json")
    try:
        raw = read_json(path)
    except Exception:
        return None
    if not isinstance(raw, dict):
        return None
    out = {k: raw[k] for k in PERMISSION_KEYS if isinstance(raw.get(k), str) and len(raw[k]) <= 40}
    if isinstance(raw.get("updated"), str) and len(raw["updated"]) <= 40:
        out["updated"] = raw["updated"]
    ms = raw.get("milestones")
    out["milestones"] = sorted(k for k in ms if isinstance(k, str) and re.match(r"^[a-z0-9-]{1,40}$", k))[:50] if isinstance(ms, dict) else []
    return out


def tour_state():
    data = load_data("onboarding.json", {})
    state = {"status": "new", "chapter": TOUR_CHAPTERS[0], "seen": [], "checks": [], "updated": None}
    if isinstance(data, dict):
        if data.get("status") in TOUR_STATUSES:
            state["status"] = data["status"]
        if data.get("chapter") in TOUR_CHAPTERS:
            state["chapter"] = data["chapter"]
        for k in ("seen", "checks"):
            v = data.get(k)
            if isinstance(v, list):
                state[k] = [x for x in v if isinstance(x, str) and re.match(r"^[a-z0-9-]{1,40}$", x)][:50]
        if isinstance(data.get("updated"), str):
            state["updated"] = data["updated"][:40]
    return state


def onboarding_get():
    return {"state": tour_state(), "chapters": TOUR_CHAPTERS, "permissions": app_permissions()}


def onboarding_post(body):
    """Merge one change: {status?, chapter?, seen?: [id], checks?: [id], reset?: true}."""
    if not isinstance(body, dict):
        return 400, {"error": "Body must be a JSON object."}
    with LOCK:
        state = {"status": "new", "chapter": TOUR_CHAPTERS[0], "seen": [], "checks": []} if body.get("reset") is True else tour_state()
        if "status" in body:
            if body["status"] not in TOUR_STATUSES:
                return 400, {"error": "status must be one of: " + ", ".join(TOUR_STATUSES) + "."}
            state["status"] = body["status"]
        if "chapter" in body:
            if body["chapter"] not in TOUR_CHAPTERS:
                return 400, {"error": "chapter must be one of: " + ", ".join(TOUR_CHAPTERS) + "."}
            state["chapter"] = body["chapter"]
        for k in ("seen", "checks"):
            if k in body:
                v = body[k]
                if not isinstance(v, list) or len(v) > 50 or not all(isinstance(x, str) and re.match(r"^[a-z0-9-]{1,40}$", x) for x in v):
                    return 400, {"error": "%s must be a list of short ids (lowercase letters, digits, dashes)." % k}
                for x in v:
                    if x not in state[k]:
                        state[k].append(x)
                state[k] = state[k][-50:]
        state["updated"] = datetime.datetime.now().isoformat(timespec="seconds")
        atomic_write(data_path("onboarding.json"), json.dumps(state, indent=2) + "\n")
    return 200, {"state": state}


# ---------- system and agents ----------

def run(cmd):
    return subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                          universal_newlines=True, timeout=10).stdout


def system_info():
    cpu = 0.0
    try:
        total = sum(float(x) for x in run(["ps", "-A", "-o", "%cpu"]).split()[1:])
        cpu = total / (os.cpu_count() or 1)
    except Exception:
        pass
    cpu = round(max(0.0, min(100.0, cpu)), 1)
    gb = 1024.0 ** 3
    total_mem = used_mem = 0.0
    try:
        total_b = int(run(["sysctl", "-n", "hw.memsize"]).strip())
        vm = run(["vm_stat"])
        m = re.search(r"page size of (\d+) bytes", vm)
        psize = int(m.group(1)) if m else 4096
        pages = 0
        for label in ("Pages active", "Pages wired down", "Pages occupied by compressor"):
            mm = re.search(re.escape(label) + r":\s+(\d+)", vm)
            if mm:
                pages += int(mm.group(1))
        total_mem = total_b / gb
        used_mem = min(pages * psize, total_b) / gb
    except Exception:
        pass
    du = shutil.disk_usage("/")
    return {"cpu_percent": cpu,
            "memory": {"used_gb": round(used_mem, 2), "total_gb": round(total_mem, 2)},
            "disk": {"free_gb": round(du.free / gb, 2), "total_gb": round(du.total / gb, 2)}}


AGENT_KINDS = ["ollama", "whisper-server", "hermes", "claude", "codex"]


def agents_info():
    out = []
    try:
        lines = run(["ps", "-axo", "pid,rss,comm"]).splitlines()[1:]
    except Exception:
        return out
    for line in lines:
        parts = line.strip().split(None, 2)
        if len(parts) < 3:
            continue
        try:
            pid, rss = int(parts[0]), int(parts[1])
        except ValueError:
            continue
        base = os.path.basename(parts[2]).lower()
        for kind in AGENT_KINDS:
            if kind in base:
                out.append({"name": os.path.basename(parts[2]), "kind": kind,
                            "pid": pid, "memory_mb": round(rss / 1024.0, 1)})
                break
    return out


# ---------- http ----------

PLACEHOLDER = (b"<!doctype html><meta charset=utf-8><title>GoldWare OS</title>"
               b"<body style='background:#0d0c0a;color:#f1ead8;font-family:sans-serif;padding:3rem'>"
               b"<h1>GoldWare OS</h1><p>The dashboard file (dashboard/index.html) is missing.</p></body>")


def safe_join(base, rel):
    """Resolve rel under base. None for NUL bytes, backslashes, or anything that escapes
    base once symlinks are resolved."""
    if "\x00" in rel or "\\" in rel:
        return None
    base = os.path.realpath(base)
    try:
        full = os.path.realpath(os.path.join(base, rel))
    except (ValueError, OSError):
        return None
    if full != base and not full.startswith(base + os.sep):
        return None
    return full


class Handler(BaseHTTPRequestHandler):
    server_version = "GoldWareOS"
    protocol_version = "HTTP/1.1"
    timeout = 30  # drop stalled or slow-loris connections

    def log_message(self, fmt, *args):
        if VERBOSE:
            sys.stderr.write("%s %s\n" % (self.address_string(), fmt % args))

    def send(self, code, body, ctype, nostore=False):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        if nostore:
            self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Content-Security-Policy", "frame-ancestors 'self'")
        if self.close_connection:
            self.send_header("Connection", "close")
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def send_json(self, code, obj):
        self.send(code, json.dumps(obj).encode("utf-8"), "application/json; charset=utf-8", True)

    def err(self, code, msg):
        self.send_json(code, {"error": msg})

    def serve_file(self, base, rel, force_text=False):
        full = safe_join(base, unquote(rel))
        if full is None or not os.path.isfile(full):
            return self.err(404, "Not found.")
        ext = os.path.splitext(full)[1].lower()
        ctype = "text/plain; charset=utf-8" if force_text else CONTENT_TYPES.get(ext, "application/octet-stream")
        with open(full, "rb") as f:
            self.send(200, f.read(), ctype)

    def host_ok(self):
        """DNS rebinding guard: only our own loopback names, with our port, are accepted."""
        host = (self.headers.get("Host") or "").strip().lower()
        port = self.server.server_address[1]
        return host in ("127.0.0.1:%d" % port, "localhost:%d" % port)

    def origin_ok(self):
        origin = self.headers.get("Origin")
        if origin is None:
            return True
        port = self.server.server_address[1]
        return origin in ("http://127.0.0.1:%d" % port, "http://localhost:%d" % port)

    def guard(self):
        """Common checks for every request. Returns True when the request may proceed."""
        if not self.host_ok():
            self.close_connection = True
            self.err(403, "Unexpected Host header.")
            return False
        if not self.origin_ok():
            self.close_connection = True
            self.err(403, "Requests from other origins are not allowed.")
            return False
        return True

    def same_origin_post(self):
        """Office POSTs can type into the user's terminals, so they must come from this page:
        an Origin (or, failing that, a Referer) naming our own loopback address, and no
        cross-site Sec-Fetch-Site. A request with neither header is refused."""
        port = self.server.server_address[1]
        own = ("http://127.0.0.1:%d" % port, "http://localhost:%d" % port)
        site = self.headers.get("Sec-Fetch-Site")
        if site is not None and site not in ("same-origin", "none"):
            return False
        origin = self.headers.get("Origin")
        if origin is not None:
            return origin in own
        ref = self.headers.get("Referer")
        return bool(ref) and any(ref == o or ref.startswith(o + "/") for o in own)

    def terminal_profile(self):
        try:
            cfg, _source, _error = load_config()
            prof = (cfg.get("letsWork") or {}).get("profile")
            return prof if isinstance(prof, str) and prof else None
        except Exception:
            return None

    def office_get(self, path, query):
        """Read-only Office endpoints. Nothing here types into a terminal."""
        q = lambda k: (query.get(k) or [""])[0]
        try:
            if path == "/api/office/agents":
                snap = office.snapshot(data_root=DATA_ROOT)
                # Table names: a table in one of your topic folders is named after the topic.
                topics, _presets = office_launch.effective(default_path(), user_path())
                snap["topics"] = [{"label": str(t.get("label", "")), "path": os.path.realpath(os.path.expanduser(str(t.get("dir", ""))))}
                                  for t in topics]
                return self.send_json(200, snap)
            if path == "/api/office/screen":
                return self.send_json(200, office.screen_of_agent(q("id")))
            if path == "/api/office/helper":
                detail = office.helper_detail(q("id"))
                if detail is None:
                    return self.err(404, "That helper has finished.")
                return self.send_json(200, detail)
            if path == "/api/office/board":
                return self.send_json(200, office.board_view(DATA_ROOT))
            if path == "/api/office/usage":
                return self.send_json(200, office.usage_snapshot())
            if path == "/api/office/chat":
                return self.send_json(200, office.chat_of_agent(q("id"), data_root=DATA_ROOT))
            if path == "/api/office/settings":
                return self.send_json(200, office_launch.view(default_path(), user_path()))
            return self.err(404, "Not found.")
        except office.OfficeError as e:
            return self.err(e.status, str(e))
        except office.TerminalError as e:
            return self.err(503, str(e))

    def office_post(self, path, body):
        if not self.same_origin_post():
            return self.err(403, "Office actions only work from the dashboard itself.")
        try:
            if path == "/api/office/send":
                return self.send_json(200, office.send_to_agent(body))
            if path == "/api/office/focus":
                return self.send_json(200, office.focus_agent(body))
            if path == "/api/office/dismiss":
                return self.send_json(200, office.dismiss_agent(body))
            if path == "/api/office/board":
                return self.send_json(200, office.board_action(DATA_ROOT, body))
            if path == "/api/office/new":
                return self.send_json(200, office_launch.new_agent(body, default_path(), user_path(), self.terminal_profile()))
            if path == "/api/office/settings":
                with LOCK:
                    return self.send_json(200, office_launch.save(body, default_path(), user_path()))
            if path == "/api/office/choose-folder":
                return self.send_json(200, office_launch.choose_folder())
            if path == "/api/office/boss":
                return self.send_json(200, office_boss.ask(body, DATA_ROOT, ROOT, self.terminal_profile()))
            if path == "/api/office/report":
                return self.send_json(200, office_boss.report(body, DATA_ROOT, ROOT, self.terminal_profile()))
            return self.err(404, "Not found.")
        except office.OfficeError as e:
            return self.err(e.status, str(e))
        except office.TerminalError as e:
            return self.err(503, str(e))

    def do_GET(self):
        if not self.guard():
            return
        path = urlparse(self.path).path
        try:
            if path == "/":
                full = os.path.join(CODE_ROOT, "dashboard", "index.html")
                if os.path.isfile(full):
                    with open(full, "rb") as f:
                        return self.send(200, f.read(), CONTENT_TYPES[".html"], True)
                return self.send(200, PLACEHOLDER, CONTENT_TYPES[".html"], True)
            if path == "/api/config":
                if "default=1" in (urlparse(self.path).query or "").split("&"):
                    try:
                        return self.send_json(200, {"config": read_json(default_path()), "source": "default", "error": None})
                    except Exception as e:
                        return self.err(500, "goldware.default.json could not be read: %s" % e)
                cfg, source, error = load_config()
                return self.send_json(200, {"config": cfg, "source": source, "error": error})
            if path == "/api/work":
                code, obj = work_get()
                return self.send_json(code, obj)
            if path == "/api/notes":
                return self.send_json(200, {"notes": notes_get()})
            if path == "/api/system":
                return self.send_json(200, system_info())
            if path == "/api/agents":
                return self.send_json(200, agents_info())
            if path == "/api/onboarding":
                return self.send_json(200, onboarding_get())
            if path.startswith("/api/office/"):
                return self.office_get(path, parse_qs(urlparse(self.path).query))
            if path.startswith("/api/"):
                return self.err(404, "Not found.")
            if path in ("/custom/office.css", "/custom/office-cast.js"):
                # Your own look for the Office and its characters. Lives in custom/ (git-ignored), so
                # updates keep it. Only these two files are served from that folder.
                name = path[len("/custom/"):]
                ctype = CONTENT_TYPES[os.path.splitext(name)[1]]
                full = safe_join(os.path.join(ROOT, "custom"), name)
                if full is None or not os.path.isfile(full):
                    return self.send(404, b"", ctype)
                with open(full, "rb") as f:
                    return self.send(200, f.read(), ctype, True)
            if path.startswith("/dashboard/"):
                return self.serve_file(os.path.join(CODE_ROOT, "dashboard"), path[len("/dashboard/"):])
            if path.startswith("/fonts/"):
                return self.serve_file(os.path.join(CODE_ROOT, "app", "Resources", "Fonts"), path[len("/fonts/"):])
            if path == "/logo.png":
                return self.serve_file(os.path.join(CODE_ROOT, "app", "Resources"), "goldware-logo.png")
            if path.startswith("/docs/"):
                return self.serve_file(os.path.join(CODE_ROOT, "docs"), path[len("/docs/"):], True)
            return self.err(404, "Not found.")
        except Exception as e:
            log("GET %s failed: %r" % (path, e))
            return self.err(500, "Server error.")

    do_HEAD = do_GET

    def do_POST(self):
        if not self.guard():
            return
        path = urlparse(self.path).path
        try:
            # A cross-site HTML form can only send text/plain, form-encoded or multipart,
            # so requiring JSON blocks simple cross-site posts even without an Origin header.
            ctype = (self.headers.get("Content-Type") or "").split(";")[0].strip().lower()
            if ctype != "application/json":
                self.close_connection = True
                return self.err(415, "Content-Type must be application/json.")
            if self.headers.get("Transfer-Encoding"):
                self.close_connection = True
                return self.err(411, "Send a Content-Length, chunked bodies are not supported.")
            try:
                length = int(self.headers.get("Content-Length") or 0)
            except ValueError:
                length = -1
            if length < 0:
                self.close_connection = True
                return self.err(400, "Invalid Content-Length.")
            if length > MAX_BODY:
                self.close_connection = True  # the unread body must not be parsed as a new request
                return self.err(413, "Body too large (limit %d bytes)." % MAX_BODY)
            raw = self.rfile.read(length) if length else b""
            try:
                body = parse_json(raw.decode("utf-8"))
            except Exception:
                return self.err(400, "Body must be valid JSON.")
            if path == "/api/config":
                err = validate_config(body)
                if err:
                    return self.err(400, err)
                with LOCK:
                    save_config(body)
                return self.send_json(200, {"config": body})
            if path == "/api/work":
                code, obj = work_post(body)
                return self.send_json(code, obj)
            if path == "/api/notes":
                code, obj = notes_post(body)
                return self.send_json(code, obj)
            if path == "/api/onboarding":
                code, obj = onboarding_post(body)
                return self.send_json(code, obj)
            if path.startswith("/api/office/"):
                return self.office_post(path, body)
            return self.err(404, "Not found.")
        except Exception as e:
            log("POST %s failed: %r" % (path, e))
            return self.err(500, "Server error.")


def make_server(port):
    """Bind loopback only, whatever the environment says."""
    httpd = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    httpd.daemon_threads = True
    return httpd


def main(argv=None):
    ap = argparse.ArgumentParser(description="GoldWare OS local server")
    ap.add_argument("--port", type=int)
    ap.add_argument("--check", action="store_true", help="validate config and exit")
    args = ap.parse_args(argv)
    if args.check:
        cfg, source, error = load_config()
        if error:
            print("Config problem: " + error)
            return 1
        print("Config OK (%s)" % source)
        return 0
    try:
        port = args.port or (int(os.environ["GOLDWARE_PORT"]) if os.environ.get("GOLDWARE_PORT") else config_port())
    except ValueError:
        sys.stderr.write("GOLDWARE_PORT must be a whole number.\n")
        return 2
    if not 1024 <= port <= 65535:
        sys.stderr.write("Port %d is out of range (1024 to 65535).\n" % port)
        return 2
    os.makedirs(DATA_ROOT, exist_ok=True)
    try:
        httpd = make_server(port)
    except OSError as e:
        sys.stderr.write("Cannot listen on 127.0.0.1:%d (%s). Another GoldWare OS server or app may "
                         "already be using it; stop it or set a different port.\n" % (port, e.strerror or e))
        return 3
    print("GoldWare OS server on http://127.0.0.1:%d" % port, flush=True)
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
