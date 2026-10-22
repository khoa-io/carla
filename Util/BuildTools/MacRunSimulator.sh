#!/bin/bash
set -euo pipefail

# Starts the native CARLA server from the locally built editor, waits until the RPC
# server is listening, runs the native Python acceptance test and shuts the server
# down again. Every artefact stays inside the repository.

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ENGINE="${CARLA_MACOS_ENGINE_ROOT:-$ROOT/Build/macos-engine/source}"
PROJECT="$ROOT/Unreal/CarlaUE4/CarlaUE4.uproject"
PYTHON="${CARLA_MACOS_PYTHON:-$ROOT/Build/macos/wheel-test/bin/python}"
MAP="${CARLA_MACOS_MAP:-/Game/Carla/Maps/Town02_Opt}"
PORT="${CARLA_MACOS_PORT:-2000}"
FRAMES="${CARLA_MACOS_FRAMES:-10}"
WIDTH="${CARLA_MACOS_WIDTH:-321}"
HEIGHT="${CARLA_MACOS_HEIGHT:-241}"
SENSORS="${CARLA_MACOS_SENSORS:-rgb}"
TIMEOUT="${CARLA_MACOS_TIMEOUT:-900}"
LOG="$ROOT/Build/macos-engine/carla-server.log"
OUTPUT="$ROOT/Build/macos-engine/simulator-frame.png"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --engine-root) ENGINE="$2"; shift 2 ;;
    --python) PYTHON="$2"; shift 2 ;;
    --map) MAP="$2"; shift 2 ;;
    --port) PORT="$2"; shift 2 ;;
    --frames) FRAMES="$2"; shift 2 ;;
    --sensors) SENSORS="$2"; shift 2 ;;
    --timeout) TIMEOUT="$2"; shift 2 ;;
    --output) OUTPUT="$2"; shift 2 ;;
    --keep-running) KEEP_RUNNING=true; shift ;;
    --binary) BINARY="$2"; shift 2 ;;
    --help) echo "Usage: bash $0 [--engine-root PATH] [--python PATH] [--map PACKAGE] [--port N] [--frames N] [--sensors LIST] [--timeout SECONDS] [--output PNG] [--binary editor|game] [--keep-running]"; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

[[ "$(uname -s)" == Darwin && "$(uname -m)" == arm64 ]] || { echo 'Native Apple Silicon macOS is required.' >&2; exit 2; }
[[ -x "$PYTHON" ]] || { echo "Provide the native Python environment with --python (${PYTHON} is missing)." >&2; exit 2; }
[[ -f "$PROJECT" ]] || { echo "The CARLA project descriptor is missing at ${PROJECT}." >&2; exit 2; }
EDITOR="$ENGINE/Engine/Binaries/Mac/UE4Editor-Cmd"
GAME="$ROOT/Unreal/CarlaUE4/Binaries/Mac/CarlaUE4.app/Contents/MacOS/CarlaUE4"
GAME_PROJECT="$ROOT/Build/macos-game/stage/CarlaUE4/CarlaUE4.uproject"
GAME_BASEDIR="$ROOT/Build/macos-game/stage/CarlaUE4/Binaries/Mac"
case "${BINARY:-editor}" in
  editor)
    [[ -x "$EDITOR" ]] || { echo "The native editor is missing at ${EDITOR}." >&2; exit 2; }
    ;;
  game)
    [[ -x "$GAME" ]] || { echo "The native game target is missing at ${GAME}. Run MacBuildGame.sh first." >&2; exit 2; }
    [[ -f "$GAME_PROJECT" ]] || { echo "Standalone game content is missing at ${GAME_PROJECT}. Run MacStageCooked.sh first." >&2; exit 2; }
    EDITOR="$GAME"
    PROJECT="$GAME_PROJECT"
    BASEDIR="-basedir=$GAME_BASEDIR"
    ;;
  *) echo "Unknown binary: ${BINARY}." >&2; exit 2 ;;
