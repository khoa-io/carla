# Native Apple Silicon build of CARLA 0.9.16

This work targets CARLA **0.9.16** (`294096eb1c38eabf246e4f3a9cdab704e33a7f4c`), which uses Unreal Engine 4.26. It provides two native ARM64 artifacts on macOS:

- the **client library and Python wheel** (`carla-0.9.16-cp311-cp311-macosx_12_0_arm64.whl`), and
- the **native simulator**: the CARLA game and editor targets of the pinned UE4.26.2 fork, built for arm64 with the Metal renderer, which host the CARLA server, spawn vehicles and render the camera sensors.

The native simulator prototype has been validated end to end on Apple Silicon: the ARM64 server loads a map, spawns a vehicle over RPC, and streams synchronized RGB, depth, semantic segmentation, LiDAR and radar data to the native Python client. See [the engine audit](macos_engine_audit.md) for the engine prerequisites, platform adaptations and remaining productization work. The UE5 build procedure does not apply to this release.

## Prerequisites

- Apple Silicon macOS, running tools natively as `arm64`.
- Xcode command-line tools, CMake, Ninja, curl, and SHA-256 utilities.
- Native CPython 3.9 through 3.12; Python 3.11 is the initial validation interpreter. This range is an accepted build configuration, not a tested interpreter matrix.
- Network access for the pinned dependency archives on the first build.

The helper compiles workspace-local Boost 1.84, rpclib, Recast/Detour, and libpng. SDK zlib provides compression. It does not invoke CARLA's Linux setup script or require Unreal for the client.

The initial dependency/client deployment target is macOS 12.0, configurable through `MACOSX_DEPLOYMENT_TARGET`. This is a compiler/linker target, not certification that the port runs on every OS at or above that version. Every static input and the extension must agree on a compatible minimum. Rebuild the dependency directory when changing toolchain, deployment target, or Python ABI; do not reuse incompatible archives.

## Build a Python wheel

Run from the CARLA repository root, using a native Python interpreter:

```sh
python3.11 -m venv Build/macos/venv
Build/macos/venv/bin/python -m pip install 'numpy<2' build distro packaging setuptools wheel
export MACOSX_DEPLOYMENT_TARGET=12.0
make PythonAPI.wheel PYTHON="$PWD/Build/macos/venv/bin/python" MACOS_ARGS="--jobs 4"
```

Supply an absolute interpreter path because the packaging command changes directory. `make LibCarla.client` builds/stages only the client and dependencies. `make setup` prepares the native third-party dependencies. `make help` lists the macOS targets. Configure concurrency to suit available memory.

Build outputs are under `Build/macos-arm64/`, staged libraries/headers under `PythonAPI/carla/dependencies/`, and wheels under `PythonAPI/carla/dist/`. These are local build products. The helper pins source archives with SHA-256 checks; record the Xcode, SDK, Python, deployment target, and artifact hashes alongside a release.

The helper records its toolchain/dependency configuration and rejects incompatible cache reuse. After changing the SDK, compiler, Python ABI, or deployment target, use `MACOS_ARGS="--jobs 4 --rebuild"` to rebuild generated binaries while preserving downloaded source archives. Run only one helper instance per checkout. A fresh Python extension compilation is forced so changed feature/deployment flags cannot silently reuse old object files.

Install the emitted wheel into a fresh native environment before testing. For example, after verifying the directory contains only the intended wheel:

```sh
python3.11 -m venv Build/macos/verify
Build/macos/verify/bin/python -m pip install 'numpy<2' PythonAPI/carla/dist/carla-*.whl
Build/macos/verify/bin/python -c 'import carla, platform; print(platform.machine(), carla.__file__); print(carla.Client("127.0.0.1", 2000).get_client_version())'
make check.PythonAPI PYTHON="$PWD/Build/macos/verify/bin/python"
```

The check target runs the existing transform and vehicle unit suites without a simulator. It does not run integration/smoke tests. The release client version is checked separately; the upstream `test_client.py` expects a Git short-hash version and does not match a release-tag build.

`make check.LibCarla PYTHON=/absolute/path/to/python3.11` additionally compiles a native C++ executable and checks the client's version RPC and timeout behavior against a local rpclib fixture. It uses TCP port 42916 by default (`MACOS_SMOKE_PORT` overrides it). This requires permission to open a loopback socket and does not replace real simulator interoperability testing.

Use `file`, `lipo -archs`, `otool -L`, and `otool -l` on the installed extension and linked archives to inspect architecture, runtime dependencies, and deployment targets. A correctly named wheel is insufficient evidence of a native or portable build. A fresh environment should import the wheel from outside the checkout without using developer library paths.

