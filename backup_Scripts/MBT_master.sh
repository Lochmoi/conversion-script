#!/bin/bash

# Automate .mkv to mp4 conversion, split, and rename
# Process MW_MBT MW_ZDK files concurrently 

#Lock file to avoid multiple instances
LOCKFILE="/var/run/master.lock"

# Check if lockfile exists and if the process is running
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
SOURCE_DIR="/home/malawi/renamed"
UPLOAD_DIR="/home/micah/upload_ready"
MOTHER_DIR="/home/malawi/mother"
CHUNK_LEN=600  # 10 minutes
MAX_PARALLEL_JOBS=2  # Process MW_MBT MW_ZDK files simultaneously

# File cleanup 
MOVE_MKV_AFTER_CONVERSION=true
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
mkdir -p "$MOTHER_DIR"

# Process  .mkv file completely (convert -> split -> rename -> upload)
process_single_file() {
    local mkv_filepath="$1"
    local filename=$(basename "$mkv_filepath")
    local basename_no_ext="${filename%.*}"
    
    echo_info "=========================================="
    echo_info "Processing: $filename"
    echo_info "=========================================="
    
    # Create temporary working directory for this file
    local work_dir="/tmp/process_$$_$(date +%s)"
    mkdir -p "$work_dir"
    
    # Step 1: Convert MKV to MP4
    local mp4_file="$work_dir/$basename_no_ext.mp4"
    echo_info "[STEP 1] Converting MKV to MP4..."
    
    if ffmpeg -i "$mkv_filepath" -c:v libx264 -preset ultrafast -crf 28 -vf "scale=-2:480"  -c:a aac -b:a 98k -max_muxing_queue_size 9999 -avoid_negative_ts make_zero -fflags +genpts "$mp4_file" -y; then
        echo_success "[STEP 1] Conversion completed: $filename"
        
        # Move/backup .mkv file after successful conversion
        if [ "$MOVE_MKV_AFTER_CONVERSION" = true ]; then
            if mv "$mkv_filepath" "$MOTHER_DIR/"; then
                echo_info "[STEP 1] Moved original MKV to mother directory: $filename"
            else
                echo_warning "[STEP 1] Failed to move MKV to mother directory: $filename"
            fi
           
         fi
    else
        echo_error "[STEP 1] Failed to convert: $filename"
        rm -rf "$work_dir"
        return 1
    fi
    
    # Step 2: Split MP4 into  10min  chunks
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
    
    # Extract duration in seconds 
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
    
    FILE_EXT="mp4"  # Output as MP4
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
            
            # Extract components from MW_MBT format: MW_MBT_YYYY_MM_DD_HH-MM-SS-XXX
            # Parse the filename format: MW_MBT_2025_09_24_18-00-00-001
            if [[ "$base" =~ ^MW_MBT_([0-9]{4})_([0-9]{2})_([0-9]{2})_([0-9]{2})-([0-9]{2})-([0-9]{2})-([0-9]{3})$ ]]; then
                year="${BASH_REMATCH[1]}"
                month="${BASH_REMATCH[2]}"
                day="${BASH_REMATCH[3]}"
                hour="${BASH_REMATCH[4]}"
                orig_minute="${BASH_REMATCH[5]}"
                orig_second="${BASH_REMATCH[6]}"
                index="${BASH_REMATCH[7]}"
                
                # Compute minute from index (each chunk is 10 minutes)
                # Add the chunk time to the original time
                let "orig_minute_num = 10#$orig_minute"
                let "chunk_minutes = (${index#0} - 1) * 10"
                let "total_minutes = orig_minute_num + chunk_minutes"
                let "final_hour = 10#$hour + total_minutes / 60"
                let "final_minute = total_minutes % 60"
                
                final_hour_str=$(printf "%02d" "$final_hour")
                final_minute_str=$(printf "%02d" "$final_minute")
                
                # Create new filename: MW_MBT_YYYY_MM_DD_HH-MM-SS.mp4
                new_name="MW_MBT_${year}_${month}_${day}_${final_hour_str}-${final_minute_str}-00.mp4"
            elif [[ "$base" =~ ^MW_ZDK_([0-9]{4})_([0-9]{2})_([0-9]{2})_([0-9]{2})-([0-9]{2})-([0-9]{2})-([0-9]{3})$ ]]; then
                year="${BASH_REMATCH[1]}"
                month="${BASH_REMATCH[2]}"
                day="${BASH_REMATCH[3]}"
                hour="${BASH_REMATCH[4]}"
                orig_minute="${BASH_REMATCH[5]}"
                orig_second="${BASH_REMATCH[6]}"
                index="${BASH_REMATCH[7]}"
                
                # Compute minute from index (each chunk is 10 minutes)
                let "orig_minute_num = 10#$orig_minute"
                let "chunk_minutes = (${index#0} - 1) * 10"
                let "total_minutes = orig_minute_num + chunk_minutes"
                let "final_hour = 10#$hour + total_minutes / 60"
                let "final_minute = total_minutes % 60"
                
                final_hour_str=$(printf "%02d" "$final_hour")
                final_minute_str=$(printf "%02d" "$final_minute")
                
                # Create new filename: MW_ZDK_YYYY_MM_DD_HH-MM-SS.mp4
                new_name="MW_ZDK_${year}_${month}_${day}_${final_hour_str}-${final_minute_str}-00.mp4"


                
            else
                echo_warning "[STEP 3] Unknown file format for: $OUT_FILE, using fallback naming"
                # Fallback naming
                new_name="MW_MBT_chunk_$(printf "%03d" "$N").mp4"
            fi
            
            # Move 10min chunk to upload directory
            if mv "$OUT_FILE" "$UPLOAD_DIR/$new_name"; then
                echo_success "[STEP 3] 10min chunk ready for upload: $new_name"
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
    local mbt_count=$(find "$SOURCE_DIR" -name "MW_MBT_*.mkv" -type f 2>/dev/null | wc -l)
    local zdk_count=$(find "$SOURCE_DIR" -name "MW_ZDK_*.mkv" -type f 2>/dev/null | wc -l)
    local total_mkv=$((mbt_count + zdk_count))
    local upload_count=$(find "$UPLOAD_DIR" -name "*.mp4" -type f 2>/dev/null | wc -l)
    local upload_size=""
    
    if [ -d "$UPLOAD_DIR" ] && [ $upload_count -gt 0 ]; then
        upload_size=$(du -sh "$UPLOAD_DIR" 2>/dev/null | cut -f1)
    fi
    
    echo_info "STATUS: MKV files remaining: $total_mkv (MW_MBT: $mbt_count, MW_ZDK: $zdk_count) | Upload ready: $upload_count files ($upload_size)"
}

