FROM alpine:3.23

RUN apk add --no-cache \
    bash \
    git \
    jq \
    curl \
    docker-cli \
    docker-compose \
    shadow

RUN groupadd -g 1000 codespace && \
    useradd -m -u 1000 -g 1000 -s /bin/bash codespace

RUN mkdir -p /home/codespace && chown -R 1000:1000 /home/codespace


COPY init.sh /init.sh
RUN chmod +x /init.sh

USER codespace

ENTRYPOINT ["/init.sh"]
