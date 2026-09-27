extends RefCounted
const UpConfigRef = preload("res://sim/UpConfig.gd")
const FlowFieldRouter = preload("res://sim/FlowFieldRouter.gd")

## Physical attack simulation for AI-controlled fiefdoms.
##
## This mirrors the player's invasion flow closely enough that a War Camp no
## longer resolves as an abstract wall/interior damage exchange. On arrival the
## army becomes grouped Invader entities that stand at the assigned wall, breach
## it, enter only through that breach, path around intact buildings, close to
## melee contact (or ranged standoff), and destroy actual placed structures.

const GRID := UpConfigRef.GRID
const CELL := UpConfigRef.CELL


static func _dist_sq(ax: int, ay: int, bx: int, by: int) -> int:
	var dx: int = ax - bx
	var dy: int = ay - by
	return dx * dx + dy * dy


static func _isqrt(v: int) -> int:
	if v <= 0:
		return 0
	var x: int = int(sqrt(float(v)))
	while (x + 1) * (x + 1) <= v:
		x += 1
	while x * x > v:
		x -= 1
	return x


static func _world_from_cell(c: Vector2i) -> Vector2i:
	return Vector2i(c.x * CELL + CELL / 2, c.y * CELL + CELL / 2)


static func _cell_from_world(x: int, y: int) -> Vector2i:
	return Vector2i(clampi(x / CELL, 0, GRID - 1), clampi(y / CELL, 0, GRID - 1))


static func _record_id(rec: Dictionary) -> int:
	return int(rec.get("rid", -1))


static func _find_building(r: UpMatch.Rival, rid: int) -> Dictionary:
	for rec in r.buildings:
		if _record_id(rec) == rid:
			return rec
	return {}


static func _point_inside_building(r: UpMatch.Rival, x: int, y: int) -> bool:
	# Same strict-union semantics as UpMatch._point_inside_building(): points on
	# an outside footprint edge count as touching, not occupying the structure.
	for dx in [-1, 1]:
		for dy in [-1, 1]:
			var px: int = x + int(dx)
			var py: int = y + int(dy)
			if px < 0 or py < 0:
				return false
			var cx: int = px / CELL
			var cy: int = py / CELL
			if cx >= GRID or cy >= GRID:
				return false
			if r.layout_occupancy[cy * GRID + cx] == 0:
				return false
	return true


static func _building_distance_sq(rec: Dictionary, px: int, py: int) -> int:
	var best: int = 1 << 62
	for c: Vector2i in rec.get("cells", []):
		var left: int = c.x * CELL
		var right: int = (c.x + 1) * CELL
		var top: int = c.y * CELL
		var bottom: int = (c.y + 1) * CELL
		var qx: int = clampi(px, left, right)
		var qy: int = clampi(py, top, bottom)
		best = mini(best, _dist_sq(px, py, qx, qy))
	return best


static func _building_contact_point(rec: Dictionary, px: int, py: int) -> Vector2i:
	var best_d: int = 1 << 62
	var best: Vector2i = Vector2i(px, py)
	for c: Vector2i in rec.get("cells", []):
		var left: int = c.x * CELL
		var right: int = (c.x + 1) * CELL
		var top: int = c.y * CELL
		var bottom: int = (c.y + 1) * CELL
		var qx: int = clampi(px, left, right)
		var qy: int = clampi(py, top, bottom)
		var dd: int = _dist_sq(px, py, qx, qy)
		if dd < best_d:
			best_d = dd
			best = Vector2i(qx, qy)
	return best


static func _building_center(rec: Dictionary) -> Vector2i:
	var cells: Array = rec.get("cells", [])
	if cells.is_empty():
		return Vector2i(GRID * CELL / 2, GRID * CELL / 2)
	var sx: int = 0
	var sy: int = 0
	for c: Vector2i in cells:
		sx += c.x * CELL + CELL / 2
		sy += c.y * CELL + CELL / 2
	return Vector2i(sx / cells.size(), sy / cells.size())


static func _has_los(r: UpMatch.Rival, ax: int, ay: int, bx: int, by: int, target_rid: int) -> bool:
	var x0: int = clampi(ax / CELL, 0, GRID - 1)
	var y0: int = clampi(ay / CELL, 0, GRID - 1)
	var x1: int = clampi(bx / CELL, 0, GRID - 1)
	var y1: int = clampi(by / CELL, 0, GRID - 1)
	var dx: int = absi(x1 - x0)
	var sx: int = 1 if x0 < x1 else -1
	var dy: int = -absi(y1 - y0)
	var sy: int = 1 if y0 < y1 else -1
	var err: int = dx + dy
	var first: bool = true
	while true:
		if not first and not (x0 == x1 and y0 == y1):
			if x0 >= 0 and y0 >= 0 and x0 < GRID and y0 < GRID:
				var marker: int = int(r.layout_occupancy[y0 * GRID + x0])
				if marker != 0:
					# Markers are only occupancy ids, so any occupied intermediary cell
					# blocks line of sight. The final target cell is exempt above.
					return false
		if x0 == x1 and y0 == y1:
			break
		first = false
		var e2: int = 2 * err
		if e2 >= dy:
			err += dy
			x0 += sx
		if e2 <= dx:
			err += dx
			y0 += sy
	return true


