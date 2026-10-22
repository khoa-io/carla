#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BUILD="$ROOT/Build/macos-server-arm64"
PREFIX="$BUILD/dependencies"
STAGE="$ROOT/Unreal/CarlaUE4/Plugins/Carla/CarlaDependencies"
JOBS="${CARLA_BUILD_CONCURRENCY:-}"
REBUILD=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --jobs) JOBS="$2"; shift 2 ;;
    --stage) STAGE="$2"; shift 2 ;;
    --rebuild) REBUILD=true; shift ;;
    --help) echo "Usage: $0 [--jobs N] [--stage ABSOLUTE_PATH] [--rebuild]"; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done
[[ "$(uname -s)" == Darwin && "$(uname -m)" == arm64 ]] || { echo "Native Apple Silicon macOS is required." >&2; exit 2; }
[[ "$STAGE" == /* && "$STAGE" != / ]] || { echo "--stage must be an absolute directory path" >&2; exit 2; }
JOBS="${JOBS:-$(sysctl -n hw.logicalcpu 2>/dev/null || echo 2)}"
[[ "$JOBS" =~ ^[1-9][0-9]*$ ]] || { echo "--jobs must be positive" >&2; exit 2; }
for tool in cmake ninja curl shasum xcrun awk; do command -v "$tool" >/dev/null; done
export CC="$(xcrun -f clang)"
export CXX="$(xcrun -f clang++)"
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-12.0}"
SDK_ROOT="$(xcrun --show-sdk-path)"
mkdir -p "$BUILD/downloads" "$BUILD/sources"
CONFIGURATION="$(
  printf 'recipe=1\ndeployment=%s\ncompiler=%s\nsdk=%s\n' "$MACOSX_DEPLOYMENT_TARGET" "$CXX" "$SDK_ROOT"
  printf 'cflags=%s\ncxxflags=%s\ncppflags=%s\nldflags=%s\n' "${CFLAGS:-}" "${CXXFLAGS:-}" "${CPPFLAGS:-}" "${LDFLAGS:-}"
  "$CXX" --version
  xcrun --show-sdk-version
  printf '%s\n' boost=1.84.0 rpclib=8430cddd7b86a19e19823fac3d72d899794f7256 recast=e23d9199687d8032b8163c4cb1cb9c8f0bc38fbe sqlite=3.34.1 xerces=3.2.3 proj=7.2.1 sumo=1da3c07e39f3e2e0d97f8f709a7255a0df8c6200 eigen=3.3.7
)"
if "$REBUILD"; then
  rm -rf "$PREFIX" "$BUILD/stage" "$BUILD"/*-build "$BUILD/sqlite3.o"
elif [[ -f "$BUILD/configuration.txt" ]]; then
  [[ "$(cat "$BUILD/configuration.txt")" == "$CONFIGURATION" ]] || { echo "Server build configuration changed. Rerun with --rebuild; source downloads are preserved." >&2; exit 2; }
elif [[ -d "$PREFIX/lib" ]]; then
  echo "Cached server binaries lack configuration metadata. Rerun with --rebuild." >&2
  exit 2
fi
printf '%s\n' "$CONFIGURATION" > "$BUILD/configuration.txt"
mkdir -p "$PREFIX/lib" "$PREFIX/include" "$PREFIX/bin"

download_source() {
  local name="$1" url="$2" checksum="$3" archive="$BUILD/downloads/$1.tar.gz"
  if [[ ! -f "$archive" && -f "$ROOT/Build/macos-arm64/downloads/$name.tar.gz" ]]; then
    cp "$ROOT/Build/macos-arm64/downloads/$name.tar.gz" "$archive"
  fi
  if [[ ! -f "$archive" ]]; then
    curl --fail --location --retry 3 "$url" -o "$archive.part"
    printf '%s  %s\n' "$checksum" "$archive.part" | shasum -a 256 -c -
    mv "$archive.part" "$archive"
  fi
  printf '%s  %s\n' "$checksum" "$archive" | shasum -a 256 -c -
  if [[ ! -d "$BUILD/sources/$name" ]]; then
    mkdir -p "$BUILD/sources/$name.partial"
    tar -xzf "$archive" -C "$BUILD/sources/$name.partial" --strip-components=1
    mv "$BUILD/sources/$name.partial" "$BUILD/sources/$name"
  fi
}

verify_native() {
  [[ "$(xcrun lipo -archs "$1")" == arm64 ]] || { echo "Expected an ARM64 binary: $1" >&2; exit 2; }
  xcrun otool -l "$1" | awk -v target="$MACOSX_DEPLOYMENT_TARGET" '
    function newer(actual, expected, actual_parts, expected_parts, part_index) {
      split(actual, actual_parts, "."); split(expected, expected_parts, ".");
      for (part_index = 1; part_index <= 3; part_index++) {
        if (actual_parts[part_index] + 0 > expected_parts[part_index] + 0) return 1;
        if (actual_parts[part_index] + 0 < expected_parts[part_index] + 0) return 0;
      }
      return 0;
    }
    $1 == "cmd" { legacy_version = ($2 == "LC_VERSION_MIN_MACOSX"); }
    $1 == "minos" || (legacy_version && $1 == "version") { found = 1; if (newer($2, target)) invalid = 1; }
    END { if (!found || invalid) exit 1; }' || { echo "Invalid macOS deployment metadata: $1" >&2; exit 2; }
}

COMMON=(-G Ninja -DCMAKE_POLICY_VERSION_MINIMUM=3.5 -DCMAKE_BUILD_TYPE=Release
  "-DCMAKE_C_COMPILER=$CC" "-DCMAKE_CXX_COMPILER=$CXX" -DCMAKE_CXX_STANDARD=14
  -DCMAKE_OSX_ARCHITECTURES=arm64 "-DCMAKE_OSX_SYSROOT=$SDK_ROOT"
  "-DCMAKE_OSX_DEPLOYMENT_TARGET=$MACOSX_DEPLOYMENT_TARGET"
  -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DBUILD_SHARED_LIBS=OFF "-DCMAKE_INSTALL_PREFIX=$PREFIX")
build_dependency() {
  local dependency="$1"; shift
  cmake -S "$BUILD/sources/$dependency" -B "$BUILD/$dependency-build" "${COMMON[@]}" "$@"
  cmake --build "$BUILD/$dependency-build" --parallel "$JOBS"
  cmake --install "$BUILD/$dependency-build"
}

download_source boost https://archives.boost.io/release/1.84.0/source/boost_1_84_0.tar.gz a5800f405508f5df8114558ca9855d2640a2de8f0445f051fa1c7c3383045724
download_source rpclib https://codeload.github.com/carla-simulator/rpclib/tar.gz/8430cddd7b86a19e19823fac3d72d899794f7256 afec1c0e23e5b57f015e58c461927fdadda3298b59a2f861969aa4780bfc8c97
download_source recast https://codeload.github.com/carla-simulator/recastnavigation/tar.gz/e23d9199687d8032b8163c4cb1cb9c8f0bc38fbe 9b974e7fd61596b8634f70c2e5e4e133659ddc9ac014c97e67aed1f75496aabe
download_source sqlite https://www.sqlite.org/2021/sqlite-autoconf-3340100.tar.gz 2a3bca581117b3b88e5361d0ef3803ba6d8da604b1c1a47d902ef785c1b53e89
download_source xerces https://archive.apache.org/dist/xerces/c/3/sources/xerces-c-3.2.3.tar.gz fb96fc49b1fb892d1e64e53a6ada8accf6f0e6d30ce0937956ec68d39bd72c7e
download_source proj https://download.osgeo.org/proj/proj-7.2.1.tar.gz b384f42e5fb9c6d01fe5fa4d31da2e91329668863a684f97be5d4760dbbf0a14
download_source sumo https://codeload.github.com/carla-simulator/sumo/tar.gz/1da3c07e39f3e2e0d97f8f709a7255a0df8c6200 f8f693ca73c87bc02033af2f33a2e59e50d4b88e52fa196005d8a1ac4dd7b450
download_source eigen https://gitlab.com/libeigen/eigen/-/archive/3.3.7/eigen-3.3.7.tar.gz d56fbad95abf993f8af608484729e3d87ef611dd85b3380a8bad1d5cbc373a57

build_dependency rpclib -DRPCLIB_CXX_STANDARD=14 -DRPCLIB_BUILD_TESTS=OFF -DRPCLIB_BUILD_EXAMPLES=OFF \
  '-DCMAKE_CXX_FLAGS=-stdlib=libc++ -DBOOST_NO_EXCEPTIONS -DASIO_NO_EXCEPTIONS'
build_dependency recast -DRECASTNAVIGATION_DEMO=OFF -DRECASTNAVIGATION_TESTS=OFF
if [[ ! -f "$PREFIX/lib/libsqlite3.a" || ! -f "$PREFIX/bin/sqlite3" ]]; then
  "$CC" -O2 -arch arm64 -isysroot "$SDK_ROOT" -mmacosx-version-min="$MACOSX_DEPLOYMENT_TARGET" \
    -DSQLITE_THREADSAFE=1 -c "$BUILD/sources/sqlite/sqlite3.c" -o "$BUILD/sqlite3.o"
  xcrun ar rcs "$PREFIX/lib/libsqlite3.a" "$BUILD/sqlite3.o"
  cp "$BUILD/sources/sqlite/sqlite3.h" "$BUILD/sources/sqlite/sqlite3ext.h" "$PREFIX/include/"
  "$CC" -O2 -arch arm64 -isysroot "$SDK_ROOT" -mmacosx-version-min="$MACOSX_DEPLOYMENT_TARGET" \
    "$BUILD/sources/sqlite/shell.c" "$BUILD/sqlite3.o" -o "$PREFIX/bin/sqlite3"
fi
build_dependency xerces -Dtranscoder=gnuiconv -Dnetwork=OFF -DCMAKE_DISABLE_FIND_PACKAGE_CURL=TRUE \
  "-DCMAKE_REQUIRED_LIBRARIES=$SDK_ROOT/usr/lib/libiconv.tbd" '-DCMAKE_EXE_LINKER_FLAGS=-liconv'
build_dependency proj "-DSQLITE3_INCLUDE_DIR=$PREFIX/include" "-DSQLITE3_LIBRARY=$PREFIX/lib/libsqlite3.a" \
  "-DEXE_SQLITE3=$PREFIX/bin/sqlite3" -DENABLE_TIFF=OFF -DENABLE_CURL=OFF \
  -DBUILD_PROJSYNC=OFF -DBUILD_PROJINFO=OFF -DBUILD_CCT=OFF -DBUILD_CS2CS=OFF \
  -DBUILD_GEOD=OFF -DBUILD_GIE=OFF -DBUILD_PROJ=OFF -DBUILD_TESTING=OFF
build_dependency sumo "-DPROJ_INCLUDE_DIR=$PREFIX/include" "-DPROJ_LIBRARY=$PREFIX/lib/libproj.a" \
  "-DXercesC_INCLUDE_DIR=$PREFIX/include" "-DXercesC_LIBRARY=$PREFIX/lib/libxerces-c.a" \
  "-DZLIB_INCLUDE_DIR=$SDK_ROOT/usr/include" "-DZLIB_LIBRARY=$SDK_ROOT/usr/lib/libz.tbd" \
  -DCMAKE_DISABLE_FIND_PACKAGE_X11=TRUE

cmake -S "$ROOT/LibCarla/cmake" -B "$BUILD/server-build" "${COMMON[@]}" \
  -DCMAKE_BUILD_TYPE=Server -DCMAKE_CXX_FLAGS_RELEASE='-O2 -DNDEBUG' \
  '-DCMAKE_CXX_FLAGS=-stdlib=libc++ -fno-exceptions -DBOOST_ERROR_CODE_HEADER_ONLY -DASIO_NO_EXCEPTIONS -DBOOST_NO_EXCEPTIONS -DLIBCARLA_NO_EXCEPTIONS -DPUGIXML_NO_EXCEPTIONS' \
  "-DCMAKE_INSTALL_PREFIX=$BUILD/stage" -DCARLA_VERSION=0.9.16 \
  -DLIBCARLA_BUILD_DEBUG=OFF -DLIBCARLA_BUILD_RELEASE=ON -DLIBCARLA_BUILD_TEST=OFF \
  "-DBOOST_INCLUDE_PATH=$BUILD/sources/boost" "-DRPCLIB_INCLUDE_PATH=$PREFIX/include" "-DRPCLIB_LIB_PATH=$PREFIX/lib"
cmake --build "$BUILD/server-build" --parallel "$JOBS"
cmake --install "$BUILD/server-build"
mkdir -p "$BUILD/stage/include/unsupported" "$BUILD/stage/bin" "$BUILD/stage/share"
cp -R "$BUILD/sources/eigen/Eigen" "$BUILD/stage/include/"
cp -R "$BUILD/sources/eigen/unsupported/Eigen" "$BUILD/stage/include/unsupported/"
cp "$PREFIX/include/OSM2ODR.h" "$BUILD/stage/include/"
cp -R "$PREFIX/share/proj" "$BUILD/stage/share/"
for library in sqlite3 xerces-c proj osm2odr; do cp "$PREFIX/lib/lib$library.a" "$BUILD/stage/lib/"; done
cp "$PREFIX/bin/RecastBuilder.app/Contents/MacOS/RecastBuilder" "$BUILD/stage/bin/RecastBuilder"
for library in rpc carla_server sqlite3 xerces-c proj osm2odr; do verify_native "$BUILD/stage/lib/lib$library.a"; done
verify_native "$BUILD/stage/bin/RecastBuilder"
cp "$BUILD/configuration.txt" "$BUILD/stage/build-configuration.txt"
mkdir -p "$(dirname "$STAGE")"
if [[ -e "$STAGE" ]]; then
  rm -rf "$BUILD/previous-stage"
  mv "$STAGE" "$BUILD/previous-stage"
fi
mv "$BUILD/stage" "$STAGE"
echo "Native server libraries and headers installed in $STAGE"
