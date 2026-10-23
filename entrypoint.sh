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

# htpasswd -i reads from stdin, avoiding passwords in process arguments.
# -B generates bcrypt hashes; write no plaintext credentials to disk.
printf '%s\n' "$PUSH_PASSWORD" | htpasswd -niB -C 10 "$PUSH_USERNAME" > /run/registreasy/push.htpasswd

if [[ -n "$PULL_PASSWORD" ]]; then
    printf '%s\n' "$PULL_PASSWORD" | htpasswd -niB -C 10 "$PULL_USERNAME" > /run/registreasy/read.htpasswd
    cat /run/registreasy/push.htpasswd >> /run/registreasy/read.htpasswd

    # Read methods accept either account; all other methods require publisher.
    cat > /etc/nginx/registry-auth.conf <<'NGINX_AUTH'
auth_basic "Registreasy read";
auth_basic_user_file /run/registreasy/read.htpasswd;

limit_except GET {
    auth_basic "Registreasy push";
    auth_basic_user_file /run/registreasy/push.htpasswd;
}
NGINX_AUTH
    echo "Registreasy: authenticated pulls enabled"
else
    # GET also allows HEAD in nginx's limit_except semantics.
    cat > /etc/nginx/registry-auth.conf <<'NGINX_AUTH'
limit_except GET {
    auth_basic "Registreasy push";
    auth_basic_user_file /run/registreasy/push.htpasswd;
}
NGINX_AUTH
    echo "Registreasy: anonymous pulls enabled"
fi

chown root:nginx /run/registreasy/*.htpasswd
chmod 0640 /run/registreasy/*.htpasswd
chmod 0644 /etc/nginx/registry-auth.conf

# Do not propagate the passwords to the two long-running child processes.
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

# If either service stops, exit so Docker can restart the whole container.
wait -n "$registry_pid" "$nginx_pid"
