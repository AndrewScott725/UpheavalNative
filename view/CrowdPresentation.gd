class_name CrowdPresentation
extends RefCounted
const UpConfigRef = preload("res://sim/UpConfig.gd")

## Presentation-only lightweight crowd solver.
##
## Each displayed soldier owns a persistent packed position/velocity record.  No
## Node2D/CharacterBody/physics body is created per soldier.  A fixed spatial
## hash limits local-avoidance queries to nearby agents, so thousands of figures
## can flow independently while authoritative combat remains packetized.

const GRID := UpConfigRef.GRID
const CELL := UpConfigRef.CELL
const STATE_WALK := 0
const STATE_ATTACK := 1
const CAT_MELEE := 0
const CAT_RANGED := 1
const FACE_N := 0
const FACE_E := 1
const FACE_S := 2
const FACE_W := 3

# Detailed crowd sprites are foot-anchored.  Contact with a standing wall is
# constrained by the visible body footprint, not only by the agent anchor, so
# no part of an invader can visually ride on top of intact/partial stone.
# These values match ArmyRenderer's current detailed 181x362 atlas at 0.180 scale.
const CROWD_BODY_HALF_WIDTH_PX: float = 16.5
const CROWD_BODY_HEIGHT_ABOVE_FOOT_PX: float = 64.5
const CROWD_WALL_PIXEL_GAP_PX: float = 1.0

var context_key: int = 0
var serial: int = 0
var last_usec: int = 0
var key_to_index: Dictionary = {}

var keys := PackedInt64Array()
var positions := PackedVector2Array()
var velocities := PackedVector2Array()
var goals := PackedVector2Array()
var owners := PackedInt32Array()
var seeds := PackedInt32Array()
var categories := PackedByteArray()
var states := PackedByteArray()
var facings := PackedByteArray()
var walls := PackedByteArray()
var inside_flags := PackedByteArray()
var seen := PackedInt32Array()
var damage_ticks := PackedInt32Array()
var combat_flags := PackedByteArray()
var colors := PackedColorArray()
var active_indices := PackedInt32Array()

# Native backend. When the GDExtension is present, the O(N * nearby-neighbors)
# steering loop runs in C++ and GDScript only prepares goals/constraints and
# applies the cheap O(N) castle/building clamps.
var _native_solver: Object = null
var _native_checked: bool = false
var _native_active: bool = false
var _native_announced: bool = false


func _ensure_native_solver() -> bool:
	if _native_checked:
		return _native_active
	_native_checked = true
	_native_active = ClassDB.class_exists("UpheavalCrowdSolver")
	if _native_active:
		_native_solver = ClassDB.instantiate("UpheavalCrowdSolver")
		_native_active = _native_solver != null
	if not _native_announced:
		_native_announced = true
		if _native_active:
			print("Upheaval crowd backend: native C++ spatial hash")
		else:
			push_warning("Upheaval native crowd solver is not loaded; using GDScript fallback. Build native/crowd_gdextension for this platform to remove the crowd hot loop from GDScript.")
	return _native_active


func native_backend_active() -> bool:
	return _ensure_native_solver()


func reset(new_context: int = 0) -> void:
	context_key = new_context
	serial = 0
	last_usec = 0
	key_to_index.clear()
	keys = PackedInt64Array()
	positions = PackedVector2Array()
	velocities = PackedVector2Array()
	goals = PackedVector2Array()
	owners = PackedInt32Array()
	seeds = PackedInt32Array()
	categories = PackedByteArray()
	states = PackedByteArray()
	facings = PackedByteArray()
	walls = PackedByteArray()
	inside_flags = PackedByteArray()
	seen = PackedInt32Array()
	damage_ticks = PackedInt32Array()
	combat_flags = PackedByteArray()
	colors = PackedColorArray()
	active_indices = PackedInt32Array()


func _wall_code(d: String) -> int:
	match d:
		"N": return 0
		"E": return 1
		"S": return 2
		_: return 3


