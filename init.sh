#!/bin/bash
set -e

echo "Codespace initializing..."

# Read configuration injected via cloud-init or configmap
CODER_AGENT_TOKEN=$(cat /run/config/coder-token 2>/dev/null || echo "")
GITHUB_TOKEN=$(cat /run/config/github-token 2>/dev/null || echo "")
REPO_URL=$(cat /run/config/repo-url 2>/dev/null || echo "")
BRANCH=$(cat /run/config/branch 2>/dev/null || echo "main")

export CODER_AGENT_TOKEN GITHUB_TOKEN

# Wait for Docker
echo "Waiting for Docker..."
while ! docker info &>/dev/null; do
  sleep 1
done

# Extract repo name from URL
REPO_NAME=$(basename "$REPO_URL" .git)
REPO_DIR="/workspaces/$REPO_NAME"

# Clone repository
if [ -n "$REPO_URL" ] && [ ! -d "$REPO_DIR/.git" ]; then
  echo "Cloning $REPO_URL..."
  git clone --branch "$BRANCH" --depth 1 "$REPO_URL" "$REPO_DIR"
fi

cd "$REPO_DIR"

# Configure git
git config --global credential.helper store
git config --global --add safe.directory "$REPO_DIR"

# Devcontainer handling
DEVCONTAINER_JSON=""
[ -f ".devcontainer/devcontainer.json" ] && DEVCONTAINER_JSON=".devcontainer/devcontainer.json"
[ -f ".devcontainer.json" ] && DEVCONTAINER_JSON=".devcontainer.json"

if [ -n "$DEVCONTAINER_JSON" ]; then
  echo "Processing devcontainer from repo..."
  
  COMPOSE_FILE=$(jq -r '.dockerComposeFile // empty' "$DEVCONTAINER_JSON")
  
  if [ -n "$COMPOSE_FILE" ]; then
    echo "Starting docker-compose configuration..."
    COMPOSE_DIR=$(dirname "$DEVCONTAINER_JSON")
    docker-compose -f "$COMPOSE_DIR/$COMPOSE_FILE" up -d
  else
    # Handle single-container devcontainer
    DOCKERFILE=$(jq -r '.build.dockerfile // .dockerFile // empty' "$DEVCONTAINER_JSON")
    IMAGE=$(jq -r '.image // empty' "$DEVCONTAINER_JSON")
    
    if [ -n "$DOCKERFILE" ]; then
      echo "Building devcontainer..."
      CONTEXT=$(jq -r '.build.context // "."' "$DEVCONTAINER_JSON")
      docker build -t devcontainer:local -f "$(dirname "$DEVCONTAINER_JSON")/$DOCKERFILE" "$(dirname "$DEVCONTAINER_JSON")/$CONTEXT"
    elif [ -n "$IMAGE" ]; then
      echo "Pulling $IMAGE..."
      docker pull "$IMAGE"
      docker tag "$IMAGE" devcontainer:local
    fi
  fi
  
  # Run lifecycle commands
  for cmd in onCreateCommand postCreateCommand postStartCommand; do
    CMD_VALUE=$(jq -r ".$cmd // empty" "$DEVCONTAINER_JSON")
    if [ -n "$CMD_VALUE" ]; then
      echo "Running $cmd..."
      eval "$CMD_VALUE" || true
    fi
  done
fi

# Install code-server
curl -fsSL https://code-server.dev/install.sh | sh

# Install coder agent bootstrap
curl -fsSL https://coder.com/install.sh | sh

# Start code-server
echo "Starting code-server..."
code-server \
  --auth none \
  --bind-addr 0.0.0.0:13337 \
  --disable-telemetry \
  "$REPO_DIR" &

# Start Coder agent (blocking)
echo "Starting Coder agent..."
exec coder agent
