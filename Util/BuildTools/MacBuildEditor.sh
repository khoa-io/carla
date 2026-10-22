#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ENGINE="${CARLA_MACOS_ENGINE_ROOT:-$ROOT/Build/macos-engine/source}"
JOBS=6
PYTHON="${CARLA_MACOS_PYTHON:-$ROOT/Build/macos/venv/bin/python}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --engine-root) ENGINE="$2"; shift 2 ;;
    --jobs) JOBS="$2"; shift 2 ;;
    --python) PYTHON="$2"; shift 2 ;;
    --help) echo "Usage: bash $0 [--engine-root PATH] [--python PATH] [--jobs N]"; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done
[[ "$(uname -s)" == Darwin && "$(uname -m)" == arm64 ]] || { echo 'Native Apple Silicon macOS is required.' >&2; exit 2; }
# Keep every compiler, package and tool cache inside the repository so a build never
# writes outside the working directory.
export CARLA_BUILD_CACHE_ROOT="${CARLA_BUILD_CACHE_ROOT:-$ROOT/Build/macos-engine/cache}"
mkdir -p "$CARLA_BUILD_CACHE_ROOT/clang-module" "$CARLA_BUILD_CACHE_ROOT/xdg" "$CARLA_BUILD_CACHE_ROOT/pip"
export CLANG_MODULE_CACHE_PATH="$CARLA_BUILD_CACHE_ROOT/clang-module"
export XDG_CACHE_HOME="$CARLA_BUILD_CACHE_ROOT/xdg"
export PIP_CACHE_DIR="$CARLA_BUILD_CACHE_ROOT/pip"
# TMPDIR is deliberately left alone: xcrun resolves the Apple Metal toolchain through
# the per-user cache directory and fails when TMPDIR is redirected.
[[ "$JOBS" =~ ^[1-9][0-9]*$ ]] || { echo '--jobs must be positive.' >&2; exit 2; }
[[ "$(git -C "$ENGINE" rev-parse HEAD)" == e9d9e60c85f643e10eeb03f42f61554d18dcb30f ]] || { echo 'The engine checkout does not match the tested UE4.26.2 pin.' >&2; exit 2; }
[[ -f "$ENGINE/Engine/Programs/UnrealHeaderTool/Config/DefaultEngine.ini" ]] || { echo 'Materialize Engine/Programs in the engine sparse checkout before building.' >&2; exit 2; }

STREETMAP="$ROOT/Unreal/CarlaUE4/Plugins/Streetmap"
ARCHIVE="$ROOT/Build/macos-engine/streetmap.tar.gz"
STREETMAP_HASH=bd74ba1b1f3316c399f969a523bfbf94641abd12780b788bc8e3222aa68c19d5
if [[ ! -f "$STREETMAP/StreetMap.uplugin" ]]; then
  if [[ ! -f "$ARCHIVE" ]]; then
    curl --fail --location --retry 3 https://codeload.github.com/carla-simulator/StreetMap/tar.gz/260273d6b7c3f28988cda31fd33441de7e272958 -o "$ARCHIVE.part"
    printf '%s  %s\n' "$STREETMAP_HASH" "$ARCHIVE.part" | shasum -a 256 -c -
    mv "$ARCHIVE.part" "$ARCHIVE"
  fi
  printf '%s  %s\n' "$STREETMAP_HASH" "$ARCHIVE" | shasum -a 256 -c -
  mkdir -p "$STREETMAP"
  tar -xzf "$ARCHIVE" --strip-components=1 -C "$STREETMAP"
fi

OPTIONAL="$ROOT/Unreal/CarlaUE4/Config/OptionalModules.ini"
export CARLA_MACOS_FBX_SDK="${CARLA_MACOS_FBX_SDK:-$ROOT/Build/macos-engine/fbx-sdk}"
if [[ ! -f "$CARLA_MACOS_FBX_SDK/lib/clang/release/libfbxsdk.dylib" ]]; then
  echo 'Provide the universal Autodesk FBX SDK 2020.3.9 through CARLA_MACOS_FBX_SDK. See Docs/build_macos.md.' >&2
  exit 2
fi
xcrun lipo -verify_arch arm64 "$CARLA_MACOS_FBX_SDK/lib/clang/release/libfbxsdk.dylib"
if [[ ! -f "$OPTIONAL" ]]; then
  printf '%s\n' 'Unity ON' 'CarSim OFF' 'Chrono OFF' 'Pytorch OFF' 'Ros2 OFF' 'SimReady OFF' 'Fast_dds OFF' > "$OPTIONAL"
fi
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-12.0}"
bash "$ROOT/Util/BuildTools/MacBuildEngineTools.sh" --engine-root "$ENGINE"
bash "$ROOT/Util/BuildTools/MacBuildEngineLibraries.sh" --engine-root "$ENGINE" --jobs "$JOBS"
bash "$ROOT/Util/BuildTools/MacBuildNvTextureTools.sh" --engine-root "$ENGINE" --jobs "$JOBS"
bash "$ROOT/Util/BuildTools/MacBuildSpeedTree.sh" --engine-root "$ENGINE" --jobs "$JOBS"
bash "$ROOT/Util/BuildTools/MacBuildShaderConductor.sh" --engine-root "$ENGINE" --python "$PYTHON" --jobs "$JOBS"
# The PhysX redistributables ship the APEX framework with a mixed case file name,
# while the engine asks for the all upper case name. Default macOS volumes are
# case-insensitive so the difference is invisible there; a case-sensitive volume
# needs an alias for every name the engine resolves at runtime.
link_case_alias() {
  local directory="$1" expected="$2" actual="$3"
  if [[ ! -e "$directory/$expected" && -e "$directory/$actual" ]]; then
    ln -sf "$actual" "$directory/$expected"
  fi
}
PHYSX_BINARIES="$ENGINE/Engine/Binaries/ThirdParty/PhysX3/Mac"
link_case_alias "$PHYSX_BINARIES" libAPEXFramework.dylib libApexFramework.dylib
link_case_alias "$PHYSX_BINARIES" libAPEXFrameworkCHECKED.dylib libApexFrameworkCHECKED.dylib
link_case_alias "$PHYSX_BINARIES" libAPEXFrameworkPROFILE.dylib libApexFrameworkPROFILE.dylib

export DOTNET_ROOT="$ROOT/Build/macos-engine/tooling/dotnet"
export CARLA_MACOS_ENABLE_EXPERIMENTAL_EDITOR=1
"$DOTNET_ROOT/dotnet" "$ENGINE/Engine/Binaries/DotNET/UnrealBuildTool.dll" \
  CarlaUE4Editor Mac Development "-Project=$ROOT/Unreal/CarlaUE4/CarlaUE4.uproject" \
  -Architecture=arm64 -NoHotReload -NoUBTMakefiles -NoDebugInfo "-MaxParallelActions=$JOBS" \
  -DisablePlugin=PerforceSourceControl+PythonScriptPlugin+AlembicHairImporter+HairStrands+RenderDocPlugin+MDL+SimReady+AlembicImporter \
  "-Log=$ROOT/Build/macos-engine/carla-editor-build.log"
