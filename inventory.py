#!/usr/bin/env python3
"""Read-only registry inventory and health service. Only listens on loopback."""
import datetime as dt
import hashlib
import json
import os
import pathlib
import re
import shutil
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

REGISTRY = "http://127.0.0.1:5001"
DATA = pathlib.Path("/data")
ASSETS = pathlib.Path(__file__).resolve().parent / "web"
PAGE_SIZE = 100
MAX_ITEMS = 2000
CACHE_SECONDS = 20
FETCH_WORKERS = 8
CACHE = {"at": 0, "data": None}
LOCK = threading.Lock()
ACCEPT = ", ".join((
    "application/vnd.oci.image.index.v1+json",
    "application/vnd.docker.distribution.manifest.list.v2+json",
    "application/vnd.oci.image.manifest.v1+json",
    "application/vnd.docker.distribution.manifest.v2+json",
))


USERS_HTPASSWD = "/run/registreasy/users.htpasswd"
PUSH_HTPASSWD = "/run/registreasy/push.htpasswd"
BASIC_RE = re.compile(r"Basic ([A-Za-z0-9+/=]{1,512})")


USER_RE = re.compile(r"[a-zA-Z0-9._-]{1,64}")


def parse_basic(header):
    """(user, password) from a Basic Authorization header, or None."""
    import base64
    match = BASIC_RE.fullmatch(header or "")
    if not match:
        return None
    try:
        user, password = base64.b64decode(match.group(1), validate=True).decode("utf-8").split(":", 1)
    except (ValueError, UnicodeDecodeError):
        return None
    return user, password


def verify_password(user, password, htpasswd):
    """True when user/password matches htpasswd (bcrypt via htpasswd -v).

    The password goes through stdin, never argv, so it stays out of the process list.
    """
    import subprocess
    if not isinstance(user, str) or not isinstance(password, str):
        return False
    if not USER_RE.fullmatch(user) or not password or len(password) > 1024 or "\n" in password:
        return False
    try:
        result = subprocess.run(
            ["htpasswd", "-v", "-i", htpasswd, user],
            input=password + "\n", capture_output=True, text=True, timeout=10,
        )
    except (OSError, subprocess.SubprocessError):
        return False
    return result.returncode == 0


def role_for(user, password):
    """'push', 'pull' or None for a username/password pair."""
    if verify_password(user, password, PUSH_HTPASSWD):
        return "push"
    if verify_password(user, password, USERS_HTPASSWD):
        return "pull"
    return None


# --- Browser sessions -------------------------------------------------------
# Sessions live in memory: a restart signs everyone out, and since passwords
# only change on restart, a password change always ends every session.
# Only sha256(token) is stored, so a memory dump cannot be replayed as a cookie.

def env_int(name, default, low, high):
    try:
        value = int(os.environ.get(name, default))
    except ValueError:
        value = default
    return max(low, min(high, value))


SESSION_IDLE_SECONDS = env_int("SESSION_IDLE_SECONDS", 1800, 1, 7 * 86400)
SESSION_MAX_SECONDS = env_int("SESSION_MAX_SECONDS", 43200, 1, 30 * 86400)
SESSION_LIMIT = env_int("SESSION_LIMIT", 1000, 1, 100000)
SECURE_COOKIE = "__Host-registreasy_session"
PLAIN_COOKIE = "registreasy_session"
TOKEN_RE = re.compile(r"[A-Za-z0-9_-]{43}")


def now():
    return time.time()


def digest_token(token):
    return hashlib.sha256(token.encode()).hexdigest()


