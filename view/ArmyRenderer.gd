extends RefCounted
const UpConfigRef = preload("res://sim/UpConfig.gd")
const GRID := UpConfigRef.GRID
const CELL := UpConfigRef.CELL

## Army/crowd battlefield rendering extracted from BoardView.

const C_SORTIE := Color("3a63b8")

static var KNIGHT_SHEET: Texture2D = null
static var ARCHER_SHEET: Texture2D = null
static var KNIGHT_CLOTH_MASK: Texture2D = null
static var ARCHER_CLOTH_MASK: Texture2D = null
static var KNIGHT_SHEET_FLIPPED: Texture2D = null
static var ARCHER_SHEET_FLIPPED: Texture2D = null
static var KNIGHT_CLOTH_MASK_FLIPPED: Texture2D = null
static var ARCHER_CLOTH_MASK_FLIPPED: Texture2D = null
static var KNIGHT_REAR_SHEET: Texture2D = null
static var ARCHER_REAR_SHEET: Texture2D = null
static var KNIGHT_REAR_SHEET_FLIPPED: Texture2D = null
static var ARCHER_REAR_SHEET_FLIPPED: Texture2D = null
static var KNIGHT_REAR_MASK: Texture2D = null
static var ARCHER_REAR_MASK: Texture2D = null
static var KNIGHT_REAR_MASK_FLIPPED: Texture2D = null
static var ARCHER_REAR_MASK_FLIPPED: Texture2D = null
static var KNIGHT_ARMOR_MASK: Texture2D = null
static var ARCHER_ARMOR_MASK: Texture2D = null
static var KNIGHT_ARMOR_MASK_FLIPPED: Texture2D = null
static var ARCHER_ARMOR_MASK_FLIPPED: Texture2D = null
static var KNIGHT_REAR_ARMOR_MASK: Texture2D = null
static var ARCHER_REAR_ARMOR_MASK: Texture2D = null
static var KNIGHT_REAR_ARMOR_MASK_FLIPPED: Texture2D = null
static var ARCHER_REAR_ARMOR_MASK_FLIPPED: Texture2D = null
static var _TEAM_TINT_CACHE: Dictionary = {}

static func _load_png_texture(path: String) -> Texture2D:
	# Runtime resource loading works both from the editor filesystem and from a
	# packed/exported project. Raw filesystem loading is only a fallback.
	var resource = load(path)
	if resource is Texture2D:
		return resource as Texture2D
	var image := Image.new()
	var error: Error = image.load(ProjectSettings.globalize_path(path))
	if error != OK:
		push_error("ArmyRenderer could not load image: %s (error %s)" % [path, error])
		return null
	return ImageTexture.create_from_image(image)

static func _ensure_textures() -> void:
	if KNIGHT_SHEET != null:
		return
	KNIGHT_SHEET = _load_png_texture("res://view/assets/knight_sheet_stable16.png")
	ARCHER_SHEET = _load_png_texture("res://view/assets/archer_sheet_stable16.png")
	KNIGHT_CLOTH_MASK = _load_png_texture("res://view/assets/knight_mask_stable16.png")
	ARCHER_CLOTH_MASK = _load_png_texture("res://view/assets/archer_mask_stable16.png")
	KNIGHT_SHEET_FLIPPED = _load_png_texture("res://view/assets/knight_sheet_stable16_flipped.png")
	ARCHER_SHEET_FLIPPED = _load_png_texture("res://view/assets/archer_sheet_stable16_flipped.png")
	KNIGHT_CLOTH_MASK_FLIPPED = _load_png_texture("res://view/assets/knight_mask_stable16_flipped.png")
	ARCHER_CLOTH_MASK_FLIPPED = _load_png_texture("res://view/assets/archer_mask_stable16_flipped.png")
	KNIGHT_REAR_SHEET = _load_png_texture("res://view/assets/knight_sheet_rear16_truev2.png")
	ARCHER_REAR_SHEET = _load_png_texture("res://view/assets/archer_sheet_rear16_truev2.png")
	KNIGHT_REAR_SHEET_FLIPPED = _load_png_texture("res://view/assets/knight_sheet_rear16_truev2_flipped.png")
	ARCHER_REAR_SHEET_FLIPPED = _load_png_texture("res://view/assets/archer_sheet_rear16_truev2_flipped.png")
	KNIGHT_REAR_MASK = _load_png_texture("res://view/assets/knight_mask_rear16_truev2.png")
	ARCHER_REAR_MASK = _load_png_texture("res://view/assets/archer_mask_rear16_truev2.png")
	KNIGHT_REAR_MASK_FLIPPED = _load_png_texture("res://view/assets/knight_mask_rear16_truev2_flipped.png")
	ARCHER_REAR_MASK_FLIPPED = _load_png_texture("res://view/assets/archer_mask_rear16_truev2_flipped.png")
	KNIGHT_ARMOR_MASK = _load_png_texture("res://view/assets/knight_armor_mask_stable16.png")
	ARCHER_ARMOR_MASK = _load_png_texture("res://view/assets/archer_armor_mask_stable16.png")
	KNIGHT_ARMOR_MASK_FLIPPED = _load_png_texture("res://view/assets/knight_armor_mask_stable16_flipped.png")
	ARCHER_ARMOR_MASK_FLIPPED = _load_png_texture("res://view/assets/archer_armor_mask_stable16_flipped.png")
	KNIGHT_REAR_ARMOR_MASK = _load_png_texture("res://view/assets/knight_armor_mask_rear16_truev2.png")
	ARCHER_REAR_ARMOR_MASK = _load_png_texture("res://view/assets/archer_armor_mask_rear16_truev2.png")
	KNIGHT_REAR_ARMOR_MASK_FLIPPED = _load_png_texture("res://view/assets/knight_armor_mask_rear16_truev2_flipped.png")
	ARCHER_REAR_ARMOR_MASK_FLIPPED = _load_png_texture("res://view/assets/archer_armor_mask_rear16_truev2_flipped.png")
