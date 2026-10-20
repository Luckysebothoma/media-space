#!/bin/bash

set -euo pipefail

# ==============================
# CONFIG
# ==============================
LOG_DIR="./logs"
PID_FILE="/tmp/ffmpeg_toolbox.pid"
REFRESH_INTERVAL=2
PROGRESS_LOG_DIR="/tmp/ffmpeg_progress"

mkdir -p "$LOG_DIR"
mkdir -p "$PROGRESS_LOG_DIR"

# ==============================
# HELPERS
# ==============================

print_header() {
    clear
    echo "========================================"
    echo "       🎬 FFmpeg Toolbox v2.0"
    echo "========================================"
    echo "Time: $(date)"
    echo ""
}

get_ffmpeg_pids() {
    pgrep -x ffmpeg || true
}

get_ffmpeg_info() {
    ps -eo pid,user,%cpu,%mem,etime,cmd | grep ffmpeg | grep -v grep || true
}

# ==============================
# CAPTURE FFMPEG OUTPUT
# ==============================

# Restart ffmpeg monitoring with proper stderr capture
start_progress_monitor() {
    local pid=$1
    local log_file="$PROGRESS_LOG_DIR/ffmpeg_${pid}.log"
    
    # Kill any existing tail process for this PID
    pkill -f "tail.*ffmpeg_${pid}.log" 2>/dev/null || true
    
    # Start capturing stderr in background
    tail -f /proc/$pid/fd/2 2>/dev/null >> "$log_file" &
}

# ==============================
# PROGRESS & ETA CALCULATION
# ==============================

parse_ffmpeg_progress() {
    local log_file=$1
    
    if [ ! -f "$log_file" ]; then
        echo ""
        return
    fi
    
    # Get the last progress line
    local last_line=$(tail -1 "$log_file" 2>/dev/null || echo "")
    
    # Extract time= value (format: time=HH:MM:SS.ms)
    local current_time=$(echo "$last_line" | grep -oP 'time=\K[0-9:.]+' || echo "")
    
    echo "$current_time"
}

time_to_seconds() {
    local time_str=$1
    
    if [ -z "$time_str" ]; then
        echo "0"
        return
    fi
    
    # Handle format HH:MM:SS or MM:SS or SS
    local hours=0 minutes=0 seconds=0
    
    if [[ $time_str =~ ^([0-9]+):([0-9]+):([0-9.]+)$ ]]; then
        hours=${BASH_REMATCH[1]}
        minutes=${BASH_REMATCH[2]}
        seconds=${BASH_REMATCH[3]}
    elif [[ $time_str =~ ^([0-9]+):([0-9.]+)$ ]]; then
        minutes=${BASH_REMATCH[1]}
        seconds=${BASH_REMATCH[2]}
    else
        seconds=$time_str
    fi
    
    local total=$(awk "BEGIN { printf \"%.0f\", ($hours * 3600) + ($minutes * 60) + $seconds }")
    echo "$total"
}

extract_duration_from_cmd() {
    local cmd=$1
    
    # Look for -t parameter (duration in seconds)
    if echo "$cmd" | grep -qP '\s-t\s+\d+'; then
        echo "$cmd" | grep -oP '(?<=-t\s)\d+' | head -1
    else
        echo "0"
    fi
}

calculate_speed() {
    local log_file=$1
    local prev_file="${log_file}.prev"
    
    if [ ! -f "$prev_file" ] || [ ! -f "$log_file" ]; then
        echo "0"
        return
    fi
    
    local prev_time=$(cat "$prev_file" 2>/dev/null || echo "0")
    local current_time=$(tail -1 "$log_file" 2>/dev/null | grep -oP 'time=\K[0-9:.]+' || echo "0")
    
    current_time=$(time_to_seconds "$current_time")
    prev_time=$(time_to_seconds "$prev_time")
    
    local diff=$(awk "BEGIN { printf \"%.2f\", $current_time - $prev_time }")
    echo "$diff"
}

