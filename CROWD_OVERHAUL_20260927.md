# Crowd / invasion overhaul — 2026-09-27

Implemented in this build:

- Home and surrounding-fiefdom invasion movement now share the same wall-contact rules.
- Standing walls are hard barriers for outside invaders; crossing occurs only after the authoritative wall collapse flag is set and only through the assigned breach.
- Ranged packets begin firing when their front first enters weapon range; rear ranks join progressively.
- Melee wall and building damage begins with the first contacting ranks rather than waiting for an entire aggregate packet.
- Building contact uses a short body-front reach rather than requiring the packet center to enter the footprint.
- Thousands of persistent lightweight visual crowd agents are stored in packed arrays; no per-soldier Node2D, CharacterBody, or physics object is created.
- Spatial-hash local separation checks neighboring buckets only.
- Crowd agents have stable identity through breach entry, independent position/velocity, velocity smoothing, deterministic lateral flow, obstacle constraints, and per-agent wall/building goals.
- Invader feet are clamped outside intact walls; visual agents are also pushed out of occupied building cells.
- Detailed mobile rendering is one MultiMesh instance per soldier instead of separate body/armor/cloth instances.
- Detailed transforms refresh adaptively rather than being rebuilt every render frame; geometric-shape degradation remains disabled.
- `native/crowd_solver/` contains the tested C++ spatial-hash hot-loop core intended for the platform GDExtension wrapper.

Important runtime note: the platform-specific Godot GDExtension binary is not included in this ZIP. The active runtime uses `view/CrowdPresentation.gd` for the same packed-agent/spatial-hash algorithm. Building/activating the C++ hot loop requires the Godot C++ bindings and a target-platform toolchain (macOS dylib for the macOS editor/export, Windows DLL for Windows, etc.).
