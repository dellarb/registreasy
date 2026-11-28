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
# Wrong-password attempts count towards a per-client lockout. Over plain HTTP the
# endpoint trusts X-Forwarded-For from this (private) host, so each run uses a
# throwaway private address and repeated runs never lock out the real one.
scratch_ip="10.$((RANDOM % 250)).$((RANDOM % 250)).$((RANDOM % 250))"

# Machine-readable records for run-tests.sh: each check prints the PASS/FAIL line
# you read and, on the same line, a "CHECK <name> PASS|FAIL" record that the
# runner attributes to this script. Names must stay unique, because
# `run-tests.sh --full <test>` selects one by that name. The shell still decides
# pass or fail; nothing here re-parses curl output.
record() {  # record PASS|FAIL <name> [file:line: detail]
    echo "CHECK $2 $1${3:+ $3}"
    if [[ "$1" == FAIL && -n "${3:-}" ]]; then
        echo "ASSERT $3"
    fi
}
note() { echo "NOTE tests/smoke.sh $1"; }
smoke_where() { echo "tests/smoke.sh:$1"; }
smoke_die() {
    note "aborting after the failed check above"
    exit 1  # no SUMMARY record, so the runner reports the failed check above
}

request() {
    local method="$1" path="$2"
    shift 2
    curl -sS --max-time 15 --output /dev/null --write-out '%{http_code}' -X "$method" "$@" "$endpoint$path"
}
expect() {
    local expected="$1" actual="$2" description="$3"
    if [[ "$expected" != "$actual" ]]; then
        echo "FAIL: $description (expected $expected, got $actual)" >&2
        record FAIL "$description" "$(smoke_where "$LINENO"): expected $expected, got $actual"
        smoke_die
    fi
    echo "PASS: $description"
    record PASS "$description"
}
# grep based checks: grep_check <description> <grep args...>
grep_check() {
    local description="$1"
    shift
    if grep -qi "$@" 2>/dev/null; then
        echo "PASS: $description"
        record PASS "$description"
    else
        echo "FAIL: $description" >&2
        record FAIL "$description" "$(smoke_where "$LINENO"): pattern $* not found"
        note "headers under test: $(tr -d '\r' <"${!#}" | tr '\n' '|')"
        smoke_die
    fi
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
expect 401 "$(request GET /api/inventory -u "$pull_user:incorrect" -H "X-Forwarded-For: $scratch_ip")" "inventory API rejects a wrong password"
expect 200 "$(request GET /api/inventory "${pull[@]}")" "pull user can read the inventory API"
expect 401 "$(delete_api)" "delete API needs credentials"
expect 403 "$(delete_api "${pull[@]}")" "pull user cannot use the delete API"
expect 403 "$(request POST /api/delete "${push[@]}" -H 'Content-Type: application/json' -d '{"repo":"x"}')" "delete API requires the action header"
expect 400 "$(delete_api "${push[@]}")" "publisher reaches the delete API (unknown repo refused)"
expect 400 "$(request GET "/api/inventory?password=x")" "credentials in the URL are refused"

# --- Browser sessions -------------------------------------------------------
origin="$(printf '%s' "$endpoint" | sed -E 's#^(https?://[^/]+).*#\1#')"
workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT
signin() {  # signin <user> <password> [curl args...] -> HTTP status; headers in $workdir/headers
    local user="$1" password="$2"
    shift 2
    curl -sS --max-time 15 --output "$workdir/body" --dump-header "$workdir/headers" --write-out '%{http_code}' \
        -X POST -H 'Content-Type: application/json' \
        --data-binary "$(python3 -c 'import json,sys; print(json.dumps({"username":sys.argv[1],"password":sys.argv[2]}))' "$user" "$password")" \
        "$@" "$endpoint/api/session"
}
cookie_of() { awk 'tolower($1) == "set-cookie:" { sub(/\r$/, ""); split($2, kv, ";"); print kv[1] }' "$workdir/headers"; }

expect 403 "$(signin "$pull_user" "$PULL_PASSWORD" -H "Origin: $origin")" "sign-in requires the action header"
expect 403 "$(signin "$pull_user" "$PULL_PASSWORD" -H 'X-Registreasy-Action: signin' -H 'Origin: https://evil.example')" "sign-in from another origin is refused"
expect 401 "$(signin "$pull_user" incorrect -H 'X-Registreasy-Action: signin' -H "Origin: $origin" -H "X-Forwarded-For: $scratch_ip")" "sign-in rejects a wrong password"
expect 200 "$(signin "$pull_user" "$PULL_PASSWORD" -H 'X-Registreasy-Action: signin' -H "Origin: $origin")" "pull user can sign in"
grep_check "session cookie is HttpOnly and SameSite=Strict" -E '^set-cookie:.*HttpOnly.*SameSite=Strict' "$workdir/headers"
if [[ "$origin" == https://* ]]; then
    grep_check "HTTPS cookie is __Host- and Secure" -E '^set-cookie: __Host-registreasy_session=.*Secure' "$workdir/headers"
fi
pull_cookie="$(cookie_of)"
expect 200 "$(request GET /api/session -b "$pull_cookie")" "session cookie is accepted"
expect 200 "$(request GET /api/inventory -b "$pull_cookie")" "session cookie reads the inventory"
expect 403 "$(request POST /api/delete -b "$pull_cookie" -H "Origin: $origin" -H 'X-Registreasy-Action: delete' \
    -H 'Content-Type: application/json' -d '{"repo":"smoke/does-not-exist","preview":true}')" "pull session cannot delete"

expect 200 "$(signin "$push_user" "$PUSH_PASSWORD" -H 'X-Registreasy-Action: signin' -H "Origin: $origin")" "publisher can sign in"
push_cookie="$(cookie_of)"
expect 403 "$(request POST /api/delete -b "$push_cookie" -H 'X-Registreasy-Action: delete' \
    -H 'Content-Type: application/json' -d '{"repo":"smoke/does-not-exist","preview":true}')" "session delete requires an Origin"
expect 400 "$(request POST /api/delete -b "$push_cookie" -H "Origin: $origin" -H 'X-Registreasy-Action: delete' \
    -H 'Content-Type: application/json' -d '{"repo":"smoke/does-not-exist","preview":true}')" "publisher session reaches the delete API"
expect 403 "$(request DELETE /api/session -b "$push_cookie" -H "Origin: $origin")" "sign-out requires the action header"
for c in "$pull_cookie" "$push_cookie"; do
    expect 200 "$(request DELETE /api/session -b "$c" -H "Origin: $origin" -H 'X-Registreasy-Action: signout')" "sign out"
    expect 401 "$(request GET /api/session -b "$c")" "signed-out cookie is rejected by the server"
done

# --- Plain HTTP is LAN-only -----------------------------------------------------
# Only checkable when talking plain HTTP straight to the container from a private
# address: the endpoint then trusts X-Forwarded-* to simulate other clients.
if [[ "$origin" == http://* ]]; then
    public=(-H 'X-Forwarded-For: 203.0.113.7')
    expect 200 "$(request GET /api/inventory "${pull[@]}")" "LAN client may use Basic auth over plain HTTP"
    expect 403 "$(request GET /api/inventory "${pull[@]}" "${public[@]}")" "public client over plain HTTP is refused (API)"
    expect 403 "$(request GET /v2/ "${pull[@]}" "${public[@]}")" "public client over plain HTTP is refused (/v2/)"
    expect 403 "$(signin "$pull_user" "$PULL_PASSWORD" -H 'X-Registreasy-Action: signin' -H "Origin: $origin" "${public[@]}")" "public client cannot sign in over plain HTTP"
    expect 200 "$(request GET /healthz "${public[@]}")" "health stays public over plain HTTP"
    expect 200 "$(request GET /api/inventory "${pull[@]}" "${public[@]}" -H 'X-Forwarded-Proto: https')" "public client via a TLS proxy is allowed"
    expect 200 "$(signin "$pull_user" "$PULL_PASSWORD" -H 'X-Registreasy-Action: signin' -H "Origin: $origin" "${public[@]}" -H 'X-Forwarded-Proto: https')" "public client via a TLS proxy can sign in"
    grep_check "TLS-proxied sign-in gets a __Host- Secure cookie" -E '^set-cookie: __Host-registreasy_session=.*Secure' "$workdir/headers"
    grep_check "HSTS sent over HTTPS" -E '^strict-transport-security:' "$workdir/headers"
    request DELETE /api/session -b "$(cookie_of)" -H "Origin: $origin" -H 'X-Registreasy-Action: signout' "${public[@]}" -H 'X-Forwarded-Proto: https' >/dev/null
fi

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

echo "SUMMARY 1 0 0"
