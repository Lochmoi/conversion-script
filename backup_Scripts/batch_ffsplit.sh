#!/bin/bash

# Batch video splitter - splits all media files in the directory into 10-minute chunks

CHUNK_LEN=600  # 10 minutes in seconds

function is_media_file {
    ffmpeg -i "$1" -hide_banner 2>&1 | grep -q "Duration"
}

for IN_FILE in *; do
    # Skip if not a regular file
    [ -f "$IN_FILE" ] || continue

    if ! is_media_file "$IN_FILE"; then
        echo "Skipping non-media file: $IN_FILE"
        continue
    fi

    echo "Processing: $IN_FILE"

    # Extract duration in seconds
    DURATION_HMS=$(ffmpeg -i "$IN_FILE" 2>&1 | grep Duration | cut -f 4 -d ' ' | tr -d ',')
    DURATION_H=$(echo "$DURATION_HMS" | cut -d ':' -f 1 | sed 's/^0*//')
    DURATION_M=$(echo "$DURATION_HMS" | cut -d ':' -f 2 | sed 's/^0*//')
    DURATION_S=$(echo "$DURATION_HMS" | cut -d ':' -f 3 | cut -d '.' -f 1 | sed 's/^0*//')

    let "DURATION = (10#$DURATION_H * 60 + 10#$DURATION_M) * 60 + 10#$DURATION_S"

    if [ "$DURATION" -le 0 ]; then
        echo "Invalid or zero duration for: $IN_FILE"
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
        echo "Creating $OUT_FILE ($N/$N_FILES)..."
        ffmpeg -i "$IN_FILE" -vcodec copy -acodec copy -ss "$OFFSET" -t "$CHUNK_LEN" "$OUT_FILE"
        let "N = N + 1"
        let "OFFSET = OFFSET + CHUNK_LEN"
    done
done

