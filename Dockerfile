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

# Working directory
WORKDIR /workspaces

# Environment
ENV PATH="/opt/codespace-host/bin:${PATH}"
ENV LOG_LEVEL="info"

# Entrypoint
ENTRYPOINT []
