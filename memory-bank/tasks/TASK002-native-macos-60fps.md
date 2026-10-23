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
| 2.3 | Establish a reproducible benchmark harness and baseline | In Progress | High | 2.2 | 2026-10-23 | Maintained encoding-free harness hardened to fail on missing/reordered IDs and unmatched world ticks. One additional 30-second static 720p run pair complete; wider alternating repeats and workload matrix pending. |
| 2.4 | Add exclusive phase timings and delivery/drop counters | In Progress | High | 2.2 | 2026-10-23 | Readback phase timing and opt-in transport counters are implemented. Harness parses final session rows, marks incomplete sessions, and leaves totals unavailable when any session lacks a close row. Effective thread/GPU timing and queue occupancy still need a diagnostic run and attribution. |
| 2.5 | Isolate the unconditional Metal query workaround | In Progress | High | 2.3, 2.4 | 2026-10-23 | Metal-only query toggle and paired experiment are implemented. Fresh-readback 30-second static pair: query on 42.20 FPS, off 46.03 FPS (+9.1%); no sequence/metadata gaps. Keep query enabled by default until correctness/fidelity and repeated matrix checks complete. |
| 2.6 | Define safe capture snapshots, ownership and shutdown | In Progress | High | 2.1, 2.4 | 2026-10-23 | Immutable frame/time/transform/dimensions/FOV/format/stream snapshots and cancel/drain code exist; async, sync, teardown, delayed-readiness and multi-sensor validation remains. |
| 2.7 | Evaluate a bounded persistent readback ring | In Progress | High | 2.5, 2.6 | 2026-10-23 | Optional ring remains default-off. Query-off static runs reached 57.13 FPS (2 slots) and 57.53 FPS (3 slots) in 30 s; an uninstrumented 60 s 2-slot run reached 60.17 FPS. One 600 s run reached 61.11 FPS but failed on missing frame 7987. A repeated 600 s run reached 60.98 FPS with consecutive IDs, zero ring saturation/map failures and zero camera-session write drops. Moving-scene throughput is below target; validate pixel fidelity and sync/multi-sensor/lifecycle cases before enabling by default. |
| 2.8 | Evaluate ordered worker processing of owned CPU buffers | Not Started | Medium | 2.6, 2.7 | 2026-10-22 | Keep Metal map/copy/unmap on render thread; process/send owned pooled buffers with immutable metadata through a bounded ordered path. Preserve buffer lifetime through async writes and measure actual delivery improvement. |
| 2.9 | Validate sensor correctness, lifecycle and compatibility | In Progress | High | 2.5, 2.6; repeat after 2.7/2.8 | 2026-10-23 | A two-slot async RGB static run passed a 600 s sequence and cleanup once; a prior 600 s run exposed one missing frame, and a 60 s autopilot run ended with a server SIGKILL timeout. Pixel/fidelity comparison, synchronous mode, multi-sensor, delayed-readiness, recreate/map-change and non-Mac compatibility remain open. |
| 2.10 | Run sustained acceptance and publish the measured decision | In Progress | High | 2.3-2.9 | 2026-10-23 | Static two-slot/query-off: one 600 s run passed at 60.98 FPS with no gaps or camera-session write drops; a prior run failed due one gap. Seeded moving workload delivered 58.07 FPS over 60 s and timed out during server shutdown. Full acceptance is not met until moving performance, lifecycle, fidelity and resource/thermal reporting pass. |

## Acceptance proposal

- One 1280x720 RGB camera with retained fidelity averages at least 60 Python-delivered frames per wall-clock second during a proposed 10-minute steady-state run after warmup. Declare exact run duration and cadence requirements in 2.2; ten minutes is a proposed stability gate, not a measured hardware property.
- Expected captured frames and received IDs reconcile, with no unexplained drops, duplicates or reordering for an every-tick sensor. Explicitly count any intended rejection policy; frame skipping does not satisfy this target.
- Readback, worker and transport backlog remain bounded, with no upward trend in capture-to-client age. No crash, reconnect or teardown failure.
- Report p50/p95/p99/max interarrival and capture-to-client latency, repeat variability, per-thread load, GPU time and thermal behavior. The nominal 60 Hz period is 16.67 ms; stricter percentile/latency/headroom limits require a workload requirement rather than an arbitrary threshold.
- Verify resolution, format, rendering settings, metadata and image data at matching frames (exact where deterministic, otherwise with declared sensor-specific tolerances). Broad analytic sensor certification remains separate productization work.

## Progress log

### 2026-10-23 — benchmark hardening and query A/B continuation

