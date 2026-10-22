# Progress

## Established

- Existing source clone completed without interruption.
- User's 0.9.16 release baseline resolved locally.
- Memory bank initialized.
- Native client/dependency bootstrap completed, including a clean build and final incremental rebuild of all affected source.
- Native CPython 3.11 ARM64 wheel built and installed into a clean environment; import outside the checkout passed.
- All 14 existing transform/vehicle unit tests passed. Native C++ buffer/variant serialization, loopback version RPC, and delayed-response timeout fixture passed.
- Installed extension has ARM64 Mach-O architecture, macOS 12.0 minimum metadata, and only system dynamic libraries.
- The native ARM64 simulator runs: the CARLA editor build in game mode serves the CARLA RPC API, loads a map with the Metal renderer, spawns vehicles and streams the camera sensors.
- The native Python acceptance test passes end to end against that server, including the frame synchronisation and the fixed simulation step.
- The native engine third-party libraries that blocked the link were rebuilt for arm64 from the pinned engine sources: NVIDIA Texture Tools 2.0.8 with squish, and the SpeedTree core library.
- The Intel ISPC texture compressor and the Qualcomm ETC2 converter have no arm64 build, so the corresponding texture formats are disabled on native Apple Silicon.

## In progress

- A `MacNoEditor` cook of `Town02_Opt` succeeds, and a runtime staging helper assembles cooked project/engine content, ICU locale data, config and the ARM64 game app.
- The standalone app aborts during Cocoa application registration before engine startup. `open -a` reports `kLSNoExecutableErr` although the bundle contains its executable; the staged standalone server gate remains open.
- Compare sensor output with analytic references and extend timing/stability runs to larger maps and longer durations.

## Implemented

- Darwin Makefile dispatch and workspace-local dependency/client bootstrap.
- Darwin Python extension configuration and optional OSM converter selection.
- Explicit native Mac server dependency paths and unsupported-integration diagnostics.
- Revised release-specific plan, build instructions, and pinned engine audit.

## Engine findings

- Read-only authenticated access to the required engine fork works.
- Inspected `carla` branch commit `e9d9e60c85f643e10eeb03f42f61554d18dcb30f` reports UE4.26.2. It contains partial native ARM64 support, but explicitly blacklists Mac Editor targets. Candidate engine compatibility with the release is not yet validated.
- No engine checkout, native PhysX/server dependency build, matching cooked Mac content, simulator launch, or Metal sensor test is available yet.

## Not validated

- The depth, segmentation, LiDAR and radar sensors, the cooked and packaged distribution, a clean second-machine install, Linux/Windows builds, and the certification of the deployment target on older macOS versions.

## Log

### 2026-10-22

