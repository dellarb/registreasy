#!/usr/bin/env bash
# HTTP permission checks for both listeners, against a throwaway registry.
set -Eeuo pipefail
read_endpoint="${1:-http://127.0.0.1:5000}"
push_endpoint="${2:-http://127.0.0.1:5002}"
read_endpoint="${read_endpoint%/}"
push_endpoint="${push_endpoint%/}"
push_user="${PUSH_USERNAME:-push}"
pull_user="${PULL_USERNAME:-pull}"
: "${PUSH_PASSWORD:?Set PUSH_PASSWORD when running smoke tests}"

request() {
    local host="$1" method="$2" path="$3"
    shift 3
    curl -sS --max-time 15 --output /dev/null --write-out '%{http_code}' -X "$method" "$@" "$host$path"
}
expect() {
    local expected="$1" actual="$2" description="$3"
    if [[ "$expected" != "$actual" ]]; then
        echo "FAIL: $description (expected $expected, got $actual)" >&2
        exit 1
    fi
    echo "PASS: $description"
}

if [[ -n "${PULL_PASSWORD:-}" ]]; then
    expect 401 "$(request "$read_endpoint" GET /v2/)" "anonymous read denied"
    expect 200 "$(request "$read_endpoint" GET /v2/ -u "$pull_user:$PULL_PASSWORD")" "pull user can read"
    expect 200 "$(request "$read_endpoint" GET /v2/ -u "$push_user:$PUSH_PASSWORD")" "publisher can read"
else
    expect 200 "$(request "$read_endpoint" GET /v2/)" "anonymous read succeeds"
fi

expect 403 "$(request "$read_endpoint" POST /v2/smoke/blobs/uploads/ -u "$push_user:$PUSH_PASSWORD")" "read endpoint rejects writes even by publisher"
expect 401 "$(request "$push_endpoint" GET /v2/)" "publisher endpoint requires authentication"
expect 401 "$(request "$push_endpoint" GET /v2/ -u "$push_user:incorrect")" "incorrect publisher password rejected"
expect 200 "$(request "$push_endpoint" GET /v2/ -u "$push_user:$PUSH_PASSWORD")" "valid publisher can authenticate"
if [[ -n "${PULL_PASSWORD:-}" ]]; then
    expect 401 "$(request "$push_endpoint" GET /v2/ -u "$pull_user:$PULL_PASSWORD")" "read-only user cannot authenticate to publisher"
fi
expect 401 "$(request "$push_endpoint" POST /v2/smoke/blobs/uploads/)" "anonymous write rejected"
expect 202 "$(request "$push_endpoint" POST /v2/smoke/blobs/uploads/ -u "$push_user:$PUSH_PASSWORD")" "authenticated publisher may upload"
