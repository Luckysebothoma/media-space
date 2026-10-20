#!/bin/bash
clear
echo '################################################################################'
echo '# MEDIA HANDLER V6: Clean Hierarchical Grouping'
echo '# 1. Group by YYYYMMDD (day)'
echo '# 2. Within day, group by hour (YYYYMMDD_HH)'
echo '# 3. Ungrouped singles within day -> stay in day folder'
echo '# 4. Remaining singles -> group by month -> year'
echo '################################################################################'

set -u

# ============================================================================
# 1. CONFIGURATION & ARGUMENT PARSING
# ============================================================================

TARGET_DIR=""
DRY_RUN=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        *)
            TARGET_DIR="$1"
            shift
            ;;
    esac
done

if [[ -z "$TARGET_DIR" ]]; then
    echo "ERROR: No target directory specified"
    echo "Usage: $0 [--dry-run] <target_dir>"
    exit 1
fi

if [[ ! -d "$TARGET_DIR" ]]; then
    echo "ERROR: Directory does not exist: $TARGET_DIR"
    exit 1
fi

# ============================================================================
# 2. LOGGING & UTILITY FUNCTIONS
# ============================================================================

log() {
    local level="$1"
    shift
    echo "$(date '+%Y-%m-%d %H:%M:%S') [$level] $*"
}

safe_mkdir() {
    local dir="$1"
    if [[ "$DRY_RUN" == true ]]; then
        log "DRY" "mkdir -p '$dir'"
    else
        mkdir -p "$dir"
    fi
}

safe_move() {
    local src="$1"
    local dst="$2"
    if [[ "$DRY_RUN" == true ]]; then
        log "DRY" "mv '$(basename "$src")' -> '$(basename "$dst")'"
    else
        mv "$src" "$dst"
    fi
}

human_readable() {
    local bytes=$1
    if (( bytes > 1073741824 )); then
        echo "$(awk "BEGIN {printf \"%.2f\", $bytes/1073741824}")GB"
    elif (( bytes > 1048576 )); then
        echo "$(awk "BEGIN {printf \"%.2f\", $bytes/1048576}")MB"
    elif (( bytes > 1024 )); then
        echo "$(awk "BEGIN {printf \"%.2f\", $bytes/1024}")KB"
    else
        echo "${bytes}B"
    fi
}

extract_datetime() {
    local fname="$1"
    # Extract YYYYMMDD from filename (YYYYMMDD_HHMMSS format)
    if [[ "$fname" =~ ^([0-9]{8})_ ]]; then
        echo "${BASH_REMATCH[1]}"
    else
        echo ""
    fi
}

extract_hour() {
    local fname="$1"
    # Extract HH from YYYYMMDD_HHMMSS format
    if [[ "$fname" =~ ^[0-9]{8}_([0-9]{2})[0-9]{4} ]]; then
        echo "${BASH_REMATCH[1]}"
    else
        echo ""
    fi
}

get_file_hash() {
    local file="$1"
    md5sum "$file" | awk '{print $1}'
}

get_file_size() {
    local file="$1"
    stat -c%s "$file" 2>/dev/null || stat -f%z "$file" 2>/dev/null || echo 0
}

move_file_to_dir() {
    local file="$1"
    local group_dir="$2"
    local file_hash="${FILE_HASHES[$file]}"
    
    if [[ -v "DUPLICATE_GROUP[$file_hash]" ]]; then
        IFS='|' read -ra dup_files <<< "${HASH_TO_FILES["$file_hash"]}"
        unset 'dup_files[-1]'
        
        if [[ "${dup_files[0]}" == "$file" ]]; then
            log "MOVE" "$(basename "$file") -> $(basename "$group_dir")/ [ORIGINAL]"
            safe_move "$file" "$group_dir/$(basename "$file")"
        else
            dup_dir="${group_dir}/.duplicates"
            safe_mkdir "$dup_dir"
            log "MOVE" "$(basename "$file") -> $(basename "$group_dir")/.duplicates/ [DUPLICATE]"
            safe_move "$file" "$dup_dir/$(basename "$file")"
        fi
    else
        log "MOVE" "$(basename "$file") -> $(basename "$group_dir")/"
        safe_move "$file" "$group_dir/$(basename "$file")"
    fi
}

