#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ENGINE="${CARLA_MACOS_ENGINE_ROOT:-$ROOT/Build/macos-engine/source}"
PROGRAM=ShaderCompileWorker
JOBS=6
while [[ $# -gt 0 ]]; do
  case "$1" in
    --engine-root) ENGINE="$2"; shift 2 ;;
    --program) PROGRAM="$2"; shift 2 ;;
    --jobs) JOBS="$2"; shift 2 ;;
    --help) echo "Usage: bash $0 [--engine-root PATH] [--program ShaderCompileWorker|UnrealPak|UnrealLightmass] [--jobs N]"; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done
[[ "$(uname -s)" == Darwin && "$(uname -m)" == arm64 ]] || { echo 'Native Apple Silicon macOS is required.' >&2; exit 2; }
[[ "$JOBS" =~ ^[1-9][0-9]*$ ]] || { echo '--jobs must be positive.' >&2; exit 2; }
case "$PROGRAM" in
  ShaderCompileWorker|UnrealPak|UnrealLightmass) ;;
  *) echo 'Unsupported engine program for this helper.' >&2; exit 2 ;;
esac
[[ "$(git -C "$ENGINE" rev-parse HEAD)" == e9d9e60c85f643e10eeb03f42f61554d18dcb30f ]] || { echo 'The engine checkout does not match the tested pin.' >&2; exit 2; }
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-12.0}"
bash "$ROOT/Util/BuildTools/MacBuildEngineTools.sh" --engine-root "$ENGINE"
export DOTNET_ROOT="$ROOT/Build/macos-engine/tooling/dotnet"
"$DOTNET_ROOT/dotnet" "$ENGINE/Engine/Binaries/DotNET/UnrealBuildTool.dll" \
  "$PROGRAM" Mac Development -Architecture=arm64 -NoHotReload -NoUBTMakefiles \
  -NoDebugInfo "-MaxParallelActions=$JOBS" "-Log=$ROOT/Build/macos-engine/$PROGRAM-build.log"
xcrun lipo -verify_arch arm64 "$ENGINE/Engine/Binaries/Mac/$PROGRAM"
