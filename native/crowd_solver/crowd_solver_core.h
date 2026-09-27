#pragma once
#include <cstdint>
#include <vector>
#include <unordered_map>

namespace upheaval {

struct CrowdAgent {
    float x = 0.0f, y = 0.0f;
    float vx = 0.0f, vy = 0.0f;
    float gx = 0.0f, gy = 0.0f;
    float radius = 12.0f;
    float max_speed = 55.0f;
    std::uint32_t seed = 0;
    std::uint8_t active = 1;
};

// Engine-independent hot loop used by the planned Godot GDExtension wrapper.
// It intentionally owns all per-frame scratch storage so a step performs no
// per-agent heap allocation after reserve().
class CrowdSolverCore {
public:
    void reserve(std::size_t n);
    void resize(std::size_t n);
    std::size_t size() const noexcept { return agents_.size(); }
    CrowdAgent &agent(std::size_t i) noexcept { return agents_[i]; }
    const CrowdAgent &agent(std::size_t i) const noexcept { return agents_[i]; }

    void set_hash_cell(float px) noexcept { hash_cell_ = px > 4.0f ? px : 4.0f; }
    void set_max_neighbors(int n) noexcept { max_neighbors_ = n > 1 ? n : 1; }
    void step(float dt);

private:
    struct CellKey {
        int x, y;
        bool operator==(const CellKey &o) const noexcept { return x == o.x && y == o.y; }
    };
    struct CellHash {
        std::size_t operator()(const CellKey &k) const noexcept {
            return (static_cast<std::uint32_t>(k.x) * 73856093u) ^
                   (static_cast<std::uint32_t>(k.y) * 19349663u);
        }
    };

    std::vector<CrowdAgent> agents_;
    std::vector<int> next_;
    std::unordered_map<CellKey, int, CellHash> heads_;
    float hash_cell_ = 28.0f;
    int max_neighbors_ = 12;
};

} // namespace upheaval
