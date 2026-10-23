# TASK002 - Improve native macOS camera delivery toward sustained 60 FPS

**Status:** In Progress
**Priority:** High
**Added:** 2026-10-22
**Updated:** 2026-10-22
**Depends on:** [TASK001](TASK001-native-macos-port.md), native prototype complete

## Original request

> Create task and sub tasks in memory bank

Context: record the completed mixed-model source review and the proposed work to improve native CARLA 0.9.16 camera delivery toward 60 FPS with retained sensor fidelity.

## Scope and current authorization

- Target workload: one 1280x720 RGB camera on the M1 Pro (10 CPU cores, 16 GPU cores, 32 GB RAM), retaining resolution, pixel format, rendering quality and sensor/network semantics.
- Additional diagnostic workloads: no camera, one 1920x1080 RGB camera, and three 1280x720 RGB/depth/semantic cameras.
- Review checkpoint: `d2736bbdbc00af9d8ea91ba4adec1b8aee49ac53`, "Add native macOS support for CARLA 0.9.16". Release baseline: `0.9.16` at `294096eb1c38eabf246e4f3a9cdab704e33a7f4c`. Engine: patched native ARM64 UE4.26.2 at `Build/macos-engine/source`, pinned to `e9d9e60c85f643e10eeb03f42f61554d18dcb30f`.
- The earlier read-only review is complete. The user's subsequent **"Proceed TASK002"** authorizes implementation, rebuilds, owned simulator runs and the measurements/validation described here. No commit or publication has been requested.
- Standalone Cocoa/LaunchServices startup remains a separate packaging issue in TASK001. Use the validated editor executable in game mode when defining the initial performance workload.

## Evidence and reasoning

The independent review used GPT-6 Astra for architecture/Metal, GPT-6.1 Sol for implementation/sensor correctness and GPT-6 Luna for benchmarking. All three models were available and exchanged critiques. Findings are from source inspection unless explicitly described as prior runtime measurements.

### Prior runtime measurements

| Workload | Python callbacks | Elapsed wall time | Average delivery | Qualification |
| --- | ---: | ---: | ---: | --- |
| One 1280x720 RGB camera | 1,079 | 30.001 s | 35.97 FPS | VideoToolbox encoding and selected raw-image copies active |
| One 1920x1080 RGB camera | 579 | 20.003 s | 28.95 FPS | Same encoding confound |
| Three 1280x720 RGB/depth/semantic cameras | 464 per camera | 20.001 s | 23.20 FPS each | No encoding; helper has counter-boundary races and aborts during teardown |

- Conditions: `UE4Editor-Cmd` in game mode, `Town02_Opt`, Metal, VSync disabled, asynchronous simulation, autopilot Tesla Model 3. The runs do not establish a hardware ceiling or Unreal's independent render FPS.
- Local scripts/results: `Build/macos-engine/capture_fps.py`, `capture_sensor_load.py`, `carla-macos-fps-results.json`, `carla-macos-fps-1080p-results.json`, and `carla-macos-fps-sensor-load-results.json`. These artifacts are ignored by Git and are not reproduced by checking out the checkpoint alone.
- Callback counts are independent of the 30 FPS video writer; playback FPS is not a camera cap. Encoding, image copies and lock contention add unmeasured work.
- Saved counts and endpoint frame IDs are consistent with the reported consecutive/aligned delivery. Neither helper preserves all IDs, so the artifacts do not independently prove interior continuity or cross-camera alignment. The multi-camera helper resets outside callback locks and snapshots after the elapsed-time endpoint.
- Two uncontrolled resolution points cannot establish a fixed-plus-pixel cost model, a 22 ms fixed cost, or a roughly 45 FPS ceiling.

### Source findings to preserve

