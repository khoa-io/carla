# Native macOS engine audit: CARLA 0.9.16

Audit date: 2026-10-22. This records the source findings, the engine
prerequisites and the platform adaptations of the native port. The native
simulator now runs: the CARLA editor target is built for arm64, serves the CARLA
RPC API, loads a map with the Metal renderer, spawns a vehicle and streams
synchronized RGB, depth, semantic segmentation, LiDAR and radar data to the
native Python client. The cooked distribution and analytic sensor accuracy are
not validated.

## Pinned source

| Component | Revision | Evidence |
| --- | --- | --- |
| CARLA | `0.9.16`, `294096eb1c38eabf246e4f3a9cdab704e33a7f4c` | `CarlaUE4.uproject` associates the project with Unreal 4.26. |
| CARLA Unreal fork | `carla`, inspected at `e9d9e60c85f643e10eeb03f42f61554d18dcb30f` | `Engine/Build/Build.version` identifies 4.26.2. |

The engine revision is a candidate pin discovered from the branch during this
audit, not a claim that the release tag specifies that exact engine commit.
The engine repository is private and requires Epic-authorized GitHub access.
The pinned engine is now checked out under `Build/macos-engine/source`.
Verified Mac/common manifest dependencies are installed. Native ARM64 .NET 8
UnrealBuildTool builds and validates the Mac SDK; native UnrealHeaderTool and
its dylibs link and execute. The native `CarlaUE4Editor` target links, and
`UE4Editor-Cmd` runs the CARLA project in game mode as the CARLA server.

The selected baseline remains UE4.26.2. UE5 Apple Silicon support cannot be
assumed to apply to this branch.

## Engine feasibility and prerequisites

The engine already contains partial Apple Silicon support:

- `MacExports.cs` defines `arm64` and whitelists several runtime/build programs,
  including `UE4Game`, `UE4Server`, `UnrealHeaderTool`, and `UnrealPak`.
- Its default architecture remains `x86_64`.
- `TargetTypesBlacklistedForAppleSilicon` explicitly includes `TargetType.Editor`.
  A native CARLA editor/cooking workflow therefore requires engine work; simply
  adding a Mac platform name to CARLA does not establish that workflow.
- `UEBuildMac.cs` disables ISPC when compiling for ARM and includes MetalRHI
  when an engine target has the required SDK.
- `MacToolChain.cs` forwards the target architecture through Clang's `-arch`
  argument. Its historical deployment target is macOS 10.14. That default is
  not an appropriate claim of Apple Silicon minimum OS support.

The existence of an ARM game target left open a native packaged-runtime route
using content cooked elsewhere. The native editor and game targets are now
built from this fork, so the CARLA server runs natively on the development
host. The content is still the uncooked source content of the release, so no
packaged distribution has been produced yet.

Before an engine build can be called reproducible, the following must be done:

1. Provision the pinned fork and dependencies on storage sized for both engine
   builds and CARLA content. CARLA's Linux guide budgets approximately 130 GB;
   this is not a measured Mac requirement. The machine had approximately
   133 GiB free at initial inspection, leaving little room for exploratory
   engine rebuilds and intermediate files.
2. Validate the complete Xcode/macOS SDK path for this old engine. Xcode 27.1
   builds native UBT/UHT with the checked-in compatibility patches; a standalone
   Metal shader/GPU/readback fixture passes. A complete editor/CARLA build and
   Unreal shader compilation remain outstanding.
3. Resolve the engine's Apple Silicon editor restriction and its actual
   underlying module/dependency failures, or explicitly select a packaged game
   workflow with externally cooked content. Removing a blacklist entry alone
   is not a validated engine port.
4. Inspect every linked Mac third-party archive/dylib using `lipo -archs` and
   every executable using `file`. PhysX and TBB have native ARM64 slices. The
   bundled FBX SDK is Intel-only; the experimental editor uses Autodesk's
   universal 2020.3.9 SDK through `CARLA_MACOS_FBX_SDK`. Its ARM64 dylib targets
   macOS 11 and links system libraries. Remaining dependencies are audited as
   their modules enter the build.
