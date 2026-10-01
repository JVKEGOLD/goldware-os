import json
import os
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
        env = dict(os.environ, GOLDWARE_ROOT=cls.root, GOLDWARE_DATA_ROOT=cls.data)
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
                  "/docs/../docs/ARCHITECTURE.md", "/fonts/..%2f..%2f..%2fdocs/ARCHITECTURE.md",
                  "/docs/%2e%2e/%2e%2e/docs/ARCHITECTURE.md"):
            # use a raw socket so the client does not normalise the path
            s = socket.create_connection(("127.0.0.1", self.port))
            s.sendall(("GET %s HTTP/1.0\r\nHost: x\r\n\r\n" % p).encode())
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


if __name__ == "__main__":
    unittest.main()