| Finding | Source lead | Consequence |
| --- | --- | --- |
| An unconditional Vulkan-workaround block ends an absolute-time query, flushes RHI work and retrieves the query with `bWait=true`. Metal emulates the query using command-buffer completion. | CARLA `Sensor/PixelReader.cpp:46-55`; engine `MetalRHIRenderQuery.cpp:279-309,332-352` | Proven synchronization boundary; its wall-clock cost is unknown. `FlushRHIThread` alone must not be described as a GPU completion wait. |
| Worker task busy-yields for readiness, then schedules map and the entire payload callback on the render thread. | `PixelReader.cpp:62-85`; `PixelReader.h:121-205` | Conversion, pooled CPU copy, serialization and stream submission still occupy the render thread. |
| The apparent final render-thread wait is a no-op because its flush is commented out. | `SceneCaptureSensor.h:399-403` | Do not diagnose a per-camera game-thread flush from the method name/comment or re-enable it as an optimization. |
| A new readback/fence and staging texture are created per capture. Reuse can also avoid Metal's repeated first-map synchronization path. | `PixelReader.cpp:36`; engine `RHIGPUReadback.cpp:125-149`; `MetalTexture.cpp:1405-1425`; `MetalRenderTarget.cpp:120-124,370-371` | Test reuse separately; no gain is measured. A ring still incurs Metal's per-map temporary shared buffer allocation and copy. |
| Metal lock/unlock assert render-thread use; ordinary BGRA8/FloatRGBA row layout is tightly packed in this fork. | engine `MetalTexture.cpp:1192-1206,1485-1487,1571-1611` | Keep map/copy/unmap on the render thread. Retain explicit size/format/pitch handling; no observed Metal pitch corruption was established. |
| Raw `&Sensor` captures cross asynchronous phases. EndPlay's render flush cannot join a worker that enqueues later. Live sensor reads also occur while creating/serializing headers. | `PixelReader.h:113-125,138-141`; `SceneCaptureSensor.cpp:615-620`; `Sensor.cpp:122-137`; `DataStream.h:38-43`; `AsyncDataStreamImpl.h:23-30`; LibCarla `ImageSerializer.h:47-55` | Snapshot immutable metadata and stream state, introduce ownership/cancel/drain, and stop worker actor reads before extending the asynchronous pipeline. Not proof of the recorded teardown abort's cause. |
| Async TCP submission discards a new message if a previous write is active; the client calls its callback before scheduling the next read. | LibCarla `streaming/detail/tcp/ServerSession.cpp:78-114`; `Client.cpp:171-180` | Count attempts, drops, write completions and client receipts separately. No benchmark loss was established. Preserve ordered submissions and review synchronization of `_is_writing`. |
| `-game` sets runtime noneditor mode; the editor executable name does not establish disabled RHI threading. Bypass zero permits command lists but does not independently enable a separate RHI thread. | engine `LaunchEngineLoop.cpp:2358-2365,2665-2678`; `MetalRHI.cpp:350-357,492-508`; `RHICommandList.cpp:713-767` | Record effective runtime RHI-thread and bypass state before proposing a toggle. |

The existing query trace scopes overlap because they share one lexical block; "create query" includes later work and "Flush" includes the query wait. Use exclusive timings rather than summing those events. `SceneCaptureCamera.cpp:49-65` also constructs per-frame profiler text; its significance remains a secondary measurement hypothesis.

### Priorities, disagreements and alternatives

- Consensus: establish controlled delivery and stage measurements first; test the Metal query change before a full ring; then evaluate reuse and worker processing independently.
- Architecture review favored the narrow query A/B for attribution. Sensor review required explicit lifecycle/metadata ownership before ring or worker changes. Both requirements are reflected in the dependencies below.
- A 2-3 slot ring is a starting hypothesis. Select depth from readiness latency and occupancy; more slots can increase latency without improving sustainable throughput.
- Do not move `FuncForSending` unchanged to a worker: it uses live actor state and mapped memory. Existing CPU output buffers already use a pool; avoid introducing a redundant full-image copy.
- Lower quality/resolution/post-processing changes sensor output. Changing `sensor_tick` or fixed timestep alone does not increase wall-clock capacity. Shared-memory/zero-copy transport and deeper Metal buffer pooling are later options if measurements justify their additional scope.
- One 720p camera at 60 FPS is plausible but unproven: approximately 67% more delivery throughput, or 40% less average interval than the encoded 35.97 FPS run. GPU rendering, simulation, readback and client capacity remain unmeasured constraints; no gain is promised.

## Implementation plan and subtasks

**Overall Status:** In Progress - 20% (2 of 10 subtasks complete; not a performance result)

