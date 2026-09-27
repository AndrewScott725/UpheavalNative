#include "crowd_solver_core.h"
#include <algorithm>
#include <cmath>

namespace upheaval {

static inline float len2(float x, float y) noexcept { return x*x + y*y; }

void CrowdSolverCore::reserve(std::size_t n) {
    agents_.reserve(n);
    next_.reserve(n);
    heads_.reserve(n / 3 + 64);
}

void CrowdSolverCore::resize(std::size_t n) {
    agents_.resize(n);
    next_.resize(n, -1);
}

void CrowdSolverCore::step(float dt) {
    if (agents_.empty()) return;
    dt = std::clamp(dt, 0.005f, 0.10f);
    if (next_.size() != agents_.size()) next_.resize(agents_.size(), -1);
    std::fill(next_.begin(), next_.end(), -1);
    heads_.clear();

    // Intrusive linked buckets: one hash entry per occupied cell, no Array/List
    // allocation per bucket and no O(N^2) neighbor scan.
    for (int i = 0; i < static_cast<int>(agents_.size()); ++i) {
        auto &a = agents_[i];
        if (!a.active) continue;
        CellKey c{static_cast<int>(std::floor(a.x / hash_cell_)),
                  static_cast<int>(std::floor(a.y / hash_cell_))};
        auto it = heads_.find(c);
        next_[i] = (it == heads_.end()) ? -1 : it->second;
        heads_[c] = i;
    }

    for (int i = 0; i < static_cast<int>(agents_.size()); ++i) {
        auto &a = agents_[i];
        if (!a.active) continue;

        float dxg = a.gx - a.x, dyg = a.gy - a.y;
        float gd2 = len2(dxg, dyg);
        float desired_x = 0.0f, desired_y = 0.0f;
        if (gd2 > 0.25f) {
            float inv = 1.0f / std::sqrt(gd2);
            desired_x = dxg * inv * a.max_speed;
            desired_y = dyg * inv * a.max_speed;
        }

        const int cx = static_cast<int>(std::floor(a.x / hash_cell_));
        const int cy = static_cast<int>(std::floor(a.y / hash_cell_));
        float sx = 0.0f, sy = 0.0f;
        int found = 0;
        const float min_sep = a.radius * 2.0f;
        const float min_sep2 = min_sep * min_sep;

        for (int oy = -1; oy <= 1 && found < max_neighbors_; ++oy) {
            for (int ox = -1; ox <= 1 && found < max_neighbors_; ++ox) {
                auto hit = heads_.find(CellKey{cx + ox, cy + oy});
                if (hit == heads_.end()) continue;
                for (int j = hit->second; j >= 0 && found < max_neighbors_; j = next_[j]) {
                    if (j == i || !agents_[j].active) continue;
                    float rx = a.x - agents_[j].x, ry = a.y - agents_[j].y;
                    float d2 = len2(rx, ry);
                    if (d2 <= 0.0001f || d2 >= min_sep2) continue;
                    float d = std::sqrt(d2);
                    float w = (min_sep - d) / min_sep;
                    sx += (rx / d) * w;
                    sy += (ry / d) * w;
                    ++found;
                }
            }
        }
        if (found > 0) {
            sx /= static_cast<float>(found);
            sy /= static_cast<float>(found);
            desired_x += sx * a.max_speed * 2.2f;
            desired_y += sy * a.max_speed * 2.2f;
            // Stable handedness breaks perfect columns without RNG in the hot loop.
            float hand = (a.seed & 1u) ? 1.0f : -1.0f;
            float mag = std::sqrt(sx*sx + sy*sy);
            float dl = std::sqrt(desired_x*desired_x + desired_y*desired_y);
            if (dl > 0.001f) {
                desired_x += (-desired_y / dl) * hand * mag * a.max_speed * 0.22f;
                desired_y += ( desired_x / dl) * hand * mag * a.max_speed * 0.22f;
            }
        }

        a.vx += (desired_x - a.vx) * 0.38f;
        a.vy += (desired_y - a.vy) * 0.38f;
        float v2 = len2(a.vx, a.vy);
        const float vmax = a.max_speed * 1.25f;
        if (v2 > vmax*vmax) {
            float inv = vmax / std::sqrt(v2);
            a.vx *= inv; a.vy *= inv;
        }
        a.x += a.vx * dt;
        a.y += a.vy * dt;
    }
}

} // namespace upheaval
