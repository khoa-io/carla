#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ENGINE="${CARLA_MACOS_ENGINE_ROOT:-$ROOT/Build/macos-engine/source}"
JOBS=2
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
bash "$ROOT/Util/BuildTools/MacBuildShaderLibraries.sh" --engine-root "$ENGINE" --jobs "$JOBS"
BUILD="$ROOT/Build/macos-engine/native-libraries-build"
THIRD_PARTY="$ENGINE/Engine/Source/ThirdParty"
cmake -S "$ROOT/Util/BuildTools/EnginePatches/native-libraries" -B "$BUILD" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release "-DENGINE_ROOT=$ENGINE" -DCMAKE_OSX_ARCHITECTURES=arm64 \
  "-DCMAKE_OSX_SYSROOT=$(xcrun --show-sdk-path)" \
  "-DCMAKE_OSX_DEPLOYMENT_TARGET=$MACOSX_DEPLOYMENT_TARGET"
cmake --build "$BUILD" --parallel "$JOBS"
stage_library() {
  local source="$1" destination="$2"
  xcrun lipo -verify_arch arm64 "$source"
  mkdir -p "$(dirname "$destination")"
  cp "$source" "$destination"
}
stage_library "$BUILD/libVHACD_LIB.a" "$THIRD_PARTY/VHACD/Lib/Mac/arm64/libVHACD_LIB.a"
stage_library "$BUILD/libnvtristrip.a" "$THIRD_PARTY/nvTriStrip/nvTriStrip-1.0.0/Lib/Mac/arm64/libnvtristrip.a"
stage_library "$BUILD/libForsythTriOptimizer.a" "$THIRD_PARTY/ForsythTriOO/Lib/Mac/arm64/libForsythTriOptimizer.a"
stage_library "$BUILD/libSPIRV-Reflect.a" "$THIRD_PARTY/SPIRV-Reflect/lib/Mac/arm64/libSPIRV-Reflect.a"
stage_library "$BUILD/libKissFFT.a" "$THIRD_PARTY/Kiss_FFT/kiss_fft129/Lib/Mac/arm64/libKissFFT.a"
stage_library "$BUILD/libmtlpp.a" "$THIRD_PARTY/mtlpp/mtlpp-master-7efad47/lib/Mac/arm64/libmtlpp.a"
stage_library "$BUILD/libmcpp.a" "$THIRD_PARTY/MCPP/mcpp-2.7.2/lib/Mac/arm64/libmcpp.a"
xcrun clang++ -std=c++14 -arch arm64 "-mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET" \
  -I "$THIRD_PARTY/MCPP/mcpp-2.7.2/inc" "$ROOT/Util/BuildTools/Tests/MacMcppSmoke.cpp" \
  -L "$THIRD_PARTY/MCPP/mcpp-2.7.2/lib/Mac/arm64" -lmcpp -o "$BUILD/mcpp-smoke"
"$BUILD/mcpp-smoke"
echo 'Native ARM64 engine dependency libraries installed separately from Intel binaries.'