func _wall_from_code(code: int) -> String:
	match code:
		0: return "N"
		1: return "E"
		2: return "S"
		_: return "W"


func _inward_face_code(d: String) -> int:
	match d:
		"N": return FACE_S
		"S": return FACE_N
		"W": return FACE_E
		_: return FACE_W


func _hash32(v: int) -> int:
	# Deterministic bounded integer mixer; avoid RNG allocations and signed
	# overflow surprises while keeping placement stable across machines.
	var x: int = v & 0x7fffffff
	x = (x * 1103515245 + 12345) & 0x7fffffff
	x = (x ^ (x >> 11)) & 0x7fffffff
	x = (x * 1664525 + 1013904223) & 0x7fffffff
	return x


func _unit_float(seed: int) -> float:
	return float(_hash32(seed) % 100000) / 100000.0


func _wall_collapsed(v, battle_state, d: String) -> bool:
	# Presentation uses "collapsed" here to mean physically passable. A wall that
	# has been rebuilt to HP_PARTIAL is solid again even though the simulation's
	# rebuild flag remains collapsed until HP_FULL.
	if battle_state == null:
		var w = v.match_ref.walls[d]
		return bool(w.collapsed) and int(w.hp()) < UpConfigRef.HP_PARTIAL
	return bool(battle_state.wall_collapsed[d]) and int(battle_state.wall_hp[d]) < UpConfigRef.HP_PARTIAL


func _outer_limit(v, d: String) -> float:
	return v._castle_outer_wall_visual_limit(d)


func _lane_px(v, d: String, army_index: int, army_seed: int) -> float:
	# Golden-ratio-like low-discrepancy placement prevents straight columns/rows.
	var u: float = fmod(float(army_index) * 0.61803398875 + _unit_float(army_seed) * 0.47, 1.0)
	var j: float = (_unit_float(army_seed + army_index * 97) - 0.5) * 0.42
	u = clampf(u + j / float(maxi(12, GRID * 2)), 0.02, 0.98)
	if d == "N" or d == "S":
		var inset_mm: float = float(CELL) * 1.45
		return lerpf(v.mmf_to_px(inset_mm), v.mmf_to_px(float(GRID * CELL) - inset_mm), u)
	var inset_mm_y: float = float(CELL) * 1.45
	return lerpf(v.mmf_to_py(inset_mm_y), v.mmf_to_py(float(GRID * CELL) - inset_mm_y), u)


func _outside_initial(v, inv, army_index: int, army_members: int, lane_px: float) -> Vector2:
	var base: Vector2 = v.interpolated_invader_visual_px(inv)
	var frontage_px: float = maxf(1.0, float((GRID - 2) * v.px_cell))
	var slots: int = maxi(8, int(frontage_px / 22.0))
	var row: int = int(army_index / slots)
	var depth: float = float(row) * 20.0 + (_unit_float(inv.id * 71 + army_index * 313) - 0.5) * 14.0
	match inv.wall:
		"N": return Vector2(lane_px, base.y - depth)
		"S": return Vector2(lane_px, base.y + depth)
		"W": return Vector2(base.x - depth, lane_px)
		_: return Vector2(base.x + depth, lane_px)


func _wall_anchor_clearance(d: String) -> float:
	# The sprite mesh is anchored at the feet and extends upward.  Therefore the
	# south-wall approach needs a full body-height offset for pixel-to-pixel
	# contact, east/west need half the body width, and north uses the foot edge.
	match d:
		"S": return CROWD_BODY_HEIGHT_ABOVE_FOOT_PX + CROWD_WALL_PIXEL_GAP_PX
		"W", "E": return CROWD_BODY_HALF_WIDTH_PX + CROWD_WALL_PIXEL_GAP_PX
		_: return CROWD_WALL_PIXEL_GAP_PX