class SessionStore:
    def __init__(self, idle=SESSION_IDLE_SECONDS, maximum=SESSION_MAX_SECONDS, limit=SESSION_LIMIT):
        self.idle, self.maximum, self.limit = idle, maximum, limit
        self.items = {}
        self.lock = threading.Lock()

    def _expired(self, item, at):
        return at - item["last_seen"] >= self.idle or at - item["created"] >= self.maximum

    def _sweep(self, at):
        for key in [k for k, v in self.items.items() if self._expired(v, at)]:
            del self.items[key]

    def create(self, user, role):
        import secrets
        token = secrets.token_urlsafe(32)
        at = now()
        with self.lock:
            self._sweep(at)
            while len(self.items) >= self.limit:
                oldest = min(self.items, key=lambda k: self.items[k]["last_seen"])
                del self.items[oldest]
            self.items[digest_token(token)] = {"user": user, "role": role, "created": at, "last_seen": at}
        return token

    def get(self, token):
        """The session for token (refreshing its idle timer), or None."""
        if not isinstance(token, str) or not TOKEN_RE.fullmatch(token):
            return None
        key = digest_token(token)
        at = now()
        with self.lock:
            item = self.items.get(key)
            if item is None:
                return None
            if self._expired(item, at):
                del self.items[key]
                return None
            item["last_seen"] = at
            return dict(item, idle_expires_at=min(at + self.idle, item["created"] + self.maximum),
                        expires_at=item["created"] + self.maximum)

    def delete(self, token):
        if isinstance(token, str) and TOKEN_RE.fullmatch(token):
            with self.lock:
                self.items.pop(digest_token(token), None)


# --- Password-guessing backoff ----------------------------------------------
# nginx rate limits per client; this additionally locks out a client address
# after repeated failures. A per-username lock applies only to public clients,
# so an internet attacker can never lock LAN users out of their own registry.

FAIL_WINDOW = 900
FAIL_LIMIT_CLIENT = 10
FAIL_LIMIT_USER = 30


class Throttle:
    def __init__(self, window=FAIL_WINDOW, per_client=FAIL_LIMIT_CLIENT, per_user=FAIL_LIMIT_USER):
        self.window, self.per_client, self.per_user = window, per_client, per_user
        self.failures = {}
        self.lock = threading.Lock()

    def _recent(self, key, at):
        stamps = [t for t in self.failures.get(key, ()) if at - t < self.window]
        if stamps:
            self.failures[key] = stamps
        else:
            self.failures.pop(key, None)
        return stamps

    def _keys(self, client, user, private):
        keys = [("client", client, self.per_client)]
        if not private and isinstance(user, str) and USER_RE.fullmatch(user):
            keys.append(("user", user.lower(), self.per_user))
        return keys

    def retry_after(self, client, user, private):
        """Seconds until another attempt is allowed (0 = allowed now)."""
        at = now()
        wait = 0
        with self.lock:
            for kind, value, limit in self._keys(client, user, private):
                stamps = self._recent((kind, value), at)
                if len(stamps) >= limit:
                    wait = max(wait, int(stamps[-limit] + self.window - at) + 1)
        return wait

    def fail(self, client, user, private):
        at = now()
        with self.lock:
            if len(self.failures) > 20000:
                for key in list(self.failures):
                    self._recent(key, at)
            for kind, value, limit in self._keys(client, user, private):
                stamps = self._recent((kind, value), at)
                stamps.append(at)
                self.failures[(kind, value)] = stamps[-limit:]


SESSIONS = SessionStore()
THROTTLE = Throttle()
SECRET_QUERY_RE = re.compile(r"(^|&)(password|passwd|pass|pw|token|auth|authorization|session|secret)=", re.I)


def same_host(origin, host):
    """True when an Origin header names this host (scheme ignored; ports compared)."""
    if not origin or not host:
        return False
    parsed = urllib.parse.urlsplit(origin)
    if parsed.scheme not in ("http", "https") or not parsed.hostname:
        return False
    default = 443 if parsed.scheme == "https" else 80
    origin_host = parsed.hostname.lower(), parsed.port or default
    target = urllib.parse.urlsplit("//" + host)
    if not target.hostname:
        return False
    return origin_host == (target.hostname.lower(), target.port or default)


def log_auth_failure(client, user):
    shown = user if isinstance(user, str) and USER_RE.fullmatch(user) else "<invalid>"
    print(f"registreasy: authentication failed client={client} user={shown}", file=sys.stderr, flush=True)


def stamp(seconds):
    if seconds is None:
        return None
    return dt.datetime.fromtimestamp(seconds, tz=dt.timezone.utc).isoformat().replace("+00:00", "Z")


