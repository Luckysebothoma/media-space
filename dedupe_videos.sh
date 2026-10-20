#!/bin/bash
set -euo pipefail

# --- CONFIG DEFAULTS ---
DRY_RUN=false
VERIFY_HASH=false
TARGET_DIR=""

usage() {
  echo "Usage: $0 [--dry-run|-n] [--verify|-v] <directory>"
  exit 1
}

# --- ARG PARSING ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--dry-run) DRY_RUN=true; shift ;;
    -v|--verify)  VERIFY_HASH=true; shift ;;
    -*) usage ;;
    *)  TARGET_DIR="$1"; shift ;;
  esac
done

[[ -n "$TARGET_DIR" ]] || usage
[[ -d "$TARGET_DIR" ]] || { echo "Error: Directory '$TARGET_DIR' not found"; exit 1; }

echo ">>> STARTING VIDEO DEDUPE <<<"
echo "Directory     : $TARGET_DIR"
echo "Dry Run       : $DRY_RUN"
echo "Hash Verify   : $VERIFY_HASH"
echo "-------------------------------------"

TMP_FILE=$(mktemp)
trap "rm -f $TMP_FILE" EXIT

# ==============================
# STEP 1: SCAN FILES
# ==============================
echo "[+] Scanning files..."
COUNT=0

# We use 'basename' inside the loop to ensure the regex only sees the filename
while read -r file; do
  ((COUNT++))
  
  fname=$(basename "$file")
  
  # STRATEGY: Strip the timestamp (_YYYYMMDD_HHMMSS) and anything like _51mb or _0.2gb
  # This leaves the unique 'ID' of the generated video.
  base=$(echo "$fname" | sed -E 's/(_[0-9.]+(mb|gb))?_[0-9]{8}_[0-9]{6}\.mp4$//i')
  
  size=$(stat -c%s "$file")
  echo "$base|$size|$file" >> "$TMP_FILE"

  [[ $((COUNT % 50)) -eq 0 ]] && echo "[SCAN] $COUNT files..."
done < <(find "$TARGET_DIR" -type f -iname "*.mp4")

TOTAL_FILES=$(wc -l < "$TMP_FILE")
echo "[+] Total files found: $TOTAL_FILES"

if [ "$TOTAL_FILES" -eq 0 ]; then
    echo "[-] No .mp4 files found in $TARGET_DIR. Exiting."
    exit 0
fi

# ==============================
# STEP 2: SORT
# ==============================
sort -t'|' -k1,1 "$TMP_FILE" -o "$TMP_FILE"

# ==============================
# STEP 3: PROCESS
# ==============================
TOTAL_DELETED=0
TOTAL_FREED=0

process_group() {
  local group=("$@")
  [ ${#group[@]} -le 1 ] && return

  # Sort by filename to keep the one with the LATEST timestamp (highest string value)
  keep_file=$(printf "%s\n" "${group[@]}" | cut -d'|' -f3 | sort | tail -n 1)
  
  keep_hash=""
  if [ "$VERIFY_HASH" = true ]; then
    keep_hash=$(md5sum "$keep_file" | awk '{print $1}')
  fi

  for entry in "${group[@]}"; do
    file=$(echo "$entry" | cut -d'|' -f3)
    size=$(echo "$entry" | cut -d'|' -f2)

    [[ "$file" == "$keep_file" ]] && continue

    if [ "$VERIFY_HASH" = true ]; then
      f_hash=$(md5sum "$file" | awk '{print $1}')
      [[ "$f_hash" != "$keep_hash" ]] && continue
    fi

    ((TOTAL_DELETED++))
    ((TOTAL_FREED+=size))

    if [ "$DRY_RUN" = false ]; then
      rm -f "$file"
      echo "[DEL] $(basename "$file")"
    else
      echo "[WOULD DEL] $(basename "$file")"
    fi
  done
}

CURRENT_KEY=""
GROUP=()

while IFS= read -r line; do
  key=$(echo "$line" | cut -d'|' -f1)
  if [[ -n "$CURRENT_KEY" && "$key" != "$CURRENT_KEY" ]]; then
    process_group "${GROUP[@]}"
    GROUP=()
  fi
  GROUP+=("$line")
  CURRENT_KEY="$key"
done < "$TMP_FILE"

[[ ${#GROUP[@]} -gt 0 ]] && process_group "${GROUP[@]}"

echo "-------------------------------------"
echo ">>> SUMMARY <<<"
echo "Files Deleted : $TOTAL_DELETED"
echo "Space Freed   : $(numfmt --to=iec $TOTAL_FREED)"
[[ "$DRY_RUN" = true ]] && echo "[DRY RUN] No files removed."
