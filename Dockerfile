FROM alpine:3.23

RUN apk add --no-cache \
    bash \
    git \
    jq \
    curl \
    docker-cli \
    docker-compose \
    ca-certificates

RUN addgroup -g 1000 codespace && \
    adduser -D -u 1000 -G codespace -s /bin/bash codespace

# Install envbuilder (static binary)
RUN curl -fsSL https://github.com/coder/envbuilder/releases/latest/download/envbuilder-linux-amd64 \
      -o /usr/local/bin/envbuilder \
 && chmod +x /usr/local/bin/envbuilder

COPY init.sh /init.sh
RUN chmod +x /init.sh

ENTRYPOINT ["/init.sh"]
