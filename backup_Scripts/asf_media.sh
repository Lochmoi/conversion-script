#!/bin/bash

# .asf media Processing with INTELLIGENT SIZING 
# Features:
# - Converts .asf files to .mp4 and splits into 10-minute chunks
# - Handles SNTV, SNLTV, and SNTVDALJIR file naming conventions
# - INTELLIGENT SIZING: 42MB target per chunk 
# - Processing mp3 files (disabled but ready for future use)
# - Concurrent file processing with job id tracking
# - Archives files after processing

# Lock file to prevent multiple instances
LOCKFILE="/var/run/asf_media_processor.lock"

# Check if lockfile exists and if the process is running
if [ -f "$LOCKFILE" ]; then
    LOCK_PID=$(cat "$LOCKFILE" 2>/dev/null)
    if [ -n "$LOCK_PID" ] && kill -0 "$LOCK_PID" 2>/dev/null; then
        echo "[ERROR] Script already running with PID $LOCK_PID, exiting"
        exit 1
    else
        echo "[INFO] Removing stale lockfile"
        rm -f "$LOCKFILE"
    fi
fi

# Create lockfile with current PID
echo $$ > "$LOCKFILE"
trap "rm -f $LOCKFILE" EXIT

# Exit on any error
set -e

# =========================================================================
# CONFIGURATION
# =========================================================================
SOURCE_DIR="/home/ftp_so/Somalia_Region_recordings"    # Directory containing source .asf files
UPLOAD_DIR="/home/micah/upload_ready"                   # Directory for processed chunks
MOTHER_DIR="/home/malawi/mother"                        # Archive directory for originals
CHUNK_LEN=600                                            # Length in seconds (10 minutes)
MAX_PARALLEL_JOBS=4                                      # Maximum concurrent processing jobs

# Processing options
MOVE_ORIGINAL_AFTER_PROCESSING=true         # Move originals to archive after successful processing
DELETE_TEMP_MP4_AFTER_SPLITTING=true        # Delete temporary MP4 after splitting

# Video encoding settings (for ASF to MP4 conversion)
VIDEO_CODEC="libx264"
VIDEO_PRESET="ultrafast"                    # ultrafast, superfast, veryfast, faster, fast, medium
VIDEO_SCALE="-2:480"                         # Scale to 480p height, width auto-calculated
VIDEO_FPS=30                                 # Target FPS
AUDIO_CODEC="aac"

# =========================================================================
# SIZE CONTROL: Choose your mode
# =========================================================================
USE_COPY_MODE=false                        # true = ULTRA-FAST (stream copy, ~2 min/hour, no size reduction)
USE_FAST_MODE=true                         # true = FAST (re-encode, ~15 min/hour, 42MB chunks) ← RECOMMENDED
                                           # false = INTELLIGENT (2-pass, ~55 min/hour, best quality)

# Fast mode settings
MAX_CHUNK_SIZE_MB=42                       # Maximum size per 10-minute chunk
FIXED_VIDEO_BITRATE="478k"                 # Fixed video bitrate for 42MB target
FIXED_AUDIO_BITRATE="96k"                  # Fixed audio bitrate

# Intelligent mode settings
TARGET_SIZE_RATIO=0.65                     # Output = 65% of source size
MIN_VIDEO_BITRATE="400k"                   # Minimum video bitrate
MAX_VIDEO_BITRATE="3000k"                  # Maximum video bitrate

# =========================================================================
# LOGGING FUNCTIONS
# =========================================================================
echo_info() { 
    echo -e "\033[0;36m[INFO]\033[0m $1" 
}

echo_success() { 
    echo -e "\033[0;32m[SUCCESS]\033[0m $1" 
}

echo_warning() { 
    echo -e "\033[0;33m[WARNING]\033[0m $1" 
}

echo_error() { 
    echo -e "\033[0;31m[ERROR]\033[0m $1" 
}

echo_progress() {
    echo -e "\033[0;35m[PROGRESS]\033[0m $1"
}

echo_debug() {
    echo -e "\033[0;90m[DEBUG]\033[0m $1"
}

# =========================================================================
# UTILITY FUNCTIONS
# =========================================================================

# Check if a file is a valid media file
is_media_file() {
    local file="$1"
    if [ ! -f "$file" ]; then
        return 1
    fi
    ffmpeg -i "$file" -hide_banner 2>&1 | grep -q "Duration" && return 0 || return 1
}

