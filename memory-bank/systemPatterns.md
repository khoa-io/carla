# System patterns

- CARLA 0.9.16 uses the classic Makefile/`Util/BuildTools` flow, `LibCarla`, `PythonAPI`, and `Unreal/CarlaUE4`. Its README identifies Unreal Engine 4.26. Do not apply the UE5 root CMake architecture to this release.
- Prove dependencies/client/Python independently of Unreal where possible, then integrate server and rendering. Keep optional integrations outside the initial build.
- Keep platform/compiler adaptation separate from driving and sensor semantics. Prefer target-scoped build settings and standard platform abstractions.
- Build every linked native dependency for ARM64 with compatible deployment targets and ABI. Never silently consume Intel binaries.
- The Buffer API keeps its original uint32/uint64 overloads; constrained integral forwarding handles Darwin's distinct size_t type without per-call casts. Internal/wire size remains uint32 and larger sizes retain checked rejection.
- MessagePack variant sequence templates use std::size_t to match std::index_sequence, while wire indices remain uint64. Waypoint hashing uses a std::size_t local seed for Boost without changing the public result type.
- Record claims as proposed, source-inspected, built, or runtime-validated. Evidence gates matter more than screenshots.
- Parent owns memory bank and shared documentation. Assign agents distinct source areas to avoid overlapping edits; review their changes before integration.
- Native engine tooling uses SDK-style .NET 8 projects and the existing NET_CORE source branches, with NATIVE_DOTNET process-launch adaptations. Child metadata actions execute the native apphost, not the managed DLL as an executable. Export DOTNET_ROOT for child processes.
- The native tooling build selects the host architecture for automatically rebuilt tools. Explicit ARM64 game/editor arguments alone do not prevent legacy UBT from rebuilding Intel UHT.
- Keep engine changes as reproducible patches under Util/BuildTools/EnginePatches. Preserve source defaults unless an explicit native build path selects the adaptation; editor blacklist bypass requires CARLA_MACOS_ENABLE_EXPERIMENTAL_EDITOR=1.
- Full editor linking needs a universal FBX SDK override rather than the bundled Intel-only binary. Keep its headers and dylib version matched and preserve vendor license/readme; do not replace physics with Chaos or change CARLA release.
- The engine links its Mac modules with dynamic lookup, so a module that is loaded with local visibility cannot satisfy the cross module references of the modules that follow it. The Mac loader therefore publishes the module symbols globally, as the Linux loader does.
- The UE4.26 Mac RHI has no thread safe mapping of a readback staging surface, so the camera readback has to be locked on the rendering thread. The native port moves the lock into a render command and keeps the GPU wait off the render thread.
- The ARM hardware reciprocal estimates are less precise than the SSE ones, so the engine's own math smoke test is calibrated per platform. Relaxing a test tolerance is preferable to changing the math that the renderer uses.
- A case-sensitive volume makes the engine's file name expectations visible: the PhysX redistributables ship `libApexFrameworkPROFILE.dylib` while the engine asks for `libAPEXFrameworkPROFILE.dylib`. The build creates the aliases instead of changing the engine.
- The Unreal header tool is built for the host architecture. The host architecture detection may not use `sysctl`, because a restricted environment denies it and the engine would silently fall back to Intel.
