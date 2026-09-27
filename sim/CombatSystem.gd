extends RefCounted
const UpConfigRef = preload("res://sim/UpConfig.gd")

## High-pressure combat rules extracted from UpMatch.
## UpMatch remains the authoritative state owner; this module only operates on
## the match instance passed to it. Keeping state ownership in one place makes
## this refactor behavior-preserving while isolating frequently changed rules.

const DIRS := ["N", "E", "S", "W"]
const TURRETS := ["NW", "NE", "SE", "SW"]
const TURRET_WALLS := {
	"NW": ["N", "W"], "NE": ["N", "E"],
	"SE": ["S", "E"], "SW": ["S", "W"],
}
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


static func _scatter(id: int, amount: int) -> Vector2i:
	return Vector2i(((id * 37) % 101 - 50) * amount / 50, ((id * 61) % 101 - 50) * amount / 50)

static func _distribute_hits_to_defender_groups(m: UpMatch, arr: Array, hits: int, dmg_per_hit: int, key: int) -> void:
	## Preserve individual-hit semantics while distributing hits across adaptive
	## defender packets. This keeps
	## exact total damage/casualties while making the cost O(groups), not O(troops).
	if hits <= 0 or arr.is_empty():
		return
	var defenders: int = m.garrison_count(arr)
	if defenders <= 0:
		return
	var base_hits: int = hits / defenders
	var extra: int = hits % defenders
	var start: int = int(m._strike_cursor.get(key, 0)) % arr.size()
	var extra_left: int = extra
	for off in arr.size():
		var u: UpMatch.Unit = arr[(start + off) % arr.size()]
		var members: int = m.unit_members(u)
		if members <= 0:
			continue
		var group_hits: int = base_hits * members
		if extra_left > 0:
			var take: int = mini(extra_left, members)
			group_hits += take
			extra_left -= take
		if group_hits > 0:
			m._mark_unit_damage(u, group_hits * dmg_per_hit)
		if extra_left <= 0 and base_hits == 0:
			break
	m._strike_cursor[key] = (start + 1) % maxi(1, arr.size())


static func queue_group_melee_wall_strikes(m: UpMatch, inv: UpMatch.Invader, w: UpMatch.Wall, attacks: Array) -> void:
	if w.melee.is_empty():
		return
	var members: int = int(m.invader_contact_members(inv, inv.wall_contact_tick))
	if members <= 0:
		return
	var dmg := int(inv.def["dmg"])
	var key: int = hash("wall-melee:" + w.dir)
	_distribute_hits_to_defender_groups(m, w.melee, members, dmg, key)
	# One compact presentation burst per attacking simulation group, positioned
	# on the visible wall face so it is not clipped beyond the board edge.
	var hit: Vector2i = m.melee_wall_impact_point(w.dir, inv.wall_lane)
	m._record_melee_impact(hit.x, hit.y)


static func collect_invader_ranged_strike(m: UpMatch, inv: UpMatch.Invader, w: UpMatch.Wall, attacks: Array) -> void:
	var wall_range: int = mini(int(inv.def.get("range", UpConfigRef.REACH)), UpConfigRef.INVADER_WALL_RANGED_MAX)
	var range_sq: int = wall_range * wall_range
	var ranged_candidates: Array = []
	var melee_candidates: Array = []
	var wp: Vector2i = m.wall_point(w.dir)
	# Wall garrisons occupy the whole parapet, not only its midpoint.  Measure
	# attacker range to the point on this wall directly opposite the invader.
	# The previous midpoint distance created dead zones near both ends of a wall:
	# the invader could enter its perpendicular firing range, stop, animate shots,
	# yet find no legal target and therefore deal no damage.
	var wall_aim := wp
	if inv.wall == "N" or inv.wall == "S":
		wall_aim.x = inv.x
	else:
		wall_aim.y = inv.y
	var wd := _dist_sq(inv.x, inv.y, wall_aim.x, wall_aim.y)

	if not w.ranged.is_empty():
		ranged_candidates.append({"arr": w.ranged, "p": wall_aim, "d": wd, "k": "wr:" + str(w.dir)})
	if not w.melee.is_empty():
		melee_candidates.append({"arr": w.melee, "p": wall_aim, "d": wd, "k": "wm:" + str(w.dir)})
	for tid in TURRETS:
		if not (inv.wall in TURRET_WALLS[tid]):
			continue
		var tr = m.turrets[tid]
		if tr.destroyed:
			continue
		var tp: Vector2i = m.turret_point(tid)
		var td := _dist_sq(inv.x, inv.y, tp.x, tp.y)
		if not tr.ranged.is_empty():
			ranged_candidates.append({"arr": tr.ranged, "p": tp, "d": td, "k": "tr:" + str(tp)})
		if not tr.melee.is_empty():
			melee_candidates.append({"arr": tr.melee, "p": tp, "d": td, "k": "tm:" + str(tp)})

	var chosen: Dictionary = {}
	var best := 1 << 62
	for c in ranged_candidates:
		if int(c["d"]) <= range_sq and int(c["d"]) < best:
			best = int(c["d"])
			chosen = c
	if chosen.is_empty():
		best = 1 << 62
		for c in melee_candidates:
			if int(c["d"]) <= range_sq and int(c["d"]) < best:
				best = int(c["d"])
				chosen = c
	if chosen.is_empty():
		return

	var arr: Array = chosen["arr"]
	if arr.is_empty():
		return
	# Front ranks begin firing on the first tick they enter weapon range; rear ranks
	# join on subsequent ticks instead of the whole packet waiting/acting as one.
	var members: int = int(m.invader_contact_members(inv, inv.wall_contact_tick)) if inv.wall_contact_tick >= 0 else m.invader_members(inv)
	if members <= 0:
		return
	var dmg := int(inv.def["dmg"])
	var key2: int = hash(str(chosen["k"]))
	_distribute_hits_to_defender_groups(m, arr, members, dmg, key2)

	var p: Vector2i = chosen["p"]
	# Aim at the stretch of wall directly opposite this group, not the wall's
	# centre point. Attackers and defenders stand on the same line, so aiming at
	# the centre drew arrows running lengthwise along the wall instead of across
	# at the defenders facing them.
	# ("d" in these candidate dictionaries is a distance, not a direction - the
	# wall this group is attacking is on the invader itself.)
	var horiz2: bool = inv.wall == "N" or inv.wall == "S"
	var aim: Vector2i = Vector2i(inv.x, p.y) if horiz2 else Vector2i(p.x, inv.y)
	var visual_arrows := mini(members, UpConfigRef.MAX_GROUP_ARROW_VISUALS)
	for n in visual_arrows:
		var sc := _scatter(inv.id + n * 97, UpConfigRef.ARCHER_SPREAD)
		m._record_shot(inv.x + sc.x / 4, inv.y + sc.y / 4, aim.x + sc.x / 2, aim.y + sc.y / 2, true)