def request(path, accept="application/json"):
    req = urllib.request.Request(REGISTRY + path, headers={"Accept": accept})
    with urllib.request.urlopen(req, timeout=5) as response:
        return json.load(response), response.headers


def call(method, path, accept="application/json"):
    req = urllib.request.Request(REGISTRY + path, method=method, headers={"Accept": accept})
    with urllib.request.urlopen(req, timeout=10) as response:
        return response.status, response.headers


REPO_RE = re.compile(r"[a-z0-9]+(?:[._/-][a-z0-9]+)*")
TAG_RE = re.compile(r"[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}")
DIGEST_RE = re.compile(r"sha256:[a-f0-9]{64}")


class LimitExceeded(ValueError):
    """The registry holds more than MAX_ITEMS repositories or tags."""


class Conflict(ValueError):
    """The registry changed between a delete preview and its confirmation."""


def paged(path, key):
    results = []
    last = None
    while True:
        query = urllib.parse.urlencode({"n": PAGE_SIZE, **({"last": last} if last else {})})
        payload, headers = request(path + ("&" if "?" in path else "?") + query)
        items = payload.get(key) or []
        if not isinstance(items, list):
            raise ValueError("Malformed registry listing")
        results.extend(items)
        if len(results) > MAX_ITEMS:
            raise LimitExceeded("Registry exceeds inventory limit")
        if not items or not headers.get("Link"):
            return results
        if items[-1] == last:
            raise ValueError("Registry pagination made no progress")
        last = items[-1]


def tag_updated(repo, tag):
    # Registry v2 filesystem tag-link mtime, NOT an authoritative push audit log.
    if not re.fullmatch(r"[a-z0-9]+(?:[._/-][a-z0-9]+)*", repo):
        return None
    if not re.fullmatch(r"[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}", tag):
        return None
    link = DATA / "docker/registry/v2/repositories" / repo / "_manifests/tags" / tag / "current/link"
    try:
        return stamp(link.stat().st_mtime) if link.is_file() and not link.is_symlink() else None
    except OSError:
        return None


def tag_metadata(repo, tag):
    encoded = urllib.parse.quote(repo, safe="/")
    manifest, headers = request(f"/v2/{encoded}/manifests/{urllib.parse.quote(tag, safe='')}", ACCEPT)
    digest = headers.get("Docker-Content-Digest")
    media_type = manifest.get("mediaType")
    platform = None
    if "manifests" in manifest:
        choices = manifest.get("manifests") or []
        choice = next((v for v in choices if v.get("platform", {}).get("os") == "linux" and v.get("platform", {}).get("architecture") == "amd64"), None)
        choice = choice or next((v for v in choices if v.get("platform", {}).get("os") == "linux"), None)
        choice = choice or (choices[0] if choices else None)
        if choice:
            platform = choice.get("platform") or {}
            platform = "/".join(str(platform[key]) for key in ("os", "architecture", "variant") if platform.get(key)) or None
            manifest, _ = request(f"/v2/{encoded}/manifests/{urllib.parse.quote(choice['digest'], safe=':')}", ACCEPT)
    created = (manifest.get("annotations") or {}).get("org.opencontainers.image.created")
    config = manifest.get("config")
    if isinstance(config, dict) and isinstance(config.get("digest"), str):
        try:
            config_data, _ = request(f"/v2/{encoded}/blobs/{urllib.parse.quote(config['digest'], safe=':')}")
            created = config_data.get("created") or created
        except (OSError, ValueError):
            pass
    layers = manifest.get("layers")
    descriptors = [config, *layers] if isinstance(layers, list) else []
    size = sum(d["size"] for d in descriptors) if descriptors and all(
        isinstance(d, dict) and type(d.get("size")) is int and d["size"] >= 0 for d in descriptors
    ) else None
    return {"digest": digest, "media_type": media_type, "built_at": created, "size_bytes": size, "platform": platform}


def tag_entry(repo, tag):
    metadata = {"digest": None, "media_type": None, "built_at": None, "size_bytes": None, "platform": None}
    try:
        metadata = tag_metadata(repo, tag)
    except (OSError, ValueError, KeyError, TypeError, AttributeError):
        # Concurrent tag updates or unusual manifests may break one tag; keep the rest.
        pass
    return {"tag": tag, "tag_updated_at": tag_updated(repo, tag), **metadata}