func _outside_goal(v, inv, lane_px: float, battle_state) -> Vector2:
	var d: String = inv.wall
	if _wall_collapsed(v, battle_state, d):
		# Once the breach exists the packet's authoritative route provides the broad
		# destination, while agents retain independent separation on the way in.
		var b: Vector2 = v.interpolated_invader_visual_px(inv)
		if d == "N" or d == "S": b.x = lane_px
		else: b.y = lane_px
		return b
	var edge: float = _outer_limit(v, d)
	var ranged: bool = str(inv.def["cat"]) == "ranged"
	var standoff: float = 0.0
	if ranged:
		# Use a practical visible firing line.  The authoritative range check remains
		# exact in fixed-point simulation; this keeps marksmen visibly off the wall.
		var range_cells: float = float(int(inv.def.get("range", CELL))) / float(CELL)
		standoff = minf(float(v.px_cell) * 4.0, float(v.px_cell) * range_cells * 0.52)
	var clearance: float = _wall_anchor_clearance(d)
	match d:
		"N": return Vector2(lane_px, edge - clearance - standoff)
		"S": return Vector2(lane_px, edge + clearance + standoff)
		"W": return Vector2(edge - clearance - standoff, lane_px)
		_: return Vector2(edge + clearance + standoff, lane_px)


func _inside_goal(v, inv, member_index: int, battle_state) -> Vector2:
	# Melee agents target the actual nearest building face so each visual soldier
	# stops independently on first pixel contact instead of following the packet
	# center several steps through the footprint.
	if str(inv.def["cat"]) == "melee" and str(inv.tgt_kind) == "b" and int(inv.tgt_id) >= 0:
		var contact_mm := Vector2i(inv.x, inv.y)
		var center_mm := Vector2i(inv.x, inv.y)
		var found: bool = false
		if battle_state == null:
			var b = v.match_ref.find_building(inv.tgt_id)
			if b != null:
				contact_mm = v.match_ref._building_contact_point(b, inv.x, inv.y)
				center_mm = Vector2i(b.cx, b.cy)
				found = true
		else:
			for rec_value in battle_state.buildings:
				var rec: Dictionary = rec_value
				if int(rec.get("rid", -1)) != int(inv.tgt_id):
					continue
				var best_d: int = 1 << 62
				var sx: int = 0
				var sy: int = 0
				var cc: int = 0
				for cell: Vector2i in rec.get("cells", []):
					var left: int = cell.x * CELL
					var right: int = (cell.x + 1) * CELL
					var top: int = cell.y * CELL
					var bottom: int = (cell.y + 1) * CELL
					var qx: int = clampi(inv.x, left, right)
					var qy: int = clampi(inv.y, top, bottom)
					var dx: int = inv.x - qx
					var dy: int = inv.y - qy
					var dd: int = dx * dx + dy * dy
					if dd < best_d:
						best_d = dd
						contact_mm = Vector2i(qx, qy)
					sx += cell.x * CELL + CELL / 2
					sy += cell.y * CELL + CELL / 2
					cc += 1
				if cc > 0:
					center_mm = Vector2i(sx / cc, sy / cc)
					found = true
				break
		if found:
			var cp := Vector2(v.mmf_to_px(float(contact_mm.x)), v.mmf_to_py(float(contact_mm.y)))
			var bp := Vector2(v.mmf_to_px(float(center_mm.x)), v.mmf_to_py(float(center_mm.y)))
			var outward: Vector2 = cp - bp
			if outward.length_squared() < 0.01:
				outward = Vector2(v.mmf_to_px(float(inv.x)), v.mmf_to_py(float(inv.y))) - bp
			if outward.length_squared() < 0.01:
				outward = Vector2.DOWN
			outward = outward.normalized()
			var tangent := Vector2(-outward.y, outward.x)
			var spread: float = (_unit_float(inv.id * 883 + member_index * 359) - 0.5) * 18.0
			return cp + outward * 5.5 + tangent * spread

	var base: Vector2 = v.interpolated_invader_visual_px(inv)
	# A compact irregular disk around the packet's strategic waypoint.  Local
	# separation, not a square spiral, determines the final crowd shape.
	var u: float = _unit_float(inv.id * 1009 + member_index * 9176)
	var vv: float = _unit_float(inv.id * 3719 + member_index * 31337)
	var ang: float = u * TAU
	var rad: float = sqrt(vv) * 24.0
	return base + Vector2(cos(ang), sin(ang)) * rad


