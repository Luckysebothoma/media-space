#!/bin/bash
# ============================================================
# smoke-test.sh — Validates i2v-microservice v4 stack
# Usage: bash smoke-test.sh [http://localhost:3000]
# ============================================================
set -euo pipefail

BASE_URL="${1:-http://localhost:3000}"
PASS=0; FAIL=0

GREEN='\033[0;32m'; RED='\033[0;31m'; CYAN='\033[0;36m'; NC='\033[0m'

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
echo "  i2v-microservice v4 — Smoke Test Suite"
echo "  Target: $BASE_URL"
echo -e "================================================${NC}"

echo ""
echo "Waiting for service to be ready (up to 60s)..."
for i in $(seq 1 30); do
  CODE=$(curl -s -o /dev/null -w "%{http_code}" "$BASE_URL/status" 2>/dev/null || echo "000")
  if [ "$CODE" = "200" ]; then echo -e "${GREEN}✓ Service is up!${NC}"; break; fi
  [ "$i" = "30" ] && { echo -e "${RED}Timed out waiting for service.${NC}"; exit 1; }
  sleep 2
done

banner "Core Endpoints"
check_http "GET / HTTP 200"          "$BASE_URL/"        "200"
check      "GET /status ok:true"     "$(curl -s $BASE_URL/status)"   '"ok":true'
check      "GET /status remotes key" "$(curl -s $BASE_URL/status)"   'remotes_mounted'
check_http "GET /doc HTTP 200"       "$BASE_URL/doc"      "200"
check_http "GET /metrics HTTP 200"   "$BASE_URL/metrics"  "200"
check      "GET /metrics has jobs_started" "$(curl -s $BASE_URL/metrics)" 'i2v_jobs_started_total'
check      "GET /presets has transitions"  "$(curl -s $BASE_URL/presets)" '"transitions"'
check      "GET /presets has motions"      "$(curl -s $BASE_URL/presets)" '"motions"'
check      "GET /presets has mobile-hd"    "$(curl -s $BASE_URL/presets)" 'mobile-hd'
check      "GET /jobs returns array"       "$(curl -s $BASE_URL/jobs)"    '"jobs"'
check      "GET /remotes returns array"    "$(curl -s $BASE_URL/remotes)" '"remotes"'
check      "GET /logs returns array"       "$(curl -s $BASE_URL/logs)"    '"logs"'
check      "GET /media returns array"      "$(curl -s $BASE_URL/media)"   '"media"'

banner "Grouped Mode"
check "POST /process/quick/standard"  "$(curl -s -X POST $BASE_URL/process/quick/standard)" '"jobId"'
check "POST /process (ratio 9:16)"    "$(curl -s -X POST $BASE_URL/process -H 'Content-Type: application/json' -d '{\"srcPath\":\"/data/media\",\"ratio\":\"9:16\",\"transition\":\"fade\",\"motion\":\"kenburns\"}')" '"jobId"'
check "POST /process bad preset"      "$(curl -s -X POST $BASE_URL/process -H 'Content-Type: application/json' -d '{\"srcPath\":\"/x\",\"preset\":\"notexist\"}')" '"error"'

banner "Singles Mode"
check "POST /process/singles/standard" "$(curl -s -X POST $BASE_URL/process/singles/standard)" '"jobId"'
check "POST /process/singles full body" "$(curl -s -X POST $BASE_URL/process/singles -H 'Content-Type: application/json' -d '{\"srcPath\":\"/data/media\",\"ratio\":\"1:1\",\"motion\":\"zoom\"}')" '"jobId"'
check "POST /process/singles missing srcPath falls back to DATA_ROOT" "$(curl -s -X POST $BASE_URL/process/singles -H 'Content-Type: application/json' -d '{}')" '"jobId"'

banner "Remotes — validation paths (no live host required)"
check "POST /remotes missing fields → error" "$(curl -s -X POST $BASE_URL/remotes -H 'Content-Type: application/json' -d '{\"name\":\"x\"}')" '"error"'
check "POST /remotes bad protocol → error"   "$(curl -s -X POST $BASE_URL/remotes -H 'Content-Type: application/json' -d '{\"name\":\"x\",\"protocol\":\"ftp\",\"host\":\"h\",\"remotePath\":\"/p\"}')" '"error"'
check "POST /remotes (ssh key) creates row"  "$(curl -s -X POST $BASE_URL/remotes -H 'Content-Type: application/json' -d '{\"name\":\"smoketest-ssh\",\"protocol\":\"ssh\",\"host\":\"127.0.0.1\",\"username\":\"test\",\"authType\":\"key\",\"privateKey\":\"dummy\",\"remotePath\":\"/tmp\"}')" '"remote"'
check "GET /remotes lists it"                "$(curl -s $BASE_URL/remotes)" 'smoketest-ssh'

REMOTE_ID=$(curl -s "$BASE_URL/remotes" | grep -o '"id":"[^"]*","name":"smoketest-ssh"' | grep -o '[a-f0-9-]\{36\}' | head -1 || true)
if [ -n "$REMOTE_ID" ]; then
  banner "Remotes — cleanup"
  check "DELETE /remotes/:id" "$(curl -s -X DELETE $BASE_URL/remotes/$REMOTE_ID)" '"ok":true'
fi

banner "Query Filters"
check "GET /jobs?mode=grouped" "$(curl -s $BASE_URL/jobs?mode=grouped)" '"jobs"'
check "GET /jobs?mode=singles" "$(curl -s $BASE_URL/jobs?mode=singles)" '"jobs"'
check "GET /logs?level=error"  "$(curl -s $BASE_URL/logs?level=error)"  '"logs"'

echo ""
echo -e "${CYAN}================================================"
TOTAL=$((PASS+FAIL))
echo -e "Results: ${GREEN}${PASS}/${TOTAL} passed${NC} | ${RED}${FAIL} failed${NC}"
echo -e "${CYAN}================================================${NC}"

[ "$FAIL" -gt 0 ] && exit 1
exit 0
