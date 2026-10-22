#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ENGINE="$ROOT/Build/macos-engine/source"
CONFIGURATION=profile
VERIFY_ONLY=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --engine) ENGINE="$2"; shift 2 ;;
    --configuration) CONFIGURATION="$2"; shift 2 ;;
    --verify-only) VERIFY_ONLY=true; shift ;;
    --help) echo "Usage: bash $0 [--engine PATH] [--configuration profile|release|checked|debug] [--verify-only]"; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done
if [[ "$(uname -s)" != Darwin || "$(uname -m)" != arm64 ]]; then
  echo "PhysX validation requires native Apple Silicon macOS." >&2
  exit 2
fi
case "$CONFIGURATION" in
  profile) SUFFIX=PROFILE ;;
  release) SUFFIX= ;;
  checked) SUFFIX=CHECKED ;;
  debug) SUFFIX=DEBUG ;;
  *) echo "Unsupported PhysX configuration: $CONFIGURATION" >&2; exit 2 ;;
esac
PHYSX="$ENGINE/Engine/Source/ThirdParty/PhysX3"
LIBRARY_DIR="$PHYSX/Lib/Mac"
BINARY_DIR="$ENGINE/Engine/Binaries/ThirdParty/PhysX3/Mac"
STATIC_LIBRARIES=(LowLevel LowLevelCloth PhysX3Extensions SceneQuery SimulationController PxTask PsFastXml PhysX3Vehicle)
DYNAMIC_LIBRARIES=(PhysX3 PhysX3Cooking PhysX3Common PxFoundation PxPvdSDK)
for library in "${STATIC_LIBRARIES[@]}"; do
  xcrun lipo -verify_arch arm64 "$LIBRARY_DIR/lib${library}${SUFFIX}.a"
done
for library in "${DYNAMIC_LIBRARIES[@]}"; do
  xcrun lipo -verify_arch arm64 "$BINARY_DIR/lib${library}${SUFFIX}.dylib"
done
echo "PhysX $CONFIGURATION libraries contain ARM64 slices."
if "$VERIFY_ONLY"; then exit 0; fi
BUILD_DIR="$ROOT/Build/macos-engine/physx-$CONFIGURATION"
mkdir -p "$BUILD_DIR"
COMPILE_DEFINITIONS=(-DNDEBUG)
if [[ "$CONFIGURATION" == debug ]]; then COMPILE_DEFINITIONS=(-D_DEBUG); fi
xcrun clang++ -std=c++14 -stdlib=libc++ -arch arm64 \
  -mmacosx-version-min="${MACOSX_DEPLOYMENT_TARGET:-12.0}" "${COMPILE_DEFINITIONS[@]}" \
  -I"$PHYSX/PhysX_3.4/Include" -I"$PHYSX/PxShared/include" \
  "$ROOT/Util/BuildTools/Tests/MacPhysXSmoke.cpp" \
  "$LIBRARY_DIR/libPhysX3Extensions${SUFFIX}.a" \
  "$LIBRARY_DIR/libPhysX3Vehicle${SUFFIX}.a" \
  -L"$BINARY_DIR" -l"PhysX3${SUFFIX}" -l"PhysX3Common${SUFFIX}" \
  -l"PxFoundation${SUFFIX}" -l"PxPvdSDK${SUFFIX}" \
  -Wl,-rpath,"$BINARY_DIR" -o "$BUILD_DIR/physx-smoke"
xcrun lipo -verify_arch arm64 "$BUILD_DIR/physx-smoke"
"$BUILD_DIR/physx-smoke"