const SHEET_COLS := 16
const SHEET_ROWS := 3
const FRAME_W := 181.0
const FRAME_H := 362.0
const ROW_WALK := 0
const ROW_ATTACK := 1
const ROW_HURT := 2
const FRAMES_PER_ROW := 16
const WALK_FPS := 15.0
const ATTACK_FPS := 16.0
const HURT_FPS := 16.0
const DETAIL_SPRITE_SCALE := 0.180
const GARRISON_SPRITE_SCALE := 0.144
const FACTION_RING_ALPHA := 0.68
const DAMAGE_ANIM_TICKS := 5.0

# Minimum visual personal space for mobile soldiers.  The old layout used only
# ~3 px between neighboring figures, so detailed sprites piled on top of one
# another.  These values keep the army readable while still allowing a large
# formation to fit around the castle.  They affect presentation only; logical
# simulation positions and combat ranges are unchanged.
const MOBILE_MEMBER_SPACING_X := 27.0
const MOBILE_MEMBER_SPACING_Y := 31.0
const OUTSIDE_FRONTAGE_SPACING := 25.0
const OUTSIDE_DEPTH_SPACING := 27.0
const MAX_INTERIOR_VISUALS_PER_PACKET := 100
const MAX_SORTIE_VISUALS_PER_PACKET := 80


static func _square_spiral_cell(index: int) -> Vector2i:
	# Stable centered square spiral: every member gets its own lattice cell, so
	# members in the same packet never receive nearly identical screen positions.
	if index <= 0:
		return Vector2i.ZERO
	var k: int = int(ceil((sqrt(float(index)) - 1.0) * 0.5))
	k = maxi(1, k)
	var t: int = 2 * k + 1
	var m: int = t * t
	t -= 1
	if index >= m - t:
		return Vector2i(k - (m - index), -k)
	m -= t
	if index >= m - t:
		return Vector2i(-k, -k + (m - index))
	m -= t
	if index >= m - t:
		return Vector2i(-k + (m - index), k)
	return Vector2i(k, k - (m - index - t))


static func member_offset(inv_id: int, member_index: int, outside: bool, wall: String) -> Vector2:
	# Interior packets use a staggered hex lattice rather than a square spiral.
	# It preserves minimum personal space but removes the conspicuous rectangular
	# carpets/rays that made large packets look like generated geometry.
	var row: int = int(floor(sqrt(float(maxi(0, member_index)))))
	var row_start: int = row * row
	var within: int = member_index - row_start
	var width: int = maxi(1, row * 2 + 1)
	var xslot: int = within % width
	var yslot: int = int(within / width)
	var centered_x: float = float(xslot) - float(width - 1) * 0.5
	var centered_y: float = float(row) * 0.62 + float(yslot)
	if member_index % 2 == 1:
		centered_x += 0.5
	var seed: int = absi(inv_id * 131 + member_index * 977)
	var jitter := Vector2(float(seed % 7) - 3.0, float((seed / 7) % 7) - 3.0) * 0.42
	var off := Vector2(centered_x * MOBILE_MEMBER_SPACING_X, centered_y * MOBILE_MEMBER_SPACING_Y) + jitter
	# Center the cloud around its packet instead of allowing every packet to trail
	# in the same direction. Outside armies use the dedicated frontage layout below.
	if not outside:
		off.y -= float(row) * MOBILE_MEMBER_SPACING_Y * 0.31
	return off