# ============================================================================
# 3. MEDIA DISCOVERY
# ============================================================================

log "INIT" "=== Clean Hierarchical Media Grouping V6 ==="
[[ "$DRY_RUN" == true ]] && log "INIT" "DRY-RUN MODE ENABLED"
log "INFO" "Target directory: $TARGET_DIR"

mapfile -t ALL_VIDEOS < <(find "$TARGET_DIR" -type f \( -iname "*.mp4" -o -iname "*.mkv" -o -iname "*.mov" -o -iname "*.avi" -o -iname "*.flv" -o -iname "*.wmv" \))
mapfile -t ALL_IMAGES < <(find "$TARGET_DIR" -type f \( -iname "*.jpg" -o -iname "*.jpeg" -o -iname "*.png" -o -iname "*.gif" -o -iname "*.bmp" -o -iname "*.webp" \))

log "INFO" "Found ${#ALL_VIDEOS[@]} videos and ${#ALL_IMAGES[@]} images"

all_media=("${ALL_VIDEOS[@]}" "${ALL_IMAGES[@]}")

if [[ ${#all_media[@]} -eq 0 ]]; then
    log "WARN" "No media files found in directory"
    log "FINISH" "Search complete."
    exit 0
fi

# ============================================================================
# 4. COMPUTE HASHES AND DETECT DUPLICATES
# ============================================================================

declare -A FILE_HASHES
declare -A HASH_TO_FILES
declare -A DUPLICATE_GROUP
declare -A FILES_MOVED

log "INFO" "Computing file hashes for duplicate detection..."
hash_count=0

for file in "${all_media[@]}"; do
    file_hash=$(get_file_hash "$file")
    FILE_HASHES["$file"]="$file_hash"
    HASH_TO_FILES["$file_hash"]+="$file|"
    ((hash_count++))
    
    if (( hash_count % 50 == 0 )); then
        log "INFO" "Processed $hash_count files..."
    fi
done

log "INFO" "Hash computation complete."

# Detect duplicates
dup_count=0
for hash in "${!HASH_TO_FILES[@]}"; do
    IFS='|' read -ra files <<< "${HASH_TO_FILES["$hash"]}"
    unset 'files[-1]'
    
    if [[ ${#files[@]} -gt 1 ]]; then
        ((dup_count++))
        DUPLICATE_GROUP["$hash"]=1
    fi
done

# ============================================================================
# 5. ORGANIZE BY DAY, THEN HOUR WITHIN DAY
# ============================================================================

declare -A DAY_GROUPS
declare -A DAY_HOUR_GROUPS
declare -A DAY_HOUR_SIZE

log "INFO" "=== Stage 1: Organizing by DAY then HOUR ==="

# First pass: organize all dated files by day and hour
for file in "${all_media[@]}"; do
    fname=$(basename "$file")
    datetime=$(extract_datetime "$fname")
    hour=$(extract_hour "$fname")
    
    if [[ -z "$datetime" ]]; then
        continue
    fi
    
    # Add to day group
    DAY_GROUPS["$datetime"]+="$file|"
    
    # Add to hour subgroup within day
    if [[ -n "$hour" ]]; then
        hour_key="${datetime}_${hour}"
        DAY_HOUR_GROUPS["$hour_key"]+="$file|"
        size=$(get_file_size "$file")
        DAY_HOUR_SIZE["$hour_key"]=$((${DAY_HOUR_SIZE["$hour_key"]:-0} + size))
    fi
done

# Determine base grouped directory
#timestamp=$(date '+%d_%m_%H_%M')
#if [[ -d "${TARGET_DIR}/grouped" ]]; then
#    group_base_dir="${TARGET_DIR}/grouped_${timestamp}"
#else
#    group_base_dir="${TARGET_DIR}/grouped"
#fi

group_base_dir="${TARGET_DIR}/grouped"

safe_mkdir "$group_base_dir"

total_groups=0
total_files=0
total_moved_bytes=0

# Process each day
for day_key in $(printf '%s\n' "${!DAY_GROUPS[@]}" | sort -r); do
    IFS='|' read -ra day_files <<< "${DAY_GROUPS["$day_key"]}"
    unset 'day_files[-1]'
    
    day_size=0
    day_count=${#day_files[@]}
    
    # Calculate total size for the day
    for file in "${day_files[@]}"; do
        size=$(get_file_size "$file")
        day_size=$((day_size + size))
    done
    
    if [[ $day_count -eq 0 ]]; then
        continue
    fi
    
    # Create day folder
    size_gb=$(awk "BEGIN {printf \"%.1f\", $day_size/1073741824}")
    if [[ "$size_gb" == "0.0" ]]; then
        size_mb=$(awk "BEGIN {printf \"%.0f\", $day_size/1048576}")
        day_dir_name="${day_key}__${day_count}_${size_mb}mb"
    else
        day_dir_name="${day_key}__${day_count}_${size_gb}gb"
    fi
    
    day_dir="${group_base_dir}/${day_dir_name}"
    safe_mkdir "$day_dir"
    
    log "FOUND" "📁 DAY: $day_key | $day_count file(s) ($(human_readable "$day_size"))"
    
    # Process hours within this day
    declare -A hour_files_in_day
    declare -A hour_processed
    
    # Find all hours for this day
    for hour_key in $(printf '%s\n' "${!DAY_HOUR_GROUPS[@]}" | grep "^${day_key}_" | sort -r); do
        IFS='|' read -ra hour_files <<< "${DAY_HOUR_GROUPS["$hour_key"]}"
        unset 'hour_files[-1]'
        hour_count=${#hour_files[@]}
        hour_size=${DAY_HOUR_SIZE["$hour_key"]}
        
        # Only create hour subfolder if there are multiple files in this hour
        if [[ $hour_count -gt 1 ]]; then
            hour=$(echo "$hour_key" | cut -d'_' -f2)
            size_gb=$(awk "BEGIN {printf \"%.1f\", $hour_size/1073741824}")
            if [[ "$size_gb" == "0.0" ]]; then
                size_mb=$(awk "BEGIN {printf \"%.0f\", $hour_size/1048576}")
                hour_dir_name="${hour_key}__${hour_count}_${size_mb}mb"
            else
                hour_dir_name="${hour_key}__${hour_count}_${size_gb}gb"
            fi
            
            hour_dir="${day_dir}/${hour_dir_name}"
            safe_mkdir "$hour_dir"
            
            log "FOUND" "  └─ HOUR: $hour_key | $hour_count file(s) ($(human_readable "$hour_size"))"
            
            for file in "${hour_files[@]}"; do
                move_file_to_dir "$file" "$hour_dir"
                FILES_MOVED["$file"]=1
                ((total_files++))
                ((total_moved_bytes += $(get_file_size "$file")))
            done
            
            ((total_groups++))
            hour_processed["$hour_key"]=1
        fi
    done
    
    # Move single files within day (not part of any hour group) directly to day folder
    for file in "${day_files[@]}"; do
        if [[ ! -v "FILES_MOVED[$file]" ]]; then
            move_file_to_dir "$file" "$day_dir"
            FILES_MOVED["$file"]=1
            ((total_files++))
            ((total_moved_bytes += $(get_file_size "$file")))
        fi
    done
    
    ((total_groups++))
done

# ============================================================================
# 6. GROUP REMAINING SINGLES BY MONTH THEN YEAR
# ============================================================================

declare -A MONTH_GROUPS
declare -A MONTH_SIZES
declare -A YEAR_GROUPS
declare -A YEAR_SIZES

log "INFO" "=== Stage 2: Grouping remaining singles by MONTH then YEAR ==="

# Collect remaining unmoved files
for file in "${all_media[@]}"; do
    if [[ -v "FILES_MOVED[$file]" ]]; then
        continue
    fi
    
    if [[ ! -f "$file" ]]; then
        continue
    fi
    
    fname=$(basename "$file")
    datetime=$(extract_datetime "$fname")
    
    if [[ -z "$datetime" ]]; then
        continue
    fi
    
    month_key="${datetime:0:6}"
    MONTH_GROUPS["$month_key"]+="$file|"
    size=$(get_file_size "$file")
    MONTH_SIZES["$month_key"]=$((${MONTH_SIZES["$month_key"]:-0} + size))
done

# Process months
for month_key in $(printf '%s\n' "${!MONTH_GROUPS[@]}" | sort -r); do
    IFS='|' read -ra month_files <<< "${MONTH_GROUPS["$month_key"]}"
    unset 'month_files[-1]'
    
    month_count=${#month_files[@]}
    month_size=${MONTH_SIZES["$month_key"]}
    
    if [[ $month_count -gt 0 ]]; then
        size_gb=$(awk "BEGIN {printf \"%.1f\", $month_size/1073741824}")
        if [[ "$size_gb" == "0.0" ]]; then
            size_mb=$(awk "BEGIN {printf \"%.0f\", $month_size/1048576}")
            dir_name="${month_key}__${month_count}_${size_mb}mb"
        else
            dir_name="${month_key}__${month_count}_${size_gb}gb"
        fi
        
        month_dir="${group_base_dir}/${dir_name}"
        safe_mkdir "$month_dir"
        
        log "FOUND" "📁 MONTH: $month_key | $month_count file(s) ($(human_readable "$month_size"))"
        
        for file in "${month_files[@]}"; do
            move_file_to_dir "$file" "$month_dir"
            FILES_MOVED["$file"]=1
            ((total_files++))
            ((total_moved_bytes += $(get_file_size "$file")))
        done
        
        ((total_groups++))
    fi
done

# ============================================================================
# 7. PROCESS TRULY UNDATED FILES
# ============================================================================

log "INFO" "=== Stage 3: Processing undated files ==="

undated_count=0
undated_size=0

for file in "${all_media[@]}"; do
    if [[ -v "FILES_MOVED[$file]" ]]; then
        continue
    fi
    
    if [[ ! -f "$file" ]]; then
        continue
    fi
    
    ((undated_count++))
    size=$(get_file_size "$file")
    undated_size=$((undated_size + size))
done

if [[ $undated_count -gt 0 ]]; then
    size_gb=$(awk "BEGIN {printf \"%.1f\", $undated_size/1073741824}")
    if [[ "$size_gb" == "0.0" ]]; then
        size_mb=$(awk "BEGIN {printf \"%.0f\", $undated_size/1048576}")
        dir_name="undated__${undated_count}_${size_mb}mb"
    else
        dir_name="undated__${undated_count}_${size_gb}gb"
    fi
    
    undated_dir="${group_base_dir}/${dir_name}"
    safe_mkdir "$undated_dir"
    
    log "FOUND" "📁 UNDATED | $undated_count file(s) ($(human_readable "$undated_size"))"
    
    for file in "${all_media[@]}"; do
        if [[ ! -v "FILES_MOVED[$file]" && -f "$file" ]]; then
            move_file_to_dir "$file" "$undated_dir"
            FILES_MOVED["$file"]=1
            ((total_files++))
            ((total_moved_bytes += $(get_file_size "$file")))
        fi
    done
    
    ((total_groups++))
fi

# ============================================================================
# 8. SUMMARY
# ============================================================================

log "FINISH" "Organization complete."
log "FINISH" "Found $total_groups groups ($total_files files)"
if [[ $dup_count -gt 0 ]]; then
    log "FINISH" "Found $dup_count duplicate file(s) - moved to .duplicates folders"
fi
log "FINISH" "Total organized: $(human_readable "$total_moved_bytes")"
if [[ "$DRY_RUN" == true ]]; then
    log "FINISH" "This was a DRY-RUN. No files were modified."
fi