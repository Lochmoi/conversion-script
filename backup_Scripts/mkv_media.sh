#!/bin/bash

# =========================================================================
# . mkv media processor with intelligent file sizing (42MB) 
# =========================================================================
# Features:
# - Converts .mkv files to .mp4 and splits into 10-minute chunks
# - Dynamic naming support for any PREFIX_IDENTIFIER pattern
# - ROBUST: 3-tier duration detection with graceful fallbacks
# - Intelligent sizing: Output relative to source with 42MB cap
# - Concurrent file processing with robust job tracking (4 job)
# - Automatic file archival after processing
# - Production-grade error handling and recovery
# =========================================================================

# Lock file to prevent multiple instances
LOCKFILE="/var/run/media_processor.lock"

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
SOURCE_DIR="/home/malawi/renamed"              # Directory containing source files
UPLOAD_DIR="/home/micah/upload_ready"          # Directory for processed chunks
MOTHER_DIR="/home/malawi/mother"               # Archive directory for originals
CHUNK_LEN=600                                  # Chunk length in seconds (10 minutes)
MAX_PARALLEL_JOBS=4                            # Maximum concurrent processing jobs

# Processing options
MOVE_ORIGINAL_AFTER_PROCESSING=true            # Move originals to archive after processing
DELETE_TEMP_MP4_AFTER_SPLITTING=true           # Delete temporary MP4 after splitting

# Video encoding settings (for MKV to MP4 conversion)
VIDEO_CODEC="libx264"
VIDEO_PRESET="ultrafast"                   # ultrafast = fastest speed (change to "medium" for better quality)
VIDEO_SCALE="-2:480"                       # Scale to 480p height (preserve aspect ratio)
VIDEO_FPS=30                               # Target FPS
AUDIO_CODEC="aac"
AUDIO_BITRATE="96k"                        # Audio bitrate

# SPEED CONTROL: Choose Mode
USE_COPY_MODE=false                        # true = ULTRA-FAST (stream copy, ~2 min/hour, no size reduction)
USE_FAST_MODE=true                         # true = FAST (re-encode, ~15 min/hour, 50% smaller)
                                           # false = INTELLIGENT (2-pass, ~55 min/hour, best quality)

# Fast mode settings (USE_FAST_MODE=true, USE_COPY_MODE=false)
MAX_CHUNK_SIZE_MB=42                       # Maximum size per 10-minute chunk
FIXED_VIDEO_BITRATE="478k"                 # Fixed video bitrate for 42MB target
FIXED_AUDIO_BITRATE="96k"                  # Fixed audio bitrate

# Intelligent mode settings (USE_FAST_MODE=false, USE_COPY_MODE=false)
TARGET_SIZE_RATIO=0.65                     # Output = 65% of source size
MIN_VIDEO_BITRATE="400k"                   # Minimum video bitrate
MAX_VIDEO_BITRATE="3000k"                  # Maximum video bitrate

# Note: 
# COPY MODE (USE_COPY_MODE=true):
#   - Stream copy, no re-encoding
#   - ULTRA-FAST: ~2 min per hour ⚡⚡⚡
#   - Same size as source (no reduction)
#   - Just remux to MP4 and split into chunks
#   - Best for: Speed over size reduction
#
# FAST MODE (USE_FAST_MODE=true, USE_COPY_MODE=false):
#   - Single-pass CBR encoding
#   - FAST: ~15 min per hour ⚡⚡
#   - Fixed 42MB chunks (50% smaller)
#   - Good quality
#   - Best for: Balance of speed and size
#
# INTELLIGENT MODE (USE_FAST_MODE=false, USE_COPY_MODE=false):
#   - 2-pass VBR encoding
#   - SLOW: ~55 min per hour ⚡
#   - Adaptive 30-42MB chunks (54% smaller)
#   - Best quality distribution
#   - Best for: Maximum quality at target size

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

