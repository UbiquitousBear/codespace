#!/bin/bash
set -euo pipefail

LINUXKIT_BIN="/Users/shamil/go/bin/linuxkit"
HOST_IMAGE="ghcr.io/ubiquitousbear/codespace:latest"
VM_IMAGE="ghcr.io/ubiquitousbear/codespaces-vm:latest"
CODESPACE_VERSION="$(date -u +%Y%m%d%H%M%SZ)"
BUILD_YAML="/tmp/codespace-vm.${CODESPACE_VERSION}.yaml"

trap 'rm -f "${BUILD_YAML}"' EXIT

# 1) Build and push codespace-host (amd64)
docker buildx build --platform linux/amd64 -t "${HOST_IMAGE}" \
  --build-arg CODESPACE_HOST_VERSION="${CODESPACE_VERSION}" \
  --push .

# Resolve the pushed host image digest so LinuxKit uses the exact image
HOST_DIGEST="$(docker buildx imagetools inspect "${HOST_IMAGE}" | sed -n 's/^Digest:[[:space:]]*//p' | head -n 1)"
if [[ -z "${HOST_DIGEST}" ]]; then
  echo "ERROR: unable to resolve image digest for ${HOST_IMAGE}" >&2
  exit 1
fi
HOST_IMAGE_REF="${HOST_IMAGE}@${HOST_DIGEST}"

sed \
  -e "s|__CODESPACE_VERSION__|${CODESPACE_VERSION}|g" \
  -e "s|__CODESPACE_HOST_IMAGE__|${HOST_IMAGE_REF}|g" \
  codespace-vm.yaml > "${BUILD_YAML}"

# 2) Build LinuxKit kernel+initrd (amd64)
rm -f codespace-vm-kernel codespace-vm-initrd.img codespace-vm-cmdline
"${LINUXKIT_BIN}" build --arch amd64 --pull --format kernel+initrd --name codespace-vm "${BUILD_YAML}"

# 3) Build and push VM image with kernel/initrd (amd64)
docker buildx build --platform linux/amd64 -t "${VM_IMAGE}" -f ./Containerfile . --push