static func _cell_walkable(r: UpMatch.Rival, c: Vector2i, start: Vector2i) -> bool:
	if c.x < 0 or c.y < 0 or c.x >= GRID or c.y >= GRID:
		return false
	if c == start:
		return true
	return int(r.layout_occupancy[c.y * GRID + c.x]) == 0


static func _goal_ok(r: UpMatch.Rival, inv: UpMatch.Invader, rec: Dictionary, c: Vector2i, attack_range: int) -> bool:
	var p: Vector2i = _world_from_cell(c)
	if _building_distance_sq(rec, p.x, p.y) > attack_range * attack_range:
		return false
	if str(inv.def["cat"]) == "ranged":
		var tp: Vector2i = _building_center(rec)
		return _has_los(r, p.x, p.y, tp.x, tp.y, _record_id(rec))
	return true


static func _flow_field(r: UpMatch.Rival, rec: Dictionary) -> PackedInt32Array:
	var rid: int = _record_id(rec)
	var key := "%d|%d" % [rid, r.layout_revision]
	if r.flow_field_cache.has(key):
		return r.flow_field_cache[key]
	var field := FlowFieldRouter.build_field(r.layout_occupancy, rec.get("cells", []))
	if r.flow_field_cache.size() >= UpConfigRef.FLOW_FIELD_CACHE_MAX:
		r.flow_field_cache.clear()
	r.flow_field_cache[key] = field
	return field


static func _follow_flow(r: UpMatch.Rival, inv: UpMatch.Invader, rec: Dictionary) -> bool:
	var wp := FlowFieldRouter.next_waypoint(_flow_field(r, rec), inv.x, inv.y)
	if wp.x < 0:
		return false
	if wp == _world_from_cell(_cell_from_world(inv.x, inv.y)):
		return false
	return _move_toward(r, inv, wp, UpConfigRef.SPEED_INSIDE)


static func _build_path(r: UpMatch.Rival, inv: UpMatch.Invader, rec: Dictionary, attack_range: int) -> Array:
	var start: Vector2i = _cell_from_world(inv.x, inv.y)
	if _goal_ok(r, inv, rec, start, attack_range):
		return []
	var q: Array = [start]
	var head: int = 0
	var came: Dictionary = {}
	came[start] = start
	var found: Vector2i = Vector2i(-1, -1)
	var dirs: Array = [Vector2i(0, -1), Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0)]
	while head < q.size():
		var cur: Vector2i = q[head]
		head += 1
		for dv: Vector2i in dirs:
			var nxt: Vector2i = cur + dv
			if came.has(nxt) or not _cell_walkable(r, nxt, start):
				continue
			came[nxt] = cur
			if _goal_ok(r, inv, rec, nxt, attack_range):
				found = nxt
				head = q.size()
				break
			q.append(nxt)
	if found.x < 0:
		return []
	var cell_path: Array = []
	var cur2: Vector2i = found
	while cur2 != start:
		cell_path.push_front(cur2)
		cur2 = came[cur2]
	var result: Array = []
	for c: Vector2i in cell_path:
		result.append(_world_from_cell(c))
	return result


static func _segment_clear(r: UpMatch.Rival, ax: int, ay: int, bx: int, by: int) -> bool:
	var dx: int = bx - ax
	var dy: int = by - ay
	var span: int = maxi(absi(dx), absi(dy))
	var steps: int = maxi(1, int(ceil(float(span) / 80.0)))
	for s in range(1, steps + 1):
		var px: int = ax + dx * s / steps
		var py: int = ay + dy * s / steps
		if _point_inside_building(r, px, py):
			return false
	return true


static func _move_toward(r: UpMatch.Rival, inv: UpMatch.Invader, dest: Vector2i, speed: int) -> bool:
	var dx: int = dest.x - inv.x
	var dy: int = dest.y - inv.y
	var dist: int = _isqrt(dx * dx + dy * dy)
	var nx: int = dest.x
	var ny: int = dest.y
	if dist > speed:
		inv.hx = dx
		inv.hy = dy
		nx = inv.x + dx * speed / maxi(1, dist)
		ny = inv.y + dy * speed / maxi(1, dist)
	if inv.inside and not _segment_clear(r, inv.x, inv.y, nx, ny):
		return false
	inv.x = nx
	inv.y = ny
	return true


static func _reset_path(inv: UpMatch.Invader) -> void:
	inv.path.clear()
	inv.path_index = 0
	inv.path_target_kind = ""
	inv.path_target_id = -1