func _agent_key(inv, global_index: int, member_index: int) -> int:
	# Identity survives wall crossing.  Using the army-global member index means a
	# soldier flows through a breach instead of disappearing outside and respawning
	# as a new interior sprite.
	var cat: int = 1 if str(inv.def["cat"]) == "ranged" else 0
	var aid: int = inv.army_id if inv.army_id >= 0 else -inv.id
	return int(aid) * 10000019 + int(global_index) * 2 + cat


func _append_agent(key: int, p: Vector2) -> int:
	var idx: int = keys.size()
	keys.append(key)
	positions.append(p)
	velocities.append(Vector2.ZERO)
	goals.append(p)
	owners.append(-1)
	seeds.append(0)
	categories.append(0)
	states.append(STATE_WALK)
	facings.append(FACE_S)
	walls.append(0)
	inside_flags.append(0)
	seen.append(0)
	damage_ticks.append(-1)
	combat_flags.append(0)
	colors.append(Color.WHITE)
	key_to_index[key] = idx
	return idx


func _face_from_velocity(vel: Vector2, fallback: int) -> int:
	if vel.length_squared() < 1.0:
		return fallback
	if absf(vel.x) >= absf(vel.y):
		return FACE_E if vel.x > 0.0 else FACE_W
	return FACE_S if vel.y > 0.0 else FACE_N


func _hash_bucket(p: Vector2) -> Vector2i:
	var cs: float = UpConfigRef.CROWD_HASH_CELL_PX
	return Vector2i(int(floor(p.x / cs)), int(floor(p.y / cs)))


func _bucket_key(c: Vector2i) -> int:
	return c.x * 73856093 ^ c.y * 19349663


func _occupancy_value(v, battle_state, cx: int, cy: int) -> int:
	if cx < 0 or cy < 0 or cx >= GRID or cy >= GRID:
		return 0
	var cell_index: int = cy * GRID + cx
	if battle_state == null:
		return int(v.match_ref.occupancy[cell_index])
	if cell_index >= 0 and cell_index < battle_state.layout_occupancy.size():
		return int(battle_state.layout_occupancy[cell_index])
	return 0


func _constrain_buildings(v, battle_state, idx: int, old_p: Vector2, p: Vector2) -> Vector2:
	if int(inside_flags[idx]) == 0:
		return p
	var off_x: float = v.mmf_to_px(0.0)
	var off_y: float = v.mmf_to_py(0.0)
	var cell_px_x: float = absf(v.mmf_to_px(float(CELL)) - off_x)
	var cell_px_y: float = absf(v.mmf_to_py(float(CELL)) - off_y)
	if cell_px_x < 1.0 or cell_px_y < 1.0:
		return p
	var local_x: float = p.x - off_x
	var local_y: float = p.y - off_y
	if local_x < 0.0 or local_y < 0.0 or local_x >= cell_px_x * GRID or local_y >= cell_px_y * GRID:
		return p
	var cx: int = clampi(int(floor(local_x / cell_px_x)), 0, GRID - 1)
	var cy: int = clampi(int(floor(local_y / cell_px_y)), 0, GRID - 1)
	if _occupancy_value(v, battle_state, cx, cy) == 0:
		return p

	# The packed agent reached an occupied building cell.  Resolve to the face it
	# crossed from, not the far side, so one soldier's feet can never slide through
	# a structure while the packet center catches up.
	var left: float = off_x + float(cx) * cell_px_x
	var right: float = left + cell_px_x
	var top: float = off_y + float(cy) * cell_px_y
	var bottom: float = top + cell_px_y
	var foot_margin: float = 2.0
	if old_p.x <= left:
		p.x = left - foot_margin
	elif old_p.x >= right:
		p.x = right + foot_margin
	elif old_p.y <= top:
		p.y = top - foot_margin
	elif old_p.y >= bottom:
		p.y = bottom + foot_margin
	else:
		# If separation pushed an already-near agent into the footprint, choose the
		# nearest face.  This is local O(1) occupancy work, not a building-list scan.
		var dl: float = absf(p.x - left)
		var dr: float = absf(right - p.x)
		var dt: float = absf(p.y - top)
		var db: float = absf(bottom - p.y)
		var best: float = minf(minf(dl, dr), minf(dt, db))
		if best == dl:
			p.x = left - foot_margin
		elif best == dr:
			p.x = right + foot_margin
		elif best == dt:
			p.y = top - foot_margin
		else:
			p.y = bottom + foot_margin
	return p


