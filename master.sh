#!/bin/bash

# Automeate  .asf to mp4. split, and rename
# Use convert_asf.sh, batch_ffsplit.sh, and shitty_script.sh into one workflow

set -e  # Exit on  error

# Configs
SOURCE_DIR="/home/ftp_so/Somalia_Region_recordings"
DONE_DIR="done"
RAW_DIR="raw"
UPLOAD_DIR="upload_ready"  # New directory for files ready for ftp/mv  upload
CHUNK_LEN=600  # 10 minutes

echo_info() { echo "[INFO] $1"; }
echo_success() { echo "[SUCCESS] $1"; }
echo_warning() { echo "[WARNING] $1"; }
echo_error() { echo "[ERROR] $1"; }

# Function to check if a file is a media file
is_media_file() {
    ffmpeg -i "$1" -hide_banner 2>&1 | grep -q "Duration"
}

# Step 1: Convert ASF files to MP4
convert_asf_files() {
    echo_info "Starting ASF to MP4 conversion..."
    
    # Create target directories if they don't exist
    mkdir -p "$DONE_DIR"
    mkdir -p "$RAW_DIR"
    
    local converted_count=0
    
    # Check if source directory exists
    if [ ! -d "$SOURCE_DIR" ]; then
        echo_error "Source directory '$SOURCE_DIR' does not exist!"
        return 1
    fi
    
    # Loop through all .asf files in the source directory
    for filepath in "$SOURCE_DIR"/*.asf; do
        # Check if any .asf files exist
        [ -e "$filepath" ] || {
            echo_warning "No .asf files found in $SOURCE_DIR"
            return 0
        }
        
        filename=$(basename "$filepath")
        basename_no_ext="${filename%.*}"
        output_mp4="$DONE_DIR/$basename_no_ext.mp4"
        
        echo_info "Converting $filename to MP4..."
        
        if ffmpeg -i "$filepath" -c:v libx264 -preset fast -c:a aac -strict experimental "$output_mp4" -y; then
            echo_success "Conversion successful: $filename"
            mv "$filepath" "$RAW_DIR/"
            echo_info "Moved original to $RAW_DIR"
            ((converted_count++))
        else
            echo_error "Failed to convert $filename"
            return 1
        fi
    done
    
    echo_success "Converted $converted_count ASF files to MP4"
    return 0
}

# Step 2: Split MP4 files into 10-minute chunks
split_mp4_files() {
    echo_info "Starting MP4 file splitting into 10-minute chunks..."
    
    cd "$DONE_DIR" || {
        echo_error "Could not change to $DONE_DIR directory"
        return 1
    }
    
    local split_count=0
    
    for IN_FILE in *.mp4; do
        # Skip if no mp4 files exist
        [ -e "$IN_FILE" ] || {
            echo_warning "No MP4 files found in $DONE_DIR"
            cd ..
            return 0
        }
        
        # Skip if not a regular file
        [ -f "$IN_FILE" ] || continue
        
        if ! is_media_file "$IN_FILE"; then
            echo_warning "Skipping non-media file: $IN_FILE"
            continue
        fi
        
        echo_info "Processing: $IN_FILE"
        
        # Extract duration in seconds
        DURATION_HMS=$(ffmpeg -i "$IN_FILE" 2>&1 | grep Duration | cut -f 4 -d ' ' | tr -d ',')
        DURATION_H=$(echo "$DURATION_HMS" | cut -d ':' -f 1 | sed 's/^0*//')
        DURATION_M=$(echo "$DURATION_HMS" | cut -d ':' -f 2 | sed 's/^0*//')
        DURATION_S=$(echo "$DURATION_HMS" | cut -d ':' -f 3 | cut -d '.' -f 1 | sed 's/^0*//')
        
        # Handle empty values (set to 0 if empty)
        DURATION_H=${DURATION_H:-0}
        DURATION_M=${DURATION_M:-0}
        DURATION_S=${DURATION_S:-0}
        
        let "DURATION = (10#$DURATION_H * 60 + 10#$DURATION_M) * 60 + 10#$DURATION_S"
        
        if [ "$DURATION" -le 0 ]; then
            echo_error "Invalid or zero duration for: $IN_FILE"
            continue
        fi
        
        FILE_EXT="${IN_FILE##*.}"
        FILE_NAME="${IN_FILE%.*}"
        OUT_FMT="${FILE_NAME}-%03d.${FILE_EXT}"
        
        N=1
        OFFSET=0
        let "N_FILES = DURATION / CHUNK_LEN + 1"
        
        while [ "$OFFSET" -lt "$DURATION" ]; do
            OUT_FILE=$(printf "$OUT_FMT" "$N")
            echo_info "Creating $OUT_FILE ($N/$N_FILES)..."
            
            if ffmpeg -i "$IN_FILE" -vcodec copy -acodec copy -ss "$OFFSET" -t "$CHUNK_LEN" "$OUT_FILE" -y; then
                let "N = N + 1"
                let "OFFSET = OFFSET + CHUNK_LEN"
            else
                echo_error "Failed to create chunk $OUT_FILE"
                cd ..
                return 1
            fi
        done
        
        # Move original file to a subfolder to keep things organized
        mkdir -p "originals"
        mv "$IN_FILE" "originals/"
        echo_info "Moved original $IN_FILE to originals/ folder"
        ((split_count++))
    done
    
    cd ..
    echo_success "Split $split_count MP4 files into chunks"
    return 0
}