# Get duration with MULTIPLE fallback methods (PRODUCTION-GRADE)
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
        
        # Remove leading zeros but keep at least one digit
        h=$(echo "$h" | sed 's/^0*\([0-9]\)/\1/'); h=${h:-0}
        m=$(echo "$m" | sed 's/^0*\([0-9]\)/\1/'); m=${m:-0}
        s=$(echo "$s" | sed 's/^0*\([0-9]\)/\1/'); s=${s:-0}
        
        # Validate they're actually numbers (prevents "10#N" error)
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

# Generate chunk name based on pattern and time offset
generate_chunk_name() {
    local base="$1"
    local chunk_index="$2"
    local extension="$3"
    
    # Pattern 1: PREFIX_IDENTIFIER_YYYY_MM_DD_HH-MM-SS-XXX (with chunk index)
    if [[ "$base" =~ ^([A-Z]+_[A-Z0-9]+)_([0-9]{4})_([0-9]{2})_([0-9]{2})_([0-9]{2})-([0-9]{2})-([0-9]{2})-([0-9]{3})$ ]]; then
        local prefix_id="${BASH_REMATCH[1]}"
        local year="${BASH_REMATCH[2]}"
        local month="${BASH_REMATCH[3]}"
        local day="${BASH_REMATCH[4]}"
        local hour="${BASH_REMATCH[5]}"
        local minute="${BASH_REMATCH[6]}"
        local second="${BASH_REMATCH[7]}"
        local orig_index="${BASH_REMATCH[8]}"
        
        # Calculate new time based on original chunk index
        local orig_minute_num=$((10#$minute))
        local chunk_minutes=$(( (10#$orig_index - 1) * 10 ))
        local total_minutes=$((orig_minute_num + chunk_minutes))
        local final_hour=$((10#$hour + total_minutes / 60))
        local final_minute=$((total_minutes % 60))
        
        # Handle day rollover
        local final_day=$((10#$day))
        if [ $final_hour -ge 24 ]; then
            final_day=$((final_day + final_hour / 24))
            final_hour=$((final_hour % 24))
        fi
        
        printf "%s_%s_%s_%02d_%02d-%02d-00.%s" \
            "$prefix_id" "$year" "$month" "$final_day" "$final_hour" "$final_minute" "$extension"
    
    # Pattern 2: PREFIX_IDENTIFIER_YYYY_MM_DD_HH-MM-SS (without chunk index)
    elif [[ "$base" =~ ^([A-Z]+_[A-Z0-9]+)_([0-9]{4})_([0-9]{2})_([0-9]{2})_([0-9]{2})-([0-9]{2})-([0-9]{2})$ ]]; then
        local prefix_id="${BASH_REMATCH[1]}"
        local year="${BASH_REMATCH[2]}"
        local month="${BASH_REMATCH[3]}"
        local day="${BASH_REMATCH[4]}"
        local hour="${BASH_REMATCH[5]}"
        local minute="${BASH_REMATCH[6]}"
        local second="${BASH_REMATCH[7]}"
        
        # Calculate new time based on chunk index
        local orig_minute_num=$((10#$minute))
        local chunk_minutes=$(( ($chunk_index - 1) * 10 ))
        local total_minutes=$((orig_minute_num + chunk_minutes))
        local final_hour=$((10#$hour + total_minutes / 60))
        local final_minute=$((total_minutes % 60))
        
        # Handle day rollover
        local final_day=$((10#$day))
        if [ $final_hour -ge 24 ]; then
            final_day=$((final_day + final_hour / 24))
            final_hour=$((final_hour % 24))
        fi
        
        printf "%s_%s_%s_%02d_%02d-%02d-00.%s" \
            "$prefix_id" "$year" "$month" "$final_day" "$final_hour" "$final_minute" "$extension"
    
    # Fallback for unrecognized patterns
    else
        echo "${base}_chunk_$(printf "%03d" "$chunk_index").${extension}"
    fi
}

# =========================================================================
# PROCESSING FUNCTIONS
# =========================================================================

# -------------------------------------------------------------------------
# MP3 PROCESSING - COMMENTED OUT (ENABLE ONLY WHEN NEEDED)
# -------------------------------------------------------------------------
# Uncomment the function below if you need to process MP3 files
# Also uncomment MP3 collection and processing sections in main functions
# -------------------------------------------------------------------------

# process_mp3_file() {
#     local mp3_filepath="$1"
#     local filename=$(basename "$mp3_filepath")
#     local basename_no_ext="${filename%.*}"
#     
#     echo_info "=========================================="
#     echo_info "Processing MP3: $filename"
#     echo_info "=========================================="
#     
#     # Create unique temporary directory
#     local work_dir="/tmp/mp3_$$_$(date +%s)_${RANDOM}"
#     mkdir -p "$work_dir"
#     
#     # Validate media file
#     if ! is_media_file "$mp3_filepath"; then
#         echo_warning "Invalid media file: $filename"
#         rm -rf "$work_dir"
#         return 1
#     fi
#     
#     # Get duration
#     local duration=$(get_duration_seconds "$mp3_filepath")
#     if [ "$duration" -le 0 ]; then
#         echo_error "Invalid duration for: $filename"
#         rm -rf "$work_dir"
#         return 1
#     fi
#     
#     echo_info "Duration: ${duration}s, will create $(( (duration / CHUNK_LEN) + 1 )) chunks"
#     
#     # Process chunks
#     local chunk_num=1
#     local offset=0
#     local chunks_created=0
#     
#     while [ $offset -lt $duration ]; do
#         local chunk_file="$work_dir/${basename_no_ext}-$(printf "%03d" $chunk_num).mp3"
#         echo_progress "Creating chunk $chunk_num..."
#         
#         # Extract chunk (using copy codec for speed)
#         if ffmpeg -i "$mp3_filepath" -acodec copy -ss $offset -t $CHUNK_LEN "$chunk_file" -y -loglevel error 2>/dev/null; then
#             # Generate proper name and move to upload directory
#             local new_name=$(generate_chunk_name "$basename_no_ext" "$chunk_num" "mp3")
#             
#             if mv "$chunk_file" "$UPLOAD_DIR/$new_name" 2>/dev/null; then
#                 echo_success "Chunk ready: $new_name"
#                 ((chunks_created++))
#             else
#                 echo_error "Failed to move chunk: $chunk_file"
#             fi
#         else
#             echo_error "Failed to create chunk $chunk_num"
#         fi
#         
#         ((chunk_num++))
#         ((offset += CHUNK_LEN))
#     done
#     
#     # Cleanup
#     rm -rf "$work_dir"
#     
#     # Archive original
#     if [ "$MOVE_ORIGINAL_AFTER_PROCESSING" = true ] && [ $chunks_created -gt 0 ]; then
#         if mv "$mp3_filepath" "$MOTHER_DIR/" 2>/dev/null; then
#             echo_info "Archived original: $filename"
#         else
#             echo_warning "Failed to archive: $filename"
#         fi
#     fi
#     
#     echo_success "MP3 processing complete: $filename ($chunks_created chunks)"
#     return 0
# }

# Process MKV file - convert to MP4 with INTELLIGENT SIZING then split
process_mkv_file() {
    local mkv_filepath="$1"
    local filename=$(basename "$mkv_filepath")
    local basename_no_ext="${filename%.*}"
    
    echo_info "=========================================="
    echo_info "Processing MKV: $filename"
    echo_info "=========================================="
    
    # Validate source file before processing (PREVENTS CRASHES)
    if [ ! -f "$mkv_filepath" ]; then
        echo_error "File does not exist: $mkv_filepath"
        return 1
    fi
    
    local filesize=$(stat -c%s "$mkv_filepath" 2>/dev/null || echo "0")
    if [ "$filesize" -eq 0 ]; then
        echo_error "File is empty (0 bytes): $filename"
        return 1
    fi
    
    echo_info "Source file size: $((filesize / 1048576)) MB"
    
    # Test if ffmpeg can read the file
    if ! ffmpeg -i "$mkv_filepath" -hide_banner 2>&1 | grep -q "Duration:"; then
        echo_error "File appears to be corrupt or not a valid media file: $filename"
        echo_error "Skipping this file to prevent crashes"
        return 1
    fi
    
    # Create unique temporary directory
    local work_dir="/tmp/mkv_$$_$(date +%s)_${RANDOM}"
    mkdir -p "$work_dir"
    
    # Step 1: Convert MKV to MP4
    local mp4_file="$work_dir/${basename_no_ext}.mp4"
    local LOG_FILE="$work_dir/ffmpeg_conversion.log"
    
    if [ "$USE_COPY_MODE" = true ]; then
        # =====================================================================
        # COPY MODE: Stream copy (no re-encoding) - ULTRA FAST
        # =====================================================================
        echo_info "[STEP 1] Converting MKV to MP4 (COPY MODE - NO RE-ENCODING)..."
        echo_info "[STEP 1] This will be very fast (~2 min per hour)"
        echo_info "[STEP 1] Output size will be same as source (no reduction)"
        
        stdbuf -oL -eL ffmpeg -hide_banner -stats -i "$mkv_filepath" \
            -c copy \
            -max_muxing_queue_size 9999 \
            -avoid_negative_ts make_zero \
            -fflags +genpts \
            "$mp4_file" -y 2>&1 | tee -a "$LOG_FILE"
        
        FFMPEG_RC=${PIPESTATUS[0]:-1}
        
        if [ "$FFMPEG_RC" -eq 0 ]; then
            local output_size_mb=$(stat -c%s "$mp4_file" 2>/dev/null)
            output_size_mb=$((output_size_mb / 1048576))
            echo_success "[STEP 1] Stream copy complete: Output ${output_size_mb}MB (same as source)"
        else
            echo_error "[STEP 1] Stream copy failed: $filename (ffmpeg rc=$FFMPEG_RC)"
            cat "$LOG_FILE" | tail -20
            rm -rf "$work_dir"
            return 1
        fi
        
    elif [ "$USE_FAST_MODE" = true ]; then
        # =====================================================================
        # FAST MODE: Single-pass CBR for speed (No duration check before encoding)
        # =====================================================================
        echo_info "[STEP 1] Converting MKV to MP4 (FAST MODE)..."
        echo_info "[STEP 1] Target: ${FIXED_VIDEO_BITRATE} video + ${FIXED_AUDIO_BITRATE} audio"
        echo_info "[STEP 1] Expected: ${MAX_CHUNK_SIZE_MB}MB per 10-min chunk (fixed size)"
        
        # Does not check duration before encoding - ffmpeg handles it
        # Validate duration AFTER successful conversion
        
        stdbuf -oL -eL ffmpeg -hide_banner -stats -i "$mkv_filepath" \
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
            
            if [ "$output_size_mb" -gt 0 ] && [ "$source_size_mb" -gt 0 ]; then
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
        # INTELLIGENT MODE: 2-pass VBR for quality (slower but better)
        # =====================================================================
        echo_info "[STEP 1] Analyzing source and calculating optimal bitrate..."
        
        # Get source file size and duration
        local source_size_bytes=$(stat -c%s "$mkv_filepath" 2>/dev/null)
        local source_size_mb=$((source_size_bytes / 1048576))
        
        # Try to get duration (with fallback)
        local source_duration=$(get_duration_seconds "$mkv_filepath")
        
        if [ -z "$source_duration" ] || [ "$source_duration" -le 0 ]; then
            echo_warning "[STEP 1] Cannot determine exact duration, using file size estimation"
            source_duration=$((source_size_mb * 60))
            echo_info "[STEP 1] Estimated duration: ~$((source_duration / 60)) minutes"
        else
            echo_info "[STEP 1] Source duration: ${source_duration} seconds ($((source_duration / 60)) minutes)"
        fi
        
        # Calculate source bitrate (NOW SAFE - duration validated)
        local source_bitrate_kbps=$(( (source_size_bytes * 8) / (source_duration * 1000) ))
        
        # Calculate target bitrate (TARGET_SIZE_RATIO of source)
        local target_total_bitrate=$(awk "BEGIN {printf \"%.0f\", $source_bitrate_kbps * $TARGET_SIZE_RATIO}")
        
        # Calculate maximum bitrate based on MAX_CHUNK_SIZE_MB
        local max_chunk_bitrate=$(awk "BEGIN {printf \"%.0f\", ($MAX_CHUNK_SIZE_MB * 8192) / $CHUNK_LEN}")
        
        # Use the LOWER of dynamic calculation or hard cap
        if [ "$target_total_bitrate" -gt "$max_chunk_bitrate" ]; then
            echo_info "[STEP 1] Dynamic target ($target_total_bitrate kbps) exceeds ${MAX_CHUNK_SIZE_MB}MB cap"
            target_total_bitrate=$max_chunk_bitrate
            echo_info "[STEP 1] Limiting to $max_chunk_bitrate kbps (${MAX_CHUNK_SIZE_MB}MB per 10-min chunk)"
        fi
        
        # Subtract audio bitrate to get video bitrate
        local audio_bitrate_num=$(echo "$AUDIO_BITRATE" | sed 's/k//')
        local target_video_bitrate=$((target_total_bitrate - audio_bitrate_num))
        
        # Apply safety limits
        if [ "$target_video_bitrate" -lt $(echo "$MIN_VIDEO_BITRATE" | sed 's/k//') ]; then
            target_video_bitrate=$(echo "$MIN_VIDEO_BITRATE" | sed 's/k//')
            echo_warning "[STEP 1] Target bitrate too low, using minimum: ${MIN_VIDEO_BITRATE}"
        fi
        
        if [ "$target_video_bitrate" -gt $(echo "$MAX_VIDEO_BITRATE" | sed 's/k//') ]; then
            target_video_bitrate=$(echo "$MAX_VIDEO_BITRATE" | sed 's/k//')
            echo_warning "[STEP 1] Target bitrate too high, using maximum: ${MAX_VIDEO_BITRATE}"
        fi
        
        local target_video_bitrate_str="${target_video_bitrate}k"
        local maxrate=$((target_video_bitrate * 12 / 10))
        local bufsize=$((target_video_bitrate * 2))
        
        # Calculate expected chunk size
        local expected_chunk_size=$(awk "BEGIN {printf \"%.0f\", ($target_total_bitrate * $CHUNK_LEN) / 8192}")
        
        echo_info "[STEP 1] Source: ${source_size_mb} MB, ${source_bitrate_kbps} kbps"
        echo_info "[STEP 1] Target: ${target_video_bitrate}kbps video + ${AUDIO_BITRATE} audio"
        echo_info "[STEP 1] Expected: ~${expected_chunk_size}MB per 10-min chunk (max: ${MAX_CHUNK_SIZE_MB}MB)"
        echo_info "[STEP 1] Converting MKV to MP4 (2-PASS MODE)..."
        
        # Use 2-pass encoding
        echo_progress "[STEP 1] Pass 1/2: Analyzing video..."
        ffmpeg -y -i "$mkv_filepath" \
            -c:v $VIDEO_CODEC -preset $VIDEO_PRESET \
            -b:v $target_video_bitrate_str -maxrate ${maxrate}k -bufsize ${bufsize}k \
            -vf "scale=$VIDEO_SCALE,fps=fps=$VIDEO_FPS" \
            -pass 1 -passlogfile "$work_dir/ffmpeg2pass" \
            -an -f mp4 /dev/null 2>&1 | tee -a "$LOG_FILE"
        
        if [ ${PIPESTATUS[0]} -ne 0 ]; then
            echo_error "[STEP 1] Pass 1 failed"
            cat "$LOG_FILE" | tail -20
            rm -rf "$work_dir"
            return 1
        fi
        
        echo_progress "[STEP 1] Pass 2/2: Encoding video..."
        stdbuf -oL -eL ffmpeg -hide_banner -stats -i "$mkv_filepath" \
            -c:v $VIDEO_CODEC -preset $VIDEO_PRESET \
            -b:v $target_video_bitrate_str -maxrate ${maxrate}k -bufsize ${bufsize}k \
            -vf "scale=$VIDEO_SCALE,fps=fps=$VIDEO_FPS" \
            -pass 2 -passlogfile "$work_dir/ffmpeg2pass" \
            -c:a $AUDIO_CODEC -b:a $AUDIO_BITRATE \
            -max_muxing_queue_size 9999 \
            -avoid_negative_ts make_zero \
            -fflags +genpts \
            "$mp4_file" -y 2>&1 | tee -a "$LOG_FILE"
        
        FFMPEG_RC=${PIPESTATUS[0]:-1}
        
        # Clean up pass log files
        rm -f "$work_dir/ffmpeg2pass"*
        
        if [ "$FFMPEG_RC" -eq 0 ]; then
            local output_size_mb=$(stat -c%s "$mp4_file" 2>/dev/null)
            output_size_mb=$((output_size_mb / 1048576))
            
            if [ "$source_size_mb" -gt 0 ] && [ "$output_size_mb" -gt 0 ]; then
                local reduction_pct=$(( (source_size_mb - output_size_mb) * 100 / source_size_mb ))
                echo_success "[STEP 1] Conversion complete: ${source_size_mb}MB → ${output_size_mb}MB (${reduction_pct}% reduction)"
            else
                echo_success "[STEP 1] Conversion complete: ${output_size_mb}MB"
            fi
        else
            echo_error "[STEP 1] Conversion failed: $filename (ffmpeg rc=$FFMPEG_RC)"
            cat "$LOG_FILE" | tail -20
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
    
    # Step 3: Get duration from CONVERTED file (more reliable than source)
    local duration=$(get_duration_seconds "$mp4_file")
    if [ "$duration" -le 0 ]; then
        echo_warning "[STEP 2] Cannot determine exact duration, will attempt chunking anyway"
        # Estimate chunks from file size
        local mp4_size=$(stat -c%s "$mp4_file" 2>/dev/null)
        local estimated_chunks=$(( (mp4_size / (MAX_CHUNK_SIZE_MB * 1048576)) + 1 ))
        echo_info "[STEP 2] Will attempt to create approximately $estimated_chunks chunks"
        duration=999999  # Large number to allow loop to run
    else
        echo_info "[STEP 2] Duration: ${duration}s, will create $(( (duration / CHUNK_LEN) + 1 )) chunks"
    fi
    
    # Step 4: Split into chunks with VALIDATION
    local chunk_num=1
    local offset=0
    local chunks_created=0
    
    while [ $offset -lt $duration ]; do
        local chunk_file="$work_dir/${basename_no_ext}-$(printf "%03d" $chunk_num).mp4"
        echo_progress "[STEP 2] Creating chunk $chunk_num..."
        
        # Split using copy codec for speed
        if ffmpeg -i "$mp4_file" -vcodec copy -acodec copy \
            -ss $offset -t $CHUNK_LEN "$chunk_file" -y -loglevel error 2>/dev/null; then
            
            # CRITICAL: Check if chunk was actually created and has meaningful content
            if [ -f "$chunk_file" ]; then
                local chunk_size=$(stat -c%s "$chunk_file" 2>/dev/null || echo "0")
                if [ "$chunk_size" -gt 1000 ]; then  # At least 1KB to be valid
                    # Generate chunk name
                    local new_name=$(generate_chunk_name "$basename_no_ext" "$chunk_num" "mp4")
                    
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
                    echo_info "[STEP 2] Reached end of file (chunk too small)"
                    break
                fi
            else
                # No more chunks to create
                echo_info "[STEP 2] No more chunks to create"
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
        
        # SAFETY LIMIT: Prevent infinite loops
        if [ $chunk_num -gt 100 ]; then
            echo_warning "[STEP 2] Stopping after 100 chunks (safety limit)"
            break
        fi
    done
    
    # Cleanup temporary MP4
    if [ "$DELETE_TEMP_MP4_AFTER_SPLITTING" = true ]; then
        rm -f "$mp4_file"
        echo_info "[STEP 2] Deleted temporary MP4"
    fi
    
    rm -rf "$work_dir"
    
    # Archive original MKV file (only if we created chunks successfully)
    if [ "$MOVE_ORIGINAL_AFTER_PROCESSING" = true ] && [ $chunks_created -gt 0 ]; then
        if mv "$mkv_filepath" "$MOTHER_DIR/" 2>/dev/null; then
            echo_info "[STEP 4] Archived original: $filename"
        else
            echo_warning "[STEP 4] Failed to archive: $filename"
        fi
    fi
    
    if [ $chunks_created -gt 0 ]; then
        echo_success "MKV processing complete: $filename ($chunks_created chunks created)"
        return 0
    else
        echo_error "MKV processing failed: $filename (no chunks created)"
        return 1
    fi
}

# =========================================================================
# STATUS AND REPORTING
# =========================================================================

show_status() {
    echo_info "=========================================="
    echo_info "STATUS REPORT"
    echo_info "=========================================="
    
    # Analyze source directory
    if [ -d "$SOURCE_DIR" ]; then
        local mkv_count=$(find "$SOURCE_DIR" -name "*.mkv" -type f 2>/dev/null | wc -l)
        
        echo_info "Source Directory: $SOURCE_DIR"
        echo_info "  MKV files: $mkv_count"
        
        # Show file patterns
        local patterns=$(find "$SOURCE_DIR" -name "*.mkv" -type f 2>/dev/null | \
            sed 's|.*/||' | sed 's/_[0-9]\{4\}_.*//g' | sort -u)
        
        if [ -n "$patterns" ]; then
            echo_info "File Patterns Found:"
            for pattern in $patterns; do
                local mkv_cnt=$(find "$SOURCE_DIR" -name "${pattern}_*.mkv" -type f 2>/dev/null | wc -l)
                if [ $mkv_cnt -gt 0 ]; then
                    echo_info "  $pattern: MKV=$mkv_cnt"
                fi
            done
        fi
    fi
    
    # Analyze upload directory
    if [ -d "$UPLOAD_DIR" ]; then
        local upload_mp4=$(find "$UPLOAD_DIR" -name "*.mp4" -type f 2>/dev/null | wc -l)
        local upload_size=$(du -sh "$UPLOAD_DIR" 2>/dev/null | cut -f1 || echo "0")
        
        echo_info "Upload Directory: $UPLOAD_DIR"
        echo_info "  MP4 chunks: $upload_mp4"
        echo_info "  Total size: $upload_size"
    fi
    
    # Analyze archive directory
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

PID_DIR="/tmp/media_processor_pids_$$"
mkdir -p "$PID_DIR"

# Clean up PID directory on exit
cleanup_pid_dir() {
    rm -rf "$PID_DIR" 2>/dev/null || true
}
trap cleanup_pid_dir EXIT

# Register a background job
register_job() {
    local pid=$1
    local filename=$2
    
    # Ensure PID directory exists
    if [ ! -d "$PID_DIR" ]; then
        mkdir -p "$PID_DIR" 2>/dev/null || {
            echo_warning "Cannot create PID directory: $PID_DIR"
            return 1
        }
    fi
    
    # Write PID file
    echo "$filename" > "$PID_DIR/${pid}.pid" 2>/dev/null || {
        echo_warning "Cannot write PID file for: $filename"
        return 1
    }
}

# Unregister a completed job
unregister_job() {
    local pid=$1
    rm -f "$PID_DIR/${pid}.pid" 2>/dev/null
}

# Count ACTUAL active jobs
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

# Show currently running jobs
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
# PROCESSING WRAPPER FUNCTIONS WITH JOB TRACKING
# =========================================================================

# Wrapper for MKV processing with job tracking
process_mkv_with_tracking() {
    local file="$1"
    local my_pid=$$
    local filename=$(basename "$file")
    
    register_job $my_pid "$filename"
    
    if process_mkv_file "$file"; then
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
    local mkv_files=()
    
    # Collect MKV files only
    echo_info "Scanning for MKV files..."
    
    while IFS= read -r -d '' file; do
        mkv_files+=("$file")
    done < <(find "$SOURCE_DIR" -name "*.mkv" -type f -print0 2>/dev/null | sort -z)
    
    local total_mkv=${#mkv_files[@]}
    
    if [ $total_mkv -eq 0 ]; then
        echo_warning "No MKV files found to process"
        return 0
    fi
    
    echo_info "Found $total_mkv MKV files"
    echo_info "Starting concurrent processing (max $MAX_PARALLEL_JOBS parallel jobs)..."
    echo ""
    
    local mkv_idx=0
    local jobs_started=0
    local start_time=$(date +%s)
    
    # Main processing loop
    while [ $mkv_idx -lt $total_mkv ]; do
        
        # Wait for available slot
        while [ $(count_active_jobs) -ge $MAX_PARALLEL_JOBS ]; do
            sleep 1
        done
        
        # Start next MKV job
        local file="${mkv_files[$mkv_idx]}"
        local fname=$(basename "$file")
        echo_info "[MKV $((mkv_idx + 1))/$total_mkv] Starting: $fname"
        
        (
            if process_mkv_with_tracking "$file"; then
                echo_success "[MKV $((mkv_idx + 1))/$total_mkv] Completed: $fname"
            else
                echo_error "[MKV $((mkv_idx + 1))/$total_mkv] Failed: $fname"
            fi
        ) &
        
        local job_pid=$!
        echo_info "  → Job PID: $job_pid"
        
        ((mkv_idx++))
        ((jobs_started++))
        
        # Show progress periodically
        if [ $((jobs_started % 5)) -eq 0 ] && [ $jobs_started -gt 0 ]; then
            local elapsed=$(($(date +%s) - start_time))
            local active=$(count_active_jobs)
            echo ""
            echo_progress "═══════════════════════════════════════"
            echo_progress "Progress: $jobs_started/$total_mkv jobs started"
            echo_progress "Active jobs: $active / $MAX_PARALLEL_JOBS"
            echo_progress "Elapsed time: ${elapsed}s"
            show_running_jobs
            echo_progress "═══════════════════════════════════════"
            echo ""
        fi
        
        sleep 0.5
    done
    
    # Wait for all remaining jobs to complete
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
    local avg_time=$((total_mkv > 0 ? total_time / total_mkv : 0))
    
    echo ""
    echo_success "═══════════════════════════════════════"
    echo_success "Processing completed in $total_time seconds"
    echo_success "Files processed: $total_mkv"
    echo_success "Average time per file: ${avg_time}s"
    echo_success "═══════════════════════════════════════"
}

# =========================================================================
# CLEANUP HANDLER
# =========================================================================

cleanup() {
    echo ""
    echo_warning "Interrupt received! Cleaning up..."
    
    # Kill all tracked jobs
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
    
    rm -rf /tmp/mkv_$$_* 2>/dev/null || true
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
    
    echo_info "=========================================="
    echo_info "  PRODUCTION MKV MEDIA PROCESSOR"
    echo_info "=========================================="
    echo_info "Checking prerequisites..."
    
    if ! command -v ffmpeg &> /dev/null; then
        echo_error "ffmpeg is not installed or not in PATH"
        echo_info "Install with: sudo apt-get install ffmpeg"
        exit 1
    fi
    
    if ! command -v ffprobe &> /dev/null; then
        echo_warning "ffprobe not found - duration detection may be less reliable"
        echo_info "Install with: sudo apt-get install ffmpeg (includes ffprobe)"
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
        echo_info "Speed: ULTRA-FAST (~2 min per hour) ⚡⚡⚡"
        echo_info "Size: Same as source (no reduction)"
    elif [ "$USE_FAST_MODE" = true ]; then
        echo_info "Mode: FAST (single-pass CBR) ← ACTIVE"
        echo_info "Speed: FAST (~15 min per hour) ⚡⚡"
        echo_info "Target: Fixed ${MAX_CHUNK_SIZE_MB}MB per chunk"
    else
        echo_info "Mode: INTELLIGENT (2-pass VBR)"
        echo_info "Speed: SLOW (~55 min per hour) ⚡"
        echo_info "Target: ${TARGET_SIZE_RATIO}x source, max ${MAX_CHUNK_SIZE_MB}MB per chunk"
    fi
    echo_info "=========================================="
    echo ""
    
    process_files_concurrently
    
    echo ""
    show_status
    
    echo ""
    echo_success "=========================================="
    echo_success "    PROCESSING COMPLETED!                 "
    echo_success "=========================================="
    echo_success "Upload-ready files: $UPLOAD_DIR"
    echo_success "Archived originals: $MOTHER_DIR"
    echo_success "=========================================="
    echo ""
}

# Run main function
main "$@"