5. Build a minimal native UE game with physics and Metal, then build CARLA with
   native server libraries and version-matched content. Verify the packaged
   executable and all loaded dylibs are ARM64.

### Physics and native libraries

CARLA's module requires `PhysX`, `PhysXVehicles`, and `PhysXVehicleLib`.
LiDAR/radar directly access PhysX scenes; substituting Chaos would require
additional sensor and vehicle work.

The engine's `PhysX.Build.cs` Mac path expects static libraries under
`Engine/Source/ThirdParty/PhysX3/Lib/Mac/`, including LowLevel, LowLevelCloth,
PhysX3Extensions, SceneQuery, SimulationController, PxTask, and PsFastXml.
It stages PhysX3, PhysX3Cooking, PhysX3Common, PxFoundation, and PxPvdSDK dylibs
from `Engine/Binaries/ThirdParty/PhysX3/Mac/`. Configuration suffixes such as
`PROFILE` affect the filenames. The eight required static and five dynamic
profile libraries contain ARM64 slices. `make check.PhysX` initializes the
vehicle SDK and runs 240 native physics steps successfully. Other enabled
engine modules still require an equivalent architecture audit.

CARLA's experimental Mac module rule now expects static `rpc`, `carla_server`,
`sqlite3`, `xerces-c`, `proj`, and `osm2odr` libraries under
`Unreal/CarlaUE4/Plugins/Carla/CarlaDependencies/lib/`, using `libNAME.a` names.
It links SDK zlib rather than Linux's hardcoded libc and SQLite shared object.
`MacBuildServer.sh` now produces these native no-exceptions libraries and matching
headers. `make check.LibCarla.server` links and executes OSM conversion and
LibCarla OpenDRIVE parsing. This proves the standalone server dependency link,
not a CARLA Unreal world or sensor pipeline. Missing libraries generate an
explicit error before linking.

The server dependency producer must also stage the matching Boost/rpclib headers
and CARLA headers. Recast/Detour and the RecastBuilder asset navigation tool
require native builds where used; an engine physics build does not provide
CARLA's client/navigation dependencies. Optional CarSim, Chrono, Pytorch, ROS 2,
and SimReady integrations require separate native dependency ports and are
explicitly rejected by the experimental Mac rules when enabled.

## Rendering and sensor audit

CARLA uses the engine RHI rather than directly requiring Vulkan or DirectX for
all sensors. Metal support in the engine is a prerequisite, not proof that
CARLA's capture path is correct.

| Sensor/path | Source finding | Required runtime validation |
| --- | --- | --- |
| RGB and camera streaming | `PixelReader.cpp` uses `FRHIGPUTextureReadback`, a blocking absolute-time query described as a Vulkan fence workaround, and an asynchronous task that waits for the readback fence. | Establish Metal query/fence progress, correct thread use, teardown safety, and frame delivery without hanging. |
| Pixel layout | `PixelReader.h` assumes tightly packed rows on non-Windows platforms; only D3D has explicit row padding removal. The engine Metal staging mapping calls `Surface->Lock` and exposes texture width while internally obtaining a stride. | Check actual CPU row stride and pixel channel order on Metal; include image widths such as 641 and 801 that reveal alignment assumptions. Do not infer packing from the requested image width. |
| Depth | `DepthCamera.cpp` chooses a GLSL material only on Linux and the other depth material elsewhere. | Compile and compare both relevant material behavior on Metal using planes at known distances; do not change a platform macro without pixel evidence. |
| Semantic/instance segmentation | Camera capture and tagging/postprocessing share the rendering/readback path. | Compare known labeled objects, background labels, stencil/material output, and exact per-pixel codes before color conversion. |
| GBuffer streams | `SceneCaptureSensor.h` includes the fork's `Renderer/Public/GBufferView.h` and uses custom GBuffer requests/readbacks. | Preserve the CARLA engine fork patches, compile Metal shader permutations, and validate formats individually. A stock UE4.26 install is insufficient evidence. |
| Exposure | `SceneCaptureSensor.cpp` applies an exposure compensation offset only on Linux. | Establish a Mac reference image; do not copy the Linux offset without measurements. |
| LiDAR/semantic LiDAR | `RayCastSemanticLidar.cpp` locks the PhysX scene and uses the fork's `ParallelLineTraceSingleByChannel`; regular LiDAR builds on the raycast path. | Validate native PhysX builds, geometry hits, counts, ranges, semantic IDs, and deterministic replay. This path does not require hardware ray tracing. |
| Radar | `Radar.cpp` uses PhysX scene locking and parallel line traces, then computes velocity/detection data. | Validate range, azimuth/elevation, velocity units/sign, and concurrent scene access. |
| Timing | `PixelReader.h` captures frame number, elapsed time, and transform before the asynchronous send. | Confirm each camera frame matches its simulation tick and joins the other sensor frames by frame number. Do not assume callback arrival order implies frame order. |

