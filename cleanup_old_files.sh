#!/bin/bash

# Define the directory
DIRECTORY="/home/backup-6-uploaded"

# Check if the directory exists
if [ ! -d "$DIRECTORY" ]; then
  echo "Directory $DIRECTORY does not exist."
  exit 1
fi

# Find and delete files older than 20 days
find "$DIRECTORY" -type f -mtime +20 -exec rm -fv {} \;

# Print a message indicating the cleanup is done
echo " All Files older than 20 days have been deleted from $DIRECTORY."
