extends RefCounted
const UpConfigRef = preload("res://sim/UpConfig.gd")
const FlowFieldRouter = preload("res://sim/FlowFieldRouter.gd")

## Invader movement/pathing state machine extracted from UpMatch.
## State still lives on UpMatch; this module owns the frequently changed movement
## and route-selection behavior.

const GRID := UpConfigRef.GRID
const CELL := UpConfigRef.CELL


static func _dist_sq(ax: int, ay: int, bx: int, by: int) -> int:
	var dx := ax - bx
	var dy := ay - by
	return dx * dx + dy * dy


static func _isqrt(v: int) -> int:
	if v <= 0:
		return 0
	var x := int(sqrt(float(v)))
	while (x + 1) * (x + 1) <= v:
		x += 1
	while x * x > v:
		x -= 1
	return x


static func cell_from_world(x: int, y: int) -> Vector2i:
	return Vector2i(clampi(x / CELL, 0, GRID - 1), clampi(y / CELL, 0, GRID - 1))


static func world_from_cell(c: Vector2i) -> Vector2i:
	return Vector2i(c.x * CELL + CELL / 2, c.y * CELL + CELL / 2)


static func cell_walkable(m: UpMatch, c: Vector2i, start: Vector2i) -> bool:
	if c.x < 0 or c.y < 0 or c.x >= GRID or c.y >= GRID:
		return false
	if c == start:
		return true
	return m.occupancy[c.y * GRID + c.x] == 0


static func path_goal_ok(m: UpMatch, inv: UpMatch.Invader, c: Vector2i, target: Vector2i, attack_range: int) -> bool:
	var wp := world_from_cell(c)
	if m._target_distance_sq(inv, wp.x, wp.y) > attack_range * attack_range:
		return false
	if inv.def["cat"] == "ranged":
		return m._has_building_los(wp.x, wp.y, target.x, target.y)
	return true


static func build_interior_path(m: UpMatch, inv: UpMatch.Invader, target: Vector2i, attack_range: int) -> Array:
	var start := cell_from_world(inv.x, inv.y)
	if path_goal_ok(m, inv, start, target, attack_range):
		return []

	var q: Array = [start]
	var head := 0
	var came := {}
	came[start] = start
	var found := Vector2i(-1, -1)
	var dirs := [Vector2i(0, -1), Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0)]

	while head < q.size():
		var cur: Vector2i = q[head]
		head += 1
		for dv: Vector2i in dirs:
			var nxt := cur + dv
			if came.has(nxt) or not cell_walkable(m, nxt, start):
				continue
			came[nxt] = cur
			if path_goal_ok(m, inv, nxt, target, attack_range):
				found = nxt
				head = q.size()
				break
			q.append(nxt)

	if found.x < 0:
		return []

	var cells: Array = []
	var cur := found
	while cur != start:
		cells.push_front(cur)
		cur = came[cur]
	var result: Array = []
	for c: Vector2i in cells:
		result.append(world_from_cell(c))
	return result


static func reset_path(inv: UpMatch.Invader) -> void:
	inv.path.clear()
	inv.path_index = 0
	inv.path_target_kind = ""
	inv.path_target_id = -1


static func _building_flow_field(m: UpMatch, building) -> PackedInt32Array:
	var key := "%d|%d" % [building.id, m.occupancy_revision]
	if m.flow_field_cache.has(key):
		return m.flow_field_cache[key]
	var field := FlowFieldRouter.build_field(m.occupancy, building.cells)
	# Occupancy revisions normally keep this dictionary tiny. The hard bound is a
	# safety valve for editor/live-reload edge cases.
	if m.flow_field_cache.size() >= UpConfigRef.FLOW_FIELD_CACHE_MAX:
		m.flow_field_cache.clear()
	m.flow_field_cache[key] = field
	return field


static func _follow_building_flow(m: UpMatch, inv: UpMatch.Invader, building) -> bool:
	var field := _building_flow_field(m, building)
	var wp := FlowFieldRouter.next_waypoint(field, inv.x, inv.y)
	if wp.x < 0:
		return false
	# A goal cell points to itself; the exact footprint contact branch handles the
	# final movement from that cell on the next tick.
	if wp == world_from_cell(cell_from_world(inv.x, inv.y)):
		return false
	return move_invader_toward(m, inv, wp, UpConfigRef.SPEED_INSIDE)