static func _acquire_target(m: UpMatch, r: UpMatch.Rival, inv: UpMatch.Invader) -> void:
	var best: int = 1 << 62
	var ties: Array = []
	for rec in r.buildings:
		var dd: int = _building_distance_sq(rec, inv.x, inv.y)
		var cand: Dictionary = {
			"kind": "b", "id": _record_id(rec),
			"px": _building_center(rec).x, "py": _building_center(rec).y,
			"lvl": int(rec["def"].get("lvl", 1)),
		}
		if dd < best:
			best = dd
			ties = [cand]
		elif dd == best:
			ties.append(cand)
	if ties.is_empty():
		inv.tgt_kind = ""
		inv.tgt_id = -1
		return
	var top_level: int = -1
	for c in ties:
		top_level = maxi(top_level, int(c["lvl"]))
	var filtered: Array = []
	for c in ties:
		if int(c["lvl"]) == top_level:
			filtered.append(c)
	var chosen: Dictionary = filtered[0] if filtered.size() == 1 else m._pick_clockwise(inv.hx, inv.hy, inv.x, inv.y, filtered)
	inv.tgt_kind = "b"
	inv.tgt_id = int(chosen["id"])


static func _recover_illegal_position(r: UpMatch.Rival, inv: UpMatch.Invader) -> bool:
	if not inv.inside or not _point_inside_building(r, inv.x, inv.y):
		return false
	var best: Vector2i = Vector2i(-1, -1)
	var best_d: int = 1 << 62
	for cy in GRID:
		for cx in GRID:
			if int(r.layout_occupancy[cy * GRID + cx]) != 0:
				continue
			var p: Vector2i = _world_from_cell(Vector2i(cx, cy))
			var dd: int = _dist_sq(inv.x, inv.y, p.x, p.y)
			if dd < best_d:
				best_d = dd
				best = p
	if best.x >= 0:
		inv.x = best.x
		inv.y = best.y
		inv.prev_x = best.x
		inv.prev_y = best.y
		_reset_path(inv)
		return true
	return false


static func spawn_army(m: UpMatch, a: UpMatch.Army, r: UpMatch.Rival) -> void:
	var total: int = a.melee + a.ranged
	if total <= 0:
		return
	var live_groups: int = 0
	for existing: UpMatch.Invader in r.invaders:
		if existing.hp > 0:
			live_groups += 1
	var group_budget: int = clampi(UpConfigRef.MAX_INVADER_GROUPS_PER_BATTLEFIELD - live_groups, 1, UpConfigRef.MAX_GROUPS_PER_ARMY)
	var both_types: bool = a.melee > 0 and a.ranged > 0
	var effective_budget: int = maxi(1, group_budget - (1 if both_types and group_budget > 1 else 0))
	var dynamic_group_size: int = maxi(UpConfigRef.INVADER_GROUP_SIZE,
		int(ceil(float(total) / float(effective_budget))))
	var specs: Array = []
	var melee_left: int = a.melee
	var ranged_left: int = a.ranged
	while melee_left > 0:
		var mn: int = mini(dynamic_group_size, melee_left)
		specs.append({"count": mn, "def": UpDefs.INVADERS["raider"]})
		melee_left -= mn
	while ranged_left > 0:
		var rn: int = mini(dynamic_group_size, ranged_left)
		specs.append({"count": rn, "def": UpDefs.INVADERS["marksman"]})
		ranged_left -= rn

	var lane_span: int = GRID * CELL - CELL
	var group_total: int = specs.size()
	for gi in group_total:
		var spec: Dictionary = specs[gi]
		var inv: UpMatch.Invader = m._new_invader()
		inv.id = m._next_id()
		inv.def = spec["def"]
		inv.member_hp = int(inv.def["hp"])
		inv.group_size = int(spec["count"])
		inv.hp = inv.group_size * inv.member_hp
		inv.wall = a.target_wall
		inv.army_id = a.id
		inv.force_color = Color("4f74b5") if a.attacker == 0 else m.rivals[a.attacker - 1].crest
		var lane: int = GRID * CELL / 2
		if group_total > 1:
			lane = CELL / 2 + gi * lane_span / (group_total - 1)
		inv.wall_lane = clampi(lane, CELL, GRID * CELL - CELL)
		var contact: Vector2i = m.invader_melee_wall_contact_point(inv.wall, inv.wall_lane) if str(inv.def["cat"]) == "melee" else m.invader_wall_contact_point(inv.wall, inv.wall_lane)
		# Match the home-fiefdom timing exactly. The announced countdown ends when
		# the army's FIRST troop can engage. If the army contains archers, all groups
		# begin one legal archer firing-range farther out so T-0 occurs at the ranged
		# firing line; melee then continues inward to physical wall contact.
		var preview_ticks: int = maxi(0, a.arrives - m.tick)
		var first_engagement_standoff: int = UpConfigRef.INVADER_WALL_RANGED_MAX if a.ranged > 0 else 0
		var approach_dist: int = first_engagement_standoff + preview_ticks * UpConfigRef.PREVIEW_APPROACH_SPEED
		var outward: Vector2i = m.invader_outward_dir(inv.wall)
		inv.x = contact.x + outward.x * approach_dist
		inv.y = contact.y + outward.y * approach_dist
		inv.prev_x = inv.x
		inv.prev_y = inv.y
		inv.at_wall = false
		inv.wall_contact_tick = -1
		inv.active_tick = a.arrives
		inv.last_progress_x = inv.x
		inv.last_progress_y = inv.y
		r.invaders.append(inv)


