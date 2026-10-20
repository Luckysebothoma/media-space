#!/bin/bash
################################################################################
# MEDIA ORGANIZER API — Consumer Guide & Testing Reference
# A living document showing how to consume every available endpoint.
# Usage: bash media_api_guide.sh [BASE_URL]
# Example: bash media_api_guide.sh http://192.168.0.140:3000
################################################################################

BASE_URL="${1:-http://192.168.0.140:3000}"

# ── Colours ───────────────────────────────────────────────────────────────────
BOLD='\033[1m'
DIM='\033[2m'
CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
RED='\033[0;31m'
NC='\033[0m'

# ── Helpers ───────────────────────────────────────────────────────────────────
section() {
  echo
  echo -e "${BOLD}${BLUE}################################################################################${NC}"
  echo -e "${BOLD}${BLUE}#  $*${NC}"
  echo -e "${BOLD}${BLUE}################################################################################${NC}"
  echo
}

subsection() {
  echo
  echo -e "${BOLD}${CYAN}── $* ──────────────────────────────────────────────────────────────────────${NC}"
  echo
}

desc() {
  echo -e "${DIM}  ▸ $*${NC}"
}

show_request() {
  local method="$1"
  local path="$2"
  local body="${3:-}"
  echo -e "${YELLOW}  REQUEST${NC}"
  if [[ -z "$body" ]]; then
    echo -e "  ${GREEN}${method}${NC} ${BASE_URL}${path}"
    echo -e "  ${DIM}curl -s -X ${method} \"${BASE_URL}${path}\"${NC}"
  else
    echo -e "  ${GREEN}${method}${NC} ${BASE_URL}${path}"
    echo -e "  ${DIM}curl -s -X ${method} \"${BASE_URL}${path}\" \\${NC}"
    echo -e "  ${DIM}  -H \"Content-Type: application/json\" \\${NC}"
    echo -e "  ${DIM}  -d '${body}'${NC}"
  fi
}

show_response() {
  local response="$1"
  echo -e "${MAGENTA}  RESPONSE${NC}"
  echo "$response" | python3 -m json.tool 2>/dev/null \
    | sed 's/^/  /' \
    || echo "  $response"
}

run_get() {
  local label="$1"
  local path="$2"
  local query="${3:-}"
  local full_path="${path}${query}"
  show_request "GET" "$full_path"
  echo
  local response
  response=$(curl -s "${BASE_URL}${full_path}")
  show_response "$response"
}

run_post() {
  local label="$1"
  local path="$2"
  local body="$3"
  show_request "POST" "$path" "$body"
  echo
  local response
  response=$(curl -s -X POST "${BASE_URL}${path}" \
    -H "Content-Type: application/json" \
    -d "$body")
  show_response "$response"
}

separator() {
  echo -e "${DIM}  ────────────────────────────────────────────────────────────────────────${NC}"
}

wait_for_server() {
  echo -e "${CYAN}  Checking server at ${BASE_URL} ...${NC}"
  for i in {1..10}; do
    if curl -sf "${BASE_URL}/" &>/dev/null; then
      echo -e "${GREEN}  ✓ Server is reachable${NC}"
      return 0
    fi
    sleep 1
  done
  echo -e "${RED}  ✗ Server not reachable at ${BASE_URL}${NC}"
  echo -e "${DIM}  Start locally: npm run dev   or   docker service logs mediastack_media-organizer${NC}"
  exit 1
}

# ══════════════════════════════════════════════════════════════════════════════

clear
echo -e "${BOLD}"
cat << 'BANNER'
  ███╗   ███╗███████╗██████╗ ██╗ █████╗      ██████╗ ██████╗  ██████╗
  ████╗ ████║██╔════╝██╔══██╗██║██╔══██╗    ██╔═══██╗██╔══██╗██╔════╝
  ██╔████╔██║█████╗  ██║  ██║██║███████║    ██║   ██║██████╔╝██║  ███╗
  ██║╚██╔╝██║██╔══╝  ██║  ██║██║██╔══██║    ██║   ██║██╔══██╗██║   ██║
  ██║ ╚═╝ ██║███████╗██████╔╝██║██║  ██║    ╚██████╔╝██║  ██║╚██████╔╝
  ╚═╝     ╚═╝╚══════╝╚═════╝ ╚═╝╚═╝  ╚═╝    ╚═════╝ ╚═╝  ╚═╝ ╚═════╝
                     API  Consumer Guide & Reference
