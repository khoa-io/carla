#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ENGINE="${CARLA_MACOS_ENGINE_ROOT:-$ROOT/Build/macos-engine/source}"
PROJECT="$ROOT/Unreal/CarlaUE4/CarlaUE4.uproject"
MAP="/Game/Carla/Maps/Town02_Opt"
OUTPUT="$ROOT/Build/macos-game/cooked"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --engine-root) ENGINE="$2"; shift 2 ;;
    --map) MAP="$2"; shift 2 ;;
    --output) OUTPUT="$2"; shift 2 ;;
    --help) echo "Usage: bash $0 [--engine-root PATH] [--map /Game/Package] [--output PATH]"; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done
[[ "$(uname -s)" == Darwin && "$(uname -m)" == arm64 ]] || { echo 'Native Apple Silicon macOS is required.' >&2; exit 2; }
[[ "$(git -C "$ENGINE" rev-parse HEAD)" == e9d9e60c85f643e10eeb03f42f61554d18dcb30f ]] || { echo 'The engine checkout does not match the tested pin.' >&2; exit 2; }
[[ -f "$PROJECT" ]] || { echo "The CARLA project descriptor is missing at ${PROJECT}." >&2; exit 2; }
[[ -x "$ENGINE/Engine/Binaries/Mac/UE4Editor-Cmd" ]] || { echo 'Build the native editor target first.' >&2; exit 2; }
if [[ "$OUTPUT" != /* ]]; then
  OUTPUT="$ROOT/$OUTPUT"
fi
mkdir -p "$OUTPUT" "$ROOT/Build/macos-engine/cache/clang-module" "$ROOT/Build/macos-engine/cache/xdg"
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-12.0}"
export DOTNET_ROOT="$ROOT/Build/macos-engine/tooling/dotnet"
export CLANG_MODULE_CACHE_PATH="$ROOT/Build/macos-engine/cache/clang-module"
export XDG_CACHE_HOME="$ROOT/Build/macos-engine/cache/xdg"
cd "$(dirname "$PROJECT")"
env "UE-LocalDataCachePath=$ROOT/Build/macos-engine/ddc" \
  "$ENGINE/Engine/Binaries/Mac/UE4Editor-Cmd" "$PROJECT" \
  -run=Cook -targetplatform=MacNoEditor "-map=$MAP" -cooksinglepackage \
  -DisablePlugins=CarlaTools,MagicLeap,MagicLeapMedia,MagicLeapPassableWorld,MagicLeapLightEstimation \
  "-OutputDir=$OUTPUT" -unattended -UTF8Output -CrashForUAT \
  -stdout -FullStdOutLogOutput "-abslog=$ROOT/Build/macos-engine/cook-mac.log"
