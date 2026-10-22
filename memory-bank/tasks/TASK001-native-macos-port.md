# TASK001 - Native CARLA 0.9.16 macOS port

**Status:** Complete (native prototype)
**Added:** 2026-10-22
**Updated:** 2026-10-22

## Original request

> I'm cloning CARLA's source code (execute `nu -c "ps | where name == 'gh'"` to see the pid). Wait for it to be done, then start. Work autonomously. Make good decisions. I'll review the final result. Spawn subagents do to tasks.
> [$memory-bank](/Users/p2p/.agents/skills/memory-bank/SKILL.md) Create a memory bank for this project so that progress and technical context can be tracked.

> Base version to start from is `0.9.16`

> [$memory-bank](/Users/p2p/.agents/skills/memory-bank/SKILL.md) Don't forget to initialize and use memory bank

> Continue to work autonomously until the porting is a success. Make good decisions. I'll review the final once it's done.

## Approach and decisions

Preserve the user's existing clone and wait for it to finish. Switch to the explicitly selected release, then separate the client, Python packaging, and Unreal/Metal investigations among agents. Use native client validation as the first executable milestone while investigating the older engine's ARM64 support. The earlier UE5 proposal is superseded; upgrading engines silently would violate the selected baseline. Compatibility layers do not satisfy native acceptance criteria.

## Implementation plan

1. Complete release checkout, instructions audit, and environment/dependency baseline.
2. Delegate distinct build, Python, and Unreal portability areas.
3. Implement and validate a native client/dependency path and Python packaging.
4. Establish engine prerequisites and implement justified Mac platform adaptations.
5. Run available checks; document exact successes, failures, remaining gates, and reproducible commands.
6. Update the technical plan and all relevant memory-bank files for handoff.

## Progress tracking

**Overall Status:** Complete - native prototype acceptance passed; standalone distribution is a separate follow-on and remains in progress

| ID | Description | Status | Updated | Notes |
| --- | --- | --- | --- | --- |
| 1.1 | Wait for existing clone | Complete | 2026-10-22 | gh exited; valid HEAD established |
| 1.2 | Initialize memory bank | Complete | 2026-10-22 | Core files and task index created |
| 1.3 | Check out 0.9.16 and audit instructions | Complete | 2026-10-22 | Stable tag checkout; no AGENTS.md at release |
| 1.4 | Delegate and audit native build/Python/Unreal | Complete | 2026-10-22 | Three agents implemented/reviewed separate scopes |
| 1.5 | Implement and validate native client/Python | Complete | 2026-10-22 | Native wheel clean import; 14 unit tests; C++ serialization/RPC/timeout passed |
| 1.6 | Native engine/server and sensors | Complete | 2026-10-22 | Native editor and server run; RGB, depth, semantic, LiDAR and radar delivered on matching frames and timestamps |
| 1.7 | Review, documentation, handoff | Complete | 2026-10-22 | Reproducible helpers and evidence updated; standalone cooking/package and analytic sensor accuracy remain productization work |
| 1.8 | Cook and stage standalone runtime | In progress | 2026-10-22 | Town02_Opt cook succeeds; staged game currently aborts in Cocoa application registration before engine startup |

## Progress log

### 2026-10-22

