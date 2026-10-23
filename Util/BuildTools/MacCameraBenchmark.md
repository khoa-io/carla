# Native macOS camera benchmark

Run with the native CARLA Python environment and WindowServer access:

```sh
Build/macos/wheel-test/bin/python Util/BuildTools/MacCameraBenchmark.py \
  --launch-server --port 2100 --warmup 10 --seconds 30 \
  --output Build/macos-engine/benchmarks/baseline-static-720p.json
```

The runner starts a private editor server in game mode on `Town02_Opt`, disables
VSync and the engine frame cap, records its command, and terminates only that
child PID. It refuses occupied RPC/stream/secondary ports and existing output
files. An existing server can be used by omitting `--launch-server`; its graphics
settings must be recorded separately. Keep normal project rendering quality.
Server logs and full metadata stay beside the JSON. No video is produced.

## Workloads and comparison contract

- Primary isolation workload: one 1280x720 BGRA8 RGB camera, 90 degree FOV,
  `sensor_tick=0`, default post processing and project fidelity, clear noon,
  spawn point 0, frozen Tesla Model 3, rear elevated camera (-6, 0, 3; pitch -12).
  Async simulation, variable timestep, rendering enabled. Full blueprint and
  world settings are recorded. A static view isolates pipeline changes.
- Final moving workload: the same camera with `--workload autopilot`, traffic
  manager seed 42, no additional traffic. Async autopilot trajectories are not
  frame deterministic; compare repetitions and report this limit.
- Diagnostics: `--sensors none`, `--width 1920 --height 1080`, and
  `--sensors rgb,depth,semantic`. These are separate runs.
- Warm up for at least 10 seconds; use 30 second exploratory runs, repeated in
  alternating A/B order. Do not change rendering quality, resolution, pixel
  format, sensor cadence or simulation mode to claim a pipeline speedup.
- Sustained gate: after warmup, 600 seconds with at least 60 delivered RGB FPS,
  retained fidelity, explained frame reconciliation, bounded age/backlog and
  clean lifecycle. Run the moving workload as well as the static isolation case.
  Report tails and variability; no unsupported percentile target is imposed.

## Clocks and interpretation

The measurement interval is a fixed half-open monotonic window `[start, end)`.
Callback entry selects membership under the same lock used to retain records.
The denominator remains the requested duration even if the sleep wakes late.
Each frame ID, simulation timestamp, callback arrival, dimensions and callback
body cost is preserved; world ticks are recorded independently. One second of
post-window arrivals is retained for boundary reconciliation. Callback work
only reads metadata and appends a row. One warmup image is retained for payload
length, hash and pixel checks after measurement. No image copy or encoding runs
inside the timed callback.

`fps` means Python delivery per wall-clock second. World delivery is not an
independent GPU render rate. `arrival_after_world_callback_ms` compares matching
frame callbacks and is a delivery-path proxy, not absolute capture latency;
callback scheduling can make it negative. Server platform seconds and Python
monotonic seconds must not be subtracted without clock calibration. Interior
missing IDs, duplicates, reorderings and timestamp mismatches are reported.
Capture/readback/network counters are required to attribute any missing IDs.

The benchmark batches destruction by actor ID, waits for an updated world
snapshot, restores settings/weather, and records cleanup failures. A successful
measurement is not a 60 FPS acceptance result. Graphics cvars, actual threading,
GPU timing and thermal behavior need server diagnostics in addition to this
client artifact.

## Readback diagnostics and Metal query experiment

The existing blocking query remains enabled by default. On Metal only, use
`--cvar 'carla.Camera.MetalBlockingQuery 0'` to omit it and rely on the readback
fence. Other RHIs retain the established query path. Compare against the same
binary with `--cvar 'carla.Camera.MetalBlockingQuery 1'`.

Use `--cvar 'carla.Camera.ReadbackDiagnostics 1'` for a separate diagnostic run.
Server log lines beginning `CarlaCameraReadback` contain a CSV header followed by
per-readback exclusive CPU phase timings, frame ID and engine platform time.
Readiness task waiting and render-command queue time are distinct. Total time
includes scheduling gaps; the game/render/RHI/GPU fields are engine frame
statistics, not extra exclusive readback phases. `payload_ms` includes the
existing conversion/copy/serialization/stream submission callback, and does not
mean TCP completion. The first diagnostic capture logs effective RHI, editor
mode, RHI thread, bypass, VSync, frame cap and screen percentage. Per-frame logging
adds overhead, so leave diagnostics off in throughput comparisons.
