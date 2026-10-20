#!/bin/bash
# ============================================================
# smoke-test.sh — Validates FFmpeg Microservice v2 stack
# Usage: bash smoke-test.sh [http://localhost:3000]
# ============================================================
set -euo pipefail

BASE_URL="${1:-http://localhost:3000}"
PASS=0; FAIL=0

GREEN='\033[0;32m'; RED='\033[0;31m'; CYAN='\033[0;36m'; YELLOW='\033[1;33m'; NC='\033[0m'

check() {
  local name="$1" result="$2" expected="$3"
  if echo "$result" | grep -q "$expected"; then
    echo -e "${GREEN}✓ PASS${NC} $name"; ((PASS++))
  else
    echo -e "${RED}✗ FAIL${NC} $name"
    echo "  Expected to contain: $expected"
    echo "  Got: ${result:0:300}"; ((FAIL++))
  fi
}

check_http() {
  local name="$1" url="$2" expected_code="$3"
  local code
  code=$(curl -s -o /dev/null -w "%{http_code}" "$url" 2>/dev/null || echo "000")
  if [ "$code" = "$expected_code" ]; then
    echo -e "${GREEN}✓ PASS${NC} $name (HTTP $code)"; ((PASS++))
  else
    echo -e "${RED}✗ FAIL${NC} $name (expected HTTP $expected_code, got $code)"; ((FAIL++))
  fi
}

banner() { echo -e "\n${CYAN}--- $* ---${NC}"; }

echo -e "${CYAN}================================================"
echo "  FFmpeg Microservice v2 — Smoke Test Suite"
echo "  Target: $BASE_URL"
echo -e "================================================${NC}"

echo ""
echo "Waiting for service to be ready (up to 60s)..."
for i in $(seq 1 30); do
  CODE=$(curl -s -o /dev/null -w "%{http_code}" "$BASE_URL/status" 2>/dev/null || echo "000")
  if [ "$CODE" = "200" ]; then
    echo -e "${GREEN}✓ Service is up!${NC}"
    break
  fi
  [ "$i" = "30" ] && { echo -e "${RED}Timed out waiting for service.${NC}"; exit 1; }
  sleep 2
done

banner "Core Endpoints"
check     "GET / returns HTML"             "$(curl -s $BASE_URL/)"                             'FFmpeg'
check_http "GET / HTTP 200"               "$BASE_URL/"                                         "200"
check     "GET /status ok:true"           "$(curl -s $BASE_URL/status)"                        '"ok":true'
check     "GET /status db connected"      "$(curl -s $BASE_URL/status)"                        'connected'
check     "GET /status presetsAvailable"  "$(curl -s $BASE_URL/status)"                        'presetsAvailable'
check_http "GET /doc HTTP 200"            "$BASE_URL/doc"                                      "200"
check     "GET /presets has presets key"  "$(curl -s $BASE_URL/presets)"                       '"presets"'
check     "GET /presets has categories"   "$(curl -s $BASE_URL/presets)"                       '"categories"'
check     "GET /presets has mobile-hd"    "$(curl -s $BASE_URL/presets)"                       'mobile-hd'
check     "GET /presets has square-hd"    "$(curl -s $BASE_URL/presets)"                       'square-hd'
check     "GET /presets has ultrawide"    "$(curl -s $BASE_URL/presets)"                       'ultrawide'
check     "GET /jobs returns array"       "$(curl -s $BASE_URL/jobs)"                          '"jobs"'
check     "GET /logs returns array"       "$(curl -s $BASE_URL/logs)"                          '"logs"'
check     "GET /logs/error-global"        "$(curl -s $BASE_URL/logs/error-global)"             '"errors"'
check     "GET /media returns array"      "$(curl -s $BASE_URL/media)"                         '"media"'
check     "GET /notfound has hint"        "$(curl -s $BASE_URL/notfound-xyz)"                  'hint'