- Waited for user's `gh repo clone` process to finish; repository pack reached roughly 2.5 GiB.
- Selected tag 0.9.16 after the user superseded the UE5 proposal.
- Started detached checkout; sandbox initially denied `.git/index.lock`, then escalated the authorized checkout.
- Initialized persistent project context and TASK001 while checkout completes.
- Completed checkout. Spawned three agents for client, Python, and Unreal work; reviewed their changes and initiated native builds.
- Provisioned native Python 3.11.17, isolated build/runtime environments, and build/test Python packages under Build/macos.
- Built native rpclib and Recast/Detour. Built a local libpng targeting macOS 12 to avoid the host Homebrew library's macOS 27 minimum.
- Added source checksums and configuration fingerprints to dependency bootstrap; independent review requested explicit ARM64 packaging and fresh extension compilation.
- Replaced the earlier UE5 plan with a 0.9.16/UE4.26 plan and documented the engine/server prerequisites.
- Fixed actual Darwin LP64 issues in Buffer, MessagePack index sequences, and waypoint hash seed types. Preserved existing Buffer uint32/uint64 overload signatures and checked narrowing.
- Completed native dependency/client builds; verified architecture/deployment metadata and rejection of incompatible cached deployment targets.
- Built and installed `carla-0.9.16-cp311-cp311-macosx_12_0_arm64.whl` in a clean local environment. Confirmed import/version from `/private/tmp`, correct wheel tags, and no Homebrew/MacPorts/build-tree dylib dependencies.
- Passed 11 transform tests and 3 vehicle tests; passed the shipped native C++ serialization/RPC/timeout fixture through the integrated Make recipe.
- Recorded exact artifact checksum, validation commands, logs, and unresolved engine work in validation.md. Full TASK001 remains In Progress.
- Continued autonomously after explicit user direction. Started scoped engine source provisioning and actual native server/UBT/PhysX implementation in three parallel agent workstreams.
- Built and tested native no-exceptions LibCarla server/OSM dependencies and native PhysX vehicle SDK/240-step simulation. Integrated both smoke tests as Make targets and reran successfully.
- Provisioned pinned engine and verified manifest dependencies. Bootstrapped native .NET 8, patched legacy build-tool runtime/process differences and modern Clang compatibility without changing simulator version.
- Built ARM64 UnrealHeaderTool and dylibs, generated metadata, and successfully generated the editor's reflection code. Restored missing Engine/Programs configuration from the sparse checkout. Native editor compilation is underway with six jobs and no debug symbols.
- Native Metal compile/GPU/readback fixture passes through Make. Installed the missing Xcode Metal component and refreshed xcrun cache. Replaced Intel-only FBX selection with a universal SDK override and built native HLSLCC from pinned source. Direct CARLA editor reflection passes; engine/editor compilation and source-content download continue.
- Built and staged remaining native mesh/FFT/shader dependencies, including Unreal's patched MCPP API and ShaderConductor/DXC. Native HLSL-to-SPIR-V-to-Metal conversion and Apple's generated shader compilation/linking pass. Corrected Mac system includes and the nil macro conflict; client SDK regression passes.
- The pinned engine forcibly disabled RTTI on Mac despite CARLA requiring non-UObject actor-data dynamic_cast. Removed that override to honor the existing target setting, preserving simulator semantics; affected native engine objects are recompiling. Source assets finished downloading and are being inventoried for safe installation. Full simulator acceptance is still pending.
- Resolved the remaining link blockers: the ARM64 NVIDIA Texture Tools and squish were rebuilt from the pinned sources, the SpeedTree core library was rebuilt for arm64, the Intel ISPC texture compressor and the Qualcomm ETC2 converter were disabled on arm64, and HLSLCC was rebuilt with RTTI so that the vector math test and the module symbol references resolve.
- Made the native build self contained: the compiler, package and tool caches are redirected into `Build/`, the Unreal header tool selects the host architecture without `sysctl`, and the PhysX file name aliases for the case-sensitive volume are created by the build.
- Fixed the native start up: the engine no longer aborts on a case-sensitive volume, the module symbols are published globally, the camera readback is locked on the rendering thread, and the degenerate triangles of the reduced meshes no longer abort the editor.
- The native acceptance test passed: the server reported 0.9.16 on `Carla/Maps/Town02_Opt`, the client spawned `vehicle.tesla.model3`, and ten consecutive RGB frames arrived with matching frame numbers and a fixed 0.05 s step. The rendered image is `Build/macos-engine/simulator-frame.png`.
- Final prototype gate passed on 2026-10-22. The ARM64 editor server ran CARLA 0.9.16 on `Town02_Opt`, spawned a Tesla Model 3, and delivered six consecutive synchronized frames from RGB, depth, semantic segmentation, LiDAR and radar at 0.05-second intervals through the native ARM64 Python wheel. The test uses 321x241 camera images and verifies nonuniform pixels, LiDAR points, radar detections, matching frame numbers and matching timestamps. The rendered image is `Build/macos-engine/simulator-all-sensors-rgb.png`; SHA-256 `25f10b2c05bde26f7f2ecd36d64dbae8b755e75a9057e9d55d7eb174eb6442b2`.
- `MacRunSimulator.sh` accepts `--sensors` and resolves relative output paths before changing to the project directory. The combined five-sensor run passed after this path fix.
- Marked TASK001 complete for the native prototype scope. Standalone cooked packaging, analytic sensor accuracy, longer stability testing, older macOS certification, additional Python versions, and CI remain productization work.
- Cooked `Town02_Opt` for `MacNoEditor` (721 packages; 0 errors, 16 warnings), and staged a standalone runtime with engine ICU data. The first standalone launch exposed an app-bundle/Cocoa registration failure; it is not yet a successful cooked distribution. The editor-hosted five-sensor prototype remains validated.
- Captured a first uncapped asynchronous 1280x720 RGB-camera run on the native server: 1,079 client-delivered frames in 30.001 seconds (35.97 FPS average; 27.147 ms median interval). The 30 fps playback MP4 and structured metadata are saved under `Build/macos-engine`; this is a single-camera throughput metric, not engine `stat fps` or a platform comparison.
- Captured a second performance clip at 1920x1080. One async RGB camera delivered 579 frames in 20.003 s (28.95 client-delivered frames/s); the video is 20 s at 30 fps. Details: `Build/macos-engine/carla-macos-fps-1080p-results.json`.
- Measured three simultaneous 1280x720 cameras (RGB, depth, semantic segmentation): each delivered 464 matching frames in 20.001 s (23.20 frames/s). The helper printed results but then exited with a native CARLA actor-destruction error during cleanup; follow up on cleanup separately. Details: `Build/macos-engine/carla-macos-fps-sensor-load-results.json`.
