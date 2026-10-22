# Native macOS validation record

Date: 2026-10-22. Baseline: CARLA 0.9.16, `294096eb1c38eabf246e4f3a9cdab704e33a7f4c`.

## Environment

- Native ARM64 macOS 27.0.1 (26A434), Xcode 27.1 (27A9275), Apple Clang 21.0.0.
- CMake 3.31.12, Ninja 1.13.2, Python 3.11.17.
- Isolated Python build environment: setuptools 79.0.1, wheel 0.48.0, build 1.6.1, NumPy 1.26.4, packaging 26.3, distro 1.9.0.
- Native dependencies: Boost 1.84.0, rpclib `8430cddd7b86a19e19823fac3d72d899794f7256`, Recast `e23d9199687d8032b8163c4cb1cb9c8f0bc38fbe`, libpng 1.6.43, SDK zlib.
- Initial binary deployment target: macOS 12.0. Runtime support on older OS versions has not been certified.

## Completed checks

- Original clone completed; detached checkout matches the requested release. No branches or commits created.
- Helper help, shell syntax, positive-job-count validation, Darwin Makefile help/dry-run, and explicit unsupported-simulator diagnostic exercised.
- Windows Makefile dispatch dry-run still selects existing Windows recipes.
- Scoped `git diff --check` passes on edited tracked sources; Python setup syntax compiles.
- Independent source review covered cache invalidation, architecture flags, buffer bounds/API compatibility, MessagePack types, and native engine limitations.
- Pinned source dependencies built as ARM64. Archive architecture and deployment metadata checks passed in the helper.
- Native LibCarla compiled/installed successfully through the final unchanged helper; a subsequent incremental build validated the API-preserving Buffer forwarding templates.
- Changing deployment target from 12 to 13 correctly rejects the existing configuration with an actionable `--rebuild` diagnostic.
- Shipped C++ smoke compiled/linked against installed headers/archives and passed buffer sizes/bounds, integer/string variant serialization, correct CARLA RPC metadata/response envelopes, and a 20 ms timeout against a 200 ms delayed response.
- Parent independently ran the integrated Make smoke recipe successfully, skipping the already validated prerequisite to avoid restaging during wheel compilation.
- Native wheel built, installed with `--no-deps --no-index` into clean `Build/macos/wheel-test`, and imported from `/private/tmp` with correct package/client version 0.9.16.
- Existing transform suite: 11 passed. Existing vehicle suite: 3 passed. Total: 14 passed.
- The actual `make check.PythonAPI` target also passed against the clean wheel environment, including its native/version/import-path guard.
- Wheel tag: `cp311-cp311-macosx_12_0_arm64`. Installed extension is ARM64, with `LC_BUILD_VERSION` minimum 12.0 / SDK 27.0. Only system zlib, libc++, and libSystem dynamic libraries are linked.

## Reproduction and artifact

```sh
bash Util/BuildTools/MacBuildClient.sh --python "$PWD/Build/macos/venv/bin/python" --jobs 8 --rebuild
make PythonAPI.wheel PYTHON="$PWD/Build/macos/venv/bin/python" MACOS_ARGS="--jobs 8"
make check.LibCarla PYTHON="$PWD/Build/macos/venv/bin/python"
make check.PythonAPI PYTHON="$PWD/Build/macos/wheel-test/bin/python"
```

The clean helper and final incremental helper were run directly; the wheel was built with the equivalent Python build recipe using `--no-isolation`. For the parent integration check, the exact command was `make -o LibCarla.client.release check.LibCarla PYTHON="$PWD/Build/macos/venv/bin/python"`. Loopback socket binding required sandbox escalation. The two Python unit commands used unittest discovery as in Mac.mk.

Artifact: `PythonAPI/carla/dist/carla-0.9.16-cp311-cp311-macosx_12_0_arm64.whl`.

SHA-256: `c96876e945f83a50e712dbff0adb651cc8f681abd9b420251958fef7ed812092`.

## Logs and outputs

Local build outputs and logs are intentionally ignored by Git:

- `Build/macos-arm64/configuration.txt`: toolchain/Python/deployment/dependency configuration.
- `Build/macos-arm64/build-final.log`: clean dependency/client build.
- `Build/macos-arm64/client.log`: initial compile investigation, including failures fixed during the port.
- `Build/macos-arm64/build-incremental.log`: final API-preserving client rebuild/install.
- `Build/macos-arm64/python-wheel.log`: native wheel build.
- `Build/macos-arm64/python-transform-tests.log`: 11 passing transform tests.
- `Build/macos-arm64/python-vehicle-tests.log`: 3 passing vehicle tests.
- `Build/macos-arm64/python-validation.log`: clean import, wheel metadata, Mach-O and dynamic linkage inspection.
- `Build/macos-arm64/python-packaging-checks.log`: packaging defaults and invalid configuration diagnostics.
- `Build/macos-arm64/python-make-check.log`: integrated Python Make target.
- `PythonAPI/carla/dependencies/`: installed client headers/archives.
- `PythonAPI/carla/dist/`: completed wheel artifact.

## Native server and engine-tool continuation

