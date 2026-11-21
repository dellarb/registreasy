#!/usr/bin/env bash
# Build a project's Dockerfile and push it to Registreasy (publish endpoint).
# Run on the registry box: the publish port is bound to 127.0.0.1.
#
# usage: scripts/publish.sh <src-dir> <repo-name> <tag> [platform]
#   src-dir    directory holding the Dockerfile (build context)
#   repo-name  repository path on the registry, e.g. tiller-router
#   tag        image tag, e.g. dirty-9cc8027 or 1.0.0
#   platform   default linux/amd64
set -euo pipefail

src="${1:?src-dir required}"; name="${2:?repo-name required}"; tag="${3:?tag required}"
platform="${4:-linux/amd64}"
envfile="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/.env"

set -a; . "$envfile"; set +a
host="127.0.0.1:${PUSH_PORT:-5002}"   # after .env, so its PUSH_PORT is honoured
img="$host/$name:$tag"

rev=$(git -C "$src" rev-parse HEAD 2>/dev/null || echo unknown)
dirty=$(git -C "$src" status --porcelain 2>/dev/null | wc -l)
printf '%s' "$PUSH_PASSWORD" | docker login "$host" -u "$PUSH_USERNAME" --password-stdin >/dev/null
trap 'docker logout "$host" >/dev/null 2>&1 || true' EXIT

# Build into the local daemon, then push with the daemon: buildx's BuildKit
# container cannot reach the host's 127.0.0.1 and the daemon already treats
# localhost as an allowed plain-HTTP registry. Single-arch only (host arch).
docker buildx build --platform "$platform" --load \
  --label "org.opencontainers.image.revision=$rev" \
  --label "org.opencontainers.image.source=$src" \
  --label "dev.registreasy.dirty-files=$dirty" \
  -t "$img" "$src"
docker push "$img" | tail -2
echo "pushed $img (revision $rev, dirty files at build: $dirty)"