static func _army_invaders(r: UpMatch.Rival, army_id: int) -> Array:
	var result: Array = []
	for inv: UpMatch.Invader in r.invaders:
		if inv.hp > 0 and inv.army_id == army_id:
			result.append(inv)
	return result


static func sync_army_hp(m: UpMatch, a: UpMatch.Army, r: UpMatch.Rival) -> void:
	var melee_hp: int = 0
	var ranged_hp: int = 0
	for inv: UpMatch.Invader in r.invaders:
		if inv.hp <= 0 or inv.army_id != a.id:
			continue
		if str(inv.def["cat"]) == "melee":
			melee_hp += inv.hp
		else:
			ranged_hp += inv.hp
	a.melee_hp = melee_hp
	a.ranged_hp = ranged_hp


static func remove_army(r: UpMatch.Rival, army_id: int) -> void:
	for i in range(r.invaders.size() - 1, -1, -1):
		var inv: UpMatch.Invader = r.invaders[i]
		if inv.army_id == army_id:
			r.invaders.remove_at(i)


static func _record_casualties(m: UpMatch, r: UpMatch.Rival, inv: UpMatch.Invader, before_members: int) -> void:
	var after_members: int = m.invader_members(inv)
	var casualties: int = maxi(0, before_members - after_members)
	if casualties <= 0:
		return
	r.death_floats.append({"x": inv.x, "y": inv.y, "fired": m.tick, "seed": inv.id + m.tick * 31, "count": casualties})


static func _damage_groups_evenly(m: UpMatch, r: UpMatch.Rival, groups: Array, damage: int) -> void:
	if damage <= 0 or groups.is_empty():
		return
	var living: Array = []
	for inv: UpMatch.Invader in groups:
		if inv.hp > 0:
			living.append(inv)
	if living.is_empty():
		return
	var base: int = damage / living.size()
	var extra: int = damage % living.size()
	for i in living.size():
		var inv2: UpMatch.Invader = living[i]
		var before_members: int = m.invader_members(inv2)
		inv2.hp = maxi(0, inv2.hp - base - (1 if i < extra else 0))
		_record_casualties(m, r, inv2, before_members)


static func _rival_wall_blocks_invaders(r: UpMatch.Rival, d: String) -> bool:
	# Rebuilt-to-half walls are solid again. The collapse flag remains true until
	# full reconstruction, so passability must also consider current wall HP.
	return not bool(r.wall_collapsed[d]) or int(r.wall_hp[d]) >= UpConfigRef.HP_PARTIAL


static func _invader_physically_inside(m: UpMatch, inv: UpMatch.Invader) -> bool:
	var span: int = GRID * CELL
	return inv.x >= 0 and inv.x <= span and inv.y >= 0 and inv.y <= span


static func _invader_physically_outside_wall(m: UpMatch, inv: UpMatch.Invader, d: String) -> bool:
	var span: int = GRID * CELL
	match d:
		"N": return inv.y < 0 and inv.x >= 0 and inv.x <= span
		"S": return inv.y > span and inv.x >= 0 and inv.x <= span
		"W": return inv.x < 0 and inv.y >= 0 and inv.y <= span
		"E": return inv.x > span and inv.y >= 0 and inv.y <= span
		_: return false


