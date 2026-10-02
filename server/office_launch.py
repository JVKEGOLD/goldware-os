"""The Office's New agent button and its settings (topics and model presets).

Python 3.9 stdlib only. Safety rules, the same family as office.py:
  * The browser sends ids only ({type, topic}). The folder and the command come from goldware.json
    (office.topics, office.presets), never from the request.
  * The command is a single line you wrote yourself, run in your own terminal. Only a same-origin
    request can change it (the server checks that before anything here runs).
  * The terminal gets `cd <quoted folder> && <command>` as an argv item of osascript, never spliced
    into AppleScript source.
  * Saving writes only office.topics and office.presets in goldware.json, atomically (temp file in
    the same folder, then rename), and keeps every other key.
  * GOLDWARE_OFFICE_DRY_RUN=1 records the osascript call in office.DRY_LOG and opens nothing.
"""
import json
import os
import re
import shlex
import shutil
import tempfile
import threading
import time

import office
from office import OfficeError, TerminalError

MAX_ITEMS = 20
MAX_LABEL = 40
MAX_COMMAND = 199            # "under 200"
MAX_DIR = 500
NEW_GAP = 5.0                # seconds between windows, so a double click opens one
DEFAULT_PROFILE = "GoldWare"
_CTRL = re.compile(r"[\x00-\x1f\x7f-\x9f]")

NEW_ITERM_SCRIPT = """\
on run argv
  set prof to item 1 of argv
  set cmd to item 2 of argv
  set wasRunning to application "iTerm" is running
  tell application "iTerm"
    activate
    set strays to {}
    if not wasRunning then
      repeat 50 times
        if (count of windows) > 0 then exit repeat
        delay 0.1
      end repeat
      repeat 50 times
        try
          if (contents of current session of first window) is not "" then exit repeat
        end try
        delay 0.1
      end repeat
      delay 0.5
      set strays to windows
    end if
    try
      set w to (create window with profile prof)
    on error
      set w to (create window with default profile)
    end try
    tell current session of w to write text cmd
    repeat with s in strays
      close s
    end repeat
  end tell
  return "opened"
end run
"""

NEW_TERMINAL_SCRIPT = """\
on run argv
  set cmd to item 2 of argv
  tell application "Terminal"
    activate
    do script cmd
  end tell
  return "opened"
end run
"""

# "Choose folder…" in the editor: the Mac's own folder picker. It returns the folder you picked, which
# the page only puts in the Folder box; nothing is saved or opened until you press Save.
CHOOSE_FOLDER_SCRIPT = """\
on run argv
  tell me to activate
  try
    set f to choose folder with prompt (item 1 of argv)
  on error number -128
    return "CANCELLED"
  end try
  return POSIX path of f
end run
"""
CHOOSE_TIMEOUT = 600         # the picker waits for you; ten minutes, then it gives up
_CHOOSING = threading.Lock() # one picker at a time

_LOCK = threading.Lock()
_LAST_NEW = [0.0]


# ---------- reading the settings ----------

def _read(path):
    try:
        with open(path, "r", encoding="utf-8") as f:
            data = json.load(f)
        return data if isinstance(data, dict) else None
    except (OSError, ValueError):
        return None


def _items(cfg, key):
    office_cfg = (cfg or {}).get("office")
    lst = office_cfg.get(key) if isinstance(office_cfg, dict) else None
    return lst if isinstance(lst, list) else None


def effective(default_path, user_path):
    """(topics, presets) as stored: the user's lists when goldware.json has them, else the defaults."""
    user, default = _read(user_path), _read(default_path)
    out = []
    for key in ("topics", "presets"):
        lst = _items(user, key)
        if lst is None:
            lst = _items(default, key) or []
        out.append([x for x in lst if isinstance(x, dict) and isinstance(x.get("id"), str)])
    return out[0], out[1]


