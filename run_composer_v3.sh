#!/bin/bash
set -euo pipefail

# --- CONFIG ---
#OUTPUT_BASE="./archives"
LOG_DIR="./.logs"
DATE_STAMP=$(date +%Y%m%d_%H%M%S)

declare -A PRESETS=(
    ["standard"]="1920:1080:23:5000"
    ["high"]="1920:1080:18:8000"
    ["4k"]="3840:2160:20:15000"
    ["cinema"]="4096:2160:18:20000"
)

MIN_DURATION=30
IMAGE_DURATION=3
MIN_SIZE_MB=1
FPS=30
#!/bin/bash
set -euo pipefail

# --- LOAD FROM ENV OR CLI ---
INPUT_PATH="${1:-${INPUT_PATH:-}}"
PRESET="${2:-${PRESET:-standard}}"
THREADS="${3:-${THREADS:-1}}"
OUTPUT_BASE="${OUTPUT_PATH:-./archives}"

if [[ -z "$INPUT_PATH" ]]; then
  echo "[ERROR] INPUT_PATH not provided"
  exit 1
fi

echo "[INFO] INPUT_PATH=$INPUT_PATH"
echo "[INFO] PRESET=$PRESET"
echo "[INFO] THREADS=$THREADS"
echo "[INFO] OUTPUT=$OUTPUT_BASE"

# your existing logic continues...

mkdir -p "$OUTPUT_BASE" "$LOG_DIR"

# --- COLORS ---
C_GREEN='\033[0;32m'
C_RED='\033[0;31m'
C_CYAN='\033[0;36m'
C_YELLOW='\033[1;33m'
C_NC='\033[0m'

show_usage() {
    echo "Usage: $0 [source_dir] [preset] [threads]"
    echo "Presets: standard, high, 4k, cinema"
    exit 1
}

