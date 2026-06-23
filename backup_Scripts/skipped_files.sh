#!/bin/bash

# Source and destination directories
SOURCE_DIR="/home/data/Recordings/Rec_Archive"
DEST_DIR="/home/backup-6"

# Stations_codes to search for
CODES=("RFM" "WRM" "KSI" "EST" "GHE")

# Get the date for midnight today
CURRENTDAY_MIDNIGHT=$(date -d "00:00" +"%Y-%m-%dT%H:%M:%S")

# Check if destination directory exists, if not, create it
if [ ! -d "$DEST_DIR" ]; then
  mkdir -p "$DEST_DIR"
fi

# Loop over the radio station codes and move the corresponding files
for CODE in "${CODES[@]}"; do

  # Find files containing the station codes from CurrentDay
  MOVED_FILES=$(find "$SOURCE_DIR" -type f -name "*$CODE*.mp3" -newermt "$CURRENTDAY_MIDNIGHT")
  
  if [ ! -z "$MOVED_FILES" ]; then

    # If files are found, move them
    find "$SOURCE_DIR" -type f -name "*$CODE*.mp3" -newermt "$CURRENTDAY_MIDNIGHT"  -exec mv -v  {} "$DEST_DIR" \;
    echo "Moved files for  $CODE."
  else

    # If no files are found
    echo "No files to move for $CODE."
  fi
done

echo "File movement process completed."
