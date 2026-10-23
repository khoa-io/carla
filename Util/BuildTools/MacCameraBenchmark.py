#!/usr/bin/env python3
"""Encoding-free native camera throughput measurement; see MacCameraBenchmark.md."""

import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import platform
import plistlib
import re
import socket
import subprocess
import threading
import time

import carla


ROOT = Path(__file__).resolve().parents[2]
SENSOR_TYPES = {"rgb": "sensor.camera.rgb", "depth": "sensor.camera.depth",
                "semantic": "sensor.camera.semantic_segmentation"}
STREAM_STATS = re.compile(
    r"CarlaStreamStats session=(?P<session>\d+) stream=(?P<stream>\d+) "
    r"reason=(?P<reason>\S+) attempts=(?P<attempts>\d+) closed=(?P<closed>\d+) "
    r"busy_drops=(?P<busy_drops>\d+) started=(?P<started>\d+) "
    r"completed=(?P<completed>\d+) errors=(?P<errors>\d+) bytes=(?P<bytes>\d+)"
)


def percentiles(values):
    ordered = sorted(values)
    if not ordered:
        return None
    def percentile(fraction):
        index = (len(ordered) - 1) * fraction
        low = int(index)
        high = min(low + 1, len(ordered) - 1)
        return ordered[low] + (ordered[high] - ordered[low]) * (index - low)
    return {"p50": percentile(.50), "p95": percentile(.95),
            "p99": percentile(.99), "max": ordered[-1]}


def sequence_summary(rows):
    ids = [row[0] for row in rows]
    return {"count": len(ids), "first": ids[0] if ids else None,
            "last": ids[-1] if ids else None,
            "duplicates": len(ids) - len(set(ids)),
            "reordered": sum(b < a for a, b in zip(ids, ids[1:])),
            "interior_missing_ids": sorted(set(range(min(ids), max(ids) + 1)) - set(ids)) if ids else [],
            "interarrival_ms": percentiles([(b[1] - a[1]) / 1e6 for a, b in zip(rows, rows[1:])])}


def parse_stream_stats(log_path):
    """Return final per-session counters, keeping periodic snapshots separate."""
    if log_path is None or not log_path.is_file():
        return {"available": False, "sessions": [], "totals": None}
    latest = {}
    with log_path.open(errors="replace") as source:
        for line in source:
            match = STREAM_STATS.search(line)
            if match:
                row = match.groupdict()
                for key in ("session", "stream", "attempts", "closed", "busy_drops",
                            "started", "completed", "errors", "bytes"):
                    row[key] = int(row[key])
                latest[row["session"]] = row
    sessions = sorted(latest.values(), key=lambda row: row["session"])
    counter_names = ("attempts", "closed", "busy_drops", "started", "completed", "errors", "bytes")
    incomplete = [row["session"] for row in sessions if row["reason"] != "close"]
    totals = ({key: sum(row[key] for row in sessions) for key in counter_names}
              if sessions and not incomplete else None)
    return {"available": bool(sessions), "complete": bool(sessions) and not incomplete,
            "sessions": sessions, "incomplete_sessions": incomplete, "totals": totals}


def git_revision(path):
    result = subprocess.run(["git", "-C", str(path), "rev-parse", "HEAD"],
                            capture_output=True, text=True, check=False)
    return result.stdout.strip() if result.returncode == 0 else None


def file_fingerprint(path):
    if not path.is_file():
        return None
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return {"path": str(path), "size": path.stat().st_size, "sha256": digest.hexdigest()}


def resource_snapshot(pid):
    """Optional system-wide GPU gauges and owned-process CPU/RSS; outside callback."""
    snapshot = {"monotonic_ns": time.monotonic_ns()}
    commands = {"thermal": ["/usr/bin/pmset", "-g", "therm"]}
    if pid is not None:
        commands["server_cpu_rss"] = ["/bin/ps", "-p", str(pid), "-o", "time=,rss=,%cpu="]
    for key, command in commands.items():
        completed = subprocess.run(command, capture_output=True, text=True, check=False, timeout=5)
        snapshot[key] = completed.stdout.strip() if completed.returncode == 0 else completed.stderr.strip()
    try:
        completed = subprocess.run(["/usr/sbin/ioreg", "-a", "-r", "-c", "AGXAccelerator", "-d", "1"],
                                   capture_output=True, check=True, timeout=5)
        snapshot["system_gpu"] = [entry["PerformanceStatistics"] for entry in plistlib.loads(completed.stdout)
                                  if "PerformanceStatistics" in entry]
    except (subprocess.SubprocessError, ValueError) as error:
        snapshot["gpu_error"] = repr(error)
    return snapshot


