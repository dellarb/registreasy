# Registreasy

A **single-container Docker registry** powered by upstream CNCF Distribution v3 and Nginx. Built for simple self-hosted image publishing, with an optional password for pulls and a separate password for pushes.

- One container, one `./data` persistence directory, no external database
- `PUSH_PASSWORD` **required**, `PULL_PASSWORD` **optional**
- Anonymous pulls by default
- Publishing always requires the publisher's credentials
- Standard `docker login`, `docker push`, `docker pull`, and Compose updates
- No custom Docker registry protocol or custom token-authentication service
- Built-in **read-only inventory page** and **/healthz** endpoint

**Why two endpoints?** Docker clients probe `GET /v2/` first and will not reliably send publishing credentials when that probe allows anonymous access. To support **both anonymous pulls and reliable `docker push`**, Registreasy exposes two ports on the *same container*, both using the *same Registry v3 storage*:

| Endpoint | Container port | NPM hostname example | Access |
| --- | --- | --- | --- |
| Read | `5000` | `registry.example.com` | GET/HEAD, anonymous unless `PULL_PASSWORD` is set |
| Publish | `5002` | `registry-push.example.com` | All registry operations, publisher account required |

The internal Registry v3 process listens only on loopback port 5001. You do not need two registry containers or two data directories.

## Deploy

```bash
git clone https://github.com/berenebot-agent/registreasy.git
cd registreasy
cp .env.example .env
# Replace PUSH_PASSWORD in .env with a long random secret
chmod 600 .env
docker compose up -d --build
docker compose logs -f
```

By default both host ports bind to `127.0.0.1`; this avoids exposing HTTP Basic credentials over your LAN before configuring HTTPS. In Nginx Proxy Manager, add **two proxy hosts**, using TLS certificates:

- `registry.example.com` -> `http://registreasy:5000`
- `registry-push.example.com` -> `http://registreasy:5002`

If NPM runs on the same Docker host, connect its existing container to the Compose network:

```bash
docker network connect registreasy_default <npm-container-name>
```

The exact network name depends on your Docker Compose project name (check `docker network ls`). NPM can then resolve `registreasy` by container name. If NPM is on another host, bind both host ports to your server's LAN IP with `BIND_ADDRESS` and restrict inbound connections to NPM using a firewall.

## Inventory and health

Browse the **read endpoint's root URL**, for example `https://registry.example.com/`, to see the inventory. The page shows a sign-in form: choose **Pull** or **Push**, then enter that account's username (pre-filled with `pull` / `push`, editable if you changed `PULL_USERNAME` / `PUSH_USERNAME`) and password. It groups image repositories and displays tags, manifest digests, image build dates (where present in OCI/Docker config) and approximate tag update dates. It includes a repository/tag filter and health status. Credentials are kept only in the browser tab's memory.

| Route on read endpoint | Behaviour |
| --- | --- |
| `GET /` | Inventory page and sign-in form (the page itself is public; it contains no data) |
| `GET /api/inventory` | JSON repository/tag inventory; requires pull or push credentials when `PULL_PASSWORD` is set |
| `GET /healthz` | Unauthenticated health JSON (HTTP 200 healthy, HTTP 503 degraded) |

The `/api/` routes on both endpoints are rate limited (10 requests/second per endpoint, bursts of 20, then HTTP 429) to slow down password guessing. Docker traffic on `/v2/` is not limited.

`/healthz` checks that the underlying Registry v3 API responds and that the image storage is writable, and shows available storage bytes. The container healthcheck uses this endpoint.

**Dates:** The tag update date comes from the Registry filesystem's current tag-link modification time and is only an approximation of the last time the tag was written; it is not a reliable historical push event timestamp. An image's build timestamp comes from its OCI/Docker metadata and can be absent or very different from its push date. Historical versions are shown only while tagged. The inventory is cached for up to 20 seconds and currently supports up to 2,000 listed repositories/tags.

No separate container, database, ports or volumes are required. On the read endpoint the page is read-only, whichever account signs in. The publish endpoint serves the same page with delete controls (see below).

## Configuration