# Get duration with MULTIPLE fallback methods
get_duration_seconds() {
    local file="$1"
    local duration_seconds=0
    
    # Method 1: Try ffprobe first (most reliable for file metadata)
    if command -v ffprobe &> /dev/null; then
        duration_seconds=$(ffprobe -v error -show_entries format=duration \
            -of default=noprint_wrappers=1:nokey=1 "$file" 2>/dev/null | cut -d '.' -f 1)
        
        if [ -n "$duration_seconds" ] && [ "$duration_seconds" -gt 0 ] 2>/dev/null; then
            echo "$duration_seconds"
            return 0
        fi
    fi
    
    # Method 2: Try ffmpeg with Duration field
    local duration_hms=$(ffmpeg -i "$file" 2>&1 | grep "Duration:" | head -n1 | cut -f 4 -d ' ' | tr -d ',')
    
    if [ -n "$duration_hms" ] && [[ "$duration_hms" != *"N/A"* ]]; then
        # Parse HH:MM:SS.ms
        local h=$(echo "$duration_hms" | cut -d ':' -f 1)
        local m=$(echo "$duration_hms" | cut -d ':' -f 2)
        local s=$(echo "$duration_hms" | cut -d ':' -f 3 | cut -d '.' -f 1)
        
        # Remove leading zeros
        h=$(echo "$h" | sed 's/^0*\([0-9]\)/\1/'); h=${h:-0}
        m=$(echo "$m" | sed 's/^0*\([0-9]\)/\1/'); m=${m:-0}
        s=$(echo "$s" | sed 's/^0*\([0-9]\)/\1/'); s=${s:-0}
        
        # Validate they're numbers
        if [[ "$h" =~ ^[0-9]+$ ]] && [[ "$m" =~ ^[0-9]+$ ]] && [[ "$s" =~ ^[0-9]+$ ]]; then
            duration_seconds=$(( (h * 60 + m) * 60 + s ))
            if [ "$duration_seconds" -gt 0 ]; then
                echo "$duration_seconds"
                return 0
            fi
        fi
    fi
    
    # Method 3: Try to get duration by actually probing the file more aggressively
    local probe_duration=$(ffmpeg -i "$file" -f null - 2>&1 | grep "time=" | tail -n1 | sed 's/.*time=\([0-9:\.]*\).*/\1/')
    if [ -n "$probe_duration" ]; then
        local h=$(echo "$probe_duration" | cut -d ':' -f 1)
        local m=$(echo "$probe_duration" | cut -d ':' -f 2)
        local s=$(echo "$probe_duration" | cut -d ':' -f 3 | cut -d '.' -f 1)
        
        h=$(echo "$h" | sed 's/^0*\([0-9]\)/\1/'); h=${h:-0}
        m=$(echo "$m" | sed 's/^0*\([0-9]\)/\1/'); m=${m:-0}
        s=$(echo "$s" | sed 's/^0*\([0-9]\)/\1/'); s=${s:-0}
        
        if [[ "$h" =~ ^[0-9]+$ ]] && [[ "$m" =~ ^[0-9]+$ ]] && [[ "$s" =~ ^[0-9]+$ ]]; then
            duration_seconds=$(( (h * 60 + m) * 60 + s ))
            if [ "$duration_seconds" -gt 0 ]; then
                echo "$duration_seconds"
                return 0
            fi
        fi
    fi
    
    # All methods failed
    echo "0"
    return 1
}

# Generate chunk name for SNTV/SNLTV/SNTVDALJIR files
generate_somalia_tv_chunk_name() {
    local base="$1"
    local chunk_index="$2"
    local extension="$3"
    
    # Extract components from filename (updated regex to handle SNTVDALJIR)
    local date=$(echo "$base" | sed -E 's/^S[N]*[L]*[T]*[V]*[D]*[A]*[L]*[J]*[I]*[R]*_([0-9]{4}-[0-9]{2}-[0-9]{2})_.*/\1/')
    local hour=$(echo "$base" | sed -E 's/^S[N]*[L]*[T]*[V]*[D]*[A]*[L]*[J]*[I]*[R]*_[0-9]{4}-[0-9]{2}-[0-9]{2}_([0-9]{2})-.*/\1/')
    
    # Compute minute from chunk index
    local idx_num=$(( ($chunk_index - 1) * 10 ))
    local minute=$(printf "%02d" "$idx_num")
    
    # Format date with underscores
    local date_fmt="${date//-/_}"
    
    # Generate appropriate name based on prefix
    if [[ "$base" == SNLTV_* ]]; then
        echo "SO_SLN_${date_fmt}_${hour}-${minute}-03.${extension}"
    elif [[ "$base" == SNTVDALJIR_* ]]; then
        echo "SO_SN2_${date_fmt}_${hour}-${minute}-03.${extension}"
    elif [[ "$base" == SNTV_* ]]; then
        echo "SO_SNT_${date_fmt}_${hour}-${minute}-03.${extension}"
    else
        echo "${base}_chunk_$(printf "%03d" "$chunk_index").${extension}"
    fi
}