def inventory():
    listing = []
    tag_count = 0
    for repo in paged("/v2/_catalog", "repositories"):
        error = None
        try:
            tags = paged("/v2/" + urllib.parse.quote(repo, safe="/") + "/tags/list", "tags")
        except LimitExceeded:
            raise
        except (OSError, ValueError):
            # e.g. a repository whose manifests were all deleted, or upload-only
            # leftovers: report it rather than failing the whole inventory.
            tags, error = [], "tags_unavailable"
        tag_count += len(tags)
        if tag_count > MAX_ITEMS:
            raise LimitExceeded("Registry exceeds inventory limit")
        listing.append((repo, tags, error))

    entries = []
    with ThreadPoolExecutor(max_workers=FETCH_WORKERS) as pool:
        pending = [(repo, error, [pool.submit(tag_entry, repo, t) for t in tags]) for repo, tags, error in listing]
        for repo, error, futures in pending:
            tags = [future.result() for future in futures]
            tags.sort(key=lambda x: (x["tag_updated_at"] or "", x["tag"]), reverse=True)
            entry = {"name": repo, "tags": tags, "updated_at": tags[0]["tag_updated_at"] if tags else None}
            if error:
                entry["error"] = error
            entries.append(entry)
    entries.sort(key=lambda x: (x["updated_at"] or "", x["name"]), reverse=True)
    return {
        "generated_at": stamp(time.time()),
        "repository_count": len(entries),
        "tag_count": tag_count,
        "repositories": entries,
        "date_note": "Tag updated date is filesystem link mtime (approximate); image built date comes from image metadata. Neither is a push audit history.",
    }


def cached_inventory():
    with LOCK:
        now = time.monotonic()
        if CACHE["data"] is not None and now - CACHE["at"] < CACHE_SECONDS:
            return CACHE["data"]
        value = inventory()
        CACHE.update(at=now, data=value)
        return value


def invalidate_cache():
    with LOCK:
        CACHE.update(at=0, data=None)


def tag_digests(repo, tags):
    encoded = urllib.parse.quote(repo, safe="/")
    digests = {}
    for tag in tags:
        _, headers = call("HEAD", f"/v2/{encoded}/manifests/{urllib.parse.quote(tag, safe='')}", ACCEPT)
        digest = headers.get("Docker-Content-Digest") or ""
        if not DIGEST_RE.fullmatch(digest):
            raise ValueError(f"could not resolve digest for {repo}:{tag}")
        digests[tag] = digest
    return digests


def repo_dir(repo):
    root = (DATA / "docker/registry/v2/repositories").resolve()
    path = (root / repo).resolve()
    if path == root or root not in path.parents:
        raise ValueError("invalid repository name")
    return path


def delete_empty_repo(repo, preview, expected_plan):
    """Remove a tagless repository's leftover directory (the registry API cannot)."""
    path = repo_dir(repo)
    if not path.is_dir():
        raise ValueError("repository not found")
    if any(c.is_dir() and not c.name.startswith("_") for c in path.iterdir()):
        raise ValueError("repository directory contains nested repositories")
    plan_id = hashlib.sha256(json.dumps([repo, None, [], []]).encode()).hexdigest()
    if expected_plan is not None and expected_plan != plan_id:
        raise Conflict("registry changed since the preview; review the new plan and try again")
    result = {"repository": repo, "scope": "repository", "tag": None, "tags": [], "digests": [],
              "plan_id": plan_id, "preview": preview, "deleted": False, "empty": True}
    if preview:
        return result
    try:
        shutil.rmtree(path)
    except OSError as exc:
        raise ValueError(f"could not remove repository directory: {exc.strerror}")
    result["deleted"] = True
    invalidate_cache()
    return result