BANNER
echo -e "${NC}"
echo -e "  ${DIM}Target: ${BASE_URL}${NC}"
echo -e "  ${DIM}Generated: $(date '+%Y-%m-%d %H:%M:%S')${NC}"

wait_for_server

# ══════════════════════════════════════════════════════════════════════════════
section "SECTION 1 — SYSTEM & UTILITY ENDPOINTS"
# ══════════════════════════════════════════════════════════════════════════════

subsection "1.1  GET /  — Health Check"
desc "Returns server status, version and a hint to /help."
desc "No body required. Use this to verify the service is alive."
separator
run_get "health" "/"

# ─────────────────────────────────────────────────────────────────────────────
subsection "1.2  GET /help  — Full API Documentation"
desc "Returns every endpoint with description, required body fields, and a"
desc "ready-to-copy JSON example. This is your built-in reference card."
separator
run_get "help" "/help"

# ─────────────────────────────────────────────────────────────────────────────
subsection "1.3  GET /calendar  — Date Context"
desc "Returns today's date broken down into every key format used by the"
desc "organizer: dayKey (YYYYMMDD), monthKey (YYYYMM), weekKey (YYYY_WNN)."
desc "Query this first when building date-based payloads so your keys match."
separator
run_get "calendar" "/calendar"

# ─────────────────────────────────────────────────────────────────────────────
subsection "1.4  GET /logs/recent  — Tail Combined Log"
desc "Returns the last N lines from combined.log (all levels: info, warn, error)."
desc "Query param: ?lines=N  (default 100)"
separator
echo -e "${CYAN}  Example A — last 20 lines${NC}"
run_get "logs-recent-20" "/logs/recent" "?lines=20"

separator
echo -e "${CYAN}  Example B — last 5 lines (quick sanity check)${NC}"
run_get "logs-recent-5" "/logs/recent" "?lines=5"

# ─────────────────────────────────────────────────────────────────────────────
subsection "1.5  GET /logs/errors  — Tail Error Log"
desc "Returns the last N lines from error.log (errors only)."
desc "Query param: ?lines=N  (default 100)"
separator
run_get "logs-errors" "/logs/errors" "?lines=10"


# ══════════════════════════════════════════════════════════════════════════════
section "SECTION 2 — SCAN ENDPOINT (READ-ONLY, NO MOVES)"
# ══════════════════════════════════════════════════════════════════════════════

subsection "2.1  POST /organize/scan  — Inventory Only"
desc "Counts files, calculates total size, detects duplicates."
desc "NEVER moves any file — safe to run at any time as a preflight check."
desc ""
desc "Required body fields:"
desc "  sourceDir  string  — absolute path to the directory to scan"
desc "  mediaType  string  — 'image' | 'video' | 'both'"

separator
echo -e "${CYAN}  Example A — scan everything${NC}"
run_post "scan-both" "/organize/scan" '{
  "sourceDir": "/media/input",
  "mediaType": "both"
}'

separator
echo -e "${CYAN}  Example B — scan images only${NC}"
run_post "scan-images" "/organize/scan" '{
  "sourceDir": "/media/input",
  "mediaType": "image"
}'

separator
echo -e "${CYAN}  Example C — scan videos only${NC}"
run_post "scan-videos" "/organize/scan" '{
  "sourceDir": "/media/input",
  "mediaType": "video"
}'


# ══════════════════════════════════════════════════════════════════════════════
section "SECTION 3 — GROUP BY FILENAME TIMESTAMP"
# ══════════════════════════════════════════════════════════════════════════════

subsection "3.1  POST /organize/filename  — Group by YYYYMMDD_HHMMSS"
desc "Groups files that share the same base timestamp in their filename."
desc "e.g. 20260322_075059.mp4 and 20260322_075059_1.jpg end up together."
desc "Output folder naming: {timestamp}__{count}_{size}mb"
desc ""
desc "Required body fields:"
desc "  sourceDir  string   — source directory (searched recursively)"
desc "  outputDir  string   — where grouped folders are created"
desc "  mediaType  string   — 'image' | 'video' | 'both'"
desc "  dryRun     boolean  — true = preview only, false = real move (default false)"

