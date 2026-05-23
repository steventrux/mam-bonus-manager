FROM alpine:3.20

RUN apk add --no-cache \
    bash \
    curl \
    jq \
    util-linux \
    findutils \
    coreutils \
    tzdata \
    nano

WORKDIR /app

COPY mam-bonus-manager.sh /usr/local/bin/mam-bonus-manager
COPY lib /usr/local/bin/lib
COPY config /usr/local/bin/config
COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh

RUN chmod +x /usr/local/bin/mam-bonus-manager \
    && chmod +x /usr/local/bin/docker-entrypoint.sh \
    && mkdir -p /config /data

ENV TZ=Europe/Rome
ENV MAM_CONFIG=/config/config.env
ENV MAM_INTERVAL_SECONDS=3600

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
CMD ["scheduler"]