- `make check.LibCarla.server MACOS_ARGS="--jobs 6"` passes: native no-exceptions server dependency link, OSM conversion, and OpenDRIVE parsing. Log: `Build/macos-server-arm64/make-smoke.log`.
- `make check.PhysX` passes: eight static/five dynamic profile libraries contain ARM64; vehicle SDK initializes and 240 physics steps settle a box at height 0.499997. Log: `Build/macos-engine/physx-make.log`.
- Pinned native .NET SDK 8.0.426 compiles UnrealBuildTool; Mac SDK validation passes. Native ARM64 UHT and six dylibs link, metadata generation passes, and UHT runs on the editor manifest. The ARM64 shader compile worker was built for the host architecture and runs.
- Manifest dependency fetcher passes six tests; 53,578 Mac/common engine dependency files were installed with blob and decompressed-pack SHA1 verification.
- Native Metal 2.3 shader compilation, metallib linking, Apple M1 Pro GPU dispatch and 64-value shared-buffer readback pass. Fixture: `MacMetalSmoke.metal`/`.mm`; log: `Build/macos-metal/smoke.log`. This is not a CARLA rendered camera test.
- Seven native source-built engine libraries are staged separately from their Intel originals. MCPP's Unreal-specific memory allocator/file-loader API passes an include and macro-expansion test (`MacMcppSmoke.cpp`), reproduced by MacBuildEngineLibraries.sh. Log: `Build/macos-engine/native-libraries.log`.
- NVIDIA Texture Tools 2.0.8 and squish were rebuilt from the pinned engine sources for arm64, with the ARM64 CPU detection of the posh library added, and the SpeedTree core library was rebuilt from its SDK sources for arm64. The Intel ISPC texture compressor and the Qualcomm ETC2 converter have no arm64 build, so those two texture formats are disabled on native Apple Silicon. Helpers: `MacBuildNvTextureTools.sh`, `MacBuildSpeedTree.sh`.
- Recompiled the native client serialization/RPC/timeout fixture with MacTypes.h preincluded and MSGPACK_DISABLE_LEGACY_NIL; it passes on port 42917. Log: `Build/macos-arm64/client-sdk-smoke.log`.
- Native ShaderConductor/DXC build completed (1,209 actions). ARM64 llvm-tblgen/clang-tblgen, native dylib staging/signing and HLSL-to-SPIR-V-to-Metal conversion pass. Apple's Metal compiler and metallib linker accept the generated fragment shader. Log: `Build/macos-engine/shader-conductor-smoke.log`. Staged dylibs link only each other/system libraries, not Homebrew/MacPorts runtimes.

## Native simulator validation

- `bash Util/BuildTools/MacBuildEditor.sh --jobs 6` completes with no errors and produces the arm64 `CarlaUE4Editor` target, the ARM64 Unreal header tool and the ARM64 shader compile worker.
- `bash Util/BuildTools/MacBuildGame.sh --jobs 6` completes with no errors and produces the standalone native game target `Unreal/CarlaUE4/Binaries/Mac/CarlaUE4.app/Contents/MacOS/CarlaUE4`, an arm64 Mach-O executable. Running it needs the packaged content layout, which is the remaining distribution work.
- `bash Util/BuildTools/MacRunSimulator.sh --map /Game/Carla/Maps/Town02_Opt` starts the native server, waits until it answers a world request and runs the native Python acceptance test.
- The acceptance test `Util/BuildTools/Tests/MacSimulatorSmoke.py` passed against the native server twice. The server reported version 0.9.16 on the map `Carla/Maps/Town02_Opt`, the native client spawned `vehicle.tesla.model3`, and ten consecutive camera frames were received with consecutive world frame numbers and a fixed 0.05 s step (0.7068 s to 1.1568 s in the final run, frames 33 to 42). The frames are not uniform, and the rendered image was written to `Build/macos-engine/simulator-frame.png`.
- `bash Util/BuildTools/MacRunSimulator.sh --sensors rgb,depth,semantic,lidar,radar --frames 6 --output Build/macos-engine/simulator-all-sensors-rgb.png` passed. Frames 32–37 aligned at 0.05 s intervals for all five sensor types in one synchronous run. Camera images were nonuniform at 321x241, LiDAR returned nonempty 16-byte point records, and radar returned detections. Client and server reported 0.9.16; the vehicle was `vehicle.tesla.model3` on `Carla/Maps/Town02_Opt`.
- `MacBuildEngineProgram.sh --program ShaderCompileWorker --jobs 6` produces an ARM64 Mach-O shader worker.
- The client was the native wheel in `Build/macos/wheel-test`, whose extension is `libcarla.cpython-311-darwin.so` for arm64.
- The engine logs the readiness line `Initialized CarlaServer: Ports(rpc=2000, streaming=2001, secondary=2002)`.
- The server log is `Build/macos-engine/carla-server.log` and the run log is `Build/macos-engine/simulator-run.log`.
- `Town01_Opt` did not answer the world request within the client timeout while its shaders and textures were still being built. The first run of a map has to compile its shaders and build its textures, so the readiness probe has to wait for the world request instead of the version request.
- An asynchronous, uncapped (`-novsync`) RGB-camera throughput run on the M1 Pro delivered 1,079 frames in 30.001 s at 1280x720: 35.97 camera frames/s average and 27.147 ms median inter-frame interval. This is client-delivered sensor throughput with one moving Tesla and one RGB camera, not Unreal's internal `stat fps`; it is not directly comparable to Linux/Windows without a matched benchmark. Video: `Build/macos-engine/carla-macos-fps.mp4`; structured result: `Build/macos-engine/carla-macos-fps-results.json`.

## Not established

The cooked and packaged macOS distribution, analytic sensor reference validation, longer stability runs, a clean second-machine install, the Linux/Windows builds, and certification of the deployment target on older macOS versions remain outstanding. The native prototype acceptance gate is complete; see `Docs/macos_engine_audit.md` and `Docs/build_macos.md` for productization limits.