# ==============================
# STATUS
# ==============================

show_status() {
    print_header
    echo "📊 Current FFmpeg Processes:"
    echo ""

    if ! get_ffmpeg_pids | grep -q .; then
        echo "✅ No ffmpeg processes running"
        return
    fi

    get_ffmpeg_info
}

# ==============================
# ADVANCED PROGRESS
# ==============================

show_progress() {
    print_header
    echo "⏳ FFmpeg Progress & ETA"
    echo ""

    PIDS=$(get_ffmpeg_pids)

    if [ -z "$PIDS" ]; then
        echo "⚠️  No running ffmpeg process."
        return
    fi

    for PID in $PIDS; do
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "📹 PID: $PID"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

        # Get the full command line
        CMD=$(ps -p $PID -o args= 2>/dev/null || echo "")
        
        if [ -z "$CMD" ]; then
            echo "❌ Process not found or terminated"
            continue
        fi

        # Extract duration from command
        TOTAL_SEC=$(extract_duration_from_cmd "$CMD")
        
        # Get progress log file
        LOG_FILE="$PROGRESS_LOG_DIR/ffmpeg_${PID}.log"
        
        # Extract current time from log
        CURRENT_TIME=$(parse_ffmpeg_progress "$LOG_FILE")
        CURRENT_SEC=$(time_to_seconds "$CURRENT_TIME")

        echo "Command: ${CMD:0:100}..."
        echo ""
        
        if [ "$TOTAL_SEC" -eq 0 ]; then
            echo "⚠️  Duration not specified (-t parameter not found)"
            echo "Current time: $CURRENT_TIME (${CURRENT_SEC}s)"
        else
            # Calculate progress percentage
            if [ "$CURRENT_SEC" -gt 0 ]; then
                PERCENT=$(awk "BEGIN { printf \"%.1f\", ($CURRENT_SEC / $TOTAL_SEC) * 100 }")
                REMAINING_SEC=$(awk "BEGIN { printf \"%.0f\", $TOTAL_SEC - $CURRENT_SEC }")
                
                # Create progress bar
                FILLED=$((PERCENT / 5))
                EMPTY=$((20 - FILLED))
                PROGRESS_BAR="["
                for ((i=0; i<FILLED; i++)); do PROGRESS_BAR+="█"; done
                for ((i=0; i<EMPTY; i++)); do PROGRESS_BAR+="░"; done
                PROGRESS_BAR+="]"
                
                echo "Progress: $PROGRESS_BAR $PERCENT%"
                echo ""
                echo "⏱️  Current:  $CURRENT_TIME ($CURRENT_SEC sec)"
                echo "⏱️  Total:    $(printf '%02d:%02d:%02d' $((TOTAL_SEC/3600)) $((TOTAL_SEC%3600/60)) $((TOTAL_SEC%60)))"
                echo "⏱️  Remaining: $(printf '%02d:%02d:%02d' $((REMAINING_SEC/3600)) $((REMAINING_SEC%3600/60)) $((REMAINING_SEC%60)))"
                
                # Show CPU and Memory
                STATS=$(ps -p $PID -o %cpu=,%mem= 2>/dev/null || echo "0 0")
                CPU=$(echo "$STATS" | awk '{print $1}')
                MEM=$(echo "$STATS" | awk '{print $2}')
                
                echo ""
                echo "💾 CPU: ${CPU}% | Memory: ${MEM}%"
            else
                echo "⏱️  Current:  $CURRENT_TIME (waiting for output...)"
                echo "⏱️  Total:    $(printf '%02d:%02d:%02d' $((TOTAL_SEC/3600)) $((TOTAL_SEC%3600/60)) $((TOTAL_SEC%60)))"
                echo "💡 Tip: Progress data should appear shortly..."
            fi
        fi

        echo ""
    done
}

