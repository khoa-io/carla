#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PYTHON="${PYTHON:-python3}"
JOBS="${CARLA_BUILD_CONCURRENCY:-}"
DEPS_ONLY=false
REBUILD=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --python) PYTHON="$2"; shift 2 ;;
    --jobs) JOBS="$2"; shift 2 ;;
    --dependencies-only) DEPS_ONLY=true; shift ;;
    --rebuild) REBUILD=true; shift ;;
    --help) echo "Usage: $0 --python /absolute/python3 [--jobs N] [--dependencies-only] [--rebuild]"; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done
if [[ "$(uname -s)" != Darwin || "$(uname -m)" != arm64 ]]; then
  echo "This build requires native Apple Silicon macOS." >&2
  exit 2
fi
PYTHON="$(command -v "$PYTHON")"
JOBS="${JOBS:-$(sysctl -n hw.logicalcpu 2>/dev/null || echo 2)}"
"$PYTHON" -c 'import platform, sys; assert platform.machine() == "arm64", "Python must run natively as arm64"; assert (3, 9) <= sys.version_info[:2] <= (3, 12), "Use Python 3.9 through 3.12 with Boost 1.84"'
[[ "$JOBS" =~ ^[1-9][0-9]*$ ]] || { echo "--jobs must be positive" >&2; exit 2; }
for tool in cmake ninja curl shasum xcrun; do command -v "$tool" >/dev/null; done
export CC="$(xcrun -f clang)"
export CXX="$(xcrun -f clang++)"
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-12.0}"
SDK_ROOT="$(xcrun --show-sdk-path)"
BUILD="$ROOT/Build/macos-arm64"
PREFIX="$BUILD/dependencies"
PNG_PREFIX="$BUILD/libpng-install"
mkdir -p "$BUILD/downloads" "$BUILD/sources" "$PREFIX"
CONFIGURATION="$(
  printf 'deployment=%s\ncompiler=%s\n' "$MACOSX_DEPLOYMENT_TARGET" "$CXX"
  printf 'cflags=%s\ncxxflags=%s\ncppflags=%s\nldflags=%s\n' "${CFLAGS:-}" "${CXXFLAGS:-}" "${CPPFLAGS:-}" "${LDFLAGS:-}"
  "$CXX" --version
  printf '%s\n' "$SDK_ROOT"
  xcrun --show-sdk-version
  "$PYTHON" -c 'import pathlib, sys, sysconfig; print(pathlib.Path(sys._base_executable).resolve()); print(sys.version); print(sysconfig.get_config_var("SOABI"))'
  printf '%s\n' recipe=1 boost=1.84.0 rpclib=8430cddd7b86a19e19823fac3d72d899794f7256 recast=e23d9199687d8032b8163c4cb1cb9c8f0bc38fbe libpng=1.6.43
)"
if "$REBUILD"; then
  rm -rf "$PREFIX" "$BUILD/client-build" "$BUILD/rpclib-build" "$BUILD/recast-build" \
    "$BUILD/libpng-build" "$PNG_PREFIX" "$BUILD/sources/boost/bin.v2" \
    "$ROOT/PythonAPI/carla/dependencies"
  rm -f "$BUILD"/boost-python*.complete
  mkdir -p "$PREFIX"
elif [[ -f "$BUILD/configuration.txt" ]]; then
  if [[ "$(cat "$BUILD/configuration.txt")" != "$CONFIGURATION" ]]; then
    echo "Native build configuration changed. Rerun with --rebuild to rebuild cached binaries (downloads are preserved)." >&2
    exit 2
  fi
elif [[ -d "$PREFIX/lib" ]]; then
  echo "Cached binaries lack a configuration record. Rerun with --rebuild (downloads are preserved)." >&2
  exit 2
fi
printf '%s\n' "$CONFIGURATION" > "$BUILD/configuration.txt"

verify_archive() {
  xcrun lipo -verify_arch arm64 "$1"
  xcrun otool -l "$1" | "$PYTHON" -c 'import re, sys
target = tuple(map(int, sys.argv[1].split(".")))
target += (0,) * (3 - len(target))
versions = re.findall(r"^\s*(?:minos|version)\s+(\d+(?:\.\d+){0,2})\s*$", sys.stdin.read(), re.MULTILINE)
assert versions, "Missing deployment metadata in " + sys.argv[2]
for version in versions:
    actual = tuple(map(int, version.split(".")))
    actual += (0,) * (3 - len(actual))
    assert actual <= target, "Dependency minimum macOS " + version + " exceeds target " + sys.argv[1] + ": " + sys.argv[2]' "$MACOSX_DEPLOYMENT_TARGET" "$1"
}

