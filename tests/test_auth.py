"""Unit tests for browser sessions, sign-in throttling and CSRF checks.

Run: python3 -m unittest discover -s tests   (no container needed)
"""
import http.client
import io
import json
import pathlib
import sys
import threading
import unittest
from http.server import ThreadingHTTPServer
from unittest import mock

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent))
import inventory  # noqa: E402


class Clock:
    def __init__(self):
        self.t = 1_000_000.0

    def __call__(self):
        return self.t


class SessionStoreTest(unittest.TestCase):
    def setUp(self):
        self.clock = Clock()
        patcher = mock.patch.object(inventory, "now", self.clock)
        patcher.start()
        self.addCleanup(patcher.stop)

    def test_create_and_get(self):
        store = inventory.SessionStore(idle=60, maximum=600, limit=10)
        token = store.create("push", "push")
        self.assertEqual(store.get(token)["role"], "push")
        self.assertIsNone(store.get("x" * 43))
        self.assertIsNone(store.get("not a token"))

    def test_only_token_hash_is_stored(self):
        store = inventory.SessionStore()
        token = store.create("pull", "pull")
        self.assertNotIn(token, store.items)
        self.assertNotIn(token, json.dumps(list(store.items)))

    def test_idle_timeout_and_sliding_refresh(self):
        store = inventory.SessionStore(idle=60, maximum=600, limit=10)
        token = store.create("pull", "pull")
        self.clock.t += 50
        self.assertIsNotNone(store.get(token))  # refreshes idle timer
        self.clock.t += 50
        self.assertIsNotNone(store.get(token))
        self.clock.t += 61
        self.assertIsNone(store.get(token))
        self.assertEqual(store.items, {})

    def test_absolute_lifetime(self):
        store = inventory.SessionStore(idle=60, maximum=100, limit=10)
        token = store.create("pull", "pull")
        for _ in range(3):
            self.clock.t += 30
            self.assertIsNotNone(store.get(token))
        self.clock.t += 30  # 120s old, though never idle
        self.assertIsNone(store.get(token))

    def test_delete(self):
        store = inventory.SessionStore()
        token = store.create("pull", "pull")
        store.delete(token)
        self.assertIsNone(store.get(token))

    def test_limit_evicts_least_recently_used(self):
        store = inventory.SessionStore(idle=1000, maximum=1000, limit=2)
        first = store.create("a", "pull")
        self.clock.t += 1
        second = store.create("b", "pull")
        self.clock.t += 1
        store.get(first)  # first is now more recent than second
        third = store.create("c", "pull")
        self.assertIsNotNone(store.get(first))
        self.assertIsNone(store.get(second))
        self.assertIsNotNone(store.get(third))


class ThrottleTest(unittest.TestCase):
    def setUp(self):
        self.clock = Clock()
        patcher = mock.patch.object(inventory, "now", self.clock)
        patcher.start()
        self.addCleanup(patcher.stop)

    def test_client_lockout_then_recovery(self):
        throttle = inventory.Throttle(window=100, per_client=3, per_user=50)
        for _ in range(3):
            self.assertEqual(throttle.retry_after("1.2.3.4", "push", False), 0)
            throttle.fail("1.2.3.4", "push", False)
        self.assertGreater(throttle.retry_after("1.2.3.4", "push", False), 0)
        self.assertEqual(throttle.retry_after("5.6.7.8", "pull", False), 0)
        self.clock.t += 101
        self.assertEqual(throttle.retry_after("1.2.3.4", "push", False), 0)

    def test_username_lock_applies_to_public_clients_only(self):
        throttle = inventory.Throttle(window=100, per_client=100, per_user=3)
        for n in range(3):
            throttle.fail(f"8.8.8.{n}", "push", False)
        self.assertGreater(throttle.retry_after("9.9.9.9", "push", False), 0)
        self.assertEqual(throttle.retry_after("192.168.1.5", "push", True), 0)

    def test_private_failures_do_not_lock_username(self):
        throttle = inventory.Throttle(window=100, per_client=100, per_user=3)
        for n in range(5):
            throttle.fail(f"10.0.0.{n}", "push", True)
        self.assertEqual(throttle.retry_after("8.8.8.8", "push", False), 0)


class HelpersTest(unittest.TestCase):
    def test_same_host(self):
        self.assertTrue(inventory.same_host("https://reg.example.com", "reg.example.com"))
        self.assertTrue(inventory.same_host("https://reg.example.com:443", "reg.example.com"))
        self.assertTrue(inventory.same_host("http://10.0.0.5:5000", "10.0.0.5:5000"))
        self.assertTrue(inventory.same_host("https://REG.example.com", "reg.example.com"))
        self.assertFalse(inventory.same_host("https://evil.example", "reg.example.com"))
        self.assertFalse(inventory.same_host("http://10.0.0.5:5001", "10.0.0.5:5000"))
        self.assertFalse(inventory.same_host("null", "reg.example.com"))
        self.assertFalse(inventory.same_host(None, "reg.example.com"))
        self.assertFalse(inventory.same_host("https://reg.example.com.evil.example", "reg.example.com"))

    def test_parse_basic(self):
        self.assertEqual(inventory.parse_basic("Basic cHVzaDpzZWNyZXQ6eA=="), ("push", "secret:x"))
        self.assertIsNone(inventory.parse_basic("Bearer abc"))
        self.assertIsNone(inventory.parse_basic(None))

    def test_verify_password_rejects_bad_input_without_running_htpasswd(self):
        with mock.patch("subprocess.run") as run:
            self.assertFalse(inventory.verify_password("bad user", "pw", "/x"))
            self.assertFalse(inventory.verify_password("push", "", "/x"))
            self.assertFalse(inventory.verify_password("push", "a\nb", "/x"))
            self.assertFalse(inventory.verify_password(None, "pw", "/x"))
            run.assert_not_called()