static func _step_wall_defense(m: UpMatch, r: UpMatch.Rival, d: String) -> void:
	if not _rival_wall_blocks_invaders(r, d):
		return
	var melee_targets: Array = []
	var ranged_targets: Array = []
	var wall_point: Vector2i = m.wall_point(d)
	var archer_range: int = int(UpDefs.DEFENDERS["archer"].get("range", 0))
	var archer_range_sq: int = archer_range * archer_range
	for inv: UpMatch.Invader in r.invaders:
		if inv.hp <= 0 or not m.invader_combat_active(inv):
			continue
		var physically_inside: bool = _invader_physically_inside(m, inv)
		if not physically_inside and not m._exterior_invader_engagement_eligible(inv, d):
			continue
		var horiz: bool = d == "N" or d == "S"
		var perp: int = absi(inv.y - wall_point.y) if horiz else absi(inv.x - wall_point.x)
		# Exterior wall defense is measured perpendicular to the whole parapet,
		# matching the home-fiefdom rule. Interior targets keep normal radial range.
		var in_archer_range: bool = (perp * perp <= archer_range_sq) if not physically_inside else (_dist_sq(wall_point.x, wall_point.y, inv.x, inv.y) <= archer_range_sq)
		if not physically_inside and str(inv.def.get("cat", "")) == "ranged" and inv.wall == d:
			var inv_attack_range: int = mini(int(inv.def.get("range", UpConfigRef.REACH)), UpConfigRef.INVADER_WALL_RANGED_MAX)
			if perp <= inv_attack_range:
				in_archer_range = true
		if not physically_inside:
			# Outside enemies belong to exactly one wall. Require both the assigned
			# wall and actual side to match, AND normal archer range.
			if inv.wall != d or not _invader_physically_outside_wall(m, inv, d):
				continue
			if str(inv.def["cat"]) == "melee" and inv.at_wall:
				melee_targets.append(inv)
			if in_archer_range:
				ranged_targets.append(inv)
		elif in_archer_range:
			# Any invader physically inside may be targeted if it is within range.
			ranged_targets.append(inv)
	if m.tick >= int(r.wall_next_melee[d]) and not melee_targets.is_empty():
		r.wall_next_melee[d] = m.tick + int(UpDefs.DEFENDERS["infantry"]["iv"])
		var defenders: int = m._army_units(int(r.wall_hp[d]), int(UpDefs.DEFENDERS["infantry"]["hp"]))
		_damage_groups_evenly(m, r, melee_targets, defenders * int(UpDefs.DEFENDERS["infantry"]["dmg"]))
	if m.tick >= int(r.wall_next_ranged[d]) and not ranged_targets.is_empty():
		r.wall_next_ranged[d] = m.tick + int(UpDefs.DEFENDERS["archer"]["iv"])
		var archers: int = m._army_units(int(r.wall_ranged_hp[d]), int(UpDefs.DEFENDERS["archer"]["hp"]))
		_damage_groups_evenly(m, r, ranged_targets, archers * int(UpDefs.DEFENDERS["archer"]["dmg"]))
		var arrow_count: int = mini(ranged_targets.size(), UpConfigRef.MAX_GROUP_ARROW_VISUALS)
		for ai in arrow_count:
			var arrow_target: UpMatch.Invader = ranged_targets[ai]
			var fire_x: int = arrow_target.x if (d == "N" or d == "S") and not arrow_target.inside else wall_point.x
			var fire_y: int = wall_point.y if (d == "N" or d == "S") or arrow_target.inside else arrow_target.y
			r.shots.append({"fx": fire_x, "fy": fire_y, "tx": arrow_target.x, "ty": arrow_target.y, "fired": m.tick, "hostile": false})


static func _update_wall_state(m: UpMatch, r: UpMatch.Rival, d: String) -> void:
	if not bool(r.wall_collapsed[d]) and int(r.wall_hp[d]) < UpConfigRef.HP_COLLAPSE:
		r.wall_collapsed[d] = true
		r.wall_collapse_tick[d] = m.tick
		r.wall_cooldown[d] = UpConfigRef.REBUILD_COOLDOWN
		r.wall_hp[d] = 0
		r.wall_ranged_hp[d] = 0
		m.log_msg("%s's %s wall has collapsed." % [r.name, UpMatch.dir_name(d)], "")
	if bool(r.wall_collapsed[d]) and int(r.wall_hp[d]) >= UpConfigRef.HP_FULL:
		r.wall_collapsed[d] = false
		r.wall_collapse_tick[d] = -1
		m.log_msg("%s's %s wall is fully rebuilt and standing again." % [r.name, UpMatch.dir_name(d)], "")


