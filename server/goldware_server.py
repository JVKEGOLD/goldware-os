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
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.environ.get("GOLDWARE_ROOT") or os.path.dirname(HERE))
DATA_ROOT = os.path.abspath(os.environ.get("GOLDWARE_DATA_ROOT") or os.path.join(ROOT, "data"))
# Static assets live next to the code, not in a test-only root copy.
CODE_ROOT = os.path.dirname(HERE)
DEFAULT_PORT = 4188
CARD_TYPES = ["welcome", "clock", "tasks", "notes", "links", "system", "agents", "embed", "html"]
CARD_SIZES = ["s", "m", "l", "w"]
STATUSES = ["inbox", "ready", "doing", "done", "dropped"]
TASK_FIELDS = ["title", "context", "status", "due_on", "priority", "focus_on"]
LOCK = threading.Lock()
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
    if "wakePhrase" in cfg and not isinstance(cfg["wakePhrase"], str):
        return "wakePhrase must be text."
    if "wakeAliases" in cfg:
        al = cfg["wakeAliases"]
        if not isinstance(al, list) or not all(isinstance(a, str) for a in al):
            return "wakeAliases must be a list of text values."
    if "models" in cfg and not isinstance(cfg["models"], dict):
        return "models must be an object."
    dash = cfg.get("dashboard")
    if dash is not None:
        if not isinstance(dash, dict):
            return "dashboard must be an object."
        if "layout" in dash and not isinstance(dash["layout"], str):
            return "dashboard.layout must be text."
        cards = dash.get("cards", [])
        if not isinstance(cards, list):
            return "dashboard.cards must be a list."
        seen = set()
        for i, card in enumerate(cards):
            where = "dashboard.cards[%d]" % i
            if not isinstance(card, dict):
                return where + " must be an object."
            cid = card.get("id")
            if not isinstance(cid, str) or not cid:
                return where + ".id must be non-empty text."
            if cid in seen:
                return where + ".id \"%s\" is used by more than one card." % cid
            seen.add(cid)
            if card.get("type") not in CARD_TYPES:
                return where + ".type must be one of: " + ", ".join(CARD_TYPES) + "."
            if card.get("size") not in CARD_SIZES:
                return where + ".size must be one of: s, m, l, w."
            if "title" in card and not isinstance(card["title"], str):
                return where + ".title must be text."
            if "options" in card and not isinstance(card["options"], dict):
                return where + ".options must be an object."
    return None


def read_json(path):
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def load_config():
    """Return (config, source, error)."""
    try:
        default = read_json(default_path())
    except Exception as e:
        default = {}
        default_err = "goldware.default.json could not be read: %s" % e
    else:
        default_err = None
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
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(text)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, path)


def save_config(cfg):
    up = user_path()
    if os.path.exists(up):
        shutil.copyfile(up, up + ".bak")
    atomic_write(up, json.dumps(cfg, indent=2) + "\n")


# ---------- work ----------

def data_path(name):
    return os.path.join(DATA_ROOT, name)


def load_data(name, fallback):
    try:
        return read_json(data_path(name))
    except Exception:
        return fallback


