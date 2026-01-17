#!/bin/bash
set -euo pipefail

log() {
  echo "[host] $*"
}

CONFIG_DIR=/run/config
CODER_BIN="/usr/local/bin/coder"

log "Starting codespace host init..."

########################################
# 1. Read config from /run/config
########################################
REPO_URL="$(cat "${CONFIG_DIR}/repo-url")"
BRANCH="$(cat "${CONFIG_DIR}/branch" 2>/dev/null || echo "main")"
GIT_NAME="$(cat "${CONFIG_DIR}/git-name" 2>/dev/null || echo "Coder User")"
GIT_EMAIL="$(cat "${CONFIG_DIR}/git-email" 2>/dev/null || echo "coder@example.com")"
CODER_TOKEN="$(cat "${CONFIG_DIR}/coder-token" 2>/dev/null || true)"
GITHUB_TOKEN="$(cat "${CONFIG_DIR}/github-token" 2>/dev/null || true)"
CODER_URL="$(cat "${CONFIG_DIR}/coder-url" 2>/dev/null || true)"

# These envs matter inside the agent & for user tools, so we’ll also pass
# them into the devcontainer via docker run.
export CODER_AGENT_TOKEN="${CODER_TOKEN:-}"
export CODER_AGENT_URL="${CODER_URL:-}"
export GITHUB_TOKEN="${GITHUB_TOKEN:-}"
export GH_ENTERPRISE_TOKEN="${GITHUB_TOKEN:-}"

REPO_NAME="${REPO_URL%.git}"
REPO_NAME="${REPO_NAME##*/}"
WORKDIR="/workspaces/${REPO_NAME}"

log "Repo URL: ${REPO_URL}"
log "Branch:   ${BRANCH}"
log "Workdir:  ${WORKDIR}"

########################################
# 2. Sanity check: coder binary & docker
########################################
if [ ! -x "${CODER_BIN}" ]; then
  log "ERROR: coder binary not found at ${CODER_BIN} (host image must bake it in)."
fi

if ! docker info >/dev/null 2>&1; then
  log "ERROR: Docker daemon not reachable; will NOT be able to build/run devcontainer."
  log "Will attempt to run coder agent in host container only."
  DEV_IMAGE_TAG=""
else
  DEV_IMAGE_TAG="devcontainer-${REPO_NAME}:latest"
fi

########################################
# 3. Configure git identity
########################################
git config --global user.name  "$GIT_NAME"
git config --global user.email "$GIT_EMAIL"

########################################
# 4. Clone or update the repo into /workspaces/<repo>
########################################
mkdir -p "/workspaces"

if [ ! -d "${WORKDIR}/.git" ]; then
  log "No existing repo, cloning fresh..."
  git clone --branch "${BRANCH}" "${REPO_URL}" "${WORKDIR}"
else
  log "Existing repo found, updating branch ${BRANCH}..."
  git -C "${WORKDIR}" fetch origin
  git -C "${WORKDIR}" checkout "${BRANCH}"
  git -C "${WORKDIR}" reset --hard "origin/${BRANCH}"
fi

cd "${WORKDIR}"

log "Current HEAD: $(git rev-parse --short HEAD || echo 'unknown')"

########################################
# 5. Decide devcontainer image (repo or universal)
########################################
DEVCONTAINER_DIR=".devcontainer"
DEVCONTAINER_DOCKERFILE="${DEVCONTAINER_DIR}/Dockerfile"
DEVCONTAINER_JSON="${DEVCONTAINER_DIR}/devcontainer.json"

BASE_DEFAULT_IMAGE="mcr.microsoft.com/devcontainers/universal:2"

has_devcontainer=false
[ -f "${DEVCONTAINER_DOCKERFILE}" ] && has_devcontainer=true
[ -f "${DEVCONTAINER_JSON}" ] && has_devcontainer=true

if [ -z "${DEV_IMAGE_TAG:-}" ]; then
  log "Skipping devcontainer image selection because Docker is unavailable."
else
  if $has_devcontainer; then
    if [ -f "${DEVCONTAINER_DOCKERFILE}" ]; then
      log "Devcontainer Dockerfile detected at ${DEVCONTAINER_DOCKERFILE}, building image '${DEV_IMAGE_TAG}'..."
      if ! docker build -f "${DEVCONTAINER_DOCKERFILE}" -t "${DEV_IMAGE_TAG}" .; then
        log "WARNING: docker build failed. Falling back to default universal image."
        DEV_IMAGE_TAG="${BASE_DEFAULT_IMAGE}"
      fi
    else
      log "devcontainer.json present but no Dockerfile. Using default universal image for now."
      DEV_IMAGE_TAG="${BASE_DEFAULT_IMAGE}"
    fi
  else
    log "No devcontainer config found. Using default universal image: ${BASE_DEFAULT_IMAGE}"
    DEV_IMAGE_TAG="${BASE_DEFAULT_IMAGE}"
  fi
