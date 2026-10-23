#!/usr/bin/env python3
"""Small CARLA Python API worker for the Rust web-control process."""

import json
import math
import os
import queue
import socket
import struct
import threading
import time

import carla


MAX_RECORD = 64 * 1024 * 1024
FAILSAFE_AFTER_S = 0.30


def read_exact(sock, size):
    chunks = bytearray()
    while len(chunks) < size:
        chunk = sock.recv(size - len(chunks))
        if not chunk:
            raise ConnectionError("web gateway disconnected")
        chunks.extend(chunk)
    return bytes(chunks)


def send_record(sock, payload):
    sock.sendall(struct.pack("!I", len(payload)) + payload)


def report(sock, writer_lock, message):
    with writer_lock:
        send_record(sock, b"S" + message.encode("utf-8", errors="replace"))


def report_disarmed(sock, writer_lock, message):
    with writer_lock:
        send_record(sock, b"D" + message.encode("utf-8", errors="replace"))


def connect_gateway(address):
    deadline = time.monotonic() + 30.0
    last_error = None
    while time.monotonic() < deadline:
        try:
            connection = socket.create_connection(address, timeout=2.0)
            connection.settimeout(None)
            return connection
        except OSError as error:
            last_error = error
            time.sleep(0.1)
    raise ConnectionError("could not connect to Rust gateway: {}".format(last_error))


def command_reader(sock, commands, state):
    try:
        while True:
            length = struct.unpack("!I", read_exact(sock, 4))[0]
            if length < 1 or length > MAX_RECORD:
                raise ValueError("invalid command record length")
            record = read_exact(sock, length)
            if record[0:1] != b"C":
                continue
            command = json.loads(record[1:].decode("utf-8"))
            try:
                commands.put_nowait(command)
            except queue.Full:
                try:
                    commands.get_nowait()
                except queue.Empty:
                    pass
                commands.put_nowait(command)
    except (ConnectionError, OSError, ValueError, json.JSONDecodeError) as error:
        with state["lock"]:
            state["error"] = str(error)


def apply_control(client, vehicle, throttle, steer, brake):
    values = [float(throttle), float(steer), float(brake)]
    if not all(math.isfinite(value) for value in values):
        values = [0.0, 0.0, 1.0]
    throttle, steer, brake = values
    if brake > 0.0:
        throttle = 0.0
    control = carla.VehicleControl(
        throttle=max(0.0, min(1.0, float(throttle))),
        steer=max(-1.0, min(1.0, float(steer))),
        brake=max(0.0, min(1.0, float(brake))),
        hand_brake=False,
        reverse=False,
        manual_gear_shift=False,
    )
    responses = client.apply_batch_sync(
        [carla.command.ApplyVehicleControl(vehicle.id, control)], False
    )
    if len(responses) != 1:
        raise RuntimeError("CARLA returned an unexpected control response count")
    if responses[0].error:
        raise RuntimeError(responses[0].error)


def spawn_vehicle(world, blueprint_name):
    library = world.get_blueprint_library()
    try:
        blueprint = library.find(blueprint_name)
    except RuntimeError as error:
        raise RuntimeError("vehicle blueprint not found: {}".format(blueprint_name)) from error
    if blueprint.has_attribute("role_name"):
        blueprint.set_attribute("role_name", "web_control")
    for transform in world.get_map().get_spawn_points():
        vehicle = world.try_spawn_actor(blueprint, transform)
        if vehicle is not None:
            return vehicle
    raise RuntimeError("no unoccupied spawn point available for the web-control vehicle")


