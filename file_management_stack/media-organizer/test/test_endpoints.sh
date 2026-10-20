#!/bin/bash
################################################################################
# MEDIA ORGANIZER — Endpoint Test Suite
# Usage: bash test/test_endpoints.sh [BASE_URL] [--with-files]
################################################################################

BASE_URL="${1:-http://192.168.0.140:3000}"
WITH_FILES="${2:-}"
PASS=0
FAIL=0
TEST_INPUT_DIR="/tmp/media_test_input_$$"
TEST_OUTPUT_DIR="/tmp/media_test_output_$$"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()  { echo -e "${CYAN}[TEST]${NC} $*"; }
pass() { echo -e "${GREEN}[PASS]${NC} $*"; ((PASS++)); }
fail() { echo -e "${RED}[FAIL]${NC} $*"; ((FAIL++)); }
info() { echo -e "${YELLOW}[INFO]${NC} $*"; }

assert_status() {
  local label="$1"
  local expected="$2"
  local actual="$3"
  if [[ "$actual" == "$expected" ]]; then
    pass "$label — HTTP $actual"
  else
    fail "$label — expected HTTP $expected, got HTTP $actual"
  fi
}

assert_json_key() {
  local label="$1"
  local key="$2"
  local body="$3"
  if echo "$body" | grep -q "\"$key\""; then
    pass "$label — key '$key' present"
  else
    fail "$label — key '$key' missing in response"
  fi
}

# ── Create test media files ──────────────────────────────────────────────────
setup_test_files() {
  info "Creating test media files in $TEST_INPUT_DIR"
  mkdir -p "$TEST_INPUT_DIR"
  mkdir -p "$TEST_OUTPUT_DIR"

  # Create dummy files with timestamp-based names
  local dates=("20260101" "20260101" "20260115" "20260201" "20260310")
  local times=("083000" "083001" "143000" "090000" "120000")
  local types=("jpg" "mp4" "jpg" "mp4" "jpg")

  for i in "${!dates[@]}"; do
    fname="${dates[$i]}_${times[$i]}.${types[$i]}"
    dd if=/dev/urandom of="${TEST_INPUT_DIR}/${fname}" bs=1024 count=$((RANDOM % 100 + 10)) 2>/dev/null
    info "  created: $fname"
  done

  # Create a duplicate
  cp "${TEST_INPUT_DIR}/20260101_083000.jpg" "${TEST_INPUT_DIR}/20260101_083000_dup.jpg"
  info "  created duplicate: 20260101_083000_dup.jpg"
}

cleanup_test_files() {
  rm -rf "$TEST_INPUT_DIR" "$TEST_OUTPUT_DIR"
  info "Cleaned up test directories"
}

# ── Wait for server ──────────────────────────────────────────────────────────
wait_for_server() {
  info "Waiting for server at $BASE_URL ..."
  for i in {1..20}; do
    if curl -sf "$BASE_URL/" &>/dev/null; then
      info "Server is up"
      return 0
    fi
    sleep 1
  done
  fail "Server did not start within 20s"
  exit 1
}

# ── Tests ────────────────────────────────────────────────────────────────────

test_health() {
  log "Health check"
  resp=$(curl -sf -w "\n%{http_code}" "$BASE_URL/")
  http_code=$(echo "$resp" | tail -1)
  body=$(echo "$resp" | head -1)
  assert_status "GET /" "200" "$http_code"
  assert_json_key "GET / body" "status" "$body"
}

test_help() {
  log "Help endpoint"
  resp=$(curl -sf -w "\n%{http_code}" "$BASE_URL/help")
  http_code=$(echo "$resp" | tail -1)
  body=$(echo "$resp" | head -1)
  assert_status "GET /help" "200" "$http_code"
  assert_json_key "GET /help body" "endpoints" "$body"
}

test_calendar() {
  log "Calendar endpoint"
  resp=$(curl -sf -w "\n%{http_code}" "$BASE_URL/calendar")
  http_code=$(echo "$resp" | tail -1)
  body=$(echo "$resp" | head -1)
  assert_status "GET /calendar" "200" "$http_code"
  assert_json_key "GET /calendar" "weekKey" "$body"
  assert_json_key "GET /calendar" "monthKey" "$body"
}

test_logs_recent() {
  log "Logs recent endpoint"
  resp=$(curl -sf -w "\n%{http_code}" "$BASE_URL/logs/recent?lines=10")
  http_code=$(echo "$resp" | tail -1)
  assert_status "GET /logs/recent" "200" "$http_code"
}

test_logs_errors() {
  log "Logs error endpoint"
  resp=$(curl -sf -w "\n%{http_code}" "$BASE_URL/logs/errors?lines=10")
  http_code=$(echo "$resp" | tail -1)
  assert_status "GET /logs/errors" "200" "$http_code"
}

