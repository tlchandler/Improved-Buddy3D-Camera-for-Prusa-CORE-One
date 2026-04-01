#!/bin/bash
#
# build_snapshot_grabber.sh — Cross-compile snapshot_grabber for RV1103 (ARM)
#
# This binary links dynamically against librockit.so (Rockchip MPI) and
# uclibc on the camera. It REQUIRES the Luckfox Pico uclibc toolchain —
# the generic arm-linux-gnueabihf-gcc produces glibc binaries that will
# fail with "can't resolve symbol '__libc_start_main'" on the camera.
#
# Prerequisites:
#   1. Luckfox uclibc toolchain extracted somewhere on your system
#      (contains arm-rockchip830-linux-uclibcgnueabihf-gcc)
#   2. rkmpi_example headers and uclibc libs (from Luckfox SDK)
#
# Windows note: extracting the toolchain on Windows breaks Linux symlinks
# (they become small text files containing the target path). Run the
# fix-symlinks step below inside Docker before first use.
#
# Usage from Windows (Git Bash):
#
#   # First time only — fix broken symlinks in toolchain:
#   MSYS_NO_PATHCONV=1 docker run --rm \
#     -v "C:/path/to/uclibc_toolchain:/build/toolchain" \
#     gcc:12 bash -c '
#       cd /build/toolchain
#       find . -type f -size -200c \( -name "*.so*" -o -name "*.a" \) | while read f; do
#         content=$(cat "$f" 2>/dev/null)
#         if echo "$content" | grep -qE "^[a-zA-Z0-9_./-]+$" && [ ${#content} -lt 100 ]; then
#           target="$(dirname "$f")/$content"
#           if [ -f "$target" ] && [ "$(wc -c < "$target")" -gt 200 ]; then
#             echo "Fixing: $f -> $content"
#             cp "$target" "$f.tmp" && mv "$f.tmp" "$f"
#           fi
#         fi
#       done
#       # Also fix libgcc_s.so linker script
#       cp arm-rockchip830-linux-uclibcgnueabihf/sysroot/lib/libgcc_s.so \
#          arm-rockchip830-linux-uclibcgnueabihf/lib/libgcc_s.so
#     '
#
#   # Build:
#   MSYS_NO_PATHCONV=1 docker run --rm \
#     -v "C:/path/to/src:/build/src" \
#     -v "C:/path/to/rkmpi_example:/build/rkmpi" \
#     -v "C:/path/to/uclibc_toolchain:/build/toolchain" \
#     -e "PATH=/build/toolchain/bin:/usr/local/bin:/usr/bin:/bin" \
#     -w /build/src \
#     gcc:12 bash build_snapshot_grabber.sh
#
# The resulting binary will appear at: src/snapshot_grabber
# Deploy to SD card:  cp snapshot_grabber /path/to/sdcard/bin/
#

set -e

HEADERS="/build/rkmpi/include"
LIBDIR="/build/rkmpi/lib/uclibc"
SRC="/build/src/snapshot_grabber.c"
OUT="/build/src/snapshot_grabber"
CC="arm-rockchip830-linux-uclibcgnueabihf-gcc"

# ============================================================
# Validate
# ============================================================

if ! command -v "$CC" &>/dev/null; then
    echo "ERROR: $CC not found."
    echo "Mount the Luckfox uclibc toolchain and set PATH, e.g.:"
    echo "  -v \"C:/path/to/uclibc_toolchain:/build/toolchain\""
    echo "  -e \"PATH=/build/toolchain/bin:/usr/local/bin:/usr/bin:/bin\""
    exit 1
fi

if [ ! -f "$SRC" ]; then
    echo "ERROR: Source file not found: $SRC"
    exit 1
fi

if [ ! -d "$HEADERS" ]; then
    echo "ERROR: Headers directory not found: $HEADERS"
    echo "Mount the rkmpi_example directory to /build/rkmpi"
    exit 1
fi

# ============================================================
# Build libjpeg-turbo (static, cross-compiled for ARM uclibc)
# ============================================================

LIBJPEG_VER="3.1.0"
LIBJPEG_DIR="/build/libjpeg-turbo-${LIBJPEG_VER}"
LIBJPEG_BUILD="/build/libjpeg-build"

if [ ! -f "$LIBJPEG_BUILD/libjpeg.a" ]; then
    echo "=== Building libjpeg-turbo ${LIBJPEG_VER} ==="

    # Install cmake if not present
    if ! command -v cmake &>/dev/null; then
        echo "Installing cmake..."
        apt-get update -qq && apt-get install -y -qq cmake >/dev/null 2>&1
    fi

    # Download source
    if [ ! -d "$LIBJPEG_DIR" ]; then
        echo "Downloading libjpeg-turbo ${LIBJPEG_VER}..."
        cd /build
        curl -sL "https://github.com/libjpeg-turbo/libjpeg-turbo/releases/download/${LIBJPEG_VER}/libjpeg-turbo-${LIBJPEG_VER}.tar.gz" \
            -o libjpeg-turbo.tar.gz
        tar xzf libjpeg-turbo.tar.gz
        rm libjpeg-turbo.tar.gz
    fi

    # Cross-compile
    mkdir -p "$LIBJPEG_BUILD"
    cd "$LIBJPEG_BUILD"
    cmake "$LIBJPEG_DIR" \
        -DCMAKE_SYSTEM_NAME=Linux \
        -DCMAKE_SYSTEM_PROCESSOR=armv7 \
        -DCMAKE_C_COMPILER="$CC" \
        -DCMAKE_C_FLAGS="-march=armv7-a -mfpu=neon -mfloat-abi=hard" \
        -DCMAKE_INSTALL_PREFIX=/build/libjpeg-install \
        -DENABLE_SHARED=OFF \
        -DENABLE_STATIC=ON \
        -DWITH_TURBOJPEG=OFF \
        -DWITH_JPEG8=ON \
        -DWITH_SIMD=ON \
        -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
        >/dev/null 2>&1
    make -j$(nproc) >/dev/null 2>&1
    echo "libjpeg-turbo built successfully"
    cd /build/src
else
    echo "=== libjpeg-turbo already built ==="
fi

# ============================================================
# Compile
# ============================================================

echo "=== Compiling snapshot_grabber ==="
echo "  Compiler: $CC"
$CC --version | head -1

$CC \
    -O2 \
    -Wall \
    -I"$HEADERS" \
    -I"$LIBJPEG_BUILD" \
    -I"$LIBJPEG_DIR" \
    -o "$OUT" \
    "$SRC" \
    -L"$LIBDIR" \
    "$LIBJPEG_BUILD/libjpeg.a" \
    -lrockit \
    -lm \
    -Wl,-rpath,/oem/usr/lib:/usr/lib \
    -Wl,--allow-shlib-undefined

# ============================================================
# Verify
# ============================================================

echo ""
echo "=== Build successful ==="
file "$OUT"
ls -la "$OUT"

# Confirm it links against uclibc, not glibc
if readelf -d "$OUT" | grep -q "libc.so.0"; then
    echo "OK: Links against libc.so.0 (uclibc)"
elif readelf -d "$OUT" | grep -q "libc.so.6"; then
    echo "ERROR: Links against libc.so.6 (glibc) — this will NOT work on the camera!"
    echo "Make sure you are using the Luckfox uclibc toolchain, not arm-linux-gnueabihf-gcc."
    exit 1
fi

echo ""
echo "Deploy: cp snapshot_grabber /path/to/sdcard/bin/"