## Initial feature coverage

The default native wheel provides core CARLA client, geometry, actor, traffic, and sensor interfaces. PNG image output is enabled. JPEG/TIFF encoding and the optional RSS variant are not part of this bootstrap.

SUMO/OpenStreetMap conversion (`Osm2Odr` and `Osm2OdrSettings`) is omitted by default on macOS. `CARLA_BUILD_OSM2ODR=true` enables its bindings only after native `osm2odr`, Xerces-C, PROJ, and SQLite libraries have been built/staged separately. The client helper does not build these optional libraries. Core CARLA map and OpenDRIVE APIs do not require the optional converter.

Linux and Windows retain their existing build paths and default feature selection. Native ROS 2 integration, PyTorch/CUDA extensions, Chrono, CarSim, and SimReady require separate ports.

## Build the native simulator

The simulator is built from the pinned UE4.26.2 fork of the CARLA engine, which is
cloned into `Build/macos-engine/source` and patched with the reproducible patches in
`Util/BuildTools/EnginePatches`. The helpers below build the native editor, the
native game target and the engine programs, and they keep every cache and intermediate
inside `Build/`:

```sh
# The engine, its native dependencies, the shaders and the CARLA editor target.
bash Util/BuildTools/MacBuildEditor.sh --jobs 6

# The engine programs, for example the shader compiler.
bash Util/BuildTools/MacBuildEngineProgram.sh --program ShaderCompileWorker --jobs 6

# The standalone native CARLA game target.
bash Util/BuildTools/MacBuildGame.sh --jobs 6
```

The game target produces `Unreal/CarlaUE4/Binaries/Mac/CarlaUE4.app`, an arm64
Mach-O executable. It resolves the project and the engine content relative to
its own directory, so it needs the content layout that the packaging step
produces. Until the content is cooked for macOS, the validated native simulator
is the editor build in game mode, which loads the uncooked source content of the
release.

`MacBuildEditor.sh` applies the engine patches, builds the pinned native third-party
libraries (NVIDIA Texture Tools, squish, SpeedTree, HLSLCC, glslang, ShaderConductor and
DXC), selects the universal Autodesk FBX SDK through `CARLA_MACOS_FBX_SDK` and finally
compiles `CarlaUE4Editor` for arm64. The patches, and the reasons for them, are listed
in `Util/BuildTools/EnginePatches/README.md`.

Two build inputs are not part of the repository:

- the pinned engine itself (`Build/macos-engine/source`, commit
  `e9d9e60c85f643e10eeb03f42f61554d18dcb30f`), which is fetched with the credentials of
  the CARLA organisation, and
- the 0.9.16 source content, which `make setup.assets` installs into
  `Unreal/CarlaUE4/Content/Carla`.

## Run the native simulator and the acceptance test

`MacRunSimulator.sh` starts the native server, waits until it answers an RPC request,
runs the native Python acceptance test and stops the server again:

```sh
bash Util/BuildTools/MacRunSimulator.sh --map /Game/Carla/Maps/Town02_Opt
```

The helper starts `UE4Editor-Cmd` with the CARLA project in game mode, which starts
the CARLA server on the RPC port 2000 and the streaming port 2001. `-GAME` has to stay
upper case: the engine only leaves the editor mode for a capitalised switch, and
`-SERVER` would select the null renderer, which cannot produce camera images. The
first start of a map compiles its shaders and builds its textures, which takes a
while; the results are cached in the derived data cache.

The acceptance test is `Util/BuildTools/Tests/MacSimulatorSmoke.py`. It connects with
the native wheel, checks the client and server versions, spawns a vehicle, and verifies
that each selected sensor reports the same world frame and simulation timestamp.
The default is RGB; pass `--sensors rgb,depth,semantic,lidar,radar` to exercise the
five core sensor paths together. Camera payloads are checked for dimensions and
nonuniform pixels; LiDAR payloads must contain points and radar must report detections.
The RGB image is written to `Build/macos-engine/simulator-frame.png` by default.

The helper waits for a world request instead of the version request, because the first
start of a map compiles its shaders and builds its textures, which takes a while.

## Validate against a simulator

Use a CARLA 0.9.16 server with matching protocol/assets. Set an explicit host/port and timeout; verify both versions before controlling the world. Exercise world inspection, actor creation/destruction, reconnects, fixed-step synchronous simulation, and sensor streaming. Restore the world's original settings and destroy test actors even on failure.

A native client connected to a Linux/Windows server is useful interoperability evidence, but is not a native macOS simulator. A local RPC fixture can validate transport and serialization without establishing engine, physics, or sensor correctness.