# Process MW_MBT files concurrently
process_files_concurrently() {
    local mbt_files=()
    local zdk_files=()

    # Collect MW_MBT.mkv files
    for file in "$SOURCE_DIR"/MW_MBT_*.mkv; do 
        [ -e "$file" ] && mbt_files+=("$file")
    done
#    for file in "$SOURCE_DIR"/MW_ZDK_*.mkv; do
 #       [ -e "$file" ] && zdk_files+=("$file")
  #  done
    local mbt_count=${#mbt_files[@]}
    local zdk_count=${#zdk_files[@]}
    
    echo_info "Found $mbt_count MW_MBT files and $zdk_count MW_ZDK files"
    
    if [ $mbt_count -eq 0 ] && [ $zdk_count -eq 0 ]; then
        echo_info "No MKV files found to process"
        return 0
    fi
    
    local mbt_index=0
    local zdk_index=0

    local processed_count=0
    
    # Process files concurrently
    while [ $mbt_index -lt $mbt_count ] || [ $zdk_index -lt $zdk_count ]; do
        
        # Start processing if available and not already processing max jobs
        if [ $mbt_index -lt $mbt_count ] && [ $(jobs -r | wc -l) -lt $MAX_PARALLEL_JOBS ]; then
            local mbt_file="${mbt_files[$mbt_index]}"
            echo_info "Starting MW_MBT processing: $(basename "$mbt_file")"
            (
                if process_single_file "$mbt_file"; then
                    echo_info "CONCURRENT: MW_MBT completed - $(basename "$mbt_file")"
                else
                    echo_error "CONCURRENT: MW_MBT failed - $(basename "$mbt_file")"
                fi
            ) &
            ((mbt_index++))
            ((processed_count++))
            sleep 1
        fi
        if [ $zdk_index -lt $zdk_count ] && [ $(jobs -r | wc -l) -lt $MAX_PARALLEL_JOBS ]; then
            local zdk_file="${zdk_files[$zdk_index]}"
            echo_info "Starting MW_ZDK processing: $(basename "$zdk_file")"
            (
                if process_single_file "$zdk_file"; then
                    echo_info "CONCURRENT: MW_ZDK completed - $(basename "$zdk_file")"
                else
                    echo_error "CONCURRENT: MW_ZDK failed - $(basename "$zdk_file")"
                fi
            ) &
            ((zdk_index++))
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
    echo_info "MW_MBT files processed: $mbt_count"
    echo_info "MW_ZDK files processed: $zdk_count"
}

# Main execution
main() {
    echo_info "Starting concurrent MKV processing pipeline..."
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
    echo_success "Processing completed!"
    
    show_status
    
    echo_info "Final upload-ready files are in: '$UPLOAD_DIR/'"
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
