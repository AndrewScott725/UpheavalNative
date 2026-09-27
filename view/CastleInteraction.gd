class_name CastleInteraction
extends RefCounted

static func bitmap_contains(v, mask: BitMap, p: Vector2) -> bool:
	if mask == null:
		return false
	var dest: Rect2 = v._castle_art_dest_rect()
	if not dest.has_point(p) or dest.size.x <= 0.0 or dest.size.y <= 0.0:
		return false
	var size := mask.get_size()
	var ix: int = clampi(int(floor((p.x - dest.position.x) * float(size.x) / dest.size.x)), 0, size.x - 1)
	var iy: int = clampi(int(floor((p.y - dest.position.y) * float(size.y) / dest.size.y)), 0, size.y - 1)
	return mask.get_bit(ix, iy)

static func piece_at_local(v, p: Vector2) -> Dictionary:
	# Reverse of the visual order; the visibly top piece receives hover/click.
	for tid in ["SE", "SW"]:
		if full_turret_contains(v, tid, p):
			return {"kind": "tower", "id": tid}
	for d in ["S", "N"]:
		if full_wall_contains(v, d, p):
			return {"kind": "wall", "id": d}
	for d in ["W", "E"]:
		if full_wall_contains(v, d, p):
			return {"kind": "wall", "id": d}
	for tid in ["NE", "NW"]:
		if full_turret_contains(v, tid, p):
			return {"kind": "tower", "id": tid}
	return {}

static func full_wall_contains(v, d: String, p: Vector2) -> bool:
	var mask = v.MODULAR_WALL_HIT_MASKS.get(d, null)
	if mask is BitMap and bitmap_contains(v, mask as BitMap, p):
		return true
	return Geometry2D.is_point_in_polygon(p, v._castle_wall_walk_quad(d))

static func full_turret_contains(v, tid: String, p: Vector2) -> bool:
	var mask = v.MODULAR_TOWER_HIT_MASKS.get(tid, null)
	if mask is BitMap and bitmap_contains(v, mask as BitMap, p):
		return true
	return v._castle_turret_contains(tid, p)
