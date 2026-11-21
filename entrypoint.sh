#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

for var in PUSH_PASSWORD PULL_PASSWORD; do
    if [[ -z "${!var:-}" ]]; then
        echo "ERROR: $var must be set and non-empty (use long random secrets)" >&2
        exit 1
    fi
done
PUSH_USERNAME="${PUSH_USERNAME:-push}"
PULL_USERNAME="${PULL_USERNAME:-pull}"
case "${REQUIRE_HTTPS:-0}" in
    1|true|yes) REQUIRE_HTTPS=1 ;;
    0|false|no|"") REQUIRE_HTTPS=0 ;;
    *) echo "ERROR: REQUIRE_HTTPS must be 0 or 1" >&2; exit 1 ;;
esac

for username in "$PUSH_USERNAME" "$PULL_USERNAME"; do
    if [[ ! "$username" =~ ^[a-zA-Z0-9._-]+$ ]]; then
        echo "ERROR: usernames may contain only letters, digits, dot, hyphen and underscore" >&2
        exit 1
    fi
done
# Case-insensitive: nginx's map lowercases $remote_user before matching it.
if [[ "${PUSH_USERNAME,,}" == "${PULL_USERNAME,,}" ]]; then
    echo "ERROR: PUSH_USERNAME and PULL_USERNAME must differ (ignoring case)" >&2
    exit 1
fi
if [[ "$PUSH_PASSWORD" == *$'\n'* || "$PULL_PASSWORD" == *$'\n'* ]]; then
    echo "ERROR: passwords cannot contain newlines" >&2
    exit 1
fi

mkdir -p /run/registreasy /data
chown root:nginx /run/registreasy
chmod 0750 /run/registreasy

# Use stdin to avoid leaking plaintext passwords through process arguments.
# push.htpasswd identifies the publisher; users.htpasswd (both accounts) guards /v2/.
printf '%s\n' "$PUSH_PASSWORD" | htpasswd -niB -C 10 "$PUSH_USERNAME" > /run/registreasy/push.htpasswd
printf '%s\n' "$PULL_PASSWORD" | htpasswd -niB -C 10 "$PULL_USERNAME" > /run/registreasy/users.htpasswd
cat /run/registreasy/push.htpasswd >> /run/registreasy/users.htpasswd
chown root:nginx /run/registreasy/*.htpasswd
chmod 0640 /run/registreasy/*.htpasswd

# Usernames are validated above, so they are safe inside a quoted nginx string.
cat > /etc/nginx/registreasy-users.conf <<NGINX_USERS
map \$remote_user \$registreasy_role {
    default other;
    ""      anon;
    "$PUSH_USERNAME" push;
}
# REQUIRE_HTTPS=1 refuses plain HTTP even from private (LAN) addresses.
map \$server_port \$registreasy_require_https {
    default $REQUIRE_HTTPS;
}
NGINX_USERS
chmod 0644 /etc/nginx/registreasy-users.conf

# The HTTP secret must remain stable across restarts for resumable uploads.
if [[ ! -s /data/.registry-http-secret ]]; then
    temp_secret="$(mktemp /data/.registry-http-secret.XXXXXX)"
    head -c 48 /dev/urandom | base64 | tr -d '\n' > "$temp_secret"
    chmod 0600 "$temp_secret"
    mv "$temp_secret" /data/.registry-http-secret
fi
export REGISTRY_HTTP_SECRET="$(cat /data/.registry-http-secret)"

# Child services need neither plain-text password.
unset PUSH_PASSWORD PULL_PASSWORD

nginx -t
registry serve /etc/distribution/config.yml &
registry_pid=$!
python3 /opt/registreasy/inventory.py &
inventory_pid=$!
nginx -g 'daemon off;' &
nginx_pid=$!

cleanup() {
    trap - EXIT INT TERM
    kill "$registry_pid" "$nginx_pid" "$inventory_pid" 2>/dev/null || true
    wait "$registry_pid" "$nginx_pid" "$inventory_pid" 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
wait -n "$registry_pid" "$nginx_pid" "$inventory_pid"
