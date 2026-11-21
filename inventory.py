#!/usr/bin/env python3
"""Read-only registry inventory and health service. Only listens on loopback."""
import datetime as dt
import hashlib
import json
import os
import pathlib
import re
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


READ_HTPASSWD = "/run/registreasy/read.htpasswd"
PUSH_HTPASSWD = "/run/registreasy/push.htpasswd"
BASIC_RE = re.compile(r"Basic ([A-Za-z0-9+/=]{1,512})")


def verify_basic(header, htpasswd):
    """True when the Basic header matches a user in htpasswd (bcrypt via htpasswd -v).

    The password goes through stdin, never argv, so it stays out of the process list.
    """
    import base64
    import subprocess
    match = BASIC_RE.fullmatch(header or "")
    if not match:
        return False
    try:
        user, password = base64.b64decode(match.group(1)).decode("utf-8").split(":", 1)
    except (ValueError, UnicodeDecodeError):
        return False
    if not re.fullmatch(r"[a-zA-Z0-9._-]{1,64}", user) or not password:
        return False
    try:
        result = subprocess.run(
            ["htpasswd", "-v", "-i", htpasswd, user],
            input=password + "\n", capture_output=True, text=True, timeout=10,
        )
    except (OSError, subprocess.SubprocessError):
        return False
    return result.returncode == 0


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
    if "manifests" in manifest:
        choices = manifest.get("manifests") or []
        choice = next((v for v in choices if v.get("platform", {}).get("os") == "linux" and v.get("platform", {}).get("architecture") == "amd64"), None)
        choice = choice or next((v for v in choices if v.get("platform", {}).get("os") == "linux"), None)
        choice = choice or (choices[0] if choices else None)
        if choice:
            manifest, _ = request(f"/v2/{encoded}/manifests/{urllib.parse.quote(choice['digest'], safe=':')}", ACCEPT)
    created = (manifest.get("annotations") or {}).get("org.opencontainers.image.created")
    config = manifest.get("config")
    if isinstance(config, dict) and isinstance(config.get("digest"), str):
        try:
            config_data, _ = request(f"/v2/{encoded}/blobs/{urllib.parse.quote(config['digest'], safe=':')}")
            created = config_data.get("created") or created
        except (OSError, ValueError):
            pass
    return {"digest": digest, "media_type": media_type, "built_at": created}


def tag_entry(repo, tag):
    metadata = {"digest": None, "media_type": None, "built_at": None}
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
        if exc.code == 404:
            raise ValueError("repository not found")
        raise
    if not tags:
        raise ValueError("repository has no tags")
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

    def respond(self, status, mime, payload):
        self.send_response(status)
        self.send_header("Content-Type", mime)
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("X-Frame-Options", "DENY")
        self.send_header("Content-Security-Policy", "default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; img-src 'self'; base-uri 'none'; frame-ancestors 'none'")
        self.end_headers()
        self.wfile.write(payload)

    def as_json(self, status, value):
        self.respond(status, "application/json; charset=utf-8", json.dumps(value, separators=(",", ":")).encode())

    def listener(self):
        # nginx sets this per server block and overrides any client-sent value.
        return self.headers.get("X-Registreasy-Listener")

    def authorized(self, role):
        """Credentials for the listener's role. The read listener also accepts
        publisher credentials (entrypoint.sh appends the publisher to
        read.htpasswd); when no read password exists, pulls are anonymous."""
        if role == "read":
            if not pathlib.Path(READ_HTPASSWD).exists():
                return True
            return verify_basic(self.headers.get("Authorization"), READ_HTPASSWD)
        return verify_basic(self.headers.get("Authorization"), PUSH_HTPASSWD)

    def do_POST(self):
        path = urllib.parse.urlsplit(self.path).path
        if path != "/api/delete" or self.listener() != "publish":
            self.as_json(404, {"error": "not_found"})
            return
        if not self.authorized("publish"):
            self.as_json(401, {"error": "unauthorized"})
            return
        # Browsers cannot send this header cross-site without a CORS preflight,
        # which we never allow, so cached Basic credentials cannot be abused.
        if self.headers.get("X-Registreasy-Action") != "delete":
            self.as_json(403, {"error": "missing_action_header"})
            return
        try:
            length = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            length = 0
        if not 0 < length <= 4096:
            self.as_json(400, {"error": "bad_request", "message": "body must be 1-4096 bytes of JSON"})
            return
        try:
            body = json.loads(self.rfile.read(length))
            if not isinstance(body, dict):
                raise ValueError("body must be a JSON object")
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
        if path == "/healthz":
            state = health()
            self.as_json(200 if state["status"] == "ok" else 503, state)
        elif path == "/api/inventory":
            role = "publish" if self.listener() == "publish" else "read"
            if not self.authorized(role):
                self.as_json(401, {"error": "unauthorized"})
                return
            try:
                value = dict(cached_inventory())
                value["can_delete"] = role == "publish"
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