static func _step_turret_defense(m: UpMatch, r: UpMatch.Rival, tid: String) -> void:
	var adj: Array = UpMatch.TURRET_WALLS[tid]
	# Same support rule as the player: both connected walls must be completely
	# down for the round tower to stay collapsed. Rebuilding either wall (HP > 0)
	# immediately rebuilds the tower with it.
	var a_down: bool = bool(r.wall_collapsed[adj[0]]) and int(r.wall_hp[adj[0]]) <= 0
	var b_down: bool = bool(r.wall_collapsed[adj[1]]) and int(r.wall_hp[adj[1]]) <= 0
	var destroyed: bool = a_down and b_down
	if destroyed:
		# Same rule as Ironcrest: when both supporting walls are down, everyone
		# stationed in the turret is lost. Rebuilding either wall restores the
		# platform, but not the soldiers who fell with it.
		r.turret_melee_hp[tid] = 0
		r.turret_ranged_hp[tid] = 0
		return

	var turret_pos: Vector2i = m.turret_point(tid)
	var melee_targets: Array = []
	var ranged_targets: Array = []
	# Turret archer coverage is the distance from the turret to the midpoint of
	# either connected wall: half of each connected wall.
	var turret_range_sq: int = m._turret_range_sq(tid, turret_pos)
	for inv: UpMatch.Invader in r.invaders:
		if inv.hp <= 0 or not m.invader_combat_active(inv):
			continue
		var in_range: bool = _dist_sq(turret_pos.x, turret_pos.y, inv.x, inv.y) <= turret_range_sq
		if not inv.inside:
			if not (inv.wall in adj):
				continue
			if not m._turret_covers_lane(tid, inv.wall, inv.wall_lane):
				continue
			if not m._exterior_invader_engagement_eligible(inv, inv.wall):
				continue
			# Any invading archer already able to damage this connected wall is
			# guaranteed to be answerable by the appropriate adjacent turret.
			var guaranteed_reply: bool = false
			if str(inv.def.get("cat", "")) == "ranged" and _invader_physically_outside_wall(m, inv, inv.wall):
				var wp: Vector2i = m.wall_point(inv.wall)
				var perp: int = absi(inv.y - wp.y) if inv.wall == "N" or inv.wall == "S" else absi(inv.x - wp.x)
				var inv_attack_range: int = mini(int(inv.def.get("range", UpConfigRef.REACH)), UpConfigRef.INVADER_WALL_RANGED_MAX)
				guaranteed_reply = perp <= inv_attack_range
			if str(inv.def["cat"]) == "melee" and inv.at_wall:
				melee_targets.append(inv)
			if in_range or guaranteed_reply:
				ranged_targets.append(inv)
		elif in_range:
			ranged_targets.append(inv)

	if m.tick >= int(r.turret_next_melee[tid]) and not melee_targets.is_empty():
		r.turret_next_melee[tid] = m.tick + int(UpDefs.DEFENDERS["infantry"]["iv"])
		var melee_count: int = m._army_units(int(r.turret_melee_hp[tid]), int(UpDefs.DEFENDERS["infantry"]["hp"]))
		_damage_groups_evenly(m, r, melee_targets, melee_count * int(UpDefs.DEFENDERS["infantry"]["dmg"]))

	if m.tick >= int(r.turret_next_ranged[tid]) and not ranged_targets.is_empty():
		r.turret_next_ranged[tid] = m.tick + int(UpDefs.DEFENDERS["archer"]["iv"])
		var ranged_count: int = m._army_units(int(r.turret_ranged_hp[tid]), int(UpDefs.DEFENDERS["archer"]["hp"]))
		_damage_groups_evenly(m, r, ranged_targets, ranged_count * int(UpDefs.DEFENDERS["archer"]["dmg"]))
		var arrow_count: int = mini(ranged_targets.size(), UpConfigRef.MAX_GROUP_ARROW_VISUALS)
		for ai in arrow_count:
			var arrow_target: UpMatch.Invader = ranged_targets[ai]
			r.shots.append({"fx": turret_pos.x, "fy": turret_pos.y, "tx": arrow_target.x, "ty": arrow_target.y, "fired": m.tick, "hostile": false})


static func _destroy_building(m: UpMatch, r: UpMatch.Rival, rid: int, attacker: int) -> void:
	for i in r.buildings.size():
		var rec: Dictionary = r.buildings[i]
		if _record_id(rec) != rid:
			continue
		var bid: String = str(rec["def"]["id"])
		var bname: String = str(rec["def"]["name"])
		r.buildings.remove_at(i)
		r.purchases[bid] = maxi(0, int(r.purchases[bid]) - 1)
		m._rival_rebuild_layout_occupancy(r)
		m.log_msg("%s destroyed %s's %s — %d buildings remain." % [m._player_name(attacker), r.name, bname, r.buildings.size()], "")
		# Any path to the old target must be reacquired against the new occupancy.
		for inv: UpMatch.Invader in r.invaders:
			if inv.tgt_id == rid:
				inv.tgt_id = -1
				inv.tgt_kind = ""
				_reset_path(inv)
		return


