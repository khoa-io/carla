# TASK003 - Build a Rust-backed web interface to view and control a CARLA vehicle

**Status:** Complete
**Priority:** High
**Added:** 2026-10-23
**Updated:** 2026-10-23
**Branch:** `codex/http-streaming`
**Depends on:** [TASK001](TASK001-native-macos-port.md), native CARLA 0.9.16 prototype

## Original Request

> Let's create a branch called `codex/http-streaming`, a task and some sub-tasks, ... to develop a solution to view and control the vehicle via a web interface. Rust is preferred for speed and memory safety

## Thought Process

- Keep the selected CARLA baseline at 0.9.16 and preserve the native macOS ARM64 prototype.
- CARLA's existing Python/C++ client transports are TCP RPC and sensor streaming, not HTTP. The web interface therefore needs a gateway that translates browser traffic into CARLA client API operations and relays camera frames.
- Prefer a Rust-owned web gateway and browser-facing service. CARLA 0.9.16 has no supported Rust client API, so investigate a narrow adapter to the supported CARLA Python API before choosing an integration boundary. Avoid reimplementing CARLA's RPC protocol unless source review demonstrates that a stable Rust client is practical.
- First establish an end-to-end MVP architecture: show a live RGB camera feed and issue bounded vehicle-control commands from a browser. Keep the simulator's existing server and sensor semantics intact.
- Define local-only defaults and an explicit configuration boundary before allowing remote access; vehicle control is privileged and should not be exposed unauthenticated on a public interface.

## Implementation Plan

1. Map the CARLA client, RPC, camera streaming and vehicle-control APIs available in this checkout; identify viable Rust-to-CARLA integration options.
2. Select and document the gateway/adapter protocol, browser frame transport, control semantics, process lifecycle and local security defaults.
3. Implement the Rust web service and the smallest CARLA adapter needed to stream a selected vehicle camera and apply user controls.
4. Build the browser interface for live viewing, vehicle selection/status and keyboard/pointer driving controls.
5. Document setup, configuration, limitations and the steps needed to bind beyond localhost.
6. Validate browser/simulator behavior and process/actor cleanup in a live local CARLA session.

## Progress Tracking

**Overall Status:** Complete - 100% (live local browser/CARLA acceptance passed)

### Subtasks

| ID | Description | Status | Updated | Notes |
|----|-------------|--------|---------|-------|
| 3.1 | Inspect CARLA 0.9.16 client, streaming and control APIs; choose a Rust integration boundary | Complete | 2026-10-23 | Existing Python API covers client connection, attached RGB camera callbacks and VehicleControl. Direct Rust would need CARLA rpclib/MessagePack RPC plus its separate custom TCP sensor protocol. |
| 3.2 | Specify gateway, frame transport, control protocol and local security model | Complete | 2026-10-23 | Rust owns HTTP/WebSocket, IPC framing, browser capability and input validation; matching Python CARLA API remains the narrow adapter. |
| 3.3 | Implement Rust HTTP/WebSocket gateway and CARLA adapter | Complete | 2026-10-23 | Implemented local-only service, adapter process, owned vehicle/camera lifecycle, bounded frame/control queues, fresh-frame gate, explicit arm/re-arm, and shutdown signal. Blocking CARLA control RPC can delay the adapter watchdog up to its 10 s timeout; braking remains best-effort. |
| 3.4 | Implement the browser viewer and vehicle controls | Complete | 2026-10-23 | JPEG camera viewer, latest-frame decode, keyboard/on-screen driving, one-controller lease, focus/visibility brake and re-arm UI. |
| 3.5 | Document operation, configuration and remote-access boundary | Complete | 2026-10-23 | Added install/run instructions, localhost security boundary, control limitations, frame freshness and validation caveats. |
| 3.6 | Validate browser/simulator behavior and process/actor cleanup in a live local CARLA session | Complete | 2026-10-23 | Native CARLA 0.9.16 Town02_Opt session: fresh 640×360 JPEG frames; browser lease acquired; second viewer denied; brief acceleration input sent; a deliberately 100-frame-stale control was rejected and disarmed. Gateway shutdown left no owned vehicle/camera actors and closed port 8765. |

## Progress Log

### 2026-10-23

- Created branch `codex/http-streaming` from the current clean `codex/macos-port` checkout.
- Recorded the web viewer/controller objective and initial implementation breakdown.
- Completed source reconnaissance of the CARLA client APIs and examples. The existing Python API supports vehicle/camera lifecycle and control; the browser-facing HTTP/WebSocket gateway is new work. Avoid reimplementing CARLA's two transport protocols in Rust for the MVP.
- Chose an initial direction for architecture: Rust owns HTTP, browser WebSockets, validation and frame fanout; a narrow Python 3.11 adapter uses the matching CARLA wheel. Keep frames binary across the adapter boundary and WebSocket, clamp throttle/brake to `[0,1]` and steering to `[-1,1]`, leave autopilot off while taking manual control, preserve the server's tick settings, and neutralize/release browser input on disconnect.
- Implemented `Util/WebControl/` with a Rust Axum HTTP/WebSocket gateway, local capability authentication, binary camera IPC, JPEG frame fanout, one-controller lease, throttle/brake/steer validation and a Python 3.11 adapter using the checkout's CARLA API. The adapter spawns and owns a Tesla demo vehicle and attached RGB camera; it leaves world tick settings untouched.
- Added explicit server-side armed state and a 750 ms camera freshness gate. A stale camera or adapter watchdog disarms and requires an explicit browser re-arm. Shutdown uses an out-of-band signal and websocket handlers have bounded sends so they can release the lease and exit.
- Reviewed safety/lifecycle concerns against CARLA sources. The Python `apply_batch_sync` binding is blocking and can hold the GIL, so a 300 ms watchdog deadline and camera callbacks can be delayed by an in-flight RPC (configured client timeout: 10 s); submitted braking is best-effort and this limitation is documented. At the implementation checkpoint, live CARLA/browser acceptance and actor cleanup were still unverified; the live acceptance below subsequently closed that gate.
- Static validation completed: `cargo check --locked`, release `cargo build --locked`, `python3 -m py_compile`, `node --check`, and `git diff --check`. At that implementation checkpoint, no tests or live simulator/browser session had been run.
- Live acceptance completed on 2026-10-23 against the native CARLA 0.9.16 editor server on `Carla/Maps/Town02_Opt`, using the matching CPython 3.11 wheel. The local viewer displayed advancing 640×360 camera frames (observed CARLA frame 2082 through 6591). Browser authentication succeeded, the first tab acquired control, and a second tab received “Another browser owns control.” A brief 250 ms acceleration-button press was sent; control was then released and the UI reported “Control released; vehicle braking.”
- Independently exercised the WebSocket stale-frame guard using the page's local capability: after acquiring a lease, a command carrying a displayed frame 100 IDs behind the latest was rejected with “Camera is stale or command sequence is invalid; take control again,” and the controller was disarmed.
- Shut down the gateway and verified actor 47 no longer existed, no `role_name=web_control` vehicle or RGB camera remained, and TCP port 8765 was closed. The CARLA server was then stopped. Live acceptance does not establish guaranteed braking during a blocked CARLA RPC; the documented 10 s RPC timeout remains the safety limitation.