separator
echo -e "${CYAN}  Example A — dry-run, both types${NC}"
run_post "filename-dryrun" "/organize/filename" '{
  "sourceDir": "/media/input",
  "outputDir": "/media/processed/by-filename",
  "mediaType": "both",
  "dryRun": true
}'

separator
echo -e "${CYAN}  Example B — real move, images only${NC}"
run_post "filename-images" "/organize/filename" '{
  "sourceDir": "/media/input",
  "outputDir": "/media/processed/by-filename",
  "mediaType": "image",
  "dryRun": false
}'

separator
echo -e "${CYAN}  Example C — real move, videos only${NC}"
run_post "filename-videos" "/organize/filename" '{
  "sourceDir": "/media/input",
  "outputDir": "/media/processed/by-filename",
  "mediaType": "video",
  "dryRun": false
}'


# ══════════════════════════════════════════════════════════════════════════════
section "SECTION 4 — GROUP BY DATE (DAY / WEEK / MONTH)"
# ══════════════════════════════════════════════════════════════════════════════

subsection "4.1  POST /organize/date  — granularity: \"day\""
desc "Groups all media that was captured on the same calendar day."
desc "Output folder: 20260322__{count}_{size}  (YYYYMMDD)"
desc ""
desc "Required body fields:"
desc "  sourceDir    string  — source path"
desc "  outputDir    string  — output path"
desc "  mediaType    string  — 'image' | 'video' | 'both'"
desc "  granularity  string  — 'day'"
desc "  dryRun       boolean — optional, default false"

separator
echo -e "${CYAN}  Example A — group by day, dry-run${NC}"
run_post "date-day-dry" "/organize/date" '{
  "sourceDir": "/media/input",
  "outputDir": "/media/processed/by-day",
  "mediaType": "both",
  "granularity": "day",
  "dryRun": true
}'

separator
echo -e "${CYAN}  Example B — group by day, images only, real move${NC}"
run_post "date-day-images" "/organize/date" '{
  "sourceDir": "/media/input",
  "outputDir": "/media/processed/by-day",
  "mediaType": "image",
  "granularity": "day",
  "dryRun": false
}'

# ─────────────────────────────────────────────────────────────────────────────
subsection "4.2  POST /organize/date  — granularity: \"week\""
desc "Groups media by ISO week number."
desc "Output folder: 2026_W12__{count}_{size}  (YYYY_WNN)"
desc "Tip: use GET /calendar first to see the current weekKey."

separator
echo -e "${CYAN}  Example A — group by week, both types, dry-run${NC}"
run_post "date-week-dry" "/organize/date" '{
  "sourceDir": "/media/input",
  "outputDir": "/media/processed/by-week",
  "mediaType": "both",
  "granularity": "week",
  "dryRun": true
}'

separator
echo -e "${CYAN}  Example B — group by week, videos only${NC}"
run_post "date-week-videos" "/organize/date" '{
  "sourceDir": "/media/input",
  "outputDir": "/media/processed/by-week",
  "mediaType": "video",
  "granularity": "week",
  "dryRun": false
}'

# ─────────────────────────────────────────────────────────────────────────────
subsection "4.3  POST /organize/date  — granularity: \"month\""
desc "Groups media by calendar month."
desc "Output folder: 202603__{count}_{size}  (YYYYMM)"
desc "Tip: use GET /calendar first to see the current monthKey."

separator
echo -e "${CYAN}  Example A — group by month, dry-run${NC}"
run_post "date-month-dry" "/organize/date" '{
  "sourceDir": "/media/input",
  "outputDir": "/media/processed/by-month",
  "mediaType": "both",
  "granularity": "month",
  "dryRun": true
}'

separator
echo -e "${CYAN}  Example B — group by month, images only${NC}"
run_post "date-month-images" "/organize/date" '{
  "sourceDir": "/media/input",
  "outputDir": "/media/processed/by-month",
  "mediaType": "image",
  "granularity": "month",
  "dryRun": false
}'


# ══════════════════════════════════════════════════════════════════════════════
section "SECTION 5 — GROUP BY HOUR"
# ══════════════════════════════════════════════════════════════════════════════

subsection "5.1  POST /organize/hour  — Group by Day + Hour"
desc "Groups media captured within the same hour of the same day."
desc "Output folder: 20260322_07__{count}_{size}  (YYYYMMDD_HH)"
desc "Ideal for burst sessions or time-lapse sequences."