# =========================================================================
# ASF PROCESSING FUNCTION (Duration handling)
# =========================================================================

process_asf_file() {
    local asf_filepath="$1"
    local filename=$(basename "$asf_filepath")
    local basename_no_ext="${filename%.*}"
    
    echo_info "=========================================="
    echo_info "Processing ASF: $filename"
    echo_info "=========================================="
    
    # Validate source file
    if [ ! -f "$asf_filepath" ]; then
        echo_error "File does not exist: $asf_filepath"
        return 1
    fi
    
    local filesize=$(stat -c%s "$asf_filepath" 2>/dev/null || echo "0")
    if [ "$filesize" -eq 0 ]; then
        echo_error "File is empty (0 bytes): $filename"
        return 1
    fi
    
    echo_info "Source file size: $((filesize / 1048576)) MB"
    
    # Create unique temporary directory
    local work_dir="/tmp/asf_$$_$(date +%s)_${RANDOM}"
    mkdir -p "$work_dir"
    
    # Step 1: Convert ASF to MP4
    local mp4_file="$work_dir/${basename_no_ext}.mp4"
    local LOG_FILE="$work_dir/ffmpeg_conversion.log"
    
    if [ "$USE_COPY_MODE" = true ]; then
        # =====================================================================
        # COPY MODE: Stream copy
        # =====================================================================
        echo_info "[STEP 1] Converting ASF to MP4 (COPY MODE - NO RE-ENCODING)..."
        
        stdbuf -oL -eL ffmpeg -hide_banner -stats -i "$asf_filepath" \
            -c copy \
            -max_muxing_queue_size 9999 \
            -avoid_negative_ts make_zero \
            -fflags +genpts \
            "$mp4_file" -y 2>&1 | tee -a "$LOG_FILE"
        
        FFMPEG_RC=${PIPESTATUS[0]:-1}
        
        if [ "$FFMPEG_RC" -eq 0 ]; then
            local output_size_mb=$(stat -c%s "$mp4_file" 2>/dev/null)
            output_size_mb=$((output_size_mb / 1048576))
            echo_success "[STEP 1] Stream copy complete: Output ${output_size_mb}MB"
        else
            echo_error "[STEP 1] Stream copy failed: $filename (ffmpeg rc=$FFMPEG_RC)"
            rm -rf "$work_dir"
            return 1
        fi
        
    elif [ "$USE_FAST_MODE" = true ]; then
        # =====================================================================
        # FAST MODE: Single-pass CBR (No duration check before encoding)
        # =====================================================================
        echo_info "[STEP 1] Converting ASF to MP4 (FAST MODE)..."
        echo_info "[STEP 1] Target: ${FIXED_VIDEO_BITRATE} video + ${FIXED_AUDIO_BITRATE} audio"
        echo_info "[STEP 1] Expected: ${MAX_CHUNK_SIZE_MB}MB per 10-min chunk"
        
        # Does not check duration before encoding -  ffmpeg handles it
        # Validate duration AFTER successful conversion
        
        stdbuf -oL -eL ffmpeg -hide_banner -stats -i "$asf_filepath" \
            -c:v $VIDEO_CODEC -preset $VIDEO_PRESET \
            -b:v $FIXED_VIDEO_BITRATE -maxrate $FIXED_VIDEO_BITRATE -bufsize $((${FIXED_VIDEO_BITRATE%k} * 2))k \
            -vf "scale=$VIDEO_SCALE,fps=fps=$VIDEO_FPS" \
            -c:a $AUDIO_CODEC -b:a $FIXED_AUDIO_BITRATE \
            -max_muxing_queue_size 9999 \
            -avoid_negative_ts make_zero \
            -fflags +genpts \
            "$mp4_file" -y 2>&1 | tee -a "$LOG_FILE"
        
        FFMPEG_RC=${PIPESTATUS[0]:-1}
        
        if [ "$FFMPEG_RC" -eq 0 ]; then
            local output_size_mb=$(stat -c%s "$mp4_file" 2>/dev/null)
            output_size_mb=$((output_size_mb / 1048576))
            local source_size_mb=$((filesize / 1048576))
            
            if [ "$output_size_mb" -gt 0 ]; then
                local reduction_pct=$(( (source_size_mb - output_size_mb) * 100 / source_size_mb ))
                echo_success "[STEP 1] Conversion complete: ${source_size_mb}MB → ${output_size_mb}MB (${reduction_pct}% reduction)"
            else
                echo_success "[STEP 1] Conversion complete: ${source_size_mb}MB → ${output_size_mb}MB"
            fi
        else
            echo_error "[STEP 1] Conversion failed: $filename (ffmpeg rc=$FFMPEG_RC)"
            cat "$LOG_FILE" | tail -20
            rm -rf "$work_dir"
            return 1
        fi
        
    else
        # =====================================================================
        # INTELLIGENT MODE: 2-pass VBR
        # =====================================================================
        echo_info "[STEP 1] Analyzing source and calculating optimal bitrate..."
        
        local source_size_bytes=$(stat -c%s "$asf_filepath" 2>/dev/null)
        local source_size_mb=$((source_size_bytes / 1048576))
        
        # Try to get duration (with fallback)
        local source_duration=$(get_duration_seconds "$asf_filepath")
        
        if [ -z "$source_duration" ] || [ "$source_duration" -le 0 ]; then
            echo_warning "[STEP 1] Cannot determine exact duration, using file size estimation"
            source_duration=$((source_size_mb * 60))
            echo_info "[STEP 1] Estimated duration: ~$((source_duration / 60)) minutes"
        else
            echo_info "[STEP 1] Source duration: ${source_duration} seconds ($((source_duration / 60)) minutes)"
        fi
        
        # Calculate bitrates
        local source_bitrate_kbps=$(( (source_size_bytes * 8) / (source_duration * 1000) ))
        local target_total_bitrate=$(awk "BEGIN {printf \"%.0f\", $source_bitrate_kbps * $TARGET_SIZE_RATIO}")
        local max_chunk_bitrate=$(awk "BEGIN {printf \"%.0f\", ($MAX_CHUNK_SIZE_MB * 8192) / $CHUNK_LEN}")
        
        if [ "$target_total_bitrate" -gt "$max_chunk_bitrate" ]; then
            target_total_bitrate=$max_chunk_bitrate
        fi
        
        local audio_bitrate_num=$(echo "$FIXED_AUDIO_BITRATE" | sed 's/k//')
        local target_video_bitrate=$((target_total_bitrate - audio_bitrate_num))
        
        # Apply limits
        if [ "$target_video_bitrate" -lt $(echo "$MIN_VIDEO_BITRATE" | sed 's/k//') ]; then
            target_video_bitrate=$(echo "$MIN_VIDEO_BITRATE" | sed 's/k//')
        fi
        
        if [ "$target_video_bitrate" -gt $(echo "$MAX_VIDEO_BITRATE" | sed 's/k//') ]; then
            target_video_bitrate=$(echo "$MAX_VIDEO_BITRATE" | sed 's/k//')
        fi
        
        local target_video_bitrate_str="${target_video_bitrate}k"
        local maxrate=$((target_video_bitrate * 12 / 10))
        local bufsize=$((target_video_bitrate * 2))
        local expected_chunk_size=$(awk "BEGIN {printf \"%.0f\", ($target_total_bitrate * $CHUNK_LEN) / 8192}")
        
        echo_info "[STEP 1] Target: ${target_video_bitrate}kbps video + ${FIXED_AUDIO_BITRATE} audio"
        echo_info "[STEP 1] Expected: ~${expected_chunk_size}MB per 10-min chunk"
        echo_info "[STEP 1] Converting ASF to MP4 (2-PASS MODE)..."
        
        # Pass 1
        echo_progress "[STEP 1] Pass 1/2: Analyzing video..."
        ffmpeg -y -i "$asf_filepath" \
            -c:v $VIDEO_CODEC -preset $VIDEO_PRESET \
            -b:v $target_video_bitrate_str -maxrate ${maxrate}k -bufsize ${bufsize}k \
            -vf "scale=$VIDEO_SCALE,fps=fps=$VIDEO_FPS" \
            -pass 1 -passlogfile "$work_dir/ffmpeg2pass" \
            -an -f mp4 /dev/null 2>&1 | tee -a "$LOG_FILE"
        
        if [ ${PIPESTATUS[0]} -ne 0 ]; then
            echo_error "[STEP 1] Pass 1 failed"
            rm -rf "$work_dir"
            return 1
        fi
        
        # Pass 2
        echo_progress "[STEP 1] Pass 2/2: Encoding video..."
        stdbuf -oL -eL ffmpeg -hide_banner -stats -i "$asf_filepath" \
            -c:v $VIDEO_CODEC -preset $VIDEO_PRESET \
            -b:v $target_video_bitrate_str -maxrate ${maxrate}k -bufsize ${bufsize}k \
            -vf "scale=$VIDEO_SCALE,fps=fps=$VIDEO_FPS" \
            -pass 2 -passlogfile "$work_dir/ffmpeg2pass" \
            -c:a $AUDIO_CODEC -b:a $FIXED_AUDIO_BITRATE \
            -max_muxing_queue_size 9999 \
            -avoid_negative_ts make_zero \
            -fflags +genpts \
            "$mp4_file" -y 2>&1 | tee -a "$LOG_FILE"
        
        FFMPEG_RC=${PIPESTATUS[0]:-1}
        rm -f "$work_dir/ffmpeg2pass"*
        
        if [ "$FFMPEG_RC" -eq 0 ]; then
            local output_size_mb=$(stat -c%s "$mp4_file" 2>/dev/null)
            output_size_mb=$((output_size_mb / 1048576))
            local reduction_pct=$(( (source_size_mb - output_size_mb) * 100 / source_size_mb ))
            echo_success "[STEP 1] Conversion complete: ${source_size_mb}MB → ${output_size_mb}MB (${reduction_pct}% reduction)"
        else
            echo_error "[STEP 1] Conversion failed: $filename (ffmpeg rc=$FFMPEG_RC)"
            rm -rf "$work_dir"
            return 1
        fi
    fi
    
    # Step 2: Validate converted file
    if ! is_media_file "$mp4_file"; then
        echo_error "[STEP 1] Converted file is invalid: $mp4_file"
        rm -rf "$work_dir"
        return 1
    fi
    
    # Step 3: Get duration from CONVERTED file (more reliable)
    local duration=$(get_duration_seconds "$mp4_file")
    if [ "$duration" -le 0 ]; then
        echo_warning "[STEP 2] Cannot determine exact duration, will attempt chunking anyway"
        # Estimate chunks from file size
        local mp4_size=$(stat -c%s "$mp4_file" 2>/dev/null)
        local estimated_chunks=$(( (mp4_size / (MAX_CHUNK_SIZE_MB * 1048576)) + 1 ))
        echo_info "[STEP 2] Will attempt to create approximately $estimated_chunks chunks"
    else
        echo_info "[STEP 2] Duration: ${duration}s, will create $(( (duration / CHUNK_LEN) + 1 )) chunks"
    fi
    
    # Step 4: Split into chunks
    local chunk_num=1
    local offset=0
    local chunks_created=0
    
    # If we don't have duration, try to split anyway and stop on error
    if [ "$duration" -le 0 ]; then
        duration=999999  # Large number to allow loop to run
    fi
    
    while [ $offset -lt $duration ]; do
        local chunk_file="$work_dir/${basename_no_ext}-$(printf "%03d" $chunk_num).mp4"
        echo_progress "[STEP 2] Creating chunk $chunk_num..."
        
        # Try to split
        if ffmpeg -i "$mp4_file" -vcodec copy -acodec copy \
            -ss $offset -t $CHUNK_LEN "$chunk_file" -y -loglevel error 2>/dev/null; then
            
            # Check if chunk was actually created and has content
            if [ -f "$chunk_file" ]; then
                local chunk_size=$(stat -c%s "$chunk_file" 2>/dev/null || echo "0")
                if [ "$chunk_size" -gt 1000 ]; then  # At least 1KB
                    local new_name=$(generate_somalia_tv_chunk_name "$basename_no_ext" "$chunk_num" "mp4")
                    
                    if mv "$chunk_file" "$UPLOAD_DIR/$new_name" 2>/dev/null; then
                        local chunk_size_mb=$((chunk_size / 1048576))
                        echo_success "[STEP 3] Chunk ready: $new_name (${chunk_size_mb}MB)"
                        ((chunks_created++))
                    else
                        echo_error "[STEP 3] Failed to move chunk: $chunk_file"
                    fi
                else
                    # Chunk too small, we've reached the end
                    rm -f "$chunk_file"
                    break
                fi
            else
                # No more chunks to create
                break
            fi
        else
            # Failed to create chunk
            if [ $chunks_created -eq 0 ]; then
                echo_error "[STEP 2] Failed to create any chunks"
            else
                echo_info "[STEP 2] Reached end of file after $chunks_created chunks"
            fi
            break
        fi
        
        ((chunk_num++))
        ((offset += CHUNK_LEN))
        
        # Safety limit
        if [ $chunk_num -gt 100 ]; then
            echo_warning "[STEP 2] Stopping after 100 chunks (safety limit)"
            break
        fi
    done
    
    # Cleanup
    if [ "$DELETE_TEMP_MP4_AFTER_SPLITTING" = true ]; then
        rm -f "$mp4_file"
        echo_info "[STEP 2] Deleted temporary MP4"
    fi
    
    rm -rf "$work_dir"
    
    # Archive original
    if [ "$MOVE_ORIGINAL_AFTER_PROCESSING" = true ] && [ $chunks_created -gt 0 ]; then
        if mv "$asf_filepath" "$MOTHER_DIR/" 2>/dev/null; then
            echo_info "[STEP 4] Archived original: $filename"
        else
            echo_warning "[STEP 4] Failed to archive: $filename"
        fi
    fi
    
    echo_success "ASF processing complete: $filename ($chunks_created chunks created)"
    return 0
}

