FROM alpine:3.23

RUN apk add --no-cache \
    bash \
    git \
    jq \
    curl \
    docker-cli \
    docker-compose \
    shadow

RUN groupadd -g 107 codespace && \
    useradd -m -u 107 -g 107 -s /bin/bash codespace

RUN mkdir -p /home/codespace && chown -R 107:107 /home/codespace


COPY init.sh /init.sh
RUN chmod +x /init.sh

USER codespace

ENTRYPOINT ["/init.sh"]
