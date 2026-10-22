# Active context

Updated: 2026-10-22. Active task: [TASK001](tasks/TASK001-native-macos-port.md).

## Direction

- The user asked for autonomous work until the native port succeeds. The native prototype gate is met: the ARM64 simulator spawns a vehicle and streams synchronized RGB frames through the native Python API. RGB, depth, semantic, LiDAR and radar also pass a combined synchronization/data smoke test.
- CARLA baseline is tag `0.9.16`, detached at `294096eb1c38eabf246e4f3a9cdab704e33a7f4c`. UE5 proposal is superseded. No branches, commits or upstream publications requested or made.
- Engine is the private UE4.26.2 fork pinned at `e9d9e60c85f643e10eeb03f42f61554d18dcb30f`, under `Build/macos-engine/source`, patched through `Util/BuildTools/EnginePatches`.
- The validated simulator process is the editor build in game mode. The standalone `CarlaUE4` game target builds and links natively, but still needs cooked content to run as a standalone app. Sensor smoke tests establish payload delivery and frame/timestamp alignment, not analytic accuracy.

## Validated

- Native ARM64 LibCarla client and CPython 3.11 wheel, clean import, 14 existing unit tests, serialization/RPC/timeout fixture.
- Native no-exceptions server dependencies, OSM conversion and LibCarla OpenDRIVE parsing. `make check.LibCarla.server` passes.
- Native PhysX vehicle SDK and 240 fixed physics steps. `make check.PhysX` passes.
- Native .NET 8 UBT, ARM64 UnrealHeaderTool, ShaderCompileWorker and the CARLA editor target `CarlaUE4Editor` for arm64. `UE4Editor-Cmd` runs the CARLA project.
- Native Metal 2.3 shader compilation, M1 Pro GPU dispatch and shared-buffer readback. `make check.Metal` passes.
- Native NVIDIA Texture Tools 2.0.8 with squish, and a native SpeedTree core library, rebuilt from the pinned engine sources for arm64.
- **The acceptance test passes**: the native server loads `Carla/Maps/Town02_Opt`, reports version 0.9.16, spawns `vehicle.tesla.model3`, and the native Python client receives ten consecutive camera frames (18 to 27) with a fixed 0.05 s step and non-uniform pixels. The rendered image is in `Build/macos-engine/simulator-frame.png`.

## Current builds

- `bash Util/BuildTools/MacBuildEditor.sh --jobs 6` builds the native editor target from a clean engine checkout, including the third-party libraries and the engine patches.
- `bash Util/BuildTools/MacBuildGame.sh --jobs 6` builds the standalone native CARLA game target, `Unreal/CarlaUE4/Binaries/Mac/CarlaUE4.app`.
- `bash Util/BuildTools/MacRunSimulator.sh` starts the server, waits for the RPC server to answer, runs the acceptance test and stops the server.

## Integration notes

- Reproducible engine patches live in `Util/BuildTools/EnginePatches` and are applied by `MacBuildEditor.sh`. They cover the native editor opt-in, the ARM64 third-party selection, the modern compiler diagnostics, the RTTI decision, the host architecture detection, the case-sensitive file names, the module symbol visibility and the camera readback.
- Mac modules are published with `RTLD_GLOBAL`, because the engine links them with dynamic lookup. The camera readback is locked on the rendering thread, because the UE4.26 Mac RHI has no thread safe staging surface mapping.
- The Intel ISPC texture compressor and the Qualcomm ETC2 converter are x86_64 only, so those texture formats are disabled on arm64. DXT, BC4, BC5 and BC6H come from the natively rebuilt NVIDIA Texture Tools.
- The build keeps every cache, the derived data cache and the shader working directories inside `Build/`. `TMPDIR` is not redirected, because `xcrun` needs the per-user cache directory to find the Metal toolchain.
- The editor and the shader compiler need the window server, so the simulator runs outside the command sandbox.

## Current follow-on

- The `MacNoEditor` cook for `Town02_Opt` succeeds (721 packages, 0 errors, 16 warnings). `MacStageCooked.sh` stages cooked assets, engine content, project config, ICU locale data and the ARM64 game app into `Build/macos-game/stage`.
- The standalone game still does not pass startup: with the staged base directory supplied it aborts during Cocoa application registration, before the engine logs a startup error. LaunchServices `open -a` reports `kLSNoExecutableErr` for the generated app despite its ARM64 Mach-O executable being present. Investigate/fix the app bundle/run mode; do not claim standalone distribution works until the five-sensor smoke test passes from the cooked package.
- The editor-hosted native acceptance remains green. Sensor smoke tests establish payload delivery and frame/timestamp alignment, not analytic accuracy.
- A first uncapped asynchronous 1280x720 RGB sensor throughput run delivered 35.97 frames/s average (1,079 frames in 30.001 s) on this M1 Pro. The captured MP4 plays at 30 fps and the JSON records settings. Treat this as one-camera client-delivery throughput, not engine-internal FPS or a cross-platform comparison.
- Follow-up uncapped tests: one 1920x1080 RGB camera delivered 28.95 frames/s (579 frames in 20.003 s); three simultaneous 1280x720 cameras (RGB, depth, semantic segmentation) each delivered 23.20 frames/s (464 synchronized frames in 20.001 s). The three-sensor helper emitted metrics before a native actor-destruction error during cleanup, so the measurement is usable but teardown is not clean. Results and 1080p video are under `Build/macos-engine/`.

## Remaining productization
- Compare sensor output with analytic references and extend timing/stability runs to larger maps and longer durations.
- Test other Python minors, certify the deployment target on older macOS releases, and add a native macOS CI runner.
