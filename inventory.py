#!/usr/bin/env python3
"""Read-only registry inventory and health service. Only listens on loopback."""
import datetime as dt
import json
import os
import pathlib
import re
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

REGISTRY = "http://127.0.0.1:5001"
DATA = pathlib.Path("/data")
ASSETS = pathlib.Path(__file__).resolve().parent / "web"
PAGE_SIZE = 100
MAX_ITEMS = 2000
CACHE_SECONDS = 20
CACHE = {"at": 0, "data": None}
LOCK = threading.Lock()
ACCEPT = ", ".join((
    "application/vnd.oci.image.index.v1+json",
    "application/vnd.docker.distribution.manifest.list.v2+json",
    "application/vnd.oci.image.manifest.v1+json",
    "application/vnd.docker.distribution.manifest.v2+json",
))


def stamp(seconds):
    if seconds is None:
        return None
    return dt.datetime.fromtimestamp(seconds, tz=dt.timezone.utc).isoformat().replace("+00:00", "Z")


def request(path, accept="application/json"):
    req = urllib.request.Request(REGISTRY + path, headers={"Accept": accept})
    with urllib.request.urlopen(req, timeout=5) as response:
        return json.load(response), response.headers


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
            raise ValueError("Registry exceeds inventory limit")
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


def inventory():
    entries = []
    tag_count = 0
    for repo in paged("/v2/_catalog", "repositories"):
        tags = []
        for tag in paged("/v2/" + urllib.parse.quote(repo, safe="/") + "/tags/list", "tags"):
            metadata = {"digest": None, "media_type": None, "built_at": None}
            try:
                metadata = tag_metadata(repo, tag)
            except (OSError, ValueError, KeyError):
                # Concurrent tag updates may invalidate a particular manifest.
                pass
            tags.append({"tag": tag, "tag_updated_at": tag_updated(repo, tag), **metadata})
            tag_count += 1
            if tag_count > MAX_ITEMS:
                raise ValueError("Registry exceeds inventory limit")
        tags.sort(key=lambda x: (x["tag_updated_at"] or "", x["tag"]), reverse=True)
        entries.append({"name": repo, "tags": tags, "updated_at": tags[0]["tag_updated_at"] if tags else None})
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

    def do_GET(self):
        path = urllib.parse.urlsplit(self.path).path
        if path == "/healthz":
            state = health()
            self.as_json(200 if state["status"] == "ok" else 503, state)
        elif path == "/api/inventory":
            try:
                self.as_json(200, cached_inventory())
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
