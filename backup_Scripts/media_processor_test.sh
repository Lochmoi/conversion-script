#!/bin/bash

# =========================================================================
#.mkv /mp3 media processing
# =========================================================================
# Features:
# - Converts .mkv files to .mp4 and splits into 10-minute chunks
# - Splits .mp3 files directly into 10-minute chunks
# - Dynamic naming support for any PREFIX_IDENTIFIER pattern
# - Concurrent file  processing 
# - Automatic file archival after processing
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
SOURCE_DIR="/home/lochmoi/bash/testfiles"           # Directory containing source files
UPLOAD_DIR="/home/lochmoi/bash/upload_ready"      # Directory for processed chunks
MOTHER_DIR="/home/lochmoi/bash/mother"            # Archive directory for originals
CHUNK_LEN=600                                # Chunk length in seconds (10 minutes)
MAX_PARALLEL_JOBS=4                         # Maximum concurrent processing jobs

# Processing options
MOVE_ORIGINAL_AFTER_PROCESSING=true         # Move originals to archive after processing
DELETE_TEMP_MP4_AFTER_SPLITTING=true        # Delete temporary MP4 after splitting

# Video encoding settings (for MKV to MP4 conversion)
VIDEO_CODEC="libx264"
VIDEO_PRESET="ultrafast"                    # ultrafast, superfast, veryfast, faster, fast, medium, slow
VIDEO_CRF=28                                 # Quality (0-51, lower = better quality, 23 = default)
VIDEO_SCALE="-2:480"                         # Scale to 480p height, width auto-calculated
VIDEO_FPS=30                                 # Target FPS
AUDIO_CODEC="aac"
AUDIO_BITRATE="128k"

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

