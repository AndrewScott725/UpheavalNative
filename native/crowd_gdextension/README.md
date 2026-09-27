# Upheaval native crowd GDExtension

This is the Godot-native bridge for the packed crowd solver. `UpheavalCrowdSolver.step_packed()` performs spatial hashing, nearby-agent separation, steering, velocity integration, and position integration in C++ in one bulk call. There is no Node2D/CharacterBody per soldier.

`CrowdPresentation.gd` detects `UpheavalCrowdSolver` with `ClassDB.class_exists()` and routes the expensive neighbor-processing hot loop through this extension. Wall/building clamping remains an O(N) presentation pass in GDScript because those constraints depend on current rendered castle geometry.

## macOS / Godot 4.7.2

This package is configured for the user's Godot 4.7.2 installation. Double-click `BUILD_MAC.command` (or run it from Terminal) on the Mac that runs Godot. The script:

1. verifies Apple Command Line Tools, Git, Python 3, and SCons;
2. downloads a fresh current `godot-cpp`;
3. builds universal macOS debug and release libraries with `api_version=4.7`;
4. verifies both `.dylib` files exist; and
5. activates `upheaval_crowd.gdextension` only after the build succeeds.

After it completes, fully quit and reopen Godot 4.7.2. The Output panel should print:

`Upheaval crowd backend: native C++ spatial hash`

If it prints the GDScript fallback instead, the native extension did not load and the Godot Output/error text should be used to diagnose the load failure.