# =========================================================================
# STATUS AND REPORTING
# =========================================================================

show_status() {
    echo_info "=========================================="
    echo_info "STATUS REPORT"
    echo_info "=========================================="
    
    if [ -d "$SOURCE_DIR" ]; then
        local asf_total=$(find "$SOURCE_DIR" -name "*.asf" -type f 2>/dev/null | wc -l)
        local sntv_count=$(find "$SOURCE_DIR" -name "SNTV_*.asf" -type f 2>/dev/null | wc -l)
        local snltv_count=$(find "$SOURCE_DIR" -name "SNLTV_*.asf" -type f 2>/dev/null | wc -l)
        local sntvdaljir_count=$(find "$SOURCE_DIR" -name "SNTVDALJIR_*.asf" -type f 2>/dev/null | wc -l)
        
        echo_info "Source Directory: $SOURCE_DIR"
        echo_info "  Total ASF files: $asf_total"
        echo_info "  SNTV files: $sntv_count"
        echo_info "  SNLTV files: $snltv_count"
        echo_info "  SNTVDALJIR files: $sntvdaljir_count"
    fi
    
    if [ -d "$UPLOAD_DIR" ]; then
        local upload_mp4=$(find "$UPLOAD_DIR" -name "*.mp4" -type f 2>/dev/null | wc -l)
        local upload_snt=$(find "$UPLOAD_DIR" -name "SO_SNT_*.mp4" -type f 2>/dev/null | wc -l)
        local upload_sln=$(find "$UPLOAD_DIR" -name "SO_SLN_*.mp4" -type f 2>/dev/null | wc -l)
        local upload_sn2=$(find "$UPLOAD_DIR" -name "SO_SN2_*.mp4" -type f 2>/dev/null | wc -l)
        local upload_size=$(du -sh "$UPLOAD_DIR" 2>/dev/null | cut -f1 || echo "0")
        
        echo_info "Upload Directory: $UPLOAD_DIR"
        echo_info "  Total MP4 chunks: $upload_mp4"
        echo_info "  SO_SNT chunks: $upload_snt"
        echo_info "  SO_SLN chunks: $upload_sln"
        echo_info "  SO_SN2 chunks: $upload_sn2"
        echo_info "  Total size: $upload_size"
    fi
    
    if [ -d "$MOTHER_DIR" ]; then
        local archive_count=$(find "$MOTHER_DIR" -type f 2>/dev/null | wc -l)
        local archive_size=$(du -sh "$MOTHER_DIR" 2>/dev/null | cut -f1 || echo "0")
        
        echo_info "Archive Directory: $MOTHER_DIR"
        echo_info "  Files: $archive_count"
        echo_info "  Total size: $archive_size"
    fi
    
    echo_info "=========================================="
}