# ==============================
# LIVE MONITOR
# ==============================

monitor_live() {
    # First, start capturing logs for all ffmpeg processes
    for PID in $(get_ffmpeg_pids); do
        start_progress_monitor $PID
    done

    while true; do
        print_header
        echo "📡 Live FFmpeg Monitor (refresh ${REFRESH_INTERVAL}s)"
        echo ""

        PIDS=$(get_ffmpeg_pids)
        
        if [ -z "$PIDS" ]; then
            echo "✅ No ffmpeg processes running"
            sleep $REFRESH_INTERVAL
            continue
        fi

        for PID in $PIDS; do
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo "PID: $PID"
            
            STATS=$(ps -p $PID -o pid,user,%cpu,%mem,etime,cmd 2>/dev/null | tail -1 || echo "")
            echo "$STATS"
            
            # Show progress if available
            LOG_FILE="$PROGRESS_LOG_DIR/ffmpeg_${PID}.log"
            if [ -f "$LOG_FILE" ]; then
                LAST_PROGRESS=$(tail -1 "$LOG_FILE" 2>/dev/null | grep -oP 'time=\K[0-9:.]+' || echo "")
                if [ -n "$LAST_PROGRESS" ]; then
                    echo "Last progress: $LAST_PROGRESS"
                fi
            fi
            echo ""
        done

        sleep $REFRESH_INTERVAL
    done
}

# ==============================
# TOP VIEW (filtered)
# ==============================

top_view() {
    print_header
    echo "🔥 Top View (Filtered for FFmpeg)"
    echo ""

    top -o %CPU -b -n 1 | grep -E "PID|ffmpeg"
}

# ==============================
# STOP
# ==============================

stop_ffmpeg() {
    print_header
    echo "🛑 Stopping FFmpeg processes..."

    PIDS=$(get_ffmpeg_pids)

    if [ -z "$PIDS" ]; then
        echo "No ffmpeg processes found."
        return
    fi

    echo "Found PIDs: $PIDS"
    echo ""

    read -p "Kill (1) Graceful or (2) Force? [1/2]: " mode

    if [ "$mode" == "2" ]; then
        kill -9 $PIDS
        echo "🔥 Force killed!"
    else
        kill $PIDS
        echo "✅ Graceful stop signal sent."
    fi
}

# ==============================
# CLEANUP
# ==============================

cleanup_logs() {
    print_header
    echo "🧹 Cleaning up old progress logs..."
    
    # Remove logs older than 1 hour
    find "$PROGRESS_LOG_DIR" -name "*.log" -mmin +60 -delete
    
    echo "✅ Cleanup complete"
}

# ==============================
# MENU
# ==============================

menu() {
    while true; do
        print_header
        echo "Choose an option:"
        echo ""
        echo "1) Show Status"
        echo "2) Live Monitor"
        echo "3) Show Progress & ETA"
        echo "4) Stop FFmpeg"
        echo "5) Top View"
        echo "6) Cleanup Logs"
        echo "7) Exit"
        echo ""

        read -p "Enter choice: " choice

        case $choice in
            1) show_status; read -p "Press enter..." ;;
            2) monitor_live ;;
            3) show_progress; read -p "Press enter..." ;;
            4) stop_ffmpeg; read -p "Press enter..." ;;
            5) top_view; read -p "Press enter..." ;;
            6) cleanup_logs; read -p "Press enter..." ;;
            7) exit 0 ;;
            *) echo "Invalid option"; sleep 1 ;;
        esac
    done
}

# ==============================
# CLI MODE
# ==============================

case "${1:-}" in
    status)
        show_status
        ;;
    monitor)
        monitor_live
        ;;
    progress)
        show_progress
        ;;
    stop)
        stop_ffmpeg
        ;;
    top)
        top_view
        ;;
    cleanup)
        cleanup_logs
        ;;
    *)
        menu
        ;;
esac
