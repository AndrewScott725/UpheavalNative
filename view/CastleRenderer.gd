class_name CastleRenderer
extends RefCounted
const UpMatch = preload("res://sim/UpMatch.gd")
const UpConfigRef = preload("res://sim/UpConfig.gd")


static func draw(v, rival = null) -> void:
	var dest: Rect2 = v._castle_art_dest_rect()

	# Authoritative overlap hierarchy (user-specified):
	# 1. North wall / rubble / partial: above landscape only.
	# 2. Northwest + Northeast towers: above north wall.
	# 3. South wall / rubble / partial: above landscape only.
	# 4. West + East walls / rubble / partial: above north towers and south wall.
	# 5. Southwest + Southeast towers: above west/east/south walls.
	# 6. Courtyard grid: topmost castle element, above every wall/tower state.
	_draw_wall(v, dest, "N", rival)
	_draw_tower(v, dest, "NW", rival)
	_draw_tower(v, dest, "NE", rival)
	_draw_wall(v, dest, "S", rival)
	_draw_wall(v, dest, "W", rival)
	_draw_wall(v, dest, "E", rival)
	_draw_tower(v, dest, "SW", rival)
	_draw_tower(v, dest, "SE", rival)

	if v.MODULAR_GRID_ART != null:
		v.draw_texture_rect(v.MODULAR_GRID_ART, dest, false)


static func draw_wall_foreground(v, rival = null) -> void:
	# Repaint only physical wall pixels above incoming attackers. This gives the
	# perimeter a true foreground occlusion layer while allowing wall/turret
	# defenders to be drawn afterward on top of the parapet. Rubble is intentionally
	# omitted so troops remain fully visible while flowing through an open breach.
	var dest: Rect2 = v._castle_art_dest_rect()
	for d in UpMatch.DIRS:
		var state := _wall_visual_state(v, d, rival)
		var physical: bool = false
		if String(state.get("mode", "single")) == "single":
			physical = String(state.get("state", "intact")) != "rubble"
		else:
			# Collapse animation is not a blocking wall; once collapse begins the
			# breach is authoritative and attackers may enter.
			physical = false
		if physical:
			_draw_wall(v, dest, d, rival)


static func _draw_wall(v, dest: Rect2, d: String, rival = null) -> void:
	var state := _wall_visual_state(v, d, rival)
	match state["mode"]:
		"single":
			_draw_texture(v, _wall_texture(v, d, String(state["state"])), dest, 1.0)
		"crossfade":
			_draw_texture(v, _wall_texture(v, d, String(state["from"])), dest, 1.0 - float(state["t"]))
			_draw_texture(v, _wall_texture(v, d, String(state["to"])), dest, float(state["t"]))


static func _draw_tower(v, dest: Rect2, tid: String, rival = null) -> void:
	var state := _tower_visual_state(v, tid, rival)
	match state["mode"]:
		"single":
			_draw_texture(v, _tower_texture(v, tid, String(state["state"])), dest, 1.0)
		"crossfade":
			_draw_texture(v, _tower_texture(v, tid, String(state["from"])), dest, 1.0 - float(state["t"]))
			_draw_texture(v, _tower_texture(v, tid, String(state["to"])), dest, float(state["t"]))


static func _draw_texture(v, tex: Texture2D, dest: Rect2, alpha: float) -> void:
	if tex == null or alpha <= 0.0:
		return
	v.draw_texture_rect(tex, dest, false, Color(1, 1, 1, clampf(alpha, 0.0, 1.0)))


static func _wall_texture(v, d: String, state: String) -> Texture2D:
	match state:
		"rubble":
			return v.MODULAR_WALL_RUBBLE.get(d, null) as Texture2D
		"partial":
			return v.MODULAR_WALL_PARTIAL.get(d, null) as Texture2D
		_:
			return v.MODULAR_WALL_INTACT.get(d, null) as Texture2D


static func _tower_texture(v, tid: String, state: String) -> Texture2D:
	match state:
		"rubble":
			return v.MODULAR_TOWER_RUBBLE.get(tid, null) as Texture2D
		"partial":
			return v.MODULAR_TOWER_PARTIAL.get(tid, null) as Texture2D
		_:
			return v.MODULAR_TOWER_INTACT.get(tid, null) as Texture2D