def search_path():
    extra = ["~/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "~/.claude/local", "~/.npm-global/bin",
             "~/.bun/bin", "~/.cargo/bin"]
    parts = (os.environ.get("PATH") or "").split(os.pathsep) + [os.path.expanduser(p) for p in extra]
    return os.pathsep.join(dict.fromkeys(p for p in parts if p))


def program_of(command):
    """The program a command starts: the first word that is not NAME=value. None if it cannot be read."""
    try:
        words = shlex.split(command)
    except ValueError:
        return None
    for w in words:
        if not re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", w):
            return w
    return None


def available(command):
    prog = program_of(command)
    if not prog:
        return False
    if "/" in prog:
        full = os.path.expanduser(prog)
        return os.path.isfile(full) and os.access(full, os.X_OK)
    return shutil.which(prog, path=search_path()) is not None


def view(default_path, user_path):
    """What the page needs to draw the menu and the editor."""
    topics, presets = effective(default_path, user_path)
    return {
        "topics": [{"id": t["id"], "label": str(t.get("label", "")), "dir": str(t.get("dir", "")),
                    "exists": os.path.isdir(os.path.expanduser(str(t.get("dir", ""))))} for t in topics],
        "presets": [{"id": p["id"], "label": str(p.get("label", "")), "command": str(p.get("command", "")),
                     "available": available(str(p.get("command", "")))} for p in presets],
        "limits": {"items": MAX_ITEMS, "label": MAX_LABEL, "command": MAX_COMMAND},
    }


# ---------- opening the terminal ----------

def terminal_app():
    forced = os.environ.get("GOLDWARE_OFFICE_TERMINAL")
    if forced in ("iTerm", "Terminal"):
        return forced
    for base in ("/Applications", os.path.expanduser("~/Applications")):
        if os.path.isdir(os.path.join(base, "iTerm.app")):
            return "iTerm"
    return "Terminal"


def new_line(directory, command):
    """What the new terminal runs: cd into the folder (quoted), then the agent."""
    return "cd %s && %s" % (shlex.quote(directory), command)


def throttle_new(now=None):
    now = time.time() if now is None else now
    with _LOCK:
        left = NEW_GAP - (now - _LAST_NEW[0])
        if left <= 0:
            _LAST_NEW[0] = now
        return max(0.0, left)


def reset_throttle():
    with _LOCK:
        _LAST_NEW[0] = 0.0


def new_agent(body, default_path, user_path, profile=None, now=None):
    """Open one terminal window running the chosen preset in the chosen topic's folder."""
    if not isinstance(body, dict):
        raise OfficeError("Body must be a JSON object.")
    topics, presets = effective(default_path, user_path)
    type_id, topic_id = body.get("type"), body.get("topic")
    if type_id is None:
        pick = next((p for p in presets if available(str(p.get("command", "")))), None) or (presets[0] if presets else None)
    else:
        pick = next((p for p in presets if isinstance(type_id, str) and p["id"] == type_id), None)
    if pick is None:
        raise OfficeError("Unknown agent type.", 422)
    if topic_id is None:
        place = topics[0] if topics else None
    else:
        place = next((t for t in topics if isinstance(topic_id, str) and t["id"] == topic_id), None)
    if place is None:
        raise OfficeError("Unknown topic.", 422)
    command = str(pick.get("command", ""))
    if not command or _CTRL.search(command) or len(command) > MAX_COMMAND:
        raise OfficeError("%s has no usable command. Open Edit and fix it." % pick.get("label", "That agent"), 422)
    if not available(command):
        raise OfficeError("%s is not installed here (%s was not found)." % (pick.get("label", "That agent"), program_of(command) or command), 422)
    directory = os.path.expanduser(str(place.get("dir", "")))
    if not directory or not os.path.isdir(directory):
        raise OfficeError("The folder for %s is missing (%s). Open Edit and fix it." % (place.get("label", "that topic"), place.get("dir", "")), 409)
    wait = throttle_new(now)
    if wait > 0:
        raise OfficeError("A new terminal is already opening.", 429)
    line = new_line(directory, command)
    app = terminal_app()
    script = NEW_ITERM_SCRIPT if app == "iTerm" else NEW_TERMINAL_SCRIPT
    out, err, code = office.osa("new", script, profile or DEFAULT_PROFILE, line, timeout=15)
    if code != 0:
        raise TerminalError(office.friendly(err))
    if out.strip() != "opened":
        raise TerminalError("The terminal did not open.")
    return {"ok": True, "type": pick["id"], "topic": place["id"], "label": pick.get("label"),
            "topic_label": place.get("label"), "terminal": app}