static func _outside_army_member_position(v: BoardView, inv: UpMatch.Invader, army_index: int, army_members: int) -> Vector2:
	# Do NOT center a packet-sized square on each authoritative group.  That was
	# the source of the giant parallel columns in the old renderer.  Every visible
	# member of an army instead receives a slot in one broad frontage shared by all
	# packets attacking the same wall.  The authoritative packet supplies only the
	# army's forward progress; presentation distributes bodies tangentially and in
	# depth like a real crowd queue.
	var base: Vector2 = v.interpolated_invader_visual_px(inv)
	var usable_px: float = maxf(OUTSIDE_FRONTAGE_SPACING * 6.0, float((GRID - 2) * v.px_cell))
	var slots: int = maxi(6, int(floor(usable_px / OUTSIDE_FRONTAGE_SPACING)))
	# Relatively-prime permutation avoids visible diagonal banding as samples are
	# skipped at high army counts.
	var perm: int = 7 if slots % 7 != 0 else 5
	var slot: int = posmod(army_index * perm + absi(inv.army_id * 11), slots)
	var row: int = int(army_index / slots)
	var tangent: float = (float(slot) - float(slots - 1) * 0.5) * OUTSIDE_FRONTAGE_SPACING
	var depth: float = float(row) * OUTSIDE_DEPTH_SPACING
	var seed: int = absi(inv.army_id * 92821 + army_index * 68917 + inv.id * 31)
	var jitter_t: float = (float(seed % 101) / 100.0 - 0.5) * 7.0
	var jitter_d: float = (float((seed / 101) % 101) / 100.0 - 0.5) * 5.0
	# Tiny per-agent stride drift breaks the "one rigid sheet" look without a
	# heavyweight per-soldier simulation or trigonometry. It advances only when
	# the already-throttled crowd buffers rebuild.
	var stride_phase: int = posmod(v._detail_anim_walk_base + seed, 16)
	var stride_tri: float = float(8 - absi(8 - stride_phase)) / 8.0
	var stride_sign: float = -1.0 if ((seed / 1031) % 2) == 0 else 1.0
	jitter_t += stride_sign * stride_tri * 2.2
	jitter_d += (stride_tri - 0.5) * 2.0
	# Keep the army mass centered around its packet progress while allowing the
	# rear ranks to queue outward. Clamp the centered term so gigantic armies do
	# not shift their entire visible mass miles away from the contact line.
	var visible_rows: int = int(ceil(float(maxi(1, army_members)) / float(slots)))
	var center_rows: float = minf(float(visible_rows - 1) * 0.5, 14.0)
	var signed_depth: float = (float(row) - center_rows) * OUTSIDE_DEPTH_SPACING + jitter_d
	match inv.wall:
		"N": return Vector2(v.mmf_to_px(float(GRID * CELL) * 0.5) + tangent + jitter_t, base.y - signed_depth)
		"S": return Vector2(v.mmf_to_px(float(GRID * CELL) * 0.5) + tangent + jitter_t, base.y + signed_depth)
		"W": return Vector2(base.x - signed_depth, v.mmf_to_py(float(GRID * CELL) * 0.5) + tangent + jitter_t)
		_:   return Vector2(base.x + signed_depth, v.mmf_to_py(float(GRID * CELL) * 0.5) + tangent + jitter_t)


static func _frame_region(row: int, frame: int) -> Rect2:
	return Rect2(float(frame) * FRAME_W, float(row) * FRAME_H, FRAME_W, FRAME_H)


static func _cycle_frame(seed: int, fps: float) -> int:
	var now: float = float(Time.get_ticks_usec()) / 1000000.0
	var phase: float = float(abs(seed) % FRAMES_PER_ROW)
	return posmod(int(floor(now * fps + phase)), FRAMES_PER_ROW)


static func _cycle_phase(seed: int, fps: float) -> float:
	var now: float = float(Time.get_ticks_usec()) / 1000000.0
	var phase: float = float(abs(seed) % FRAMES_PER_ROW)
	return fmod(now * fps + phase, float(FRAMES_PER_ROW))


static func _hurt_frame(age_ticks: float) -> int:
	var progress: float = clampf(age_ticks / DAMAGE_ANIM_TICKS, 0.0, 1.0)
	return mini(FRAMES_PER_ROW - 1, int(floor(progress * float(FRAMES_PER_ROW))))


static func _is_recently_damaged(v: BoardView, damage_mark_tick: int) -> bool:
	if v.match_ref == null or damage_mark_tick < 0:
		return false
	var age: float = float(v.match_ref.tick - damage_mark_tick) + v.interpolation_alpha()
	return age >= 0.0 and age <= DAMAGE_ANIM_TICKS


