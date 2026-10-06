"""The Office record player: pick a music style and Spotify on this Mac plays it.

The page only ever sends a style key, a whole volume from 0 to 100, or one of the fixed actions below;
never a Spotify URI or a script. Playlists reach osascript as arguments, never as script source.
Nothing here likes, follows or saves anything, or changes Spotify settings, and nothing plays on its
own: only a play request (a click or Enter in the Office) starts music.

Styles: the built-in Instrumental and Vocals playlists below (Spotify's own public playlists), plus the
user's own playlists in goldware.json under office.music.playlists, shown on the Mine tab. GoldWare
ships with no personal playlists: the Mine tab's "Add my playlists" button asks the boss to add them.
"""
import os
import re
import subprocess
import threading
import time

import office
from office import OfficeError

# Spotify's own editorial playlists (public). Each id was checked: open.spotify.com/playlist/<id>
# answered with this title. Swap one by changing its id and title.
STYLES = [
    {"key": "lofi", "label": "Lo-fi beats", "group": "instrumental", "color": "#b48ce0", "playlist": "37i9dQZF1DWWQRwui0ExPn", "title": "lofi beats"},
    {"key": "jazz", "label": "Jazz", "group": "instrumental", "color": "#f2a34a", "playlist": "37i9dQZF1DX0SM0LYsmbMT", "title": "Jazz Vibes"},
    {"key": "classical", "label": "Classical", "group": "instrumental", "color": "#d8c27a", "playlist": "37i9dQZF1DWWEJlAGA9gs0", "title": "Classical Essentials"},
    {"key": "piano", "label": "Piano", "group": "instrumental", "color": "#e8e4d8", "playlist": "37i9dQZF1DX4sWSpwq3LiO", "title": "Peaceful Piano"},
    {"key": "ambient", "label": "Ambient", "group": "instrumental", "color": "#7fc8d8", "playlist": "37i9dQZF1DX3Ogo9pFvBkY", "title": "Ambient Relaxation"},
    {"key": "synthwave", "label": "Synthwave", "group": "instrumental", "color": "#ff4fa3", "playlist": "37i9dQZF1DXdLEN7aqioXM", "title": "Retrowave // Outrun"},
    {"key": "videogame", "label": "Video game music", "group": "instrumental", "color": "#40b848", "playlist": "37i9dQZF1DXdfOcg1fm0VG", "title": "Video Game Soundtracks"},
    {"key": "film", "label": "Film scores", "group": "instrumental", "color": "#ff5a4a", "playlist": "37i9dQZF1DX1tz6EDao8it", "title": "Iconic Soundtracks"},
    {"key": "focus", "label": "Deep focus", "group": "instrumental", "color": "#7088ff", "playlist": "37i9dQZF1DWZeKCadgRdKQ", "title": "Deep Focus"},
    {"key": "guitar", "label": "Acoustic guitar", "group": "instrumental", "color": "#d8935a", "playlist": "37i9dQZF1DX0jgyAiPl8Af", "title": "Peaceful Guitar"},
    {"key": "slackkey", "label": "Hawaiian slack key", "group": "instrumental", "color": "#2fb3a0", "playlist": "3KoSe59lras2PfH8ghmV2I", "title": "Hawaiian Slack Key Guitar \u2013 Best of"},
    {"key": "bossa", "label": "Bossa nova", "group": "instrumental", "color": "#ffcb05", "playlist": "37i9dQZF1DX4AyFl3yqHeK", "title": "Bossa Nova"},
    {"key": "indie", "label": "Indie", "group": "vocals", "color": "#e07a5f", "playlist": "37i9dQZF1DXdbXrPNafg9d", "title": "All New Indie"},
    {"key": "hiphop", "label": "Hip hop", "group": "vocals", "color": "#f0b000", "playlist": "37i9dQZF1DX0XUsuxWHRQd", "title": "RapCaviar"},
    {"key": "rnb", "label": "R&B and soul", "group": "vocals", "color": "#c07ad8", "playlist": "37i9dQZF1DX4SBhb3fqCJd", "title": "RNB X"},
    {"key": "pop", "label": "Pop", "group": "vocals", "color": "#ff7eb6", "playlist": "37i9dQZF1DXcBWIGoYBM5M", "title": "Today\u2019s Top Hits"},
    {"key": "rock", "label": "Rock", "group": "vocals", "color": "#ff6a3d", "playlist": "37i9dQZF1DWXRqgorJj26U", "title": "Rock Classics"},
    {"key": "reggae", "label": "Reggae", "group": "vocals", "color": "#4cc456", "playlist": "37i9dQZF1DXbSbnqxMTGx9", "title": "Reggae Classics"},
    {"key": "country", "label": "Country", "group": "vocals", "color": "#c98b4a", "playlist": "37i9dQZF1DX1lVhptIYRda", "title": "Hot Country"},
    {"key": "throwback", "label": "Throwback 2000s", "group": "vocals", "color": "#4aa8ff", "playlist": "37i9dQZF1DX4o1oenSJRJd", "title": "All Out 2000s"},
    {"key": "gospel", "label": "Gospel and worship", "group": "vocals", "color": "#f7e7a1", "playlist": "37i9dQZF1DXcb6CQIjdqKy", "title": "Top Christian & Gospel"},
]
MINE_COLORS = ["#9fd3ff", "#7ef0b0", "#ffb35c", "#ff8ad8", "#c9a24a", "#b48ce0", "#7fc8d8", "#ff6a3d"]
MAX_MINE = 24
MAX_LABEL = 60
ACTIONS = ("play", "pause", "resume", "next", "volume")
FIELDS = {"action", "style", "volume"}
PLAYLIST_ID = re.compile(r"^[A-Za-z0-9]{22}$")
PLAYLIST_LINK = re.compile(r"^https://open\.spotify\.com/(?:intl-[a-z]{2}(?:-[A-Za-z]{2})?/)?playlist/([A-Za-z0-9]{22})(?:[/?#].*)?$")
ART = re.compile(r"^https://i\.scdn\.co/image/[a-z0-9]+$")   # only Spotify's own cover images reach the page
COLOR = re.compile(r"^#[0-9A-Fa-f]{6}$")
SLACK = 5   # seconds of polling and reporting lag allowed around the end of a song

