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
SOURCE="$ENGINE/Engine/Source/ThirdParty/hlslcc/hlslcc"
BUILD="$ROOT/Build/macos-engine/hlslcc-build"
cmake -S "$SOURCE/projects" -B "$BUILD" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES=arm64 \
  "-DCMAKE_OSX_DEPLOYMENT_TARGET=${MACOSX_DEPLOYMENT_TARGET:-12.0}" \
  -DCMAKE_CXX_FLAGS='-fno-exceptions -frtti'
cmake --build "$BUILD" --parallel "$JOBS"
xcrun lipo -verify_arch arm64 "$BUILD/libhlslcc.a"
mkdir -p "$SOURCE/lib/Mac/arm64"
cp "$BUILD/libhlslcc.a" "$SOURCE/lib/Mac/arm64/libhlslcc.a"
echo 'Native ARM64 HLSL cross-compiler library installed.'

GLSLANG="$ENGINE/Engine/Source/ThirdParty/glslang/glslang"
GLSLANG_BUILD="$ROOT/Build/macos-engine/glslang-build"
cmake -S "$GLSLANG/src/glslang_lib" -B "$GLSLANG_BUILD" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES=arm64 \
  "-DCMAKE_OSX_SYSROOT=$(xcrun --show-sdk-path)" \
  "-DCMAKE_OSX_DEPLOYMENT_TARGET=${MACOSX_DEPLOYMENT_TARGET:-12.0}" \
  -DENABLE_GLSLANG_BINARIES=OFF -DENABLE_OPT=OFF -DBUILD_TESTING=OFF -DSKIP_GLSLANG_INSTALL=ON
cmake --build "$GLSLANG_BUILD" --target glslang HLSL OGLCompiler OSDependent SPIRV --parallel "$JOBS"
mkdir -p "$GLSLANG/lib/Mac/arm64"
for library in glslang/libglslang.a hlsl/libHLSL.a OGLCompilersDLL/libOGLCompiler.a \
    glslang/OSDependent/Unix/libOSDependent.a SPIRV/libSPIRV.a; do
  xcrun lipo -verify_arch arm64 "$GLSLANG_BUILD/$library"
  cp "$GLSLANG_BUILD/$library" "$GLSLANG/lib/Mac/arm64/$(basename "$library")"
done
echo 'Native ARM64 GLSL/SPIR-V compiler libraries installed.'
