#!/bin/bash

# Automate .asf to mp4 conversion, split, and rename
# Process SNTV and SNLTV files concurrently to reduce processing time

#Lock file to avoid multiple instances
LOCKFILE="/var/run/master.lock"

# Check if lockfile exists and if the process is actually running
if [ -f "$LOCKFILE" ]; then
    LOCK_PID=$(cat "$LOCKFILE" 2>/dev/null)
    if [ -n "$LOCK_PID" ] && kill -0 "$LOCK_PID" 2>/dev/null; then
        echo "Script already running with PID $LOCK_PID, exiting"
        exit 1
    else
        echo "Removing stale lockfile"
        rm -f "$LOCKFILE"
    fi
fi

echo $$ > "$LOCKFILE"
trap "rm -f $LOCKFILE" EXIT

set -e  # Exit on error

# Configs
SOURCE_DIR="/home/ftp_so/Somalia_Region_recordings"
UPLOAD_DIR="/home/micah/upload_ready"
CHUNK_LEN=600  # 10 minutes
MAX_PARALLEL_JOBS=2  # Process SNTV and SNLTV simultaneously

# File cleanup settings
DELETE_ASF_AFTER_CONVERSION=true
DELETE_MP4_AFTER_SPLITTING=true

echo_info() { echo "[INFO] $1"; }
echo_success() { echo "[SUCCESS] $1"; }
echo_warning() { echo "[WARNING] $1"; }
echo_error() { echo "[ERROR] $1"; }

# Function to check if a file is a media file
is_media_file() {
    ffmpeg -i "$1" -hide_banner 2>&1 | grep -q "Duration"
}

# Create upload directory
mkdir -p "$UPLOAD_DIR"