STATE_SCRIPT = """
if application "Spotify" is running then
  tell application "Spotify"
    set s to player state as string
    set t to ""
    set a to ""
    set u to ""
    set d to "0"
    set p to "0"
    try
      set t to name of current track
      set a to artist of current track
      set u to spotify url of current track
      set d to (duration of current track) as string
      set p to (player position) as string
    end try
    set w to ""
    try
      set w to artwork url of current track
    end try
    return s & tab & t & tab & a & tab & (sound volume as string) & tab & u & tab & d & tab & p & tab & w
  end tell
else
  return "not running"
end if
"""
RUNNING_SCRIPT = 'return application "Spotify" is running'
PLAY_SCRIPT = 'on run argv\ntell application "Spotify" to play track (item 1 of argv)\nend run'
VOLUME_SCRIPT = 'on run argv\ntell application "Spotify" to set sound volume to ((item 1 of argv) as integer)\nend run'
SIMPLE = {"pause": 'tell application "Spotify" to pause', "resume": 'tell application "Spotify" to play',
          "next": 'tell application "Spotify" to next track'}

ADD_PLAYLISTS = (
    "The user wants their own Spotify playlists on the Office record player (its Mine tab). Ask them which "
    "playlists, in the order they want them (in Spotify: the playlist's ... menu > Share > Copy link to playlist). "
    "Then add each one to office.music.playlists in {config} as {{\"label\": \"short name\", \"playlist\": \"the share "
    "link or its 22-character id\"}}, keeping everything else in that file. If the file does not exist yet, copy "
    "{default} to it first. Never edit goldware.default.json. Check it with `python3 {check} --check`, then tell "
    "the user to reopen the record player. Do not sign in to Spotify or change anything in it."
)


class Failed(OfficeError):
    def __init__(self, message, status=502):
        super().__init__(message, status)


# The music session (see reconcile): one record player per server.
LOCK = threading.Lock()
SESSION = {"value": None}
clock = time.monotonic
sleeper = time.sleep
runner = None      # tests: runner(name, script, *args) -> stdout
launcher = None    # tests: launcher()


# ---------- the user's own playlists (goldware.json office.music.playlists) ----------

