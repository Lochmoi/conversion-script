#!/bin/bash

# Define the source directory and the target directory
SOURCE_DIR="/home/lochmoi/bash/test"
TARGET_DIR="$SOURCE_DIR/converted"

# Create the target directory if it doesn't exist
mkdir -p "$TARGET_DIR"

# Loop through all MP4 files in the source directory
for mp4file in "$SOURCE_DIR"/*.mp4; do
    # Check if there are any MP4 files in the directory
    if [ -e "$mp4file" ]; then
        # Extract the base filename without extension
        filename=$(basename "$mp4file" .mp4)
        
        # Define the output MP3 file path
        mp3file="$TARGET_DIR/$filename.mp3"
        
        # Convert MP4 to MP3 using ffmpeg
        ffmpeg -i "$mp4file" -vn -acodec libmp3lame -ab 192k -ar 44100 "$mp3file"
        
        echo "Converted: $mp4file -> $mp3file"
    fi
done

echo "Conversions complete!!"
