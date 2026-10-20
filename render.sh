#!/bin/bash
################################################################################
# Media Composer Lite - Reliable Image-to-Video Engine
# Optimized for Debian 12 (Bookworm)
################################################################################

set -euo pipefail

# --- CONFIGURATION ---
DATE_STAMP=$(date +%Y%m%d_%H%M%S)
OUTPUT_BASE="./archives"
LOG_DIR="./.logs"
mkdir -p "$OUTPUT_BASE" "$LOG_DIR"

# --- COLORS ---
C_GREEN='\033[0;32m'
C_RED='\033[0;31m'
C_CYAN='\033[0;36m'
C_NC='\033[0m'

# --- CLEANUP ---
cleanup() {
    rm -f ffmpeg_list_*.txt
}
trap cleanup EXIT

# --- CORE FUNCTIONS ---

scan_and_render() {
    local source_dir="$1"
    local preset="$2"

    # 1. Resolve absolute path
    source_dir=$(realpath "$source_dir")
    echo -e "${C_CYAN}[INFO]${C_NC} Scanning: $source_dir"

    # 2. Find subdirectories containing images
    mapfile -t folders < <(find "$source_dir" -maxdepth 1 -type d ! -path "$source_dir" | sort)

    if [[ ${#folders[@]} -eq 0 ]]; then
        echo -e "${C_RED}[ERR]${C_NC} No subdirectories found in $source_dir"
        exit 1
    fi

    echo -e "${C_GREEN}[OK]${C_NC} Found ${#folders[@]} folders. starting render..."

    for folder in "${folders[@]}"; do
        local folder_name=$(basename "$folder")
        local output_file="${OUTPUT_BASE}/${folder_name}_${DATE_STAMP}.mp4"
        local manifest="ffmpeg_list_${BASHPID}.txt"
        
        echo -e "\n${C_CYAN}--------------------------------------------------${C_NC}"
        echo -e "Processing: ${C_CYAN}$folder_name${C_NC}"

        # 3. Create Manifest
        find "$folder" -maxdepth 1 -type f \( -iname "*.jpg" -o -iname "*.png" -o -iname "*.jpeg" \) | sort | while read -r img; do
            echo "file '$img'"
            echo "duration 3"
        done > "$manifest"

        # Concat requirement: Repeat last file
        tail -n 2 "$manifest" >> "$manifest" 2>/dev/null || true

        if [[ ! -s "$manifest" ]]; then
            echo -e "${C_RED}[SKIP]${C_NC} No images found in $folder_name"
            rm -f "$manifest"
            continue
        fi

        # 4. Define Preset (CRF 23 = Standard, 18 = High)
        local width=1920 height=1080 crf=23
        [[ "$preset" == "high" ]] && crf=18

        # 5. Execute FFmpeg
        # Using libx264 for maximum compatibility on Debian
        if ffmpeg -y -hide_banner -loglevel error -stats \
            -f concat -safe 0 -i "$manifest" \
            -vf "scale=w=$width:h=$height:force_original_aspect_ratio=decrease,pad=w=$width:h=$height:x=(ow-iw)/2:y=(oh-ih)/2,fps=24" \
            -c:v libx264 -crf $crf -preset medium -pix_fmt yuv420p \
            -movflags +faststart "$output_file"; then
            echo -e "${C_GREEN}[SUCCESS]${C_NC} Rendered: $output_file"
        else
            echo -e "${C_RED}[FAILED]${C_NC} Check images in $folder_name"
        fi

        rm -f "$manifest"
    done
}

# --- INTERACTIVE INTERFACE ---

clear
echo -e "${C_CYAN}==================================================${C_NC}"
echo -e "           MEDIA COMPOSER LITE v1.0               "
echo -e "${C_CYAN}==================================================${C_NC}"

read -p "Enter Source Directory Path: " SRC_PATH
if [[ ! -d "$SRC_PATH" ]]; then
    echo -e "${C_RED}Error: Directory not found.${C_NC}"
    exit 1
fi

echo -e "\nSelect Quality:"
echo "1) Standard (1080p, CRF 23)"
echo "2) High Quality (1080p, CRF 18)"
read -p "Choice [1-2]: " Q_CHOICE

PRESET_VAL="standard"
[[ "$Q_CHOICE" == "2" ]] && PRESET_VAL="high"

# Run the engine
scan_and_render "$SRC_PATH" "$PRESET_VAL"

echo -e "\n${C_GREEN}All tasks completed.${C_NC}"
