FROM docker.io/maptiler/tileserver-gl:v5.5.0

USER root
RUN apt-get update && \
    apt-get install -y --no-install-recommends haproxy curl && \
    rm -rf /var/lib/apt/lists/*

COPY haproxy.cfg /usr/local/etc/haproxy/haproxy.cfg
COPY tileserver-config.json /tileserver-config.json
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

USER node
EXPOSE 8080

ENTRYPOINT ["/entrypoint.sh"]
