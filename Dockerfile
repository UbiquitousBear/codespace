FROM docker:29-dind

# Install dependencies
RUN apk add --no-cache \
    bash \
    curl \
    git \
    jq \
    tar \
    gzip

# Optional: Install oras for dev container features support
# This enables pulling OCI artifacts for features
ARG ORAS_VERSION=1.2.0
RUN curl -fsSL "https://github.com/oras-project/oras/releases/download/v${ORAS_VERSION}/oras_${ORAS_VERSION}_linux_amd64.tar.gz" \
    | tar -xz -C /usr/local/bin oras

# Copy codespace-host
COPY bin/ /opt/codespace-host/bin/
COPY lib/ /opt/codespace-host/lib/
COPY defaults/ /opt/codespace-host/defaults/

# Make scripts executable
RUN chmod +x /opt/codespace-host/bin/* \
    && chmod +x /opt/codespace-host/lib/*.sh

# Install Coder CLI using official install script
# The script detects the platform and installs the appropriate binary
ARG CODER_VERSION=2.28.6
RUN curl -fsSL "https://github.com/coder/coder/releases/download/v${CODER_VERSION}/coder_${CODER_VERSION}_linux_amd64.tar.gz" \
  | tar -xz -C /usr/local/bin coder

# Working directory
WORKDIR /workspaces

# Environment
ENV PATH="/opt/codespace-host/bin:${PATH}"
ENV LOG_LEVEL="info"

# Entrypoint
ENTRYPOINT ["/opt/codespace-host/bin/codespace-host.sh"]
