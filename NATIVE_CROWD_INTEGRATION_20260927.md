# Native crowd integration — 2026-09-27

This build stops treating the DINO-style crowd solver as a GDScript-only experiment.

## Runtime architecture

Authoritative combat remains packetized/deterministic in `sim/`. Visual soldiers remain packed records in `view/CrowdPresentation.gd`; there are still no per-soldier Nodes or physics bodies.

The expensive local crowd step now has a native C++ backend in `native/crowd_gdextension/`:

- intrusive spatial hash
- neighboring-cell lookup only
- capped neighbor separation
- desired-velocity steering
- smoothing and speed limiting
- position integration
- persistent C++ scratch storage
- one bulk GDScript → C++ call per crowd presentation step

The O(N) wall/building constraint pass stays in GDScript because it depends directly on the rendered castle geometry. The O(N × nearby-neighbor) hot loop is what moves native.

`CrowdPresentation.gd` detects the native class `UpheavalCrowdSolver`. If present it uses C++; otherwise it emits a warning and retains the old solver only as a compatibility fallback.

## macOS activation

A GDExtension is a platform-native binary and cannot be produced for macOS from the Linux build environment used to prepare this ZIP. The complete extension source and build configuration are included. On the Mac that runs Godot, double-click/run:

`native/crowd_gdextension/BUILD_MAC.command`

This package is now configured for Godot 4.7.2. `BUILD_MAC.command` downloads a fresh `godot-cpp`, targets `api_version=4.7`, builds universal debug/release dylibs, verifies them, and activates `upheaval_crowd.gdextension`. Fully quit and reopen Godot 4.7.2. The Output panel will print:

`Upheaval crowd backend: native C++ spatial hash`

If the binary is absent, the Output panel explicitly warns that the GDScript fallback is active; there is no silent claim that native code is running.

## Native-core benchmark in the build environment

The engine-independent C++ core was compiled with `-O3` and tested with 10,000 agents. 120 crowd steps completed in roughly 0.34 seconds total on this build host (~2.8 ms/step). This excludes Godot packed-array bridge copies and rendering, so the in-game number will differ, but it validates the intended scale of the hot loop.
