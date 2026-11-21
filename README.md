# Registreasy

A **single-container Docker registry** powered by upstream CNCF Distribution v3 and Nginx. Built for simple self-hosted image publishing: one port, one read-only account and one publisher account.

- One container, one port, one `./data` persistence directory, no external database
- `PULL_PASSWORD` and `PUSH_PASSWORD` both **required**
- Permissions follow the account: `pull` reads, `push` reads, publishes and deletes
- Standard `docker login`, `docker push`, `docker pull`, and Compose updates
- No custom Docker registry protocol or custom token-authentication service
- Built-in **read-only inventory page** and **/healthz** endpoint

**One endpoint, two accounts.** Nginx asks for credentials at `GET /v2/`, so Docker clients always send them, including on pushes. The pull account can only GET/HEAD; any write by it is refused with HTTP 403. Only the publisher account can push or delete.

There are no anonymous pulls: Docker clients won't reliably send push credentials when the `/v2/` probe allows anonymous access, so a single endpoint has to require a login. Use long random passwords for both accounts.

The internal Registry v3 process listens only on loopback port 5001.

## Deploy

```bash
git clone https://github.com/berenebot-agent/registreasy.git
cd registreasy
cp .env.example .env
# Replace PUSH_PASSWORD and PULL_PASSWORD in .env with long random secrets
chmod 600 .env
docker compose up -d --build
docker compose logs -f
```

By default the host port binds to `127.0.0.1`; this avoids exposing HTTP Basic credentials over your LAN before configuring HTTPS. In Nginx Proxy Manager, add **one proxy host** with a TLS certificate:

- `registry.example.com` -> `http://registreasy:5000`

If NPM runs on the same Docker host, connect its existing container to the Compose network:

```bash
docker network connect registreasy_default <npm-container-name>
```

The exact network name depends on your Docker Compose project name (check `docker network ls`). NPM can then resolve `registreasy` by container name. If NPM is on another host, bind the host port to your server's LAN IP with `BIND_ADDRESS` and restrict inbound connections to NPM using a firewall.

## Inventory and health

Browse the **root URL**, for example `https://registry.example.com/`, to see the inventory. The page shows a sign-in form: enter either account's username and password. The pull account gets a read-only view; the publisher account also gets delete controls. It groups image repositories and displays tags, manifest digests, image build dates (where present in OCI/Docker config) and approximate tag update dates. It includes a repository/tag filter and health status. Signing in creates a server-side session (see **Sign-in and sessions** below); the page never stores your password, and reloading keeps you signed in.

| Route | Behaviour |
| --- | --- |
| `GET /` | Inventory page and sign-in form (the page itself is public; it contains no data) |
| `POST /api/session` | Sign in with `{"username","password"}`; sets the session cookie |
| `GET /api/session` | Current user, role and expiry times, or 401 |
| `DELETE /api/session` | Sign out (ends the session on the server) |
| `GET /api/inventory` | JSON repository/tag inventory; requires a session or pull/push Basic credentials. `can_delete` is true only for the publisher |
| `POST /api/delete` | Delete tags or repositories; publisher only (see below) |
| `GET /healthz` | Unauthenticated health JSON (HTTP 200 healthy, HTTP 503 degraded) |

The `/api/` routes are rate limited per client (10 requests/second, bursts of 20) and overall (30 requests/second); sign-in attempts are limited to 10 per minute per client. Docker traffic on `/v2/` is not limited.

### Sign-in and sessions

- Signing in sends the password once, in the body of `POST /api/session`. The server checks it and creates a session; the browser only gets a random session ID in a cookie that page scripts cannot read (`HttpOnly`, `SameSite=Strict`). Over HTTPS the cookie is `__Host-registreasy_session` and also `Secure`.
- Sessions end after `SESSION_IDLE_SECONDS` (default 30 minutes) without activity, after `SESSION_MAX_SECONDS` (default 12 hours) in total, on sign-out, or when the container restarts. Sessions are held in memory and only a hash of each ID is kept.
- Sign-in, sign-out and delete must carry an `X-Registreasy-Action` header and, from a browser, an `Origin` matching this host. Other sites cannot trigger them (CSRF).
- After 10 failed passwords in 15 minutes a client address must wait (HTTP 429 with `Retry-After`). Failed attempts are logged as `registreasy: authentication failed client=… user=…` for tools such as fail2ban. Repeated failures from the internet also briefly lock that username for other internet clients; LAN clients are never locked out by internet traffic.
- Scripts can keep using HTTP Basic auth on `/api/inventory` and `/api/delete` (in the `Authorization` header, never the URL: credentials in a query string are refused with HTTP 400).

