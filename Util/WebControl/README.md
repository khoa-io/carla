# CARLA Web Control (prototype)

A local browser viewer and keyboard controller for the native CARLA 0.9.16 setup. The Rust process serves the UI and WebSocket API, owns a short-lived browser capability, validates control input, encodes camera frames as JPEG, and supervises a small Python adapter that uses the matching CARLA client API.

## Requirements

- A running CARLA 0.9.16 server accepting the standard RPC connection (default `127.0.0.1:2000`).
- Rust/Cargo.
- A Python 3.11 environment with the CARLA wheel built from this checkout installed. Do not install a wheel for a different CARLA version.

For this checkout's native wheel, an example install is:

```sh
python3.11 -m venv Build/web-control-venv
Build/web-control-venv/bin/python -m pip install PythonAPI/carla/dist/carla-0.9.16-cp311-cp311-macosx_12_0_arm64.whl
```

## Run

From the repository root:

```sh
cargo run --release --manifest-path Util/WebControl/Cargo.toml -- \
  --python "$PWD/Build/web-control-venv/bin/python" \
  --carla-host 127.0.0.1 \
  --carla-port 2000
```

Open the printed local URL (default `http://127.0.0.1:8765`). The adapter spawns a `vehicle.tesla.model3` at an available map spawn point and attaches a 640×360 RGB camera. On normal Rust shutdown, the adapter attempts a brake command, stops and destroys its camera, then destroys the vehicle it spawned. If a CARLA RPC stalls or cleanup exceeds the shutdown grace period, forced process termination can bypass that cleanup. The simulator's current synchronous/asynchronous settings are left alone.

Use **Take control**, then hold **W/A/S/D** or the on-screen buttons. A second browser can view the stream but cannot acquire the one-controller lease while another browser holds it. Releasing the control button, losing focus, hiding the page, disconnecting, or letting input go stale sends a full-brake command. A stale-input timeout disarms driving; press **Re-arm** to continue.

## Safety and scope

- HTTP listens only on `127.0.0.1`; there is no remote-bind option. WebSocket requests must match the local origin and prove a per-process random capability served in the page. Remote access, TLS, authentication for remote users and multi-vehicle selection are out of scope.
- The Python adapter owns only the demo vehicle and camera it creates. It does not attach to or take control of an arbitrary existing vehicle.
- Throttle/brake are clamped to `[0,1]`, steering to `[-1,1]`, and braking takes precedence over throttle. The adapter submits controls with `apply_batch_sync(..., do_tick=False)` and checks CARLA's command response.
- The adapter checks a 300 ms monotonic input deadline independently of camera sending and submits a brake command when it expires. The CARLA Python `apply_batch_sync` call is blocking, however, and the client RPC timeout is 10 seconds; a stalled control RPC can delay the watchdog and camera callbacks. This is best-effort braking, not a guaranteed stop if CARLA is paused, unreachable, or the adapter/process has crashed.
- The adapter preserves world tick ownership and does not change world settings. In synchronous mode another client must continue to own and advance the world.
- Frames carry the CARLA frame number, dimensions, simulation timestamp and adapter receive time. The browser sends the displayed frame number with control updates; the gateway rejects controls when the displayed CARLA world frame falls more than eight frame IDs behind the latest encoded frame, or when no frame has arrived for 750 ms. A stale camera or adapter watchdog disarms control and requires an explicit re-arm.
- The camera defaults to 640×360 at 20 Hz and the Rust gateway JPEG-encodes at quality 82. These are prototype defaults, not performance measurements or claims about Unreal render FPS.

## Validation

Live local acceptance passed on 2026-10-23 against CARLA 0.9.16 on `Town02_Opt`. The browser displayed advancing 640×360 camera frames, acquired the one-controller lease, sent a brief acceleration input, and showed the release/braking state. A second viewer could see the stream but was denied control while the first held the lease. A command using a frame 100 IDs behind the latest was rejected and disarmed. On gateway shutdown, the adapter's owned vehicle and camera were destroyed and the web port closed.

This acceptance does not make braking fail-safe when a CARLA RPC blocks. The adapter's synchronous control RPC can delay watchdog handling up to its configured 10-second timeout; braking and cleanup remain best-effort under that condition.