- The user asked to catch up on the mixed-model review and start work toward 60 FPS. Re-read the review, then obtained an independent GPT-6 Astra critique of the current code and measurement plan.
- Hardened `MacCameraBenchmark.py`: world ticks now include warmup and boundary-drain records; interior gaps, duplicate/reordered IDs, unmatched camera/world IDs, timestamp mismatches and invalid dimensions fail the measurement. Added parsing of final server TCP counters and explicit partial/unavailable status; no totals are inferred when sessions lack close rows. Updated the benchmark contract.
- Ran the same native CARLA 0.9.16 / UE4.26.2 build on `Town02_Opt`, frozen-vehicle static scene, one 1280x720 RGB camera, 10-second warmup and 30-second window. `ReadbackSlots=0`; CPU/RSS/GPU/thermal resource sampling and server transport diagnostics were enabled identically.
- Query enabled: 1,266 callbacks / 30 s = 42.20 Python-delivered FPS. Query disabled: 1,381 / 30 s = 46.03 FPS (+9.1% in this pair). Both have zero camera/world ID gaps, duplicates, reorderings, timestamp mismatches, unmatched frame IDs, invalid dimensions, or cleanup errors. The second session log records one write error during query-off teardown; the measured client sequence has no missing frames. The world-tick TCP session lacks a final close row, so aggregate server totals are intentionally unavailable.
- These are one exploratory pair, not 60 FPS acceptance or a stable effect estimate. Keep the query enabled by default pending alternating repetitions, runtime thread/GPU evidence, pixel comparison and lifecycle review. The persistent ring remains off and unvalidated.
- Artifacts: `Build/macos-engine/benchmarks/query1-static-720p-repeat.json` and `query0-static-720p-repeat.json`, each with a matching `.server.log`.

### 2026-10-23 — persistent ring evaluation and sustained workload

- With the same query-off static workload and resource sampling enabled, the 2-slot ring delivered 57.13 FPS and the 3-slot ring 57.53 FPS over 30 seconds. Both had no ID gaps/reordering/timestamp errors, zero ring saturation/map failures, high-water occupancy 2, and clean shutdown. The marginal 3-slot result does not justify the larger ring.
- Separate 15-second ring diagnostics observed effective Metal/RHI settings (`rhi_thread=1`, `bypass=0`). Median map time was about 1.2 ms with the 2-slot ring versus 11.3 ms on the fresh-readback query-off path; median map-queue delay remained about 25 ms. These diagnostic runs include per-frame logging and are not throughput evidence.
- An uninstrumented 60-second 2-slot static run delivered 3,610 consecutive RGB frames (60.17 FPS), with no unmatched world ticks, timestamp/dimension errors or cleanup failures. A first 600-second static run averaged 61.11 FPS but failed correctness due the single missing camera ID 7987; ring saturation and map failures were zero.
- Repeated the 600-second static run with transport diagnostics. It delivered 36,587 consecutive matching camera frames (60.98 FPS); p95/p99 interarrival 17.04/17.30 ms; p95/p99 arrival-after-world-callback 52.42/52.80 ms with no upward trend. Ring stats: 37,286 submitted/retired, zero saturation, high-water 2, zero map failures. Camera TCP stream 2: 37,284 attempts/started/completed, zero busy drops/errors. The separate world-tick session had no final close row, so aggregate transport totals are unavailable. Shutdown and benchmark cleanup succeeded.
- A 60-second seeded autopilot run delivered 3,484 consecutive matching RGB frames at 58.07 FPS; the last three five-second bins ranged 52.6–55.0 FPS. The camera TCP session showed zero busy drops/write errors and the ring had zero saturation/map failures, but the owned editor process exceeded the 20-second stop timeout and required SIGKILL. Thus the moving workload misses target and lifecycle gate.
- Raised the owned-server stop allowance to 60 seconds after the log showed engine shutdown at the prior 20-second deadline. A repeat moving run then hit a native 60-second `TimeoutException` while waiting for the simulator during cleanup and produced no JSON result; the server log again shows engine shutdown, and the isolated process/ports were confirmed gone. The harness timeout change is syntax-checked, but the moving teardown path needs a focused fix before another performance run.
- Not yet verified: image equality/fidelity across settings, ten-minute moving workload, synchronous mode, multi-sensor operation, sensor recreation/map change, delayed-readiness cancellation, or full-run thermal/resource trends. Keep the experimental query/ring settings disabled by default.

### 2026-10-22 — implementation authorized

- User said "Proceed TASK002". Marked In Progress and started the authorized implementation and measurement work.
- Defined the controlled workload/acceptance contract in `Util/BuildTools/MacCameraBenchmark.md`. Added a maintained encoding-free harness with full frame/tick records, fixed monotonic boundaries, warmup-only payload sample, independent cleanup reporting and ownership of only its child server PID.
- Current workspace has about 34 GiB free; avoid large videos/traces or unnecessary engine rebuilds.

### 2026-10-22

- Completed the requested read-only mixed-model review with Astra, Sol and Luna; all three models were available and exchanged critiques. No source edits, builds, server control or performance experiments were performed.
- User requested a task and subtasks in memory bank. Created TASK002, recorded the completed review as 2.1, and left 2.2-2.10 unstarted with explicit dependencies and evidence gates.
- Corrected current memory summaries that still described an absent engine build, no native checkpoint, all GPU waiting off the render thread, or fully verified frame continuity from endpoint-only performance summaries. Preserved historical logs.