static func collect_defending_wall_melee(m: UpMatch, attacks: Array) -> void:
	for d in DIRS:
		var w = m.walls[d]
		if w.melee.is_empty():
			continue
		var slot: String = m._wall_melee_slot(d)
		if not m._has_ready_defenders(slot):
			continue

		var targets: Array = []
		for inv: UpMatch.Invader in m.invaders:
			if inv.hp <= 0:
				continue
			if inv.inside or not inv.at_wall:
				continue
			if inv.wall != d:
				continue
			if not m.invader_combat_active(inv):
				continue
			if inv.def["cat"] != "melee":
				continue
			if not m.invader_melee_ready_at_wall(inv, d):
				continue
			targets.append(inv)

		if targets.is_empty():
			continue

		var ready: Array = m._take_ready_defenders(slot)
		var ti: int = 0
		for u: UpMatch.Unit in ready:
			if not m._defender_is_current(u, slot):
				continue
			var target = targets[ti % targets.size()]
			ti += 1
			m._schedule_defender_after_attack(u)
			m._mark_invader_damage(target, int(u.def["dmg"]) * m.unit_members(u))


static func collect_defending_ranged(m: UpMatch, attacks: Array) -> void:
	for d in DIRS:
		var w = m.walls[d]
		collect_wall_ranged(m, w.ranged, d, m.wall_point(d),
			Vector2i(1, 0) if d == "N" or d == "S" else Vector2i(0, 1), attacks)
	for tid in TURRETS:
		var tr = m.turrets[tid]
		if not tr.destroyed:
			collect_turret_ranged(m, tr.ranged, tid, m.turret_point(tid), attacks)