func _constrain_wall(v, battle_state, idx: int, p: Vector2) -> Vector2:
	if int(inside_flags[idx]) != 0:
		# Do not teleport rear ranks across a newly opened breach when the packet's
		# strategic center becomes "inside".  Agents outside the courtyard continue
		# to flow through the opening under their own velocity. Once their centers
		# have entered the field, keep them off every intact parapet.
		var left: float = v.mmf_to_px(0.0) + 2.0
		var right: float = v.mmf_to_px(float(GRID * CELL)) - 2.0
		var top: float = v.mmf_to_py(0.0) + 2.0
		var bottom: float = v.mmf_to_py(float(GRID * CELL)) - 2.0
		var xmin: float = minf(left, right)
		var xmax: float = maxf(left, right)
		var ymin: float = minf(top, bottom)
		var ymax: float = maxf(top, bottom)
		if p.x >= xmin - 6.0 and p.x <= xmax + 6.0 and p.y >= ymin - 6.0 and p.y <= ymax + 6.0:
			p.x = clampf(p.x, xmin, xmax)
			p.y = clampf(p.y, ymin, ymax)
		return p
	var d: String = _wall_from_code(int(walls[idx]))
	if _wall_collapsed(v, battle_state, d):
		return p
	var edge: float = _outer_limit(v, d)
	var clearance: float = _wall_anchor_clearance(d)
	var ranged: bool = int(categories[idx]) == CAT_RANGED
	var g: Vector2 = goals[idx]
	if ranged:
		# Marksmen stop at their individual firing line.  The secondary wall clamp
		# guarantees the visible body footprint remains completely outside stone.
		match d:
			"N": p.y = minf(p.y, minf(g.y, edge - clearance))
			"S": p.y = maxf(p.y, maxf(g.y, edge + clearance))
			"W": p.x = minf(p.x, minf(g.x, edge - clearance))
			"E": p.x = maxf(p.x, maxf(g.x, edge + clearance))
	else:
		# Melee contact is pixel-to-pixel: the first visible body pixel may touch
		# the wall, but the agent anchor can never advance far enough for the body
		# to overlap the intact/partial wall artwork.
		match d:
			"N": p.y = minf(p.y, edge - clearance)
			"S": p.y = maxf(p.y, edge + clearance)
			"W": p.x = minf(p.x, edge - clearance)
			"E": p.x = maxf(p.x, edge + clearance)
	return p


func _at_goal(idx: int) -> bool:
	return positions[idx].distance_squared_to(goals[idx]) <= 9.0


