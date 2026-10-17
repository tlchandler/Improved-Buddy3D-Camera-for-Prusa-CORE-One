#!/bin/bash
#
# build_print_timelapse.sh — Cross-compile print_timelapse for ARM
#
# Static binary, no external dependencies. Runs on any ARMv7 Linux.
#
# Usage from Windows (Git Bash):
#
#   MSYS_NO_PATHCONV=1 docker run --rm \
#     -v "C:/path/to/sdcard/src:/src" \
#     -w /src gcc:12 \
#     bash build_print_timelapse.sh [output-path]
#
set -e

OUTPUT_PATH=${1:-print_timelapse}

apt-get update -qq
apt-get install -y -qq gcc-arm-linux-gnueabihf > /dev/null 2>&1

arm-linux-gnueabihf-gcc -static -O2 -o "$OUTPUT_PATH" print_timelapse.c -lm

echo "Build complete: $OUTPUT_PATH ($(wc -c < "$OUTPUT_PATH") bytes)"
