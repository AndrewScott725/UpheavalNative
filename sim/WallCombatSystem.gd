extends RefCounted
const UpConfigRef = preload("res://sim/UpConfig.gd")

## Perimeter geometry and first-contact rules live here so wall combat has one
## authoritative implementation shared by home and rival battle systems.

static func wall_point(d: String) -> Vector2i:
	match d:
		"N": return Vector2i(UpConfigRef.GRID * UpConfigRef.CELL / 2, -UpConfigRef.CELL)
		"S": return Vector2i(UpConfigRef.GRID * UpConfigRef.CELL / 2, UpConfigRef.GRID * UpConfigRef.CELL)
		"W": return Vector2i(-UpConfigRef.CELL, UpConfigRef.GRID * UpConfigRef.CELL / 2)
		_: return Vector2i(UpConfigRef.GRID * UpConfigRef.CELL, UpConfigRef.GRID * UpConfigRef.CELL / 2)

static func wall_attack_point(d: String, lane: int) -> Vector2i:
	var cell := UpConfigRef.CELL
	var span := UpConfigRef.GRID * cell
	lane = clampi(lane, cell, span - cell)
	match d:
		"N": return Vector2i(lane, -cell)
		"S": return Vector2i(lane, span)
		"W": return Vector2i(-cell, lane)
		_: return Vector2i(span, lane)

static func invader_wall_contact_point(d: String, lane: int) -> Vector2i:
	var cell := UpConfigRef.CELL
	var span := UpConfigRef.GRID * cell
	lane = clampi(lane, cell, span - cell)
	match d:
		"N": return Vector2i(lane, -UpConfigRef.REACH)
		"S": return Vector2i(lane, span + UpConfigRef.REACH)
		"W": return Vector2i(-UpConfigRef.REACH, lane)
		_: return Vector2i(span + UpConfigRef.REACH, lane)

static func invader_melee_wall_contact_point(d: String, lane: int) -> Vector2i:
	return invader_wall_contact_point(d, lane)

static func melee_wall_impact_point(d: String, lane: int) -> Vector2i:
	var cell := UpConfigRef.CELL
	var span := UpConfigRef.GRID * cell
	lane = clampi(lane, cell, span - cell)
	var inset := 760
	match d:
		"N": return Vector2i(lane, -inset)
		"S": return Vector2i(lane, span + inset)
		"W": return Vector2i(-inset, lane)
		_: return Vector2i(span + inset, lane)

static func invader_melee_ready_at_wall(m, inv, d: String) -> bool:
	if inv == null or inv.hp <= 0 or inv.inside or inv.wall != d:
		return false
	var w = m.walls[d]
	var blocks: bool = not w.collapsed or w.hp() >= UpConfigRef.HP_PARTIAL
	if inv.def["cat"] != "melee" or not inv.at_wall or not blocks:
		return false
	var contact := invader_melee_wall_contact_point(d, inv.wall_lane)
	if inv.x != contact.x or inv.y != contact.y:
		return false
	return inv.wall_contact_tick >= 0

static func invader_entry_point(d: String, lane: int) -> Vector2i:
	var cell := UpConfigRef.CELL
	var span := UpConfigRef.GRID * cell
	lane = clampi(lane, cell, span - cell)
	match d:
		"N": return Vector2i(lane, cell / 2)
		"S": return Vector2i(lane, span - cell / 2)
		"W": return Vector2i(cell / 2, lane)
		_: return Vector2i(span - cell / 2, lane)

static func invader_outward_dir(d: String) -> Vector2i:
	match d:
		"N": return Vector2i(0, -1)
		"S": return Vector2i(0, 1)
		"W": return Vector2i(-1, 0)
		_: return Vector2i(1, 0)

static func invader_horde_contact_point(inv) -> Vector2i:
	var p := invader_wall_contact_point(inv.wall, inv.wall_lane)
	var outward := invader_outward_dir(inv.wall)
	var depth := absi(inv.id * 431 + inv.army_id * 97) % 601
	return p + outward * depth

static func invader_combat_active(tick: int, inv) -> bool:
	return inv.active_tick <= 0 or tick >= inv.active_tick

static func turret_point(id: String) -> Vector2i:
	var cell := UpConfigRef.CELL
	var span := UpConfigRef.GRID * cell
	var x: int = -cell if id == "NW" or id == "SW" else span
	var y: int = -cell if id == "NW" or id == "NE" else span
	return Vector2i(x, y)