Runtime validation now confirms the readback and synchronization paths operate on
the development Mac. The smoke test checks six consecutive frames at a fixed
0.05-second step across RGB, depth, semantic segmentation, LiDAR and radar. It
does not yet compare sensor measurements against analytic reference scenes or
establish performance and long-run stability.

## First server acceptance gate

After the engine and native server dependencies are available, load a minimal
map, spawn one vehicle, enable synchronous mode with a fixed timestep, and attach
an RGB camera through the native Python client. Record executable/library
architectures, engine and CARLA revisions, SDK versions, camera dimensions,
tick/frame IDs, timestamps, image hashes, and errors. Verify dimensions, payload
length, nonempty image content, correct orientation/channel order, and bounded
completion. Repeat with an unaligned image width before extending the gate to
depth, segmentation, LiDAR, and radar. Restore the world's original settings
and destroy actors on both success and failure.

## Pinned engine source references

These links require access to CARLA's Unreal fork:

- [Engine version](https://github.com/CarlaUnreal/UnrealEngine/blob/e9d9e60c85f643e10eeb03f42f61554d18dcb30f/Engine/Build/Build.version)
- [Mac architecture defaults and editor restriction](https://github.com/CarlaUnreal/UnrealEngine/blob/e9d9e60c85f643e10eeb03f42f61554d18dcb30f/Engine/Source/Programs/UnrealBuildTool/Platform/Mac/MacExports.cs)
- [Mac platform configuration](https://github.com/CarlaUnreal/UnrealEngine/blob/e9d9e60c85f643e10eeb03f42f61554d18dcb30f/Engine/Source/Programs/UnrealBuildTool/Platform/Mac/UEBuildMac.cs)
- [Mac Clang toolchain](https://github.com/CarlaUnreal/UnrealEngine/blob/e9d9e60c85f643e10eeb03f42f61554d18dcb30f/Engine/Source/Programs/UnrealBuildTool/Platform/Mac/MacToolChain.cs)
- [PhysX platform libraries](https://github.com/CarlaUnreal/UnrealEngine/blob/e9d9e60c85f643e10eeb03f42f61554d18dcb30f/Engine/Source/ThirdParty/PhysX3/PhysX.Build.cs)
- [Metal staging mapping](https://github.com/CarlaUnreal/UnrealEngine/blob/e9d9e60c85f643e10eeb03f42f61554d18dcb30f/Engine/Source/Runtime/Apple/MetalRHI/Private/MetalRenderTarget.cpp)
- [GPU readback API](https://github.com/CarlaUnreal/UnrealEngine/blob/e9d9e60c85f643e10eeb03f42f61554d18dcb30f/Engine/Source/Runtime/RHI/Public/RHIGPUReadback.h)
