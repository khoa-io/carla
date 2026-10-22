#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
VERSION=20250912_2171890
CHECKSUM=997d8cb2dde7f3757d789b898ddd0e33bbb5a0f3097ee2b0936971c585d007b5
BUILD="$ROOT/Build/macos-assets"
ARCHIVE="$BUILD/$VERSION.tar.gz"
DESTINATION="$ROOT/Unreal/CarlaUE4/Content/Carla"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --archive) ARCHIVE="$2"; shift 2 ;;
    --help) echo "Usage: bash $0 [--archive PATH]"; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done
[[ "$(uname -s)" == Darwin && "$(uname -m)" == arm64 ]] || { echo 'Native Apple Silicon macOS is required.' >&2; exit 2; }
if [[ -d "$DESTINATION" ]]; then
  if [[ -f "$DESTINATION/.macos-source-version" && "$(cat "$DESTINATION/.macos-source-version")" == "$VERSION $CHECKSUM" ]]; then
    if [[ ! -f "$DESTINATION/.version" ]]; then
      printf '%s\n' "$VERSION" > "$DESTINATION/.version"
    elif [[ "$(cat "$DESTINATION/.version")" != "$VERSION" ]]; then
      echo 'Existing content version metadata is inconsistent; it will not be overwritten.' >&2
      exit 2
    fi
    echo 'Version-matched source assets already installed; existing asset edits are preserved.'
    exit 0
  fi
  echo "Existing content at $DESTINATION has not been identified by this installer. It will not be overwritten." >&2
  exit 2
fi
mkdir -p "$BUILD"
AVAILABLE_KB="$(df -Pk "$ROOT" | awk 'NR == 2 { print $4 }')"
REQUIRED_KB=$(( (25086917383 + 1023) / 1024 + 15 * 1024 * 1024 ))
if [[ ! -f "$ARCHIVE" ]]; then
  REQUIRED_KB=$(( REQUIRED_KB + (21567002106 + 1023) / 1024 ))
fi
[[ "$AVAILABLE_KB" =~ ^[0-9]+$ && "$AVAILABLE_KB" -ge "$REQUIRED_KB" ]] || { echo 'Insufficient free space for source assets plus a 15 GiB build reserve.' >&2; exit 2; }
if [[ ! -f "$ARCHIVE" ]]; then
  curl --fail --location --retry 3 --continue-at - \
    "https://carla-assets.s3.us-east-005.backblazeb2.com/$VERSION.tar.gz" -o "$ARCHIVE.part"
  printf '%s  %s\n' "$CHECKSUM" "$ARCHIVE.part" | shasum -a 256 -c -
  mv "$ARCHIVE.part" "$ARCHIVE"
fi
printf '%s  %s\n' "$CHECKSUM" "$ARCHIVE" | shasum -a 256 -c -
STAGE="$(mktemp -d "$BUILD/assets-stage.XXXXXX")"
echo "Extracting verified source content into $STAGE"
tar --no-same-owner -xzf "$ARCHIVE" -C "$STAGE"
printf '%s %s\n' "$VERSION" "$CHECKSUM" > "$STAGE/.macos-source-version"
printf '%s\n' "$VERSION" > "$STAGE/.version"
mkdir -p "$(dirname "$DESTINATION")"
[[ ! -e "$DESTINATION" ]] || { echo 'Destination appeared during extraction; preserving the staging directory.' >&2; exit 2; }
mv "$STAGE" "$DESTINATION"
echo "CARLA 0.9.16 source content installed at $DESTINATION"