static func ensure_path(m: UpMatch, inv: UpMatch.Invader, target: Vector2i, attack_range: int) -> void:
	if inv.path_target_kind == inv.tgt_kind and inv.path_target_id == inv.tgt_id and inv.path_index < inv.path.size():
		return
	inv.path = build_interior_path(m, inv, target, attack_range)
	inv.path_index = 0
	inv.path_target_kind = inv.tgt_kind
	inv.path_target_id = inv.tgt_id


static func interior_segment_clear(m: UpMatch, ax: int, ay: int, bx: int, by: int) -> bool:
	# Authoritative anti-tunnelling check. Grid pathfinding chooses legal cells,
	# but every actual movement segment is verified too so interpolation, direct
	# final approach, or a future path change can never carry an invader through
	# an intact building.
	var dx := bx - ax
	var dy := by - ay
	var span := maxi(absi(dx), absi(dy))
	var steps := maxi(1, int(ceil(float(span) / 80.0)))
	for s in range(1, steps + 1):
		var px := ax + dx * s / steps
		var py := ay + dy * s / steps
		if m._point_inside_building(px, py):
			return false
	return true


static func recover_illegal_interior_position(m: UpMatch, inv: UpMatch.Invader) -> bool:
	# Defensive recovery for any invalid interior position that reaches this step.
	# Normal movement cannot enter a building; if an invalid point is detected,
	# relocate to the nearest empty grid-cell centre before any targeting/damage.
	if not inv.inside or not m._point_inside_building(inv.x, inv.y):
		return false

	var best := Vector2i(-1, -1)
	var best_d := 1 << 62
	for cy in GRID:
		for cx in GRID:
			if m.occupancy[cy * GRID + cx] != 0:
				continue
			var p := world_from_cell(Vector2i(cx, cy))
			var d := _dist_sq(inv.x, inv.y, p.x, p.y)
			if d < best_d:
				best_d = d
				best = p
	if best.x >= 0:
		inv.x = best.x
		inv.y = best.y
		inv.last_progress_x = inv.x
		inv.last_progress_y = inv.y
		reset_path(inv)
		m._sync_invader_index(inv)
		return true
	return false


## Renamed from move_toward(): that name is a @GlobalScope utility function
## (move_toward(from, to, delta) on floats), and Godot 4.2 resolves unqualified
## calls to the built-in even from inside this file, so the internal calls below
## were binding to the wrong function.
static func move_invader_toward(m: UpMatch, inv: UpMatch.Invader, dest: Vector2i, speed: int) -> bool:
	var dx := dest.x - inv.x
	var dy := dest.y - inv.y
	var d := _isqrt(dx * dx + dy * dy)
	var nx := dest.x
	var ny := dest.y
	if d > speed:
		inv.hx = dx
		inv.hy = dy
		nx = inv.x + dx * speed / max(1, d)
		ny = inv.y + dy * speed / max(1, d)

	# Once inside, no movement segment may enter or tunnel through an occupied
	# building footprint. Walls/turrets are outside the legal interior rectangle;
	# breach entry is handled separately before inv.inside becomes true.
	if inv.inside and not interior_segment_clear(m, inv.x, inv.y, nx, ny):
		return false

	inv.x = nx
	inv.y = ny
	m._sync_invader_index(inv)
	return true


static func check_progress(m: UpMatch, inv: UpMatch.Invader) -> bool:
	var moved_sq := _dist_sq(inv.x, inv.y, inv.last_progress_x, inv.last_progress_y)
	if moved_sq <= UpConfigRef.STUCK_MOVE_EPSILON * UpConfigRef.STUCK_MOVE_EPSILON:
		inv.stuck_ticks += 1
	else:
		inv.stuck_ticks = 0
		inv.last_progress_x = inv.x
		inv.last_progress_y = inv.y
	if inv.stuck_ticks < UpConfigRef.STUCK_REPATH_TICKS:
		return false
	inv.stuck_ticks = 0
	inv.last_progress_x = inv.x
	inv.last_progress_y = inv.y
	reset_path(inv)
	return true


static func _ranged_wall_in_range(m: UpMatch, inv: UpMatch.Invader) -> bool:
	if inv == null or inv.hp <= 0 or inv.inside or inv.def["cat"] != "ranged":
		return false
	var r: int = mini(int(inv.def.get("range", UpConfigRef.REACH)), UpConfigRef.INVADER_WALL_RANGED_MAX)
	var p: Vector2i = m.wall_point(inv.wall)
	# Range to the point directly opposite the group on its assigned wall, not the
	# wall centre.  This lets marksmen stop and fire the instant their individual
	# front reaches weapon range instead of marching all the way onto the stone.
	match inv.wall:
		"N", "S": p.x = inv.x
		"W", "E": p.y = inv.y
	return _dist_sq(inv.x, inv.y, p.x, p.y) <= r * r