# =========================================================================
# JOB TRACKING SYSTEM
# =========================================================================

PID_DIR="/tmp/asf_media_processor_pids_$$"
mkdir -p "$PID_DIR"

cleanup_pid_dir() {
    rm -rf "$PID_DIR" 2>/dev/null || true
}
trap cleanup_pid_dir EXIT

register_job() {
    local pid=$1
    local filename=$2
    
    if [ ! -d "$PID_DIR" ]; then
        mkdir -p "$PID_DIR" 2>/dev/null || return 1
    fi
    
    echo "$filename" > "$PID_DIR/${pid}.pid" 2>/dev/null || return 1
}

unregister_job() {
    local pid=$1
    rm -f "$PID_DIR/${pid}.pid" 2>/dev/null
}

count_active_jobs() {
    local count=0
    shopt -s nullglob
    for pid_file in "$PID_DIR"/*.pid; do
        [ -f "$pid_file" ] || continue
        local pid=$(basename "$pid_file" .pid)
        if kill -0 "$pid" 2>/dev/null; then
            ((count++))
        else
            rm -f "$pid_file"
        fi
    done
    shopt -u nullglob
    echo $count
}

show_running_jobs() {
    local count=0
    echo_info "Currently processing:"
    shopt -s nullglob
    for pid_file in "$PID_DIR"/*.pid; do
        [ -f "$pid_file" ] || continue
        local pid=$(basename "$pid_file" .pid)
        if kill -0 "$pid" 2>/dev/null; then
            local filename=$(cat "$pid_file")
            echo_info "  [PID $pid] $filename"
            ((count++))
        fi
    done
    shopt -u nullglob
    if [ $count -eq 0 ]; then
        echo_info "  (none)"
    fi
    return $count
}

# =========================================================================
# PROCESSING WRAPPER
# =========================================================================

process_asf_with_tracking() {
    local file="$1"
    local my_pid=$$
    local filename=$(basename "$file")
    
    register_job $my_pid "$filename"
    
    if process_asf_file "$file"; then
        local result=0
    else
        local result=1
    fi
    
    unregister_job $my_pid
    return $result
}

# =========================================================================
# CONCURRENT PROCESSING
# =========================================================================

process_files_concurrently() {
    local sntv_files=()
    local snltv_files=()
    local sntvdaljir_files=()
    
    echo_info "Scanning for SNTV files..."
    while IFS= read -r -d '' file; do
        sntv_files+=("$file")
    done < <(find "$SOURCE_DIR" -name "SNTV_*.asf" -type f -print0 2>/dev/null | sort -z)
    
    echo_info "Scanning for SNLTV files..."
    while IFS= read -r -d '' file; do
        snltv_files+=("$file")
    done < <(find "$SOURCE_DIR" -name "SNLTV_*.asf" -type f -print0 2>/dev/null | sort -z)
    
    echo_info "Scanning for SNTVDALJIR files..."
    while IFS= read -r -d '' file; do
        sntvdaljir_files+=("$file")
    done < <(find "$SOURCE_DIR" -name "SNTVDALJIR_*.asf" -type f -print0 2>/dev/null | sort -z)
    
    local total_sntv=${#sntv_files[@]}
    local total_snltv=${#snltv_files[@]}
    local total_sntvdaljir=${#sntvdaljir_files[@]}
    local total_files=$((total_sntv + total_snltv + total_sntvdaljir))
    
    if [ $total_files -eq 0 ]; then
        echo_warning "No ASF files found to process"
        return 0
    fi
    
    echo_info "Found $total_sntv SNTV, $total_snltv SNLTV, and $total_sntvdaljir SNTVDALJIR files"
    echo_info "Starting concurrent processing (max $MAX_PARALLEL_JOBS parallel jobs)..."
    echo ""
    
    local sntv_idx=0
    local snltv_idx=0
    local sntvdaljir_idx=0
    local jobs_started=0
    local start_time=$(date +%s)
    
    while [ $sntv_idx -lt $total_sntv ] || [ $snltv_idx -lt $total_snltv ] || [ $sntvdaljir_idx -lt $total_sntvdaljir ]; do
        
        while [ $(count_active_jobs) -ge $MAX_PARALLEL_JOBS ]; do
            sleep 1
        done
        
        # Process SNTV files
        if [ $sntv_idx -lt $total_sntv ] && [ $(count_active_jobs) -lt $MAX_PARALLEL_JOBS ]; then
            local file="${sntv_files[$sntv_idx]}"
            local fname=$(basename "$file")
            echo_info "[SNTV $((sntv_idx + 1))/$total_sntv] Starting: $fname"
            
            (
                if process_asf_with_tracking "$file"; then
                    echo_success "[SNTV $((sntv_idx + 1))/$total_sntv] Completed: $fname"
                else
                    echo_error "[SNTV $((sntv_idx + 1))/$total_sntv] Failed: $fname"
                fi
            ) &
            
            local job_pid=$!
            echo_info "  → Job PID: $job_pid"
            
            ((sntv_idx++))
            ((jobs_started++))
            sleep 0.5
            continue
        fi
        
        # Process SNLTV files
        if [ $snltv_idx -lt $total_snltv ] && [ $(count_active_jobs) -lt $MAX_PARALLEL_JOBS ]; then
            local file="${snltv_files[$snltv_idx]}"
            local fname=$(basename "$file")
            echo_info "[SNLTV $((snltv_idx + 1))/$total_snltv] Starting: $fname"
            
            (
                if process_asf_with_tracking "$file"; then
                    echo_success "[SNLTV $((snltv_idx + 1))/$total_snltv] Completed: $fname"
                else
                    echo_error "[SNLTV $((snltv_idx + 1))/$total_snltv] Failed: $fname"
                fi
            ) &
            
            local job_pid=$!
            echo_info "  → Job PID: $job_pid"
            
            ((snltv_idx++))
            ((jobs_started++))
            sleep 0.5
            continue
        fi
        
        # Process SNTVDALJIR files
        if [ $sntvdaljir_idx -lt $total_sntvdaljir ] && [ $(count_active_jobs) -lt $MAX_PARALLEL_JOBS ]; then
            local file="${sntvdaljir_files[$sntvdaljir_idx]}"
            local fname=$(basename "$file")
            echo_info "[SNTVDALJIR $((sntvdaljir_idx + 1))/$total_sntvdaljir] Starting: $fname"
            
            (
                if process_asf_with_tracking "$file"; then
                    echo_success "[SNTVDALJIR $((sntvdaljir_idx + 1))/$total_sntvdaljir] Completed: $fname"
                else
                    echo_error "[SNTVDALJIR $((sntvdaljir_idx + 1))/$total_sntvdaljir] Failed: $fname"
                fi
            ) &
            
            local job_pid=$!
            echo_info "  → Job PID: $job_pid"
            
            ((sntvdaljir_idx++))
            ((jobs_started++))
            sleep 0.5
            continue
        fi
        
        # Progress reporting
        if [ $((jobs_started % 4)) -eq 0 ] && [ $jobs_started -gt 0 ]; then
            local elapsed=$(($(date +%s) - start_time))
            local active=$(count_active_jobs)
            echo ""
            echo_progress "═══════════════════════════════════════"
            echo_progress "Progress: $jobs_started/$total_files jobs started"
            echo_progress "Active jobs: $active / $MAX_PARALLEL_JOBS"
            echo_progress "Elapsed time: ${elapsed}s"
            show_running_jobs
            echo_progress "═══════════════════════════════════════"
            echo ""
        fi
        
        sleep 0.5
    done
    
    echo ""
    echo_info "All jobs started. Waiting for completion..."
    echo ""
    
    while [ $(count_active_jobs) -gt 0 ]; do
        local active=$(count_active_jobs)
        echo_info "Waiting for $active remaining jobs..."
        show_running_jobs
        sleep 3
    done
    
    local end_time=$(date +%s)
    local total_time=$((end_time - start_time))
    local avg_time=$((total_files > 0 ? total_time / total_files : 0))
    
    echo ""
    echo_success "═══════════════════════════════════════"
    echo_success "Processing completed in $total_time seconds"
    echo_success "Files processed: $total_files"
    echo_success "Average time per file: ${avg_time}s"
    echo_success "═══════════════════════════════════════"
}

# =========================================================================
# CLEANUP HANDLER
# =========================================================================

cleanup() {
    echo ""
    echo_warning "Interrupt received! Cleaning up..."
    
    shopt -s nullglob
    for pid_file in "$PID_DIR"/*.pid; do
        [ -f "$pid_file" ] || continue
        local pid=$(basename "$pid_file" .pid)
        if kill -0 "$pid" 2>/dev/null; then
            local filename=$(cat "$pid_file")
            echo_info "Stopping: $filename (PID: $pid)"
            kill "$pid" 2>/dev/null || true
        fi
    done
    
    sleep 2
    
    for pid_file in "$PID_DIR"/*.pid; do
        [ -f "$pid_file" ] || continue
        local pid=$(basename "$pid_file" .pid)
        if kill -0 "$pid" 2>/dev/null; then
            kill -9 "$pid" 2>/dev/null || true
        fi
    done
    shopt -u nullglob
    
    rm -rf /tmp/asf_$$_* 2>/dev/null || true
    cleanup_pid_dir
    rm -f "$LOCKFILE"
    
    echo_info "Cleanup complete"
    exit 0
}

# =========================================================================
# MAIN EXECUTION
# =========================================================================

main() {
    trap cleanup SIGINT SIGTERM
    
    echo_info "Checking prerequisites..."
    
    if ! command -v ffmpeg &> /dev/null; then
        echo_error "ffmpeg is not installed or not in PATH"
        echo_info "Install with: sudo apt-get install ffmpeg"
        exit 1
    fi
    
    if ! command -v ffprobe &> /dev/null; then
        echo_warning "ffprobe not found - duration detection may be less reliable"
    fi
    
    if [ ! -d "$SOURCE_DIR" ]; then
        echo_error "Source directory does not exist: $SOURCE_DIR"
        exit 1
    fi
    
    mkdir -p "$UPLOAD_DIR" "$MOTHER_DIR"
    
    show_status
    
    echo ""
    echo_info "=========================================="
    echo_info "Starting processing at $(date)"
    if [ "$USE_COPY_MODE" = true ]; then
        echo_info "Mode: COPY (stream copy, no re-encoding)"
    elif [ "$USE_FAST_MODE" = true ]; then
        echo_info "Mode: FAST (single-pass CBR) ← ACTIVE"
        echo_info "Target: ${MAX_CHUNK_SIZE_MB}MB per chunk"
    else
        echo_info "Mode: INTELLIGENT (2-pass VBR)"
    fi
    echo_info "=========================================="
    echo ""
    
    process_files_concurrently
    
    echo ""
    show_status
    
    echo ""
    echo_success "=========================================="
    echo_success "      ASF PROCESSING COMPLETED!           "
    echo_success "=========================================="
    echo_success "Upload-ready files: $UPLOAD_DIR"
    echo_success "Archived originals: $MOTHER_DIR"
    echo_success "=========================================="
    echo ""
}

main "$@"