def wait_until(deadline):
    while True:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            return
        time.sleep(min(remaining, .5))


def parse_args():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=2100)
    parser.add_argument("--seconds", type=float, default=30)
    parser.add_argument("--warmup", type=float, default=10)
    parser.add_argument("--width", type=int, default=1280)
    parser.add_argument("--height", type=int, default=720)
    parser.add_argument("--sensors", default="rgb", help="rgb,depth,semantic or none")
    parser.add_argument("--workload", choices=["static", "autopilot"], default="static")
    parser.add_argument("--spawn-index", type=int, default=0)
    parser.add_argument("--seed", type=int, default=42)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--launch-server", action="store_true")
    parser.add_argument("--engine-root", type=Path, default=ROOT / "Build/macos-engine/source")
    parser.add_argument("--startup-timeout", type=float, default=600)
    parser.add_argument("--shutdown-timeout", type=float, default=60)
    parser.add_argument("--server-arg", action="append", default=[], help="Use --server-arg=-Flag")
    parser.add_argument("--cvar", action="append", default=[], help="Additional server console setting, e.g. 'carla.Camera.MetalBlockingQuery 0'")
    parser.add_argument("--stream-diagnostics", action="store_true")
    parser.add_argument("--sample-resources", action="store_true", help="Sample CPU/RSS, system GPU and thermal gauges each 5s; use consistently in comparisons")
    arguments = parser.parse_args()
    arguments.sensor_names = [] if arguments.sensors == "none" else arguments.sensors.split(",")
    if (arguments.seconds <= 0 or arguments.warmup < 0 or arguments.width <= 0
            or arguments.shutdown_timeout <= 0
            or arguments.height <= 0 or len(set(arguments.sensor_names)) != len(arguments.sensor_names)
            or set(arguments.sensor_names) - SENSOR_TYPES.keys()):
        parser.error("Invalid duration, dimensions or sensor list")
    if arguments.launch_server and arguments.host != "127.0.0.1":
        parser.error("An owned server must use 127.0.0.1")
    return arguments


