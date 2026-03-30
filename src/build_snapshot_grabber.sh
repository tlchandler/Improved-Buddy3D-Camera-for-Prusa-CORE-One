#!/bin/bash
#
# build_snapshot_grabber.sh — Cross-compile snapshot_grabber for RV1103 (ARM)
#
# This script runs inside a Docker container to cross-compile
# snapshot_grabber.c into a dynamically-linked ARM binary that
# links against librockit.so at runtime on the camera.
#
# The rkmpi headers and library are expected at /build/rkmpi/
# (mounted from the host's rkmpi_example directory).
#
# The RV1103 camera uses uclibc, so we need to set the dynamic
# linker to /lib/ld-uClibc.so.0 instead of the glibc default.
#
# Usage from Windows (Git Bash):
#
#   MSYS_NO_PATHCONV=1 docker run --rm \
#     -v "C:/path/to/sdcard/src:/build/src" \
#     -v "/tmp/rkmpi_example:/build/rkmpi" \
#     -w /build/src \
#     gcc:12 bash build_snapshot_grabber.sh
#
# Or if you have the Luckfox SDK toolchain installed, run
# build_snapshot_grabber.sh directly (it detects the toolchain).
#
# The resulting binary will appear at: sdcard/src/snapshot_grabber
#
# On the camera, place it at: /mnt/sdcard/bin/snapshot_grabber
# It requires /oem/usr/lib/librockit.so at runtime.
#

set -e

HEADERS="/build/rkmpi/include"
LIBDIR="/build/rkmpi/lib/uclibc"
SRC="/build/src/snapshot_grabber.c"
OUT="/build/src/snapshot_grabber"

# ============================================================
# Detect or install cross-compiler
# ============================================================

# Check for Luckfox SDK uclibc toolchain first (preferred)
LUCKFOX_GCC="arm-rockchip830-linux-uclibcgnueabihf-gcc"
GNUEABIHF_GCC="arm-linux-gnueabihf-gcc"
CC=""

if command -v "$LUCKFOX_GCC" &>/dev/null; then
    CC="$LUCKFOX_GCC"
    echo "=== Using Luckfox SDK toolchain: $CC ==="
elif command -v "$GNUEABIHF_GCC" &>/dev/null; then
    CC="$GNUEABIHF_GCC"
    echo "=== Using system cross-compiler: $CC ==="
else
    echo "=== Installing ARM cross-compiler ==="
    apt-get update -qq
    apt-get install -y -qq gcc-arm-linux-gnueabihf > /dev/null 2>&1
    CC="$GNUEABIHF_GCC"
fi

# ============================================================
# Validate inputs
# ============================================================

if [ ! -f "$SRC" ]; then
    echo "ERROR: Source file not found: $SRC"
    exit 1
fi

if [ ! -d "$HEADERS" ]; then
    echo "ERROR: Headers directory not found: $HEADERS"
    echo "Mount the rkmpi_example directory to /build/rkmpi"
    exit 1
fi

echo "=== Compiling snapshot_grabber ==="
echo "  Compiler: $CC"
echo "  Source:   $SRC"
echo "  Headers:  $HEADERS"
echo "  Libs:     $LIBDIR"

# ============================================================
# Compile
# ============================================================
# The camera runs uclibc with dynamic linker /lib/ld-uClibc.so.0.
# When using the glibc cross-compiler (arm-linux-gnueabihf-gcc),
# we override the dynamic linker path so the binary runs on the
# uclibc-based camera firmware.
#
# The Luckfox SDK compiler already targets uclibc, so no override
# is needed in that case.

EXTRA_LDFLAGS=""
if [ "$CC" = "$GNUEABIHF_GCC" ]; then
    echo "  NOTE: Overriding dynamic linker for uclibc target"
    EXTRA_LDFLAGS="-Wl,--dynamic-linker=/lib/ld-uClibc.so.0"
fi

$CC \
    -O2 \
    -Wall \
    -I"$HEADERS" \
    -o "$OUT" \
    "$SRC" \
    -L"$LIBDIR" \
    -lrockit \
    -Wl,-rpath,/oem/usr/lib:/usr/lib \
    -Wl,--allow-shlib-undefined \
    $EXTRA_LDFLAGS

# ============================================================
# Verify the output
# ============================================================

if [ -f "$OUT" ]; then
    echo ""
    echo "=== Build successful ==="
    file "$OUT"
    SIZE_CMD="${CC/gcc/size}"
    if command -v "$SIZE_CMD" &>/dev/null; then
        $SIZE_CMD "$OUT"
    fi
    echo ""
    echo "Deploy to camera SD card:"
    echo "  cp snapshot_grabber /path/to/sdcard/bin/"
    echo ""
    echo "On camera, run:"
    echo "  /mnt/sdcard/bin/snapshot_grabber [output.jpg] [width] [height] [quality]"
    echo ""
    echo "IMPORTANT: The binary requires /oem/usr/lib/librockit.so at runtime."
    echo "If using glibc compiler, also needs uclibc libs on camera (/lib/ld-uClibc.so.0)."
    echo "The camera's stock firmware already has these."
else
    echo "=== Build FAILED ==="
    exit 1
fi
