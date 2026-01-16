FROM alpine:3.23

RUN apk add --no-cache \
    bash \
    git \
    jq \
    curl \
    docker-cli \
    docker-compose \
    ca-certificates \
    nodejs-current \
    npm

RUN addgroup -g 1000 codespace && \
    adduser -D -u 1000 -G codespace -s /bin/bash codespace

COPY init.sh /init.sh
RUN chmod +x /init.sh

ENTRYPOINT ["/init.sh"]
