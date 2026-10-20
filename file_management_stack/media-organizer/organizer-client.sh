#!/usr/bin/env bash

# ==============================
# CONFIG
# ==============================
HOST="http://192.168.0.140:3000/v1"
SOURCE_DIR="/media/input"
OUTPUT_DIR="/media/processed"
MEDIA_TYPE="both"

# Timeouts (seconds)
TIMEOUT="${TIMEOUT:-300000}"
CONNECT_TIMEOUT="${CONNECT_TIMEOUT:-5}"

# Retry config
RETRIES="${RETRIES:-2}"
RETRY_DELAY="${RETRY_DELAY:-2}"

# Debug mode (set DEBUG=1)
DEBUG="${DEBUG:-0}"

# ==============================
# HELP
# ==============================
usage() {
  echo "Usage: $0 [command]"
  echo ""
  echo "Commands:"
  echo "  health        - Check API status"
  echo "  guide         - Fetch API guide"
  echo "  scan          - Scan directory (read-only)"
  echo "  date-dry      - Group by date (dry-run)"
  echo "  date-run      - Group by date (real run)"
  echo "  filename-dry  - Group by filename (dry-run)"
  echo "  filename-run  - Group by filename (real run)"
  echo "  separate      - Separate images/videos"
  echo "  dedup-dry     - Deduplicate (dry-run)"
  echo "  dedup-run     - Deduplicate (real run)"
  echo "  logs          - Fetch recent logs"
  exit 1
}

# ==============================
# CORE HTTP CLIENT (NO HANG)
# ==============================
call_api() {
  local METHOD=$1
  local URL=$2
  local DATA=$3

  echo "→ $METHOD $URL"

  local attempt=0
  local response
  local exit_code

  while [ $attempt -le $RETRIES ]; do
    [ "$DEBUG" -eq 1 ] && echo "  Attempt $((attempt+1))..."

    response=$(curl -sS \
      --max-time "$TIMEOUT" \
      --connect-timeout "$CONNECT_TIMEOUT" \
      --retry 0 \
      -X "$METHOD" "$URL" \
      -H "Content-Type: application/json" \
      -d "$DATA")

    exit_code=$?

    if [ $exit_code -eq 0 ]; then
      echo "$response" | jq . 2>/dev/null || echo "$response"
      echo ""
      return 0
    fi

    echo "⚠️  Request failed (exit $exit_code)"

    attempt=$((attempt+1))
    if [ $attempt -le $RETRIES ]; then
      echo "⏳ Retrying in ${RETRY_DELAY}s..."
      sleep "$RETRY_DELAY"
    fi
  done

  echo "❌ Request failed after $RETRIES retries"
  return 1
}

# ==============================
# SIMPLE GET WRAPPER
# ==============================
call_get() {
  call_api GET "$1" ""
}

# ==============================
# COMMAND HANDLER
# ==============================
CMD=$1

case "$CMD" in

  health)
    call_get "$HOST/"
    ;;

  guide)
    call_get "$HOST/guide"
    ;;

  scan)
    call_api POST "$HOST/organize/scan" \
      "{\"sourceDir\":\"$SOURCE_DIR\",\"mediaType\":\"$MEDIA_TYPE\"}"
    ;;

  date-dry)
    call_api POST "$HOST/organize/date" \
      "{\"sourceDir\":\"$SOURCE_DIR\",\"outputDir\":\"$OUTPUT_DIR\",\"mediaType\":\"$MEDIA_TYPE\",\"granularity\":\"day\",\"dryRun\":true}"
    ;;

  date-run)
    call_api POST "$HOST/organize/date" \
      "{\"sourceDir\":\"$SOURCE_DIR\",\"outputDir\":\"$OUTPUT_DIR\",\"mediaType\":\"$MEDIA_TYPE\",\"granularity\":\"day\",\"dryRun\":false}"
    ;;

  filename-dry)
    call_api POST "$HOST/organize/filename" \
      "{\"sourceDir\":\"$SOURCE_DIR\",\"outputDir\":\"$OUTPUT_DIR/by-filename\",\"mediaType\":\"$MEDIA_TYPE\",\"dryRun\":true}"
    ;;

  filename-run)
    call_api POST "$HOST/organize/filename" \
      "{\"sourceDir\":\"$SOURCE_DIR\",\"outputDir\":\"$OUTPUT_DIR/by-filename\",\"mediaType\":\"$MEDIA_TYPE\",\"dryRun\":false}"
    ;;

  separate)
    call_api POST "$HOST/organize/separate" \
      "{\"sourceDir\":\"$SOURCE_DIR\",\"outputDir\":\"$OUTPUT_DIR\",\"dryRun\":false}"
    ;;

  dedup-dry)
    call_api POST "$HOST/organize/deduplicate" \
      "{\"sourceDir\":\"$SOURCE_DIR\",\"outputDir\":\"$OUTPUT_DIR\",\"mediaType\":\"$MEDIA_TYPE\",\"dryRun\":true}"
    ;;

  dedup-run)
    call_api POST "$HOST/organize/deduplicate" \
      "{\"sourceDir\":\"$SOURCE_DIR\",\"outputDir\":\"$OUTPUT_DIR\",\"mediaType\":\"$MEDIA_TYPE\",\"dryRun\":false}"
    ;;

  logs)
    call_get "$HOST/logs/recent?lines=20"
    ;;

  *)
    usage
    ;;

esac