test_404() {
  log "404 handler"
  http_code=$(curl -sf -o /dev/null -w "%{http_code}" "$BASE_URL/nonexistent-route" 2>/dev/null || echo "404")
  assert_status "GET /nonexistent" "404" "$http_code"
}

test_validation_missing_fields() {
  log "Validation — missing required fields"
  resp=$(curl -sf -o /dev/null -w "%{http_code}" -X POST "$BASE_URL/organize/filename" \
    -H "Content-Type: application/json" \
    -d '{"mediaType":"both"}')
  assert_status "POST /organize/filename (missing dirs)" "422" "$resp"
}

test_validation_bad_media_type() {
  log "Validation — invalid mediaType"
  resp=$(curl -sf -o /dev/null -w "%{http_code}" -X POST "$BASE_URL/organize/filename" \
    -H "Content-Type: application/json" \
    -d "{\"sourceDir\":\"/tmp\",\"outputDir\":\"/tmp/out\",\"mediaType\":\"audio\"}")
  assert_status "POST /organize/filename (bad mediaType)" "422" "$resp"
}

test_validation_bad_granularity() {
  log "Validation — invalid granularity"
  resp=$(curl -sf -o /dev/null -w "%{http_code}" -X POST "$BASE_URL/organize/date" \
    -H "Content-Type: application/json" \
    -d "{\"sourceDir\":\"/tmp\",\"outputDir\":\"/tmp/out\",\"mediaType\":\"both\",\"granularity\":\"year\"}")
  assert_status "POST /organize/date (bad granularity)" "422" "$resp"
}

test_scan_dryrun() {
  log "Scan endpoint (dry-run, no files required)"
  resp=$(curl -sf -w "\n%{http_code}" -X POST "$BASE_URL/organize/scan" \
    -H "Content-Type: application/json" \
    -d "{\"sourceDir\":\"/tmp\",\"mediaType\":\"both\"}")
  http_code=$(echo "$resp" | tail -1)
  body=$(echo "$resp" | head -1)
  assert_status "POST /organize/scan" "200" "$http_code"
  assert_json_key "POST /organize/scan body" "operation" "$body"
}

