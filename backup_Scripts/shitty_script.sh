#!/bin/bash

for file in SNLTV_*.mp4; do
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

  mv -v "$file" "$new_name"
done