def revision_of(task):
    body = {k: v for k, v in task.items() if k != "revision"}
    canon = json.dumps(body, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
    return hashlib.sha256(canon.encode("utf-8")).hexdigest()[:12]


def today_str():
    return datetime.date.today().isoformat()


def stored_tasks():
    data = load_data("tasks.json", {"tasks": []})
    tasks = data.get("tasks", []) if isinstance(data, dict) else []
    return tasks if isinstance(tasks, list) else []


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
        elif k == "context":
            if v is None:
                v = ""
            if not isinstance(v, str):
                return None, "context must be text."
        elif k == "status":
            if v not in STATUSES:
                return None, "status must be one of: " + ", ".join(STATUSES) + "."
        elif k in ("due_on", "focus_on"):
            if v is not None and (not isinstance(v, str) or not re.match(r"^\d{4}-\d{2}-\d{2}$", v)):
                return None, "%s must be YYYY-MM-DD or null." % k
        elif k == "priority":
            if v is not None and (isinstance(v, bool) or not isinstance(v, (int, str))):
                return None, "priority must be a number, text, or null."
        clean[k] = v
    if creating and "title" not in clean:
        return None, "title is required."
    return clean, None


def work_get():
    tasks = [with_revision(t) for t in stored_tasks() if isinstance(t, dict)]
    return 200, {"today": today_str(), "tasks": tasks}


def work_post(body):
    if not isinstance(body, dict):
        return 400, {"error": "Body must be a JSON object."}
    with LOCK:
        tasks = stored_tasks()
        if body.get("create") is True:
            rid = body.get("request_id")
            if not isinstance(rid, str) or not rid:
                return 400, {"error": "request_id is required to create a task."}
            changes, err = check_changes(body.get("changes"), True)
            if err:
                return 400, {"error": err}
            tid = "t-" + hashlib.sha256(rid.encode("utf-8")).hexdigest()[:12]
            for t in tasks:
                if t.get("id") == tid:
                    return 200, {"task": with_revision(t), "created": False}
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
    data = load_data("notes.json", {"notes": {}})
    notes = data.get("notes", {}) if isinstance(data, dict) else {}
    return notes if isinstance(notes, dict) else {}


def notes_post(body):
    if not isinstance(body, dict):
        return 400, {"error": "Body must be a JSON object."}
    cid, text = body.get("cardId"), body.get("text")
    if not isinstance(cid, str) or not cid:
        return 400, {"error": "cardId must be non-empty text."}
    if not isinstance(text, str):
        return 400, {"error": "text must be text."}
    with LOCK:
        notes = notes_get()
        notes[cid] = text
        atomic_write(data_path("notes.json"), json.dumps({"notes": notes}, indent=2) + "\n")
    return 200, {"notes": notes}


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
    base = os.path.realpath(base)
    full = os.path.realpath(os.path.join(base, rel))
    if full != base and not full.startswith(base + os.sep):
        return None
    return full


class Handler(BaseHTTPRequestHandler):
    server_version = "GoldWareOS"
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        if VERBOSE:
            sys.stderr.write("%s %s\n" % (self.address_string(), fmt % args))

    def send(self, code, body, ctype, nostore=False):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        if nostore:
            self.send_header("Cache-Control", "no-store")
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def send_json(self, code, obj):
        self.send(code, json.dumps(obj).encode("utf-8"), "application/json; charset=utf-8", True)

    def err(self, code, msg):
        self.send_json(code, {"error": msg})

    def serve_file(self, base, rel, force_text=False):
        full = safe_join(base, rel)
        if full is None or not os.path.isfile(full):
            return self.err(404, "Not found.")
        ext = os.path.splitext(full)[1].lower()
        ctype = "text/plain; charset=utf-8" if force_text else CONTENT_TYPES.get(ext, "application/octet-stream")
        with open(full, "rb") as f:
            self.send(200, f.read(), ctype)

    def origin_ok(self):
        origin = self.headers.get("Origin")
        if origin is None:
            return True
        port = self.server.server_address[1]
        return origin in ("http://127.0.0.1:%d" % port, "http://localhost:%d" % port)

    def do_GET(self):
        path = urlparse(self.path).path
        try:
            if path == "/":
                full = os.path.join(CODE_ROOT, "dashboard", "index.html")
                if os.path.isfile(full):
                    with open(full, "rb") as f:
                        return self.send(200, f.read(), CONTENT_TYPES[".html"], True)
                return self.send(200, PLACEHOLDER, CONTENT_TYPES[".html"], True)
            if path == "/api/config":
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
            if path.startswith("/api/"):
                return self.err(404, "Not found.")
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
            return self.err(500, "Server error: %s" % e)

    do_HEAD = do_GET

    def do_POST(self):
        path = urlparse(self.path).path
        if not self.origin_ok():
            return self.err(403, "Requests from other origins are not allowed.")
        try:
            length = int(self.headers.get("Content-Length") or 0)
            if length > 5 * 1024 * 1024:
                return self.err(400, "Body too large.")
            raw = self.rfile.read(length) if length else b""
            try:
                body = json.loads(raw.decode("utf-8"))
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
            return self.err(404, "Not found.")
        except Exception as e:
            return self.err(500, "Server error: %s" % e)


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
    port = args.port or (int(os.environ["GOLDWARE_PORT"]) if os.environ.get("GOLDWARE_PORT") else config_port())
    os.makedirs(DATA_ROOT, exist_ok=True)
    httpd = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    httpd.daemon_threads = True
    print("GoldWare OS server on http://127.0.0.1:%d" % port, flush=True)
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
