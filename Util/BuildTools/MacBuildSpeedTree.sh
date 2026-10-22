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

# The SpeedTree SDK ships Intel-only static archives. Its portable sources are in the
# engine tree, so the core library is rebuilt for arm64 and staged separately.
SDK="$ENGINE/Engine/Source/ThirdParty/SpeedTree/SpeedTreeSDK-v7.0"
[[ -d "$SDK/Source/Core/Source" ]] || { echo "SpeedTree SDK source is missing at ${SDK}." >&2; exit 2; }
BUILD="$ROOT/Build/macos-engine/speedtree-build"
rm -rf "$BUILD"
mkdir -p "$BUILD"
OBJECTS=()
while IFS= read -r source; do
  object="$BUILD/$(basename "$source" .cpp).o"
  xcrun clang++ -std=c++14 -arch arm64 "-mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET" \
    -O2 -DNDEBUG=1 -I "$SDK/Include" -I "$SDK/Source/Core/Source" -c "$source" -o "$object"
  OBJECTS+=("$object")
done < <(find "$SDK/Source/Core/Source" -name '*.cpp' | sort)
[[ "${#OBJECTS[@]}" -gt 0 ]] || { echo 'No SpeedTree sources were compiled.' >&2; exit 2; }
xcrun libtool -static -o "$BUILD/libSpeedTreeCore.a" "${OBJECTS[@]}"
xcrun lipo -verify_arch arm64 "$BUILD/libSpeedTreeCore.a"
DESTINATION="$SDK/Lib/MacOSX/Release-arm64"
mkdir -p "$DESTINATION"
cp "$BUILD/libSpeedTreeCore.a" "$DESTINATION/libSpeedTreeCore.a"
echo 'Native ARM64 SpeedTree core library installed separately from Intel binaries.'
