# Native macOS port: CARLA 0.9.16

Updated 2026-10-22. The user's explicit **0.9.16** baseline supersedes the earlier UE5 proposal.

## Baseline and success criteria

- CARLA tag `0.9.16`: `294096eb1c38eabf246e4f3a9cdab704e33a7f4c`.
- Unreal Engine 4.26; inspected candidate fork commit `e9d9e60c85f643e10eeb03f42f61554d18dcb30f` reports 4.26.2. Exact release-to-engine compatibility still needs build/runtime proof.
- Native ARM64 macOS; Metal via Unreal's existing rendering abstraction; compatible native dependencies and Python extension.
- Preserve existing simulation, RPC, sensor encoding, coordinate, and simulation-time semantics.
- First client milestone: compile/insta   ll native LibCarla and a wheel; prove import, core API behavior, architecture, linkage, and RPC.
- First simulator milestone: native package loads a minimal map, spawns one vehicle, and delivers synchronized RGB frames to the native Python client.

Working instructions: [Docs/build_macos.md](Docs/build_macos.md). Engine findings and pinned evidence: [Docs/macos_engine_audit.md](Docs/macos_engine_audit.md). Persistent task history: [memory-bank/index.md](memory-bank/index.md).

Current result: the native client and simulator prototype milestones passed on the development Mac. The CPython 3.11 wheel passed with a clean import, 14 existing unit tests, architecture/linkage inspection and a C++ serialization/RPC/timeout fixture. The arm64 `CarlaUE4Editor` target runs the CARLA project in game mode as the server, loads `Carla/Maps/Town02_Opt` with Metal, and spawns `vehicle.tesla.model3`. Six consecutive synchronized frames passed for RGB, depth, semantic segmentation, LiDAR and radar at a fixed 0.05 s step. Camera dimensions were 321x241. The standalone game target is built, while cooking, packaging and analytic sensor accuracy remain open. See [the validation record](memory-bank/validation.md) for the exact command and artifacts.

## Workstreams and evidence gates

| Workstream | Scope | Completion evidence |
| --- | --- | --- |
| Baseline | Wait for existing clone, pin release, inspect instructions/tools | Completed checkout and environment manifest |
| Native dependencies | Boost/rpclib/Recast/libpng, ARM64, libc++, consistent deployment target | Pinned archives, successful builds, architecture/minimum OS inspection |
| LibCarla client | Independent build without Unreal; stage headers/archives | ARM64 archive and executable client/link/RPC checks |
| Python | Darwin bindings/linking, ABI-specific wheel, native installation | Clean-environment import, existing relevant unit tests, linkage inspection |
| Engine | Native UE4.26 target tools, PhysX and other dependencies | Minimal native engine game; documented editor/cooker decision |
| Simulator | Server archives, Mac module/link rules, minimal content | Native CARLA process and packaged startup: the native server runs and answers the RPC API |
| Metal/sensors | Camera format/readback, depth/labels, raycast sensors, timing | Five core sensor streams pass synchronous frame/timestamp matching; analytic accuracy and long-run stability remain open |
| Distribution | CI, clean machine, signing, docs, hardware coverage | Repeatable build/install and stability/performance evidence |

## Build foundation

Use the release's classic Makefile/LibCarla CMake structure; do not apply UE5 root CMake instructions. Darwin dispatch selects a dedicated client helper; Linux and Windows retain their existing procedures. Source-build the dependencies needed for a core client and isolate build products under `Build/`.

Pin source archives/checksums. Record compiler/SDK/interpreter versions and deployment target. Inspect static archives as well as the final extension: host Homebrew libpng was compiled for macOS 27 and cannot be linked into a wheel advertised as macOS 12/15 compatible. Build a local libpng instead.

The initial helper targets macOS 12 at the compiler/linker level. Actual runtime validation is initially on the development host; lower OS certification requires separate machines. The earlier proposed macOS 15 support floor remains a product decision, not a measured requirement.