- Confirmed clone PID 98047 and waited until it exited.
- Clone defaulted to UE58; selected tag 0.9.16 at `294096eb1c38eabf246e4f3a9cdab704e33a7f4c` instead.
- Read current-branch instructions and UE4 build skill; its Linux-only procedure is context, not a native Mac solution.
- Started authorized detached checkout with sandbox escalation after metadata write denial.
- Recorded modern host tools and limited free storage; initialized the memory bank before source changes.
- Completed release checkout and delegated client, Python, and Unreal audits/implementation.
- Provisioned isolated native Python 3.11.17 and started installing build/test packages.
- Verified private engine repository access without downloading it. Agent inspected branch `carla` at `e9d9e60c85f643e10eeb03f42f61554d18dcb30f`, reporting UE4.26.2 and an explicit native Mac editor blacklist.
- Found Homebrew libpng static objects require macOS 27; requested a pinned source build to avoid inaccurate wheel minimum OS tags.
- Added Darwin Makefile dispatch with explicit diagnostics for unvalidated simulator targets.
- Built/checksummed source dependencies and compiled all native LibCarla client units. Darwin size_t differs from uint64_t; fixed Buffer overload resolution with API-preserving integral forwarding, MessagePack index sequence types, and waypoint hash seed type.
- Hardened dependency caching, partial downloads, native architecture/minimum OS checks, and SDK-only zlib selection. Verified changed deployment target rejects cached binaries.
- Built CPython 3.11 native ARM64 wheel, installed into a clean environment and imported from outside the checkout. Confirmed wheel tag, Mach-O ARM64/minimum12 metadata, and only system dylib linkage.
- Passed existing 11 transform + 3 vehicle tests and native C++ buffer/variant/RPC/timeout fixture. Parent independently executed the Make fixture recipe.
- Retained unvalidated engine/server/sensor work as In Progress, not Completed. An externally cooked native runtime route is possible in principle but requires Mac-target cooked content and native engine/PhysX/server libraries; existing Windows/Linux release content is insufficient.
- Updated the plan, README, build instructions, engine audit, and memory bank for review. No branches, commits, upstream publications, engine clone or content downloads performed.
- User requested continuation through port success. Started shallow filtered private engine clone into Build/macos-engine/source; reactivated three agents for actual server dependency compilation, native build-tool bootstrap, and PhysX/runtime compilation. Engine provisioning changes the earlier no-engine-download checkpoint; previous client validation remains unchanged.
- Native server dependency and PhysX smoke tests pass through Make targets. Native .NET 8 UBT validates the SDK; ARM64 UHT links, writes metadata, executes, and generates UE4Editor reflection code. Added reproducible engine patches and a checksum-verified manifest fetcher with six passing tests. Editor compilation is underway; full CARLA/Metal/sensor acceptance remains pending.
- Native Metal shader/GPU/readback and SDK-macro client regression tests pass. Built native engine mesh, FFT and shader preprocessing/cross-compilation dependencies, preserving Intel originals. Native ShaderConductor/DXC (1,209 actions) and its ARM64 LLVM generators pass HLSL-to-SPIR-V-to-Metal conversion and Apple's generated shader compilation/linking.
- Fixed system-header classification, MacTypes nil alias conflict, case-sensitive Metal includes and modern compiler compatibility. Removed the pinned fork's Mac RTTI override rather than changing CARLA actor-data casts; matching target settings now require another affected engine rebuild. Editor/CARLA compilation is progressing, not yet a simulator success.
- Completed the exact 0.9.16 source-content archive download (21,567,002,106 bytes). Integrity/path/expanded-size inventory is running before choosing a disk-safe extraction. Vehicle/RGB synchronized-frame fixture is implemented and syntax/import tested only; actual simulator acceptance remains pending.
- Cleared the remaining link blockers: NVIDIA Texture Tools 2.0.8 with squish and the SpeedTree core library were rebuilt for arm64 from the pinned engine sources, HLSLCC was rebuilt with RTTI, and the Intel ISPC texture compressor and the Qualcomm ETC2 converter were disabled on arm64 because they only exist as x86_64 binaries.
- Made the build self contained: the compiler and tool caches are redirected into `Build/`, the Unreal header tool detects the host architecture without `sysctl`, and the build creates the PhysX file name aliases that the case-sensitive volume needs. All 27 engine patches apply to the pristine engine sources.
- Fixed the native start up: the engine no longer aborts on a case-sensitive volume, the Mac loader publishes the module symbols globally because the engine links them with dynamic lookup, the camera readback is locked on the rendering thread because the UE4.26 Mac RHI has no thread safe staging surface mapping, and the degenerate triangles of the reduced meshes no longer abort the editor.
- The native acceptance test passed twice. The server reported 0.9.16 on `Carla/Maps/Town02_Opt`, the native client spawned `vehicle.tesla.model3`, and ten consecutive RGB frames arrived with consecutive world frame numbers and a fixed 0.05 s step; the rendered image is `Build/macos-engine/simulator-frame.png`. The helper `MacRunSimulator.sh` reproduces the whole run.
- The standalone native game target `CarlaUE4.app` is built and links for arm64. It expects the packaged content layout, so cooking the content for macOS is the remaining step before it can run on its own.
- The native server smoke test passes with RGB, depth, semantic segmentation, LiDAR and radar enabled together. Six consecutive frames match the simulation frame IDs and fixed 0.05 s timestamps; cameras are 321x241, LiDAR returns points, and radar returns detections. The rendered image is `Build/macos-engine/simulator-all-sensors-rgb.png`.
- The native prototype acceptance is complete. A standalone cooked distribution, analytic sensor references, longer multi-map stability runs, older macOS certification, other Python versions and CI remain outside the validated prototype gate.
- Cooked `Town02_Opt` for `MacNoEditor` (721 packages; 0 errors, 16 warnings) and added staging of engine/project content, ICU locale files, config and the ARM64 game bundle. Standalone startup remains unresolved: launch through the test helper aborts in Cocoa application registration; LaunchServices cannot resolve the app executable. The editor-hosted acceptance remains the validated deliverable.