banner "Quick Fire — Desktop Presets"
check "POST /process/quick (default)"          "$(curl -s -X POST $BASE_URL/process/quick)"                        '"jobId"'
check "POST /process/quick/standard"           "$(curl -s -X POST $BASE_URL/process/quick/standard)"               '"jobId"'
check "POST /process/quick/high"               "$(curl -s -X POST $BASE_URL/process/quick/high)"                   '"jobId"'
check "POST /process/quick/4k"                 "$(curl -s -X POST $BASE_URL/process/quick/4k)"                     '"jobId"'
check "POST /process/quick/cinematic"          "$(curl -s -X POST $BASE_URL/process/quick/cinematic)"              '"jobId"'
check "POST /process/quick/ultrawide"          "$(curl -s -X POST $BASE_URL/process/quick/ultrawide)"              '"jobId"'
check "POST /process/quick/ultrawide-4k"       "$(curl -s -X POST $BASE_URL/process/quick/ultrawide-4k)"           '"jobId"'
check "POST /process/quick/classic-hd"         "$(curl -s -X POST $BASE_URL/process/quick/classic-hd)"             '"jobId"'
check "POST /process/quick/classic-sd"         "$(curl -s -X POST $BASE_URL/process/quick/classic-sd)"             '"jobId"'

banner "Quick Fire — Mobile Presets (9:16 portrait)"
check "POST /process/quick/mobile-hd"          "$(curl -s -X POST $BASE_URL/process/quick/mobile-hd)"              '"jobId"'
check "POST /process/quick/mobile-4k"          "$(curl -s -X POST $BASE_URL/process/quick/mobile-4k)"              '"jobId"'
check "POST /process/quick/mobile-sd"          "$(curl -s -X POST $BASE_URL/process/quick/mobile-sd)"              '"jobId"'
check "POST /process/quick/mobile-landscape"   "$(curl -s -X POST $BASE_URL/process/quick/mobile-landscape)"       '"jobId"'
check "POST /process/quick/mobile-landscape-hd" "$(curl -s -X POST $BASE_URL/process/quick/mobile-landscape-hd)"  '"jobId"'

banner "Quick Fire — Social / Square Presets"
check "POST /process/quick/square-hd"          "$(curl -s -X POST $BASE_URL/process/quick/square-hd)"              '"jobId"'
check "POST /process/quick/square-4k"          "$(curl -s -X POST $BASE_URL/process/quick/square-4k)"              '"jobId"'
check "POST /process/quick/portrait-social"    "$(curl -s -X POST $BASE_URL/process/quick/portrait-social)"        '"jobId"'

banner "Quick Fire — Aliases"
check "POST /process/quick/cinema (→cinematic)" "$(curl -s -X POST $BASE_URL/process/quick/cinema)"               '"jobId"'
check "POST /process/quick/reel (→mobile-hd)"   "$(curl -s -X POST $BASE_URL/process/quick/reel)"                 '"jobId"'
check "POST /process/quick/reels (→mobile-hd)"  "$(curl -s -X POST $BASE_URL/process/quick/reels)"                '"jobId"'
check "POST /process/quick/tiktok (→mobile-hd)" "$(curl -s -X POST $BASE_URL/process/quick/tiktok)"               '"jobId"'
check "POST /process/quick/shorts (→mobile-hd)" "$(curl -s -X POST $BASE_URL/process/quick/shorts)"               '"jobId"'
check "POST /process/quick/vertical"            "$(curl -s -X POST $BASE_URL/process/quick/vertical)"              '"jobId"'
check "POST /process/quick/portrait"            "$(curl -s -X POST $BASE_URL/process/quick/portrait)"              '"jobId"'
check "POST /process/quick/landscape"           "$(curl -s -X POST $BASE_URL/process/quick/landscape)"             '"jobId"'
check "POST /process/quick/square"              "$(curl -s -X POST $BASE_URL/process/quick/square)"                '"jobId"'
check "POST /process/quick/instagram"           "$(curl -s -X POST $BASE_URL/process/quick/instagram)"             '"jobId"'
check "POST /process/quick/feed"                "$(curl -s -X POST $BASE_URL/process/quick/feed)"                  '"jobId"'
check "POST /process/quick/1080p"               "$(curl -s -X POST $BASE_URL/process/quick/1080p)"                 '"jobId"'
check "POST /process/quick/9-16"                "$(curl -s -X POST $BASE_URL/process/quick/9-16)"                  '"jobId"'
check "POST /process/quick/16-9"                "$(curl -s -X POST $BASE_URL/process/quick/16-9)"                  '"jobId"'
check "POST /process/quick/4-3"                 "$(curl -s -X POST $BASE_URL/process/quick/4-3)"                   '"jobId"'

banner "Quick Fire — Error Cases"
check "POST /process/quick/bad_preset → error"  "$(curl -s -X POST $BASE_URL/process/quick/ultramax1234)"          '"error"'
check "POST /process/quick/UPPERCASE → error"   "$(curl -s -X POST $BASE_URL/process/quick/NOTAPRESET)"            '"error"'

