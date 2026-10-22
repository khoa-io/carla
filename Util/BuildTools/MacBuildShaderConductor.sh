#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ENGINE="${CARLA_MACOS_ENGINE_ROOT:-$ROOT/Build/macos-engine/source}"
PYTHON="$ROOT/Build/macos/venv/bin/python"
JOBS=2
while [[ $# -gt 0 ]]; do
  case "$1" in
    --engine-root) ENGINE="$2"; shift 2 ;;
    --python) PYTHON="$2"; shift 2 ;;
    --jobs) JOBS="$2"; shift 2 ;;
    --help) echo "Usage: bash $0 [--engine-root PATH] [--python PATH] [--jobs N]"; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done
[[ "$(uname -s)" == Darwin && "$(uname -m)" == arm64 ]] || { echo 'Native Apple Silicon macOS is required.' >&2; exit 2; }
[[ "$JOBS" =~ ^[1-9][0-9]*$ ]] || { echo '--jobs must be positive.' >&2; exit 2; }
[[ -x "$PYTHON" ]] || { echo 'Provide native Python with --python.' >&2; exit 2; }
[[ "$("$PYTHON" -c 'import platform; print(platform.machine())')" == arm64 ]] || { echo 'Python must run natively as ARM64.' >&2; exit 2; }
SOURCE="$ENGINE/Engine/Source/ThirdParty/ShaderConductor/ShaderConductor"
BUILD="$ROOT/Build/macos-engine/shader-conductor-build"
cmake -S "$SOURCE" -B "$BUILD" -G Ninja -DCMAKE_BUILD_TYPE=Release \
  -DSC_ARCH_NAME=arm64 -DCMAKE_OSX_ARCHITECTURES=arm64 \
  "-DCMAKE_OSX_DEPLOYMENT_TARGET=${MACOSX_DEPLOYMENT_TARGET:-12.0}" \
  "-DCMAKE_OSX_SYSROOT=$(xcrun --show-sdk-path)" \
  "-DPYTHON_EXECUTABLE=$PYTHON" "-DPython3_EXECUTABLE=$PYTHON" \
  -DSPIRV_WERROR=OFF -DLLVM_HOST_TRIPLE=arm64-apple-darwin -DLLVM_TARGET_ARCH=AArch64
cmake --build "$BUILD" --target ShaderConductor dxcompiler --parallel "$JOBS"
STAGE="$ENGINE/Engine/Binaries/ThirdParty/ShaderConductor/Mac/arm64"
mkdir -p "$STAGE"
for library in libdxcompiler.dylib libShaderConductor.dylib; do
  xcrun lipo -verify_arch arm64 "$BUILD/Lib/$library"
  cp "$BUILD/Lib/$library" "$STAGE/$library"
  install_name_tool -id "@rpath/$library" "$STAGE/$library"
  if otool -l "$STAGE/$library" | grep 'path RPATH_DUMMY ' >/dev/null; then
    install_name_tool -rpath RPATH_DUMMY @loader_path "$STAGE/$library"
  fi
  codesign --force --sign - "$STAGE/$library"
done
xcrun clang++ -std=c++17 -arch arm64 "-mmacosx-version-min=${MACOSX_DEPLOYMENT_TARGET:-12.0}" \
  -I "$SOURCE/Include" "$ROOT/Util/BuildTools/Tests/MacShaderConductorSmoke.cpp" \
  -L "$STAGE" -lShaderConductor "-Wl,-rpath,$STAGE" -o "$BUILD/shader-conductor-smoke"
"$BUILD/shader-conductor-smoke" "$BUILD/shader-smoke.metal"
MODULE_CACHE="${CLANG_MODULE_CACHE_PATH:-$ROOT/Build/macos-engine/cache/clang-module}"
mkdir -p "$MODULE_CACHE"
xcrun -sdk macosx metal -std=macos-metal2.3 "-mmacosx-version-min=${MACOSX_DEPLOYMENT_TARGET:-12.0}" \
  -fmodules-cache-path="$MODULE_CACHE" \
  -c "$BUILD/shader-smoke.metal" -o "$BUILD/shader-smoke.air"
xcrun -sdk macosx metallib "$BUILD/shader-smoke.air" -o "$BUILD/shader-smoke.metallib"
echo 'Native ARM64 ShaderConductor and DXC installed.'
