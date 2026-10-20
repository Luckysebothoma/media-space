REGISTRY="${REGISTRY:-192.168.0.140:5000}"
IMAGE_NAME="media-organizer"
IMAGE_TAG="latest"
FULL_IMAGE="${REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG}"
PROJECT_DIR="."
SERVICE_NAME="media_organizer"
SKIP_SWARM=false
STACK_NAME="mediastack"

# ============================================================================
# SECTION 20 — DOCKER BUILD + PUSH TO LOCAL REGISTRY
# ============================================================================
#section "20. DOCKER BUILD & PUSH TO ${REGISTRY}"

echo "Building Docker image: ${FULL_IMAGE}"
docker build --no-cache -t "${FULL_IMAGE}" "${PROJECT_DIR}"

echo "Pushing image to local registry ${REGISTRY}..."
if docker push "${FULL_IMAGE}"; then
  echo "Image pushed successfully: ${FULL_IMAGE}"
else
  echo "Push failed — registry at ${REGISTRY} may not be reachable. Image built locally as ${FULL_IMAGE}"
  echo "To push manually: docker push ${FULL_IMAGE}"
  echo "Ensure insecure-registries includes ${REGISTRY} in /etc/docker/daemon.json"
fi
