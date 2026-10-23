# syntax=docker/dockerfile:1
# Reuse the upstream Docker Distribution v3 binary; add only nginx and startup glue.
FROM registry:3 AS distribution

FROM nginx:1.28-alpine

RUN apk add --no-cache apache2-utils bash tini

COPY --from=distribution /bin/registry /usr/local/bin/registry
COPY registry.yml /etc/distribution/config.yml
COPY nginx.conf /etc/nginx/nginx.conf
COPY entrypoint.sh /usr/local/bin/registreasy-entrypoint
RUN chmod 0755 /usr/local/bin/registreasy-entrypoint \
    && mkdir -p /data /run/registreasy

ENV OTEL_TRACES_EXPORTER=none

EXPOSE 5000
VOLUME ["/data"]

HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
  CMD wget -q -O /dev/null http://127.0.0.1:5001/v2/ || exit 1

ENTRYPOINT ["/sbin/tini", "--", "/usr/local/bin/registreasy-entrypoint"]
