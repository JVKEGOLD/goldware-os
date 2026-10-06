"""The Office record player: server/office_music.py with osascript stubbed, its two routes on a dry-run
server, and what the shipped page may and may not contain (no personal playlists, the Add button)."""
import json
import os
import re
import sys
import unittest

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(REPO, "server"))
sys.path.insert(0, os.path.join(REPO, "tests"))
import office_music as m  # noqa: E402

OWN = "https://open.spotify.com/playlist/0123456789abcdefABCDEF?si=x"


def cfg(playlists):
    return {"office": {"music": {"playlists": playlists}}}


class Player:
    """A pretend Spotify: answers the state script, records every command and its arguments."""

    def __init__(self):
        self.calls, self.running, self.state = [], True, "paused"
        self.song = ["So What", "Miles Davis", "spotify:track:OWNSONG000000000000000", "200000"]
        self.position, self.now, self.launched = 30.0, 1000.0, 0
        m.SESSION["value"] = None
        m.sleeper = lambda s: None
        m.clock = lambda: self.now
        m.launcher = self.launch
        m.runner = self.run

    def launch(self):
        self.launched += 1
        self.running = True

    def run(self, name, script, *args):
        self.calls.append((name, args))
        if name == "state":
            if not self.running:
                return "not running"
            return "\t".join([self.state, self.song[0], self.song[1], "40", self.song[2], self.song[3], str(self.position), ""])
        if name == "running":
            return "true" if self.running else "false"
        if name == "play":
            pid = args[0].split(":")[-1]
            self.song = ["Song 1", "Artist", "spotify:track:PL%s%s" % (pid[:4], "1".rjust(16, "0")), "180000"]
            self.state, self.position = "playing", 0.0
        elif name == "pause":
            self.state = "paused"
        elif name == "resume":
            self.state = "playing"
        elif name == "next":
            pre = self.song[2][len("spotify:track:"):][:6]
            self.song = ["Song 2", "Artist", "spotify:track:%s%s" % (pre, "2".rjust(16, "0")), "180000"]
        return ""

    def commands(self):
        return [c for c in self.calls if c[0] not in ("state", "running")]


class Validation(unittest.TestCase):
    def test_built_in_styles_are_complete_and_ship_no_personal_playlists(self):
        groups = [s["group"] for s in m.STYLES]
        self.assertGreaterEqual(groups.count("instrumental"), 12)
        self.assertGreaterEqual(groups.count("vocals"), 9)
        self.assertNotIn("mine", groups, "Mine comes only from the user's goldware.json")
        self.assertEqual(len({s["key"] for s in m.STYLES}), len(m.STYLES))
        for s in m.STYLES:
            self.assertRegex(s["playlist"], r"^[A-Za-z0-9]{22}$")
            self.assertRegex(s["color"], r"^#[0-9a-f]{6}$")
        self.assertEqual(m.styles({}), m.STYLES)

    def test_own_playlists_take_a_link_or_an_id(self):
        self.assertEqual(m.playlist_id(OWN), "0123456789abcdefABCDEF")
        self.assertEqual(m.playlist_id("https://open.spotify.com/intl-de/playlist/0123456789abcdefABCDEF"), "0123456789abcdefABCDEF")
        self.assertEqual(m.playlist_id(" 0123456789abcdefABCDEF "), "0123456789abcdefABCDEF")
        for bad in ("spotify:playlist:0123456789abcdefABCDEF", "https://evil.example/playlist/0123456789abcdefABCDEF",
                    "https://open.spotify.com/album/0123456789abcdefABCDEF", "0123", None, 5):
            self.assertIsNone(m.playlist_id(bad), bad)
        mine = m.mine(cfg([{"label": "Deep work", "playlist": OWN}, {"label": "Friday", "playlist": "37i9dQZF1DXcBWIGoYBM5M", "color": "#FF8AD8"}]))
        self.assertEqual([x["label"] for x in mine], ["Deep work", "Friday"])
        self.assertEqual([x["group"] for x in mine], ["mine", "mine"])
        self.assertEqual(mine[0]["key"], "my-0123456789abcdefABCDEF")
        self.assertEqual(mine[1]["color"], "#FF8AD8")

    def test_validate_names_the_bad_field(self):
        self.assertIsNone(m.validate(None))
        self.assertIsNone(m.validate({"playlists": []}))
        for music, field in ((["x"], "office.music must"), ({"playlists": "x"}, "playlists must"),
                             ({"playlists": [{"label": "", "playlist": OWN}]}, ".label"),
                             ({"playlists": [{"label": "A\nB", "playlist": OWN}]}, ".label"),
                             ({"playlists": [{"label": "A", "playlist": "spotify:playlist:x"}]}, ".playlist"),
                             ({"playlists": [{"label": "A", "playlist": OWN}, {"label": "B", "playlist": OWN}]}, "repeats"),
                             ({"playlists": [{"label": "A", "playlist": OWN, "color": "red"}]}, ".color"),
                             ({"playlists": [{"label": "A", "playlist": OWN}] * 0 + [{"label": str(i), "playlist": "%022d" % i} for i in range(25)]}, "up to 24")):
            err = m.validate(music)
            self.assertIsNotNone(err, music)
            self.assertIn(field, err)
        self.assertEqual(m.mine(cfg([{"label": "A", "playlist": "nope"}])), [], "a broken list plays nothing")

    def test_the_server_config_check_uses_it(self):
        import goldware_server as g
        with open(os.path.join(REPO, "goldware.default.json"), encoding="utf-8") as f:
            base = json.load(f)
        base["office"]["music"] = {"playlists": [{"label": "A", "playlist": "javascript:alert(1)"}]}
        self.assertIn("office.music.playlists[0].playlist", g.validate_config(base))
        base["office"]["music"] = {"playlists": [{"label": "A", "playlist": OWN}]}
        self.assertIsNone(g.validate_config(base))