def tilde(path, home=None):
    """A folder as the editor shows it: ~ for your home folder, no trailing slash."""
    home = home or os.path.expanduser("~")
    path = path.rstrip("/") or "/"
    if path == home:
        return "~"
    if path.startswith(home + "/"):
        return "~" + path[len(home):]
    return path


def choose_folder():
    """Show the Mac folder picker. Returns {"dir": "~/..."} or {"cancelled": True}."""
    if not _CHOOSING.acquire(blocking=False):
        raise OfficeError("A folder picker is already open.", 409)
    try:
        out, err, code = office.osa("choose", CHOOSE_FOLDER_SCRIPT, "Choose the folder for this topic", timeout=CHOOSE_TIMEOUT)
    finally:
        _CHOOSING.release()
    if code != 0:
        raise TerminalError(office.friendly(err))
    picked = out.strip()
    if not picked or picked == "CANCELLED":
        return {"cancelled": True}
    if _CTRL.search(picked) or len(picked) > MAX_DIR:
        raise OfficeError("That folder name cannot be used.", 422)
    return {"dir": tilde(picked), "name": os.path.basename(picked.rstrip("/"))}


# ---------- saving ----------

def slug(label, taken):
    base = re.sub(r"[^a-z0-9]+", "-", label.lower()).strip("-")[:30].strip("-") or "item"
    out, n = base, 2
    while out in taken:
        out = "%s-%d" % (base, n)
        n += 1
    taken.add(out)
    return out


def _label(raw, what):
    if not isinstance(raw, str):
        raise OfficeError("Every %s needs a name." % what)
    text = raw.strip()
    if _CTRL.search(text):
        raise OfficeError("A %s name cannot have control characters." % what)
    if not 1 <= len(text) <= MAX_LABEL:
        raise OfficeError("A %s name must be 1 to %d characters." % (what, MAX_LABEL))
    return text


def clean_topics(raw):
    if not isinstance(raw, list) or not 1 <= len(raw) <= MAX_ITEMS:
        raise OfficeError("Keep between 1 and %d topics." % MAX_ITEMS)
    taken, out = set(), []
    for t in raw:
        if not isinstance(t, dict):
            raise OfficeError("Each topic needs a name and a folder.")
        label = _label(t.get("label"), "topic")
        d = t.get("dir")
        if not isinstance(d, str):
            raise OfficeError("%s needs a folder." % label)
        d = d.strip()
        if _CTRL.search(d) or not d or len(d) > MAX_DIR:
            raise OfficeError("The folder for %s must be one line of text up to %d characters." % (label, MAX_DIR))
        if not (d.startswith("/") or d == "~" or d.startswith("~/")):
            raise OfficeError("The folder for %s must start with / or ~/." % label)
        if not os.path.isdir(os.path.expanduser(d)):
            raise OfficeError("The folder for %s does not exist: %s" % (label, d))
        out.append({"id": slug(label, taken), "label": label, "dir": d})
    return out


