#!/usr/bin/env bash
# HTTP-level permission tests. Run against a throwaway instance.
set -Eeuo pipefail

base="${1:-http://127.0.0.1:5000}"
base="${base%/}"
push_user="${PUSH_USERNAME:-push}"
pull_user="${PULL_USERNAME:-pull}"
: "${PUSH_PASSWORD:?Set PUSH_PASSWORD when running smoke tests}"

request() {
    local method="$1" path="$2"
    shift 2
    curl -sS --max-time 15 --output /dev/null --write-out '%{http_code}' -X "$method" "$@" "$base$path"
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
    expect 401 "$(request GET /v2/)" "anonymous read denied"
    expect 200 "$(request GET /v2/ -u "$pull_user:$PULL_PASSWORD")" "pull account reads"
    expect 200 "$(request GET /v2/ -u "$push_user:$PUSH_PASSWORD")" "push account reads"
    expect 401 "$(request POST /v2/smoke/blobs/uploads/ -u "$pull_user:$PULL_PASSWORD")" "pull account cannot write"
else
    expect 200 "$(request GET /v2/)" "anonymous read succeeds"
fi

expect 401 "$(request POST /v2/smoke/blobs/uploads/)" "anonymous write denied"
expect 401 "$(request POST /v2/smoke/blobs/uploads/ -u "$push_user:incorrect")" "incorrect push password denied"
expect 202 "$(request POST /v2/smoke/blobs/uploads/ -u "$push_user:$PUSH_PASSWORD")" "publisher may begin blob upload"
expect 404 "$(request GET /)" "non-registry routes blocked"