def delete_images(body):
    """Delete a tag (and every tag sharing its manifest) or a whole repository.

    The registry removes manifests by digest, so a tag delete also removes any
    other tags on the same digest. `preview` returns the plan (with a `plan_id`)
    without deleting. A confirmation may pass that `plan_id` back; if the
    registry changed since the preview the delete is refused (Conflict).
    Disk space is only reclaimed later by garbage collection.
    """
    repo = body.get("repo")
    tag = body.get("tag")
    preview = body.get("preview") is True
    expected_plan = body.get("plan_id")
    if expected_plan is not None and (not isinstance(expected_plan, str) or not re.fullmatch(r"[a-f0-9]{64}", expected_plan)):
        raise ValueError("invalid plan_id")
    if not isinstance(repo, str) or not REPO_RE.fullmatch(repo):
        raise ValueError("invalid repository name")
    if tag is not None and (not isinstance(tag, str) or not TAG_RE.fullmatch(tag)):
        raise ValueError("invalid tag")
    encoded = urllib.parse.quote(repo, safe="/")
    try:
        tags = paged("/v2/" + encoded + "/tags/list", "tags")
    except urllib.error.HTTPError as exc:
        if exc.code != 404:
            raise
        # Registry says unknown: a leftover directory may still be listed in the catalog.
        tags = []
    if not tags:
        if tag is not None:
            raise ValueError("tag not found")
        return delete_empty_repo(repo, preview, expected_plan)
    digests = tag_digests(repo, tags)
    if tag is not None:
        if tag not in digests:
            raise ValueError("tag not found")
        target = digests[tag]
        removed_tags = sorted(t for t, d in digests.items() if d == target)
        remove_digests = [target]
        scope = "tag"
    else:
        removed_tags = sorted(digests)
        remove_digests = sorted(set(digests.values()))
        scope = "repository"
    plan_id = hashlib.sha256(json.dumps([repo, tag, removed_tags, remove_digests]).encode()).hexdigest()
    if expected_plan is not None and expected_plan != plan_id:
        raise Conflict("registry changed since the preview; review the new plan and try again")
    result = {
        "repository": repo,
        "scope": scope,
        "tag": tag,
        "tags": removed_tags,
        "digests": remove_digests,
        "plan_id": plan_id,
        "preview": preview,
        "deleted": False,
    }
    if preview:
        return result
    for digest in remove_digests:
        status, _ = call("DELETE", f"/v2/{encoded}/manifests/{digest}")
        if status not in (200, 202):
            raise ValueError(f"registry refused delete of {digest} (HTTP {status})")
    result["deleted"] = True
    invalidate_cache()
    return result


def health():
    upstream = False
    writable = False
    free = None
    try:
        value, _ = request("/v2/")
        upstream = isinstance(value, dict)
    except (OSError, ValueError):
        pass
    try:
        stats = os.statvfs(DATA)
        free = stats.f_bavail * stats.f_frsize
        probe = DATA / f".health-probe-{os.getpid()}-{threading.get_ident()}"
        with probe.open("x") as out:
            out.write("ok")
        probe.unlink()
        writable = True
    except OSError:
        pass
    return {
        "status": "ok" if upstream and writable else "degraded",
        "registry": "ok" if upstream else "unavailable",
        "storage": {"writable": writable, "free_bytes": free},
        "checked_at": stamp(time.time()),
    }