def main():
    args = parse_args()
    args.output = args.output.resolve()
    args.output.parent.mkdir(parents=True, exist_ok=True)
    if args.output.exists():
        raise FileExistsError(args.output)
    if platform.system() != "Darwin" or platform.machine() != "arm64":
        raise RuntimeError("Use native Apple Silicon Python")
    result = {"schema_version": 1, "started_utc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
              "arguments": {k: str(v) if isinstance(v, Path) else v for k, v in vars(args).items()},
              "host": {"platform": platform.platform(), "machine": platform.machine(),
                       "python": platform.python_version()},
              "revision": git_revision(ROOT), "engine_revision": git_revision(args.engine_root),
              "harness_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
              "clock": vars(time.get_clock_info("monotonic")),
              "carla_module": file_fingerprint(ROOT / "Unreal/CarlaUE4/Plugins/Carla/Binaries/Mac/UE4Editor-Carla.dylib"),
              "status": "starting", "cleanup_errors": []}
    server = None
    server_log = None
    world = None
    original_settings = None
    original_weather = None
    tick_token = None
    actors = []
    sensors = []
    lock = threading.Lock()
    capture = {"start_ns": None, "end_ns": None, "closed": False}
    frames = {name: [] for name in args.sensor_names}
    ticks = []
    errors = []
    sample = {}
    resource_samples = []
    stop_resources = threading.Event()
    resource_thread = None

    def monitor_resources():
        while not stop_resources.is_set():
            try:
                resource_samples.append(resource_snapshot(server.pid if server is not None else None))
            except Exception as error:
                resource_samples.append({"error": repr(error)})
            stop_resources.wait(5)

    def on_tick(snapshot):
        entered = time.monotonic_ns()
        with lock:
            if not capture["closed"]:
                ticks.append([snapshot.frame, entered, snapshot.timestamp.elapsed_seconds,
                              snapshot.timestamp.platform_timestamp, snapshot.timestamp.delta_seconds])

    def receiver(name):
        def receive(image):
            entered = time.monotonic_ns()
            with lock:
                start = capture["start_ns"]
                if start is not None and not capture["closed"]:
                    # Metadata only: no image copy, hashing, encoding, disk I/O or RPC here.
                    row = [image.frame, entered, image.timestamp, image.width, image.height, 0]
                    frames[name].append(row)
                    row[5] = time.monotonic_ns() - entered
                elif start is None and name not in sample:
                    # Retain one warmup image for correctness checks after the timed window.
                    sample[name] = image
        return receive

    try:
        if args.launch_server:
            for port in (args.port, args.port + 1, args.port + 2):
                with socket.socket() as probe:
                    # Allow TCP TIME_WAIT from our preceding run, never a listener.
                    probe.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
                    probe.bind((args.host, port))
            project = ROOT / "Unreal/CarlaUE4/CarlaUE4.uproject"
            binary = args.engine_root / "Engine/Binaries/Mac/UE4Editor-Cmd"
            command = [str(binary), str(project), "/Game/Carla/Maps/Town02_Opt", "-GAME", "-log",
                       "-stdout", "-FullStdOutLogOutput", "-unattended", "-nosound", "-novsync",
                       f"-carla-rpc-port={args.port}", "-ResX=1280", "-ResY=720", "-windowed",
                       "-ExecCmds=" + ",".join(["r.VSync 0", "t.MaxFPS 0", *args.cvar]), *args.server_arg]
            result["server_command"] = command
            environment = os.environ.copy()
            environment["UE-LocalDataCachePath"] = str(ROOT / "Build/macos-engine/ddc")
            environment["CLANG_MODULE_CACHE_PATH"] = str(ROOT / "Build/macos-engine/cache/clang-module")
            environment["XDG_CACHE_HOME"] = str(ROOT / "Build/macos-engine/cache/xdg")
            environment["CARLA_STREAMING_DIAGNOSTICS"] = "1" if args.stream_diagnostics else "0"
            log_path = args.output.with_suffix(".server.log")
            server_log = log_path.open("x")
            server = subprocess.Popen(command, cwd=project.parent, env=environment,
                                      stdout=server_log, stderr=subprocess.STDOUT)
            result.update(server_pid=server.pid, server_log=str(log_path))
            print(f"Owned server PID {server.pid}; log {log_path}", flush=True)
        deadline = time.monotonic() + args.startup_timeout
        while True:
            if server is not None and server.poll() is not None:
                raise RuntimeError(f"Server exited at startup: {server.returncode}")
            try:
                # rpclib does not recover this connection after an early refusal.
                # A fresh client per attempt is required while the server loads.
                client = carla.Client(args.host, args.port)
                client.set_timeout(5)
                world = client.get_world()
                break
            except RuntimeError:
                if time.monotonic() >= deadline:
                    raise
                time.sleep(1)
        print("Server RPC/world ready", flush=True)
        client.set_timeout(60)
        result.update(client_version=client.get_client_version(), server_version=client.get_server_version(),
                      client_extension=carla.libcarla.__file__, map=world.get_map().name)
        original_settings, original_weather = world.get_settings(), world.get_weather()
        settings = world.get_settings()
        settings.synchronous_mode = False
        settings.fixed_delta_seconds = None
        settings.no_rendering_mode = False
        world.apply_settings(settings)
        world.set_weather(carla.WeatherParameters.ClearNoon)
        result["world_settings"] = str(world.get_settings())
        result["weather"] = str(world.get_weather())
        library = world.get_blueprint_library()
        spawn = world.get_map().get_spawn_points()[args.spawn_index]
        vehicle = world.spawn_actor(library.find("vehicle.tesla.model3"), spawn)
        actors.append(vehicle.id)
        result.update(vehicle=vehicle.type_id, spawn_transform=str(spawn))
        if args.workload == "static":
            vehicle.set_simulate_physics(False)
        else:
            manager = client.get_trafficmanager(args.port + 6000)
            manager.set_random_device_seed(args.seed)
            vehicle.set_autopilot(True, manager.get_port())
        camera_transform = carla.Transform(carla.Location(x=-6, z=3), carla.Rotation(pitch=-12))
        result["camera_transform"] = str(camera_transform)
        result["sensors"] = {}
        for name in args.sensor_names:
            blueprint = library.find(SENSOR_TYPES[name])
            for attribute, value in {"image_size_x": args.width, "image_size_y": args.height,
                                     "fov": 90, "sensor_tick": 0.0}.items():
                blueprint.set_attribute(attribute, str(value))
            sensor = world.spawn_actor(blueprint, camera_transform, attach_to=vehicle)
            actors.append(sensor.id)
            sensors.append(sensor)
            result["sensors"][name] = {"id": sensor.id, "attributes": sensor.attributes}
            sensor.listen(receiver(name))
        tick_token = world.on_tick(on_tick)
        print(f"Warming up {args.warmup}s ({args.workload}, {args.sensors}, {args.width}x{args.height})", flush=True)
        wait_until(time.monotonic() + args.warmup)
        if args.sample_resources:
            resource_thread = threading.Thread(target=monitor_resources, daemon=True)
            resource_thread.start()
        with lock:
            capture["start_ns"] = time.monotonic_ns()
            capture["end_ns"] = capture["start_ns"] + round(args.seconds * 1e9)
        print(f"Measuring {args.seconds}s", flush=True)
        wait_until(capture["end_ns"] / 1e9)
        # Keep boundary arrivals for frame reconciliation without changing the denominator.
        wait_until(time.monotonic() + 1)
        with lock:
            capture["closed"] = True
        start_ns, end_ns = capture["start_ns"], capture["end_ns"]
        stop_resources.set()
        if resource_thread is not None:
            resource_thread.join(timeout=20)
        measured_ticks = [row for row in ticks if start_ns <= row[1] < end_ns]
        tick_by_id = {row[0]: row for row in ticks}
        result.update(measurement_start_ns=start_ns, measurement_end_ns=end_ns,
                      measurement_seconds=(end_ns - start_ns) / 1e9,
                      tick_columns=["frame", "arrival_monotonic_ns", "simulation_seconds",
                                    "server_platform_seconds", "delta_seconds"], ticks=ticks,
                      frame_columns=["frame", "arrival_monotonic_ns", "simulation_seconds",
                                     "width", "height", "callback_body_ns"], frames=frames,
                      world_summary=sequence_summary(measured_ticks), camera_summary={}, resource_samples=resource_samples)
        result["world_summary"]["fps"] = len(measured_ticks) / args.seconds
        if (not measured_ticks or result["world_summary"]["duplicates"]
                or result["world_summary"]["reordered"]
                or result["world_summary"]["interior_missing_ids"]):
            errors.append("world tick sequence has missing, duplicate or reordered frames")
        for name, rows in frames.items():
            measured = [row for row in rows if start_ns <= row[1] < end_ns]
            summary = sequence_summary(measured)
            summary["fps"] = len(measured) / args.seconds
            summary["callback_body_ms"] = percentiles([row[5] / 1e6 for row in measured])
            unmatched_ids = [row[0] for row in measured if row[0] not in tick_by_id]
            matched = [row for row in measured if row[0] in tick_by_id]
            summary["world_tick_matches"] = len(matched)
            summary["unmatched_world_frame_ids"] = unmatched_ids
            summary["arrival_after_world_callback_ms"] = percentiles([
                (row[1] - tick_by_id[row[0]][1]) / 1e6 for row in matched])
            # This is a delivery-path proxy, not absolute GPU capture-to-client latency.
            summary["timestamp_mismatches"] = sum(abs(row[2] - tick_by_id[row[0]][2]) > 1e-5
                                                   for row in matched)
            summary["invalid_dimensions"] = sum(row[3:5] != [args.width, args.height] for row in measured)
            summary["five_second_bins"] = []
            for begin in range(0, round(args.seconds * 1e9), 5_000_000_000):
                end = min(begin + 5_000_000_000, round(args.seconds * 1e9))
                part = [row for row in measured if start_ns + begin <= row[1] < start_ns + end]
                summary["five_second_bins"].append({"offset_seconds": begin / 1e9,
                    "fps": len(part) / ((end - begin) / 1e9),
                    "arrival_after_world_callback_ms": percentiles([
                        (row[1] - tick_by_id[row[0]][1]) / 1e6 for row in part if row[0] in tick_by_id])})
            result["camera_summary"][name] = summary
            image = sample.get(name)
            if image is None:
                errors.append(f"{name}: no warmup image")
            else:
                raw = bytes(image.raw_data)
                result["sensors"][name]["warmup_sample"] = {
                    "frame": image.frame, "bytes": len(raw), "sha256": hashlib.sha256(raw).hexdigest(),
                    "nonuniform": len(set(raw[0::4])) > 1}
                if len(raw) != args.width * args.height * 4:
                    errors.append(f"{name}: invalid payload length")
            if (not measured or summary["duplicates"] or summary["reordered"]
                    or summary["interior_missing_ids"] or unmatched_ids
                    or summary["invalid_dimensions"] or summary["timestamp_mismatches"]):
                errors.append(f"{name}: sequence coverage or metadata/order validation failed")
        result["status"] = "failed" if errors else "measured"
    except BaseException as error:
        result["status"] = "failed"
        errors.append(repr(error))
    finally:
        stop_resources.set()
        if resource_thread is not None:
            resource_thread.join(timeout=20)
        with lock:
            capture["closed"] = True
        def cleanup(action):
            try:
                action()
            except Exception as error:
                result["cleanup_errors"].append(repr(error))
        if world is not None:
            if tick_token is not None:
                cleanup(lambda: world.remove_on_tick(tick_token))
            for sensor in sensors:
                cleanup(sensor.stop)
            if actors:
                def destroy_owned():
                    replies = client.apply_batch_sync([carla.command.DestroyActor(actor) for actor in reversed(actors)], False)
                    for reply in replies:
                        if reply.has_error():
                            raise RuntimeError(reply.error)
                    # Advance the client actor snapshot before Python sensor destructors run.
                    world.wait_for_tick(30)
                cleanup(destroy_owned)
            if original_weather is not None:
                cleanup(lambda: world.set_weather(original_weather))
            if original_settings is not None:
                cleanup(lambda: world.apply_settings(original_settings))
        if server is not None:
            if server.poll() is None:
                server.terminate()
                try:
                    server.wait(timeout=args.shutdown_timeout)
                except subprocess.TimeoutExpired:
                    result["cleanup_errors"].append(
                        f"Owned server required SIGKILL after {args.shutdown_timeout:g}s")
                    server.kill()
                    server.wait()
            result["server_exit_code"] = server.returncode
        if server_log is not None:
            server_log.close()
            result["stream_diagnostics"] = parse_stream_stats(Path(result["server_log"]))
        if args.stream_diagnostics and "stream_diagnostics" not in result:
            result["stream_diagnostics"] = {"available": False, "complete": False,
                                            "sessions": [], "incomplete_sessions": [], "totals": None,
                                            "note": "No owned server log was available to parse."}
        elif args.stream_diagnostics and not result["stream_diagnostics"]["available"]:
            result["stream_diagnostics"]["note"] = "No final session counters found; server diagnostics are incomplete."
        result["errors"] = errors
        if result["cleanup_errors"]:
            result["status"] = "failed"
        args.output.write_text(json.dumps(result, indent=2) + "\n")
        print(json.dumps({key: result.get(key) for key in
                          ["status", "world_summary", "camera_summary", "errors", "cleanup_errors"]}, indent=2), flush=True)
        print(f"Full result: {args.output}", flush=True)
    if result["status"] == "failed":
        raise SystemExit(1)


if __name__ == "__main__":
    main()
