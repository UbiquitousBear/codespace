FROM docker:27-cli

# Install dependencies
RUN apk add --no-cache \
    bash \
    ca-certificates \
    curl \
    git \
    jq \
    openssh-client \
    tar \
    gzip \
    nodejs \
    npm


# Devcontainer CLI for builds
ARG DEVCONTAINER_CLI_VERSION=latest
RUN npm install -g "@devcontainers/cli@${DEVCONTAINER_CLI_VERSION}" \
    && npm cache clean --force

# Copy codespace-host
COPY bin/ /opt/codespace-host/bin/
COPY init/ /opt/codespace-host/init/
COPY lib/ /opt/codespace-host/lib/
COPY defaults/ /opt/codespace-host/defaults/

# Make scripts executable
RUN chmod +x /opt/codespace-host/bin/* \
    && chmod +x /opt/codespace-host/init/*.sh \
    && chmod +x /opt/codespace-host/lib/*.sh

# Build metadata
ARG CODESPACE_HOST_VERSION="dev"
ENV CODESPACE_HOST_VERSION="${CODESPACE_HOST_VERSION}"
RUN echo "${CODESPACE_HOST_VERSION}" > /opt/codespace-host/VERSION

# Install Coder CLI using official install script
# The script detects the platform and installs the appropriate binary
ARG CODER_VERSION=2.28.6
ENV CODER_VERSION="${CODER_VERSION}"

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

# Working directory
WORKDIR /workspaces

# Environment
ENV PATH="/opt/codespace-host/bin:${PATH}"
ENV LOG_LEVEL="info"

# Entrypoint
ENTRYPOINT []