separator
echo -e "${CYAN}  Example A — dry-run preview${NC}"
run_post "hour-dry" "/organize/hour" '{
  "sourceDir": "/media/input",
  "outputDir": "/media/processed/by-hour",
  "mediaType": "both",
  "dryRun": true
}'

separator
echo -e "${CYAN}  Example B — real move, images only${NC}"
run_post "hour-images" "/organize/hour" '{
  "sourceDir": "/media/input",
  "outputDir": "/media/processed/by-hour",
  "mediaType": "image",
  "dryRun": false
}'


# ══════════════════════════════════════════════════════════════════════════════
section "SECTION 6 — FLATTEN"
# ══════════════════════════════════════════════════════════════════════════════

subsection "6.1  POST /organize/flatten  — Move All to Single Directory"
desc "Moves every matching file into one flat outputDir."
desc "Duplicates (by MD5) are automatically skipped — only unique files land."
desc "Useful for consolidating scattered media before a re-sort."

separator
echo -e "${CYAN}  Example A — flatten all, dry-run${NC}"
run_post "flatten-dry" "/organize/flatten" '{
  "sourceDir": "/media/input",
  "outputDir": "/media/processed/flat",
  "mediaType": "both",
  "dryRun": true
}'

separator
echo -e "${CYAN}  Example B — flatten videos only${NC}"
run_post "flatten-videos" "/organize/flatten" '{
  "sourceDir": "/media/input",
  "outputDir": "/media/processed/flat-videos",
  "mediaType": "video",
  "dryRun": false
}'

separator
echo -e "${CYAN}  Example C — flatten images only${NC}"
run_post "flatten-images" "/organize/flatten" '{
  "sourceDir": "/media/input",
  "outputDir": "/media/processed/flat-images",
  "mediaType": "image",
  "dryRun": false
}'


# ══════════════════════════════════════════════════════════════════════════════
section "SECTION 7 — SEPARATE BY TYPE"
# ══════════════════════════════════════════════════════════════════════════════

subsection "7.1  POST /organize/separate  — Split into images/ and videos/"
desc "Splits all media under sourceDir into two subdirectories:"
desc "  outputDir/images__N_Xmb"
desc "  outputDir/videos__N_Xmb"
desc "mediaType is always 'both' for this endpoint — no filter needed."
desc ""
desc "Required body fields:"
desc "  sourceDir  string   — source path"
desc "  outputDir  string   — parent output path"
desc "  dryRun     boolean  — optional"

separator
echo -e "${CYAN}  Example A — separate, dry-run${NC}"
run_post "separate-dry" "/organize/separate" '{
  "sourceDir": "/media/input",
  "outputDir": "/media/processed",
  "dryRun": true
}'

separator
echo -e "${CYAN}  Example B — separate, real move${NC}"
run_post "separate-real" "/organize/separate" '{
  "sourceDir": "/media/input",
  "outputDir": "/media/processed",
  "dryRun": false
}'


# ══════════════════════════════════════════════════════════════════════════════
section "SECTION 8 — RELATED CONTENT"
# ══════════════════════════════════════════════════════════════════════════════

subsection "8.1  POST /organize/related  — Group Same-Timestamp Image+Video Pairs"
desc "Finds hours where BOTH images and videos exist with the same timestamp."
desc "Only groups containing at least one image AND one video are moved."
desc "Perfect for camera setups that capture a still + a clip simultaneously."
desc ""
desc "Required body fields:"
desc "  sourceDir  string   — source path"
desc "  outputDir  string   — output path"
desc "  dryRun     boolean  — optional"

separator
echo -e "${CYAN}  Example A — find related, dry-run${NC}"
run_post "related-dry" "/organize/related" '{
  "sourceDir": "/media/input",
  "outputDir": "/media/processed/related",
  "dryRun": true
}'

separator
echo -e "${CYAN}  Example B — find related, real move${NC}"
run_post "related-real" "/organize/related" '{
  "sourceDir": "/media/input",
  "outputDir": "/media/processed/related",
  "dryRun": false
}'


# ══════════════════════════════════════════════════════════════════════════════
section "SECTION 9 — DEDUPLICATE"
# ══════════════════════════════════════════════════════════════════════════════