func sync_and_step(v, invaders: Array, battle_state, p_context_key: int, visual_cap: int) -> void:
	if context_key != p_context_key:
		reset(p_context_key)
	serial += 1
	active_indices = PackedInt32Array()
	var total_members: int = 0
	for inv in invaders:
		if inv.hp > 0:
			total_members += v.match_ref.invader_members(inv)
	if total_members <= 0:
		return
	visual_cap = clampi(visual_cap, 1, UpConfigRef.CROWD_MAX_VISIBLE_AGENTS)
	var stride: int = maxi(1, int(ceil(float(total_members) / float(visual_cap))))

	var army_totals: Dictionary = {}
	for inv in invaders:
		if inv.hp <= 0:
			continue
		var aid: int = inv.army_id if inv.army_id >= 0 else -inv.id
		army_totals[aid] = int(army_totals.get(aid, 0)) + v.match_ref.invader_members(inv)
	var army_seen: Dictionary = {}

	for inv in invaders:
		if inv.hp <= 0:
			continue
		var members: int = v.match_ref.invader_members(inv)
		var aid2: int = inv.army_id if inv.army_id >= 0 else -inv.id
		var member_base: int = int(army_seen.get(aid2, 0))
		army_seen[aid2] = member_base + members
		var local_stride: int = stride
		# Interior agents are costlier because they participate in obstacle-dense
		# local avoidance; still keep hundreds of independently moving figures.
		if inv.inside:
			local_stride = maxi(local_stride, int(ceil(float(maxi(1, members)) / 320.0)))
		for n in range(0, members, local_stride):
			var global_index: int = member_base + n
			var key: int = _agent_key(inv, global_index, n)
			var lane: float = _lane_px(v, inv.wall, global_index, aid2 * 131 + int(inv.id))
			var initial: Vector2
			var goal: Vector2
			if inv.inside:
				initial = _inside_goal(v, inv, n, battle_state)
				goal = initial
			else:
				initial = _outside_initial(v, inv, global_index, int(army_totals.get(aid2, members)), lane)
				goal = _outside_goal(v, inv, lane, battle_state)
			var idx: int
			if key_to_index.has(key):
				idx = int(key_to_index[key])
			else:
				idx = _append_agent(key, initial)
			goals[idx] = goal
			owners[idx] = int(inv.id)
			seeds[idx] = _hash32(int(inv.id) * 7919 + n * 101)
			categories[idx] = CAT_RANGED if str(inv.def["cat"]) == "ranged" else CAT_MELEE
			walls[idx] = _wall_code(inv.wall)
			inside_flags[idx] = 1 if inv.inside else 0
			positions[idx] = _constrain_wall(v, battle_state, idx, positions[idx])
			damage_ticks[idx] = int(inv.damage_mark_tick)
			# Attack animation follows authoritative combat state. A presentation goal
			# by itself is not permission to fire.
			var attacking: bool = false
			if inv.inside:
				attacking = int(inv.structure_contact_tick) >= 0
			elif str(inv.def["cat"]) == "ranged":
				attacking = int(inv.wall_contact_tick) >= 0 and not _wall_collapsed(v, battle_state, inv.wall)
			else:
				attacking = bool(inv.at_wall) and not _wall_collapsed(v, battle_state, inv.wall)
			combat_flags[idx] = 1 if attacking else 0
			colors[idx] = inv.force_color.lightened(0.18) if str(inv.def["cat"]) == "ranged" else inv.force_color
			seen[idx] = serial
			active_indices.append(idx)


	var now_usec: int = Time.get_ticks_usec()
	var dt: float = 1.0 / float(UpConfigRef.CROWD_PRESENTATION_HZ)
	if last_usec > 0:
		dt = clampf(float(now_usec - last_usec) / 1000000.0, 0.018, 0.085)
	last_usec = now_usec

	# Native DINO-style crowd hot loop. Speeds remain presentation decisions in
	# GDScript, but the spatial hash, local-neighbor queries, separation steering,
	# smoothing and integration are executed in one C++ bulk call.
	var max_speeds := PackedFloat32Array()
	max_speeds.resize(positions.size())
	var old_active_positions := PackedVector2Array()
	old_active_positions.resize(active_indices.size())
	for ai_pos in active_indices.size():
		var idx: int = active_indices[ai_pos]
		old_active_positions[ai_pos] = positions[idx]
		var to_goal: Vector2 = goals[idx] - positions[idx]
		var speed: float = float(v.px_cell) * 1.25
		if not _wall_collapsed(v, battle_state, _wall_from_code(int(walls[idx]))) and int(categories[idx]) == CAT_RANGED:
			speed = float(v.px_cell) * 0.72
		elif to_goal.length() > float(v.px_cell) * 2.5:
			speed = float(v.px_cell) * 0.64
		max_speeds[idx] = speed

	if _ensure_native_solver():
		var result: Array = _native_solver.call(
			"step_packed", positions, velocities, goals, active_indices, seeds, max_speeds,
			UpConfigRef.CROWD_PERSONAL_RADIUS_PX, dt, UpConfigRef.CROWD_HASH_CELL_PX, UpConfigRef.CROWD_MAX_NEIGHBORS)
		if result.size() >= 2:
			var native_positions: PackedVector2Array = result[0]
			var native_velocities: PackedVector2Array = result[1]
			positions = native_positions
			velocities = native_velocities
	else:
		_step_gdscript_fallback(max_speeds, dt)

	# Geometry-specific constraints are deliberately a linear pass after native
	# integration. This keeps stone/building rules authoritative while the costly
	# crowd-neighbor work stays native.
	for ai_pos in active_indices.size():
		var idx: int = active_indices[ai_pos]
		var before: Vector2 = old_active_positions[ai_pos]
		var np: Vector2 = positions[idx]
		np = _constrain_wall(v, battle_state, idx, np)
		np = _constrain_buildings(v, battle_state, idx, before, np)
		positions[idx] = np
		var dstr: String = _wall_from_code(int(walls[idx]))
		var fallback_face: int = _inward_face_code(dstr)
		facings[idx] = _face_from_velocity(velocities[idx], fallback_face)
		states[idx] = STATE_ATTACK if int(combat_flags[idx]) != 0 else STATE_WALK