static func _damage_age(v: BoardView, damage_mark_tick: int) -> float:
	if v.match_ref == null or damage_mark_tick < 0:
		return 9999.0
	return float(v.match_ref.tick - damage_mark_tick) + v.interpolation_alpha()


static func _draw_faction_marker(v: BoardView, p: Vector2, c: Color, scale_mult: float) -> void:
	var ring: Color = Color(c.r, c.g, c.b, FACTION_RING_ALPHA)
	var shadow: Color = Color(0, 0, 0, 0.20)
	v.draw_circle(Vector2(p.x, p.y + 2.0 * scale_mult), 3.5 * scale_mult, shadow)
	v.draw_circle(Vector2(p.x, p.y + 0.4 * scale_mult), 2.6 * scale_mult, ring)


static func _draw_sprite(v: BoardView, texture: Texture2D, region: Rect2, p: Vector2, scale: float,
		modulate: Color = Color(1, 1, 1, 1), width_mult: float = 1.0) -> void:
	if texture == null:
		return
	var draw_w: float = FRAME_W * scale * width_mult
	var draw_h: float = FRAME_H * scale
	var foot_y: float = 4.0 * scale
	var dest := Rect2(p.x - draw_w * 0.5, p.y - draw_h + foot_y, draw_w, draw_h)
	v.draw_texture_rect_region(texture, dest, region, modulate)


static func _direction_flip(facing_dir: String, fallback_flip: bool) -> bool:
	match facing_dir:
		"W": return true
		"E": return false
		# North uses a dedicated detailed rear-view sheet. Mirroring simply provides
		# the opposite stride phase; it no longer fakes a rear view with an overlay.
		"N": return true
		"S": return false
		_: return fallback_flip


static func _draw_unit_sprite(v: BoardView, texture: Texture2D, flipped_texture: Texture2D, cloth_mask: Texture2D, flipped_mask: Texture2D,
		rear_texture: Texture2D, rear_flipped_texture: Texture2D, rear_mask: Texture2D, rear_flipped_mask: Texture2D,
		armor_mask: Texture2D, armor_mask_flipped: Texture2D, rear_armor_mask: Texture2D, rear_armor_mask_flipped: Texture2D,
		p: Vector2, team_color: Color, seed: int, state: String, flip: bool, scale: float,
		hurt_age_ticks: float = -1.0, facing_dir: String = "") -> void:
	if not v.battle_visual_visible(p):
		return
	var row: int = ROW_WALK
	var frame: int = 0
	match state:
		"hurt":
			row = ROW_HURT
			frame = _hurt_frame(maxf(0.0, hurt_age_ticks))
		"attack":
			row = ROW_ATTACK
			frame = _cycle_frame(seed, ATTACK_FPS)
		"idle":
			row = ROW_WALK
			frame = 0
		_:
			row = ROW_WALK
			frame = _cycle_frame(seed, WALK_FPS)
	var actual_flip: bool = _direction_flip(facing_dir, flip)
	var body_tex: Texture2D
	var mask_tex: Texture2D
	var armor_tex: Texture2D
	if facing_dir == "N":
		body_tex = rear_flipped_texture if actual_flip else rear_texture
		mask_tex = rear_flipped_mask if actual_flip else rear_mask
		armor_tex = rear_armor_mask_flipped if actual_flip else rear_armor_mask
	else:
		body_tex = flipped_texture if actual_flip else texture
		mask_tex = flipped_mask if actual_flip else cloth_mask
		armor_tex = armor_mask_flipped if actual_flip else armor_mask
	var width_mult: float = 0.94 if facing_dir == "N" or facing_dir == "S" else 1.0
	var tint_base: Color = team_color.lightened(0.10)
	tint_base.a = 0.90
	var armor_tint: Color = team_color.lightened(0.18)
	armor_tint = Color(
		lerpf(0.78, armor_tint.r, 0.72),
		lerpf(0.78, armor_tint.g, 0.72),
		lerpf(0.80, armor_tint.b, 0.72),
		0.42
	)
	var region: Rect2 = _frame_region(row, frame)
	_draw_sprite(v, body_tex, region, p, scale, Color(1, 1, 1, 1), width_mult)
	_draw_sprite(v, armor_tex, region, p, scale, armor_tint, width_mult)
	_draw_sprite(v, mask_tex, region, p, scale, tint_base, width_mult)