def playlist_id(value):
    """A 22-character Spotify playlist id from an id or an open.spotify.com share link, else None."""
    if not isinstance(value, str):
        return None
    v = value.strip()
    if PLAYLIST_ID.match(v):
        return v
    m = PLAYLIST_LINK.match(v)
    return m.group(1) if m else None


def validate(music):
    """For validate_config: None when office.music is fine, else a message naming the field."""
    if music is None:
        return None
    if not isinstance(music, dict):
        return "office.music must be an object."
    lst = music.get("playlists", [])
    if not isinstance(lst, list) or len(lst) > MAX_MINE:
        return "office.music.playlists must be a list of up to %d playlists." % MAX_MINE
    seen = set()
    for i, p in enumerate(lst):
        where = "office.music.playlists[%d]" % i
        if not isinstance(p, dict):
            return where + " must be an object."
        label = p.get("label")
        if not isinstance(label, str) or not 1 <= len(label.strip()) <= MAX_LABEL or re.search(r"[\x00-\x1f]", label):
            return where + ".label must be one line of text up to %d characters." % MAX_LABEL
        pid = playlist_id(p.get("playlist"))
        if not pid:
            return where + ".playlist must be a Spotify playlist link (open.spotify.com/playlist/...) or its 22-character id."
        if pid in seen:
            return where + " repeats a playlist that is already on the list."
        seen.add(pid)
        if "color" in p and (not isinstance(p["color"], str) or not COLOR.match(p["color"])):
            return where + ".color must look like #RRGGBB."
    return None


def mine(cfg):
    """The user's playlists as styles on the Mine tab. A broken entry is skipped, never played."""
    music = ((cfg or {}).get("office") or {}).get("music") if isinstance(cfg, dict) else None
    if validate(music):
        return []
    out = []
    for i, p in enumerate((music or {}).get("playlists", [])):
        pid = playlist_id(p["playlist"])
        out.append({"key": "my-" + pid, "label": p["label"].strip(), "group": "mine",
                    "color": p.get("color") or MINE_COLORS[i % len(MINE_COLORS)], "playlist": pid, "title": p["label"].strip()})
    return out


def styles(cfg):
    return STYLES + mine(cfg)


# ---------- Spotify over osascript ----------

def _osa(name, script, *args):
    if runner:
        return str(runner(name, script, *args)).strip()
    out, err, code = office.osa("music-" + name, script, *args, timeout=8)
    if code != 0:
        raise Failed(friendly(err))
    return (out or "").strip()


def friendly(err):
    text = str(err or "")
    if "-1743" in text or "Not authorized" in text:
        return "Allow GoldWare OS to control Spotify in System Settings > Privacy & Security > Automation."
    if "-600" in text:
        return "Spotify is not running."
    return "Spotify did not respond: %s" % (text.strip().splitlines() or [""])[0][:160]


def read_state():
    out = _osa("state", STATE_SCRIPT)
    if not out or out == "not running":
        return {"running": False, "state": "stopped", "track": None, "artist": None, "volume": None, "url": None}
    parts = (out.split("\t") + [""] * 8)[:8]
    s, track, artist, volume, url, duration, position, art = parts

    def num(x):
        try:
            return float(str(x).replace(",", "."))
        except ValueError:
            return 0.0
    return {"running": True, "state": s.strip(), "track": track or None, "artist": artist or None,
            "volume": int(volume) if volume.strip().isdigit() else None, "url": url.strip() or None,
            "duration": num(duration) / 1000, "position": num(position),
            "art": art.strip() if ART.match(art.strip()) else None}


def running():
    return _osa("running", RUNNING_SCRIPT) == "true"


def require_running():
    if not running():
        raise Failed("Spotify is not open. Pick a style to start it.", 409)