def main():
    host = os.environ.get("CARLA_WEB_HOST", "127.0.0.1")
    port = int(os.environ.get("CARLA_WEB_PORT", "2000"))
    blueprint_name = os.environ.get("CARLA_WEB_VEHICLE", "vehicle.tesla.model3")
    width = int(os.environ.get("CARLA_WEB_WIDTH", "640"))
    height = int(os.environ.get("CARLA_WEB_HEIGHT", "360"))
    gateway = os.environ.get("CARLA_WEB_IPC_ADDR", "127.0.0.1:0")
    ipc_token = os.environ.get("CARLA_WEB_IPC_TOKEN", "")
    gateway_host, gateway_port = gateway.rsplit(":", 1)

    sock = connect_gateway((gateway_host, int(gateway_port)))
    send_record(sock, b"H" + ipc_token.encode("ascii"))
    camera = None
    vehicle = None
    last_applied = None
    latest_frame = queue.Queue(maxsize=1)
    commands = queue.Queue(maxsize=1)
    state = {"lock": threading.Lock(), "error": None}
    writer_lock = threading.Lock()
    reader = threading.Thread(target=command_reader, args=(sock, commands, state), daemon=True)
    reader.start()

    try:
        report(sock, writer_lock, "Connecting to CARLA at {}:{}".format(host, port))
        client = carla.Client(host, port)
        client.set_timeout(10.0)
        world = client.get_world()
        vehicle = spawn_vehicle(world, blueprint_name)

        camera_bp = world.get_blueprint_library().find("sensor.camera.rgb")
        camera_bp.set_attribute("image_size_x", str(width))
        camera_bp.set_attribute("image_size_y", str(height))
        camera_bp.set_attribute("fov", "90")
        camera_bp.set_attribute("sensor_tick", "0.05")
        camera_transform = carla.Transform(carla.Location(x=1.6, z=1.7))
        camera = world.spawn_actor(camera_bp, camera_transform, attach_to=vehicle)

        def on_image(image):
            # raw_data is a memory view into the callback image; copy it before returning.
            item = (image.frame, image.width, image.height, float(image.timestamp), time.monotonic_ns(), bytes(image.raw_data))
            try:
                latest_frame.put_nowait(item)
            except queue.Full:
                try:
                    latest_frame.get_nowait()
                except queue.Empty:
                    pass
                try:
                    latest_frame.put_nowait(item)
                except queue.Full:
                    pass

        camera.listen(on_image)
        report(sock, writer_lock, "Connected; spawned {} (actor {})".format(blueprint_name, vehicle.id))
        def send_frames():
            while True:
                try:
                    frame_id, frame_width, frame_height, sim_timestamp, received_ns, raw = latest_frame.get(timeout=0.1)
                except queue.Empty:
                    if state["error"] is not None:
                        return
                    continue
                header = struct.pack("!QIIdQ", frame_id, frame_width, frame_height, sim_timestamp, received_ns)
                try:
                    with writer_lock:
                        send_record(sock, b"F" + header + raw)
                except (ConnectionError, OSError) as error:
                    with state["lock"]:
                        state["error"] = str(error)
                    return

        sender = threading.Thread(target=send_frames, daemon=True)
        sender.start()
        armed = False
        last_control_message = time.monotonic()
        last_failsafe = 0.0

        while True:
            with state["lock"]:
                connection_error = state["error"]
            if connection_error is not None:
                raise ConnectionError(connection_error)

            try:
                command = commands.get(timeout=0.01)
                last_control_message = time.monotonic()
                if command.get("shutdown"):
                    apply_control(client, vehicle, 0.0, 0.0, 1.0)
                    armed = False
                    last_applied = (0.0, 0.0, 1.0)
                    break
                next_armed = bool(command.get("armed", False))
                control_tuple = (
                    max(0.0, min(1.0, float(command.get("throttle", 0.0)))),
                    max(-1.0, min(1.0, float(command.get("steer", 0.0)))),
                    max(0.0, min(1.0, float(command.get("brake", 1.0)))),
                )
                if next_armed:
                    apply_control(client, vehicle, *control_tuple)
                    armed = True
                    last_applied = control_tuple
                else:
                    apply_control(client, vehicle, 0.0, 0.0, 1.0)
                    armed = False
                    last_applied = (0.0, 0.0, 1.0)
            except queue.Empty:
                pass

            now = time.monotonic()
            if armed and now - last_control_message > FAILSAFE_AFTER_S:
                apply_control(client, vehicle, 0.0, 0.0, 1.0)
                armed = False
                last_applied = (0.0, 0.0, 1.0)
                report_disarmed(sock, writer_lock, "Control timed out; brake command submitted. Re-arm from the browser to drive.")
                last_failsafe = now
            elif not armed and now - last_failsafe > 1.0 and last_applied != (0.0, 0.0, 1.0):
                apply_control(client, vehicle, 0.0, 0.0, 1.0)
                last_applied = (0.0, 0.0, 1.0)
                last_failsafe = now

    finally:
        try:
            if vehicle is not None and vehicle.is_alive and last_applied != (0.0, 0.0, 1.0):
                try:
                    apply_control(client, vehicle, 0.0, 0.0, 1.0)
                except Exception:
                    pass
            if camera is not None:
                try:
                    if camera.is_alive:
                        camera.stop()
                except Exception:
                    pass
                try:
                    if camera.is_alive:
                        camera.destroy()
                except Exception:
                    pass
            if vehicle is not None:
                try:
                    if vehicle.is_alive:
                        vehicle.destroy()
                except Exception:
                    pass
        finally:
            try:
                sock.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            sock.close()


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print("CARLA web adapter error: {}".format(error), flush=True)
        raise