class Playing(unittest.TestCase):
    def setUp(self):
        self.p = Player()

    def post(self, body, c=None):
        return m.handle("POST", body, c or {})

    def test_get_reads_the_player_and_never_controls_it(self):
        code, body = m.handle("GET", None, {})
        self.assertEqual(code, 200)
        self.assertEqual((body["state"], body["track"], body["volume"]), ("paused", "So What", 40))
        self.assertIsNone(body["style"], "music the user started is never given a style")
        self.assertNotIn("url", body)
        self.assertFalse(any("playlist" in s for s in body["styles"]))
        self.assertEqual(self.p.commands(), [])
        self.p.running = False
        self.assertEqual(m.handle("GET", None, {})[1]["running"], False)
        self.assertEqual(self.p.launched, 0, "reading never opens Spotify")

    def test_play_passes_the_playlist_as_an_argument(self):
        code, body = self.post({"action": "play", "style": "jazz"})
        self.assertEqual(code, 200)
        self.assertEqual(self.p.commands(), [("play", ("spotify:playlist:37i9dQZF1DX0SM0LYsmbMT",))])
        self.assertNotIn("37i9dQZF1DX0SM0LYsmbMT", m.PLAY_SCRIPT, "the uri is never script source")
        self.assertEqual((body["style"], body["state"], body["track"]), ("jazz", "playing", "Song 1"))

    def test_own_playlist_plays_from_goldware_json(self):
        c = cfg([{"label": "Deep work", "playlist": OWN}])
        code, body = self.post({"action": "play", "style": "my-0123456789abcdefABCDEF"}, c)
        self.assertEqual(code, 200)
        self.assertEqual(self.p.commands(), [("play", ("spotify:playlist:0123456789abcdefABCDEF",))])
        self.assertEqual(body["style_label"], "Deep work")
        self.assertEqual(self.post({"action": "play", "style": "my-0123456789abcdefABCDEF"})[0], 422, "not on the list, not playable")

    def test_play_opens_spotify_when_closed(self):
        self.p.running = False
        self.assertEqual(self.post({"action": "play", "style": "hiphop"})[0], 200)
        self.assertEqual(self.p.launched, 1)

    def test_refuses_unknown_styles_raw_uris_and_extra_fields(self):
        for style in ("metal", "spotify:playlist:37i9dQZF1DX0SM0LYsmbMT", "37i9dQZF1DX0SM0LYsmbMT", 'jazz" to quit', "", None, 5, ["jazz"]):
            code, body = self.post({"action": "play", "style": style})
            self.assertEqual(code, 422, style)
        for body in ({"action": "play", "uri": "spotify:track:x"}, {"action": "play", "style": "jazz", "script": "x"},
                     {"action": "like", "style": "jazz"}, {"action": None}, "play", ["play"]):
            self.assertEqual(self.post(body)[0], 422, body)
        self.assertEqual(self.p.commands(), [], "nothing refused reached Spotify")

    def test_volume_is_a_whole_number_from_0_to_100(self):
        for v in (-1, 101, 50.5, "50", None, True):
            self.assertEqual(self.post({"action": "volume", "volume": v})[0], 422, v)
        self.assertEqual(self.p.commands(), [])
        for v in (0, 37, 100):
            self.assertEqual(self.post({"action": "volume", "volume": v})[0], 200)
        self.assertEqual(self.p.commands(), [("volume", ("0",)), ("volume", ("37",)), ("volume", ("100",))])

    def test_controls_never_open_spotify(self):
        self.p.running = False
        for action in ("pause", "resume", "next"):
            code, body = self.post({"action": action})
            self.assertEqual(code, 409)
            self.assertIn("not open", body["error"])
        self.assertEqual(self.p.launched, 0)

    def test_style_drops_when_the_user_plays_something_else(self):
        self.post({"action": "play", "style": "lofi"})
        self.assertEqual(m.handle("GET", None, {})[1]["style"], "lofi")
        self.p.now += 40
        self.p.song = ["Solitude", "Billie Holiday", "spotify:track:OTHERSONG0000000000000", "200000"]
        self.assertIsNone(m.handle("GET", None, {})[1]["style"])

    def test_style_carries_on_to_the_next_song_and_through_skip(self):
        self.post({"action": "play", "style": "lofi"})
        self.p.now += 185
        self.p.song = ["Song 2", "Artist", "spotify:track:PL37i9" + "2".rjust(16, "0"), "180000"]
        self.assertEqual(m.handle("GET", None, {})[1]["style"], "lofi")
        self.p.now += 20
        self.assertEqual(self.post({"action": "next"})[1]["style"], "lofi")

    def test_play_that_does_not_switch_is_an_error_not_a_claim(self):
        m.runner = lambda name, script, *a: ("playing\tSolitude\tB\t40\tspotify:track:OTHERSONG0000000000000\t200000\t5\t"
                                             if name == "state" else "true" if name == "running" else "")
        code, body = self.post({"action": "play", "style": "lofi"})
        self.assertEqual(code, 502)
        self.assertIn("same song", body["error"])
        self.assertIsNone(m.handle("GET", None, {})[1]["style"])

    def test_only_spotify_cover_images_reach_the_page(self):
        for art, want in (("https://i.scdn.co/image/ab67616d0000b273", "https://i.scdn.co/image/ab67616d0000b273"),
                          ("https://evil.example/x.png", None), ("javascript:alert(1)", None)):
            m.runner = lambda name, script, *a, art=art: ("playing\tS\tA\t40\tspotify:track:X\t1\t1\t" + art) if name == "state" else "true"
            self.assertEqual(m.handle("GET", None, {})[1]["art"], want)

    def test_friendly_errors(self):
        self.assertIn("Automation", m.friendly("execution error: Not authorized to send Apple events to Spotify. (-1743)"))
        self.assertEqual(m.handle("DELETE", None, {})[0], 405)

    def test_add_playlists_request_names_this_install_and_stays_short(self):
        text = m.add_playlists_request("/x/GoldWare OS", "/x/GoldWare OS/goldware.json", "/x/GoldWare OS/goldware.default.json")
        self.assertIn("/x/GoldWare OS/goldware.json", text)
        self.assertIn("Never edit goldware.default.json", text)
        self.assertIn("office.music.playlists", text)
        self.assertLess(len(text), 1400, "the boss takes one line under 1800 characters")