static func draw_detailed_archer(v: BoardView, p: Vector2, c: Color, face: float,
		seed: int = 0, state: String = "walk", damage_age_ticks: float = -1.0, scale_mult: float = 1.0, facing_dir: String = "") -> void:
	_ensure_textures()
	var anim_state := state
	var anim_seed := seed
	if damage_age_ticks >= 0.0:
		anim_state = "hurt"
	_draw_unit_sprite(v, ARCHER_SHEET, ARCHER_SHEET_FLIPPED, ARCHER_CLOTH_MASK, ARCHER_CLOTH_MASK_FLIPPED,
		ARCHER_REAR_SHEET, ARCHER_REAR_SHEET_FLIPPED, ARCHER_REAR_MASK, ARCHER_REAR_MASK_FLIPPED,
		ARCHER_ARMOR_MASK, ARCHER_ARMOR_MASK_FLIPPED, ARCHER_REAR_ARMOR_MASK, ARCHER_REAR_ARMOR_MASK_FLIPPED,
		p, c, anim_seed, anim_state, face < 0.0,
		GARRISON_SPRITE_SCALE * scale_mult if scale_mult < 1.0 else DETAIL_SPRITE_SCALE * scale_mult,
		damage_age_ticks, facing_dir)


static func draw_detailed_soldier(v: BoardView, p: Vector2, c: Color,
		seed: int = 0, state: String = "walk", damage_age_ticks: float = -1.0,
		flip: bool = false, scale_mult: float = 1.0, facing_dir: String = "") -> void:
	_ensure_textures()
	var anim_state := state
	var anim_seed := seed
	if damage_age_ticks >= 0.0:
		anim_state = "hurt"
	_draw_unit_sprite(v, KNIGHT_SHEET, KNIGHT_SHEET_FLIPPED, KNIGHT_CLOTH_MASK, KNIGHT_CLOTH_MASK_FLIPPED,
		KNIGHT_REAR_SHEET, KNIGHT_REAR_SHEET_FLIPPED, KNIGHT_REAR_MASK, KNIGHT_REAR_MASK_FLIPPED,
		KNIGHT_ARMOR_MASK, KNIGHT_ARMOR_MASK_FLIPPED, KNIGHT_REAR_ARMOR_MASK, KNIGHT_REAR_ARMOR_MASK_FLIPPED,
		p, c, anim_seed, anim_state, flip,
		GARRISON_SPRITE_SCALE * scale_mult if scale_mult < 1.0 else DETAIL_SPRITE_SCALE * scale_mult,
		damage_age_ticks, facing_dir)


static func _facing_from_heading(hx: int, hy: int, fallback: String = "S") -> String:
	if absi(hx) >= absi(hy) and hx != 0:
		return "E" if hx > 0 else "W"
	if hy != 0:
		return "S" if hy > 0 else "N"
	return fallback


static func _inward_facing_for_wall(wall: String) -> String:
	match wall:
		"N": return "S"
		"S": return "N"
		"W": return "E"
		_: return "W"


static func _invader_state(v: BoardView, inv: UpMatch.Invader) -> String:
	if _is_recently_damaged(v, inv.damage_mark_tick):
		return "hurt"
	var moving: bool = inv.prev_x != inv.x or inv.prev_y != inv.y
	var combat_engaged: bool = (inv.at_wall and not inv.inside) or inv.tgt_kind != "" or (inv.active_tick > 0 and v.match_ref.tick >= inv.active_tick)
	if combat_engaged and not moving:
		return "attack"
	return "walk"


static func _sortie_state(v: BoardView, sortie: UpMatch.Sortie) -> String:
	if _is_recently_damaged(v, sortie.damage_mark_tick):
		return "hurt"
	var moving: bool = sortie.prev_x != sortie.x or sortie.prev_y != sortie.y
	if sortie.tgt_id >= 0 and not moving:
		return "attack"
	return "walk"




static func _representative_count(members: int) -> int:
	# Keep enough full-detail figures to make every live interior packet readable
	# without expanding thousands of members into thousands of animated sprites.
	return clampi(int(ceil(sqrt(float(maxi(1, members))))), 1, 8)


