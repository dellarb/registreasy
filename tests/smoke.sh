#!/usr/bin/env bash
# HTTP permission checks for the single endpoint. Safe against a live registry:
# the one upload it starts is cancelled, and every other write is refused.
set -Eeuo pipefail
endpoint="${1:-http://127.0.0.1:5000}"
endpoint="${endpoint%/}"
push_user="${PUSH_USERNAME:-push}"
pull_user="${PULL_USERNAME:-pull}"
: "${PUSH_PASSWORD:?Set PUSH_PASSWORD when running smoke tests}"
: "${PULL_PASSWORD:?Set PULL_PASSWORD when running smoke tests}"
push=(-u "$push_user:$PUSH_PASSWORD")
pull=(-u "$pull_user:$PULL_PASSWORD")

request() {
    local method="$1" path="$2"
    shift 2
    curl -sS --max-time 15 --output /dev/null --write-out '%{http_code}' -X "$method" "$@" "$endpoint$path"
}
expect() {
    local expected="$1" actual="$2" description="$3"
    if [[ "$expected" != "$actual" ]]; then
        echo "FAIL: $description (expected $expected, got $actual)" >&2
        exit 1
    fi
    echo "PASS: $description"
}
delete_api() {
    request POST /api/delete -H 'Content-Type: application/json' -H 'X-Registreasy-Action: delete' \
        -d '{"repo":"smoke/does-not-exist","preview":true}' "$@"
}

expect 401 "$(request GET /v2/)" "anonymous read challenged"
expect 401 "$(request GET /v2/ -u "$push_user:incorrect")" "incorrect publisher password rejected"
expect 401 "$(request GET /v2/ -u "$pull_user:incorrect")" "incorrect pull password rejected"
expect 200 "$(request GET /v2/ "${pull[@]}")" "pull user can read"
expect 200 "$(request GET /v2/ "${push[@]}")" "publisher can read"
expect 200 "$(request HEAD /v2/ "${pull[@]}" --head)" "pull user can HEAD"

expect 401 "$(request POST /v2/smoke/blobs/uploads/)" "anonymous write challenged"
expect 403 "$(request POST /v2/smoke/blobs/uploads/ "${pull[@]}")" "pull user cannot start an upload"
expect 403 "$(request PUT /v2/smoke/manifests/x "${pull[@]}" -H 'Content-Type: application/vnd.oci.image.manifest.v1+json' -d '{}')" "pull user cannot put a manifest"
expect 403 "$(request DELETE /v2/smoke/manifests/sha256:0000000000000000000000000000000000000000000000000000000000000000 "${pull[@]}")" "pull user cannot delete on /v2/"
expect 403 "$(request POST /v2/smoke/blobs/uploads/ -u "nobody:whatever")" "unknown user cannot write"
expect 401 "$(request POST /v2/smoke/blobs/uploads/ -u "$push_user:incorrect")" "publisher name with wrong password cannot write"

expect 200 "$(request GET /)" "inventory page is public"
expect 200 "$(request GET /healthz)" "health is public"
expect 401 "$(request GET /api/inventory)" "inventory API needs credentials"
expect 401 "$(request GET /api/inventory -u "$pull_user:incorrect")" "inventory API rejects a wrong password"
expect 200 "$(request GET /api/inventory "${pull[@]}")" "pull user can read the inventory API"
expect 401 "$(delete_api)" "delete API needs credentials"
expect 403 "$(delete_api "${pull[@]}")" "pull user cannot use the delete API"
expect 403 "$(request POST /api/delete "${push[@]}" -H 'Content-Type: application/json' -d '{"repo":"x"}')" "delete API requires the action header"
expect 400 "$(delete_api "${push[@]}")" "publisher reaches the delete API (unknown repo refused)"

# Start an upload, then cancel it so runs against a live registry leave no
# dangling upload session behind.
headers="$(curl -sS --max-time 15 --output /dev/null --dump-header - -X POST \
    "${push[@]}" "$endpoint/v2/smoke/blobs/uploads/")"
status="$(printf '%s\n' "$headers" | awk 'NR == 1 { print $2 }')"
expect 202 "$status" "publisher may upload"
location="$(printf '%s\n' "$headers" | awk 'tolower($1) == "location:" { print $2 }' | tr -d '\r')"
[[ "$location" == /* ]] && location="$endpoint$location"
if [[ -n "$location" ]]; then
    expect 204 "$(curl -sS --max-time 15 --output /dev/null --write-out '%{http_code}' -X DELETE \
        "${push[@]}" "$location")" "publisher can cancel the test upload"
fi
