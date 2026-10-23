# Registreasy

A small, single-container Docker/OCI registry with **authenticated pushes** and **optional anonymous pulls**. It packages the upstream [CNCF Distribution Registry v3](https://distribution.github.io/distribution/) and Nginx; it does not reimplement the registry protocol.

- One Docker container and one port
- `PUSH_PASSWORD` is required
- `PULL_PASSWORD` is optional; blank means anyone who can reach the service may pull
- A read-only account cannot publish, replace, or delete images
- All images persist in `./data`
- Works with standard Docker CLI and Docker Compose
- No database, UI, token service, or custom registry protocol

## Quick start

```bash
git clone https://github.com/berenebot-agent/registreasy.git
cd registreasy
cp .env.example .env
# Edit .env and set a long, random PUSH_PASSWORD
chmod 600 .env
docker compose up -d --build
```

By default, the port is bound to **127.0.0.1:5000** so an upstream HTTPS reverse proxy can be used without exposing unencrypted credentials on the LAN.

In Nginx Proxy Manager, forward your TLS-enabled registry hostname to `registreasy:5000` on a shared Docker network, or to the host's selected address and port. For NPM on the **same Docker host**, attach its container to the project's network:

```bash
docker network connect registreasy_default <npm-container-name>
```

Then forward to `registreasy`, port `5000`. If Docker Compose uses a different project name, inspect `docker network ls`.

If NPM runs on **another machine**, set `BIND_ADDRESS` in `.env` to this server's LAN IP (not 127.0.0.1), and firewall the port so only NPM can reach it. Never publish plain HTTP directly to the internet; HTTP Basic credentials require TLS in transit.

Check the API through your proxy:

```bash
curl -i https://registry.example.com/v2/
```

An anonymous-read registry returns HTTP 200. A registry with `PULL_PASSWORD` set returns HTTP 401 until valid credentials are sent.

## Configuration

| Environment variable | Default | Purpose |
| --- | --- | --- |
| `PUSH_PASSWORD` | **Required** | Password for the publishing account |
| `PUSH_USERNAME` | `push` | Publishing account name |
| `PULL_PASSWORD` | Empty | Optional password to require for pulls |
| `PULL_USERNAME` | `pull` | Read-only account name (if enabled) |
| `BIND_ADDRESS` | `127.0.0.1` | Host address for Docker's published port |
| `PORT` | `5000` | Host port; internal container port is always 5000 |

Usernames accept letters, digits, underscore, hyphen and dot. Push and pull usernames must differ. The publishing user also has pull permissions. The `./data` directory is the only required persistent mount; image data stays there. Generated bcrypt password files live only in the container's runtime directory and are recreated at startup.

### Open pull, restricted push (default)

On an HTTPS-enabled build host:

```bash
# Not a reliable password check with anonymous pulls: see note below
docker login registry.example.com -u push
docker tag alpine:latest registry.example.com/demo/alpine:1
docker push registry.example.com/demo/alpine:1
```

On a deployment host, without logging in:

```bash
docker pull registry.example.com/demo/alpine:1
```

An app can use `image: registry.example.com/demo/alpine:1` with normal `docker compose pull && docker compose up -d`.

### Protected pulls

Set `PULL_PASSWORD` and restart with `docker compose up -d`. Pull users log in using `PULL_USERNAME` and `PULL_PASSWORD`. The publishing user can still read, but the pull user cannot write.

**Important Docker CLI behaviour:** when pulls are anonymous, `GET /v2/` does not challenge the client. Consequently, `docker login` may say it succeeded even with an incorrect push password; an actual `docker push` is the authorization test. When pull authentication is enabled, login performs a meaningful credential check.

## Security and limitations

- This is intended for small, single-node registries. It has no user-management UI or fine-grained per-repository policies.
- The Nginx proxy is the **only external path** to Registry v3, which listens on loopback inside the container.
- GET and HEAD are read methods. Nginx requires the publishing account for POST, PUT, PATCH, DELETE and all other methods.
- Registry v3 has its delete API disabled by default, including for publishers.
- When `PULL_PASSWORD` is unset, image contents, tags and manifests are accessible to anyone who can connect. Use a LAN/Tailscale firewall or HTTPS proxy access restrictions if needed.
- NPM handles HTTPS. Do **not** send Basic credentials over unencrypted HTTP except for controlled localhost testing.
- Docker Compose interpolates passwords into the container environment and Docker administrators can inspect them. Keep `.env` private, restrict host access, and rotate credentials when necessary.
- Back up `./data`. Avoid editing registry storage directly.
- `docker login` credentials persist in Docker's credential store (or its local Docker configuration) until changed or removed.

## Development and tests

```bash
docker build -t registreasy:local .
PUSH_PASSWORD=test-push docker compose up -d --build
bash tests/smoke.sh http://127.0.0.1:5000
```

The smoke test checks anonymous read and writer authentication at the HTTP API level. CI also builds the container and runs real Docker push/pull scenarios in both authentication modes.

Source: [CNCF Distribution](https://distribution.github.io/distribution/), [Nginx](https://nginx.org/).