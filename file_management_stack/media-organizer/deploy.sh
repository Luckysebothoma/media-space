REGISTRY="${REGISTRY:-192.168.0.140:5000}"
IMAGE_NAME="media-organizer"
IMAGE_TAG="latest"
FULL_IMAGE="${REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG}"
PROJECT_DIR="."
SERVICE_NAME="media_organizer"
SKIP_SWARM=false
STACK_NAME="yt-stack"

mkdir -p /mnt/blue_488gb/_ALL_BACKUP_2026/older_moved_11_Apr_26/media-organizer/dump

# ============================================================================
# SECTION 21 — DOCKER SWARM INIT + DEPLOY
# ============================================================================

if [[ "$SKIP_SWARM" == false ]]; then
  echo "21. DOCKER SWARM INIT & DEPLOY"

  # Init swarm if not already active
  if ! docker info 2>/dev/null | grep -q "Swarm: active"; then
    echo "Initializing Docker Swarm..."
    docker swarm init || log "WARN" "Swarm init failed — may already be in a swarm, continuing..."
  else
    echo "Docker Swarm already active"
  fi

  echo "Deploying stack '${STACK_NAME}'..."
  docker stack deploy -c "${PROJECT_DIR}/docker-compose.yml" "${STACK_NAME}" --with-registry-auth

  echo "Waiting for service to start..."
  sleep 8

  echo "Stack services:"
  docker stack services "${STACK_NAME}" 2>/dev/null || true
else
  echo "21. SKIPPING SWARM (--skip-swarm)"
fi
sleep 5

STACK=&{STACK_NAME}

echo "────────────────────────────────────"
echo "🩺 HEALTH CHECK: $STACK"
echo "────────────────────────────────────"

echo ""
echo "📦 SERVICE LIST"
docker service ls | grep "$STACK"

echo ""
echo "────────────────────────────────────"
echo "🔎 TASK DETAILS (NO-TRUNC)"
echo "────────────────────────────────────"

for svc in $(docker service ls --format "{{.Name}}" | grep "$STACK"); do
  echo ""
  echo "➡ $svc"
  docker service ps "$svc" --no-trunc
done

echo ""
echo "────────────────────────────────────"
echo "📜 LOGS (LAST 50 LINES)"
echo "────────────────────────────────────"

for svc in $(docker service ls --format "{{.Name}}" | grep "$STACK"); do
  echo ""
  echo "📌 $svc logs"
  docker service logs "$svc" --tail 10 || true
done

echo ""
echo "🌐 API CHECK"
curl -sf http://192.168.0.140:3000/ || echo "❌ API DOWN"

echo ""
echo "✔ Done"