class Page(unittest.TestCase):
    def test_the_shipped_page_has_no_playlists_and_offers_the_add_button(self):
        def read(*parts):
            with open(os.path.join(REPO, *parts), encoding="utf-8") as f:
                return f.read()
        js, css, html = read("dashboard", "office-music.js"), read("dashboard", "office-music.css"), read("dashboard", "index.html")
        self.assertNotRegex(js, r"spotify:playlist:|open\.spotify\.com/playlist/[A-Za-z0-9]{22}", "no playlist ids in the page")
        self.assertIn("Add my playlists", js)
        self.assertIn("action: 'add-playlists'", js)
        self.assertIn("['mine', 'Mine']", js)
        self.assertIn("mountRecordPlayer.demoFetch", js)
        self.assertIn("if (b.action === 'add-playlists') return { ok: true, demo: true };", js, "demo never reaches the boss")
        self.assertIn('href="/dashboard/office-music.css"', html)
        self.assertIn('src="/dashboard/office-music.js"', html)
        self.assertLess(html.index("/dashboard/office-music.css"), html.index("/custom/office.css"), "custom/office.css still wins")
        self.assertIn("prefers-reduced-motion", css)


from test_server import ServerCase  # noqa: E402  (a dry-run server on a spare port)


class Routes(ServerCase):
    def test_get_lists_the_styles_without_reaching_spotify(self):
        code, body, _ = self.req("/api/office/music")
        self.assertEqual(code, 200)
        self.assertEqual(len(body["styles"]), len(m.STYLES))
        self.assertFalse(body["running"], "a dry run never talks to Spotify")

    def test_posts_only_from_the_dashboard_and_only_known_styles(self):
        self.assertEqual(self.req("/api/office/music", {"action": "pause"}, {"Origin": "http://evil.example"})[0], 403)
        self.assertEqual(self.req("/api/office/music", {"action": "pause"})[0], 403, "no Origin, no Referer")
        own = {"Origin": self.base}
        code, body, _ = self.req("/api/office/music", {"action": "play", "style": "spotify:playlist:37i9dQZF1DX0SM0LYsmbMT"}, own)
        self.assertEqual(code, 422)
        self.assertEqual(self.req("/api/office/music", {"action": "add-playlists", "x": 1}, own)[0], 422, "only the exact button request reaches the boss")


if __name__ == "__main__":
    unittest.main()
