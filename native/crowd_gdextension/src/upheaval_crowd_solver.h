#pragma once

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_vector2_array.hpp>

#include "../../crowd_solver/crowd_solver_core.h"

namespace godot {

class UpheavalCrowdSolver : public RefCounted {
    GDCLASS(UpheavalCrowdSolver, RefCounted)

    upheaval::CrowdSolverCore core_;

protected:
    static void _bind_methods();

public:
    UpheavalCrowdSolver() = default;
    ~UpheavalCrowdSolver() = default;

    // Bulk bridge: GDScript submits packed arrays once per presentation step.
    // Only indices in active_indices are copied into the native hot loop.
    // The return Array is [PackedVector2Array positions, PackedVector2Array velocities].
    Array step_packed(
        const PackedVector2Array &positions,
        const PackedVector2Array &velocities,
        const PackedVector2Array &goals,
        const PackedInt32Array &active_indices,
        const PackedInt32Array &seeds,
        const PackedFloat32Array &max_speeds,
        double personal_radius,
        double dt,
        double hash_cell,
        int32_t max_neighbors);

    String backend_name() const { return "native-cpp-spatial-hash"; }
};

} // namespace godot
