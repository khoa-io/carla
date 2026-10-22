#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ENGINE="${CARLA_MACOS_ENGINE_ROOT:-$ROOT/Build/macos-engine/source}"
JOBS=4
while [[ $# -gt 0 ]]; do
  case "$1" in
    --engine-root) ENGINE="$2"; shift 2 ;;
    --jobs) JOBS="$2"; shift 2 ;;
    --help) echo "Usage: bash $0 [--engine-root PATH] [--jobs N]"; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done
[[ "$(uname -s)" == Darwin && "$(uname -m)" == arm64 ]] || { echo 'Native Apple Silicon macOS is required.' >&2; exit 2; }
[[ "$JOBS" =~ ^[1-9][0-9]*$ ]] || { echo '--jobs must be positive.' >&2; exit 2; }
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-12.0}"

# NVIDIA Texture Tools 2.0.8 and the bundled squish compressor are only shipped as
# x86_64 Mac binaries. The upstream CMake project is rebuilt here for arm64 and the
# results are staged separately from the Intel originals.
NVTT_ROOT="$ENGINE/Engine/Source/ThirdParty/nvTextureTools/nvTextureTools-2.0.8/src"
[[ -f "$NVTT_ROOT/src/CMakeLists.txt" ]] || { echo "nvTextureTools source is missing at ${NVTT_ROOT}." >&2; exit 2; }
BUILD="$ROOT/Build/macos-engine/nvtt-build"
cmake -S "$NVTT_ROOT" -B "$BUILD" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release -DNVTT_SHARED=ON -DCMAKE_OSX_ARCHITECTURES=arm64 \
  "-DCMAKE_OSX_SYSROOT=$(xcrun --show-sdk-path)" \
  "-DCMAKE_OSX_DEPLOYMENT_TARGET=$MACOSX_DEPLOYMENT_TARGET"
cmake --build "$BUILD" --parallel "$JOBS"

BINARY_DIR="$ENGINE/Engine/Binaries/ThirdParty/nvTextureTools/Mac/arm64"
SQUISH_DIR="$ENGINE/Engine/Source/ThirdParty/nvTextureTools/nvTextureTools-2.0.8/lib/Mac/arm64"
mkdir -p "$BINARY_DIR" "$SQUISH_DIR"
for library in nvcore nvmath nvimage nvtt; do
  source="$BUILD/src/$library/lib$library.dylib"
  [[ -f "$source" ]] || { echo "Missing build output ${source}." >&2; exit 2; }
  xcrun lipo -verify_arch arm64 "$source"
  cp "$source" "$BINARY_DIR/lib$library.dylib"
done
xcrun lipo -verify_arch arm64 "$BUILD/src/nvtt/squish/libsquish.a"
cp "$BUILD/src/nvtt/squish/libsquish.a" "$SQUISH_DIR/libsquish.a"
echo 'Native ARM64 NVIDIA Texture Tools and squish installed separately from Intel binaries.'