static func _draw_large_battle_interior_representatives(v: BoardView) -> void:
	var m = v.match_ref
	if m == null:
		return

	# Invaders that have crossed the breach remain full soldier/archer imagery.
	for inv: UpMatch.Invader in m.invaders:
		if inv.hp <= 0 or not inv.inside:
			continue
		var members: int = m.invader_members(inv)
		var visual_count: int = mini(MAX_INTERIOR_VISUALS_PER_PACKET, _representative_count(members))
		var state := _invader_state(v, inv)
		var damage_age := _damage_age(v, inv.damage_mark_tick) if state == "hurt" else -1.0
		var flip := _flip_from_heading(inv.hx, inv.hy)
		var facing_dir: String = _facing_from_heading(inv.hx, inv.hy, _inward_facing_for_wall(inv.wall))
		var base: Vector2 = v.interpolated_invader_visual_px(inv)
		for n in visual_count:
			var source_index: int = int(floor(float(n) * float(maxi(1, members)) / float(visual_count)))
			var p: Vector2 = base + member_offset(inv.id, source_index, false, inv.wall)
			var c: Color = inv.force_color.lightened(0.18) if inv.def["cat"] == "ranged" else inv.force_color
			var seed := inv.id * 7919 + source_index * 101
			if inv.def["cat"] == "ranged":
				draw_detailed_archer(v, p, c, -1.0 if flip else 1.0, seed, state, damage_age, 1.0, facing_dir)
			else:
				draw_detailed_soldier(v, p, c, seed, state, damage_age, flip, 1.0, facing_dir)

	# Turret melee defenders are converted to Sortie packets as soon as an enemy
	# enters the courtyard.  Keep those packets visible as detailed defenders so
	# they visibly leave the turret and fight rather than disappearing from it.
	for sortie: UpMatch.Sortie in m.sortied:
		if sortie.dead or sortie.hp <= 0:
			continue
		var members: int = m.sortie_members(sortie)
		var visual_count: int = mini(MAX_SORTIE_VISUALS_PER_PACKET, _representative_count(members))
		var base: Vector2 = v.interpolated_mm_to_px(sortie.prev_x, sortie.prev_y, sortie.x, sortie.y)
		var state := _sortie_state(v, sortie)
		var damage_age := _damage_age(v, sortie.damage_mark_tick) if state == "hurt" else -1.0
		var flip := _flip_from_heading(sortie.hx, sortie.hy)
		var facing_dir: String = _facing_from_heading(sortie.hx, sortie.hy, "S")
		for n in visual_count:
			var source_index: int = int(floor(float(n) * float(maxi(1, members)) / float(visual_count)))
			var p: Vector2 = base + member_offset(sortie.id, source_index, false, "")
			draw_detailed_soldier(v, p, C_SORTIE, sortie.id * 3571 + source_index * 131, state, damage_age, flip, 1.0, facing_dir)


static func _batch_frame(v: BoardView, seed: int, state: String, damage_age_ticks: float) -> Dictionary:
	var row: int = ROW_WALK
	var frame: int = 0
	match state:
		"hurt":
			row = ROW_HURT
			frame = _hurt_frame(maxf(0.0, damage_age_ticks))
		"attack":
			row = ROW_ATTACK
			var slots: int = [2, 4, 6, 8, 12][v.adaptive_quality_level]
			var phase_slot: int = absi(seed) % slots
			var base: int = v._detail_anim_attack_base
			frame = posmod(base + int(floor(float(phase_slot) * float(FRAMES_PER_ROW) / float(slots))), FRAMES_PER_ROW)
		"idle":
			row = ROW_WALK
			frame = 0
		_:
			row = ROW_WALK
			var slots2: int = [2, 4, 6, 8, 12][v.adaptive_quality_level]
			var phase_slot2: int = absi(seed) % slots2
			var base2: int = v._detail_anim_walk_base
			frame = posmod(base2 + int(floor(float(phase_slot2) * float(FRAMES_PER_ROW) / float(slots2))), FRAMES_PER_ROW)
	return {"row": row, "frame": frame}


static func _batch_mesh(row: int, frame: int, scale: float, width_mult: float) -> ArrayMesh:
	var draw_w: float = FRAME_W * scale * width_mult
	var draw_h: float = FRAME_H * scale
	var foot_y: float = 4.0 * scale
	var x0 := -draw_w * 0.5
	var x1 := draw_w * 0.5
	var y0 := -draw_h + foot_y
	var y1 := foot_y
	var u0 := float(frame) / float(SHEET_COLS)
	var u1 := float(frame + 1) / float(SHEET_COLS)
	var v0 := float(row) / float(SHEET_ROWS)
	var v1 := float(row + 1) / float(SHEET_ROWS)
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([
		Vector3(x0, y0, 0.0), Vector3(x1, y0, 0.0), Vector3(x1, y1, 0.0), Vector3(x0, y1, 0.0)
	])
	arrays[Mesh.ARRAY_TEX_UV] = PackedVector2Array([
		Vector2(u0, v0), Vector2(u1, v0), Vector2(u1, v1), Vector2(u0, v1)
	])
	arrays[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 1, 2, 0, 2, 3])
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


static func _new_mm(mesh: Mesh, capacity: int = 64, with_colors: bool = true) -> MultiMesh:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_2D
	mm.use_colors = with_colors
	mm.mesh = mesh
	mm.instance_count = capacity
	mm.visible_instance_count = 0
	return mm


