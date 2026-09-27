class_name TooltipRenderer
extends RefCounted

const UpConfigRef = preload("res://sim/UpConfig.gd")
const UpDefsRef = preload("res://sim/UpDefs.gd")

static func draw(v) -> void:
	if _draw_army(v):
		return
	_draw_wall(v)
	_draw_turret(v)

static func _draw_army(v) -> bool:
	if v.hover_army_id < 0 or v.match_ref == null:
		return false
	var invaders: Array = v.match_ref.invaders
	if v.recon_rival_index >= 0 and v.recon_rival_index < v.match_ref.rivals.size():
		invaders = v.match_ref.rivals[v.recon_rival_index].invaders
	var infantry: int = 0
	var archers: int = 0
	var fallback_color: Color = v.C_BANNER
	for inv in invaders:
		if inv.hp <= 0 or inv.army_id != v.hover_army_id:
			continue
		fallback_color = inv.force_color
		var units: int = v.match_ref.invader_members(inv)
		if str(inv.def.get("cat", "")) == "ranged":
			archers += units
		else:
			infantry += units

	# Resolve the War Camp's source fiefdom from the persistent Army record so the
	# tooltip identifies who sent the formation, not the fiefdom currently viewed.
	var source_name: String = "Unknown Fiefdom"
	var source_color: Color = fallback_color
	var source_device: int = 0
	for army in v.match_ref.armies:
		if army.id != v.hover_army_id:
			continue
		var attacker: int = int(army.attacker)
		source_name = v.match_ref._player_name(attacker)
		if attacker == 0:
			source_color = v.C_BANNER
			source_device = 0
		elif attacker > 0 and attacker <= v.match_ref.rivals.size():
			var source_rival = v.match_ref.rivals[attacker - 1]
			source_color = source_rival.crest
			source_device = int(source_rival.device)
		break

	var rows: Array = [
		["Infantry:", str(infantry)],
		["Archers:", str(archers)],
	]
	var bw := 238.0
	var bh := 62.0 + rows.size() * 22.0
	var pos: Vector2 = v.hover_army_screen_pos + Vector2(18.0, 18.0)
	_draw_army_stat(v, source_name, source_color, source_device, rows, pos, bw, bh)
	return true


static func _draw_army_stat(v, source_name: String, source_color: Color, source_device: int, rows: Array, pos: Vector2, bw: float, bh: float) -> void:
	pos.x = clampf(pos.x, 8.0, maxf(8.0, v.size.x - bw - 8.0))
	pos.y = clampf(pos.y, 8.0, maxf(8.0, v.size.y - bh - 8.0))
	v.draw_rect(Rect2(pos, Vector2(bw, bh)), Color(0.086, 0.125, 0.180, 0.66))
	v.draw_rect(Rect2(pos, Vector2(bw, bh)), v.C_GOLD, false, 1.5)
	v.draw_string(v.font_disp, pos + Vector2(12, 24), "Incoming Army", HORIZONTAL_ALIGNMENT_LEFT, -1, 18, v.C_GOLD)
	# Compact faction banner + source fiefdom name. Keep it within the tooltip so
	# the army's origin is visible without adding Total or Target rows.
	v._draw_castle_banner(pos + Vector2(22.0, 34.0), 12.0, 18.0, source_color, source_device)
	v.draw_string(v.font_body, pos + Vector2(36.0, 49.0), source_name, HORIZONTAL_ALIGNMENT_LEFT, bw - 48.0, 15, Color("fffaf0"))
	var y := 76.0
	for r in rows:
		v.draw_string(v.font_body, pos + Vector2(18, y), r[0], HORIZONTAL_ALIGNMENT_LEFT, 150, 16, Color("fffaf0"))
		v.draw_string(v.font_body, pos + Vector2(bw - 68, y), r[1], HORIZONTAL_ALIGNMENT_RIGHT, 52, 16, Color("f0c85f"))
		y += 22.0

