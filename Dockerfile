# codespace-host image
# This runs as a LinuxKit service and orchestrates the dev container

FROM docker:27-dind

# Install dependencies
RUN apk add --no-cache \
    bash \
    curl \
    git \
    jq \
    openssh-client \
    tar \
    gzip

# Optional: Install oras for dev container features support
# This enables pulling OCI artifacts for features
ARG ORAS_VERSION=1.3.0
RUN curl -fsSL "https://github.com/oras-project/oras/releases/download/v${ORAS_VERSION}/oras_${ORAS_VERSION}_linux_amd64.tar.gz" \
    | tar -xz -C /usr/local/bin oras

COPY bin/ /opt/codespace-host/bin/
COPY lib/ /opt/codespace-host/lib/
COPY defaults/ /opt/codespace-host/defaults/

RUN chmod +x /opt/codespace-host/bin/* \
    && chmod +x /opt/codespace-host/lib/*.sh

ARG CODER_VERSION=2.28.6
RUN curl -fsSL https://coder.com/install.sh | sh -s -- --version ${CODER_VERSION}

# Working directory
WORKDIR /workspaces

# Environment
ENV PATH="/opt/codespace-host/bin:${PATH}"
ENV LOG_LEVEL="info"

# Entrypoint
ENTRYPOINT ["/opt/codespace-host/bin/codespace-host.sh"]