static func _move_inside(m: UpMatch, r: UpMatch.Rival, inv: UpMatch.Invader, attacker: int) -> void:
	if _recover_illegal_position(r, inv):
		return
	var rec: Dictionary = _find_building(r, inv.tgt_id)
	if inv.tgt_id < 0 or rec.is_empty():
		_acquire_target(m, r, inv)
		rec = _find_building(r, inv.tgt_id)
		_reset_path(inv)
	if rec.is_empty():
		return

	var ranged: bool = str(inv.def["cat"]) == "ranged"
	var distance_sq: int = _building_distance_sq(rec, inv.x, inv.y)
	var distance: int = _isqrt(distance_sq)
	var target_center: Vector2i = _building_center(rec)

	# Raiders use the same two-stage building approach as the player's invaders:
	# path to an adjacent empty cell, then close the final half-cell directly to
	# the exact occupied-cell edge. They never damage a building from a gap.
	if not ranged and distance > UpConfigRef.CROWD_MELEE_FRONT_REACH:
		inv.structure_contact_tick = -1
		var contact: Vector2i = _building_contact_point(rec, inv.x, inv.y)
		var here_cell: Vector2i = _cell_from_world(inv.x, inv.y)
		var here_center: Vector2i = _world_from_cell(here_cell)
		var in_goal_cell: bool = _building_distance_sq(rec, here_center.x, here_center.y) <= (CELL / 2) * (CELL / 2)
		var direct_close_distance: int = CELL / 2 + UpConfigRef.SPEED_INSIDE
		if distance <= direct_close_distance or in_goal_cell:
			var before_x: int = inv.x
			var before_y: int = inv.y
			if _move_toward(r, inv, contact, UpConfigRef.SPEED_INSIDE):
				if inv.x == contact.x and inv.y == contact.y and (before_x != inv.x or before_y != inv.y):
					inv.structure_contact_tick = m.tick
			return

		# Shared reverse flow field. Every melee packet attacking this building
		# reads the same directional map instead of constructing its own A* path.
		# The exact footprint-contact branch above still owns the final approach.
		_follow_flow(r, inv, rec)
		return

	if ranged:
		var attack_range: int = int(inv.def.get("range", UpConfigRef.REACH))
		var in_range: bool = distance_sq <= attack_range * attack_range
		if in_range:
			in_range = _has_los(r, inv.x, inv.y, target_center.x, target_center.y, inv.tgt_id)
		if not in_range:
			inv.structure_contact_tick = -1
			# Open-courtyard direct-line movement bypasses pathfinding completely.
			# A* remains only for paths actually obstructed by structures.
			if _segment_clear(r, inv.x, inv.y, target_center.x, target_center.y):
				_move_toward(r, inv, target_center, UpConfigRef.SPEED_INSIDE)
				return
			if inv.path_target_id != inv.tgt_id or inv.path_index >= inv.path.size():
				inv.path = _build_path(r, inv, rec, attack_range)
				inv.path_index = 0
				inv.path_target_kind = "b"
				inv.path_target_id = inv.tgt_id
			if inv.path_index < inv.path.size():
				var waypoint2: Vector2i = inv.path[inv.path_index]
				if _dist_sq(inv.x, inv.y, waypoint2.x, waypoint2.y) <= UpConfigRef.PATH_WAYPOINT_REACH * UpConfigRef.PATH_WAYPOINT_REACH:
					inv.path_index += 1
				if inv.path_index < inv.path.size():
					waypoint2 = inv.path[inv.path_index]
					_move_toward(r, inv, waypoint2, UpConfigRef.SPEED_INSIDE)
			return

	# The first melee rank attacks on the same tick its sprite-leading edge reaches
	# the structure. Rear ranks join progressively, matching the home battlefield.
	if not ranged and _building_distance_sq(rec, inv.x, inv.y) > UpConfigRef.CROWD_MELEE_FRONT_REACH * UpConfigRef.CROWD_MELEE_FRONT_REACH:
		_reset_path(inv)
		return
	if inv.structure_contact_tick < 0:
		inv.structure_contact_tick = m.tick

	if m.tick < inv.next_attack:
		return
	inv.next_attack = m.tick + int(inv.def["iv"])
	var members: int = m.invader_contact_members(inv, inv.structure_contact_tick)
	if members <= 0:
		return
	var damage: int = int(inv.def["dmg"]) * members
	rec["hp"] = int(rec["hp"]) - damage
	rec["flash"] = 4
	# Building attrition mirrors the player's invasion rules.
	var before_members: int = m.invader_members(inv)
	inv.hp = maxi(0, inv.hp - int(inv.def["attr"]) * members)
	_record_casualties(m, r, inv, before_members)
	if not ranged:
		var hit: Vector2i = _building_contact_point(rec, inv.x, inv.y)
		r.melee_impacts.append({"x": hit.x, "y": hit.y, "fired": m.tick})
	else:
		r.shots.append({"fx": inv.x, "fy": inv.y, "tx": target_center.x, "ty": target_center.y, "fired": m.tick, "hostile": true})
	if int(rec["hp"]) <= 0:
		_destroy_building(m, r, inv.tgt_id, attacker)