subsection "9.1  POST /organize/deduplicate  — MD5-Based Duplicate Removal"
desc "Computes MD5 hash of every file. Keeps the first occurrence in place."
desc "All subsequent identical files are moved to outputDir/duplicates/."
desc "Run with dryRun: true first to see how many duplicates exist before committing."

separator
echo -e "${CYAN}  Example A — deduplicate, dry-run (safe preview)${NC}"
run_post "dedup-dry" "/organize/deduplicate" '{
  "sourceDir": "/media/input",
  "outputDir": "/media/processed",
  "mediaType": "both",
  "dryRun": true
}'

separator
echo -e "${CYAN}  Example B — deduplicate images only${NC}"
run_post "dedup-images" "/organize/deduplicate" '{
  "sourceDir": "/media/input",
  "outputDir": "/media/processed",
  "mediaType": "image",
  "dryRun": false
}'

separator
echo -e "${CYAN}  Example C — deduplicate videos only${NC}"
run_post "dedup-videos" "/organize/deduplicate" '{
  "sourceDir": "/media/input",
  "outputDir": "/media/processed",
  "mediaType": "video",
  "dryRun": false
}'


# ══════════════════════════════════════════════════════════════════════════════
section "SECTION 10 — VALIDATION BEHAVIOUR (ERROR CASES)"
# ══════════════════════════════════════════════════════════════════════════════

subsection "10.1  Missing required fields → HTTP 422"
desc "Every POST endpoint validates its body with Zod."
desc "Missing or wrong-type fields return 422 with a detailed fieldErrors map."
separator
run_post "err-missing-fields" "/organize/filename" '{
  "mediaType": "both"
}'

subsection "10.2  Invalid mediaType → HTTP 422"
desc "mediaType only accepts: image | video | both"
separator
run_post "err-bad-mediatype" "/organize/filename" '{
  "sourceDir": "/media/input",
  "outputDir": "/media/processed",
  "mediaType": "audio"
}'

subsection "10.3  Invalid granularity → HTTP 422"
desc "granularity only accepts: day | week | month"
separator
run_post "err-bad-granularity" "/organize/date" '{
  "sourceDir": "/media/input",
  "outputDir": "/media/processed",
  "mediaType": "both",
  "granularity": "year"
}'

subsection "10.4  Invalid JSON body → HTTP 400"
desc "Malformed JSON returns 400 Bad Request."
separator
show_request "POST" "/organize/scan" "not-valid-json"
echo
response=$(curl -s -X POST "${BASE_URL}/organize/scan" \
  -H "Content-Type: application/json" \
  -d "not-valid-json")
show_response "$response"

subsection "10.5  Unknown route → HTTP 404"
desc "Any path not registered returns 404 with a hint to /help."
separator
run_get "404-test" "/logs"


# ══════════════════════════════════════════════════════════════════════════════
section "SECTION 11 — RECOMMENDED WORKFLOW"
# ══════════════════════════════════════════════════════════════════════════════

echo -e "${BOLD}  Suggested step-by-step workflow for a new media directory:${NC}"
echo
echo -e "  ${GREEN}Step 1${NC}  ${DIM}— Check the server is alive${NC}"
echo -e "  ${CYAN}  curl ${BASE_URL}/${NC}"
echo
echo -e "  ${GREEN}Step 2${NC}  ${DIM}— Get today's date keys (useful for date-based grouping)${NC}"
echo -e "  ${CYAN}  curl ${BASE_URL}/calendar${NC}"
echo
echo -e "  ${GREEN}Step 3${NC}  ${DIM}— Scan first — understand what you have before moving anything${NC}"
echo -e "  ${CYAN}  curl -s -X POST ${BASE_URL}/organize/scan \\${NC}"
echo -e "  ${CYAN}    -H \"Content-Type: application/json\" \\${NC}"
echo -e "  ${CYAN}    -d '{\"sourceDir\":\"/media/input\",\"mediaType\":\"both\"}'${NC}"
echo
echo -e "  ${GREEN}Step 4${NC}  ${DIM}— Dry-run your chosen operation to preview groups${NC}"
echo -e "  ${CYAN}  curl -s -X POST ${BASE_URL}/organize/date \\${NC}"
echo -e "  ${CYAN}    -H \"Content-Type: application/json\" \\${NC}"
echo -e "  ${CYAN}    -d '{\"sourceDir\":\"/media/input\",\"outputDir\":\"/media/processed\",${NC}"
echo -e "  ${CYAN}         \"mediaType\":\"both\",\"granularity\":\"day\",\"dryRun\":true}'${NC}"
echo
echo -e "  ${GREEN}Step 5${NC}  ${DIM}— Happy with the preview? Re-run with dryRun: false${NC}"
echo -e "  ${CYAN}  (same payload, change \"dryRun\":false)${NC}"
echo
echo -e "  ${GREEN}Step 6${NC}  ${DIM}— Check logs to confirm operations${NC}"
echo -e "  ${CYAN}  curl \"${BASE_URL}/logs/recent?lines=30\"${NC}"
echo
echo -e "  ${GREEN}Step 7${NC}  ${DIM}— If duplicates remain, isolate them${NC}"
echo -e "  ${CYAN}  curl -s -X POST ${BASE_URL}/organize/deduplicate \\${NC}"
echo -e "  ${CYAN}    -H \"Content-Type: application/json\" \\${NC}"
echo -e "  ${CYAN}    -d '{\"sourceDir\":\"/media/input\",\"outputDir\":\"/media/processed\",${NC}"
echo -e "  ${CYAN}         \"mediaType\":\"both\",\"dryRun\":false}'${NC}"
echo


