FROM docker:27-dind

# Install dependencies
RUN apk add --no-cache \
    bash \
    curl \
    git \
    jq \
    openssh-client \
    tar \
    gzip \
    nodejs \
    npm

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

RUN set -eux; \
  curl -fsSL "https://github.com/coder/coder/releases/download/v${CODER_VERSION}/coder_${CODER_VERSION}_linux_amd64.tar.gz" \
    -o /tmp/coder.tar.gz; \
  mkdir -p /tmp/coder-extract; \
  tar -xzf /tmp/coder.tar.gz -C /tmp/coder-extract; \
  # adjust this mv if they ever change the layout:
  mv /tmp/coder-extract/coder /usr/local/bin/coder || \
    mv /tmp/coder-extract/coder_${CODER_VERSION}_linux_amd64/coder /usr/local/bin/coder; \
  chmod +x /usr/local/bin/coder; \
  rm -rf /tmp/coder.tar.gz /tmp/coder-extract

  RUN curl -fsSL https://code-server.dev/install.sh | sh && \
  rm -rf ~/.cache/

# Working directory
WORKDIR /workspaces

# Environment
ENV PATH="/opt/codespace-host/bin:${PATH}"
ENV LOG_LEVEL="info"

# Entrypoint
ENTRYPOINT ["/opt/codespace-host/bin/codespace-host"]