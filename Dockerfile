FROM mcr.microsoft.com/playwright:v1.56.1-jammy

ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=Europe/Rome

RUN ln -snf /usr/share/zoneinfo/${TZ} /etc/localtime \
    && echo ${TZ} > /etc/timezone \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
        bash \
        curl \
        jq \
        util-linux \
        findutils \
        coreutils \
        tzdata \
        nano \
        ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY package.json /app/package.json
RUN npm install --omit=dev

COPY mam-bonus-manager.sh /usr/local/bin/mam-bonus-manager
COPY lib /usr/local/bin/lib
COPY config /usr/local/bin/config
COPY scripts /usr/local/bin/scripts
COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh

RUN chmod +x /usr/local/bin/mam-bonus-manager \
    && chmod +x /usr/local/bin/docker-entrypoint.sh \
    && chmod +x /usr/local/bin/scripts/mam-browser-gift.js \
    && mkdir -p /config /data /config/browser-profile

ENV MAM_CONFIG=/config/config.env
ENV MAM_INTERVAL_SECONDS=3600
ENV PLAYWRIGHT_BROWSERS_PATH=/ms-playwright
ENV NODE_PATH=/app/node_modules

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
CMD ["scheduler"]
