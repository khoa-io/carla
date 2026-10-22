# Native macOS engine adaptations

These patches target CARLA's UE4.26.2 fork at
`e9d9e60c85f643e10eeb03f42f61554d18dcb30f`, not UE5. They are applied
idempotently by `MacBuildEngineTools.sh` before compiling the native .NET 8
build tools. The engine repository and its licensed dependencies are not
vendored into CARLA.

`tooling/` contains .NET project definitions, process/runtime adaptations,
macOS compiler settings, the explicit experimental native editor opt-in, and
ARM64 third-party library selection/build changes. `runtime/` contains narrow
modern compiler and case-sensitive filesystem compatibility fixes.

`native-libraries/` builds pinned engine dependency sources. MCPP's original
autoconf inputs are normalized into a generated build copy, leaving engine
sources unchanged; configuration generates the platform header and CMake
compiles the Unreal-specific library API. Intel archives are preserved and
ARM64 outputs are staged separately.

The bundled FBX SDK requires a matching universal replacement selected by
`CARLA_MACOS_FBX_SDK`. Its vendor license applies. See `Docs/build_macos.md` and
the memory bank for the current evidence.

`runtime/0009-native-third-party-arm64.patch` renames the libwebsockets status
enumerators, which collide with the `cups` header on macOS, adds the ARM64 CPU
detection to the pinned NVIDIA Texture Tools sources, selects the ARM64 third
party archives, and disables the two texture formats that only exist as x86_64
binaries. `runtime/0010-allow-case-sensitive-volume.patch` lets the engine start
from a case-sensitive volume. `runtime/0011-native-runtime-fixes.patch` publishes
the module symbols globally, because the engine links its Mac modules with
dynamic lookup, and tolerates the less precise ARM hardware reciprocals in the
engine's own math smoke test. `runtime/0012-mesh-degenerate-triangles.patch`
keeps the degenerate triangles of a reduced mesh from aborting the editor.
`tooling/0015-host-architecture-detection.patch` detects the host architecture
without `sysctl`, so that the Unreal header tool is built for the native
architecture in a restricted environment.

The native editor target links and the native CARLA server runs; the camera
sensor was validated with the native Python client. See `Docs/build_macos.md`.
