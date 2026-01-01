FROM alpine:3.23

RUN apk add --no-cache \
    bash \
    git \
    jq \
    curl \
    docker-cli \
    docker-compose

# Install code-server
RUN curl -fsSL https://code-server.dev/install.sh | sh

# Install coder agent bootstrap
RUN curl -fsSL https://coder.com/install.sh | sh

COPY init.sh /init.sh
RUN chmod +x /init.sh

ENTRYPOINT ["/init.sh"]
