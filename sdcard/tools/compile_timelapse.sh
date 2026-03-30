#!/bin/bash
# compile_timelapse.sh — Compile timelapse frames into MP4
#
# Run on your PC (requires ffmpeg installed).
# Usage: ./compile_timelapse.sh /path/to/sdcard/timelapse/20260330_143022
#        ./compile_timelapse.sh /path/to/sdcard/timelapse/20260330_143022 24

set -e

DIR="$1"
FPS="${2:-30}"

if [ -z "$DIR" ] || [ ! -d "$DIR" ]; then
    echo "Usage: $0 <timelapse_session_directory> [fps]"
    echo ""
    echo "Example: $0 /media/sdcard/timelapse/20260330_143022"
    echo "         $0 /media/sdcard/timelapse/20260330_143022 24"
    echo ""
    echo "Available sessions:"
    PARENT=$(dirname "$DIR" 2>/dev/null || echo ".")
    ls -d "$PARENT"/[0-9]* 2>/dev/null | while read d; do
        COUNT=$(ls "$d"/frame_*.jpg 2>/dev/null | wc -l)
        echo "  $d ($COUNT frames)"
    done
    exit 1
fi

FRAME_COUNT=$(ls "$DIR"/frame_*.jpg 2>/dev/null | wc -l)
if [ "$FRAME_COUNT" -eq 0 ]; then
    echo "Error: No frame_*.jpg files found in $DIR"
    exit 1
fi

OUTPUT="$DIR/timelapse.mp4"

echo "Compiling $FRAME_COUNT frames at ${FPS}fps -> $OUTPUT"

ffmpeg -framerate "$FPS" \
    -i "$DIR/frame_%05d.jpg" \
    -c:v libx264 \
    -pix_fmt yuv420p \
    -movflags +faststart \
    -y \
    "$OUTPUT"

echo ""
echo "Done! Timelapse saved to: $OUTPUT"
echo "Duration: $(echo "scale=1; $FRAME_COUNT / $FPS" | bc) seconds"