# --- ARGS ---
[[ $# -lt 1 ]] && show_usage

SRC_PATH="${1%/}"
#PRESET="${2:-standard}"
#THREADS="${3:-4}"

if [[ ! -v PRESETS[$PRESET] ]]; then
    echo -e "${C_RED}Error: Unknown preset '$PRESET'${C_NC}"
    exit 1
fi

IFS=':' read -r WIDTH HEIGHT CRF BITRATE <<< "${PRESETS[$PRESET]}"

echo -e "${C_CYAN}>>> COMPOSER V4 STARTED: $DATE_STAMP <<<${C_NC}"
echo -e "Source: $SRC_PATH | Quality: $PRESET (${WIDTH}x${HEIGHT}, CRF $CRF, BR ${BITRATE}k)"
echo -e "Image Duration: ${IMAGE_DURATION}s | Min Video: ${MIN_DURATION}s | FPS: ${FPS} | Threads: $THREADS"
echo -e "Mode: Process each folder independently (non-recursive)"

if [[ ! -d "$SRC_PATH" ]]; then
    echo -e "${C_RED}Error: Source directory not found${C_NC}"
    exit 1
fi

success_count=0
skip_count=0
fail_count=0

process_folder() {
    local folder="$1"
    local folder_name
    folder_name=$(basename "$folder")

    local output_file="${OUTPUT_BASE}/${folder_name}_${DATE_STAMP}.mp4"
    local log_file="${LOG_DIR}/${folder_name}.log"
    local manifest
    manifest=$(mktemp)

    echo -e "${C_YELLOW}Processing:${C_NC} $folder_name"

    # Collect images ONLY from this folder (maxdepth 1)
    mapfile -t images < <(
        find "$folder" -maxdepth 1 -type f \
        \( -iname "*.jpg" -o -iname "*.jpeg" -o -iname "*.png" -o -iname "*.webp" -o -iname "*.bmp" -o -iname "*.tiff" \) \
        | sort
    )

    if [[ ${#images[@]} -eq 0 ]]; then
        echo -e "${C_YELLOW}[SKIP] No images found${C_NC}"
        ((skip_count++))
        rm -f "$manifest"
        return
    fi

    local total_duration
    total_duration=$(( ${#images[@]} * IMAGE_DURATION ))

    # Ensure minimum duration
    if (( total_duration < MIN_DURATION )); then
        total_duration=$MIN_DURATION
    fi

    # --- SINGLE IMAGE MODE ---
    if [[ ${#images[@]} -eq 1 ]]; then
        local img="${images[0]}"
        echo "  Images: 1 | Mode: single-image (loop, ${total_duration}s)"

        if ffmpeg -y -loglevel error -loop 1 -i "$img" \
            -vf "scale=${WIDTH}:${HEIGHT}:force_original_aspect_ratio=decrease,pad=${WIDTH}:${HEIGHT}:(ow-iw)/2:(oh-ih)/2,fps=${FPS}" \
            -t "$total_duration" \
            -c:v libx264 -crf "$CRF" -b:v "${BITRATE}k" -preset fast \
            -pix_fmt yuv420p -threads "$THREADS" \
            "$output_file" > "$log_file" 2>&1
        then
            local size_mb
            size_mb=$(du -m "$output_file" 2>/dev/null | cut -f1 || echo "0")
            
            if (( size_mb < MIN_SIZE_MB )); then
                echo -e "${C_YELLOW}  [WARN] Output too small (${size_mb}MB < ${MIN_SIZE_MB}MB)${C_NC}"
                ((fail_count++))
                rm -f "$output_file"
            else
                echo -e "${C_GREEN}  ✓ DONE (${size_mb}MB, ${total_duration}s)${C_NC}"
                ((success_count++))
            fi
        else
            echo -e "${C_RED}  ✗ FAILED${C_NC}"
            ((fail_count++))
        fi

        rm -f "$manifest"
        return
    fi

    # --- MULTI IMAGE MODE ---
    echo "  Images: ${#images[@]} | Mode: multi-image (${total_duration}s total)"

    {
        for img in "${images[@]}"; do
            printf "file '%s'\n" "$img"
            printf "duration %s\n" "$IMAGE_DURATION"
        done
        printf "file '%s'\n" "${images[-1]}"
    } > "$manifest"

    if ffmpeg -y -loglevel error -f concat -safe 0 -i "$manifest" \
        -vf "scale=${WIDTH}:${HEIGHT}:force_original_aspect_ratio=decrease,pad=${WIDTH}:${HEIGHT}:(ow-iw)/2:(oh-ih)/2,fps=${FPS}" \
        -c:v libx264 -crf "$CRF" -b:v "${BITRATE}k" -preset fast \
        -pix_fmt yuv420p -threads "$THREADS" \
        "$output_file" > "$log_file" 2>&1
    then
        if [[ -f "$output_file" ]]; then
            local size_mb
            size_mb=$(du -m "$output_file" 2>/dev/null | cut -f1 || echo "0")

            if (( size_mb < MIN_SIZE_MB )); then
                echo -e "${C_YELLOW}  [WARN] Output too small (${size_mb}MB < ${MIN_SIZE_MB}MB)${C_NC}"
                ((fail_count++))
                rm -f "$output_file"
            else
                echo -e "${C_GREEN}  ✓ DONE (${size_mb}MB, ${total_duration}s)${C_NC}"
                ((success_count++))
            fi
        fi
    else
        echo -e "${C_RED}  ✗ FAILED (see $log_file)${C_NC}"
        ((fail_count++))
    fi

    rm -f "$manifest"
}

# --- FIND ALL FOLDERS RECURSIVELY (excluding .duplicates) ---
mapfile -t all_folders < <(
    find "$SRC_PATH" -mindepth 1 -type d ! -name ".duplicates" | sort
)

if [[ ${#all_folders[@]} -eq 0 ]]; then
    echo -e "${C_YELLOW}No folders found${C_NC}"
    exit 0
fi

echo -e "${C_CYAN}Found ${#all_folders[@]} folder(s) to process${C_NC}"
echo ""

# --- MAIN LOOP ---
for folder in "${all_folders[@]}"; do
    set +e
    process_folder "$folder"
    set -e
done

echo ""
echo -e "${C_CYAN}>>> ALL JOBS FINISHED <<<${C_NC}"
echo -e "${C_GREEN}✓ Success: $success_count${C_NC} | ${C_YELLOW}⊘ Skipped: $skip_count${C_NC} | ${C_RED}✗ Failed: $fail_count${C_NC}"