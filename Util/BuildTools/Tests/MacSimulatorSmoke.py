import argparse
import json
import platform
import queue
import time

import carla


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=2000)
    parser.add_argument("--frames", type=int, default=10)
    parser.add_argument("--vehicle", default="vehicle.tesla.model3")
    parser.add_argument("--width", type=int, default=321)
    parser.add_argument("--height", type=int, default=241)
    parser.add_argument("--sensors", default="rgb")
    parser.add_argument("--output")
    arguments = parser.parse_args()
    if platform.system() != "Darwin" or platform.machine() != "arm64":
        raise RuntimeError("Run this acceptance test with native Apple Silicon Python")
    if arguments.frames < 2:
        raise ValueError("At least two synchronized frames are required")
    if arguments.width < 1 or arguments.height < 1:
        raise ValueError("Image dimensions must be positive")
    sensor_types = {
        "rgb": ("sensor.camera.rgb", "camera"),
        "depth": ("sensor.camera.depth", "camera"),
        "semantic": ("sensor.camera.semantic_segmentation", "camera"),
        "lidar": ("sensor.lidar.ray_cast", "lidar"),
        "radar": ("sensor.other.radar", "radar"),
    }
    sensor_names = [name.strip() for name in arguments.sensors.split(",") if name.strip()]
    if not sensor_names or len(set(sensor_names)) != len(sensor_names):
        raise ValueError("At least one unique camera sensor is required")
    unsupported = set(sensor_names) - set(sensor_types)
    if unsupported:
        raise ValueError("Unsupported camera sensor(s): " + ", ".join(sorted(unsupported)))

    client = carla.Client(arguments.host, arguments.port)
    client.set_timeout(60.0)
    if client.get_client_version() != "0.9.16" or client.get_server_version() != "0.9.16":
        raise RuntimeError("Both client and server must report CARLA 0.9.16")
    world = client.get_world()
    original_settings = world.get_settings()
    settings = world.get_settings()
    settings.synchronous_mode = True
    settings.fixed_delta_seconds = 0.05
    settings.no_rendering_mode = False
    vehicle = None
    cameras = []
    received_frames = {name: queue.Queue() for name in sensor_names}
    frame_numbers = []
    timestamps = []
    started = time.monotonic()
    try:
        world.apply_settings(settings)
        library = world.get_blueprint_library()
        vehicle_blueprint = library.find(arguments.vehicle)
        spawn_points = world.get_map().get_spawn_points()
        if not spawn_points:
            spawn_points = [carla.Transform(carla.Location(z=2.0))]
        for transform in spawn_points:
            vehicle = world.try_spawn_actor(vehicle_blueprint, transform)
            if vehicle is not None:
                break
        if vehicle is None:
            raise RuntimeError("Could not spawn the test vehicle")

        for sensor_name in sensor_names:
            sensor_blueprint = library.find(sensor_types[sensor_name][0])
            if sensor_types[sensor_name][1] == "camera":
                sensor_blueprint.set_attribute("image_size_x", str(arguments.width))
                sensor_blueprint.set_attribute("image_size_y", str(arguments.height))
                transform = carla.Transform(carla.Location(x=1.5, z=2.4), carla.Rotation(pitch=-12))
            elif sensor_types[sensor_name][1] == "lidar":
                sensor_blueprint.set_attribute("channels", "32")
                sensor_blueprint.set_attribute("points_per_second", "32000")
                sensor_blueprint.set_attribute("rotation_frequency", "20.0")
                sensor_blueprint.set_attribute("range", "50.0")
                transform = carla.Transform(carla.Location(z=2.2))
            else:
                sensor_blueprint.set_attribute("horizontal_fov", "35.0")
                sensor_blueprint.set_attribute("vertical_fov", "20.0")
                sensor_blueprint.set_attribute("points_per_second", "1500")
                transform = carla.Transform(carla.Location(x=1.5, z=1.0))
            sensor_blueprint.set_attribute("sensor_tick", "0.0")
            camera = world.spawn_actor(
                sensor_blueprint,
                transform,
                attach_to=vehicle,
            )
            cameras.append((sensor_name, camera))
            camera.listen(received_frames[sensor_name].put)
        for index in range(arguments.frames + 5):
            frame_number = world.tick(60.0)
            images = {}
            for sensor_name, frames in received_frames.items():
                image = frames.get(timeout=60.0)
                while image.frame < frame_number:
                    image = frames.get(timeout=60.0)
                if image.frame != frame_number:
                    raise RuntimeError(sensor_name + " camera and world frame numbers do not match")
                sensor_kind = sensor_types[sensor_name][1]
                if sensor_kind == "camera":
                    if (image.width != arguments.width or image.height != arguments.height
                            or len(image.raw_data) != arguments.width * arguments.height * 4):
                        raise RuntimeError("Invalid " + sensor_name + " camera payload")
                elif sensor_kind == "lidar":
                    if len(image.raw_data) == 0 or len(image.raw_data) % 16:
                        raise RuntimeError("Invalid or empty LiDAR point payload")
                elif len(image) == 0:
                    raise RuntimeError("Radar returned no detections")
                images[sensor_name] = image
            image = images.get("rgb", next(iter(images.values())))
            for sensor_name, sensor_image in images.items():
                if abs(sensor_image.timestamp - image.timestamp) > 1e-5:
                    raise RuntimeError(sensor_name + " timestamp does not match for frame " + str(frame_number))
            if index >= 5:
                for sensor_name, sensor_image in images.items():
                    if sensor_types[sensor_name][1] != "camera":
                        continue
                    raw_data = bytes(sensor_image.raw_data)
                    if len({raw_data[offset:offset + 4] for offset in range(0, len(raw_data), 4)}) < 2:
                        raise RuntimeError(sensor_name + " frame is uniform; rendering/readback needs investigation")
                frame_numbers.append(image.frame)
                timestamps.append(image.timestamp)
        if any(second != first + 1 for first, second in zip(frame_numbers, frame_numbers[1:])):
            raise RuntimeError("Synchronized camera frames were dropped")
        if any(abs(second - first - 0.05) > 1e-5 for first, second in zip(timestamps, timestamps[1:])):
            raise RuntimeError("Sensor timestamps do not match the fixed simulation step")
        if arguments.output:
            image.save_to_disk(arguments.output)
        print(json.dumps({
            "status": "passed",
            "client_extension": carla.libcarla.__file__,
            "server_version": client.get_server_version(),
            "map": world.get_map().name,
            "vehicle": vehicle.type_id,
            "sensors": sensor_names,
            "frames": frame_numbers,
            "timestamps": timestamps,
            "resolution": [arguments.width, arguments.height],
            "image_path": arguments.output,
            "elapsed_seconds": time.monotonic() - started,
        }, indent=2))
    finally:
        for _, camera in cameras:
            camera.stop()
            camera.destroy()
        if vehicle is not None:
            vehicle.destroy()
        world.apply_settings(original_settings)


if __name__ == "__main__":
    main()
