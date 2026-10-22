#!/bin/bash
set -euo pipefail

if [[ "$(uname -s)" != Darwin || "$(uname -m)" != arm64 ]]; then
  echo 'Native engine tooling requires an Apple Silicon macOS host.' >&2
  exit 2
fi

repository_root="$(cd "$(dirname "$0")/../.." && pwd)"
engine_root="${CARLA_MACOS_ENGINE_ROOT:-${repository_root}/Build/macos-engine/source}"
bootstrap_only=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --engine-root) engine_root="$2"; shift 2 ;;
    --bootstrap-only) bootstrap_only=true; shift ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

tooling_root="${repository_root}/Build/macos-engine/tooling"
sdk_version=8.0.426
sdk_hash=17cd408c92eb6ceedc06d41fa726c783b9be020c6ae5f3624ad3a0b2c26a78aa7d09f38338003163a72bb14d437731debf533c0451a5c6a05de3b1e37a3aa50a
sdk_archive="${tooling_root}/downloads/dotnet-sdk-${sdk_version}-osx-arm64.tar.gz"
mkdir -p "${tooling_root}/downloads"
if [[ ! -f "$sdk_archive" ]]; then
  curl --fail --location --retry 3 \
    "https://builds.dotnet.microsoft.com/dotnet/Sdk/${sdk_version}/dotnet-sdk-${sdk_version}-osx-arm64.tar.gz" \
    --output "${sdk_archive}.download"
  printf '%s  %s\n' "$sdk_hash" "${sdk_archive}.download" | shasum -a 512 -c -
  mv "${sdk_archive}.download" "$sdk_archive"
fi
printf '%s  %s\n' "$sdk_hash" "$sdk_archive" | shasum -a 512 -c -

export DOTNET_ROOT="${tooling_root}/dotnet"
export DOTNET_CLI_HOME="${tooling_root}/dotnet-home"
export DOTNET_CLI_TELEMETRY_OPTOUT=1
export DOTNET_SKIP_FIRST_TIME_EXPERIENCE=1
export NUGET_PACKAGES="${tooling_root}/nuget-packages"
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-12.0}"
if [[ ! -x "${DOTNET_ROOT}/dotnet" ]]; then
  mkdir -p "$DOTNET_ROOT"
  tar -xzf "$sdk_archive" -C "$DOTNET_ROOT"
fi
[[ "$(xcrun lipo -archs "${DOTNET_ROOT}/dotnet")" == arm64 ]]
[[ "$("${DOTNET_ROOT}/dotnet" --version)" == "$sdk_version" ]]
"${DOTNET_ROOT}/dotnet" --info
if $bootstrap_only; then
  exit 0
fi

programs_root="${engine_root}/Engine/Source/Programs"
if [[ ! -f "${programs_root}/UnrealBuildTool/UnrealBuildTool.csproj" ]]; then
  echo "Unreal Engine source is missing at ${engine_root}." >&2
  exit 2
fi
patch_root="${repository_root}/Util/BuildTools/EnginePatches/tooling"
for patch_file in "${patch_root}"/*.patch "${repository_root}/Util/BuildTools/EnginePatches/runtime"/*.patch; do
  [[ -f "$patch_file" ]] || continue
  if git -C "$engine_root" apply --reverse --check "$patch_file" 2>/dev/null; then
    continue
  fi
  git -C "$engine_root" apply --check "$patch_file"
  git -C "$engine_root" apply "$patch_file"
done
cp "${patch_root}/UnrealBuildTool.Native.csproj" "${programs_root}/UnrealBuildTool/"
cp "${patch_root}/DotNETUtilities.Native.csproj" "${programs_root}/DotNETCommon/DotNETUtilities/"
"${DOTNET_ROOT}/dotnet" build \
  "${programs_root}/UnrealBuildTool/UnrealBuildTool.Native.csproj" \
  --configuration Release --nologo --disable-build-servers
"${DOTNET_ROOT}/dotnet" "${engine_root}/Engine/Binaries/DotNET/UnrealBuildTool.dll" \
  -Mode=ValidatePlatforms -Platforms=Mac | tee "${tooling_root}/platform-validation.log"
grep -q 'Mac VALID' "${tooling_root}/platform-validation.log"