static func step(m: UpMatch, r: UpMatch.Rival) -> void:
	if r.defeated:
		return
	for d in UpMatch.DIRS:
		if int(r.wall_cooldown[d]) > 0:
			r.wall_cooldown[d] = int(r.wall_cooldown[d]) - 1
		_update_wall_state(m, r, d)
		_step_wall_defense(m, r, d)
	for tid in UpMatch.TURRETS:
		_step_turret_defense(m, r, tid)

	for inv: UpMatch.Invader in r.invaders:
		if inv.hp <= 0:
			continue
		inv.prev_x = inv.x
		inv.prev_y = inv.y
		var d: String = inv.wall
		if not inv.inside:
			# Same first-engagement countdown semantics as the home battlefield.
			# At T-0 marksmen may begin firing if actually in range; infantry from a
			# mixed army keeps advancing at full approach speed until it touches stone.
			if inv.active_tick > 0 and m.tick >= inv.active_tick:
				inv.active_tick = 0
			var wall_blocks: bool = _rival_wall_blocks_invaders(r, d)
			var contact: Vector2i = m.invader_melee_wall_contact_point(d, inv.wall_lane) if str(inv.def["cat"]) == "melee" else m.invader_wall_contact_point(d, inv.wall_lane)

			# Surrounding-fiefdom battles now use the same contact semantics as home:
			# ranged troops stop/fire as soon as their lane enters range; melee stops
			# exactly on first physical contact and feeds additional ranks into combat.
			if wall_blocks and str(inv.def["cat"]) == "ranged":
				var wp_lane: Vector2i = m.wall_point(d)
				match d:
					"N", "S": wp_lane.x = inv.x
					"W", "E": wp_lane.y = inv.y
				var rr: int = mini(int(inv.def.get("range", UpConfigRef.REACH)), UpConfigRef.INVADER_WALL_RANGED_MAX)
				if _dist_sq(inv.x, inv.y, wp_lane.x, wp_lane.y) <= rr * rr:
					inv.active_tick = 0
					inv.at_wall = false
					if inv.wall_contact_tick < 0:
						inv.wall_contact_tick = m.tick
					if m.tick >= inv.next_attack:
						inv.next_attack = m.tick + int(inv.def["iv"])
						var ranged_members: int = m.invader_contact_members(inv, inv.wall_contact_tick)
						var ranged_damage: int = int(inv.def["dmg"]) * ranged_members
						if int(r.wall_ranged_hp[d]) > 0:
							r.wall_ranged_hp[d] = maxi(0, int(r.wall_ranged_hp[d]) - ranged_damage)
						else:
							r.wall_hp[d] = maxi(0, int(r.wall_hp[d]) - ranged_damage)
						r.shots.append({"fx": inv.x, "fy": inv.y, "tx": wp_lane.x, "ty": wp_lane.y, "fired": m.tick, "hostile": true})
						_update_wall_state(m, r, d)
					continue
				inv.wall_contact_tick = -1
				_move_toward(r, inv, contact, UpConfigRef.PREVIEW_APPROACH_SPEED if inv.active_tick > 0 else UpConfigRef.SPEED_APPROACH)
				continue

			if inv.active_tick > 0:
				if inv.x != contact.x or inv.y != contact.y:
					_move_toward(r, inv, contact, UpConfigRef.PREVIEW_APPROACH_SPEED)
					continue
				inv.active_tick = 0
				inv.at_wall = true
				inv.wall_contact_tick = m.tick

			if wall_blocks:
				if inv.x != contact.x or inv.y != contact.y:
					_move_toward(r, inv, contact, UpConfigRef.SPEED_APPROACH)
					continue
				inv.at_wall = true
				if inv.wall_contact_tick < 0:
					inv.wall_contact_tick = m.tick
				if m.tick < inv.next_attack:
					continue
				inv.next_attack = m.tick + int(inv.def["iv"])
				var members: int = m.invader_contact_members(inv, inv.wall_contact_tick)
				if members <= 0:
					continue
				var damage: int = int(inv.def["dmg"]) * members
				r.wall_hp[d] = maxi(0, int(r.wall_hp[d]) - damage)
				var hit: Vector2i = m.melee_wall_impact_point(d, inv.wall_lane)
				r.melee_impacts.append({"x": hit.x, "y": hit.y, "fired": m.tick})
				_update_wall_state(m, r, d)
				continue

			inv.at_wall = false
			inv.wall_contact_tick = -1
			var entry: Vector2i = m.invader_entry_point(d, inv.wall_lane)
			match d:
				"N", "S": inv.x = entry.x
				"W", "E": inv.y = entry.y
			var entry_dist: int = _isqrt(_dist_sq(inv.x, inv.y, entry.x, entry.y))
			if entry_dist > UpConfigRef.SPEED_APPROACH:
				_move_toward(r, inv, entry, UpConfigRef.SPEED_APPROACH)
				continue
			inv.x = entry.x
			inv.y = entry.y
			inv.inside = true
			inv.last_progress_x = inv.x
			inv.last_progress_y = inv.y
			_reset_path(inv)
			continue

		inv.x = clampi(inv.x, CELL / 2, GRID * CELL - CELL / 2)
		inv.y = clampi(inv.y, CELL / 2, GRID * CELL - CELL / 2)
		_move_inside(m, r, inv, _army_attacker(m, inv.army_id))

	# Remove dead groups after all groups have acted this tick.
	for i in range(r.invaders.size() - 1, -1, -1):
		var dead_inv: UpMatch.Invader = r.invaders[i]
		if dead_inv.hp <= 0:
			r.invaders.remove_at(i)

	# Presentation event lifetimes for the reconnaissance view.
	for i in range(r.shots.size() - 1, -1, -1):
		if m.tick - int(r.shots[i]["fired"]) > UpConfigRef.ARROW_FLIGHT:
			r.shots.remove_at(i)
	for i in range(r.melee_impacts.size() - 1, -1, -1):
		if m.tick - int(r.melee_impacts[i]["fired"]) > UpConfigRef.MELEE_IMPACT_TICKS:
			r.melee_impacts.remove_at(i)
	for i in range(r.death_floats.size() - 1, -1, -1):
		if m.tick - int(r.death_floats[i]["fired"]) > UpConfigRef.DEATH_FLOAT_TICKS:
			r.death_floats.remove_at(i)
	for rec in r.buildings:
		if int(rec.get("flash", 0)) > 0:
			rec["flash"] = int(rec.get("flash", 0)) - 1


static func _army_attacker(m: UpMatch, army_id: int) -> int:
	for a: UpMatch.Army in m.armies:
		if a.id == army_id:
			return a.attacker
	return -1
