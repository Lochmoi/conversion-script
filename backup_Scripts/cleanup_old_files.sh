#!/bin/bash

# Define the directory
DIRECTORY="/home/data/Recordings/Rec_Archive"

# Check if the directory exists
if [ ! -d "$DIRECTORY" ]; then
  echo "Directory $DIRECTORY does not exist."
  exit 1
fi

# Find and delete files older than 4 days
find "$DIRECTORY" -type f -mtime +4 -exec rm -fv {} \;


# Print a message indicating the cleanup is done
echo " All Files older than 4 days have been deleted from $DIRECTORY."
