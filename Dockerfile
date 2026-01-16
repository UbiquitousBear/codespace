# codespace-host: coordinates devcontainer + runs coder agent inside it
FROM alpine:3.23

# Basic tooling needed for coordination + talking to Docker
RUN apk add --no-cache \
    bash \
    git \
    jq \
    curl \
    ca-certificates \
    docker-cli

# Create a non-root user (host doesn’t run user workloads, just orchestration)
RUN addgroup -g 1000 codespace && \
    adduser -D -u 1000 -G codespace -s /bin/bash codespace

#
# Bake the coder binary into the host image
# (you can pin a version or switch this to an internal mirror later)
#
RUN curl -fsSL https://coder.com/install.sh | sh -s -- --bin-dir /usr/local/bin

# Optional: sanity check (can be removed later)
RUN ls -l /usr/local/bin/coder

# Add the host init script
COPY init.sh /usr/local/bin/init-host.sh
RUN chmod +x /usr/local/bin/init-host.sh

USER codespace
WORKDIR /home/codespace

ENTRYPOINT ["/usr/local/bin/init-host.sh"]
