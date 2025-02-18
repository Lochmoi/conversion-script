#!/bin/bash

echo "Script is running toa files!.."

directory="/home/uploadready"
age_threshold=5

# Current timestamp
current_time=$(date +%s)

# Timestamp for 5 days ago
#five_days_ago=$(date -d "$current_time - 5 days" +%s)
five_days_ago=$(date -d "5 days ago" +%s)

# Get older than 5 days and delete them
#find "$directory" -mtime +"$age_threshold" -delete
find "$directory" -mtime +"$age_threshold" -print
#echo "Deleted files older than $age_threshold days" >> $logfile

find "$directory" -mtime +"$age_threshold" -print

echo  "Deletion don!!"