fi

########################################
# 6. Start devcontainer container (if image chosen)
########################################
DEV_CONTAINER_NAME="dev-${REPO_NAME}"

if [ -n "${DEV_IMAGE_TAG:-}" ]; then
  # Remove any old container with same name
  if docker ps -a --format '{{.Names}}' | grep -q "^${DEV_CONTAINER_NAME}\$"; then
    log "Removing existing devcontainer '${DEV_CONTAINER_NAME}'..."
    docker rm -f "${DEV_CONTAINER_NAME}" >/dev/null 2>&1 || \
      log "WARNING: Failed to remove existing devcontainer; continuing."
  fi

  log "Starting devcontainer '${DEV_CONTAINER_NAME}' from image '${DEV_IMAGE_TAG}'..."

  # Note:
  # - host network so ports (e.g. 13337 for code-server) line up with Coder apps
  # - /workspaces/<repo> mounted
  # - /run/config mounted read-only for tokens/config
  if ! docker run -d \
      --name "${DEV_CONTAINER_NAME}" \
      --network host \
      -v "/workspaces/${REPO_NAME}:/workspaces/${REPO_NAME}" \
      -v "/run/config:/run/config:ro" \
      -w "/workspaces/${REPO_NAME}" \
      -e GITHUB_TOKEN="${GITHUB_TOKEN:-}" \
      -e GH_ENTERPRISE_TOKEN="${GITHUB_TOKEN:-}" \
      "${DEV_IMAGE_TAG}" \
      sleep infinity >/dev/null; then
    log "WARNING: Failed to start devcontainer; will fall back to running coder agent in host container."
    DEV_IMAGE_TAG=""
  else
    log "Devcontainer '${DEV_CONTAINER_NAME}' is running."
  fi
fi

########################################
# 7. Start coder agent (prefer devcontainer)
########################################
if [ -n "${DEV_IMAGE_TAG:-}" ]; then
  # v2: agent lives inside devcontainer
  log "Preparing coder agent inside devcontainer '${DEV_CONTAINER_NAME}'..."

  if [ ! -x "${CODER_BIN}" ]; then
    log "ERROR: coder binary missing on host; cannot copy into devcontainer."
  else
    log "Copying coder binary into devcontainer..."
    docker cp "${CODER_BIN}" "${DEV_CONTAINER_NAME}:/usr/local/bin/coder" || \
      log "WARNING: docker cp of coder into devcontainer failed."
  fi

  log "Starting coder agent inside devcontainer..."
  docker exec -d "${DEV_CONTAINER_NAME}" sh -lc '
    set -e
    if [ ! -x /usr/local/bin/coder ]; then
      echo "[devcontainer] ERROR: /usr/local/bin/coder is missing or not executable." >&2
      exit 1
    fi

    CODER_AGENT_TOKEN="$(cat /run/config/coder-token 2>/dev/null || echo "")"
    if [ -z "$CODER_AGENT_TOKEN" ]; then
      echo "[devcontainer] ERROR: CODER_AGENT_TOKEN missing; cannot start agent." >&2
      exit 1
    fi

    CODER_AGENT_URL="$(cat /run/config/coder-url 2>/dev/null || echo "")"
    if [ -z "$CODER_AGENT_URL" ]; then
      echo "[devcontainer] ERROR: CODER_AGENT_URL missing; cannot start agent." >&2
      exit 1
    fi

    export CODER_AGENT_TOKEN
    export CODER_AGENT_URL
    # Optional: propagate GH vars into agent env too
    export GITHUB_TOKEN="$(cat /run/config/github-token 2>/dev/null || echo "")"
    export GH_ENTERPRISE_TOKEN="$GITHUB_TOKEN"

    echo "[devcontainer] Starting coder agent..."
    exec coder agent
  '

  log "Coder agent launch requested inside devcontainer. Control plane will attach when it connects."
else
  # Fallback: run agent in host container
  log "No devcontainer running; starting coder agent in host container."

  if [ -z "${CODER_AGENT_TOKEN:-}" ]; then
    log "ERROR: CODER_AGENT_TOKEN missing; cannot start agent in host."
  elif [ ! -x "${CODER_BIN}" ]; then
    log "ERROR: coder binary missing; cannot start agent in host."
  else
    log "Starting coder agent in host container..."
    "${CODER_BIN}" agent &
  fi
fi

########################################
# 8. Keep host container alive
########################################
log "Host init complete. Keeping host container running."
tail -f /dev/null