`/healthz` checks that the underlying Registry v3 API responds and that the image storage is writable, and shows available storage bytes. The container healthcheck uses this endpoint.

**Dates:** The tag update date comes from the Registry filesystem's current tag-link modification time and is only an approximation of the last time the tag was written; it is not a reliable historical push event timestamp. An image's build timestamp comes from its OCI/Docker metadata and can be absent or very different from its push date. Historical versions are shown only while tagged. The inventory is cached for up to 20 seconds and currently supports up to 2,000 listed repositories/tags.

No separate container, database, ports or volumes are required.

## Configuration

| Variable | Default | Meaning |
| --- | --- | --- |
| `PUSH_PASSWORD` | **Required** | Publisher password |
| `PUSH_USERNAME` | `push` | Publisher login |
| `PULL_PASSWORD` | **Required** | Read-only password |
| `PULL_USERNAME` | `pull` | Read-only login |
| `BIND_ADDRESS` | `127.0.0.1` | Host interface on which the port is published |
| `PORT` | `5000` | Host port |
| `REQUIRE_HTTPS` | `0` | `1` refuses plain HTTP from every address (see **Security**) |
| `SESSION_IDLE_SECONDS` | `1800` | Web sign-in ends after this much inactivity |
| `SESSION_MAX_SECONDS` | `43200` | Web sign-in ends after this long regardless |

Publisher credentials also permit read access. Read-only credentials **never permit writes**. Usernames accept letters, numbers, periods, underscores and hyphens, and must differ (ignoring case).

## Publish an image

```bash
docker login registry.example.com -u push
docker pull alpine:latest
docker tag alpine:latest registry.example.com/demo/alpine:1
docker push registry.example.com/demo/alpine:1
```

## Pull or deploy the same image

On machines that only deploy, log in with the read-only account:

```bash
docker login registry.example.com -u pull
docker pull registry.example.com/demo/alpine:1
```

For your application:

```yaml
services:
  app:
    image: registry.example.com/demo/alpine:1
    restart: unless-stopped
```

When a version or tag changes: `docker compose pull && docker compose up -d`. Credentials persist in Docker's local credential store or configuration. Docker keeps one login per hostname, so a machine logged in as `pull` can't push; log in as `push` on machines that publish (it can pull too).

## Deleting images

Sign in to the inventory page with the publisher account. Each repository has a **Delete repository** button, and each tag row has a **Delete** button. Both show a preview first (which tags and manifests will go) and ask for confirmation.

Deleting a tag removes its manifest, so any other tag pointing at the same digest is removed too. The preview lists them.

API (publisher login, required header `X-Registreasy-Action: delete`):

```bash
curl -u push:"$PUSH_PASSWORD" -H 'Content-Type: application/json' -H 'X-Registreasy-Action: delete' \
  -d '{"repo":"tiller-router","tag":"latest","preview":true}' https://registry.<host>/api/delete
```

Omit `tag` to delete the whole repository. Use `"preview": true` to see the plan without deleting; the response includes a `plan_id`. Send that `plan_id` with the real delete and it is refused with HTTP 409 if the tags or digests changed since the preview (the web page always does this). Registry-level DELETE on `/v2/` also requires push login.

**Disk space:** a delete frees nothing until garbage collection runs. GC must not run while uploads can happen, so stop the registry first. Run from the checkout directory (`registry.yml` stores data under `/data`, so mount `./data` there):

```bash
docker compose stop
docker run --rm -v "$PWD/registry.yml:/etc/distribution/config.yml:ro" \
  -v "$PWD/data:/data" registry:3 \
  garbage-collect --delete-untagged /etc/distribution/config.yml
docker compose start
```

Add `--dry-run` after `garbage-collect` to see what would be removed first. Run GC after deletes you care about; it is not automatic. Deleting the last tag leaves an empty repository listed (the registry keeps its directory); **Delete repository** on it removes that directory.

