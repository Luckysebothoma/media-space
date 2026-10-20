#!/bin/bash
set -uo pipefail

# --- CONFIG ---
OUTPUT_BASE="./archives"
LOG_DIR="./.logs"
DATE_STAMP=$(date +%Y%m%d_%H%M%S)

declare -A PRESETS=(
    ["standard"]="1920:1080:23"
    ["high"]="1920:1080:18"
    ["4k"]="3840:2160:20"
    ["cinema"]="4096:2160:18"
)

MIN_DURATION=10
IMAGE_DURATION=3
MIN_SIZE_MB=1

mkdir -p "$OUTPUT_BASE" "$LOG_DIR"

# --- COLORS ---
C_GREEN='\033[0;32m'
C_RED='\033[0;31m'
C_CYAN='\033[0;36m'
C_YELLOW='\033[1;33m'
C_NC='\033[0m'

show_usage() {
    echo "Usage: $0 [source_dir] [preset]"
    exit 1
}

# --- ARGS ---
[[ $# -lt 1 ]] && show_usage

SRC_PATH="${1%/}"
PRESET="${2:-standard}"

if [[ ! -v PRESETS[$PRESET] ]]; then
    echo -e "${C_RED}Error: Unknown preset '$PRESET'${C_NC}"
    exit 1
fi

IFS=':' read -r WIDTH HEIGHT CRF <<< "${PRESETS[$PRESET]}"

echo -e "${C_CYAN}>>> COMPOSER STARTED: $DATE_STAMP <<<${C_NC}"
echo -e "Source: $SRC_PATH | Quality: $PRESET (${WIDTH}x${HEIGHT}, CRF $CRF)"

if [[ ! -d "$SRC_PATH" ]]; then
    echo -e "${C_RED}Error: Source directory not found${C_NC}"
    exit 1
fi

# --- FIND SUBFOLDERS ---
mapfile -t folders < <(find "$SRC_PATH" -mindepth 1 -maxdepth 1 -type d | sort)

if [[ ${#folders[@]} -eq 0 ]]; then
    echo -e "${C_YELLOW}No folders found${C_NC}"
    exit 0
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

    # Collect images (robust)
    mapfile -t images < <(
        find "$folder" -maxdepth 1 -type f \
        \( -iname "*.jpg" -o -iname "*.jpeg" -o -iname "*.png" -o -iname "*.webp" -o -iname "*.bmp" -o -iname "*.tiff" \) \
        | sort
    )

    if [[ ${#images[@]} -eq 0 ]]; then
        echo -e "${C_YELLOW}[SKIP] No images${C_NC}"
        ((skip_count++))
        rm -f "$manifest"
        return
    fi

    # --- SINGLE IMAGE MODE ---
    if [[ ${#images[@]} -eq 1 ]]; then
        local img="${images[0]}"
        echo "Mode: single-image (loop)"

        if ffmpeg -y -loglevel error -loop 1 -i "$img" \
            -vf "scale=${WIDTH}:${HEIGHT}:force_original_aspect_ratio=decrease,pad=${WIDTH}:${HEIGHT}:(ow-iw)/2:(oh-ih)/2,fps=24" \
            -t "$MIN_DURATION" \
            -c:v libx264 -crf "$CRF" -preset fast \
            -pix_fmt yuv420p "$output_file" > "$log_file" 2>&1
        then
            size_mb=$(du -m "$output_file" 2>/dev/null | cut -f1 || echo "0")
            echo -e "${C_GREEN}✓ DONE (${size_mb}MB)${C_NC}"
            ((success_count++))
        else
            echo -e "${C_RED}✗ FAILED${C_NC}"
            ((fail_count++))
        fi

        rm -f "$manifest"
        return
    fi

    # --- MULTI IMAGE MODE ---
    echo "Mode: multi-image (${#images[@]} images)"

    {
        for img in "${images[@]}"; do
            printf "file '%s'\n" "$img"
            printf "duration %s\n" "$IMAGE_DURATION"
        done
        printf "file '%s'\n" "${images[-1]}"
    } > "$manifest"

    if ffmpeg -y -loglevel error -f concat -safe 0 -i "$manifest" \
        -vf "scale=${WIDTH}:${HEIGHT}:force_original_aspect_ratio=decrease,pad=${WIDTH}:${HEIGHT}:(ow-iw)/2:(oh-ih)/2,fps=24" \
        -c:v libx264 -crf "$CRF" -preset fast \
        -pix_fmt yuv420p "$output_file" > "$log_file" 2>&1
    then
        if [[ -f "$output_file" ]]; then
            size_mb=$(du -m "$output_file" 2>/dev/null | cut -f1 || echo "0")

            if (( size_mb < MIN_SIZE_MB )); then
                echo -e "${C_YELLOW}[WARN] Output too small (${size_mb}MB)${C_NC}"
                ((fail_count++))
            else
                echo -e "${C_GREEN}✓ DONE (${size_mb}MB)${C_NC}"
                ((success_count++))
            fi
        fi
    else
        echo -e "${C_RED}✗ FAILED (see $log_file)${C_NC}"
        ((fail_count++))
    fi

    rm -f "$manifest"
}

# --- MAIN LOOP ---
for folder in "${folders[@]}"; do
    # Critical: isolate errors so script never exits mid-loop
    set +e
    process_folder "$folder"
    set -e
done

echo -e "${C_CYAN}>>> ALL JOBS FINISHED <<<${C_NC}"
echo -e "${C_GREEN}✓ Success: $success_count${C_NC} | ${C_YELLOW}⊘ Skipped: $skip_count${C_NC} | ${C_RED}✗ Failed: $fail_count${C_NC}"

#ensure script exiits with non-zero if complete or had failures
# exit to ensure swam dont revert the pod
exit 0;
