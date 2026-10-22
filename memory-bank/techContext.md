# Technical context

## Baseline

- Workspace: `/Volumes/WIZARD/Users/p2p/scm/github.com/carla-simulator/carla`.
- Source: `https://github.com/carla-simulator/carla.git`.
- Selected release: `0.9.16`, commit `294096eb1c38eabf246e4f3a9cdab704e33a7f4c`.
- Matching engine: release README refers to `https://github.com/CarlaUnreal/UnrealEngine.git`, branch `carla`. Read-only authenticated access verified. Inspected candidate commit `e9d9e60c85f643e10eeb03f42f61554d18dcb30f` reports 4.26.2; release compatibility not yet validated by build.
- Existing UE58 `AGENTS.md` and its Linux-only UE4 build skill were read before switching. Neither should be assumed present at the historical tag. Linux setup scripts are not macOS installers.

## Host observed 2026-10-22

- Architecture: `arm64`.
- macOS 27.0.1 (26A434); Xcode 27.1 (27A9275).
- Developer directory: `/Applications/Xcode.app/Contents/Developer`.
- CMake 3.31.12; Ninja 1.13.2; default Python 3.15.0.
- Initial `/opt/homebrew/bin/python*` discovery found only Python 3.15; a compatible isolated interpreter was then provisioned below.
- Provisioned native Python 3.11.17 under `Build/macos/python/` and build venv `Build/macos/venv`; no system interpreter replacement.
- Build environment installed NumPy 1.26.4, build 1.6.1, distro 1.9.0, packaging 26.3, wheel 0.48.0, pytest 9.1.1, and setuptools 79.0.1. The final Darwin build requirements omit Linux-only distro/auditwheel/pyelftools.
- Workspace volume approximately 133 GiB free; system data volume approximately 164 GiB free. Recheck before engine/content downloads.
- `sysctl -n hw.memsize` was denied by sandbox; memory capacity not verified. Later runs outside the sandbox reported 32 GiB of memory and 10 logical cores.
- The workspace volume `/Volumes/WIZARD` is a case-sensitive APFS volume; the system volume is case-insensitive. The engine's file name expectations follow the case-insensitive convention, so the build creates the missing aliases.

## Useful commands

```sh
nu -c "ps | where name == 'gh'"
git rev-parse HEAD
git status --short
git show-ref --tags 0.9.16
git show 0.9.16:README.md
```

The completed clone was preserved. Do not reclone it. Never expose authentication tokens in logs.

## Native implementation commands

```sh
make LibCarla.client PYTHON="$PWD/Build/macos/venv/bin/python" MACOS_ARGS="--jobs 4"
make PythonAPI.wheel PYTHON="$PWD/Build/macos/venv/bin/python" MACOS_ARGS="--jobs 4"
make check.PythonAPI PYTHON="$PWD/Build/macos/wheel-test/bin/python"
make check.LibCarla PYTHON="$PWD/Build/macos/venv/bin/python"
```

Bootstrap: `Util/BuildTools/MacBuildClient.sh`, outputs `Build/macos-arm64/`, staged client dependencies `PythonAPI/carla/dependencies/`. Final helper clean/incremental builds and the wheel passed. See validation.md for exact evidence and artifact checksum.

Dependency pins: Boost 1.84.0, rpclib `8430cddd7b86a19e19823fac3d72d899794f7256`, Recast `e23d9199687d8032b8163c4cb1cb9c8f0bc38fbe`, libpng 1.6.43. Archive checksums are in the helper. C++14/libc++, ARM64, initial deployment target 12.0. Host Homebrew libpng targets macOS 27 and is deliberately excluded.

## Native simulator commands

```sh
bash Util/BuildTools/MacBuildEditor.sh --jobs 6
bash Util/BuildTools/MacBuildEngineProgram.sh --program ShaderCompileWorker --jobs 6
bash Util/BuildTools/MacBuildGame.sh --jobs 6
bash Util/BuildTools/MacRunSimulator.sh --map /Game/Carla/Maps/Town02_Opt
```

The engine checkout is `Build/macos-engine/source` at `e9d9e60c85f643e10eeb03f42f61554d18dcb30f`. `MacBuildEditor.sh` applies the patches in `Util/BuildTools/EnginePatches`, builds the native third-party libraries and compiles `CarlaUE4Editor`. `MacRunSimulator.sh` starts `Engine/Binaries/Mac/UE4Editor-Cmd` with the CARLA project in game mode and runs the native Python acceptance test.

All build caches, the derived data cache and the shader working directories stay inside `Build/`. `TMPDIR` is deliberately not redirected, because `xcrun` resolves the Apple Metal toolchain through the per-user cache directory and fails when it is moved. The editor and the shader compiler need access to the window server, so the simulator runs outside the command sandbox.

The wheel extension explicitly sets architecture and minimum deployment compiler/linker flags; the standalone Python interpreter's default `-mmacosx-version-min=11.0` must not override dependency target 12.0. Installed wheel links `/usr/lib/libz.1.dylib`, `/usr/lib/libc++.1.dylib`, and `/usr/lib/libSystem.B.dylib` only.