func _step_gdscript_fallback(max_speeds: PackedFloat32Array, dt: float) -> void:
	# Functional compatibility fallback only. Production builds should load the
	# native GDExtension so this O(N * nearby-neighbors) loop is never hot.
	var buckets: Dictionary = {}
	for idx in active_indices:
		var c: Vector2i = _hash_bucket(positions[idx])
		var k: int = _bucket_key(c)
		if not buckets.has(k):
			buckets[k] = []
		buckets[k].append(idx)

	var min_sep: float = UpConfigRef.CROWD_PERSONAL_RADIUS_PX * 2.0
	var max_neighbors: int = UpConfigRef.CROWD_MAX_NEIGHBORS
	for idx in active_indices:
		var p: Vector2 = positions[idx]
		var g: Vector2 = goals[idx]
		var to_goal: Vector2 = g - p
		var speed: float = max_speeds[idx]
		var desired: Vector2 = to_goal.normalized() * speed if to_goal.length_squared() > 0.5 else Vector2.ZERO
		var sep := Vector2.ZERO
		var found: int = 0
		var cell: Vector2i = _hash_bucket(p)
		for oy in range(-1, 2):
			for ox in range(-1, 2):
				var bk: int = _bucket_key(cell + Vector2i(ox, oy))
				if not buckets.has(bk):
					continue
				for other in buckets[bk]:
					if other == idx:
						continue
					var delta: Vector2 = p - positions[other]
					var dsq: float = delta.length_squared()
					if dsq <= 0.001 or dsq >= min_sep * min_sep:
						continue
					var dist: float = sqrt(dsq)
					sep += delta / dist * ((min_sep - dist) / min_sep)
					found += 1
					if found >= max_neighbors:
						break
				if found >= max_neighbors:
					break
			if found >= max_neighbors:
				break
		if found > 0:
			sep /= float(found)
			var side: float = -1.0 if (int(seeds[idx]) & 1) == 0 else 1.0
			var tangent := Vector2(-desired.y, desired.x).normalized() * side
			desired += sep * speed * 2.2 + tangent * sep.length() * speed * 0.22
		var old_v: Vector2 = velocities[idx]
		var nv: Vector2 = old_v.lerp(desired, 0.38)
		if nv.length() > speed * 1.25:
			nv = nv.normalized() * speed * 1.25
		positions[idx] = p + nv * dt
		velocities[idx] = nv


func facing_string(idx: int) -> String:
	match int(facings[idx]):
		FACE_N: return "N"
		FACE_E: return "E"
		FACE_S: return "S"
		_: return "W"