test_with_real_files() {
  log "=== File movement tests (requires test files) ==="
  setup_test_files

  # Test: scan
  log "Scan with real files"
  resp=$(curl -sf -w "\n%{http_code}" -X POST "$BASE_URL/organize/scan" \
    -H "Content-Type: application/json" \
    -d "{\"sourceDir\":\"$TEST_INPUT_DIR\",\"mediaType\":\"both\"}")
  http_code=$(echo "$resp" | tail -1)
  body=$(echo "$resp" | head -1)
  assert_status "POST /organize/scan (real files)" "200" "$http_code"
  assert_json_key "scan response" "totalFiles" "$body"
  info "Scan result: $(echo $body | python3 -c 'import json,sys; d=json.load(sys.stdin); print(f"totalFiles={d[\"totalFiles\"]}, totalBytesHuman={d[\"totalBytesHuman\"]}")' 2>/dev/null || echo $body)"

  # Test: groupByFilename dry-run
  log "groupByFilename dry-run"
  resp=$(curl -sf -w "\n%{http_code}" -X POST "$BASE_URL/organize/filename" \
    -H "Content-Type: application/json" \
    -d "{\"sourceDir\":\"$TEST_INPUT_DIR\",\"outputDir\":\"$TEST_OUTPUT_DIR/filename\",\"mediaType\":\"both\",\"dryRun\":true}")
  http_code=$(echo "$resp" | tail -1)
  body=$(echo "$resp" | head -1)
  assert_status "POST /organize/filename (dry-run)" "200" "$http_code"
  assert_json_key "groupByFilename dry-run" "groups" "$body"

  # Verify no files were moved in dry-run
  moved_count=$(ls "$TEST_INPUT_DIR" 2>/dev/null | wc -l)
  if [[ "$moved_count" -ge 5 ]]; then
    pass "dry-run — source files untouched ($moved_count files remain)"
  else
    fail "dry-run — source files appear to have been moved"
  fi

  # Test: groupByDate by day (real move)
  log "groupByDate by day (real move)"
  resp=$(curl -sf -w "\n%{http_code}" -X POST "$BASE_URL/organize/date" \
    -H "Content-Type: application/json" \
    -d "{\"sourceDir\":\"$TEST_INPUT_DIR\",\"outputDir\":\"$TEST_OUTPUT_DIR/by-day\",\"mediaType\":\"both\",\"granularity\":\"day\",\"dryRun\":false}")
  http_code=$(echo "$resp" | tail -1)
  body=$(echo "$resp" | head -1)
  assert_status "POST /organize/date day (real)" "200" "$http_code"

  # Verify files were moved
  if ls "$TEST_OUTPUT_DIR/by-day" 2>/dev/null | grep -q "__"; then
    pass "groupByDate — output directories created with expected naming"
  else
    fail "groupByDate — no output directories found"
  fi

  # Verify duplicate detection
  dup_found=$(echo "$body" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(len(d.get("duplicates",[])))' 2>/dev/null || echo "0")
  if [[ "$dup_found" -ge 1 ]]; then
    pass "duplicate detection — found $dup_found duplicate(s)"
  else
    fail "duplicate detection — expected at least 1 duplicate"
  fi

  # Test: images only
  setup_test_files
  log "images-only filter"
  resp=$(curl -sf -w "\n%{http_code}" -X POST "$BASE_URL/organize/scan" \
    -H "Content-Type: application/json" \
    -d "{\"sourceDir\":\"$TEST_INPUT_DIR\",\"mediaType\":\"image\"}")
  http_code=$(echo "$resp" | tail -1)
  body=$(echo "$resp" | head -1)
  image_count=$(echo "$body" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("totalFiles",0))' 2>/dev/null || echo "?")
  assert_status "POST /organize/scan (images only)" "200" "$http_code"
  info "images-only count: $image_count"

  # Test: videos only
  resp=$(curl -sf -w "\n%{http_code}" -X POST "$BASE_URL/organize/scan" \
    -H "Content-Type: application/json" \
    -d "{\"sourceDir\":\"$TEST_INPUT_DIR\",\"mediaType\":\"video\"}")
  http_code=$(echo "$resp" | tail -1)
  body=$(echo "$resp" | head -1)
  video_count=$(echo "$body" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("totalFiles",0))' 2>/dev/null || echo "?")
  assert_status "POST /organize/scan (videos only)" "200" "$http_code"
  info "videos-only count: $video_count"

  # Test: separate
  log "separateByType"
  resp=$(curl -sf -w "\n%{http_code}" -X POST "$BASE_URL/organize/separate" \
    -H "Content-Type: application/json" \
    -d "{\"sourceDir\":\"$TEST_INPUT_DIR\",\"outputDir\":\"$TEST_OUTPUT_DIR/separate\",\"dryRun\":true}")
  http_code=$(echo "$resp" | tail -1)
  assert_status "POST /organize/separate" "200" "$http_code"

  # Test: deduplicate
  log "deduplicateOnly"
  resp=$(curl -sf -w "\n%{http_code}" -X POST "$BASE_URL/organize/deduplicate" \
    -H "Content-Type: application/json" \
    -d "{\"sourceDir\":\"$TEST_INPUT_DIR\",\"outputDir\":\"$TEST_OUTPUT_DIR/dedup\",\"mediaType\":\"both\",\"dryRun\":true}")
  http_code=$(echo "$resp" | tail -1)
  assert_status "POST /organize/deduplicate" "200" "$http_code"

  # Test: week grouping
  setup_test_files
  log "groupByDate by week"
  resp=$(curl -sf -w "\n%{http_code}" -X POST "$BASE_URL/organize/date" \
    -H "Content-Type: application/json" \
    -d "{\"sourceDir\":\"$TEST_INPUT_DIR\",\"outputDir\":\"$TEST_OUTPUT_DIR/by-week\",\"mediaType\":\"both\",\"granularity\":\"week\",\"dryRun\":true}")
  http_code=$(echo "$resp" | tail -1)
  assert_status "POST /organize/date week" "200" "$http_code"

  # Test: month grouping
  setup_test_files
  log "groupByDate by month"
  resp=$(curl -sf -w "\n%{http_code}" -X POST "$BASE_URL/organize/date" \
    -H "Content-Type: application/json" \
    -d "{\"sourceDir\":\"$TEST_INPUT_DIR\",\"outputDir\":\"$TEST_OUTPUT_DIR/by-month\",\"mediaType\":\"both\",\"granularity\":\"month\",\"dryRun\":true}")
  http_code=$(echo "$resp" | tail -1)
  assert_status "POST /organize/date month" "200" "$http_code"

  cleanup_test_files
}

# ── Run all tests ────────────────────────────────────────────────────────────

echo
echo "================================================================================"
echo " MEDIA ORGANIZER — Test Suite"
echo " Target: $BASE_URL"
echo "================================================================================"
echo

wait_for_server

test_health
test_help
test_calendar
test_logs_recent
test_logs_errors
test_404
test_validation_missing_fields
test_validation_bad_media_type
test_validation_bad_granularity
test_scan_dryrun

if [[ "$WITH_FILES" == "--with-files" ]]; then
  test_with_real_files
else
  info "Skipping file-movement tests (pass --with-files to enable)"
fi

echo
echo "================================================================================"
echo -e " Results: ${GREEN}${PASS} passed${NC} | ${RED}${FAIL} failed${NC}"
echo "================================================================================"
echo

exit $FAIL