# Step 3: Rename files to  SLN
rename_files() {
    echo_info "Starting file renaming to desired format..."
    
    cd "$DONE_DIR" || {
        echo_error "Could not change to $DONE_DIR directory"
        return 1
    }
    
    mkdir -p "../$UPLOAD_DIR"
    local renamed_count=0
    
    for file in SNLTV_*.mp4; do
        # Skip if no files match pattern
        [ -e "$file" ] || {
            echo_warning "No SNLTV_*.mp4 files found for renaming"
            cd ..
            return 0
        }
        
        base="${file%.*}"  # Remove .mp4 extension
        
        # Extract components using sed
        date=$(echo "$base" | sed -E 's/^SNLTV_([0-9]{4}-[0-9]{2}-[0-9]{2})_.*/\1/')
        hour=$(echo "$base" | sed -E 's/^SNLTV_[0-9]{4}-[0-9]{2}-[0-9]{2}_([0-9]{2})-.*/\1/')
        index=$(echo "$base" | sed -E 's/^.*-([0-9]{3})$/\1/')
        
        # Compute minute from index (001 → 00, 002 → 10, etc.)
        idx_num=$((10 * (${index#0} - 1)))
        minute=$(printf "%02d" "$idx_num")
        
        # Format date and rename
        date_fmt="${date//-/_}"
        new_name="SO_SLN_${date_fmt}_${hour}-${minute}-03.mp4"
        
        echo_info "Renaming: $file -> $new_name"
        
        if mv "$file" "../$UPLOAD_DIR/$new_name"; then
            echo_success "Renamed and moved: $file -> $new_name"
            ((renamed_count++))
        else
            echo_error "Failed to rename $file"
            cd ..
            return 1
        fi
    done
    
    cd ..
    echo_success "Renamed and moved $renamed_count files to $UPLOAD_DIR directory"
    return 0
}

# Main execution
main() {
    echo_info "Starting automated ASF processing pipeline..."
    echo_info "=========================================="
    
    # Check if ffmpeg is available
    if ! command -v ffmpeg &> /dev/null; then
        echo_error "ffmpeg is not installed or not in PATH"
        exit 1
    fi
    
    # Step 1: Convert ASF to MP4
    if ! convert_asf_files; then
        echo_error "ASF conversion failed. Stopping pipeline."
        exit 1
    fi
    
    # Step 2: Split MP4 files
    if ! split_mp4_files; then
        echo_error "MP4 splitting failed. Stopping pipeline."
        exit 1
    fi
    
    # Step 3: Rename files
    if ! rename_files; then
        echo_error "File renaming failed. Stopping pipeline."
        exit 1
    fi
    
    echo_info "=========================================="
    echo_success "Pipeline completed successfully!"
    echo_info "Original .asf: moved to '$RAW_DIR/'"
    echo_info "Original .mp4: moved to '$DONE_DIR/originals/'"
    echo_info "Final files: ready in '$UPLOAD_DIR/' mv reelftp"
}

# Run main function
main "$@"