class Handler(BaseHTTPRequestHandler):
    server_version = "Registreasy/1.0"
    sys_version = ""

    # --- request context (set by nginx; the app only listens on loopback) ---
    # nginx overwrites these headers on every proxied request, so clients cannot
    # inject them. They carry the real client address and transport scheme.

    def scheme(self):
        return "https" if self.headers.get("X-Registreasy-Scheme") == "https" else "http"

    def client(self):
        return (self.headers.get("X-Registreasy-Client") or self.client_address[0])[:64]

    def client_private(self):
        return self.headers.get("X-Registreasy-Private") == "1"

    def cookie_name(self):
        return SECURE_COOKIE if self.scheme() == "https" else PLAIN_COOKIE

    def cookie_token(self):
        from http.cookies import CookieError, SimpleCookie
        jar = SimpleCookie()
        try:
            jar.load(self.headers.get("Cookie") or "")
        except CookieError:
            return None
        morsel = jar.get(self.cookie_name())
        return morsel.value if morsel else None

    def cookie_header(self, token, clear=False):
        parts = [f"{self.cookie_name()}={'' if clear else token}", "Path=/", "HttpOnly", "SameSite=Strict"]
        if self.scheme() == "https":
            parts.append("Secure")
        if clear:
            parts.append("Max-Age=0")
        return "; ".join(parts)

    # --- responses ---

    def respond(self, status, mime, payload, extra=()):
        self.send_response(status)
        self.send_header("Content-Type", mime)
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("X-Frame-Options", "DENY")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("Cross-Origin-Opener-Policy", "same-origin")
        self.send_header("Cross-Origin-Resource-Policy", "same-origin")
        self.send_header("Content-Security-Policy", "default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; img-src 'self'; base-uri 'none'; form-action 'self'; frame-ancestors 'none'")
        if self.scheme() == "https":
            self.send_header("Strict-Transport-Security", "max-age=31536000")
        for name, value in extra:
            self.send_header(name, value)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(payload)

    def as_json(self, status, value, extra=()):
        self.respond(status, "application/json; charset=utf-8", json.dumps(value, separators=(",", ":")).encode(), extra)

    def log_message(self, fmt, *args):
        # The request line never carries secrets (query secrets are refused), but
        # keep access logging to nginx, which already records every request.
        pass

    # --- authentication ---

    def check_password(self, user, password):
        """role, or None; applies failure backoff. Returns ('locked', seconds) when throttled."""
        client, private = self.client(), self.client_private()
        wait = THROTTLE.retry_after(client, user, private)
        if wait:
            return ("locked", wait)
        role = role_for(user, password)
        if role is None:
            THROTTLE.fail(client, user, private)
            log_auth_failure(client, user)
        return role

    def authenticate(self):
        """(principal, error_response). principal = {user, role, via}."""
        token = self.cookie_token()
        if token:
            item = SESSIONS.get(token)
            if item:
                return {"user": item["user"], "role": item["role"], "via": "session", "session": item}, None
        header = self.headers.get("Authorization")
        if header:
            pair = parse_basic(header)
            role = self.check_password(*pair) if pair else None
            if isinstance(role, tuple):
                return None, (429, {"error": "too_many_failures", "message": "too many failed sign-ins; try again later"},
                              [("Retry-After", str(role[1]))])
            if role:
                return {"user": pair[0], "role": role, "via": "basic"}, None
        return None, (401, {"error": "unauthorized"}, [])

    def require_action(self, action, need_origin):
        """CSRF guard for state-changing requests. Returns an error tuple or None.

        A custom header cannot be sent cross-site without a CORS preflight, which
        is never granted. Browser requests must also come from this host's Origin.
        """
        if self.headers.get("X-Registreasy-Action") != action:
            return 403, {"error": "missing_action_header", "message": f"send X-Registreasy-Action: {action}"}
        origin = self.headers.get("Origin")
        if origin is None and not need_origin:
            return None
        if not same_host(origin, self.headers.get("Host")):
            return 403, {"error": "bad_origin", "message": "request origin does not match this host"}
        return None

    def read_json(self):
        if (self.headers.get("Content-Type") or "").split(";")[0].strip().lower() != "application/json":
            raise ValueError("Content-Type must be application/json")
        try:
            length = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            length = 0
        if not 0 < length <= 4096:
            raise ValueError("body must be 1-4096 bytes of JSON")
        body = json.loads(self.rfile.read(length))
        if not isinstance(body, dict):
            raise ValueError("body must be a JSON object")
        return body

    def secret_in_query(self):
        query = urllib.parse.urlsplit(self.path).query
        if query and SECRET_QUERY_RE.search(query):
            self.as_json(400, {"error": "secret_in_url", "message": "credentials are never accepted in the URL; use the Authorization header or the sign-in form"})
            return True
        return False

    def session_view(self, principal):
        item = principal.get("session")
        return {
            "username": principal["user"],
            "role": principal["role"],
            "can_delete": principal["role"] == "push",
            "idle_expires_at": stamp(item["idle_expires_at"]) if item else None,
            "expires_at": stamp(item["expires_at"]) if item else None,
        }

    # --- routes ---

    def sign_in(self):
        error = self.require_action("signin", need_origin=True)
        if error:
            self.as_json(*error)
            return
        try:
            body = self.read_json()
        except ValueError as exc:
            self.as_json(400, {"error": "bad_request", "message": str(exc)[:150]})
            return
        user, password = body.get("username"), body.get("password")
        role = self.check_password(user, password) if isinstance(user, str) and isinstance(password, str) else None
        if isinstance(role, tuple):
            self.as_json(429, {"error": "too_many_failures", "message": "too many failed sign-ins; try again later"},
                         [("Retry-After", str(role[1]))])
            return
        if role is None:
            self.as_json(401, {"error": "unauthorized", "message": "username or password not accepted"})
            return
        # Always a fresh token (no session fixation); an old cookie is replaced.
        SESSIONS.delete(self.cookie_token())
        token = SESSIONS.create(user, role)
        item = SESSIONS.get(token)
        principal = {"user": user, "role": role, "session": item}
        self.as_json(200, self.session_view(principal), [("Set-Cookie", self.cookie_header(token))])

    def sign_out(self):
        error = self.require_action("signout", need_origin=True)
        if error:
            self.as_json(*error)
            return
        SESSIONS.delete(self.cookie_token())
        self.as_json(200, {"signed_out": True}, [("Set-Cookie", self.cookie_header("", clear=True))])

    def do_DELETE(self):
        if self.secret_in_query():
            return
        if urllib.parse.urlsplit(self.path).path == "/api/session":
            self.sign_out()
        else:
            self.as_json(404, {"error": "not_found"})

    def do_POST(self):
        if self.secret_in_query():
            return
        path = urllib.parse.urlsplit(self.path).path
        if path == "/api/session":
            self.sign_in()
            return
        if path != "/api/delete":
            self.as_json(404, {"error": "not_found"})
            return
        principal, error = self.authenticate()
        if error:
            self.as_json(*error)
            return
        if principal["role"] != "push":
            self.as_json(403, {"error": "forbidden", "message": "only the publisher account can delete"})
            return
        # Cookie sessions must prove same-origin; Basic-auth scripts need only the header.
        error = self.require_action("delete", need_origin=principal["via"] == "session")
        if error:
            self.as_json(*error)
            return
        try:
            body = self.read_json()
        except ValueError as exc:
            self.as_json(400, {"error": "bad_request", "message": str(exc)[:150]})
            return
        try:
            self.as_json(200, delete_images(body))
        except Conflict as exc:
            self.as_json(409, {"error": "changed_since_preview", "message": str(exc)[:150]})
        except ValueError as exc:
            self.as_json(400, {"error": "delete_refused", "message": str(exc)[:150]})
        except OSError as exc:
            self.as_json(503, {"error": "registry_unavailable", "message": str(exc)[:150]})

    def do_GET(self):
        path = urllib.parse.urlsplit(self.path).path
        if path.startswith("/api/") and self.secret_in_query():
            return
        if path == "/healthz":
            state = health()
            self.as_json(200 if state["status"] == "ok" else 503, state)
        elif path == "/api/session":
            principal, error = self.authenticate()
            if error:
                self.as_json(*error)
                return
            self.as_json(200, self.session_view(principal))
        elif path == "/api/inventory":
            principal, error = self.authenticate()
            if error:
                self.as_json(*error)
                return
            try:
                value = dict(cached_inventory())
                value["can_delete"] = principal["role"] == "push"
                self.as_json(200, value)
            except (OSError, ValueError) as exc:
                self.as_json(503, {"error": "inventory_unavailable", "message": str(exc)[:150]})
        elif path in ("/", "/index.html"):
            self.respond(200, "text/html; charset=utf-8", (ASSETS / "inventory.html").read_bytes())
        elif path == "/inventory.js":
            self.respond(200, "text/javascript; charset=utf-8", (ASSETS / "inventory.js").read_bytes())
        elif path == "/inventory.css":
            self.respond(200, "text/css; charset=utf-8", (ASSETS / "inventory.css").read_bytes())
        else:
            self.as_json(404, {"error": "not_found"})


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", 5003), Handler).serve_forever()