def clean_presets(raw):
    if not isinstance(raw, list) or not 1 <= len(raw) <= MAX_ITEMS:
        raise OfficeError("Keep between 1 and %d agents." % MAX_ITEMS)
    taken, out = set(), []
    for p in raw:
        if not isinstance(p, dict):
            raise OfficeError("Each agent needs a name and a command.")
        label = _label(p.get("label"), "agent")
        c = p.get("command")
        if not isinstance(c, str):
            raise OfficeError("%s needs a command." % label)
        c = c.strip()
        if not c or _CTRL.search(c):
            raise OfficeError("The command for %s must be one line with no control characters." % label)
        if len(c) > MAX_COMMAND:
            raise OfficeError("The command for %s must be under 200 characters." % label)
        out.append({"id": slug(label, taken), "label": label, "command": c})
    return out


def validate_shape(office_cfg):
    """For goldware.json as a whole (used by validate_config): the shape only, since a folder can
    disappear after it was saved. Returns None or a message."""
    if office_cfg is None:
        return None
    if not isinstance(office_cfg, dict):
        return "office must be an object."
    for key, fields in (("topics", ("dir",)), ("presets", ("command",))):
        lst = office_cfg.get(key)
        if lst is None:
            continue
        if not isinstance(lst, list) or len(lst) > MAX_ITEMS:
            return "office.%s must be a list of up to %d items." % (key, MAX_ITEMS)
        for i, x in enumerate(lst):
            where = "office.%s[%d]" % (key, i)
            if not isinstance(x, dict):
                return where + " must be an object."
            if not isinstance(x.get("id"), str) or not re.match(r"^[a-z0-9][a-z0-9-]{0,39}$", x["id"]):
                return where + ".id must be a lowercase slug."
            if not isinstance(x.get("label"), str) or not 1 <= len(x["label"]) <= MAX_LABEL:
                return where + ".label must be text between 1 and %d characters." % MAX_LABEL
            for f in fields:
                v = x.get(f)
                if not isinstance(v, str) or not v.strip() or _CTRL.search(v) or len(v) > (MAX_DIR if f == "dir" else MAX_COMMAND):
                    return where + ".%s must be one line of text." % f
    return None


def save(body, default_path, user_path):
    """Replace office.topics and/or office.presets in goldware.json. Everything else stays."""
    if not isinstance(body, dict):
        raise OfficeError("Body must be a JSON object.")
    if "topics" not in body and "presets" not in body:
        raise OfficeError("Send topics, presets, or both.")
    new = {}
    if "topics" in body:
        new["topics"] = clean_topics(body["topics"])
    if "presets" in body:
        new["presets"] = clean_presets(body["presets"])
    if os.path.exists(user_path):
        try:
            with open(user_path, "r", encoding="utf-8") as f:
                cfg = json.load(f)
        except (OSError, ValueError) as e:
            raise OfficeError("goldware.json is not valid JSON (%s), so nothing was saved. Fix or remove it first." % e, 409)
        if not isinstance(cfg, dict):
            raise OfficeError("goldware.json is not a JSON object, so nothing was saved.", 409)
    else:
        cfg = _read(default_path) or {}
    section = cfg.get("office")
    section = dict(section) if isinstance(section, dict) else {}
    # A list that was not sent keeps what is in effect now (the defaults on a first save), so a save of
    # one list still leaves a complete office section.
    topics, presets = effective(default_path, user_path)
    section["topics"] = new.get("topics", topics)
    section["presets"] = new.get("presets", presets)
    cfg["office"] = section
    text = json.dumps(cfg, indent=2, ensure_ascii=False) + "\n"
    folder = os.path.dirname(os.path.abspath(user_path))
    fd, tmp = tempfile.mkstemp(prefix=".goldware.", suffix=".tmp", dir=folder)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(text)
            f.flush()
            os.fsync(f.fileno())
        if os.path.exists(user_path):
            try:
                os.chmod(tmp, os.stat(user_path).st_mode & 0o777)
            except OSError:
                pass
        os.replace(tmp, user_path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise
    return view(default_path, user_path)