static func _wall_visual_state(v, d: String, rival = null) -> Dictionary:
	var wall_hp: int = 0
	var wall_collapsed: bool = false
	var collapse_tick: int = -1
	var state: String = "intact"
	if rival == null:
		var w = v.match_ref.walls[d]
		wall_hp = w.hp()
		wall_collapsed = w.collapsed
		collapse_tick = w.collapse_tick
		state = v.match_ref.wall_state(w)
	else:
		wall_hp = int(rival.wall_hp[d])
		wall_collapsed = bool(rival.wall_collapsed[d])
		collapse_tick = int(rival.wall_collapse_tick.get(d, -1))
		state = v._rival_wall_visual_state(rival, d)

	# Damage never uses the half-built art. A wall remains visually intact until
	# it actually collapses, then dissolves directly from intact -> rubble.
	if state == "collapsing":
		var t: float = 1.0
		if collapse_tick >= 0:
			t = clampf(float(v.match_ref.tick - collapse_tick + 1) / float(UpConfigRef.WALL_COLLAPSE_ANIM_TICKS), 0.0, 1.0)
		return {"mode": "crossfade", "from": "intact", "to": "rubble", "t": t}

	# Half-built art exists only on the rebuild path: rubble -> half-built -> intact.
	if wall_collapsed:
		if wall_hp >= UpConfigRef.HP_PARTIAL:
			return {"mode": "single", "state": "partial"}
		return {"mode": "single", "state": "rubble"}

	# Standing/damaged walls remain on the intact artwork. Once HP_FULL is reached
	# the simulation clears collapsed and this is the full rebuilt wall.
	return {"mode": "single", "state": "intact"}


static func _tower_visual_state(v, tid: String, rival = null) -> Dictionary:
	var adj: Array = UpMatch.TURRET_WALLS[tid]
	var a_hp: int = 0
	var b_hp: int = 0
	var a_collapsed: bool = false
	var b_collapsed: bool = false
	var a_collapse_tick: int = -1
	var b_collapse_tick: int = -1
	if rival == null:
		var aw = v.match_ref.walls[adj[0]]
		var bw = v.match_ref.walls[adj[1]]
		a_hp = aw.hp()
		b_hp = bw.hp()
		a_collapsed = aw.collapsed
		b_collapsed = bw.collapsed
		a_collapse_tick = aw.collapse_tick
		b_collapse_tick = bw.collapse_tick
	else:
		a_hp = int(rival.wall_hp[adj[0]])
		b_hp = int(rival.wall_hp[adj[1]])
		a_collapsed = bool(rival.wall_collapsed[adj[0]])
		b_collapsed = bool(rival.wall_collapsed[adj[1]])
		a_collapse_tick = int(rival.wall_collapse_tick.get(adj[0], -1))
		b_collapse_tick = int(rival.wall_collapse_tick.get(adj[1], -1))

	var both_collapsed: bool = a_collapsed and b_collapsed
	if not both_collapsed:
		# One standing wall is enough to support a full round tower.
		return {"mode": "single", "state": "intact"}

	# Both walls are down. Rebuild path begins only after one support reaches the
	# configured half-built/rebuilding value. Until then the tower stays rubble.
	if a_hp >= UpConfigRef.HP_PARTIAL or b_hp >= UpConfigRef.HP_PARTIAL:
		return {"mode": "single", "state": "partial"}

	# On collapse, dissolve directly from full tower -> rubble; never pass through
	# half-built while the tower is being knocked down.
	var collapse_tick: int = maxi(a_collapse_tick, b_collapse_tick)
	if collapse_tick >= 0 and v.match_ref.tick - collapse_tick < UpConfigRef.WALL_COLLAPSE_ANIM_TICKS:
		var t: float = clampf(float(v.match_ref.tick - collapse_tick + 1) / float(UpConfigRef.WALL_COLLAPSE_ANIM_TICKS), 0.0, 1.0)
		return {"mode": "crossfade", "from": "intact", "to": "rubble", "t": t}
	return {"mode": "single", "state": "rubble"}

