#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

if [[ -z "${PUSH_PASSWORD:-}" ]]; then
    echo "ERROR: PUSH_PASSWORD must be set and non-empty" >&2
    exit 1
fi
PUSH_USERNAME="${PUSH_USERNAME:-push}"
PULL_USERNAME="${PULL_USERNAME:-pull}"
PULL_PASSWORD="${PULL_PASSWORD:-}"

for username in "$PUSH_USERNAME" "$PULL_USERNAME"; do
    if [[ ! "$username" =~ ^[a-zA-Z0-9._-]+$ ]]; then
        echo "ERROR: usernames may contain only letters, digits, dot, hyphen and underscore" >&2
        exit 1
    fi
done
if [[ -n "$PULL_PASSWORD" && "$PUSH_USERNAME" == "$PULL_USERNAME" ]]; then
    echo "ERROR: PUSH_USERNAME and PULL_USERNAME must be different" >&2
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
printf '%s\n' "$PUSH_PASSWORD" | htpasswd -niB -C 10 "$PUSH_USERNAME" > /run/registreasy/push.htpasswd

if [[ -n "$PULL_PASSWORD" ]]; then
    printf '%s\n' "$PULL_PASSWORD" | htpasswd -niB -C 10 "$PULL_USERNAME" > /run/registreasy/read.htpasswd
    # Publishers can also pull from the read endpoint.
    cat /run/registreasy/push.htpasswd >> /run/registreasy/read.htpasswd
    cat > /etc/nginx/pull-auth.conf <<'NGINX_AUTH'
auth_basic "Registreasy pull";
auth_basic_user_file /run/registreasy/read.htpasswd;
NGINX_AUTH
    echo "Registreasy: authenticated pulls enabled"
else
    cat > /etc/nginx/pull-auth.conf <<'NGINX_AUTH'
auth_basic off;
NGINX_AUTH
    echo "Registreasy: anonymous pulls enabled"
fi

chown root:nginx /run/registreasy/*.htpasswd
chmod 0640 /run/registreasy/*.htpasswd
chmod 0644 /etc/nginx/pull-auth.conf

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
nginx -g 'daemon off;' &
nginx_pid=$!

cleanup() {
    trap - EXIT INT TERM
    kill "$registry_pid" "$nginx_pid" 2>/dev/null || true
    wait "$registry_pid" "$nginx_pid" 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
wait -n "$registry_pid" "$nginx_pid"
