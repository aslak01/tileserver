FROM docker.io/maptiler/tileserver-gl:latest

USER root
RUN apt-get update && \
    apt-get install -y --no-install-recommends haproxy curl && \
    rm -rf /var/lib/apt/lists/*

COPY haproxy.cfg /usr/local/etc/haproxy/haproxy.cfg
COPY tileserver-config.json /tileserver-config.json
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 8080

ENTRYPOINT ["/entrypoint.sh"]