| ID | Description | Status | Priority | Depends on | Updated | Deliverable / completion condition |
| --- | --- | --- | --- | --- | --- | --- |
| 2.1 | Complete mixed-model review and capture evidence | Complete | High | TASK001 | 2026-10-22 | Independent source reviews and critique exchange recorded above, with corrections and unknowns. |
| 2.2 | Define workload and acceptance contract | Complete | High | 2.1 | 2026-10-22 | Contract in `Util/BuildTools/MacCameraBenchmark.md`: fixed static isolation workload and seeded moving workload, retained project fidelity, exact monotonic window, 30-second exploratory runs and 600-second sustained gate. |
| 2.3 | Establish a reproducible benchmark harness and baseline | In Progress | High | 2.2 | 2026-10-22 | Maintained encoding-free harness added; baseline and repeated workload matrix pending. |
| 2.4 | Add exclusive phase timings and delivery/drop counters | Not Started | High | 2.2 | 2026-10-22 | Measure game/render/RHI/GPU time, copy/readiness/map/unmap, payload processing, send attempts/drops/completion and client arrivals; record effective threading/cvars and queue occupancy. Separate diagnostic trace overhead from throughput runs. |
| 2.5 | Isolate the unconditional Metal query workaround | Not Started | High | 2.3, 2.4 | 2026-10-22 | Compare existing behavior with a Metal-specific path omitting the blocking workaround while preserving submission/fence progress and other RHIs. Check pixels, IDs, metadata, latency and shutdown; retain only a supported improvement. |
| 2.6 | Define safe capture snapshots, ownership and shutdown | Not Started | High | 2.1, 2.4 | 2026-10-22 | Immutable frame/time/transform/dimensions/FOV/format/stream state; no asynchronous actor reads; explicit generation/cancel/in-flight drain across GPU, render commands and worker tasks. |
| 2.7 | Evaluate a bounded persistent readback ring | Not Started | High | 2.5, 2.6 | 2026-10-22 | Compare fresh readbacks with persistent slots and 2 versus 3 slots under the same conditions; measure allocations, first-map waits, occupancy and age. Recreate on size/format changes, reuse only after unmap, and expose saturation without silently dropping captures. |
| 2.8 | Evaluate ordered worker processing of owned CPU buffers | Not Started | Medium | 2.6, 2.7 | 2026-10-22 | Keep Metal map/copy/unmap on render thread; process/send owned pooled buffers with immutable metadata through a bounded ordered path. Preserve buffer lifetime through async writes and measure actual delivery improvement. |
| 2.9 | Validate sensor correctness, lifecycle and compatibility | Not Started | High | 2.5, 2.6; repeat after 2.7/2.8 | 2026-10-22 | Check pixels/format/pitch, headers, ordering, gaps/duplicates, latency, disconnect, destroy/recreate, map change and delayed-readiness cancellation. Diagnose the existing teardown abort separately; check Vulkan/non-Mac behavior for shared changes. |
| 2.10 | Run sustained acceptance and publish the measured decision | Not Started | High | 2.3-2.9 | 2026-10-22 | Record sustained throughput, tails, latency, backlog, drops, resources/thermals and fidelity; state whether 60 FPS is met and what still limits it. Update memory-bank validation/progress with exact artifacts and reproducible commands. |

## Acceptance proposal

- One 1280x720 RGB camera with retained fidelity averages at least 60 Python-delivered frames per wall-clock second during a proposed 10-minute steady-state run after warmup. Declare exact run duration and cadence requirements in 2.2; ten minutes is a proposed stability gate, not a measured hardware property.
- Expected captured frames and received IDs reconcile, with no unexplained drops, duplicates or reordering for an every-tick sensor. Explicitly count any intended rejection policy; frame skipping does not satisfy this target.
- Readback, worker and transport backlog remain bounded, with no upward trend in capture-to-client age. No crash, reconnect or teardown failure.
- Report p50/p95/p99/max interarrival and capture-to-client latency, repeat variability, per-thread load, GPU time and thermal behavior. The nominal 60 Hz period is 16.67 ms; stricter percentile/latency/headroom limits require a workload requirement rather than an arbitrary threshold.
- Verify resolution, format, rendering settings, metadata and image data at matching frames (exact where deterministic, otherwise with declared sensor-specific tolerances). Broad analytic sensor certification remains separate productization work.

## Progress log

### 2026-10-22 — implementation authorized

- User said "Proceed TASK002". Marked In Progress and started the authorized implementation and measurement work.
- Defined the controlled workload/acceptance contract in `Util/BuildTools/MacCameraBenchmark.md`. Added a maintained encoding-free harness with full frame/tick records, fixed monotonic boundaries, warmup-only payload sample, independent cleanup reporting and ownership of only its child server PID.
- Current workspace has about 34 GiB free; avoid large videos/traces or unnecessary engine rebuilds.

### 2026-10-22

- Completed the requested read-only mixed-model review with Astra, Sol and Luna; all three models were available and exchanged critiques. No source edits, builds, server control or performance experiments were performed.
- User requested a task and subtasks in memory bank. Created TASK002, recorded the completed review as 2.1, and left 2.2-2.10 unstarted with explicit dependencies and evidence gates.
- Corrected current memory summaries that still described an absent engine build, no native checkpoint, all GPU waiting off the render thread, or fully verified frame continuity from endpoint-only performance summaries. Preserved historical logs.