class HandlerTest(unittest.TestCase):
    """Runs the real handler in-process with a fake password check."""

    HOST = "reg.example.com"

    @classmethod
    def setUpClass(cls):
        # One server and one event loop for the whole class. Starting and, above
        # all, stopping a server costs ~0.5 s (serve_forever polls every 0.5 s),
        # which used to dominate the suite. The server itself is stateless per
        # request; everything a request reads is patched per test in setUp.
        cls.server = ThreadingHTTPServer(("127.0.0.1", 0), inventory.Handler)
        cls.server_thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.server_thread.start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()   # returns as soon as the loop has stopped
        cls.server_thread.join(timeout=5)
        assert not cls.server_thread.is_alive(), "handler server thread did not stop"
        cls.server.server_close()

    def setUp(self):
        # Every test starts from an empty session store, a fresh throttle and a
        # fresh clock: no request data carries over from the test before it.
        self.clock = Clock()
        patches = [
            mock.patch.object(inventory, "now", self.clock),
            mock.patch.object(inventory, "SESSIONS", inventory.SessionStore(idle=60, maximum=600, limit=100)),
            mock.patch.object(inventory, "THROTTLE", inventory.Throttle(window=900, per_client=4, per_user=100)),
            mock.patch.object(inventory, "role_for", lambda u, p: {("push", "pw-push"): "push", ("pull", "pw-pull"): "pull"}.get((u, p))),
            mock.patch.object(inventory, "cached_inventory", lambda: {"repositories": []}),
            mock.patch.object(inventory, "delete_images", lambda body: {"deleted": False, "preview": True}),
            mock.patch("sys.stderr", new=io.StringIO()),
        ]
        for p in patches:
            p.start()
            self.addCleanup(p.stop)

    def call(self, method, path, body=None, headers=None, scheme="https", client="203.0.113.9", private=False):
        conn = http.client.HTTPConnection("127.0.0.1", self.server.server_address[1], timeout=5)
        h = {"Host": self.HOST, "X-Registreasy-Scheme": scheme, "X-Registreasy-Client": client,
             "X-Registreasy-Private": "1" if private else "0"}
        if body is not None:
            h["Content-Type"] = "application/json"
            body = json.dumps(body)
        h.update(headers or {})
        conn.request(method, path, body=body, headers=h)
        r = conn.getresponse()
        data = r.read()
        conn.close()
        return r.status, dict(r.getheaders()), (json.loads(data) if data and r.getheader("Content-Type", "").startswith("application/json") else data)

    def signin(self, user="push", password="pw-push", **kw):
        headers = {"Origin": f"https://{self.HOST}", "X-Registreasy-Action": "signin"}
        headers.update(kw.pop("headers", {}))
        return self.call("POST", "/api/session", {"username": user, "password": password}, headers=headers, **kw)

    def cookie(self, set_cookie):
        return set_cookie.split(";", 1)[0]

    def test_signin_sets_hardened_cookie_over_https(self):
        status, headers, body = self.signin()
        self.assertEqual(status, 200)
        self.assertEqual(body["role"], "push")
        attrs = [a.strip() for a in headers["Set-Cookie"].split(";")]
        self.assertTrue(attrs[0].startswith("__Host-registreasy_session="))
        for attr in ("Path=/", "HttpOnly", "SameSite=Strict", "Secure"):
            self.assertIn(attr, attrs)
        self.assertFalse(any(a.lower().startswith(("expires", "max-age", "domain")) for a in attrs))
        self.assertIn("max-age=", headers.get("Strict-Transport-Security", ""))

    def test_signin_over_lan_http_cookie_is_not_secure(self):
        status, headers, _ = self.signin(scheme="http", client="192.168.1.20", private=True,
                                         headers={"Origin": f"http://{self.HOST}"})
        self.assertEqual(status, 200)
        self.assertTrue(headers["Set-Cookie"].startswith("registreasy_session="))
        self.assertNotIn("Secure", headers["Set-Cookie"])
        self.assertNotIn("Strict-Transport-Security", headers)

    def test_session_survives_reload_and_signout_revokes_it(self):
        _, headers, _ = self.signin()
        cookie = {"Cookie": self.cookie(headers["Set-Cookie"])}
        status, _, body = self.call("GET", "/api/session", headers=cookie)
        self.assertEqual((status, body["username"], body["can_delete"]), (200, "push", True))
        self.assertEqual(self.call("GET", "/api/inventory", headers=cookie)[0], 200)
        out = self.call("DELETE", "/api/session", headers={**cookie, "Origin": f"https://{self.HOST}", "X-Registreasy-Action": "signout"})
        self.assertEqual(out[0], 200)
        self.assertIn("Max-Age=0", out[1]["Set-Cookie"])
        self.assertEqual(self.call("GET", "/api/session", headers=cookie)[0], 401)
        self.assertEqual(self.call("GET", "/api/inventory", headers=cookie)[0], 401)

    def test_idle_session_expires(self):
        _, headers, _ = self.signin()
        cookie = {"Cookie": self.cookie(headers["Set-Cookie"])}
        self.clock.t += 61
        self.assertEqual(self.call("GET", "/api/inventory", headers=cookie)[0], 401)

    def test_https_cookie_ignored_on_plain_http(self):
        _, headers, _ = self.signin()
        token = self.cookie(headers["Set-Cookie"]).split("=", 1)[1]
        status = self.call("GET", "/api/session", headers={"Cookie": f"__Host-registreasy_session={token}"}, scheme="http")[0]
        self.assertEqual(status, 401)

    def test_new_token_on_every_signin(self):
        _, first, _ = self.signin()
        _, second, _ = self.signin(headers={"Cookie": self.cookie(first["Set-Cookie"])})
        self.assertNotEqual(self.cookie(first["Set-Cookie"]), self.cookie(second["Set-Cookie"]))
        self.assertEqual(self.call("GET", "/api/session", headers={"Cookie": self.cookie(first["Set-Cookie"])})[0], 401)

    def test_signin_requires_action_header_and_origin(self):
        self.assertEqual(self.signin(headers={"X-Registreasy-Action": ""})[0], 403)
        self.assertEqual(self.signin(headers={"Origin": "https://evil.example"})[0], 403)
        status = self.call("POST", "/api/session", {"username": "push", "password": "pw-push"},
                           headers={"X-Registreasy-Action": "signin"})[0]
        self.assertEqual(status, 403)  # no Origin at all

    def test_signin_requires_json(self):
        status = self.call("POST", "/api/session", headers={"Origin": f"https://{self.HOST}", "X-Registreasy-Action": "signin",
                                                            "Content-Type": "application/x-www-form-urlencoded"})[0]
        self.assertEqual(status, 400)

    def test_wrong_password_is_generic_and_throttled(self):
        for _ in range(4):
            status, _, body = self.signin(password="wrong")
            self.assertEqual(status, 401)
            self.assertNotIn("push", json.dumps(body))
        status, headers, _ = self.signin()  # even the right password waits
        self.assertEqual(status, 429)
        self.assertGreater(int(headers["Retry-After"]), 0)

    def test_basic_auth_still_works_for_scripts(self):
        status = self.call("GET", "/api/inventory", headers={"Authorization": "Basic cHVsbDpwdy1wdWxs"})[0]
        self.assertEqual(status, 200)
        status = self.call("POST", "/api/delete", {"repo": "x", "preview": True},
                           headers={"Authorization": "Basic cHVzaDpwdy1wdXNo", "X-Registreasy-Action": "delete"})[0]
        self.assertEqual(status, 200)

    def test_cookie_delete_needs_origin(self):
        _, headers, _ = self.signin()
        cookie = self.cookie(headers["Set-Cookie"])
        base = {"Cookie": cookie, "X-Registreasy-Action": "delete"}
        self.assertEqual(self.call("POST", "/api/delete", {"repo": "x"}, headers=base)[0], 403)
        self.assertEqual(self.call("POST", "/api/delete", {"repo": "x"}, headers={**base, "Origin": "https://evil.example"})[0], 403)
        self.assertEqual(self.call("POST", "/api/delete", {"repo": "x"}, headers={**base, "Origin": f"https://{self.HOST}"})[0], 200)

    def test_pull_session_cannot_delete(self):
        _, headers, _ = self.signin("pull", "pw-pull")
        status = self.call("POST", "/api/delete", {"repo": "x"}, headers={
            "Cookie": self.cookie(headers["Set-Cookie"]), "X-Registreasy-Action": "delete", "Origin": f"https://{self.HOST}"})[0]
        self.assertEqual(status, 403)

    def test_secrets_in_query_string_refused(self):
        self.assertEqual(self.call("GET", "/api/inventory?password=pw-pull")[0], 400)
        self.assertEqual(self.call("GET", "/api/session?token=abc")[0], 400)
        self.assertEqual(self.call("POST", "/api/session?user=push&pass=x", {})[0], 400)

    def test_security_headers(self):
        _, headers, _ = self.call("GET", "/api/session")
        self.assertEqual(headers["Referrer-Policy"], "no-referrer")
        self.assertEqual(headers["Cache-Control"], "no-store")
        self.assertNotIn("Access-Control-Allow-Origin", headers)


if __name__ == "__main__":
    unittest.main()
