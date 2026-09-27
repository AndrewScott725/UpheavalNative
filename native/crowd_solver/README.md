# Upheaval native crowd solver core

This directory contains the allocation-light C++ hot loop for the next GDExtension build of Upheaval's crowd presentation. It uses packed agent records plus an intrusive spatial hash (one linked-list index per agent) so each agent only examines neighboring cells.

The current prototype deliberately keeps `view/CrowdPresentation.gd` as a functional fallback because a Godot GDExtension binary is platform-specific and must be linked against the Godot C++ bindings for the target editor/export platform. The C++ core here has no Godot dependency, so it can be unit-tested separately and wrapped without changing the algorithm.

Do **not** add thousands of Node2D/CharacterBody instances. The wrapper should retain native arrays between calls and expose bulk sync/readback methods rather than making one GDScript call per soldier.