# ══════════════════════════════════════════════════════════════════════════════
section "SECTION 12 — QUICK REFERENCE CARD"
# ══════════════════════════════════════════════════════════════════════════════

echo -e "${BOLD}  All endpoints at a glance:${NC}"
echo
printf "  ${BOLD}%-10s %-26s %-18s %s${NC}\n" "METHOD" "PATH" "MOVES FILES?" "KEY BODY FIELDS"
printf "  ${DIM}%-10s %-26s %-18s %s${NC}\n" "──────" "──────────────────────────" "────────────────" "─────────────────────────────────────────"
printf "  %-10s %-26s %-18s %s\n" "GET"  "/"                        "no"  "—"
printf "  %-10s %-26s %-18s %s\n" "GET"  "/help"                    "no"  "—"
printf "  %-10s %-26s %-18s %s\n" "GET"  "/calendar"                "no"  "—"
printf "  %-10s %-26s %-18s %s\n" "GET"  "/logs/recent?lines=N"     "no"  "—"
printf "  %-10s %-26s %-18s %s\n" "GET"  "/logs/errors?lines=N"     "no"  "—"
printf "  %-10s %-26s %-18s %s\n" "POST" "/organize/scan"           "NEVER" "sourceDir, mediaType"
printf "  %-10s %-26s %-18s %s\n" "POST" "/organize/filename"       "yes" "sourceDir, outputDir, mediaType, dryRun"
printf "  %-10s %-26s %-18s %s\n" "POST" "/organize/date"           "yes" "sourceDir, outputDir, mediaType, granularity, dryRun"
printf "  %-10s %-26s %-18s %s\n" "POST" "/organize/hour"           "yes" "sourceDir, outputDir, mediaType, dryRun"
printf "  %-10s %-26s %-18s %s\n" "POST" "/organize/flatten"        "yes" "sourceDir, outputDir, mediaType, dryRun"
printf "  %-10s %-26s %-18s %s\n" "POST" "/organize/separate"       "yes" "sourceDir, outputDir, dryRun"
printf "  %-10s %-26s %-18s %s\n" "POST" "/organize/related"        "yes" "sourceDir, outputDir, dryRun"
printf "  %-10s %-26s %-18s %s\n" "POST" "/organize/deduplicate"    "yes" "sourceDir, outputDir, mediaType, dryRun"
echo
echo -e "  ${DIM}mediaType values:    image | video | both${NC}"
echo -e "  ${DIM}granularity values:  day | week | month${NC}"
echo -e "  ${DIM}dryRun:              true = preview only (default false)${NC}"
echo


# ══════════════════════════════════════════════════════════════════════════════
echo -e "${BOLD}${GREEN}"
echo "  ✓ Guide complete. All endpoints exercised."
echo -e "${NC}"
echo -e "  ${DIM}Tip: pipe this script through 'less -R' for colour-paged output:${NC}"
echo -e "  ${DIM}  bash media_api_guide.sh ${BASE_URL} | less -R${NC}"
echo
