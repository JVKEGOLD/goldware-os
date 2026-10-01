import json
import os
import threading
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import unittest
import urllib.error
import urllib.request

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SERVER = os.path.join(REPO, "server", "goldware_server.py")


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p


class ServerCase(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.mkdtemp()
        cls.root = os.path.join(cls.tmp, "root")
        os.makedirs(cls.root)
        shutil.copy(os.path.join(REPO, "goldware.default.json"), cls.root)
        cls.data = os.path.join(cls.tmp, "data")
        cls.port = free_port()
        cls.base = "http://127.0.0.1:%d" % cls.port
        env = dict(os.environ, GOLDWARE_ROOT=cls.root, GOLDWARE_DATA_ROOT=cls.data,
                   GOLDWARE_OFFICE_EMPTY="1", GOLDWARE_OFFICE_DRY_RUN="1")
        cls.proc = subprocess.Popen([sys.executable, SERVER, "--port", str(cls.port)], env=env,
                                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
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

    def req(self, path, body=None, headers=None, raw=None):
        data = raw if raw is not None else (json.dumps(body).encode() if body is not None else None)
        h = {"Content-Type": "application/json"}
        h.update(headers or {})
        r = urllib.request.Request(self.base + path, data=data, headers=h)
        try:
            resp = urllib.request.urlopen(r, timeout=10)
        except urllib.error.HTTPError as e:
            resp = e
        raw_body = resp.read()
        try:
            parsed = json.loads(raw_body)
        except Exception:
            parsed = raw_body
        return resp.status if hasattr(resp, "status") else resp.code, parsed, resp.headers

    def user_cfg(self):
        return os.path.join(self.root, "goldware.json")

    def default_cfg(self):
        with open(os.path.join(self.root, "goldware.default.json")) as f:
            return json.load(f)


class TestConfig(ServerCase):
    def test_1_default(self):
        code, j, h = self.req("/api/config")
        self.assertEqual(code, 200)
        self.assertEqual(j["source"], "default")
        self.assertIsNone(j["error"])
        self.assertEqual(j["config"]["assistantName"], "GoldWare")
        self.assertEqual(h["Cache-Control"], "no-store")

    def test_2_post_valid_and_backup(self):
        cfg = self.default_cfg()
        cfg["assistantName"] = "Nova"
        code, j, _ = self.req("/api/config", cfg)
        self.assertEqual(code, 200)
        self.assertEqual(j["config"]["assistantName"], "Nova")
        self.assertFalse(os.path.exists(self.user_cfg() + ".bak"))
        cfg["assistantName"] = "Orbit"
        self.assertEqual(self.req("/api/config", cfg)[0], 200)
        with open(self.user_cfg() + ".bak") as f:
            self.assertEqual(json.load(f)["assistantName"], "Nova")
        _, j, _ = self.req("/api/config")
        self.assertEqual(j["source"], "goldware.json")
        self.assertEqual(j["config"]["assistantName"], "Orbit")

    def test_3_post_invalid(self):
        base = self.default_cfg()
        cases = []
        c = dict(base, assistantName="")
        cases.append((c, "assistantName"))
        c = dict(base, assistantName="x" * 25)
        cases.append((c, "assistantName"))
        c = dict(base, accentColor="gold")
        cases.append((c, "accentColor"))
        cases.append((dict(base, port=80), "port"))
        cases.append((dict(base, port=4177), "port"))
        cases.append((dict(base, port="4188"), "port"))
        c = json.loads(json.dumps(base))
        c["dashboard"]["cards"][1]["id"] = c["dashboard"]["cards"][0]["id"]
        cases.append((c, "id"))
        c = json.loads(json.dumps(base))
        c["dashboard"]["cards"][0]["type"] = "bogus"
        cases.append((c, "type"))
        c = json.loads(json.dumps(base))
        c["dashboard"]["cards"][0]["size"] = "xl"
        cases.append((c, "size"))
        for cfg, field in cases:
            code, j, _ = self.req("/api/config", cfg)
            self.assertEqual(code, 400, field)
            self.assertIn(field, j["error"])
        code, j, _ = self.req("/api/config", raw=b"{nope")
        self.assertEqual(code, 400)
        self.assertIn("error", j)

    def test_4_invalid_file_falls_back(self):
        with open(self.user_cfg(), "w") as f:
            f.write("{broken")
        _, j, _ = self.req("/api/config")
        self.assertEqual(j["source"], "default")
        self.assertIn("goldware.json", j["error"])
        with open(self.user_cfg(), "w") as f:
            json.dump(dict(self.default_cfg(), accentColor="red"), f)
        _, j, _ = self.req("/api/config")
        self.assertEqual(j["source"], "default")
        self.assertIn("accentColor", j["error"])
        self.assertEqual(j["config"]["accentColor"], "#C9A24A")

    def test_5_check_flag(self):
        env = dict(os.environ, GOLDWARE_ROOT=self.root)
        r = subprocess.run([sys.executable, SERVER, "--check"], env=env,
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True)
        self.assertEqual(r.returncode, 1)  # file left invalid by the previous test
        os.remove(self.user_cfg())
        r = subprocess.run([sys.executable, SERVER, "--check"], env=env,
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True)
        self.assertEqual(r.returncode, 0, r.stdout)


class TestWork(ServerCase):
    def create(self, rid, **changes):
        changes.setdefault("title", "Write docs")
        return self.req("/api/work", {"create": True, "request_id": rid, "changes": changes})

    def test_create_idempotent_update(self):
        code, j, _ = self.create("req-1", context="notes here")
        self.assertEqual(code, 200)
        t = j["task"]
        import hashlib
        self.assertEqual(t["id"], "t-" + hashlib.sha256(b"req-1").hexdigest()[:12])
        self.assertEqual(t["status"], "inbox")
        self.assertEqual(len(t["revision"]), 12)
        code, j2, _ = self.create("req-1", title="Different")
        self.assertEqual(j2["task"]["id"], t["id"])
        self.assertEqual(j2["task"]["title"], "Write docs")
        _, w, _ = self.req("/api/work")
        self.assertEqual(len([x for x in w["tasks"] if x["id"] == t["id"]]), 1)
        self.assertRegex(w["today"], r"^\d{4}-\d{2}-\d{2}$")
        for k in ("id", "title", "status", "revision", "context", "due_on", "priority", "focus_on"):
            self.assertIn(k, w["tasks"][0])
        code, u, _ = self.req("/api/work", {"id": t["id"], "based_on": t["revision"],
                                            "changes": {"status": "doing", "due_on": "2026-10-01"}})
        self.assertEqual(code, 200)
        self.assertEqual(u["task"]["status"], "doing")
        self.assertNotEqual(u["task"]["revision"], t["revision"])
        # stale revision
        code, e, _ = self.req("/api/work", {"id": t["id"], "based_on": t["revision"],
                                            "changes": {"status": "done"}})
        self.assertEqual(code, 409)
        self.assertEqual(e["error"], "That task changed since you loaded it. Reload and try again.")

    def test_404_and_400(self):
        code, j, _ = self.req("/api/work", {"id": "t-nope", "based_on": "abc", "changes": {"title": "x"}})
        self.assertEqual(code, 404)
        self.assertIn("error", j)
        self.assertEqual(self.req("/api/work", {"create": True, "changes": {"title": "x"}})[0], 400)
        self.assertEqual(self.create("req-bad", status="weird")[0], 400)
        self.assertEqual(self.req("/api/work", [1, 2])[0], 400)
        self.assertEqual(self.req("/api/work", raw=b"nope")[0], 400)
        self.assertEqual(self.req("/api/work", {"create": True, "request_id": "r", "changes": {}})[0], 400)


class TestMisc(ServerCase):
    def test_notes(self):
        _, j, _ = self.req("/api/notes")
        self.assertEqual(j, {"notes": {}})
        code, j, _ = self.req("/api/notes", {"cardId": "notes", "text": "hello"})
        self.assertEqual(code, 200)
        _, j, _ = self.req("/api/notes")
        self.assertEqual(j["notes"]["notes"], "hello")
        self.assertEqual(self.req("/api/notes", {"cardId": "x"})[0], 400)

    def test_system(self):
        code, j, h = self.req("/api/system")
        self.assertEqual(code, 200)
        self.assertGreaterEqual(j["cpu_percent"], 0)
        self.assertGreater(j["memory"]["total_gb"], 0)
        self.assertGreater(j["memory"]["used_gb"], 0)
        self.assertGreater(j["disk"]["total_gb"], 0)
        self.assertIn("free_gb", j["disk"])
        self.assertEqual(h["Cache-Control"], "no-store")

    def test_agents_shape(self):
        code, j, _ = self.req("/api/agents")
        self.assertEqual(code, 200)
        self.assertIsInstance(j, list)
        for a in j:
            self.assertEqual(set(a), {"name", "kind", "pid", "memory_mb"})

    def test_static(self):
        code, body, h = self.req("/")
        self.assertEqual(code, 200)
        self.assertIn("text/html", h["Content-Type"])
        self.assertEqual(h["Cache-Control"], "no-store")
        self.assertEqual(self.req("/nothing")[0], 404)
        self.assertEqual(self.req("/dashboard/missing.html")[0], 404)
        code, _, h = self.req("/logo.png")
        if os.path.exists(os.path.join(REPO, "app", "Resources", "goldware-logo.png")):
            self.assertEqual(code, 200)
            self.assertEqual(h["Content-Type"], "image/png")
        code, _, h = self.req("/fonts/DMSans.ttf")
        if code == 200:
            self.assertEqual(h["Content-Type"], "font/ttf")

    def test_traversal_blocked(self):
        for p in ("/dashboard/../goldware.default.json", "/dashboard/%2e%2e/goldware.default.json",
                  "/docs/../goldware.default.json", "/fonts/..%2f..%2f..%2fdocs/ARCHITECTURE.md",
                  "/docs/%2e%2e/%2e%2e/docs/ARCHITECTURE.md"):
            # use a raw socket so the client does not normalise the path
            s = socket.create_connection(("127.0.0.1", self.port))
            s.sendall(("GET %s HTTP/1.0\r\nHost: 127.0.0.1:%d\r\n\r\n" % (p, self.port)).encode())
            data = b""
            while True:
                chunk = s.recv(4096)
                if not chunk:
                    break
                data += chunk
            s.close()
            self.assertIn(b" 404 ", data.split(b"\r\n")[0], p)
            self.assertNotIn(b"GoldWare OS contract", data, p)

    def test_origin(self):
        body = {"cardId": "o", "text": "t"}
        code, j, _ = self.req("/api/notes", body, {"Origin": "http://evil.example"})
        self.assertEqual(code, 403)
        self.assertIn("error", j)
        self.assertEqual(self.req("/api/notes", body, {"Origin": self.base})[0], 200)
        self.assertEqual(self.req("/api/notes", body,
                                  {"Origin": "http://localhost:%d" % self.port})[0], 200)
        self.assertEqual(self.req("/api/notes", body)[0], 200)


def raw_request(port, data, read=True):
    """Send raw bytes, return the full response bytes (no client-side normalising)."""
    s = socket.create_connection(("127.0.0.1", port), timeout=10)
    s.sendall(data)
    out = b""
    try:
        while read:
            chunk = s.recv(4096)
            if not chunk:
                break
            out += chunk
    except socket.timeout:
        pass
    s.close()
    return out


def status_of(resp):
    return int(resp.split(b" ", 2)[1])


class TestHardening(ServerCase):
    def raw(self, method, path, headers=None, body=b""):
        h = {"Host": "127.0.0.1:%d" % self.port, "Connection": "close"}
        h.update(headers or {})
        head = "%s %s HTTP/1.1\r\n" % (method, path) + "".join("%s: %s\r\n" % kv for kv in h.items())
        return raw_request(self.port, head.encode() + b"\r\n" + body)

    # (1) DNS rebinding
    def test_host_header_checked_on_get_and_post(self):
        for host in ("evil.example", "evil.example:%d" % self.port, "127.0.0.1", "127.0.0.1:1",
                     "127.0.0.1.evil.example:%d" % self.port, ""):
            self.assertEqual(status_of(self.raw("GET", "/api/notes", {"Host": host})), 403, host)
            self.assertEqual(status_of(self.raw("GET", "/", {"Host": host})), 403, host)
            body = b'{"cardId":"a","text":"b"}'
            self.assertEqual(status_of(self.raw("POST", "/api/notes", {
                "Host": host, "Content-Type": "application/json",
                "Content-Length": str(len(body))}, body)), 403, host)
        for host in ("127.0.0.1:%d" % self.port, "localhost:%d" % self.port, "LOCALHOST:%d" % self.port):
            self.assertEqual(status_of(self.raw("GET", "/api/notes", {"Host": host})), 200, host)

    def test_origin_checked_on_get_and_null_origin_rejected(self):
        self.assertEqual(self.req("/api/notes", headers={"Origin": "http://evil.example"})[0], 403)
        self.assertEqual(self.req("/api/notes", headers={"Origin": "null"})[0], 403)
        self.assertEqual(self.req("/api/notes", {"cardId": "n", "text": "t"}, {"Origin": "null"})[0], 403)
        self.assertEqual(self.req("/api/notes", headers={"Origin": self.base})[0], 200)

    def test_post_requires_json_content_type(self):
        body = b'{"cardId":"ct","text":"x"}'
        for ct in ("text/plain", "application/x-www-form-urlencoded", "multipart/form-data; boundary=x", ""):
            h = {"Content-Length": str(len(body))}
            if ct:
                h["Content-Type"] = ct
            self.assertEqual(status_of(self.raw("POST", "/api/notes", h, body)), 415, ct)
        h = {"Content-Type": "Application/JSON; charset=utf-8", "Content-Length": str(len(body))}
        self.assertEqual(status_of(self.raw("POST", "/api/notes", h, body)), 200)
        _, j, _ = self.req("/api/notes")
        self.assertEqual(j["notes"]["ct"], "x")

    # (2) no permissive CORS
    def test_no_cors_headers(self):
        for path in ("/api/config", "/api/notes", "/"):
            _, _, h = self.req(path, headers={"Origin": self.base})
            self.assertFalse([k for k in h.keys() if k.lower().startswith("access-control-")], path)
        resp = self.raw("OPTIONS", "/api/notes", {"Origin": "http://evil.example"})
        self.assertNotIn(b"access-control", resp.lower())
        self.assertNotEqual(status_of(resp), 200)

    # (3) traversal
    def test_traversal_variants(self):
        paths = ("/dashboard/%00", "/dashboard/index.html%00.png", "/dashboard/..%5cgoldware.default.json",
                 "/dashboard/..\\goldware.default.json", "/dashboard/%252e%252e/goldware.default.json",
                 "/dashboard//etc/passwd", "/dashboard/%2fetc%2fpasswd", "/docs/..%2f..%2fgoldware.default.json",
                 "/dashboard/....//goldware.default.json", "/fonts/%00../../../../etc/passwd")
        for p in paths:
            resp = self.raw("GET", p)
            self.assertEqual(status_of(resp), 404, p)
            self.assertNotIn(b"assistantName", resp, p)
            self.assertNotIn(b"root:", resp, p)

    def test_symlink_escape_blocked(self):
        link = os.path.join(REPO, "dashboard", "zz-test-link.txt")
        target = os.path.join(self.tmp, "secret.txt")
        with open(target, "w") as f:
            f.write("TOPSECRET")
        os.symlink(target, link)
        try:
            resp = self.raw("GET", "/dashboard/zz-test-link.txt")
            self.assertEqual(status_of(resp), 404)
            self.assertNotIn(b"TOPSECRET", resp)
        finally:
            os.unlink(link)

    # (5) body limits, malformed JSON
    def test_body_too_large_413(self):
        big = b'{"cardId":"big","text":"' + b"a" * (1024 * 1024) + b'"}'
        resp = self.raw("POST", "/api/notes", {"Content-Type": "application/json",
                                                "Content-Length": str(len(big))}, big[:2000])
        self.assertEqual(status_of(resp), 413)
        # server is still healthy afterwards
        self.assertEqual(self.req("/api/notes")[0], 200)

    def test_bad_content_length_and_chunked(self):
        h = {"Content-Type": "application/json"}
        self.assertEqual(status_of(self.raw("POST", "/api/notes", dict(h, **{"Content-Length": "abc"}))), 400)
        self.assertEqual(status_of(self.raw("POST", "/api/notes", dict(h, **{"Content-Length": "-5"}))), 400)
        self.assertEqual(status_of(self.raw("POST", "/api/notes", dict(h, **{"Transfer-Encoding": "chunked"}),
                                            b"0\r\n\r\n")), 411)

    def test_malformed_json_variants(self):
        for raw in (b"", b"{", b"[", b"NaN", b'{"cardId":"a","text":NaN}', b"\xff\xfe", b"[" * 100000):
            code, j, _ = self.req("/api/notes", raw=raw)
            self.assertEqual(code, 400, raw[:20])
            self.assertIn("error", j)
        self.assertEqual(self.req("/api/config", raw=b'{"assistantName":"A","accentColor":"#C9A24A","x":Infinity}')[0], 400)

    def test_concurrent_writes_stay_consistent(self):
        errors = []

        def worker(i):
            try:
                for k in range(8):
                    c1, _, _ = self.req("/api/work", {"create": True, "request_id": "c-%d-%d" % (i, k),
                                                      "changes": {"title": "t%d-%d" % (i, k)}})
                    c2, _, _ = self.req("/api/notes", {"cardId": "n%d" % i, "text": "v%d" % k})
                    if c1 != 200 or c2 != 200:
                        errors.append((c1, c2))
            except Exception as e:  # pragma: no cover
                errors.append(repr(e))

        ts = [threading.Thread(target=worker, args=(i,)) for i in range(8)]
        for t in ts:
            t.start()
        for t in ts:
            t.join()
        self.assertEqual(errors, [])
        _, w, _ = self.req("/api/work")
        self.assertEqual(len([t for t in w["tasks"] if t["title"].startswith("t")]), 64)
        with open(os.path.join(self.data, "tasks.json")) as f:
            json.load(f)
        self.assertEqual([n for n in os.listdir(self.data) if n.endswith(".tmp")], [])

    def test_corrupt_data_is_quarantined_not_500(self):
        os.makedirs(self.data, exist_ok=True)
        for name, url, key in (("tasks.json", "/api/work", "tasks"), ("notes.json", "/api/notes", "notes")):
            path = os.path.join(self.data, name)
            with open(path, "w") as f:
                f.write("{this is not json")
            code, j, _ = self.req(url)
            self.assertEqual(code, 200, name)
            self.assertFalse(j[key])
            kept = [n for n in os.listdir(self.data) if n.startswith(name + ".corrupt-")]
            self.assertEqual(len(kept), 1, name)
            with open(os.path.join(self.data, kept[0])) as f:
                self.assertEqual(f.read(), "{this is not json")
        # wrong shape is treated the same, and writing works again
        with open(os.path.join(self.data, "tasks.json"), "w") as f:
            json.dump({"tasks": ["oops", 5]}, f)
        self.assertEqual(self.req("/api/work")[0], 200)
        self.assertEqual(self.req("/api/work", {"create": True, "request_id": "after", "changes": {"title": "ok"}})[0], 200)

    # (6) config validation completeness
    def test_config_limits(self):
        base = self.default_cfg()

        def mod(fn):
            c = json.loads(json.dumps(base))
            fn(c)
            return c
        cards = lambda c: c["dashboard"]["cards"]
        cases = [
            ("wakePhrase", mod(lambda c: c.update(wakePhrase=5))),
            ("wakePhrase", mod(lambda c: c.update(wakePhrase="x" * 101))),
            ("wakeAliases", mod(lambda c: c.update(wakeAliases=["a"] * 51))),
            ("wakeAliases", mod(lambda c: c.update(wakeAliases=["a" * 101]))),
            ("letsWork", mod(lambda c: c.update(letsWork="x"))),
            ("letsWork.command", mod(lambda c: c.update(letsWork={"command": "a\nb"}))),
            ("letsWork.command", mod(lambda c: c.update(letsWork={"command": 5}))),
            ("letsWork.terminal", mod(lambda c: c.update(letsWork={"terminal": "Warp"}))),
            ("letsWork.profile", mod(lambda c: c.update(letsWork={"profile": 5}))),
            ("models.local", mod(lambda c: c["models"].update(local=5))),
            ("models.whisper", mod(lambda c: c["models"].update(whisper="../../etc/passwd"))),
            ("models.whisper", mod(lambda c: c["models"].update(whisper="a\\b.bin"))),
            ("dashboard.layout", mod(lambda c: c["dashboard"].update(layout="x" * 65))),
            ("dashboard.layout", mod(lambda c: c["dashboard"].update(layout=3))),
            ("at most", mod(lambda c: c["dashboard"].update(cards=[
                {"id": "c%d" % i, "type": "clock", "size": "s"} for i in range(101)]))),
            (".id", mod(lambda c: cards(c)[0].update(id="has space"))),
            (".id", mod(lambda c: cards(c)[0].update(id="../x"))),
            (".id", mod(lambda c: cards(c)[0].update(id="a" * 65))),
            (".id", mod(lambda c: cards(c)[0].update(id=7))),
            (".title", mod(lambda c: cards(c)[0].update(title="t" * 101))),
            (".options", mod(lambda c: cards(c)[0].update(options=[1]))),
            ("options.html", mod(lambda c: cards(c)[0].update(options={"html": "x" * (200 * 1024 + 1)}))),
            ("options.html", mod(lambda c: cards(c)[0].update(options={"html": 5}))),
            ("options.url", mod(lambda c: cards(c)[0].update(options={"url": "javascript:alert(1)"}))),
            ("options.url", mod(lambda c: cards(c)[0].update(options={"url": "//evil.example/x"}))),
            ("options.url", mod(lambda c: cards(c)[0].update(options={"url": 5}))),
            ("options.links", mod(lambda c: cards(c)[0].update(options={"links": "nope"}))),
            ("options.links", mod(lambda c: cards(c)[0].update(options={"links": [{"label": "a", "url": "javascript:1"}]}))),
            ("options.links", mod(lambda c: cards(c)[0].update(options={"links": [{"label": 3, "url": "/x"}]}))),
        ]
        for field, cfg in cases:
            code, j, _ = self.req("/api/config", cfg)
            self.assertEqual(code, 400, field)
            self.assertIn(field, j["error"])
        self.assertFalse(os.path.exists(self.user_cfg()))
        ok = mod(lambda c: cards(c)[0].update(options={"html": "x" * (200 * 1024),
                                                         "url": "/docs/CUSTOMIZING.md"}))
        self.assertEqual(self.req("/api/config", ok)[0], 200)
        many = mod(lambda c: c["dashboard"].update(cards=[
            {"id": "c%d" % i, "type": "clock", "size": "s"} for i in range(100)]))
        self.assertEqual(self.req("/api/config", many)[0], 200)

    def test_zz_config_post_writes_only_user_file(self):
        before = set(os.listdir(self.root))
        for _ in range(2):
            self.assertEqual(self.req("/api/config", self.default_cfg())[0], 200)
        after = set(os.listdir(self.root))
        self.assertEqual(after - before - {"goldware.json", "goldware.json.bak"}, set())
        # the body cannot influence the destination: path-like fields are just data or rejected
        evil = dict(self.default_cfg(), **{"path": "../../x", "file": "/etc/passwd"})
        self.assertEqual(self.req("/api/config", evil)[0], 200)
        self.assertEqual(set(os.listdir(self.root)) - {"goldware.json", "goldware.json.bak", "goldware.default.json"}, set())

    def test_errors_do_not_leak_paths(self):
        resp = self.raw("GET", "/dashboard/%00")
        self.assertNotIn(REPO.encode(), resp)

    # (4) iframe sandbox
    def test_dashboard_sandbox_rules(self):
        with open(os.path.join(REPO, "dashboard", "index.html"), encoding="utf-8") as f:
            html = f.read()
        import re
        # html card: scripts only, never same-origin
        m = re.search(r'sandbox: "([^"]*)", srcdoc', html)
        self.assertIsNotNone(m)
        self.assertEqual(m.group(1), "allow-scripts")
        # embed card: same-origin permission only on the branch for non-local URLs
        m = re.search(r'sandbox: isLocalUrl\(o\.url\) \? "([^"]*)" : "([^"]*)"', html)
        self.assertIsNotNone(m)
        self.assertNotIn("allow-same-origin", m.group(1))
        self.assertIn("allow-scripts", m.group(1))
        self.assertNotIn("allow-top-navigation", html)
        self.assertIn("(?!\\/)", html)  # protocol-relative URLs are not "safe"

    def test_vision_tab_draws_each_hand_gesture(self):
        with open(os.path.join(REPO, "dashboard", "index.html"), encoding="utf-8") as f:
            html = f.read()
        import re
        for g in ("scan", "file", "point", "pinch", "scroll", "open"):
            self.assertRegex(html, r'data-gesture="%s"><div class="gicon"><svg class="hand-art"' % g, g)
        # the lock, send, lock up and clear out cards are emoji, not hands
        for g in ("lock", "send", "letswork", "lockup", "clearout"):
            self.assertIn('data-gesture="%s"' % g, html)
        self.assertRegex(html, r'data-gesture="letswork"><div class="gicon"><svg class="hand-art"')
        self.assertNotRegex(html, r'(?i)thumbs up[^<]{0,12}lock|Thumbs up: lock')
        # 6 hand cards, the Let's work card, and 4 quadrant hands
        self.assertEqual(len(re.findall(r'<svg class="hand-art"', html)), 11)

    def test_office_tab_and_assets(self):
        import re
        with open(os.path.join(REPO, "dashboard", "index.html"), encoding="utf-8") as f:
            html = f.read()
        tabs = re.findall(r'<button class="topbar-tab" data-tab="(\w+)"', html)
        self.assertEqual(tabs, ["dashboard", "voice", "vision", "office"])  # Office is the fourth tab
        self.assertIn('id="tab-office"', html)
        self.assertIn('"office"].indexOf(t)', html)             # the router knows it
        for sel in ('id="office-canvas"', 'id="office-roster"', 'id="office-dock"', 'id="office-stage"'):
            self.assertIn(sel, html)
        self.assertIn("/dashboard/office.js", html)
        self.assertIn("/dashboard/office.css", html)
        for path, ctype in (("/dashboard/office.js", "javascript"), ("/dashboard/office.css", "text/css")):
            code, body, h = self.req(path)
            self.assertEqual(code, 200, path)
            self.assertIn(ctype, h["Content-Type"])
        with open(os.path.join(REPO, "dashboard", "office.js"), encoding="utf-8") as f:
            js = f.read()
        for ep in ("/api/office/agents", "/api/office/screen", "/api/office/send", "/api/office/focus",
                   "/api/office/board", "/api/office/usage", "/api/office/helper"):
            self.assertIn(ep, js)
        # nothing from the old private world, and no mascot art (words split so this file stays clean)
        banned = "(?i)" + "|".join(["al" + "len", "masc" + "ot", "bean" + "ie", "kine" + "tic", "mat" + "rix", "vau" + "lt",
                                    "/api/clients", "/api/document", "\u2014"])
        for name in ("office.js", "office.css"):
            with open(os.path.join(REPO, "dashboard", name), encoding="utf-8") as f:
                text = f.read()
            self.assertNotRegex(text, banned, name)
        self.assertNotRegex(html, r"(?i)" + "|".join(["al" + "len", "masc" + "ot", "bean" + "ie"]))

    def test_office_endpoints_return_json(self):
        for path in ("/api/office/agents", "/api/office/board", "/api/office/usage"):
            code, j, h = self.req(path)
            self.assertEqual(code, 200, path)
            self.assertIsInstance(j, dict, path)
            self.assertIn("application/json", h["Content-Type"])
        self.assertIsInstance(self.req("/api/office/agents")[1]["agents"], list)
        self.assertEqual(self.req("/api/office/screen?id=nope")[0], 404)

    def test_shortcut_buttons_and_card(self):
        with open(os.path.join(REPO, "dashboard", "index.html"), encoding="utf-8") as f:
            html = f.read()
        # the Shortcuts card renders three fixed goldwareos:// buttons
        self.assertIn('case "shortcuts"', html)
        for route in ("lets-work", "lock-up", "clear-out"):
            self.assertIn('href: "goldwareos://" + c.route', html)
            self.assertIn('route: "%s"' % route, html)
            # and the Voice tab docs carry a plain link too
            self.assertIn('href="goldwareos://%s"' % route, html)
        self.assertNotIn("goldwareos://\" + o.", html)  # never built from config
        with open(os.path.join(REPO, "goldware.default.json"), encoding="utf-8") as f:
            cfg = json.load(f)
        cards = cfg["dashboard"]["cards"]
        self.assertIn("shortcuts", [c["type"] for c in cards])
        self.assertEqual(cfg["letsWork"]["profile"], "GoldWare")
        self.assertEqual(self.req("/api/config", cfg)[0], 200)

    def test_goldware_iterm_profile(self):
        path = os.path.join(REPO, "app", "Resources", "iTerm", "goldware-profile.json")
        with open(path, encoding="utf-8") as f:
            raw = f.read()
        prof = json.loads(raw)["Profiles"][0]
        self.assertEqual(prof["Name"], "GoldWare")
        self.assertEqual(prof["Guid"], "goldware-os-profile")
        self.assertTrue(prof["Normal Font"].startswith("JetBrainsMonoNF-Regular 15"))
        # a look only: nothing that would run in every window Let's work opens
        for k in ("Initial Text", "Custom Command", "Command"):
            self.assertNotIn(k, prof)

    def test_sandboxed_frame_origin_cannot_call_api(self):
        # A sandboxed iframe without allow-same-origin sends Origin: null.
        self.assertEqual(self.req("/api/config", headers={"Origin": "null"})[0], 403)
        self.assertEqual(self.req("/api/config", self.default_cfg(), {"Origin": "null"})[0], 403)
        self.assertEqual(self.req("/api/work", {"create": True, "request_id": "z", "changes": {"title": "x"}},
                                  {"Origin": "null"})[0], 403)

    def test_frame_ancestors_header(self):
        _, _, h = self.req("/")
        self.assertIn("frame-ancestors 'self'", h["Content-Security-Policy"])
        self.assertEqual(h["X-Content-Type-Options"], "nosniff")


class TestStartup(unittest.TestCase):
    def run_server(self, *args, **env):
        e = dict(os.environ, **env)
        return subprocess.run([sys.executable, SERVER] + list(args), env=e, stdout=subprocess.PIPE,
                              stderr=subprocess.PIPE, universal_newlines=True, timeout=20)

    def test_port_in_use_exits_cleanly(self):
        blocker = socket.socket()
        blocker.bind(("127.0.0.1", 0))
        blocker.listen(1)
        port = blocker.getsockname()[1]
        tmp = tempfile.mkdtemp()
        try:
            r = self.run_server("--port", str(port), GOLDWARE_DATA_ROOT=tmp)
        finally:
            blocker.close()
            shutil.rmtree(tmp, ignore_errors=True)
        self.assertEqual(r.returncode, 3)
        self.assertIn("Cannot listen on 127.0.0.1:%d" % port, r.stderr)
        self.assertNotIn("Traceback", r.stderr)

    def test_bad_port_values(self):
        tmp = tempfile.mkdtemp()
        try:
            self.assertEqual(self.run_server("--port", "80", GOLDWARE_DATA_ROOT=tmp).returncode, 2)
            r = self.run_server(GOLDWARE_PORT="abc", GOLDWARE_DATA_ROOT=tmp)
            self.assertEqual(r.returncode, 2)
            self.assertNotIn("Traceback", r.stderr)
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    def test_binds_loopback_only(self):
        sys.path.insert(0, os.path.join(REPO, "server"))
        try:
            import goldware_server
        finally:
            sys.path.pop(0)
        httpd = goldware_server.make_server(0)
        try:
            self.assertEqual(httpd.server_address[0], "127.0.0.1")
        finally:
            httpd.server_close()
        with open(SERVER, encoding="utf-8") as f:
            src = f.read()
        self.assertNotIn("0.0.0.0", src)
        self.assertNotIn('("", ', src)

    def test_check_mode(self):
        tmp = tempfile.mkdtemp()
        try:
            def check():
                return self.run_server("--check", GOLDWARE_ROOT=tmp)
            r = check()  # no default file at all
            self.assertEqual(r.returncode, 1)
            self.assertIn("goldware.default.json", r.stdout)
            shutil.copy(os.path.join(REPO, "goldware.default.json"), tmp)
            r = check()
            self.assertEqual(r.returncode, 0, r.stdout)
            self.assertIn("Config OK", r.stdout)
            with open(os.path.join(tmp, "goldware.json"), "w") as f:
                json.dump({"assistantName": "x", "accentColor": "#C9A24A", "port": 4177}, f)
            r = check()
            self.assertEqual(r.returncode, 1)
            self.assertIn("port", r.stdout)
            os.remove(os.path.join(tmp, "goldware.json"))
            with open(os.path.join(tmp, "goldware.default.json"), "w") as f:
                json.dump({"assistantName": "", "accentColor": "#C9A24A"}, f)
            r = check()  # an invalid default is also reported
            self.assertEqual(r.returncode, 1)
            self.assertIn("assistantName", r.stdout)
        finally:
            shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    unittest.main()
