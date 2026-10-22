#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
COOKED="$ROOT/Build/macos-game/cooked"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --cooked) COOKED="$2"; shift 2 ;;
    --help) echo "Usage: bash $0 [--cooked PATH]"; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done
PROJECT_CONTENT="$COOKED/CarlaUE4/Content"
ENGINE_CONTENT="$COOKED/Engine/Content"
MAP="$PROJECT_CONTENT/Carla/Maps/Town02_Opt.umap"
[[ -f "$MAP" ]] || { echo "Cooked Town02_Opt is missing at ${MAP}. Run MacCookMap.sh first." >&2; exit 2; }
[[ -d "$ENGINE_CONTENT" ]] || { echo "Cooked Engine content is missing at ${ENGINE_CONTENT}." >&2; exit 2; }
STAGE="$ROOT/Unreal/CarlaUE4/Saved/Cooked/MacNoEditor"
mkdir -p "$STAGE/CarlaUE4" "$STAGE/Engine"
rsync -a "$COOKED/CarlaUE4/" "$STAGE/CarlaUE4/"
rsync -a "$COOKED/Engine/" "$STAGE/Engine/"
for directory in Config Maps/OpenDrive Maps/Nav Maps/TM; do
  source="$ROOT/Unreal/CarlaUE4/Content/Carla/$directory"
  if [[ -d "$source" ]]; then
    mkdir -p "$STAGE/CarlaUE4/Content/Carla/$directory"
    rsync -a "$source/" "$STAGE/CarlaUE4/Content/Carla/$directory/"
  fi
done

GAME_STAGE="$ROOT/Build/macos-game/stage"
mkdir -p "$GAME_STAGE/CarlaUE4/Binaries/Mac" "$GAME_STAGE/CarlaUE4/Config"
rsync -a "$STAGE/CarlaUE4/Content/" "$GAME_STAGE/CarlaUE4/Content/"
rsync -a "$STAGE/Engine/Content/" "$GAME_STAGE/Engine/Content/"
rsync -a "$ROOT/Unreal/CarlaUE4/Config/" "$GAME_STAGE/CarlaUE4/Config/"
cp "$ROOT/Unreal/CarlaUE4/CarlaUE4.uproject" "$GAME_STAGE/CarlaUE4/"
rsync -a "$ROOT/Unreal/CarlaUE4/Binaries/Mac/CarlaUE4.app/" "$GAME_STAGE/CarlaUE4/Binaries/Mac/CarlaUE4.app/"
rsync -a "$ROOT/Build/macos-engine/source/Engine/Content/Internationalization/" "$GAME_STAGE/Engine/Content/Internationalization/"
echo "Staged cooked MacNoEditor content at ${STAGE}"
echo "Staged standalone runtime at ${GAME_STAGE}"