static func _ensure_batch_capacity(batch: Dictionary, needed: int) -> void:
	var cap: int = int(batch["capacity"])
	if needed <= cap:
		return
	var new_cap := maxi(64, cap)
	while new_cap < needed:
		new_cap *= 2
	batch["capacity"] = new_cap
	var mm: MultiMesh = batch["body_mm"]
	mm.instance_count = new_cap

static func _begin_detail_batches(v: BoardView, total_mobile: int, context_key: int) -> bool:
	var now_usec := Time.get_ticks_usec()
	var refresh_usec: int = v.detailed_batch_refresh_usec(total_mobile)
	var must_refresh: bool = (
		v._detail_sprite_context != context_key
		or v._detail_sprite_last_usec <= 0
		or now_usec - v._detail_sprite_last_usec >= refresh_usec
	)
	v._detail_sprite_rebuilding = must_refresh
	if not must_refresh:
		return false
	for key in v._detail_sprite_active_keys:
		if v._detail_sprite_batches.has(key):
			var old_batch: Dictionary = v._detail_sprite_batches[key]
			old_batch["count"] = 0
			var old_body: MultiMesh = old_batch["body_mm"]
			old_body.visible_instance_count = 0
	v._detail_sprite_active_keys.clear()
	v._detail_sprite_last_usec = now_usec
	v._detail_sprite_context = context_key
	# One clock read per batch rebuild, not one call per soldier.
	var now_sec: float = float(now_usec) / 1000000.0
	v._detail_anim_walk_base = int(floor(now_sec * WALK_FPS))
	v._detail_anim_attack_base = int(floor(now_sec * ATTACK_FPS))
	return true

static func _queue_detail_unit(v: BoardView, unit_kind: String, p: Vector2, team_color: Color, seed: int,
		state: String, damage_age_ticks: float, flip: bool, facing_dir: String) -> void:
	if not v._detail_sprite_rebuilding or not v.battle_visual_visible(p):
		return
	_ensure_textures()
	var info := _batch_frame(v, seed, state, damage_age_ticks)
	var row: int = int(info["row"])
	var frame: int = int(info["frame"])
	var actual_flip: bool = _direction_flip(facing_dir, flip)
	var rear: bool = facing_dir == "N"
	var body_tex: Texture2D
	if unit_kind == "archer":
		body_tex = (ARCHER_REAR_SHEET_FLIPPED if actual_flip else ARCHER_REAR_SHEET) if rear else (ARCHER_SHEET_FLIPPED if actual_flip else ARCHER_SHEET)
	else:
		body_tex = (KNIGHT_REAR_SHEET_FLIPPED if actual_flip else KNIGHT_REAR_SHEET) if rear else (KNIGHT_SHEET_FLIPPED if actual_flip else KNIGHT_SHEET)
	var width_mult: float = 0.94 if facing_dir == "N" or facing_dir == "S" else 1.0
	var key := "%s|%s|%s|%d|%d" % [unit_kind, "rear" if rear else ("flip" if actual_flip else "front"), facing_dir, row, frame]
	var batch: Dictionary
	if not v._detail_sprite_batches.has(key):
		var mesh := _batch_mesh(row, frame, DETAIL_SPRITE_SCALE, width_mult)
		batch = {
			"body_mm": _new_mm(mesh, 64, true),
			"body_tex": body_tex,
			"count": 0, "capacity": 64
		}
		v._detail_sprite_batches[key] = batch
	else:
		batch = v._detail_sprite_batches[key]
	var idx: int = int(batch["count"])
	_ensure_batch_capacity(batch, idx + 1)
	var body_mm: MultiMesh = batch["body_mm"]
	body_mm.set_instance_transform_2d(idx, Transform2D(0.0, p))
	# One GPU instance per soldier.  A mild whole-body tint preserves faction read
	# while eliminating the old armor+cloth mask instances and ~2/3 of CPU->GPU
	# setter traffic.
	var tint := Color(
		lerpf(1.0, team_color.r, 0.14),
		lerpf(1.0, team_color.g, 0.14),
		lerpf(1.0, team_color.b, 0.14), 1.0)
	body_mm.set_instance_color(idx, tint)
	batch["count"] = idx + 1
	if idx == 0:
		v._detail_sprite_active_keys.append(key)

static func _queue_detail_archer(v: BoardView, p: Vector2, c: Color, seed: int, state: String,
		damage_age_ticks: float, flip: bool, facing_dir: String) -> void:
	_queue_detail_unit(v, "archer", p, c, seed, state, damage_age_ticks, flip, facing_dir)


