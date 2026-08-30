#!/bin/bash
# Build FluffyChat Linux AppImage inside a Holy Build Box (Enterprise Linux 8,
# glibc 2.28) container for maximum cross-distro compatibility.
# Usage: ./scripts/build-linux-appimage.sh
# Set CONTAINER_ENGINE=podman or CONTAINER_ENGINE=docker to force an engine.
set -e

# Auto-detect container engine. Docker-compatible Podman wrappers are detected
# as podman so we can run as container root (mapped to the host user in rootless mode).
if [ -z "${CONTAINER_ENGINE:-}" ]; then
    if command -v docker >/dev/null 2>&1 && docker --version 2>/dev/null | grep -q "Docker"; then
        CONTAINER_ENGINE="docker"
    elif command -v podman >/dev/null 2>&1; then
        CONTAINER_ENGINE="podman"
    else
        echo "Error: no container engine found (docker or podman)." >&2
        exit 1
    fi
fi

IMAGE_TAG="fluffychat-appimage-build:latest"
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# NOTE: must live outside build/ because the entrypoint runs `flutter clean`,
# which deletes the whole build/ directory (including this bind mount's
# mountpoint on the host) before building.
OUTPUT_DIR="${PROJECT_ROOT}/dist/appimage"

# Default Flutter version is read from .tool_versions.yaml; allow override
# via the FLUTTER_VERSION environment variable for CI or local testing.
FLUTTER_VERSION="${FLUTTER_VERSION:-$(yq '.environment.flutter' < "${PROJECT_ROOT}/.tool_versions.yaml" 2>/dev/null || true)}"
if [ -z "$FLUTTER_VERSION" ]; then
    FLUTTER_VERSION="3.47.1"
fi

mkdir -p "$OUTPUT_DIR"

# Caching: in CI we can use Docker Buildx with GitHub Actions cache. Locally
# the container engine's normal layer cache is used.
APPIMAGE_BUILD_CACHE="${APPIMAGE_BUILD_CACHE:-}"

if [ "$APPIMAGE_BUILD_CACHE" = "gha" ] && [ "$CONTAINER_ENGINE" = "docker" ]; then
    echo "=== Building container image with Docker Buildx + GHA cache (Flutter $FLUTTER_VERSION) ==="
    docker buildx build \
      --build-arg FLUTTER_VERSION="$FLUTTER_VERSION" \
      -t "$IMAGE_TAG" \
      -f "${PROJECT_ROOT}/scripts/linux-appimage/Dockerfile" \
      --cache-from type=gha \
      --cache-to type=gha,mode=max \
      --load \
      "${PROJECT_ROOT}/scripts/linux-appimage"
else
    echo "=== Building container image with $CONTAINER_ENGINE (Flutter $FLUTTER_VERSION) ==="
    $CONTAINER_ENGINE build \
      --build-arg FLUTTER_VERSION="$FLUTTER_VERSION" \
      -t "$IMAGE_TAG" \
      -f "${PROJECT_ROOT}/scripts/linux-appimage/Dockerfile" \
      "${PROJECT_ROOT}/scripts/linux-appimage"
fi

# Docker runs as real root, so map to the host UID to avoid root-owned output files.
# Rootless Podman maps container root to the host user, so running as container root
# gives the correct file ownership without needing --userns=keep-id.
if [ "$CONTAINER_ENGINE" = "podman" ]; then
    USER_FLAGS=""
else
    USER_FLAGS="--user $(id -u):$(id -g)"
fi

echo "=== Building AppImage ==="
$CONTAINER_ENGINE run --rm \
  $USER_FLAGS \
  -v "${PROJECT_ROOT}:/build:Z" \
  -v "${OUTPUT_DIR}:/output:Z" \
  "$IMAGE_TAG" \
  /build/scripts/linux-appimage/entrypoint.sh

echo "=== AppImage ready: ${OUTPUT_DIR}/FluffyChat-x86_64.AppImage ==="
