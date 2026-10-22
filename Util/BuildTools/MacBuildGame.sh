#!/bin/bash
set -euo pipefail

# Builds the standalone native CARLA game (the CarlaUE4 target) for arm64 macOS. The
# editor build in MacBuildEditor.sh is used for the command line tools; this target
# is the game executable that hosts the CARLA server.

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ENGINE="${CARLA_MACOS_ENGINE_ROOT:-$ROOT/Build/macos-engine/source}"
PROJECT="$ROOT/Unreal/CarlaUE4/CarlaUE4.uproject"
JOBS=6
TARGET=CarlaUE4
while [[ $# -gt 0 ]]; do
  case "$1" in
    --engine-root) ENGINE="$2"; shift 2 ;;
    --project) PROJECT="$2"; shift 2 ;;
    --target) TARGET="$2"; shift 2 ;;
    --jobs) JOBS="$2"; shift 2 ;;
    --help) echo "Usage: bash $0 [--engine-root PATH] [--project PATH] [--target NAME] [--jobs N]"; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done
[[ "$(uname -s)" == Darwin && "$(uname -m)" == arm64 ]] || { echo 'Native Apple Silicon macOS is required.' >&2; exit 2; }
[[ "$JOBS" =~ ^[1-9][0-9]*$ ]] || { echo '--jobs must be positive.' >&2; exit 2; }
[[ -f "$PROJECT" ]] || { echo "The CARLA project descriptor is missing at ${PROJECT}." >&2; exit 2; }
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-12.0}"
export DOTNET_ROOT="$ROOT/Build/macos-engine/tooling/dotnet"
export CARLA_MACOS_ENABLE_EXPERIMENTAL_EDITOR=1
"$DOTNET_ROOT/dotnet" "$ENGINE/Engine/Binaries/DotNET/UnrealBuildTool.dll" \
  "$TARGET" Mac Development "-Project=$PROJECT" \
  -Architecture=arm64 -NoHotReload -NoUBTMakefiles -NoDebugInfo "-MaxParallelActions=$JOBS" \
  -DisablePlugin=PerforceSourceControl+PythonScriptPlugin+AlembicHairImporter+HairStrands+RenderDocPlugin+MDL+SimReady+AlembicImporter \
  "-Log=$ROOT/Build/macos-engine/game-build.log"
GAME_BINARY="$ROOT/Unreal/CarlaUE4/Binaries/Mac/$TARGET.app/Contents/MacOS/$TARGET"
[[ -f "$GAME_BINARY" ]] || GAME_BINARY="$ROOT/Unreal/CarlaUE4/Binaries/Mac/$TARGET"
[[ -f "$GAME_BINARY" ]] || { echo "The native game binary was not produced at ${GAME_BINARY}." >&2; exit 2; }
xcrun lipo -verify_arch arm64 "$GAME_BINARY"
echo "Native ARM64 CARLA game target built: ${GAME_BINARY}"
