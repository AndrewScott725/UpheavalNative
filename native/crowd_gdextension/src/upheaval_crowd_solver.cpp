#include "upheaval_crowd_solver.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/string.hpp>

using namespace godot;

void UpheavalCrowdSolver::_bind_methods() {
    ClassDB::bind_method(D_METHOD(
        "step_packed",
        "positions", "velocities", "goals", "active_indices", "seeds", "max_speeds",
        "personal_radius", "dt", "hash_cell", "max_neighbors"),
        &UpheavalCrowdSolver::step_packed);
    ClassDB::bind_method(D_METHOD("backend_name"), &UpheavalCrowdSolver::backend_name);
}

Array UpheavalCrowdSolver::step_packed(
    const PackedVector2Array &p_positions,
    const PackedVector2Array &p_velocities,
    const PackedVector2Array &p_goals,
    const PackedInt32Array &p_active_indices,
    const PackedInt32Array &p_seeds,
    const PackedFloat32Array &p_max_speeds,
    double p_personal_radius,
    double p_dt,
    double p_hash_cell,
    int32_t p_max_neighbors) {

    PackedVector2Array out_positions = p_positions;
    PackedVector2Array out_velocities = p_velocities;
    Array result;

    const int64_t active_count = p_active_indices.size();
    if (active_count <= 0) {
        result.append(out_positions);
        result.append(out_velocities);
        return result;
    }

    core_.resize(static_cast<std::size_t>(active_count));
    core_.set_hash_cell(static_cast<float>(p_hash_cell));
    core_.set_max_neighbors(p_max_neighbors);

    for (int64_t local_i = 0; local_i < active_count; ++local_i) {
        const int32_t source_i = p_active_indices[local_i];
        auto &a = core_.agent(static_cast<std::size_t>(local_i));
        if (source_i < 0 || source_i >= p_positions.size() ||
            source_i >= p_velocities.size() || source_i >= p_goals.size()) {
            a.active = 0;
            continue;
        }
        const Vector2 p = p_positions[source_i];
        const Vector2 v = p_velocities[source_i];
        const Vector2 g = p_goals[source_i];
        a.x = p.x; a.y = p.y;
        a.vx = v.x; a.vy = v.y;
        a.gx = g.x; a.gy = g.y;
        a.radius = static_cast<float>(p_personal_radius);
        a.max_speed = (source_i < p_max_speeds.size()) ? p_max_speeds[source_i] : 55.0f;
        a.seed = (source_i < p_seeds.size()) ? static_cast<std::uint32_t>(p_seeds[source_i]) : 0u;
        a.active = 1;
    }

    core_.step(static_cast<float>(p_dt));

    for (int64_t local_i = 0; local_i < active_count; ++local_i) {
        const int32_t source_i = p_active_indices[local_i];
        if (source_i < 0 || source_i >= out_positions.size() || source_i >= out_velocities.size()) {
            continue;
        }
        const auto &a = core_.agent(static_cast<std::size_t>(local_i));
        if (!a.active) continue;
        out_positions.set(source_i, Vector2(a.x, a.y));
        out_velocities.set(source_i, Vector2(a.vx, a.vy));
    }

    result.append(out_positions);
    result.append(out_velocities);
    return result;
}