static func _wall_blocks_invaders(w) -> bool:
	# A half-rebuilt wall is physical stone again even though the rebuild state
	# keeps `collapsed` true until full HP. Invaders must stop and attack it; only
	# rubble below HP_PARTIAL is an open breach.
	return not w.collapsed or w.hp() >= UpConfigRef.HP_PARTIAL


static func clamp_outside_to_assigned_wall(inv: UpMatch.Invader) -> void:
	# Authoritative invariant: until an invader is explicitly marked inside, its
	# center may never exist on the fiefdom side of its assigned perimeter wall.
	if inv.inside:
		return
	match inv.wall:
		"N": inv.y = mini(inv.y, 0)
		"S": inv.y = maxi(inv.y, GRID * CELL)
		"W": inv.x = mini(inv.x, 0)
		"E": inv.x = maxi(inv.x, GRID * CELL)


static func move_and_collect(m: UpMatch, attacks: Array) -> void:
	for inv: UpMatch.Invader in m.invaders:
		if inv.hp <= 0:
			continue
		var w = m.walls[inv.wall]
		if not inv.inside:
			# active_tick is the announced first-engagement time for the whole army.
			# Before it expires the force is still travelling and cannot participate in
			# combat. At T-0 ranged may fire as soon as its own range test succeeds,
			# while infantry immediately continues toward physical wall contact at the
			# normal approach speed.
			if inv.active_tick > 0 and m.tick >= inv.active_tick:
				inv.active_tick = 0
				m._sync_invader_index(inv)
			var contact: Vector2i = m.invader_melee_wall_contact_point(inv.wall, inv.wall_lane) if inv.def["cat"] == "melee" else m.invader_wall_contact_point(inv.wall, inv.wall_lane)

			# Standing-wall approach is resolved by unit role.  Marksmen stop and
			# fire the first tick they enter range; melee keeps marching until actual
			# body contact.  This removes the old packet-wide "everyone reaches the
			# wall, then everyone acts" gate.
			if _wall_blocks_invaders(w) and inv.def["cat"] == "ranged":
				if _ranged_wall_in_range(m, inv):
					inv.active_tick = 0
					inv.at_wall = false
					if inv.wall_contact_tick < 0:
						inv.wall_contact_tick = m.tick
					if m.tick >= inv.next_attack:
						inv.next_attack = m.tick + int(inv.def["iv"])
						m._collect_invader_ranged_strike(inv, w, attacks)
					continue
				inv.wall_contact_tick = -1
				move_invader_toward(m, inv, contact, UpConfigRef.PREVIEW_APPROACH_SPEED if inv.active_tick > 0 else UpConfigRef.SPEED_APPROACH)
				clamp_outside_to_assigned_wall(inv)
				m._sync_invader_index(inv)
				continue

			if inv.active_tick > 0:
				# Melee approach: the authoritative packet front continues to the exact
				# wall face.  Rendering independently queues the rear ranks behind it.
				if inv.x != contact.x or inv.y != contact.y:
					move_invader_toward(m, inv, contact, UpConfigRef.PREVIEW_APPROACH_SPEED)
					clamp_outside_to_assigned_wall(inv)
					m._sync_invader_index(inv)
					continue
				inv.active_tick = 0
				inv.at_wall = true
				inv.wall_contact_tick = m.tick
				m._sync_invader_index(inv)

			# A wall is passable only after its authoritative collapse flag has
			# actually been set.  Melee stops at first contact; progressive frontage
			# determines how many members are attacking on each subsequent tick.
			if _wall_blocks_invaders(w):
				if inv.x != contact.x or inv.y != contact.y:
					move_invader_toward(m, inv, contact, UpConfigRef.SPEED_APPROACH)
					clamp_outside_to_assigned_wall(inv)
					m._sync_invader_index(inv)
					continue
				if inv.wall_contact_tick < 0:
					inv.wall_contact_tick = m.tick
				inv.at_wall = true
				clamp_outside_to_assigned_wall(inv)
				m._sync_invader_index(inv)
				if not m.invader_melee_ready_at_wall(inv, inv.wall):
					continue
				if m.tick < inv.next_attack:
					continue
				inv.next_attack = m.tick + int(inv.def["iv"])
				if not w.melee.is_empty():
					m._queue_group_melee_wall_strikes(inv, w, attacks)
				continue

			inv.at_wall = false
			inv.wall_contact_tick = -1
			var entry: Vector2i = m.invader_entry_point(inv.wall, inv.wall_lane)

			# Cross the assigned breach perpendicular to its wall. Lock the lane
			# coordinate so an outside group can never take a diagonal shortcut
			# across another standing wall or corner turret.
			match inv.wall:
				"N", "S": inv.x = entry.x
				"W", "E": inv.y = entry.y

			var entry_dist := _isqrt(_dist_sq(inv.x, inv.y, entry.x, entry.y))
			if entry_dist > UpConfigRef.SPEED_APPROACH:
				move_invader_toward(m, inv, entry, UpConfigRef.SPEED_APPROACH)
				continue
			inv.x = entry.x
			inv.y = entry.y
			inv.inside = true
			inv.last_progress_x = inv.x
			inv.last_progress_y = inv.y
			reset_path(inv)
			m._sync_invader_index(inv)
			continue

		if inv.x < CELL / 2 or inv.y < CELL / 2 or inv.x > GRID * CELL - CELL / 2 or inv.y > GRID * CELL - CELL / 2:
			inv.x = clampi(inv.x, CELL / 2, GRID * CELL - CELL / 2)
			inv.y = clampi(inv.y, CELL / 2, GRID * CELL - CELL / 2)
			inv.last_progress_x = inv.x
			inv.last_progress_y = inv.y
			reset_path(inv)
			m._sync_invader_index(inv)

		# No invader may target or attack while occupying an intact building.
		if recover_illegal_interior_position(m, inv):
			continue

		if inv.tgt_id < 0 or not m._target_valid(inv):
			m._acquire_interior_target(inv)
			reset_path(inv)
		if inv.tgt_id < 0:
			continue

		var tp: Vector2i = m._target_point(inv)
		var inside_range: int
		if inv.def["cat"] == "ranged":
			inside_range = int(inv.def.get("range", UpConfigRef.REACH))
		elif inv.tgt_kind == "b":
			# Packet coordinates are body centres.  Stop when the leading edge of the
			# first infantry sprite touches the building footprint, not when the
			# entire packet centre reaches the exact edge.
			inside_range = UpConfigRef.CROWD_MELEE_FRONT_REACH
		else:
			inside_range = UpConfigRef.REACH
		var d2 := _isqrt(m._target_distance_sq(inv, inv.x, inv.y))
		var blocked_los: bool = inv.def["cat"] == "ranged" and not m._has_building_los(inv.x, inv.y, tp.x, tp.y)

		# Building pathfinding is cell-based. An adjacent walkable cell centre is
		# still half a cell (500 millicells) from the building edge, while melee
		# structure reach is exactly ZERO. Stage at an adjacent cell, then walk the
		# final short segment to the nearest footprint edge. Damage is impossible
		# until the authoritative group position reaches that edge.
		if inv.def["cat"] != "ranged" and inv.tgt_kind == "b" and d2 > inside_range:
			var b = m.find_building(inv.tgt_id)
			if b == null:
				inv.tgt_id = -1
				reset_path(inv)
				continue
			var contact: Vector2i = m._building_contact_point(b, inv.x, inv.y)
			var direct_close_distance := CELL / 2 + UpConfigRef.SPEED_INSIDE
			# The pathfinder (path_goal_ok) treats the invader's current cell as a
			# goal when that cell's CENTRE is within reach, and then returns an
			# empty path. This branch must use the same arrival test. Measuring only
			# from the invader's actual position left a gap: an invader pushed off
			# its cell centre could be "arrived" to the pathfinder but "not close
			# enough" here, so neither branch moved it. check_progress would then
			# drop the target, reacquire the same nearest building, and freeze
			# again - groups were observed stuck for 600+ ticks.
			# Safe against crossing buildings: a goal cell is walkable and shares an
			# edge with the target, so a straight move to the contact point on that
			# edge never leaves the cell.
			var here_cell := cell_from_world(inv.x, inv.y)
			var in_goal_cell := path_goal_ok(m, inv, here_cell, contact, CELL / 2)
			if d2 <= direct_close_distance or in_goal_cell:
				var before_x := inv.x
				var before_y := inv.y
				var moved := move_invader_toward(m, inv, contact, UpConfigRef.SPEED_INSIDE)
				if inv.x == contact.x and inv.y == contact.y and (before_x != inv.x or before_y != inv.y):
					inv.structure_contact_tick = m.tick
				if moved:
					inv.stuck_ticks = 0
					inv.last_progress_x = inv.x
					inv.last_progress_y = inv.y
				elif check_progress(m, inv):
					inv.tgt_id = -1
					reset_path(inv)
				continue

			# Shared reverse flow field: all melee groups attacking this building
			# reuse one 12x12 directional map rather than constructing one A* path
			# per group. Exact contact is still resolved by the branch above.
			if _follow_building_flow(m, inv, b):
				inv.stuck_ticks = 0
				inv.last_progress_x = inv.x
				inv.last_progress_y = inv.y
			elif check_progress(m, inv):
				inv.tgt_id = -1
				reset_path(inv)
			continue

		if d2 > inside_range or blocked_los:
			inv.structure_contact_tick = -1
			# Direct-line fast path: if no structure blocks the segment, do not run
			# pathfinding at all. This is the common case in open courtyard space.
			if not blocked_los and interior_segment_clear(m, inv.x, inv.y, tp.x, tp.y):
				move_invader_toward(m, inv, tp, UpConfigRef.SPEED_INSIDE)
				inv.stuck_ticks = 0
				inv.last_progress_x = inv.x
				inv.last_progress_y = inv.y
				continue
			ensure_path(m, inv, tp, inside_range)
			if inv.path_index < inv.path.size():
				var waypoint: Vector2i = inv.path[inv.path_index]
				if _dist_sq(inv.x, inv.y, waypoint.x, waypoint.y) <= UpConfigRef.PATH_WAYPOINT_REACH * UpConfigRef.PATH_WAYPOINT_REACH:
					inv.path_index += 1
					if inv.path_index < inv.path.size():
						waypoint = inv.path[inv.path_index]
				if inv.path_index < inv.path.size():
					move_invader_toward(m, inv, waypoint, UpConfigRef.SPEED_INSIDE)
			else:
				check_progress(m, inv)
				if inv.stuck_ticks == 0:
					inv.tgt_id = -1
					reset_path(inv)
				continue

			if check_progress(m, inv):
				inv.tgt_id = -1
				reset_path(inv)
			continue

		inv.stuck_ticks = 0
		inv.last_progress_x = inv.x
		inv.last_progress_y = inv.y
		if inv.tgt_kind == "b":
			# Melee: first touching rank acts immediately. Ranged: first rank fires as
			# soon as it is in weapon range. Rear ranks feed into combat progressively.
			if inv.structure_contact_tick < 0:
				inv.structure_contact_tick = m.tick
		else:
			inv.structure_contact_tick = -1
		if m.tick < inv.next_attack:
			continue
		inv.next_attack = m.tick + int(inv.def["iv"])

		if inv.tgt_kind == "b":
			var b = m.find_building(inv.tgt_id)
			if b == null:
				inv.tgt_id = -1
				reset_path(inv)
				continue
			if inv.def["cat"] == "melee" and m._building_distance_sq(b, inv.x, inv.y) > UpConfigRef.CROWD_MELEE_FRONT_REACH * UpConfigRef.CROWD_MELEE_FRONT_REACH:
				# Defense in depth: a Raider may hit only when its sprite-leading edge
				# can physically touch the target footprint.
				reset_path(inv)
				continue
			var members: int = m.invader_contact_members(inv, inv.structure_contact_tick)
			if members <= 0:
				continue
			m._mark_building_damage(b, int(inv.def["dmg"]) * members)
			if inv.def["cat"] == "melee":
				# Visible contact burst exactly where the Raider meets the building.
				var hit: Vector2i = m._building_contact_point(b, inv.x, inv.y)
				m._record_melee_impact(hit.x, hit.y)
			m._mark_invader_attr(inv, int(inv.def["attr"]) * members)
		elif inv.tgt_kind == "s":
			var s = m.find_sortie(inv.tgt_id)
			if s == null or s.hp <= 0 or s.dead:
				inv.tgt_id = -1
				reset_path(inv)
				continue
			m._mark_sortie_damage(s, int(inv.def["dmg"]) * m.invader_members(inv))
		elif inv.tgt_kind == "u":
			var rec: Dictionary = m._find_stationed_defender(inv.tgt_id)
			if rec.is_empty():
				inv.tgt_kind = ""
				inv.tgt_id = -1
				reset_path(inv)
				continue
			var u = rec["u"]
			m._mark_unit_damage(u, int(inv.def["dmg"]) * m.invader_members(inv))
		else:
			inv.tgt_id = -1
			reset_path(inv)
