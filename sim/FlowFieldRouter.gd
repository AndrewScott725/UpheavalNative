extends RefCounted
const UpConfigRef = preload("res://sim/UpConfig.gd")

## Shared grid flow fields for large interior armies.
##
## The 12x12 courtyard is small, but rebuilding an A* path separately for every
## simulation group still creates avoidable spikes when a breach releases a large
## army.  A flow field is built once per building/layout revision and every melee
## group targeting that building reads one next-cell vector from the cached field.
## The authoritative unit positions, targets, HP and combat rules remain unchanged.

const GRID := UpConfigRef.GRID
const CELL := UpConfigRef.CELL
const DIRS := [Vector2i(0, -1), Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0)]

static func _idx(c: Vector2i) -> int:
	return c.y * GRID + c.x

static func _inside(c: Vector2i) -> bool:
	return c.x >= 0 and c.y >= 0 and c.x < GRID and c.y < GRID

static func _world(c: Vector2i) -> Vector2i:
	return Vector2i(c.x * CELL + CELL / 2, c.y * CELL + CELL / 2)

static func _walkable(occupancy: PackedInt32Array, c: Vector2i) -> bool:
	return _inside(c) and int(occupancy[_idx(c)]) == 0

static func _goal_cells(occupancy: PackedInt32Array, building_cells: Array) -> Array:
	# Melee troops stage in a free orthogonally adjacent cell, then use the
	# existing exact contact-point code for the final half-cell movement.
	var seen := {}
	var goals: Array = []
	for raw in building_cells:
		var bc: Vector2i = raw
		for dv: Vector2i in DIRS:
			var c := bc + dv
			if not _walkable(occupancy, c) or seen.has(c):
				continue
			seen[c] = true
			goals.append(c)
	return goals

static func build_field(occupancy: PackedInt32Array, building_cells: Array) -> PackedInt32Array:
	# Each entry stores the INDEX of the next courtyard cell toward the target.
	# -1 means unreachable; a goal points to itself.
	var next_cell := PackedInt32Array()
	next_cell.resize(GRID * GRID)
	next_cell.fill(-1)
	var queue: Array = []
	for g: Vector2i in _goal_cells(occupancy, building_cells):
		var gi := _idx(g)
		next_cell[gi] = gi
		queue.append(g)
	var head := 0
	while head < queue.size():
		var cur: Vector2i = queue[head]
		head += 1
		var cur_i := _idx(cur)
		for dv: Vector2i in DIRS:
			var n := cur + dv
			if not _walkable(occupancy, n):
				continue
			var ni := _idx(n)
			if next_cell[ni] != -1:
				continue
			next_cell[ni] = cur_i
			queue.append(n)
	return next_cell

static func next_waypoint(field: PackedInt32Array, world_x: int, world_y: int) -> Vector2i:
	if field.size() != GRID * GRID:
		return Vector2i(-1, -1)
	var c := Vector2i(clampi(world_x / CELL, 0, GRID - 1), clampi(world_y / CELL, 0, GRID - 1))
	var ni: int = int(field[_idx(c)])
	if ni < 0:
		return Vector2i(-1, -1)
	var nc := Vector2i(ni % GRID, int(ni / GRID))
	return _world(nc)