## Current validation

The build passed on ARM64 macOS 27.0.1 with Xcode 27.1, CMake 3.31.12, Ninja 1.13.2, and Python 3.11.17. The native wheel installs/imports in a clean environment outside the checkout. All 11 existing transform tests and 3 vehicle tests passed, as did the C++ buffer/variant serialization and RPC/timeout fixture. Both macOS Make check targets were exercised successfully.

The installed extension is ARM64 with minimum OS metadata 12.0 and only system zlib/libc++/libSystem dynamic dependencies.

The native simulator acceptance test passed on the native server. It reported version 0.9.16 on `Carla/Maps/Town02_Opt`, spawned `vehicle.tesla.model3`, and received six consecutive synchronized frames from RGB, depth, semantic segmentation, LiDAR, and radar at the fixed 0.05 s step. Camera images were nonuniform; LiDAR returned points and radar returned detections. The run used 321x241 camera images and wrote `Build/macos-engine/simulator-all-sensors-rgb.png`.

Still unvalidated: older macOS versions, other Python minors, full Linux/Windows builds, and the cooked/packaged distribution. The sensor smoke checks establish data delivery and frame/timestamp alignment, not analytic accuracy against reference scenes.

## Remaining simulator work

1. Cook the CARLA content for macOS and package a redistributable simulator, so the server no longer depends on the uncooked source assets.
2. Compare sensor outputs with analytic fixtures, including known camera labels/depths and LiDAR/radar geometry.
3. Extend the timing and stability validation to larger maps and longer runs.
4. Certify the deployment target on older macOS versions.

The macOS `launch`, `CarlaUE4Editor`, and `package` Make targets still fail with an explanation instead of executing the Linux scripts; use the helpers below for the native paths.
# Native engine work in progress

The client milestone is validated independently of the simulator. Native server
dependencies and PhysX now have executable smoke tests:

```sh
make check.LibCarla.server MACOS_ARGS="--jobs 6"
make check.PhysX
make check.Metal
```

The experimental editor command is `bash Util/BuildTools/MacBuildEditor.sh`.
It requires the pinned engine checkout from `Docs/macos_engine_audit.md`,
Mac/common manifest dependencies, and `Engine/Programs`, `Engine/Content`,
`Engine/Source`, `Engine/Build`, `Engine/Config`, `Engine/Plugins`, and
`Engine/Shaders` materialized in that checkout. It bootstraps native .NET 8,
applies the checked-in engine patches, and disables optional unsupported
Perforce, Python editor scripting, hair import, RenderDoc, MDL and SimReady
plugins. The native CARLA Python API remains enabled separately.
Native engine dependency sources are built by `MacBuildEngineLibraries.sh`;
this includes the engine's Unreal-specific MCPP callback API, not an upstream
replacement. `MacBuildShaderConductor.sh` builds native ShaderConductor/DXC;
its original engine dylibs are Intel-only. Both shader frontends and native
LLVM table-generation programs must be built before camera shader validation.
Native Metal's `mtlpp` wrapper is rebuilt with RTTI to match CARLA's engine
settings. The Intel-only Embree 2 editor mesh optimization is disabled on ARM64,
using the existing non-Embree path instead; this does not replace PhysX.

`make setup.assets` installs the exact 0.9.16 source-content archive
`20250912_2171890`. It verifies SHA256, checks space for its 23.4 GiB expansion
plus a 15 GiB reserve, extracts into staging, and refuses to overwrite
unidentified existing content. The compressed download is approximately 20.1 GiB.

The command installs the source content of the release, which the native simulator
loads; it is not a packaged distribution, because the content is not cooked for macOS.
The engine's bundled FBX SDK is Intel-only. The development build uses Autodesk's
universal FBX SDK 2020.3.9 in `Build/macos-engine/fbx-sdk`, selected by
`CARLA_MACOS_FBX_SDK`. Obtain it from the [official Autodesk FBX SDK downloads](https://aps.autodesk.com/developer/overview/fbx-sdk),
retain its license/readme, and review its terms before use. The package tested
here is `fbx202039_fbxsdk_clang_mac.pkg.tgz`, SHA256
`c2bd9e9882c87368691e546a6ee8676646c81192c178150ac53f7bb3ac04262a`.
`pkgutil --expand-full` can extract the package into the build workspace without
running its installer. Use the extracted `2020.3.9` directory as the SDK root.

Xcode's Metal compiler must be installed (`xcodebuild -downloadComponent MetalToolchain`
on the development host). Review that command's installation behavior before
running it on another machine.