# Grab a job ID for detail check
QUICK_RES=$(curl -s -X POST "$BASE_URL/process/quick/standard")
JOB_ID=$(echo "$QUICK_RES" | grep -o '"jobId":"[^"]*"' | cut -d'"' -f4 || true)
if [ -n "$JOB_ID" ]; then
  sleep 1
  DETAIL=$(curl -s "$BASE_URL/jobs/$JOB_ID")
  banner "Job Detail"
  check "GET /jobs/:id has job"    "$DETAIL" '"job"'
  check "GET /jobs/:id has events" "$DETAIL" '"events"'
  check "GET /jobs/:id has logs"   "$DETAIL" '"logs"'
  check "GET /jobs/:id has media"  "$DETAIL" '"media"'
fi

banner "Process Endpoints"
check "POST /process full body (standard)"      "$(curl -s -X POST $BASE_URL/process -H 'Content-Type: application/json' -d '{\"srcPath\":\"/data/media\",\"preset\":\"standard\",\"threads\":1}')"    '"jobId"'
check "POST /process mobile-hd"                 "$(curl -s -X POST $BASE_URL/process -H 'Content-Type: application/json' -d '{\"srcPath\":\"/data/media\",\"preset\":\"mobile-hd\"}')"                '"jobId"'
check "POST /process square-hd"                 "$(curl -s -X POST $BASE_URL/process -H 'Content-Type: application/json' -d '{\"srcPath\":\"/data/media\",\"preset\":\"square-hd\"}')"                '"jobId"'
check "POST /process portrait-social"           "$(curl -s -X POST $BASE_URL/process -H 'Content-Type: application/json' -d '{\"srcPath\":\"/data/media\",\"preset\":\"portrait-social\"}')"          '"jobId"'
check "POST /process ultrawide"                 "$(curl -s -X POST $BASE_URL/process -H 'Content-Type: application/json' -d '{\"srcPath\":\"/data/media\",\"preset\":\"ultrawide\"}')"                '"jobId"'
check "POST /process mode:single"               "$(curl -s -X POST $BASE_URL/process -H 'Content-Type: application/json' -d '{\"srcPath\":\"/data/media\",\"preset\":\"standard\",\"mode\":\"single\"}')" '"jobId"'
check "POST /process bad preset → error"        "$(curl -s -X POST $BASE_URL/process -H 'Content-Type: application/json' -d '{\"srcPath\":\"/x\",\"preset\":\"notexist\"}')"                          '"error"'
check "POST /process missing srcPath → error"   "$(curl -s -X POST $BASE_URL/process -H 'Content-Type: application/json' -d '{\"preset\":\"standard\"}')"                                             '"error"'
check "POST /process/folder standard"           "$(curl -s -X POST $BASE_URL/process/folder -H 'Content-Type: application/json' -d '{\"folderPath\":\"/data/media/test\",\"preset\":\"standard\"}')"  '"jobId"'
check "POST /process/folder mobile-hd"          "$(curl -s -X POST $BASE_URL/process/folder -H 'Content-Type: application/json' -d '{\"folderPath\":\"/data/media/test\",\"preset\":\"mobile-hd\"}')" '"jobId"'
check "POST /process/folder no path → error"    "$(curl -s -X POST $BASE_URL/process/folder -H 'Content-Type: application/json' -d '{}')"                                                             '"error"'

banner "Query Filters"
check "GET /jobs?status=running"   "$(curl -s $BASE_URL/jobs?status=running)"   '"jobs"'
check "GET /jobs?status=done"      "$(curl -s $BASE_URL/jobs?status=done)"      '"jobs"'
check "GET /jobs?status=failed"    "$(curl -s $BASE_URL/jobs?status=failed)"    '"jobs"'
check "GET /logs?level=error"      "$(curl -s $BASE_URL/logs?level=error)"      '"logs"'
check "GET /logs?level=info"       "$(curl -s $BASE_URL/logs?level=info)"       '"logs"'
check "GET /media?type=video"      "$(curl -s $BASE_URL/media?type=video)"      '"media"'
check "GET /media?type=image"      "$(curl -s $BASE_URL/media?type=image)"      '"media"'

echo ""
echo -e "${CYAN}================================================"
TOTAL=$((PASS+FAIL))
echo -e "Results: ${GREEN}${PASS}/${TOTAL} passed${NC} | ${RED}${FAIL} failed${NC}"
echo -e "${CYAN}================================================${NC}"

[ "$FAIL" -gt 0 ] && exit 1
exit 0
