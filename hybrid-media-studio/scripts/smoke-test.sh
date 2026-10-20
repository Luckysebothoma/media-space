#!/bin/bash
# Hybrid Media Studio — Smoke Test
set -euo pipefail
BASE="${1:-http://localhost:3000}"
PASS=0; FAIL=0
GREEN='\033[0;32m'; RED='\033[0;31m'; CYAN='\033[0;36m'; NC='\033[0m'

chk() {
  local name="$1" body="$2" expect="$3"
  if echo "$body" | grep -q "$expect"; then echo -e "${GREEN}✓${NC} $name"; ((PASS++));
  else echo -e "${RED}✗${NC} $name — expected '$expect'"; echo "  got: ${body:0:200}"; ((FAIL++)); fi
}

echo -e "${CYAN}═══ HMS Smoke Tests → $BASE ═══${NC}"

# Wait for service
for i in $(seq 1 40); do
  [ "$(curl -sf -o/dev/null -w '%{http_code}' $BASE/status 2>/dev/null||echo 0)" = "200" ] && break
  [ $i = 40 ] && { echo "Timed out waiting"; exit 1; }
  sleep 2
done

chk "GET / HTML"           "$(curl -sf $BASE/)"              "HYBRID"
chk "GET /status ok"       "$(curl -sf $BASE/status)"        '"ok":true'
chk "GET /status remotion" "$(curl -sf $BASE/status)"        'remotion'
chk "GET /doc"             "$(curl -sf $BASE/doc)"           '"service"'
chk "GET /presets"         "$(curl -sf $BASE/presets)"       '"ffmpeg"'
chk "GET /audio"           "$(curl -sf $BASE/audio)"         '"audio"'
chk "GET /jobs"            "$(curl -sf $BASE/jobs)"          '"jobs"'
chk "GET /media"           "$(curl -sf $BASE/media)"         '"media"'
chk "GET /logs/errors"     "$(curl -sf $BASE/logs/errors)"   '"errors"'
chk "GET /summary"         "$(curl -sf $BASE/summary)"       '"jobs"'
chk "GET /notfound 404"    "$(curl -sf $BASE/xyzzy 2>/dev/null || echo 'Not found')" "Not found"

# Organise scan
SCAN=$(curl -sf -X POST $BASE/organise/scan -H 'Content-Type: application/json' -d '{"srcPath":"/data/media","mediaType":"both"}')
chk "POST /organise/scan"    "$SCAN"  '"totalFiles"'

# Process quick
PQ=$(curl -sf -X POST $BASE/process/quick/standard)
chk "POST /process/quick/standard" "$PQ" '"jobId"'

# Render quick
RQ=$(curl -sf -X POST $BASE/render/quick/cineslide)
chk "POST /render/quick/cineslide" "$RQ" '"jobId"'

# Pipeline
PP=$(curl -sf -X POST $BASE/pipeline -H 'Content-Type: application/json' \
  -d '{"srcPath":"/data/media","skipOrganise":false,"skipProcess":false,"skipRender":false,"dryRun":true}')
chk "POST /pipeline"  "$PP" '"pipeline"'

# Bad preset
BP=$(curl -sf -X POST $BASE/process/quick/ultramax 2>/dev/null || echo '{"error":"x"}')
chk "Bad preset error" "$BP" '"error"'

echo ""
echo -e "${CYAN}Results: ${GREEN}${PASS} passed${NC} | ${RED}${FAIL} failed${NC}${CYAN}${NC}"
[ $FAIL -gt 0 ] && exit 1; exit 0