# Get duration of media file in seconds
get_duration_seconds() {
    local file="$1"
    local duration_hms=$(ffmpeg -i "$file" 2>&1 | grep Duration | cut -f 4 -d ' ' | tr -d ',')
    
    if [ -z "$duration_hms" ]; then
        echo "0"
        return
    fi
    
    local h=$(echo "$duration_hms" | cut -d ':' -f 1 | sed 's/^0*//')
    local m=$(echo "$duration_hms" | cut -d ':' -f 2 | sed 's/^0*//')
    local s=$(echo "$duration_hms" | cut -d ':' -f 3 | cut -d '.' -f 1 | sed 's/^0*//')
    
    h=${h:-0}
    m=${m:-0}
    s=${s:-0}
    
    echo $(( (10#$h * 60 + 10#$m) * 60 + 10#$s ))
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

# Process MP3 file - split into 10-minute chunks
process_mp3_file() {
    local mp3_filepath="$1"
    local filename=$(basename "$mp3_filepath")
    local basename_no_ext="${filename%.*}"
    
    echo_info "=========================================="
    echo_info "Processing MP3: $filename"
    echo_info "=========================================="
    
    # Create unique temporary directory
    local work_dir="/tmp/mp3_$$_$(date +%s)_${RANDOM}"
    mkdir -p "$work_dir"
    
    # Validate media file
    if ! is_media_file "$mp3_filepath"; then
        echo_warning "Invalid media file: $filename"
        rm -rf "$work_dir"
        return 1
    fi
    
    # Get duration
    local duration=$(get_duration_seconds "$mp3_filepath")
    if [ "$duration" -le 0 ]; then
        echo_error "Invalid duration for: $filename"
        rm -rf "$work_dir"
        return 1
    fi
    
    echo_info "Duration: ${duration}s, will create $(( (duration / CHUNK_LEN) + 1 )) chunks"
    
    # Process chunks
    local chunk_num=1
    local offset=0
    local chunks_created=0
    
    while [ $offset -lt $duration ]; do
        local chunk_file="$work_dir/${basename_no_ext}-$(printf "%03d" $chunk_num).mp3"
        echo_progress "Creating chunk $chunk_num..."
        
        # Extract chunk (using copy codec for speed)
        if ffmpeg -i "$mp3_filepath" -acodec copy -ss $offset -t $CHUNK_LEN "$chunk_file" -y -loglevel error 2>/dev/null; then
            # Generate proper name and move to upload directory
            local new_name=$(generate_chunk_name "$basename_no_ext" "$chunk_num" "mp3")
            
            if mv "$chunk_file" "$UPLOAD_DIR/$new_name" 2>/dev/null; then
                echo_success "Chunk ready: $new_name"
                ((chunks_created++))
            else
                echo_error "Failed to move chunk: $chunk_file"
            fi
        else
            echo_error "Failed to create chunk $chunk_num"
        fi
        
        ((chunk_num++))
        ((offset += CHUNK_LEN))
    done
    
    # Cleanup
    rm -rf "$work_dir"
    
    # Archive original
    if [ "$MOVE_ORIGINAL_AFTER_PROCESSING" = true ] && [ $chunks_created -gt 0 ]; then
        if mv "$mp3_filepath" "$MOTHER_DIR/" 2>/dev/null; then
            echo_info "Archived original: $filename"
        else
            echo_warning "Failed to archive: $filename"
        fi
    fi
    
    echo_success "MP3 processing complete: $filename ($chunks_created chunks)"
    return 0
}

# Process MKV file - convert to MP4 then split
process_mkv_file() {
    local mkv_filepath="$1"
    local filename=$(basename "$mkv_filepath")
    local basename_no_ext="${filename%.*}"
    
    echo_info "=========================================="
    echo_info "Processing MKV: $filename"
    echo_info "=========================================="
    
    # Create unique temporary directory
    local work_dir="/tmp/mkv_$$_$(date +%s)_${RANDOM}"
    mkdir -p "$work_dir"
    
    # Step 1: Convert MKV to MP4
    local mp4_file="$work_dir/${basename_no_ext}.mp4"
    echo_info "Converting to MP4..."
    
    if ffmpeg -hide_banner -i "$mkv_filepath" \
        -c:v $VIDEO_CODEC -preset $VIDEO_PRESET -crf $VIDEO_CRF \
        -vf "scale=$VIDEO_SCALE,fps=fps=$VIDEO_FPS" \
        -c:a $AUDIO_CODEC -b:a $AUDIO_BITRATE \
        -max_muxing_queue_size 9999 \
        -avoid_negative_ts make_zero -fflags +genpts \
        "$mp4_file" -y -loglevel error 2>/dev/null; then
        echo_success "Conversion complete"
    else
        echo_error "Conversion failed: $filename"
        rm -rf "$work_dir"
        return 1
    fi
    
    # Step 2: Get duration
    local duration=$(get_duration_seconds "$mp4_file")
    if [ "$duration" -le 0 ]; then
        echo_error "Invalid duration for converted file"
        rm -rf "$work_dir"
        return 1
    fi
    
    echo_info "Duration: ${duration}s, will create $(( (duration / CHUNK_LEN) + 1 )) chunks"
    
    # Step 3: Split into chunks
    local chunk_num=1
    local offset=0
    local chunks_created=0
    
    while [ $offset -lt $duration ]; do
        local chunk_file="$work_dir/${basename_no_ext}-$(printf "%03d" $chunk_num).mp4"
        echo_progress "Creating chunk $chunk_num..."
        
        if ffmpeg -i "$mp4_file" -vcodec copy -acodec copy -ss $offset -t $CHUNK_LEN "$chunk_file" -y -loglevel error 2>/dev/null; then
            local new_name=$(generate_chunk_name "$basename_no_ext" "$chunk_num" "mp4")
            if mv "$chunk_file" "$UPLOAD_DIR/$new_name" 2>/dev/null; then
                echo_success "Chunk ready: $new_name"
                ((chunks_created++))
            else
                echo_error "Failed to move chunk: $chunk_file"
            fi
        else
            echo_error "Failed to create chunk $chunk_num"
        fi
        
        ((chunk_num++))
        ((offset += CHUNK_LEN))
    done 
    # Cleanup
    if [ "$DELETE_TEMP_MP4_AFTER_SPLITTING" = true ]; then
        rm -f "$mp4_file"
    fi
    rm -rf "$work_dir"
    
    # Archive original
    if [ "$MOVE_ORIGINAL_AFTER_PROCESSING" = true ] && [ $chunks_created -gt 0 ]; then
        if mv "$mkv_filepath" "$MOTHER_DIR/" 2>/dev/null; then
            echo_info "Archived original: $filename"
        else
            echo_warning "Failed to archive: $filename"
        fi
    fi
    
    echo_success "MKV processing complete: $filename ($chunks_created chunks)"
    return 0
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
        local mp3_count=$(find "$SOURCE_DIR" -name "*.mp3" -type f 2>/dev/null | wc -l)
        
        echo_info "Source Directory: $SOURCE_DIR"
        echo_info "  MKV files: $mkv_count"
        echo_info "  MP3 files: $mp3_count"
        
        # Show file patterns
        local patterns=$(find "$SOURCE_DIR" -name "*.*" -type f 2>/dev/null | \
            sed 's|.*/||' | sed 's/_[0-9]\{4\}_.*//g' | sort -u)
        
        if [ -n "$patterns" ]; then
            echo_info "File Patterns Found:"
            for pattern in $patterns; do
                local mkv_cnt=$(find "$SOURCE_DIR" -name "${pattern}_*.mkv" -type f 2>/dev/null | wc -l)
                local mp3_cnt=$(find "$SOURCE_DIR" -name "${pattern}_*.mp3" -type f 2>/dev/null | wc -l)
                if [ $mkv_cnt -gt 0 ] || [ $mp3_cnt -gt 0 ]; then
                    echo_info "  $pattern: MKV=$mkv_cnt, MP3=$mp3_cnt"
                fi
            done
        fi
    fi
    
    # Analyze upload directory
    if [ -d "$UPLOAD_DIR" ]; then
        local upload_mp4=$(find "$UPLOAD_DIR" -name "*.mp4" -type f 2>/dev/null | wc -l)
        local upload_mp3=$(find "$UPLOAD_DIR" -name "*.mp3" -type f 2>/dev/null | wc -l)
        local upload_size=$(du -sh "$UPLOAD_DIR" 2>/dev/null | cut -f1 || echo "0")
        
        echo_info "Upload Directory: $UPLOAD_DIR"
        echo_info "  MP4 chunks: $upload_mp4"
        echo_info "  MP3 chunks: $upload_mp3"
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
# CONCURRENT PROCESSING
# =========================================================================

process_files_concurrently() {
    local mkv_files=()
    local mp3_files=()
    
    # Collect files
    echo_info "Scanning for files..."
    
    while IFS= read -r -d '' file; do
        mkv_files+=("$file")
    done < <(find "$SOURCE_DIR" -name "*.mkv" -type f -print0 2>/dev/null | sort -z)
    
    while IFS= read -r -d '' file; do
        mp3_files+=("$file")
    done < <(find "$SOURCE_DIR" -name "*.mp3" -type f -print0 2>/dev/null | sort -z)
    
    local total_mkv=${#mkv_files[@]}
    local total_mp3=${#mp3_files[@]}
    local total_files=$((total_mkv + total_mp3))
    
    if [ $total_files -eq 0 ]; then
        echo_warning "No files found to process"
        return 0
    fi
    
    echo_info "Found $total_mkv MKV and $total_mp3 MP3 files"
    echo_info "Starting concurrent processing (max $MAX_PARALLEL_JOBS parallel jobs)..."
    
    local mkv_idx=0
    local mp3_idx=0
    local jobs_started=0
    local start_time=$(date +%s)
    
    # Process all files
    while [ $mkv_idx -lt $total_mkv ] || [ $mp3_idx -lt $total_mp3 ]; do
        
        # Process MKV files
        while [ $mkv_idx -lt $total_mkv ] && [ $(jobs -r | wc -l) -lt $MAX_PARALLEL_JOBS ]; do
            local file="${mkv_files[$mkv_idx]}"
            local fname=$(basename "$file")
            echo_info "[$((mkv_idx + 1))/$total_mkv] Starting: $fname"
            
            (
                if process_mkv_file "$file"; then
                    echo_success "[$((mkv_idx + 1))/$total_mkv] Completed: $fname"
                else
                    echo_error "[$((mkv_idx + 1))/$total_mkv] Failed: $fname"
                fi
            ) &
            
            ((mkv_idx++))
            ((jobs_started++))
            sleep 0.2
        done
        
        # Process MP3 files
        while [ $mp3_idx -lt $total_mp3 ] && [ $(jobs -r | wc -l) -lt $MAX_PARALLEL_JOBS ]; do
            local file="${mp3_files[$mp3_idx]}"
            local fname=$(basename "$file")
            echo_info "[$((mp3_idx + 1))/$total_mp3] Starting: $fname"
            
            (
                if process_mp3_file "$file"; then
                    echo_success "[$((mp3_idx + 1))/$total_mp3] Completed: $fname"
                else
                    echo_error "[$((mp3_idx + 1))/$total_mp3] Failed: $fname"
                fi
            ) &
            
            ((mp3_idx++))
            ((jobs_started++))
            sleep 0.2
        done
        
        # Wait if max jobs reached
        while [ $(jobs -r | wc -l) -ge $MAX_PARALLEL_JOBS ]; do
            sleep 1
        done
        
        # Show progress
        if [ $((jobs_started % 10)) -eq 0 ]; then
            local elapsed=$(($(date +%s) - start_time))
            echo_progress "Started $jobs_started/$total_files jobs (${elapsed}s elapsed)"
        fi
    done
    
    # Wait for all jobs to complete
    echo_info "Waiting for all jobs to complete..."
    wait
    
    local end_time=$(date +%s)
    local total_time=$((end_time - start_time))
    
    echo_success "Processing completed in $total_time seconds"
    echo_success "Processed: $total_mkv MKV files, $total_mp3 MP3 files"
}

# =========================================================================
# CLEANUP HANDLER
# =========================================================================

cleanup() {
    echo ""
    echo_warning "Interrupt received! Cleaning up..."
    
    # Kill all background jobs
    jobs -p | xargs -r kill 2>/dev/null || true
    
    # Wait briefly for jobs to terminate
    sleep 2
    
    # Force kill if still running
    jobs -p | xargs -r kill -9 2>/dev/null || true
    
    # Clean up temporary directories
    rm -rf /tmp/mkv_$$_* 2>/dev/null || true
    rm -rf /tmp/mp3_$$_* 2>/dev/null || true
    
    # Remove lockfile
    rm -f "$LOCKFILE"
    
    echo_info "Cleanup complete"
    exit 0
}

# =========================================================================
# MAIN EXECUTION
# =========================================================================

main() {
    # Set up signal handlers
    trap cleanup SIGINT SIGTERM
    
    # Check prerequisites
    echo_info "Checking prerequisites..."
    
    if ! command -v ffmpeg &> /dev/null; then
        echo_error "ffmpeg is not installed or not in PATH"
        echo_info "Install with: sudo apt-get install ffmpeg"
        exit 1
    fi
    
    if [ ! -d "$SOURCE_DIR" ]; then
        echo_error "Source directory does not exist: $SOURCE_DIR"
        exit 1
    fi
    
    # Create required directories
    mkdir -p "$UPLOAD_DIR" "$MOTHER_DIR"
    
    # Show initial status
    show_status
    
    # Start processing
    echo ""
    echo_info "Starting processing at $(date)"
    echo ""
    
    process_files_concurrently
    
    # Show final status
    echo ""
    show_status
    
    echo ""
    echo_success "=========================================="
    echo_success "         PROCESSING COMPLETED!            "
    echo_success "=========================================="
    echo_success "Upload-ready files: $UPLOAD_DIR"
    echo_success "Archived originals: $MOTHER_DIR"
    echo_success "=========================================="
    echo ""
}

# =========================================================================
# SCRIPT ENTRY POINT
# =========================================================================

# Run main function with all arguments
main "$@"