## Security

**Plain HTTP is LAN-only, automatically.** Passwords (Basic auth) and session cookies cross plain HTTP readably, so the registry accepts plain HTTP only from private addresses (10/8, 172.16/12, 192.168/16, 100.64/10, loopback, IPv6 ULA/link-local). Internet clients get HTTP 403 unless they arrive over HTTPS; `/healthz` stays open. On a LAN this needs no setup.

A reverse proxy on a private address (Caddy, NPM, Traefik…) is trusted to report the real client (`X-Forwarded-For`) and whether it used HTTPS (`X-Forwarded-Proto`). Headers from public addresses are ignored, so internet clients cannot forge them.

### Exposing publicly

1. Put a TLS-terminating proxy in front and point it at `http://registreasy:5000`. It must send `X-Forwarded-For` and `X-Forwarded-Proto` (Caddy, NPM and Traefik do by default).
2. Set `REQUIRE_HTTPS=1`. Plain HTTP is then refused even from private addresses. This matters if Docker's userland proxy is in use (rootless Docker, some IPv6 or Docker Desktop setups): there every client appears to come from the private Docker gateway address, and without this setting an internet client could use plain HTTP.
3. Keep `BIND_ADDRESS=127.0.0.1` (or firewall the port) so only the proxy reaches the container.
4. Use long random passwords and watch the `authentication failed` log lines.

- The endpoint needs trusted HTTPS when accessed from other machines. NPM should terminate TLS.
- Only Nginx reaches the internal Registry v3 backend; direct backend access is blocked.
- `/v2/` always challenges for credentials, which is required for reliable Docker CLI publishing.
- Nginx refuses every non-GET/HEAD `/v2/` request from any user other than the publisher (HTTP 403), before the password check; the publisher's password is still verified on every request.
- Deletion requires `PUSH_PASSWORD`. Pull credentials get HTTP 403 from `/api/delete` and never see delete controls.
- Security rests on the two passwords: use long random secrets. Password-checking `/api/` routes are rate limited with a per-client lockout; `/v2/` is not.
- Responses carry a strict Content-Security-Policy, `X-Frame-Options: DENY`, `Referrer-Policy: no-referrer`, and HSTS over HTTPS. No CORS is ever allowed.
- Registry deletes remove manifest references only. Disk space is reclaimed by garbage collection (see below).
- Environment secrets are visible to host-level Docker administrators via container inspection. Keep `.env` private, and rotate passwords when needed.
- Persistent image storage and the stable internal HTTP signing secret live in `./data`; back it up.
- The port should only be reachable through the trusted TLS proxy. Limit access to it further by source IP if desired.

## Prebuilt images (GHCR)

Publishing a GitHub release whose tag is `vMAJOR.MINOR.PATCH` (for example `v0.1.0`) runs the integration tests, then builds `linux/amd64` and `linux/arm64` images and pushes them to `ghcr.io/<owner>/<repo>`:

| Release | Image tags |
| --- | --- |
| `v0.1.0` | `0.1.0`, `0.1`, `latest` |
| `v1.2.3` | `1.2.3`, `1.2`, `1`, `latest` |
| `v0.2.0-rc.1` (marked pre-release) | `0.2.0-rc.1` only |

Releases with any other tag format fail the workflow without publishing. To use a prebuilt image instead of building locally, replace `build: .` in `docker-compose.yml` with, for example, `image: ghcr.io/<owner>/registreasy:0.1`. New GHCR packages are private by default; make the package public in its GitHub settings if other machines should pull it without logging in.

## Development

```bash
docker build -t registreasy:local .
export PUSH_PASSWORD=test-push PULL_PASSWORD=test-pull
docker compose up -d --build
bash tests/smoke.sh http://127.0.0.1:5000
python3 -m unittest discover -s tests   # session, throttle and CSRF unit tests; no container needed
```

The smoke tests exercise both accounts' permissions; the test upload they start is cancelled afterwards, so they are safe to run against a live registry. GitHub Actions additionally tests real `docker login`, push and pull behaviour for both accounts, and the delete API.

This project wraps [CNCF Distribution](https://distribution.github.io/distribution/) and [Nginx](https://nginx.org/), rather than implementing image storage itself.
