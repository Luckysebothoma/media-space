#!/usr/bin/env bash
#set -euo pipefail

set +u 
# ==========================
# CONFIGURATION
# ==========================
REGISTRY="192.168.0.140:5000"
IMAGE_NAME="media-composer"
VERSION_PREFIX="0.0"

DOCKERFILE_DEV="Dockerfile"
DOCKERFILE_PRD="Dockerfile"
DOCKERFILE="Dockerfile"
# ==========================
# FUNCTIONS
# ==========================
log() {
  echo -e "\n🔹 $1"
}

error() {
  echo -e "\n❌ $1"
  exit 1
}

get_latest_version() {
  docker images --format "{{.Tag}}" "${REGISTRY}/${IMAGE_NAME}" \
    | grep "^${VERSION_PREFIX}\." \
    | sort -V \
    | tail -n 1
}

increment_version() {
  local last="$1"
  if [[ -z "$last" ]]; then
    echo "${VERSION_PREFIX}.1"
  else
    local patch
    patch=$(echo "$last" | awk -F. '{print $3}')
    echo "${VERSION_PREFIX}.$((patch + 1))"
  fi
}

# ==========================
# ENV SELECTION
# ==========================

log "Selected environment: $ENV"
log "Using Dockerfile: $DOCKERFILE"

# ==========================
# VERSIONING
# ==========================
LAST_VERSION=$(get_latest_version || true)
NEW_VERSION=$(increment_version "$LAST_VERSION")

FULL_IMAGE="${REGISTRY}/${IMAGE_NAME}:${NEW_VERSION}"
LATEST_IMAGE="${REGISTRY}/${IMAGE_NAME}:latest"

log "Last version : ${LAST_VERSION:-none}"
log "New version  : $NEW_VERSION"

# ==========================
# BUILD
# ==========================
log "Building image..."
docker build \
  -f "$DOCKERFILE" \
  -t "$FULL_IMAGE" \
  -t "$LATEST_IMAGE" \
  . --no-cache

# ==========================
# PUSH
# ==========================
log "Pushing image tags..."
docker push "$FULL_IMAGE"
docker push "$LATEST_IMAGE"

log "✅ Build & push complete"
echo "📦 Image pushed:"
echo "   - $FULL_IMAGE"
echo "   - $LATEST_IMAGE"