# Process a single .asf file completely (convert -> split -> rename -> upload)
process_single_file() {
    local asf_filepath="$1"
    local filename=$(basename "$asf_filepath")
    local basename_no_ext="${filename%.*}"
    
    echo_info "=========================================="
    echo_info "Processing: $filename"
    echo_info "=========================================="
    
    # Create temporary working directory for this file
    local work_dir="/tmp/process_$$_$(date +%s)"
    mkdir -p "$work_dir"
    
    # Step 1: Convert ASF to MP4
    local mp4_file="$work_dir/$basename_no_ext.mp4"
    echo_info "[STEP 1] Converting ASF to MP4..."
    
    #if ffmpeg -i "$asf_filepath" -c:v libx264 -preset fast -c:a aac -max_muxing_queue_size 9999 -avoid_negative_ts make_zero -fflags +genpts "$mp4_file" -y; then
    if ffmpeg -i "$asf_filepath" -c:v libx264 -preset ultrafast -crf 28 -vf "scale=-2:480"  -c:a aac -b:a 98k -max_muxing_queue_size 9999 -avoid_negative_ts make_zero -fflags +genpts "$mp4_file" -y; then
        echo_success "[STEP 1] Conversion completed: $filename"
        
        # Delete ASF file after successful conversion
        if [ "$DELETE_ASF_AFTER_CONVERSION" = true ]; then
            rm -f "$asf_filepath"
            echo_info "[STEP 1] Deleted original ASF: $filename"
        fi
    else
        echo_error "[STEP 1] Failed to convert: $filename"
        rm -rf "$work_dir"
        return 1
    fi
    
    # Step 2: Split MP4 into chunks
    echo_info "[STEP 2] Splitting MP4 into 10-minute chunks..."
    cd "$work_dir" || {
        echo_error "[STEP 2] Could not change to working directory"
        rm -rf "$work_dir"
        return 1
    }
    
    local IN_FILE="$basename_no_ext.mp4"
    
    if ! is_media_file "$IN_FILE"; then
        echo_warning "[STEP 2] Skipping non-media file: $IN_FILE"
        cd - > /dev/null
        rm -rf "$work_dir"
        return 1
    fi
    
    # Extract duration in seconds (same logic as original)
    DURATION_HMS=$(ffmpeg -i "$IN_FILE" 2>&1 | grep Duration | cut -f 4 -d ' ' | tr -d ',')
    DURATION_H=$(echo "$DURATION_HMS" | cut -d ':' -f 1 | sed 's/^0*//')
    DURATION_M=$(echo "$DURATION_HMS" | cut -d ':' -f 2 | sed 's/^0*//')
    DURATION_S=$(echo "$DURATION_HMS" | cut -d ':' -f 3 | cut -d '.' -f 1 | sed 's/^0*//')
    
    # Handle empty values
    DURATION_H=${DURATION_H:-0}
    DURATION_M=${DURATION_M:-0}
    DURATION_S=${DURATION_S:-0}
    
    let "DURATION = (10#$DURATION_H * 60 + 10#$DURATION_M) * 60 + 10#$DURATION_S"
    
    if [ "$DURATION" -le 0 ]; then
        echo_error "[STEP 2] Invalid or zero duration for: $IN_FILE"
        cd - > /dev/null
        rm -rf "$work_dir"
        return 1
    fi
    
    FILE_EXT="${IN_FILE##*.}"
    FILE_NAME="${IN_FILE%.*}"
    OUT_FMT="${FILE_NAME}-%03d.${FILE_EXT}"
    
    N=1
    OFFSET=0
    let "N_FILES = DURATION / CHUNK_LEN + 1"
    local chunks_created=0
    
    echo_info "[STEP 2] Will create $N_FILES chunks from $DURATION second video"
    
    while [ "$OFFSET" -lt "$DURATION" ]; do
        OUT_FILE=$(printf "$OUT_FMT" "$N")
        echo_info "[STEP 2] Creating chunk $N/$N_FILES: $OUT_FILE"
        
        if ffmpeg -i "$IN_FILE" -vcodec copy -acodec copy -ss "$OFFSET" -t "$CHUNK_LEN" "$OUT_FILE" -y; then
            echo_success "[STEP 2] Created chunk: $OUT_FILE"
            
            # Step 3: Immediately rename and move this chunk to upload directory
            echo_info "[STEP 3] Renaming chunk: $OUT_FILE"
            
            local base="${OUT_FILE%.*}"
            
            # Extract components using sed (same logic as original)
            date=$(echo "$base" | sed -E 's/^S[N]*[L]*TV_([0-9]{4}-[0-9]{2}-[0-9]{2})_.*/\1/')
            hour=$(echo "$base" | sed -E 's/^S[N]*[L]*TV_[0-9]{4}-[0-9]{2}-[0-9]{2}_([0-9]{2})-.*/\1/')
            index=$(echo "$base" | sed -E 's/^.*-([0-9]{3})$/\1/')
            
            # Compute minute from index
            idx_num=$((10 * (${index#0} - 1)))
            minute=$(printf "%02d" "$idx_num")
            
            # Format date and rename
            date_fmt="${date//-/_}"
            
            if [[ "$OUT_FILE" == SNLTV_* ]]; then
                new_name="SO_SLN_${date_fmt}_${hour}-${minute}-03.mp4"
            elif [[ "$OUT_FILE" == SNTV_* ]]; then
                new_name="SO_SNT_${date_fmt}_${hour}-${minute}-03.mp4"
            else
                echo_warning "[STEP 3] Unknown file prefix for: $OUT_FILE"
                let "N = N + 1"
                let "OFFSET = OFFSET + CHUNK_LEN"
                continue
            fi
            
            # Move chunk to upload directory
            if mv "$OUT_FILE" "$UPLOAD_DIR/$new_name"; then
                echo_success "[STEP 3] Chunk ready for upload: $new_name"
                ((chunks_created++))
            else
                echo_error "[STEP 3] Failed to move chunk: $OUT_FILE"
            fi
            
            let "N = N + 1"
            let "OFFSET = OFFSET + CHUNK_LEN"
        else
            echo_error "[STEP 2] Failed to create chunk: $OUT_FILE"
            cd - > /dev/null
            rm -rf "$work_dir"
            return 1
        fi
    done
    
    # Delete original MP4 after successful splitting
    if [ "$DELETE_MP4_AFTER_SPLITTING" = true ]; then
        rm -f "$IN_FILE"
        echo_info "[STEP 2] Deleted original MP4: $IN_FILE"
    fi
    
    cd - > /dev/null
    rm -rf "$work_dir"
    
    echo_success "File processing completed: $filename ($chunks_created chunks created)"
    return 0
}

# Enhanced status function with file type breakdown
show_status() {
    local asf_count=$(find "$SOURCE_DIR" -name "S*TV_*.asf" -type f 2>/dev/null | wc -l)
    local sntv_count=$(find "$SOURCE_DIR" -name "SNTV_*.asf" -type f 2>/dev/null | wc -l)
    local snltv_count=$(find "$SOURCE_DIR" -name "SNLTV_*.asf" -type f 2>/dev/null | wc -l)
    local upload_count=$(find "$UPLOAD_DIR" -name "*.mp4" -type f 2>/dev/null | wc -l)
    local upload_size=""
    
    if [ -d "$UPLOAD_DIR" ] && [ $upload_count -gt 0 ]; then
        upload_size=$(du -sh "$UPLOAD_DIR" 2>/dev/null | cut -f1)
    fi
    
    echo_info "STATUS: Total ASF remaining: $asf_count (SNTV: $sntv_count, SNLTV: $snltv_count) | Upload ready: $upload_count files ($upload_size)"
}

# Process SNTV and SNLTV files concurrently
process_files_concurrently() {
    local sntv_files=()
    local snltv_files=()
    
    # Collect SNTV files
    for file in "$SOURCE_DIR"/SNTV_*.asf; do
        [ -e "$file" ] && sntv_files+=("$file")
    done
    
    # Collect SNLTV files
    for file in "$SOURCE_DIR"/SNLTV_*.asf; do
        [ -e "$file" ] && snltv_files+=("$file")
    done
    
    local sntv_count=${#sntv_files[@]}
    local snltv_count=${#snltv_files[@]}
    
    echo_info "Found $sntv_count SNTV files and $snltv_count SNLTV files"
    
    if [ $sntv_count -eq 0 ] && [ $snltv_count -eq 0 ]; then
        echo_info "No .asf files found to process"
        return 0
    fi
    
    local sntv_index=0
    local snltv_index=0
    local processed_count=0
    
    # Process both types concurrently
    while [ $sntv_index -lt $sntv_count ] || [ $snltv_index -lt $snltv_count ]; do
        
        # Start SNTV processing if available and not already processing max jobs
        if [ $sntv_index -lt $sntv_count ] && [ $(jobs -r | wc -l) -lt $MAX_PARALLEL_JOBS ]; then
            local sntv_file="${sntv_files[$sntv_index]}"
            echo_info "Starting SNTV processing: $(basename "$sntv_file")"
            (
                if process_single_file "$sntv_file"; then
                    echo_info "CONCURRENT: SNTV completed - $(basename "$sntv_file")"
                else
                    echo_error "CONCURRENT: SNTV failed - $(basename "$sntv_file")"
                fi
            ) &
            ((sntv_index++))
            ((processed_count++))
            sleep 1
        fi
        
        # Start SNLTV processing if available and not already processing max jobs
        if [ $snltv_index -lt $snltv_count ] && [ $(jobs -r | wc -l) -lt $MAX_PARALLEL_JOBS ]; then
            local snltv_file="${snltv_files[$snltv_index]}"
            echo_info "Starting SNLTV processing: $(basename "$snltv_file")"
            (
                if process_single_file "$snltv_file"; then
                    echo_info "CONCURRENT: SNLTV completed - $(basename "$snltv_file")"
                else
                    echo_error "CONCURRENT: SNLTV failed - $(basename "$snltv_file")"
                fi
            ) &
            ((snltv_index++))
            ((processed_count++))
            sleep 1
        fi
        
        # Wait if we have max jobs running
        while [ $(jobs -r | wc -l) -ge $MAX_PARALLEL_JOBS ]; do
            sleep 3
        done
        
        # Show progress every few files
        if [ $((processed_count % 4)) -eq 0 ]; then
            show_status
        fi
    done
    
    # Wait for all background jobs to complete
    echo_info "Waiting for all processing jobs to complete..."
    wait
    
    echo_success "Concurrent processing completed!"
    echo_info "SNTV files processed: $sntv_count"
    echo_info "SNLTV files processed: $snltv_count"
}

# Main execution
main() {
    echo_info "Starting concurrent ASF processing pipeline..."
    echo_info "=========================================="
    
    # Check if ffmpeg is available
    if ! command -v ffmpeg &> /dev/null; then
        echo_error "ffmpeg is not installed or not in PATH"
        exit 1
    fi
    
    # Check if source directory exists
    if [ ! -d "$SOURCE_DIR" ]; then
        echo_error "Source directory '$SOURCE_DIR' does not exist!"
        exit 1
    fi
    
    show_status
    
    # Use concurrent processing to reduce total processing time
    process_files_concurrently
    
    echo_info "=========================================="
    echo_success "Conversion process complete!"
    
    show_status
    
    echo_info "Final upload-ready files in: '$UPLOAD_DIR/'"
    echo_info "=========================================="
}

# Handle Ctrl+C gracefully
cleanup() {
    echo_info "Cleaning up temporary files..."
    rm -rf /tmp/process_$$_*
    exit 0
}

trap cleanup SIGINT SIGTERM

# Run main function
main "$@"