| Variable | Default | Meaning |
| --- | --- | --- |
| `PUSH_PASSWORD` | **Required** | Publisher password |
| `PUSH_USERNAME` | `push` | Publisher login |
| `PULL_PASSWORD` | Empty | Blank allows anyone with network access to pull |
| `PULL_USERNAME` | `pull` | Read-only login if `PULL_PASSWORD` is set |
| `BIND_ADDRESS` | `127.0.0.1` | Host interface on which both ports are published |
| `PORT` | `5000` | Read-only host port |
| `PUSH_PORT` | `5002` | Publishing host port |

Publisher credentials also permit read access. Read-only credentials **never permit writes**. Usernames accept letters, numbers, periods, underscores and hyphens, and must differ if both credentials are configured.

## Publish an image

```bash
docker login registry-push.example.com -u push
docker pull alpine:latest
docker tag alpine:latest registry-push.example.com/demo/alpine:1
docker push registry-push.example.com/demo/alpine:1
```

## Pull or deploy the same image

No login is required when `PULL_PASSWORD` is empty:

```bash
docker pull registry.example.com/demo/alpine:1
```

For your application:

```yaml
services:
  app:
    image: registry.example.com/demo/alpine:1
    restart: unless-stopped
```

When a version or tag changes: `docker compose pull && docker compose up -d`. The publisher and read hostname refer to the **same repository and tag** in the same underlying storage.

If you set `PULL_PASSWORD`, first use `docker login registry.example.com -u pull` on the remote host. Credentials persist in Docker's local credential store or configuration.

## Deleting images

The publish endpoint serves the inventory page too: `https://registry-push.<host>/` (publisher login). Each repository has a **Delete repository** button, and each tag row has a **Delete** button. Both show a preview first (which tags and manifests will go) and ask for confirmation.

Deleting a tag removes its manifest, so any other tag pointing at the same digest is removed too. The preview lists them.

API (publisher login, required header `X-Registreasy-Action: delete`):

```bash
curl -u push:"$PUSH_PASSWORD" -H 'Content-Type: application/json' -H 'X-Registreasy-Action: delete' \
  -d '{"repo":"tiller-router","tag":"latest","preview":true}' https://registry-push.<host>/api/delete
```

Omit `tag` to delete the whole repository. Use `"preview": true` to see the plan without deleting; the response includes a `plan_id`. Send that `plan_id` with the real delete and it is refused with HTTP 409 if the tags or digests changed since the preview (the web page always does this). Note the publish endpoint's `/api/delete` route is the only delete path; registry-level DELETE on `/v2/` also requires push login.

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

- Both endpoints need trusted HTTPS when accessed from other machines. NPM should terminate TLS.
- Only Nginx reaches the internal Registry v3 backend; direct backend access is blocked.
- Read endpoint blocks all non-GET/HEAD methods, regardless of username.
- The publishing endpoint challenges credentials at `GET /v2/`, which is required for reliable Docker CLI publishing.
- Deletion is available only on the publish endpoint, behind `PUSH_PASSWORD`. The read endpoint never shows delete controls (even to a publisher) and has no delete route at all.
- Registry deletes remove manifest references only. Disk space is reclaimed by garbage collection (see below).
- Without `PULL_PASSWORD`, images and tags are not confidential. Limit access through LAN/Tailscale/firewall rules if that matters.
- Environment secrets are visible to host-level Docker administrators via container inspection. Keep `.env` private, and rotate passwords when needed.
- Persistent image storage and the stable internal HTTP signing secret live in `./data`; back it up.
- `PUSH_PORT` should only be reachable through the trusted TLS proxy. Limit access to it further by source IP if desired.

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
PUSH_PASSWORD=test-password docker compose up -d --build
PUSH_PASSWORD=test-password bash tests/smoke.sh \
  http://127.0.0.1:5000 http://127.0.0.1:5002
```

The smoke tests exercise both endpoints' access permissions; the test upload they start is cancelled afterwards, so they are safe to run against a live registry. GitHub Actions additionally tests real `docker login`, push and pull behaviour in both anonymous and protected-read modes, and the delete API.

This project wraps [CNCF Distribution](https://distribution.github.io/distribution/) and [Nginx](https://nginx.org/), rather than implementing image storage itself.