esac

if [[ "$OUTPUT" != /* ]]; then
  OUTPUT="$PWD/$OUTPUT"
fi

mkdir -p "$ROOT/Build/macos-engine/ddc"
# The engine's local data cache path is set per child process because the name
# contains a hyphen, which the shell cannot export.
DDC_PATH="$ROOT/Build/macos-engine/ddc"
export CLANG_MODULE_CACHE_PATH="$ROOT/Build/macos-engine/cache/clang-module"
export XDG_CACHE_HOME="$ROOT/Build/macos-engine/cache/xdg"

SERVER_PID=""
cleanup() {
  if [[ -n "$SERVER_PID" ]] && kill -0 "$SERVER_PID" 2>/dev/null; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

cd "$(dirname "$PROJECT")"
# A previous run that crashed can leave the editor spinning and holding the RPC port
# and the log file.
pkill -9 -f "UE4Editor-Cmd" 2>/dev/null || true
pkill -9 -f "CarlaUE4.app" 2>/dev/null || true
pkill -9 -f "ShaderCompileWorker" 2>/dev/null || true
sleep 2
: > "$LOG"
env "UE-LocalDataCachePath=$DDC_PATH" "$EDITOR" "$PROJECT" "$MAP" ${BASEDIR:-} \
  -GAME -log -stdout -FullStdOutLogOutput -unattended -nosound \
  "-carla-rpc-port=$PORT" >> "$LOG" 2>&1 &
SERVER_PID=$!

echo "Native CARLA server starting (pid ${SERVER_PID}, map ${MAP}, rpc port ${PORT})."
deadline=$((SECONDS + TIMEOUT))
while ! grep -q "Initialized CarlaServer" "$LOG" 2>/dev/null; do
  if ! kill -0 "$SERVER_PID" 2>/dev/null; then
    echo 'The native CARLA server exited before the RPC server was ready:' >&2
    tail -40 "$LOG" >&2
    exit 1
  fi
  if (( SECONDS > deadline )); then
    echo "Timed out after ${TIMEOUT}s waiting for the CARLA RPC server." >&2
    tail -40 "$LOG" >&2
    exit 1
  fi
  sleep 2
done
grep "Initialized CarlaServer" "$LOG" | tail -1
# The RPC server is announced while the game mode is initialized, but the game thread
# only answers requests once the engine has finished its start up, which includes the
# compilation of the shaders of the map. The native client is used as the readiness
# probe.
echo 'Waiting for the native CARLA server to answer an RPC request.'
deadline=$((SECONDS + TIMEOUT))
until "$PYTHON" -c "
import sys
import carla
client = carla.Client('127.0.0.1', $PORT)
client.set_timeout(10.0)
# The world request needs a loaded world, so it is the readiness signal.
sys.exit(0 if client.get_world() else 1)
" >/dev/null 2>&1; do
  if ! kill -0 "$SERVER_PID" 2>/dev/null; then
    echo 'The native CARLA server exited before it answered an RPC request:' >&2
    tail -40 "$LOG" >&2
    exit 1
  fi
  if (( SECONDS > deadline )); then
    echo "Timed out after ${TIMEOUT}s waiting for the CARLA server to answer." >&2
    tail -40 "$LOG" >&2
    exit 1
  fi
  sleep 3
done
echo 'Native CARLA server is ready; running the native Python acceptance test.'
"$PYTHON" "$ROOT/Util/BuildTools/Tests/MacSimulatorSmoke.py" \
  --port "$PORT" --frames "$FRAMES" --width "$WIDTH" --height "$HEIGHT" \
  --sensors "$SENSORS" --output "$OUTPUT"
echo "RGB frame written to ${OUTPUT}"
if [[ "${KEEP_RUNNING:-false}" == true ]]; then
  echo 'Leaving the server running; press Ctrl-C to stop it.'
  wait "$SERVER_PID"
fi