download_source() {
  local name="$1" url="$2" checksum="$3" archive="$BUILD/downloads/$1.tar.gz"
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

PY_SUFFIX="$("$PYTHON" -c 'import sys; print("%d%d" % sys.version_info[:2])')"
if [[ ! -f "$BUILD/boost-python$PY_SUFFIX.complete" || ! -f "$PREFIX/lib/libboost_python$PY_SUFFIX.a" || ! -f "$PREFIX/lib/libboost_filesystem.a" || ! -f "$PREFIX/lib/libboost_system.a" ]]; then
  download_source boost https://archives.boost.io/release/1.84.0/source/boost_1_84_0.tar.gz a5800f405508f5df8114558ca9855d2640a2de8f0445f051fa1c7c3383045724
  (
    cd "$BUILD/sources/boost"
    ./bootstrap.sh --with-toolset=clang --with-python="$PYTHON" --with-libraries=python,filesystem,system
    "$PYTHON" -c 'import sys, sysconfig; print("using python : %d.%d : \"%s\" : \"%s\" : \"%s\" ;" % (sys.version_info.major, sys.version_info.minor, sys.executable, sysconfig.get_path("include"), sysconfig.get_config_var("LIBDIR")))' > project-config.jam
    ./b2 --user-config=/dev/null --ignore-site-config --with-python --with-filesystem --with-system toolset=clang architecture=arm address-model=64 target-os=darwin variant=release link=static threading=multi cxxflags="-std=c++14 -stdlib=libc++ -fPIC -mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET" --layout=system --prefix="$PREFIX" -j"$JOBS" install
  )
  touch "$BUILD/boost-python$PY_SUFFIX.complete"
fi

download_source rpclib https://codeload.github.com/carla-simulator/rpclib/tar.gz/8430cddd7b86a19e19823fac3d72d899794f7256 afec1c0e23e5b57f015e58c461927fdadda3298b59a2f861969aa4780bfc8c97
download_source recast https://codeload.github.com/carla-simulator/recastnavigation/tar.gz/e23d9199687d8032b8163c4cb1cb9c8f0bc38fbe 9b974e7fd61596b8634f70c2e5e4e133659ddc9ac014c97e67aed1f75496aabe
download_source libpng https://codeload.github.com/pnggroup/libpng/tar.gz/refs/tags/v1.6.43 fecc95b46cf05e8e3fc8a414750e0ba5aad00d89e9fdf175e94ff041caf1a03a
cmake -S "$BUILD/sources/libpng" -B "$BUILD/libpng-build" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_OSX_DEPLOYMENT_TARGET="$MACOSX_DEPLOYMENT_TARGET" \
  -DCMAKE_INSTALL_PREFIX="$PNG_PREFIX" -DPNG_SHARED=OFF -DPNG_STATIC=ON \
  -DZLIB_INCLUDE_DIR="$SDK_ROOT/usr/include" -DZLIB_LIBRARY="$SDK_ROOT/usr/lib/libz.tbd" \
  -DPNG_TESTS=OFF -DPNG_TOOLS=OFF -DPNG_FRAMEWORK=OFF
cmake --build "$BUILD/libpng-build" --parallel "$JOBS"
cmake --install "$BUILD/libpng-build"
for dependency in rpclib recast; do
  cmake -S "$BUILD/sources/$dependency" -B "$BUILD/$dependency-build" -G Ninja \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5 -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_CXX_STANDARD=14 -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$MACOSX_DEPLOYMENT_TARGET" \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DCMAKE_INSTALL_PREFIX="$PREFIX" \
    -DRPCLIB_CXX_STANDARD=14 -DRPCLIB_BUILD_TESTS=OFF -DRPCLIB_BUILD_EXAMPLES=OFF \
    -DRECASTNAVIGATION_DEMO=OFF -DRECASTNAVIGATION_TESTS=OFF
  cmake --build "$BUILD/$dependency-build" --parallel "$JOBS"
  cmake --install "$BUILD/$dependency-build"
done
for archive in libboost_python"$PY_SUFFIX".a libboost_filesystem.a libboost_system.a librpc.a libRecast.a libDetour.a libDetourCrowd.a; do
  verify_archive "$PREFIX/lib/$archive"
done
verify_archive "$PNG_PREFIX/lib/libpng.a"
if "$DEPS_ONLY"; then exit 0; fi
cmake -S "$ROOT/LibCarla/cmake" -B "$BUILD/client-build" -G Ninja \
  -DCMAKE_POLICY_VERSION_MINIMUM=3.5 -DCMAKE_BUILD_TYPE=Client \
  -DCMAKE_CXX_STANDARD=14 -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_OSX_DEPLOYMENT_TARGET="$MACOSX_DEPLOYMENT_TARGET" \
  -DCMAKE_CXX_FLAGS="-stdlib=libc++ -DBOOST_ERROR_CODE_HEADER_ONLY" \
  -DCMAKE_CXX_FLAGS_RELEASE_CLIENT="-O2 -DNDEBUG" \
  -DCMAKE_INSTALL_PREFIX="$ROOT/PythonAPI/carla/dependencies" \
  -DCARLA_VERSION=0.9.16 -DLIBCARLA_BUILD_DEBUG=OFF -DLIBCARLA_BUILD_RELEASE=ON \
  -DLIBCARLA_BUILD_TEST=OFF -DBOOST_INCLUDE_PATH="$PREFIX/include" \
  -DBOOST_LIB_PATH="$PREFIX/lib" -DRPCLIB_INCLUDE_PATH="$PREFIX/include" \
  -DRPCLIB_LIB_PATH="$PREFIX/lib" -DRECAST_INCLUDE_PATH="$PREFIX/include" \
  -DRECAST_LIB_PATH="$PREFIX/lib" -DLIBPNG_INCLUDE_PATH="$PNG_PREFIX/include/" \
  -DLIBPNG_LIB_PATH="$PNG_PREFIX/lib"
cmake --build "$BUILD/client-build" --parallel "$JOBS"
cmake --install "$BUILD/client-build"
verify_archive "$ROOT/PythonAPI/carla/dependencies/lib/libcarla_client.a"