Provide core client bindings first. Optional OSM conversion, JPEG/TIFF output, RSS, native ROS 2, CUDA/PyTorch, Chrono, CarSim, and SimReady need separate dependency work. Keep unsupported configurations explicit.

## UE4.26 engine decision

The inspected fork contains partial ARM64 support but defaults to x86_64 and explicitly blacklists Mac `Editor` targets. Removing that entry is insufficient: native build tools, shader compilation, PhysX/vehicle libraries, other engine dependencies, and cooker/editor modules must actually build and run.

Evaluate two routes against the native product requirement:

1. Fully native editor/cooking/toolchain: resolve engine module restrictions and rebuild every missing ARM64 dependency. This is the route to a complete native development workflow.
2. Native packaged game with version-matched content cooked elsewhere: useful as an intermediate runtime milestone. It still requires native runtime dependencies and is not a fully native editor/cooker solution.

Do not silently upgrade the engine or rely on Rosetta/Wine. Engine access has been verified; no engine/content download has occurred. Measure disk/memory requirements before provisioning engine builds. Workspace free space was approximately 133 GiB at initial inspection, so a full speculative engine/content download needs an explicit capacity plan.

## Simulator acceptance experiments

Start with one vehicle and one 640x480 RGB camera on a minimal map, basic lighting, fixed weather, one tick owner, `fixed_delta_seconds=0.05`, and `sensor_tick=0.0`. Align physics substeps. Warm up, then request at least 1,000 ticks, joining packets to snapshots by frame ID and simulation timestamp with bounded queues/timeouts. Allow GPU delivery latency and drain pending frames before declaring loss.

Require correct payload lengths, orientation/channel order, meaningful image changes, no missing/duplicate expected frames in the controlled experiment, and clean teardown/restart. Repeat with an unaligned image width to reveal row-stride bugs. Report elapsed wall time separately from simulation timestep; no FPS promise follows from a fixed timestep.

Then validate:

- Depth against known geometric distances and documented decoding.
- Semantic/instance labels against known objects, exact codes away from boundaries, and actor lifecycle.
- LiDAR against geometry, count/range/coordinate conventions, timing, and configured noise/dropout behavior.
- Radar against static/moving targets and radial velocity units/sign.
- IMU/GNSS and optional optical flow against controlled trajectories/motion.
- Multi-sensor timing, map reload, client reconnect, shutdown with pending readbacks, memory growth, and long runs.

Define tolerances before running comparisons. Do not demand bitwise physics determinism across architectures or identical RGB pixels across GPUs. A client-only test or NullRHI run does not establish camera correctness.

## Integration, review, and ownership

Land reviewable changes in order: dependency/client portability; Python wheel; engine/server platform support; reproduced Metal/sensor fixes; then GPU CI and release packaging. Add focused validation alongside each change. Maintain a record of engine patches separate from CARLA patches.

Use native ARM64 build CI for client/wheel checks and controlled Apple hardware for Metal/runtime tests. Prove unattended rendering/session behavior. Protect licensed engine access and signing credentials. Verify clean-machine install, runtime library paths, asset discovery, shutdown, and only the advertised OS/hardware matrix.

Maintainer acceptance and ongoing CI ownership remain external requirements for official support. Drafting this plan or changing local source does not authorize posting messages or publishing PRs.

## Schedule and next decisions

The earlier 24-week/two-engineer proposal was based on UE5 and is not a validated estimate for UE4.26 ARM64. Re-estimate after native client/wheel proof and the engine dependency audit. The critical uncertainty is now the older engine's native toolchain and physics/editor dependencies.

Continue executable client progress while investigating engine prerequisites. Keep task status truthful: source adapters and diagnostics are preparatory changes; simulator support requires actual engine/server/sensor validation. Record current build results and remaining gates in the memory bank rather than marking the full port complete.
