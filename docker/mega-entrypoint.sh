#!/usr/bin/env bash
set -Eeuo pipefail
log(){ printf '[%(%F %T)T] %s\n' -1 "$*"; }
# Swarm secrets -> env (never baked into the image)
for n in hms ffmpeg media; do
  [[ -r /run/secrets/${n}_pass ]] && export "${n^^}_DB_PASSWORD=$(cat /run/secrets/${n}_pass)"
done
H="${DB_HOST:-postgres}"
export HMS_DATABASE_URL="postgres://hms:${HMS_DB_PASSWORD:-}@${H}:5432/hms"
export FFMPEG_DATABASE_URL="postgres://ffmpeg:${FFMPEG_DB_PASSWORD:-}@${H}:5432/ffmpeg"
export MEDIA_DATABASE_URL="postgres://media:${MEDIA_DB_PASSWORD:-}@${H}:5432/media"
export REDIS_URL="redis://${REDIS_HOST:-redis}:${REDIS_PORT:-6379}"
export PATH="/opt/tools:$PATH"

mkdir -p "$INPUT_DIR" "$PROCESSED_DIR/duplicates" "$TMP_DIR"
log "housekeeping: purging $TMP_DIR files older than ${TMP_RETENTION_DAYS:-7}d"
find "$TMP_DIR" -type f -mtime +"${TMP_RETENTION_DAYS:-7}" -delete 2>/dev/null || true
# App-level reconciliation (requeue PROCESSING jobs, orphan flagging) belongs in
# hooks: it must be heartbeat-aware or a restarting replica steals live jobs.
for h in /app/hooks/startup.d/*.sh; do [[ -x "$h" ]] && { log "hook $h"; "$h" || log "hook failed (continuing)"; }; done

log "waiting for postgres"
for i in $(seq 1 60); do pg_isready -q -h "$H" -U hms -d hms && break; sleep 2; done

pids=(); i=0
while IFS='|' read -r name dir cmd db; do
  [[ -z "${name:-}" || "$name" == \#* ]] && continue
  port=$(( ${APP_PORT:-3000} + i )); i=$((i+1))
  log "start $name on :$port ($dir: $cmd)"
  db="${db:-hms}"; up="${db^^}_DB_PASSWORD"; pw="${!up:-}"
  ( cd "/app/$dir" && exec env PORT="$port" \
      DB_HOST="$H" DB_PORT=5432 DB_NAME="$db" DB_USER="$db" DB_PASSWORD="$pw" DB_PASS="$pw" \
      POSTGRES_HOST="$H" POSTGRES_PORT=5432 POSTGRES_DB="$db" POSTGRES_USER="$db" POSTGRES_PASSWORD="$pw" \
      PGHOST="$H" PGPORT=5432 PGDATABASE="$db" PGUSER="$db" PGPASSWORD="$pw" \
      DATABASE_URL="postgres://$db:$pw@$H:5432/$db" \
      bash -c "$cmd" ) & pids+=($!)
done < /app/docker/mega-services.conf
if ((${#pids[@]}==0)); then log "no services in manifest; idling"; exec sleep infinity; fi
trap 'kill "${pids[@]}" 2>/dev/null || true' TERM INT
wait -n || true
log "a service exited; stopping container so Swarm restarts it"
kill "${pids[@]}" 2>/dev/null || true; exit 1
