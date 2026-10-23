# Registreasy

A **single-container Docker registry** powered by upstream CNCF Distribution v3 and Nginx. Built for simple self-hosted image publishing, with an optional password for pulls and a separate password for pushes.

- One container, one `./data` persistence directory, no external database
- `PUSH_PASSWORD` **required**, `PULL_PASSWORD` **optional**
- Anonymous pulls by default
- Publishing always requires the publisher's credentials
- Standard `docker login`, `docker push`, `docker pull`, and Compose updates
- No custom Docker registry protocol or custom token-authentication service

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

## Security

- Both endpoints need trusted HTTPS when accessed from other machines. NPM should terminate TLS.
- Only Nginx reaches the internal Registry v3 backend; direct backend access is blocked.
- Read endpoint blocks all non-GET/HEAD methods, regardless of username.
- The publishing endpoint challenges credentials at `GET /v2/`, which is required for reliable Docker CLI publishing.
- Registry manifest deletion is disabled by default. No deletion controls or user-management UI are provided.
- Without `PULL_PASSWORD`, images and tags are not confidential. Limit access through LAN/Tailscale/firewall rules if that matters.
- Environment secrets are visible to host-level Docker administrators via container inspection. Keep `.env` private, and rotate passwords when needed.
- Persistent image storage and the stable internal HTTP signing secret live in `./data`; back it up.
- `PUSH_PORT` should only be reachable through the trusted TLS proxy. Limit access to it further by source IP if desired.

## Development

```bash
docker build -t registreasy:local .
PUSH_PASSWORD=test-password docker compose up -d --build
PUSH_PASSWORD=test-password bash tests/smoke.sh \
  http://127.0.0.1:5000 http://127.0.0.1:5002
```

The smoke tests exercise both endpoints' access permissions. GitHub Actions additionally tests real `docker login`, push and pull behaviour in both anonymous and protected-read modes.

This project wraps [CNCF Distribution](https://distribution.github.io/distribution/) and [Nginx](https://nginx.org/), rather than implementing image storage itself.