static func _draw_wall(v) -> void:
	if v.hover_wall == "" or v.hover_turret != "" or v.match_ref == null:
		return
	var rows: Array
	if v.recon_rival_index >= 0:
		var rv: UpMatch.Rival = v.match_ref.rivals[v.recon_rival_index]
		var melee_hp: int = int(rv.wall_hp[v.hover_wall])
		var ranged_hp: int = int(rv.wall_ranged_hp[v.hover_wall])
		rows = [
			["Defending Infantry:", str(v.match_ref._army_units(melee_hp, int(UpDefsRef.DEFENDERS["infantry"]["hp"])))],
			["Defending Archers:", str(v.match_ref._army_units(ranged_hp, int(UpDefsRef.DEFENDERS["archer"]["hp"])))],
			["Wall HP:", str(melee_hp / UpConfigRef.S)],
		]
	else:
		var w = v.match_ref.walls[v.hover_wall]
		rows = [
			["Defending Infantry:", str(v.match_ref.garrison_count(w.melee))],
			["Defending Archers:", str(v.match_ref.garrison_count(w.ranged))],
			["Wall HP:", str(w.hp() / UpConfigRef.S)],
		]
	var bw := 232.0
	var bh := 36.0 + rows.size() * 22.0
	var inner: int = v.GRID * v.px_cell
	var off: int = v.wall_thick + v.gap
	var local_pos := Vector2.ZERO
	match v.hover_wall:
		"N": local_pos = Vector2(off + inner * 0.5, off + 8)
		"S": local_pos = Vector2(off + inner * 0.5, off + inner - 8)
		"W": local_pos = Vector2(off + 8, off + inner * 0.5)
		_: local_pos = Vector2(off + inner - 8, off + inner * 0.5)
	var pos: Vector2 = v._board_to_screen(local_pos)
	match v.hover_wall:
		"N": pos += Vector2(-bw * 0.5, 0)
		"S": pos += Vector2(-bw * 0.5, -bh)
		"W": pos += Vector2(0, -bh * 0.5)
		_: pos += Vector2(-bw, -bh * 0.5)
	_draw_stat(v, "%s Wall" % UpMatch.dir_name(v.hover_wall), rows, pos, bw, bh)

static func _draw_turret(v) -> void:
	if v.hover_turret == "" or v.match_ref == null:
		return
	var rows: Array = []
	if v.recon_rival_index >= 0:
		var rv: UpMatch.Rival = v.match_ref.rivals[v.recon_rival_index]
		var adj: Array = UpMatch.TURRET_WALLS[v.hover_turret]
		var destroyed: bool = bool(rv.wall_collapsed[adj[0]]) and int(rv.wall_hp[adj[0]]) <= 0 \
			and bool(rv.wall_collapsed[adj[1]]) and int(rv.wall_hp[adj[1]]) <= 0
		rows.append(["Defending Infantry:", str(v.match_ref._army_units(int(rv.turret_melee_hp[v.hover_turret]), int(UpDefsRef.DEFENDERS["infantry"]["hp"])))])
		rows.append(["Defending Archers:", str(v.match_ref._army_units(int(rv.turret_ranged_hp[v.hover_turret]), int(UpDefsRef.DEFENDERS["archer"]["hp"])))])
		if not v._viewing_local_fiefdom():
			rows.append(["Connected Walls:", "%s / %s" % [adj[0], adj[1]]])
		if destroyed:
			rows.append(["Status:", "Destroyed"])
	else:
		var tr = v.match_ref.turrets[v.hover_turret]
		# Only soldiers physically stationed in the tower count here. Infantry that
		# have sortied into the courtyard are no longer defending the tower.
		rows.append(["Defending Infantry:", str(v.match_ref.garrison_count(tr.melee))])
		rows.append(["Defending Archers:", str(v.match_ref.garrison_count(tr.ranged))])
		if tr.destroyed:
			rows.append(["Status:", "Destroyed"])
	var bw := 232.0
	var bh := 36.0 + rows.size() * 22.0
	var inner: int = v.GRID * v.px_cell
	var off: int = v.wall_thick + v.gap
	var anchor_pos := Vector2.ZERO
	match v.hover_turret:
		"NW": anchor_pos = Vector2(off + 8, off + 8)
		"NE": anchor_pos = Vector2(off + inner - 8, off + 8)
		"SE": anchor_pos = Vector2(off + inner - 8, off + inner - 8)
		_: anchor_pos = Vector2(off + 8, off + inner - 8)
	var pos: Vector2 = v._board_to_screen(anchor_pos)
	match v.hover_turret:
		"NE": pos.x -= bw
		"SE": pos -= Vector2(bw, bh)
		"SW": pos.y -= bh
	_draw_stat(v, "%s Turret" % v.hover_turret, rows, pos, bw, bh)


static func _draw_stat(v, title: String, rows: Array, pos: Vector2, bw: float, bh: float) -> void:
	pos.x = clampf(pos.x, 8.0, maxf(8.0, v.size.x - bw - 8.0))
	pos.y = clampf(pos.y, 8.0, maxf(8.0, v.size.y - bh - 8.0))
	v.draw_rect(Rect2(pos, Vector2(bw, bh)), Color(0.086, 0.125, 0.180, 0.66))
	v.draw_rect(Rect2(pos, Vector2(bw, bh)), v.C_GOLD, false, 1.5)
	v.draw_string(v.font_disp, pos + Vector2(12, 25), title, HORIZONTAL_ALIGNMENT_LEFT, -1, 18, v.C_GOLD)
	var y := 52.0
	for r in rows:
		v.draw_string(v.font_body, pos + Vector2(18, y), r[0], HORIZONTAL_ALIGNMENT_LEFT, 150, 16, Color("fffaf0"))
		v.draw_string(v.font_body, pos + Vector2(bw - 68, y), r[1], HORIZONTAL_ALIGNMENT_RIGHT, 52, 16, Color("f0c85f"))
		y += 22.0