static func collect_wall_ranged(m: UpMatch, arr: Array, wall_dir: String, from: Vector2i, axis: Vector2i, attacks: Array) -> void:
	if arr.is_empty():
		return
	var slot: String = m._wall_ranged_slot(wall_dir)
	if not m._has_ready_defenders(slot):
		return

	var range_limit: int = int(m._max_ranged_range(arr))
	# Always inspect through the maximum legal invading-wall archer envelope. A
	# ranged invader that can currently damage this wall must be a valid reply
	# target for every defending archer stationed on the same parapet.
	var exterior_reply_range: int = maxi(range_limit, UpConfigRef.INVADER_WALL_RANGED_MAX)
	var candidates: Array = m._nearest_wall_front_invaders_combined(
		from, wall_dir, exterior_reply_range, UpConfigRef.WALL_ARCHER_SPREAD)
	if candidates.is_empty():
		return

	var ci: int = 0
	var ready: Array = m._take_ready_defenders(slot)
	for u: UpMatch.Unit in ready:
		if not m._defender_is_current(u, slot):
			continue

		# Range is constant per archer; it was being re-read from the def
		# dictionary on every candidate offset.
		var r: int = int(u.def.get("range", 0))
		var r_sq: int = r * r
		# Exterior attackers are measured perpendicular to the parapet.  A wall
		# garrison represents archers distributed along the full wall, so an invading
		# archer that can shoot the wall must be answerable by defending wall archers.
		# Interior targets still use the individual defender's lane.
		var picked: Dictionary = {}
		for offset in candidates.size():
			var idx := (ci + offset) % candidates.size()
			var c: Dictionary = candidates[idx]
			var target = c["u"]
			var perp: int = int(c["perp"])
			if not bool(target.inside):
				# Reciprocity rule: if this invading archer is in legal wall-attack
				# range, a wall archer on that same wall can always return fire.
				var guaranteed_reply: bool = m._invader_ranged_attacking_wall(target, wall_dir)
				if guaranteed_reply or perp <= r:
					picked = c
					ci = (idx + 1) % candidates.size()
					break
				continue
			var dl: int = absi(int(c["lane"]) - u.lane)
			if dl > r:
				continue
			if dl * dl + perp * perp <= r_sq:
				picked = c
				ci = (idx + 1) % candidates.size()
				break
		if picked.is_empty():
			m._keep_defender_ready(slot, u)
			continue

		var target = picked["u"]
		m._schedule_defender_after_attack(u)
		m._mark_invader_damage(target, int(u.def["dmg"]) * m.unit_members(u))
		m._retarget_invader_to_stationed_if_attacking_building(target, u)
		# Arrows are presentation only and capped at MAX_SHOTS. Once the buffer
		# is full _record_shot discards the result, so skip the scatter maths
		# entirely instead of computing it for thousands of archers per tick.
		if m.shots.size() < UpConfigRef.MAX_SHOTS:
			# Loose from where this archer actually stands on the wall, so volleys
			# fan out along its length instead of all leaving the centre point.
			var fire_lane: int = int(picked["lane"]) if not bool(target.inside) else u.lane
			var ox: int = fire_lane if axis.x == 1 else from.x
			var oy: int = from.y if axis.x == 1 else fire_lane
			m._record_shot(ox, oy, target.x, target.y, false)


static func collect_turret_ranged(m: UpMatch, arr: Array, tid: String, from: Vector2i, attacks: Array) -> void:
	if arr.is_empty():
		return
	var slot: String = m._turret_ranged_slot(tid)
	if not m._has_ready_defenders(slot):
		return
	var candidates: Array = m._nearest_turret_invaders(tid, from, UpConfigRef.TURRET_SPREAD)
	if candidates.is_empty():
		return
	var weights: Array = []
	var total_weight := 0
	for c in candidates:
		var distance: int = max(CELL, _isqrt(int(c["d"])))
		var weight: int = max(1, (1000 * CELL) / distance)
		weights.append(weight)
		total_weight += weight

	var ready: Array = m._take_ready_defenders(slot)
	for u: UpMatch.Unit in ready:
		if not m._defender_is_current(u, slot):
			continue
		var pick: int = abs(u.id * 1103515245 + m.tick * 12345) % max(1, total_weight)
		var ci := 0
		for j in weights.size():
			pick -= int(weights[j])
			if pick < 0:
				ci = j
				break
		var target = candidates[ci]["u"]
		m._schedule_defender_after_attack(u)
		m._mark_invader_damage(target, int(u.def["dmg"]) * m.unit_members(u))
		m._retarget_invader_to_stationed_if_attacking_building(target, u)
		if m.shots.size() < UpConfigRef.MAX_SHOTS:
			var sc := _scatter(u.id, UpConfigRef.ARCHER_SPREAD)
			m._record_shot(from.x + sc.x, from.y + sc.y, target.x, target.y, false)


static func apply_combat(m: UpMatch, attacks: Array) -> void:
	var dead_defender_slots: Dictionary = {}
	for u: UpMatch.Unit in m._dirty_units:
		u.hp -= u.pending_damage
		u.pending_damage = 0
		u.group_size = m.unit_members(u)
		if u.hp <= 0:
			var slot: String = m._defender_slot_for_unit(u)
			if slot != "":
				dead_defender_slots[slot] = true
			m._unregister_stationed_unit(u)
	m._dirty_units.clear()

	for inv: UpMatch.Invader in m._dirty_invaders:
		var before_members: int = int(m.invader_members(inv))
		inv.hp -= inv.pending_damage + inv.pending_attr
		var after_members: int = int(m.invader_members(inv))
		var casualties := maxi(0, before_members - after_members)
		if casualties > 0:
			# Hybrid simulation groups stay compact, but presentation/statistics
			# remain soldier-true: one skull and one kill count per actual casualty.
			m._record_invader_death_floats(inv, casualties)
			m.stat_killed += casualties
		inv.pending_damage = 0
		inv.pending_attr = 0
	m._dirty_invaders.clear()

	for s: UpMatch.Sortie in m._dirty_sorties:
		s.hp -= s.pending_damage
		s.pending_damage = 0
		s.group_size = m.sortie_members(s)
	m._dirty_sorties.clear()

	var destroyed: Array = []
	for b: UpMatch.Building in m._dirty_buildings:
		b.hp -= b.pending_damage
		b.pending_damage = 0
		b.flash = 4
		if b.hp <= 0:
			destroyed.append(b.id)
	m._dirty_buildings.clear()
	for id in destroyed:
		m._destroy_building(int(id), false)

	if not dead_defender_slots.is_empty():
		m._purge_dead_defender_slots(dead_defender_slots.keys())