def ensure_running():
    if running():
        return
    if launcher:
        launcher()
    elif not office.dry_run():
        subprocess.run(["open", "-g", "-b", "com.spotify.client"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10)
    for _ in range(20):
        sleeper(0.5)
        if running():
            return
    raise Failed("Spotify did not open. Is it installed?")


# ---------- the session: name a style only while the music is provably that playlist ----------
# Spotify's AppleScript cannot say which playlist a song came from. So a style is named for the first
# new song after Play (or Skip), then for each song that follows when the last one ran out. Any other
# change (the user picks something in Spotify, a change while paused, a song cut short) ends it.

def reconcile(state, now=None):
    now = clock() if now is None else now
    s = SESSION["value"]
    if not s:
        return None
    url = state.get("url")
    if not (state.get("running") and state.get("state") in ("playing", "paused") and url):
        SESSION["value"] = None
        return None
    if url == s["track"]:
        pass
    elif s["expect"]:
        if url == s["before"]:
            return None      # Spotify has not caught up yet: claim nothing until it does
        s["expect"] = False
    elif s["ends_at"] is not None and now >= s["ends_at"] - SLACK:
        pass                 # the last song ran out and the playlist moved on
    else:
        SESSION["value"] = None
        return None
    s["track"] = url
    s["ends_at"] = now + max(state.get("duration", 0) - state.get("position", 0), 0) if state.get("state") == "playing" else None
    return s["style"]


# ---------- the route ----------

def view(cfg):
    state = read_state()
    all_styles = styles(cfg)
    key = reconcile(state)
    style = next((x for x in all_styles if x["key"] == key), None)
    out = {k: v for k, v in state.items() if k not in ("url", "duration", "position")}
    out.update(ok=True, style=style and style["key"], style_label=style and style["label"],
               styles=[{k: x[k] for k in ("key", "label", "group", "color", "title")} for x in all_styles])
    return out


def handle(method, body, cfg):
    """GET /api/office/music reads the player; POST runs one validated action. Returns (status, dict)."""
    try:
        if method == "GET":
            return 200, view(cfg)
        if method != "POST":
            return 405, {"error": "Method not allowed."}
        if not isinstance(body, dict):
            return 422, {"error": "Send a JSON object."}
        if set(body) - FIELDS:
            return 422, {"error": "Only action, style and volume are allowed."}
        action = body.get("action")
        if action not in ACTIONS:
            return 422, {"error": "Unknown action."}
        with LOCK:
            if action == "play":
                play(body, cfg)
            elif action == "volume":
                v = body.get("volume")
                if isinstance(v, bool) or not isinstance(v, int) or not 0 <= v <= 100:
                    return 422, {"error": "Volume is a whole number from 0 to 100."}
                require_running()
                _osa("volume", VOLUME_SCRIPT, str(v))
            else:
                require_running()
                if action == "next":
                    s = SESSION["value"]
                    if s:
                        s.update(expect=True, before=read_state().get("url"))
                _osa(action, SIMPLE[action])
            if action != "play":
                sleeper(0.35)   # Spotify reports a change a moment after it makes it
        return 200, view(cfg)
    except OfficeError as e:
        return e.status, {"error": str(e)}


def play(body, cfg):
    key = body.get("style")
    style = next((x for x in styles(cfg) if isinstance(key, str) and x["key"] == key), None)
    if not style:
        raise Failed("Pick one of the styles on the wheel.", 422)
    uri = "spotify:playlist:" + style["playlist"]
    if not re.match(r"^spotify:playlist:[A-Za-z0-9]{22}$", uri):
        raise Failed("That playlist id is not valid.", 500)
    ensure_running()
    before = read_state().get("url")
    try:
        _osa("play", PLAY_SCRIPT, uri)
    except Failed:
        sleeper(1.5)   # Spotify can refuse the first command while it is still opening
        _osa("play", PLAY_SCRIPT, uri)
    SESSION["value"] = {"style": style["key"], "before": before, "track": None, "ends_at": None, "expect": True}
    state = {}
    for wait in (1.0, 1.0, 1.5, 1.5):   # Spotify takes a second or two to report the new playlist
        sleeper(wait)
        state = read_state()
        if state.get("state") == "playing" and state.get("url") and state.get("url") != before:
            return
    SESSION["value"] = None
    if state.get("state") != "playing":
        raise Failed("Spotify opened but is not playing. Check that it is signed in and online.")
    raise Failed("Spotify kept playing the same song instead of %s. Try again." % style["title"])


def add_playlists_request(root, config_path, default_path):
    """What the Mine tab's button asks the boss to do, with this install's own paths."""
    return ADD_PLAYLISTS.format(config=config_path, default=default_path,
                                check=os.path.join(root, "server", "goldware_server.py"))
