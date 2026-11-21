# syntax=docker/dockerfile:1
# The upstream Docker Distribution v3 binary does all image storage and transfer.
FROM registry:3 AS distribution
FROM nginx:1.28-alpine

RUN apk add --no-cache apache2-utils bash tini python3
COPY --from=distribution /bin/registry /usr/local/bin/registry
COPY registry.yml /etc/distribution/config.yml
COPY nginx.conf /etc/nginx/nginx.conf
COPY registry-proxy.conf /etc/nginx/registry-proxy.conf
COPY entrypoint.sh /usr/local/bin/registreasy-entrypoint
COPY inventory.py /opt/registreasy/inventory.py
COPY web/ /opt/registreasy/web/
RUN chmod 0755 /usr/local/bin/registreasy-entrypoint \
    && mkdir -p /data /run/registreasy

ENV OTEL_TRACES_EXPORTER=none
EXPOSE 5000
VOLUME ["/data"]

HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
  CMD wget -q -O /dev/null http://127.0.0.1:5003/healthz || exit 1

ENTRYPOINT ["/sbin/tini", "--", "/usr/local/bin/registreasy-entrypoint"]
