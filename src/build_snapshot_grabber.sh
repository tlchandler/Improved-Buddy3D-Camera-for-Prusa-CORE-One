#!/bin/bash
#
# build_snapshot_grabber.sh — Cross-compile snapshot_grabber for RV1103 (ARM)
#
# This binary links dynamically against librockit.so (Rockchip MPI),
# libjpeg-turbo (libjpeg.so.8), and uclibc on the camera. It REQUIRES
# the Luckfox Pico uclibc toolchain — the generic arm-linux-gnueabihf-gcc
# produces glibc binaries that will fail on the camera.
#
# libjpeg-turbo is built as a shared library (.so) because the camera's
# uclibc dynamic linker cannot load binaries with statically linked
# libjpeg (causes segfault due to .ARM.exidx program header incompatibility).
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
# Output:
#   src/snapshot_grabber    — the binary
#   src/libjpeg.so.8        — shared library (must also be deployed)
#
# Deploy to SD card:
#   cp snapshot_grabber /path/to/sdcard/bin/
#   cp libjpeg.so.8 /path/to/sdcard/bin/
#

set -e

HEADERS="/build/rkmpi/include"
LIBDIR="/build/rkmpi/lib/uclibc"
SRC="/build/src/snapshot_grabber.c"
OUT="/build/src/snapshot_grabber"
CC="arm-rockchip830-linux-uclibcgnueabihf-gcc"
STRIP="arm-rockchip830-linux-uclibcgnueabihf-strip"

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
# Build libjpeg-turbo (shared library, cross-compiled for ARM uclibc)
# ============================================================

LIBJPEG_VER="2.1.5.1"
LIBJPEG_DIR="/build/libjpeg-turbo-${LIBJPEG_VER}"
LIBJPEG_BUILD="/build/libjpeg-build"
SYSROOT=$($CC -print-sysroot)

if [ ! -f "$LIBJPEG_BUILD/libjpeg.so.8" ]; then
    echo "=== Building libjpeg-turbo ${LIBJPEG_VER} (shared) ==="

    # Install cmake if not present
    if ! command -v cmake &>/dev/null; then
        echo "Installing cmake..."
        apt-get update -qq && apt-get install -y -qq cmake >/dev/null 2>&1
    fi

    # Download source
    if [ ! -d "$LIBJPEG_DIR" ]; then
        echo "Downloading libjpeg-turbo ${LIBJPEG_VER}..."
        cd /build
        curl -fsL "https://github.com/libjpeg-turbo/libjpeg-turbo/releases/download/${LIBJPEG_VER}/libjpeg-turbo-${LIBJPEG_VER}.tar.gz" \
            -o libjpeg-turbo.tar.gz
        tar xzf libjpeg-turbo.tar.gz
        rm libjpeg-turbo.tar.gz
    fi

    # Cross-compile as shared library
    mkdir -p "$LIBJPEG_BUILD"
    cd "$LIBJPEG_BUILD"
    cmake "$LIBJPEG_DIR" \
        -DCMAKE_SYSTEM_NAME=Linux \
        -DCMAKE_SYSTEM_PROCESSOR=armv7 \
        -DCMAKE_C_COMPILER="$CC" \
        -DCMAKE_C_FLAGS="-march=armv7-a -mfpu=neon -mfloat-abi=hard" \
        -DCMAKE_SYSROOT="$SYSROOT" \
        -DENABLE_SHARED=ON \
        -DENABLE_STATIC=OFF \
        -DWITH_TURBOJPEG=OFF \
        -DWITH_JPEG8=ON \
        -DWITH_SIMD=OFF \
        >/dev/null
    make -j$(nproc) >/dev/null
    # Strip debug symbols to reduce .so size
    $STRIP "$LIBJPEG_BUILD"/libjpeg.so.8.* 2>/dev/null || true
    echo "libjpeg-turbo built successfully"
    cd /build/src
else
    echo "=== libjpeg-turbo already built ==="
fi

# Copy .so to output directory (resolve symlinks to get the actual file)
LIBJPEG_SO=$(readlink -f "$LIBJPEG_BUILD/libjpeg.so.8")
cp "$LIBJPEG_SO" /build/src/libjpeg.so.8

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
    -L"$LIBJPEG_BUILD" \
    -ljpeg \
    -lrockit \
    -Wl,-rpath,/oem/usr/lib:/usr/lib:/tmp \
    -Wl,--allow-shlib-undefined

# ============================================================
# Verify
# ============================================================

echo ""
echo "=== Build successful ==="
file "$OUT"
ls -la "$OUT"
ls -la /build/src/libjpeg.so.8

# Confirm it links against uclibc, not glibc
if readelf -d "$OUT" | grep -q "libc.so.0"; then
    echo "OK: Links against libc.so.0 (uclibc)"
elif readelf -d "$OUT" | grep -q "libc.so.6"; then
    echo "ERROR: Links against libc.so.6 (glibc) — this will NOT work on the camera!"
    echo "Make sure you are using the Luckfox uclibc toolchain, not arm-linux-gnueabihf-gcc."
    exit 1
fi

echo ""
echo "Deploy both files to SD card:"
echo "  cp snapshot_grabber /path/to/sdcard/bin/"
echo "  cp libjpeg.so.8 /path/to/sdcard/bin/"
