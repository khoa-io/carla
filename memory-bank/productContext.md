# Product context

Researchers should be able to develop and run CARLA on Apple Silicon directly, using the usual Python API and sensor interfaces. Native libraries and reproducible instructions should reduce compatibility-layer setup and make failures diagnosable.

A native client is independently useful with a matching remote CARLA server. A native simulator must additionally prove Metal sensor readback, frame/timestamp association, simulation behavior, and packaged startup. Performance improvements require measurements.