static func _queue_detail_soldier(v: BoardView, p: Vector2, c: Color, seed: int, state: String,
		damage_age_ticks: float, flip: bool, facing_dir: String) -> void:
	_queue_detail_unit(v, "knight", p, c, seed, state, damage_age_ticks, flip, facing_dir)


static func _finalize_detail_batches(v: BoardView) -> void:
	if v._detail_sprite_rebuilding:
		for key in v._detail_sprite_active_keys:
			var batch: Dictionary = v._detail_sprite_batches[key]
			var count: int = int(batch["count"])
			var body_mm: MultiMesh = batch["body_mm"]
			body_mm.visible_instance_count = count
	for key in v._detail_sprite_active_keys:
		var batch: Dictionary = v._detail_sprite_batches[key]
		if int(batch["count"]) <= 0:
			continue
		var body_mm2: MultiMesh = batch["body_mm"]
		var body_tex2: Texture2D = batch["body_tex"]
		v.draw_multimesh(body_mm2, body_tex2)
	v._detail_sprite_rebuilding = false

static func _draw_home_detailed_batches(v: BoardView, total_mobile: int) -> void:
	var m = v.match_ref
	var context_key: int = hash(["home", v.recon_rival_index])
	var rebuilding := _begin_detail_batches(v, total_mobile, context_key)
	if rebuilding:
		# True lightweight visual agents: persistent per-soldier position/velocity
		# records, spatial-hash local separation, individual wall stopping and no
		# Node2D/physics body per soldier.
		v.crowd_presentation.sync_and_step(v, m.invaders, null, context_key,
			mini(v.visual_soldier_cap(), UpConfigRef.CROWD_MAX_VISIBLE_AGENTS))
		for ai in v.crowd_presentation.active_indices:
			var p: Vector2 = v.crowd_presentation.positions[ai]
			var damage_tick: int = int(v.crowd_presentation.damage_ticks[ai])
			var state: String = "hurt" if _is_recently_damaged(v, damage_tick) else ("attack" if int(v.crowd_presentation.states[ai]) == 1 else "walk")
			var damage_age: float = _damage_age(v, damage_tick) if state == "hurt" else -1.0
			var facing_dir: String = v.crowd_presentation.facing_string(ai)
			var flip: bool = facing_dir == "W" or facing_dir == "N"
			var c: Color = v.crowd_presentation.colors[ai]
			var seed: int = int(v.crowd_presentation.seeds[ai])
			if int(v.crowd_presentation.categories[ai]) == 1:
				_queue_detail_archer(v, p, c, seed, state, damage_age, flip, facing_dir)
			else:
				_queue_detail_soldier(v, p, c, seed, state, damage_age, flip, facing_dir)

		# Mobile defenders remain packet-authoritative but are a much smaller pool;
		# they still share the single-instance GPU batches above.
		var stride: int = maxi(1, int(ceil(float(maxi(1, total_mobile)) / float(v.visual_soldier_cap()))))
		for sortie: UpMatch.Sortie in m.sortied:
			if sortie.dead or sortie.hp <= 0:
				continue
			var members2: int = m.sortie_members(sortie)
			var sortie_stride: int = maxi(stride, int(ceil(float(maxi(1, members2)) / float(MAX_SORTIE_VISUALS_PER_PACKET))))
			var base: Vector2 = v.interpolated_mm_to_px(sortie.prev_x, sortie.prev_y, sortie.x, sortie.y)
			var state2 := _sortie_state(v, sortie)
			var damage_age2 := _damage_age(v, sortie.damage_mark_tick) if state2 == "hurt" else -1.0
			var flip2 := _flip_from_heading(sortie.hx, sortie.hy)
			var facing_dir2: String = _facing_from_heading(sortie.hx, sortie.hy, "S")
			for n2 in range(0, members2, sortie_stride):
				var off2: Vector2 = member_offset(sortie.id, n2, false, "")
				_queue_detail_soldier(v, base + off2, C_SORTIE, sortie.id * 3571 + n2 * 131, state2, damage_age2, flip2, facing_dir2)
	_finalize_detail_batches(v)

static func _flip_from_heading(hx: int, hy: int, fallback_face: float = 1.0) -> bool:
	if hx < 0:
		return true
	if hx > 0:
		return false
	if hy < 0:
		return true
	if hy > 0:
		return false
	return fallback_face < 0.0


static func draw(v: BoardView) -> void:
	var m = v.match_ref
	var total_mobile: int = m.live_invader_count() + m.live_sortie_count()

	# Authoritative mass-army presentation: all runtime quality tiers use the
	# actual knight/archer sprite atlases in GPU MultiMesh batches. Performance
	# fallback changes refresh cadence, phase variety and representative density,
	# never the visual language of the soldiers.
	_draw_home_detailed_batches(v, total_mobile)
