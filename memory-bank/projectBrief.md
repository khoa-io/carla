# Project brief

Port CARLA Simulator **0.9.16** natively to macOS on Apple Silicon. The user's explicit version choice supersedes the earlier UE5 proposal. Use the engine required by this release; investigate native ARM64 engine compatibility rather than substituting Wine, Rosetta, or a VM.

First milestone: reproducible native LibCarla and Python client builds. Full prototype: native simulator, Metal rendering, one vehicle, and synchronized RGB camera delivery to the native Python API. Later gates cover depth, segmentation, LiDAR, radar, stability, packaging, and maintainable automated checks.

Preserve existing Linux/Windows behavior and public simulation/network semantics. Do not claim full native simulator support from client-only builds or static inspection. Record externally blocked work and exact evidence.

User authorized autonomous implementation, waiting for the existing clone, subagent delegation, and persistent Markdown project documentation. No request to commit changes or publish upstream messages/PRs.
