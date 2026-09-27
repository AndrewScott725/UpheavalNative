class_name BoardView
extends Control
const UpConfigRef = preload("res://sim/UpConfig.gd")

const BuildingRenderer = preload("res://view/BuildingRenderer.gd")
const ArmyRenderer = preload("res://view/ArmyRenderer.gd")
const EffectsRenderer = preload("res://view/EffectsRenderer.gd")
const CastleRenderer = preload("res://view/CastleRenderer.gd")
const CastleInteraction = preload("res://view/CastleInteraction.gd")
const TooltipRenderer = preload("res://view/TooltipRenderer.gd")
const CrowdPresentation = preload("res://view/CrowdPresentation.gd")
const BoardCoordinates = preload("res://view/BoardCoordinates.gd")
var FIEFDOM_CASTLE_ART: Texture2D = null
var FIEFDOM_LANDSCAPE_ART: Texture2D = null
var MODULAR_GRID_ART: Texture2D = null
var MODULAR_WALL_INTACT: Dictionary = {}
var MODULAR_WALL_PARTIAL: Dictionary = {}
var MODULAR_WALL_RUBBLE: Dictionary = {}
var MODULAR_TOWER_INTACT: Dictionary = {}
var MODULAR_TOWER_PARTIAL: Dictionary = {}
var MODULAR_TOWER_RUBBLE: Dictionary = {}
var MODULAR_WALL_HIT_MASKS: Dictionary = {}
var MODULAR_TOWER_HIT_MASKS: Dictionary = {}

# Presentation-only faction art mapping. Each faction can supply its own one-piece
# 6000x5360 landscape and castle while all simulation/grid logic stays unchanged.
const FACTION_VISUALS := {
	"ironcrest": {
		"landscape": "res://view/assets/fiefdom_landscape_reference.webp",
		"castle": "res://view/assets/fiefdom_castle_reference.png"
	}
}
var faction_visual_id: String = "ironcrest"
const FIEFDOM_CASTLE_ART_FIELD_SRC := Rect2(295.0, 415.0, 549.0, 492.0)
const FIEFDOM_CASTLE_ART_VISIBLE_SRC := Rect2(0.0, 53.0, 1122.0, 1282.0)
const FIEFDOM_CASTLE_ART_ROW_SRC = [415.0, 454.0, 493.0, 532.0, 571.0, 611.0, 652.0, 693.0, 735.0, 777.0, 819.0, 862.0, 907.0]
const FIEFDOM_CASTLE_ART_COL_TOP_SRC = [305.0, 349.0, 393.0, 436.0, 479.0, 522.0, 565.0, 607.0, 650.0, 693.0, 736.0, 779.0, 822.0]
const FIEFDOM_CASTLE_ART_COL_BOTTOM_SRC = [295.0, 341.0, 388.0, 433.0, 479.0, 523.0, 569.0, 615.0, 661.0, 707.0, 753.0, 799.0, 844.0]

## Presentation only (§16.1). Reads the simulation, draws it, reports clicks
## upward as intent. Never decides an outcome.

signal building_clicked(id: int)
signal cell_clicked(x: int, y: int)
signal wall_clicked(dir: String)
signal turret_clicked(id: String)

const GRID := UpConfigRef.GRID
const CELL := UpConfigRef.CELL

var px_cell: int = 44
var wall_thick: int = 68
var gap: int = 0

var match_ref: UpMatch = null
var ghost_def: Dictionary = {}
var ghost_rot: int = 0
var hover_cell := Vector2i(-1, -1)
var hover_wall: String = ""
var hover_turret: String = ""
var hover_army_id: int = -1
var hover_army_screen_pos: Vector2 = Vector2.ZERO
var arm_cat: String = ""
## Index into match_ref.rivals of the fiefdom being scouted, or -1 when the
## board is showing the player's own fiefdom (§10). Set by Main.
var recon_rival_index: int = -1
var local_player_id: int = 0
var inset_top: float = 0.0
var inset_bottom: float = 0.0
var inset_left: float = 0.0
var inset_right: float = 0.0

## User camera controls for the central fiefdom view.
var view_zoom: float = 1.0
var view_pan: Vector2 = Vector2.ZERO
var _panning: bool = false
var _pan_last: Vector2 = Vector2.ZERO
const VIEW_ZOOM_MIN := 0.16
const VIEW_ZOOM_MAX := 2.40
const VIEW_ZOOM_STEP := 1.12

var font_body: Font
var font_disp: Font

const C_GRASS_A := Color("5d7a3e")
const C_GRASS_B := Color("55703a")
const C_FIELD := Color("6d8f47")
const C_STONE := Color("b9ae97")
const C_STONE_DK := Color("8d8271")
const C_STONE_SH := Color("57503f")
const C_DOWN := Color("4a463d")
const C_GOLD := Color("d9b451")
const C_BANNER := Color("2f4f8f")
const C_INV_M := Color("9e2b25")
const C_INV_R := Color("c4732a")
const C_SORTIE := Color("3a63b8")
const C_ARCHER_FIG := Color("d8cbb0")   ## parapet archer figures
const C_INFANTRY_FIG := Color("9fb4d8")  ## parapet infantry figures
const C_ARROW_OUT := Color("f0e6cf")     ## defender arrows — pale shaft
const C_ARROW_IN := Color("e8b24a")      ## invader arrows — darker, warmer

## Wall and turret states for the reconnaissance view (§10). These deliberately
## match the values _draw_walls() uses for the player's own fiefdom, so a
## scouted rival reads exactly like home: same stone, same darkening per state.
const C_WALL_FULL := Color("b9ae97")      ## == C_STONE
const C_WALL_PART := Color("b9ae97")      ## partial walls render as full stone
const C_WALL_CRUMBLE := Color("908775")   ## == C_STONE.darkened(0.22)
const C_BREACH := Color("4a463d")         ## == C_DOWN
const C_TURRET := Color("bdb29d")         ## == C_STONE.lightened(0.06)

var _scatter: Array = []
var _last_draw_tick: int = -1
var gain_popups: Array = []
var _popup_serial: int = 0

## Legacy emergency crowd fallback. Normal mobile troops now use the actual
## detailed knight/archer atlases in MultiMesh batches (managed by ArmyRenderer).
## These simple meshes remain only as a worst-case fallback after sustained lag.
var _invader_multimesh: MultiMesh
var _invader_head_multimesh: MultiMesh
var _invader_shadow_multimesh: MultiMesh
var _invader_bow_multimesh: MultiMesh
## Decorative wall garrison. Drawn with the same three-part soldier shape the
## game uses for close-up units - at most 120 figures, far below the 500 the
## detailed path already handles, so a MultiMesh batch is unnecessary here.
var _wall_crowd_count: int = 0
# Persistent presentation state for wall defenders. When an attack ends, figures
# ease out of their combat formation while their patrol clock continues running,
# so they never snap/teleport back to a pre-attack patrol position.
var _wall_response_state: Dictionary = {}
## Screen positions of this frame's archer figures, per wall, so defender arrows
## can be drawn leaving the soldier nearest the shot rather than a bare point on
## the wall line. View-only; rebuilt every frame before arrows are drawn.
var _wall_archer_pts := {"N": [], "E": [], "S": [], "W": [],
	"NW": [], "NE": [], "SE": [], "SW": []}
var _invader_texture: ImageTexture
var _gpu_crowd_capacity: int = 0
var _gpu_crowd_tick: int = -1
var _gpu_crowd_count: int = 0
var _gpu_ranged_count: int = 0
var _gpu_crowd_last_usec: int = 0

## Detailed mobile soldiers are also GPU-batched.  Each active batch shares one
## atlas texture/animation frame/facing, while per-instance transforms and colors
## preserve every visible soldier position and faction tint.  This keeps the
## detailed art without one CanvasItem draw submission per soldier.
var _detail_sprite_batches: Dictionary = {}
var _detail_sprite_active_keys: Array = []
var _detail_sprite_last_usec: int = 0
var _detail_sprite_context: int = -2147483648
var _detail_sprite_rebuilding: bool = false
var _detail_anim_walk_base: int = 0
var _detail_anim_attack_base: int = 0
var crowd_presentation = CrowdPresentation.new()

## Presentation-only interpolation fraction supplied by Main every frame.
var render_alpha: float = 0.0

## Local adaptive presentation quality. 0=performance, 4=ultra. This never
## changes simulation state or network authority; it only decides how richly
## this machine draws the same authoritative battle.
var adaptive_quality_level: int = UpConfigRef.ADAPTIVE_QUALITY_START
var _quality_avg_frame_ms: float = 16.7
var _quality_avg_work_ms: float = 8.0
var _quality_eval_elapsed: float = 0.0
var _quality_up_elapsed: float = 0.0
var _quality_down_elapsed: float = 0.0
var _quality_last_change_msec: int = 0

## Emergency-only performance fallback. Every stage keeps detailed soldier art.
## Stages 1/2 only reduce batch refresh/sampling after sustained distracting lag.
var adaptive_detail_stage: int = 0
var _detail_lag_elapsed: float = 0.0
var _detail_recovery_elapsed: float = 0.0
var _detail_last_change_msec: int = 0

## Rendering is split into two CanvasItem layers. The root/static layer owns
## input and redraws only when world/camera state changes. A child BoardView
## reuses the same renderer code for continuously moving combat/effects.
var render_role: String = "static" # "static", "dynamic", or "tooltip"
var dynamic_layer: BoardView = null
var tooltip_layer: BoardView = null
var _last_static_check_tick: int = -1
var _last_static_signature: int = -1
var _last_tooltip_signature: int = -1

func detail_sprite_limit() -> int:
	# 1500 is the normal/preferred ceiling. Only sustained severe lag lowers it.
	match adaptive_detail_stage:
		1: return UpConfigRef.ADAPTIVE_DETAIL_STAGE1_LIMIT
		2: return UpConfigRef.ADAPTIVE_DETAIL_STAGE2_LIMIT
		_: return UpConfigRef.UNIT_DETAIL_LIMIT

func visual_soldier_cap() -> int:
	# Keep recognizable detailed soldiers even on slow machines. Lower quality
	# tiers reduce the NUMBER of simultaneously represented soldiers and refresh
	# cadence, never replace them with geometric primitives.
	match adaptive_quality_level:
		0: return 3000
		1: return 5000
		2: return 8000
		3: return 12000
		_: return 16000

func visual_wall_scale() -> float:
	return [0.45, 0.62, 0.80, 1.0, 1.18][adaptive_quality_level]

func projectile_stride() -> int:
	return [5, 3, 2, 1, 1][adaptive_quality_level]

func impact_stride() -> int:
	return [4, 3, 2, 1, 1][adaptive_quality_level]

func death_visual_cap_per_event() -> int:
	return [12, 30, 80, 250, 1000][adaptive_quality_level]

func effect_spark_rays() -> int:
	return [2, 4, 6, 8, 8][adaptive_quality_level]

func effect_particle_count() -> int:
	return [0, 1, 2, 4, 6][adaptive_quality_level]

func quality_shadows_enabled() -> bool:
	return adaptive_quality_level >= 2

func animation_variation_scale() -> float:
	return [0.0, 0.25, 0.55, 0.82, 1.0][adaptive_quality_level]

func patrol_motion_scale() -> float:
	# Wall/turret garrison patrol is core readability, not optional decoration.
	# Keep it visibly moving even on the lowest adaptive tier.
	return [0.62, 0.72, 0.82, 0.92, 1.0][adaptive_quality_level]

func crowd_refresh_usec() -> int:
	return [100000, 75000, 50000, 33333, 25000][adaptive_quality_level]

func detailed_batch_refresh_usec(total_mobile: int) -> int:
	# Same detailed atlas at every tier. Under pressure we update transforms and
	# animation frames less often; Canvas interpolation keeps motion readable.
	# Crowd transforms do not need to be rebuilt at render-frame frequency.
	# 20-30 Hz transform updates with sprite animation between updates read as
	# continuous motion while cutting thousands of GDScript->engine setters.
	var usec: int = [100000, 80000, 50000, 40000, 33333][adaptive_quality_level]
	if total_mobile > UpConfigRef.UNIT_DETAIL_LIMIT:
		usec = maxi(usec, 33333)
	if adaptive_detail_stage == 1:
		usec = maxi(usec, 66667)
	elif adaptive_detail_stage >= 2:
		usec = maxi(usec, 100000)
	return usec

func should_use_simplified_crowd(_total_mobile: int) -> bool:
	# Geometric soldiers are no longer a runtime fallback. Even the emergency
	# stage preserves the detailed infantry/archer atlas and instead lowers batch
	# refresh cadence plus visual sampling density.
	return false

func interpolation_alpha() -> float:
	var a := clampf(render_alpha, 0.0, 1.0)
	# On the lowest tiers, quantize presentation interpolation to reduce constant
	# visual churn. Simulation remains fixed at 10 TPS and fully exact.
	if adaptive_quality_level == 0:
		return round(a * 2.0) / 2.0
	if adaptive_quality_level == 1:
		return round(a * 4.0) / 4.0
	return a

func _update_adaptive_detail_fallback(fps: int) -> void:
	# Detailed sprites are a readability priority. Ordinary 40-50 FPS variation
	# and short spikes do nothing. Only sustained ~30 FPS-class lag escalates this
	# stage, and escalation now reduces update cadence/sampling rather than changing
	# soldiers into geometric shapes. Cosmetic FX is always sacrificed first.
	var fx_fallback_exhausted: bool = adaptive_quality_level <= UpConfigRef.ADAPTIVE_QUALITY_MIN
	var severe_lag := fx_fallback_exhausted and (
		_quality_avg_frame_ms > UpConfigRef.ADAPTIVE_DETAIL_LAG_FRAME_MS
		or _quality_avg_work_ms > UpConfigRef.ADAPTIVE_DETAIL_LAG_WORK_MS
		or (fps > 0 and fps < UpConfigRef.ADAPTIVE_DETAIL_LAG_FPS)
	)
	var healthy := (
		_quality_avg_frame_ms < UpConfigRef.ADAPTIVE_DETAIL_RECOVER_FRAME_MS
		and _quality_avg_work_ms < UpConfigRef.ADAPTIVE_DETAIL_RECOVER_WORK_MS
		and (fps == 0 or fps >= UpConfigRef.ADAPTIVE_DETAIL_RECOVER_FPS)
	)

	if severe_lag:
		_detail_lag_elapsed += UpConfigRef.ADAPTIVE_QUALITY_EVAL_SECONDS
		_detail_recovery_elapsed = 0.0
	elif healthy:
		_detail_recovery_elapsed += UpConfigRef.ADAPTIVE_QUALITY_EVAL_SECONDS
		_detail_lag_elapsed = maxf(0.0, _detail_lag_elapsed - UpConfigRef.ADAPTIVE_QUALITY_EVAL_SECONDS)
	else:
		# Borderline performance neither escalates nor immediately erases the lag
		# history. This makes the trigger resistant to isolated spikes.
		_detail_lag_elapsed = maxf(0.0, _detail_lag_elapsed - UpConfigRef.ADAPTIVE_QUALITY_EVAL_SECONDS * 0.25)
		_detail_recovery_elapsed = 0.0

	var now_msec := Time.get_ticks_msec()
	var cooldown_msec := int(UpConfigRef.ADAPTIVE_DETAIL_CHANGE_COOLDOWN_SECONDS * 1000.0)
	var change_allowed := _detail_last_change_msec <= 0 or now_msec - _detail_last_change_msec >= cooldown_msec

	if change_allowed and adaptive_detail_stage == 0 and _detail_lag_elapsed >= UpConfigRef.ADAPTIVE_DETAIL_DOWN_HOLD_SECONDS:
		adaptive_detail_stage = 1
		_detail_lag_elapsed = 0.0
		_detail_recovery_elapsed = 0.0
		_detail_last_change_msec = now_msec
		_gpu_crowd_last_usec = 0
	elif change_allowed and adaptive_detail_stage == 1 and _detail_lag_elapsed >= UpConfigRef.ADAPTIVE_DETAIL_STAGE2_HOLD_SECONDS:
		adaptive_detail_stage = 2
		_detail_lag_elapsed = 0.0
		_detail_recovery_elapsed = 0.0
		_detail_last_change_msec = now_msec
		_gpu_crowd_last_usec = 0
	elif change_allowed and adaptive_detail_stage > 0 and _detail_recovery_elapsed >= UpConfigRef.ADAPTIVE_DETAIL_RECOVER_HOLD_SECONDS:
		# Recover one stage at a time only after long, clear headroom.
		adaptive_detail_stage -= 1
		_detail_lag_elapsed = 0.0
		_detail_recovery_elapsed = 0.0
		_detail_last_change_msec = now_msec
		_gpu_crowd_last_usec = 0


func _update_adaptive_quality(delta: float) -> void:
	if delta <= 0.0:
		return
	var frame_ms := clampf(delta * 1000.0, 1.0, 100.0)
	var work_ms := clampf(float(Performance.get_monitor(Performance.TIME_PROCESS)) * 1000.0, 0.0, 100.0)
	_quality_avg_frame_ms = lerpf(_quality_avg_frame_ms, frame_ms, 0.055)
	_quality_avg_work_ms = lerpf(_quality_avg_work_ms, work_ms, 0.075)
	_quality_eval_elapsed += delta
	if _quality_eval_elapsed < UpConfigRef.ADAPTIVE_QUALITY_EVAL_SECONDS:
		return
	_quality_eval_elapsed = 0.0

	# Hysteresis is intentionally asymmetric: visual quality drops quickly when
	# responsiveness is threatened, but only rises after several seconds of clear
	# headroom. This avoids quality oscillation during huge battles.
	var fps := Engine.get_frames_per_second()
	_update_adaptive_detail_fallback(fps)
	var wants_down := _quality_avg_frame_ms > 21.0 or _quality_avg_work_ms > 16.5 or (fps > 0 and fps < 48)
	# TIME_PROCESS measures actual work rather than VSync waiting, so a powerful
	# machine on a 60 Hz display can still climb toward Ultra.
	var wants_up := _quality_avg_work_ms < 9.0 and (fps == 0 or fps >= 55)
	if wants_down:
		_quality_down_elapsed += UpConfigRef.ADAPTIVE_QUALITY_EVAL_SECONDS
		_quality_up_elapsed = 0.0
	elif wants_up:
		_quality_up_elapsed += UpConfigRef.ADAPTIVE_QUALITY_EVAL_SECONDS
		_quality_down_elapsed = 0.0
	else:
		_quality_up_elapsed = 0.0
		_quality_down_elapsed = 0.0

	if _quality_down_elapsed >= UpConfigRef.ADAPTIVE_QUALITY_DOWN_HOLD_SECONDS and adaptive_quality_level > UpConfigRef.ADAPTIVE_QUALITY_MIN:
		adaptive_quality_level -= 1
		_quality_down_elapsed = 0.0
		_quality_up_elapsed = 0.0
		_gpu_crowd_last_usec = 0
		_quality_last_change_msec = Time.get_ticks_msec()
	elif _quality_up_elapsed >= UpConfigRef.ADAPTIVE_QUALITY_UP_HOLD_SECONDS and adaptive_quality_level < UpConfigRef.ADAPTIVE_QUALITY_MAX:
		adaptive_quality_level += 1
		_quality_down_elapsed = 0.0
		_quality_up_elapsed = 0.0
		_gpu_crowd_last_usec = 0
		_quality_last_change_msec = Time.get_ticks_msec()


func _ready() -> void:
	# Child render layers share the root textures and do not load/copy the modular
	# castle assets or hit-test images. This avoids duplicate image memory and setup.
	if FIEFDOM_CASTLE_ART == null or FIEFDOM_LANDSCAPE_ART == null:
		_apply_faction_visuals(faction_visual_id)

	font_body = ThemeDB.fallback_font
	font_disp = font_body
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	mouse_filter = Control.MOUSE_FILTER_PASS if render_role == "static" else Control.MOUSE_FILTER_IGNORE

	if render_role != "tooltip":
		var rng := RandomNumberGenerator.new()
		rng.seed = 424242
		for i in 420:
			_scatter.append(Vector3(rng.randf(), rng.randf(), rng.randf()))

	if render_role != "static":
		if render_role == "dynamic":
			_init_gpu_crowd()
		set_process(false)
		return

	_load_modular_castle_art()

	# The dynamic child draws moving units/effects.
	dynamic_layer = BoardView.new()
	dynamic_layer.render_role = "dynamic"
	dynamic_layer.name = "DynamicBattleLayer"
	dynamic_layer.z_index = 1000
	dynamic_layer.z_as_relative = false
	dynamic_layer.faction_visual_id = faction_visual_id
	dynamic_layer.FIEFDOM_CASTLE_ART = FIEFDOM_CASTLE_ART
	dynamic_layer.FIEFDOM_LANDSCAPE_ART = FIEFDOM_LANDSCAPE_ART
	add_child(dynamic_layer)
	dynamic_layer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	# The animated layer must never participate in hit-testing; all gameplay input
	# stays on the static BoardView below it.
	dynamic_layer.mouse_filter = Control.MOUSE_FILTER_IGNORE

	# Dedicated tooltip layer. Tooltips must be the absolute topmost board visual,
	# above castle art, buildings, ghosts, soldiers, projectiles, and effects.
	tooltip_layer = BoardView.new()
	tooltip_layer.render_role = "tooltip"
	tooltip_layer.name = "TooltipLayer"
	tooltip_layer.z_index = 4096
	tooltip_layer.z_as_relative = false
	tooltip_layer.faction_visual_id = faction_visual_id
	tooltip_layer.FIEFDOM_CASTLE_ART = FIEFDOM_CASTLE_ART
	tooltip_layer.FIEFDOM_LANDSCAPE_ART = FIEFDOM_LANDSCAPE_ART
	add_child(tooltip_layer)
	tooltip_layer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	tooltip_layer.mouse_filter = Control.MOUSE_FILTER_IGNORE

	set_process(true)


func _texture_from_png(path: String) -> Texture2D:
	var resource = load(path)
	if resource is Texture2D:
		return resource as Texture2D
	var image: Image = Image.load_from_file(path)
	if image == null or image.is_empty():
		push_error("Could not load faction art: %s" % path)
		return null
	return ImageTexture.create_from_image(image)


func _apply_faction_visuals(faction_id: String) -> void:
	var id: String = faction_id.to_lower()
	if not FACTION_VISUALS.has(id):
		id = "ironcrest"
	var visual: Dictionary = FACTION_VISUALS[id]
	var castle_tex: Texture2D = _texture_from_png(str(visual["castle"]))
	var landscape_tex: Texture2D = _texture_from_png(str(visual["landscape"]))
	if castle_tex != null:
		FIEFDOM_CASTLE_ART = castle_tex
	if landscape_tex != null:
		FIEFDOM_LANDSCAPE_ART = landscape_tex
	faction_visual_id = id


func _load_modular_castle_art() -> void:
	if MODULAR_GRID_ART != null and not MODULAR_WALL_INTACT.is_empty() and not MODULAR_TOWER_INTACT.is_empty():
		return
	MODULAR_GRID_ART = _texture_from_png("res://view/assets/castle_grid_exact.png")
	for d in UpMatch.DIRS:
		var intact_tex: Texture2D = _texture_from_png("res://view/assets/castle_wall_%s_intact.png" % d)
		var partial_tex: Texture2D = _texture_from_png("res://view/assets/castle_wall_%s_partial.png" % d)
		var rubble_tex: Texture2D = _texture_from_png("res://view/assets/castle_wall_%s_rubble.png" % d)
		if intact_tex != null:
			MODULAR_WALL_INTACT[d] = intact_tex
			var wall_hit_img: Image = intact_tex.get_image()
			if wall_hit_img != null and not wall_hit_img.is_empty():
				var wall_mask := BitMap.new()
				wall_mask.create_from_image_alpha(wall_hit_img, 0.06)
				MODULAR_WALL_HIT_MASKS[d] = wall_mask
		if partial_tex != null:
			MODULAR_WALL_PARTIAL[d] = partial_tex
		if rubble_tex != null:
			MODULAR_WALL_RUBBLE[d] = rubble_tex
	for tid in UpMatch.TURRETS:
		var intact_t: Texture2D = _texture_from_png("res://view/assets/castle_tower_%s_intact.png" % tid)
		var partial_t: Texture2D = _texture_from_png("res://view/assets/castle_tower_%s_partial.png" % tid)
		var rubble_t: Texture2D = _texture_from_png("res://view/assets/castle_tower_%s_rubble.png" % tid)
		if intact_t != null:
			MODULAR_TOWER_INTACT[tid] = intact_t
			var tower_hit_img: Image = intact_t.get_image()
			if tower_hit_img != null and not tower_hit_img.is_empty():
				var tower_mask := BitMap.new()
				tower_mask.create_from_image_alpha(tower_hit_img, 0.06)
				MODULAR_TOWER_HIT_MASKS[tid] = tower_mask
		if partial_t != null:
			MODULAR_TOWER_PARTIAL[tid] = partial_t
		if rubble_t != null:
			MODULAR_TOWER_RUBBLE[tid] = rubble_t


func set_faction_visual(faction_id: String) -> void:
	# Public hook for a future faction-selection screen. Add another entry to
	# FACTION_VISUALS and call this with its key to swap both castle and landscape.
	_apply_faction_visuals(faction_id)
	if dynamic_layer != null:
		dynamic_layer.faction_visual_id = faction_visual_id
		dynamic_layer.FIEFDOM_CASTLE_ART = FIEFDOM_CASTLE_ART
		dynamic_layer.FIEFDOM_LANDSCAPE_ART = FIEFDOM_LANDSCAPE_ART
	if tooltip_layer != null:
		tooltip_layer.faction_visual_id = faction_visual_id
		tooltip_layer.FIEFDOM_CASTLE_ART = FIEFDOM_CASTLE_ART
		tooltip_layer.FIEFDOM_LANDSCAPE_ART = FIEFDOM_LANDSCAPE_ART
	queue_redraw()


func _init_gpu_crowd() -> void:
	# Emergency-only lightweight crowd resources. The preferred renderer now batches
	# the actual detailed sprite atlases; these simple shapes are retained only for
	# the final adaptive fallback when a machine cannot sustain the detailed batches.
	var img := Image.create(2, 2, false, Image.FORMAT_RGBA8)
	img.fill(Color.WHITE)
	_invader_texture = ImageTexture.create_from_image(img)

	# Large crowds still use MultiMesh, but preserve the same visual language as
	# the detailed path: colored body, skin head, soft shadow, and a bow marker
	# for ranged troops. This costs only a handful of batched draw calls.
	var body_quad := QuadMesh.new()
	body_quad.size = Vector2(7.2, 14.0)
	var head_quad := QuadMesh.new()
	head_quad.size = Vector2(8.0, 8.0)
	var shadow_quad := QuadMesh.new()
	shadow_quad.size = Vector2(13.6, 4.8)
	var bow_quad := QuadMesh.new()
	bow_quad.size = Vector2(2.4, 14.0)

	_invader_multimesh = MultiMesh.new()
	_invader_multimesh.transform_format = MultiMesh.TRANSFORM_2D
	_invader_multimesh.use_colors = true
	_invader_multimesh.mesh = body_quad

	_invader_head_multimesh = MultiMesh.new()
	_invader_head_multimesh.transform_format = MultiMesh.TRANSFORM_2D
	_invader_head_multimesh.use_colors = true
	_invader_head_multimesh.mesh = head_quad

	_invader_shadow_multimesh = MultiMesh.new()
	_invader_shadow_multimesh.transform_format = MultiMesh.TRANSFORM_2D
	_invader_shadow_multimesh.use_colors = true
	_invader_shadow_multimesh.mesh = shadow_quad

	_invader_bow_multimesh = MultiMesh.new()
	_invader_bow_multimesh.transform_format = MultiMesh.TRANSFORM_2D
	_invader_bow_multimesh.use_colors = true
	_invader_bow_multimesh.mesh = bow_quad

	for mm in [_invader_multimesh, _invader_head_multimesh, _invader_shadow_multimesh, _invader_bow_multimesh]:
		mm.instance_count = 0
		mm.visible_instance_count = 0





## Garrison figures pacing each standing wall. View-only: reads garrison sizes
## and writes nothing back to the simulation.
##
## Each figure keeps its own beat rather than sweeping the whole wall in unison:
## a private sub-stretch to walk, its own speed, its own phase, and a lateral
## offset across the walkway. All derived from the figure's index, so it is
## deterministic and costs no stored state.
func _wall_outward_facing(d: String) -> String:
	match d:
		"N": return "N"
		"S": return "S"
		"W": return "W"
		_: return "E"


func _local_wall_under_attack(d: String) -> bool:
	if match_ref == null:
		return false
	for inv: UpMatch.Invader in match_ref.invaders:
		if inv.hp > 0 and not inv.inside and inv.wall == d and inv.at_wall:
			return true
	return false


func _local_wall_attack_lane_fraction(d: String) -> float:
	# Mean lane of all groups currently pressing this wall.  Defenders converge
	# toward the portion of the parapet directly overlooking the attackers.
	if match_ref == null:
		return 0.5
	var total_lane: float = 0.0
	var groups: int = 0
	for inv: UpMatch.Invader in match_ref.invaders:
		if inv.hp > 0 and not inv.inside and inv.wall == d and inv.at_wall:
			total_lane += float(inv.wall_lane)
			groups += 1
	if groups <= 0:
		return 0.5
	return clampf((total_lane / float(groups)) / float(GRID * CELL), 0.04, 0.96)


func _local_wall_attack_move_progress(d: String) -> float:
	# Use the first physical wall contact as the start of a short visual run to the
	# outer parapet. This is presentation-only; combat timing remains authoritative.
	if match_ref == null:
		return 0.0
	var first_contact: int = -1
	for inv: UpMatch.Invader in match_ref.invaders:
		if inv.hp <= 0 or inv.inside or inv.wall != d or not inv.at_wall:
			continue
		if inv.wall_contact_tick >= 0 and (first_contact < 0 or inv.wall_contact_tick < first_contact):
			first_contact = inv.wall_contact_tick
	if first_contact < 0:
		return 1.0 if _local_wall_under_attack(d) else 0.0
	var move_ticks: float = maxf(1.0, float(UpConfigRef.TPS) * 0.85)
	return clampf((float(match_ref.tick - first_contact) + interpolation_alpha()) / move_ticks, 0.0, 1.0)


func _rival_wall_under_attack(rv: UpMatch.Rival, d: String) -> bool:
	for inv: UpMatch.Invader in rv.invaders:
		if inv.hp > 0 and not inv.inside and inv.wall == d and inv.at_wall:
			return true
	return false


func _rival_wall_attack_lane_fraction(rv: UpMatch.Rival, d: String) -> float:
	var total_lane: float = 0.0
	var groups: int = 0
	for inv: UpMatch.Invader in rv.invaders:
		if inv.hp > 0 and not inv.inside and inv.wall == d and inv.at_wall:
			total_lane += float(inv.wall_lane)
			groups += 1
	if groups <= 0:
		return 0.5
	return clampf((total_lane / float(groups)) / float(GRID * CELL), 0.04, 0.96)


func _rival_wall_attack_move_progress(rv: UpMatch.Rival, d: String) -> float:
	var first_contact: int = -1
	for inv: UpMatch.Invader in rv.invaders:
		if inv.hp <= 0 or inv.inside or inv.wall != d or not inv.at_wall:
			continue
		if inv.wall_contact_tick >= 0 and (first_contact < 0 or inv.wall_contact_tick < first_contact):
			first_contact = inv.wall_contact_tick
	if first_contact < 0:
		return 1.0 if _rival_wall_under_attack(rv, d) else 0.0
	var move_ticks: float = maxf(1.0, float(UpConfigRef.TPS) * 0.85)
	return clampf((float(match_ref.tick - first_contact) + interpolation_alpha()) / move_ticks, 0.0, 1.0)


func _wall_response(key: String, under_attack: bool, lane_f: float, attack_move: float, now_usec: float) -> Dictionary:
	# Preserve the last combat lane and blend smoothly back into the continuously
	# advancing patrol path after combat.  Patrol phase never pauses, so defenders
	# simply resume walking from where the release blend leaves them instead of
	# jumping back to an old procedural position.
	var st: Dictionary = _wall_response_state.get(key, {"blend": 0.0, "lane": lane_f, "last_usec": now_usec})
	var prev_usec: float = float(st.get("last_usec", now_usec))
	var dt: float = clampf((now_usec - prev_usec) / 1000000.0, 0.0, 0.12)
	var blend: float = float(st.get("blend", 0.0))
	var lane: float = float(st.get("lane", lane_f))
	if under_attack:
		lane = lane_f
		# Rush-in remains quick and follows the authoritative attack approach.
		blend = maxf(blend, attack_move)
	else:
		# Return at ordinary patrol pace rather than teleporting. A ~5 second release
		# is comparable to traversing a normal patrol segment at current visual speed.
		blend = maxf(0.0, blend - dt / 5.0)
	st["blend"] = blend
	st["lane"] = lane
	st["last_usec"] = now_usec
	_wall_response_state[key] = st
	return st


func _local_turret_attack_wall(tid: String) -> String:
	var adj: Array = UpMatch.TURRET_WALLS[tid]
	for d in adj:
		if _local_wall_under_attack(str(d)):
			return str(d)
	return ""


func _rival_turret_attack_wall(rv: UpMatch.Rival, tid: String) -> String:
	var adj: Array = UpMatch.TURRET_WALLS[tid]
	for d in adj:
		if _rival_wall_under_attack(rv, str(d)):
			return str(d)
	return ""


func _scan_facing(now_usec: float, seed: int) -> String:
	var idx: int = posmod(int(floor(now_usec / 2300000.0)) + posmod(seed, 4), 4)
	match idx:
		0: return "N"
		1: return "E"
		2: return "S"
		_: return "W"


func _draw_wall_crowd() -> void:
	if match_ref == null:
		return
	var m = match_ref
	var inner: int = GRID * px_cell
	var off: int = wall_thick + gap
	var now := float(Time.get_ticks_usec())
	_wall_crowd_count = 0
	for k in _wall_archer_pts: _wall_archer_pts[k].clear()

	for d in UpMatch.DIRS:
		var w = m.walls[d]
		if w.collapsed:
			continue
		var garrison: int = m.garrison_count(w.melee) + m.garrison_count(w.ranged)
		if garrison <= 0:
			continue
		var n: int = _wall_figure_count(garrison)
		var ranged_share: float = float(m.garrison_count(w.ranged)) / float(garrison)
		var horiz: bool = d == "N" or d == "S"
		var rect: Rect2 = _wall_rect(d, inner, off)
		var walk_depth: float = maxf(12.0, float(wall_thick) * 0.26)
		var walk_rect: Rect2 = _castle_wall_walk_rect(d) if _use_exact_castle_art() else rect
		if not _use_exact_castle_art():
			if horiz:
				if d == "N":
					walk_rect.size.y = walk_depth
				else:
					walk_rect.position.y = rect.end.y - walk_depth
					walk_rect.size.y = walk_depth
			else:
				if d == "W":
					walk_rect.size.x = walk_depth
				else:
					walk_rect.position.x = rect.end.x - walk_depth
					walk_rect.size.x = walk_depth
		var span: float = (walk_rect.size.x if horiz else walk_rect.size.y) - 10.0
		var width: float = (walk_rect.size.y if horiz else walk_rect.size.x)
		# Leave visible personal space between parapet defenders.  If a huge
		# garrison would make sprites overlap, show fewer representative figures
		# rather than stacking them on top of one another.
		var wall_slot_spacing: float = 26.0
		n = mini(n, maxi(2, int(floor(maxf(1.0, span) / wall_slot_spacing))))
		var walk_quad: PackedVector2Array = _castle_wall_walk_quad(d) if _use_exact_castle_art() else PackedVector2Array()
		var under_attack: bool = _local_wall_under_attack(d)
		var attack_lane_f: float = _local_wall_attack_lane_fraction(d) if under_attack else 0.5
		var attack_move: float = _local_wall_attack_move_progress(d) if under_attack else 0.0
		var response: Dictionary = _wall_response("home:%s" % d, under_attack, attack_lane_f, attack_move, now)
		var response_blend: float = float(response["blend"])
		var response_lane_f: float = float(response["lane"])

		for i in n:
			var h: int = (i * 2654435761 + int(d.unicode_at(0)) * 40503) & 0x7FFFFFFF
			# Patrol over most of the usable wall length so movement reads as forward
			# travel rather than walking in place.  Each soldier still owns a slightly
			# different segment and speed to avoid marching in lock-step.
			var beat: float = 0.56 + float(h % 31) / 100.0
			beat = minf(beat, 0.86)
			var slot_center_f: float = (float(i) + 0.5) / float(maxi(1, n))
			var slot_half_f: float = 0.34 / float(maxi(1, n))
			var startf: float = clampf(slot_center_f - slot_half_f, 0.0, 1.0)
			beat = minf(beat, slot_half_f * 2.0)
			var period: float = float(UpConfigRef.WALL_PATROL_SLOW_USEC
				- (h / 4343) % (UpConfigRef.WALL_PATROL_SLOW_USEC - UpConfigRef.WALL_PATROL_FAST_USEC))
			var phase: float = fmod(now / period + float((h / 7) % 100) / 100.0, 1.0)
			var moving_positive: bool = sin(phase * TAU) >= 0.0
			# Cosine ping-pong gives a smooth turn at each end rather than snapping from
			# one direction to the other.
			var travel: float = 0.5 - 0.5 * cos(phase * TAU)
			travel = lerpf(0.5, travel, patrol_motion_scale())
			var along: float = (startf + travel * beat) * maxf(1.0, span) + 6.0
			var lateral_range: float = width - 7.0
			var lateral: float = (float((h / 97) % 100) / 100.0 - 0.5) * lateral_range

			var p: Vector2
			if _use_exact_castle_art():
				# Patrol freely when idle. Under attack, run toward the section of the
				# parapet overlooking the invader lane and then to its OUTER edge:
				# north/south defenders move up/down; west/east defenders left/right.
				var patrol_along_f: float = clampf(startf + travel * beat, 0.015, 0.985)
				var patrol_across_f: float = 0.08 + float((h / 97) % 100) / 100.0 * 0.84
				var formation_step_f: float = minf(0.06, wall_slot_spacing / maxf(1.0, span))
				var formation_offset: float = (float(i) - float(n - 1) * 0.5) * formation_step_f
				var target_along_f: float = clampf(response_lane_f + formation_offset, 0.03, 0.97)
				var outer_across_f: float = 0.07 if d == "N" or d == "W" else 0.93
				var along_f: float = lerpf(patrol_along_f, target_along_f, response_blend)
				var across_f: float = lerpf(patrol_across_f, outer_across_f, response_blend)
				p = _quad_bilerp(walk_quad, along_f, across_f) if horiz else _quad_bilerp(walk_quad, across_f, along_f)
			else:
				p = Vector2(walk_rect.position.x + along, walk_rect.position.y + width * 0.5 + lateral) if horiz \
					else Vector2(walk_rect.position.x + width * 0.5 + lateral, walk_rect.position.y + along)
			var is_ranged: bool = float(i) / float(n) < ranged_share
			var facing_dir: String = _wall_outward_facing(d) if under_attack else (("E" if moving_positive else "W") if horiz else ("S" if moving_positive else "N"))
			var anim_state: String = "attack" if under_attack and attack_move >= 0.88 else "walk"
			if is_ranged:
				var face: float = -1.0 if facing_dir == "W" or facing_dir == "N" else 1.0
				ArmyRenderer.draw_detailed_archer(self, p, C_BANNER.lightened(0.30), face, h, anim_state, -1.0, 1.15, facing_dir)
				_wall_archer_pts[d].append(p)
			else:
				ArmyRenderer.draw_detailed_soldier(self, p, C_BANNER, h, anim_state, -1.0, facing_dir == "W" or facing_dir == "N", 1.15, facing_dir)
			_wall_crowd_count += 1


## Turret garrisons. Same sqrt ratio as the walls but capped far lower, and
## near-stationary: a turret platform is a post, not a patrol route.
func _draw_turret_crowd() -> void:
	var m = match_ref
	var inner: int = GRID * px_cell
	var off: int = wall_thick + gap
	var now := float(Time.get_ticks_usec())

	for tid in UpMatch.TURRETS:
		var tr = m.turrets[tid]
		if tr.destroyed:
			continue
		var garrison: int = m.garrison_count(tr.melee) + m.garrison_count(tr.ranged)
		if garrison <= 0:
			continue
		var n: int = mini(UpConfigRef.TURRET_VISUAL_MAX, _wall_figure_count(garrison))
		var ranged_share: float = float(m.garrison_count(tr.ranged)) / float(garrison)
		var rect: Rect2 = _turret_rect(tid, inner, off)
		var platform_center: Vector2 = _castle_turret_platform_center(tid) if _use_exact_castle_art() else rect.get_center() - Vector2(0, rect.size.y * 0.06)
		var platform_radii: Vector2 = _castle_turret_platform_radii(tid) if _use_exact_castle_art() else Vector2(minf(rect.size.x, rect.size.y) * 0.30, minf(rect.size.x, rect.size.y) * 0.30)
		var attack_wall: String = _local_turret_attack_wall(tid)

		for i in n:
			var hh: int = (i * 2654435761 + int(tid.unicode_at(0)) * 7919
				+ int(tid.unicode_at(1)) * 104729) & 0x7FFFFFFF
			# a fixed post inside the platform, with a small shuffle on the spot
			var period: float = 7000000.0 + float((hh / 10007) % 5000000)
			var sway: float = sin(now / period * TAU + float(hh % 628) / 100.0) * 1.2 * patrol_motion_scale()
			var ang: float = TAU * float(hh % 1000) / 1000.0
			var radial: float = 0.20 + 0.70 * float((hh / 1000) % 100) / 100.0
			if _use_exact_castle_art():
				if n <= 1:
					ang = 0.0
					radial = 0.0
				else:
					# Deterministic rings keep turret defenders separated instead of
					# allowing several random radial posts to overlap.
					var outer_count: int = mini(n, 7)
					if i < outer_count:
						ang = -PI * 0.5 + TAU * float(i) / float(outer_count)
						radial = 0.78
					else:
						var inner_count: int = maxi(1, n - outer_count)
						ang = -PI * 0.5 + TAU * float(i - outer_count) / float(inner_count) + PI / float(maxi(2, inner_count))
						radial = 0.42
			var ellipse: Vector2 = Vector2(cos(ang) * platform_radii.x * radial, sin(ang) * platform_radii.y * radial)
			var p: Vector2 = platform_center + ellipse + Vector2(sway, sway * 0.25)
			var is_ranged: bool = float(i) / float(n) < ranged_share
			var facing_dir: String = _wall_outward_facing(attack_wall) if attack_wall != "" else _scan_facing(now, hh)
			var anim_state: String = "attack" if attack_wall != "" else "idle"
			if is_ranged:
				var face: float = -1.0 if facing_dir == "W" or facing_dir == "N" else 1.0
				ArmyRenderer.draw_detailed_archer(self, p, C_BANNER.lightened(0.30), face, hh, anim_state, -1.0, 1.15, facing_dir)
				_wall_archer_pts[tid].append(p)
			else:
				ArmyRenderer.draw_detailed_soldier(self, p, C_BANNER, hh, anim_state, -1.0, facing_dir == "W" or facing_dir == "N", 1.15, facing_dir)
			_wall_crowd_count += 1


func _wall_figure_count(garrison: int) -> int:
	if garrison <= 0:
		return 0
	var base := clampi(int(sqrt(float(garrison))), UpConfigRef.WALL_VISUAL_MIN, UpConfigRef.WALL_VISUAL_MAX)
	return clampi(int(round(float(base) * visual_wall_scale())), 2, int(round(float(UpConfigRef.WALL_VISUAL_MAX) * 1.2)))


func _ensure_gpu_crowd_capacity(required: int) -> void:
	if required <= _gpu_crowd_capacity:
		return
	var new_capacity := maxi(256, _gpu_crowd_capacity)
	while new_capacity < required:
		new_capacity *= 2
	new_capacity = mini(new_capacity, UpConfigRef.MAX_VISUAL_INVADERS)
	_gpu_crowd_capacity = new_capacity
	_invader_multimesh.instance_count = _gpu_crowd_capacity
	_invader_head_multimesh.instance_count = _gpu_crowd_capacity
	_invader_shadow_multimesh.instance_count = _gpu_crowd_capacity
	_invader_bow_multimesh.instance_count = _gpu_crowd_capacity


func _set_gpu_soldier_instance(index: int, p: Vector2, body_color: Color, ranged: bool) -> void:
	_invader_multimesh.set_instance_transform_2d(index, Transform2D(0.0, p + Vector2(0.0, -3.0)))
	_invader_multimesh.set_instance_color(index, body_color)
	_invader_head_multimesh.set_instance_transform_2d(index, Transform2D(0.0, p + Vector2(0.0, -13.0)))
	_invader_head_multimesh.set_instance_color(index, Color("e0c49a"))
	_invader_shadow_multimesh.set_instance_transform_2d(index, Transform2D(0.0, p + Vector2(0.0, 6.0)))
	_invader_shadow_multimesh.set_instance_color(index, Color(0, 0, 0, 0.24))
	if ranged:
		_invader_bow_multimesh.set_instance_transform_2d(_gpu_ranged_count, Transform2D(0.0, p + Vector2(6.0, -4.0)))
		_invader_bow_multimesh.set_instance_color(_gpu_ranged_count, Color("6b4a24"))
		_gpu_ranged_count += 1

func _finalize_gpu_crowd_counts() -> void:
	_invader_multimesh.visible_instance_count = _gpu_crowd_count
	_invader_head_multimesh.visible_instance_count = _gpu_crowd_count
	_invader_shadow_multimesh.visible_instance_count = _gpu_crowd_count if quality_shadows_enabled() else 0
	_invader_bow_multimesh.visible_instance_count = _gpu_ranged_count

func _draw_gpu_crowd_batches() -> void:
	if _gpu_crowd_count <= 0:
		return
	if quality_shadows_enabled():
		draw_multimesh(_invader_shadow_multimesh, _invader_texture)
	draw_multimesh(_invader_multimesh, _invader_texture)
	draw_multimesh(_invader_head_multimesh, _invader_texture)
	if _gpu_ranged_count > 0:
		draw_multimesh(_invader_bow_multimesh, _invader_texture)

func _refresh_gpu_crowd() -> void:
	if match_ref == null or _invader_multimesh == null:
		return

	# Updating thousands of MultiMesh transforms in a single 10 Hz burst produced
	# visible frame-time spikes. Update visual instances at ~30 Hz instead and use
	# interpolated group positions. Combat/simulation remains completely unchanged.
	var now_usec := Time.get_ticks_usec()
	if _gpu_crowd_last_usec > 0 and now_usec - _gpu_crowd_last_usec < crowd_refresh_usec():
		return
	_gpu_crowd_last_usec = now_usec
	_gpu_crowd_tick = match_ref.tick
	_gpu_ranged_count = 0

	# Only armies still outside the perimeter use the lightweight batched crowd.
	# Interior invaders and mobile defenders are deliberately rendered as detailed
	# sprites by ArmyRenderer so a breach can never make soldier imagery disappear.
	var total_soldiers: int = 0
	for inv: UpMatch.Invader in match_ref.invaders:
		if inv.hp > 0 and not inv.inside:
			total_soldiers += match_ref.invader_members(inv)
	if total_soldiers <= detail_sprite_limit():
		_gpu_crowd_count = 0
		_gpu_ranged_count = 0
		_invader_multimesh.visible_instance_count = 0
		_invader_head_multimesh.visible_instance_count = 0
		_invader_shadow_multimesh.visible_instance_count = 0
		_invader_bow_multimesh.visible_instance_count = 0
		return

	var stride := maxi(1, int(ceil(float(total_soldiers) / float(visual_soldier_cap()))))
	var wanted := int(ceil(float(total_soldiers) / float(stride)))
	wanted = mini(wanted, visual_soldier_cap())
	_ensure_gpu_crowd_capacity(wanted)

	var instance_i := 0
	for inv in match_ref.invaders:
		if inv.hp <= 0 or inv.inside:
			continue
		var members: int = match_ref.invader_members(inv)
		var visual_count := int(ceil(float(members) / float(stride)))
		if visual_count <= 0:
			continue

		var spread := minf(72.0, 10.0 + sqrt(float(visual_count)) * 3.8)
		var base := interpolated_invader_visual_px(inv)
		for n in visual_count:
			if instance_i >= visual_soldier_cap():
				break
			var seed: int = absi(inv.id * 1103515245 + n * 12345 + 1013904223)
			var fx := float(seed % 1009) / 1008.0
			var fy := float((seed / 1009) % 1013) / 1012.0
			var ox := (fx * 2.0 - 1.0) * spread
			var oy := (fy * 2.0 - 1.0) * spread

			if not inv.inside:
				if inv.wall == "N" or inv.wall == "S":
					ox *= 1.45
					oy *= 1.10
				else:
					oy *= 1.45
					ox *= 1.10

			var p := clamp_invader_visual_outside_wall(inv, base + Vector2(ox, oy))
			if not battle_visual_visible(p):
				continue
			var av := animation_variation_scale()
			if av > 0.0:
				var phase := float((seed % 628)) / 100.0 + float(now_usec % 4000000) / 4000000.0 * TAU
				p += Vector2(sin(phase) * 0.65, cos(phase * 0.73) * 0.35) * av
			var is_ranged: bool = str(inv.def["cat"]) == "ranged"
			var c: Color = inv.force_color.lightened(0.18) if is_ranged else inv.force_color
			_set_gpu_soldier_instance(instance_i, p, c, is_ranged)
			instance_i += 1

		if instance_i >= visual_soldier_cap():
			break

	# Interior invaders and sortie defenders are intentionally omitted here;
	# ArmyRenderer draws representative detailed sprites for those groups.

	_gpu_crowd_count = instance_i
	_finalize_gpu_crowd_counts()

func _refresh_rival_gpu_crowd(rv: UpMatch.Rival) -> void:
	if match_ref == null or _invader_multimesh == null:
		return
	var now_usec := Time.get_ticks_usec()
	if _gpu_crowd_last_usec > 0 and now_usec - _gpu_crowd_last_usec < crowd_refresh_usec():
		return
	_gpu_crowd_last_usec = now_usec
	_gpu_ranged_count = 0
	var total_soldiers: int = 0
	for inv: UpMatch.Invader in rv.invaders:
		if inv.hp > 0 and not inv.inside:
			total_soldiers += match_ref.invader_members(inv)
	if total_soldiers <= detail_sprite_limit():
		_gpu_crowd_count = 0
		_gpu_ranged_count = 0
		_invader_multimesh.visible_instance_count = 0
		_invader_head_multimesh.visible_instance_count = 0
		_invader_shadow_multimesh.visible_instance_count = 0
		_invader_bow_multimesh.visible_instance_count = 0
		return
	var stride: int = maxi(1, int(ceil(float(total_soldiers) / float(visual_soldier_cap()))))
	var wanted: int = mini(visual_soldier_cap(), int(ceil(float(total_soldiers) / float(stride))))
	_ensure_gpu_crowd_capacity(wanted)
	var instance_i: int = 0
	for inv: UpMatch.Invader in rv.invaders:
		if inv.hp <= 0 or inv.inside:
			continue
		var members: int = match_ref.invader_members(inv)
		var visual_count: int = int(ceil(float(members) / float(stride)))
		var spread: float = minf(72.0, 10.0 + sqrt(float(maxi(1, visual_count))) * 3.8)
		var base: Vector2 = interpolated_invader_visual_px(inv)
		for n in visual_count:
			if instance_i >= visual_soldier_cap():
				break
			var seed: int = absi(inv.id * 1103515245 + n * 12345 + 1013904223)
			var fx: float = float(seed % 1009) / 1008.0
			var fy: float = float((seed / 1009) % 1013) / 1012.0
			var ox: float = (fx * 2.0 - 1.0) * spread
			var oy: float = (fy * 2.0 - 1.0) * spread
			if not inv.inside:
				if inv.wall == "N" or inv.wall == "S":
					ox *= 1.45
					oy *= 1.10
				else:
					oy *= 1.45
					ox *= 1.10
			var pp: Vector2 = base + Vector2(ox, oy)
			if not battle_visual_visible(pp):
				continue
			var av := animation_variation_scale()
			if av > 0.0:
				var phase := float(seed % 628) / 100.0 + float(now_usec % 4000000) / 4000000.0 * TAU
				pp += Vector2(sin(phase) * 0.65, cos(phase * 0.73) * 0.35) * av
			var is_ranged: bool = str(inv.def["cat"]) == "ranged"
			var c: Color = inv.force_color.lightened(0.18) if is_ranged else inv.force_color
			_set_gpu_soldier_instance(instance_i, pp, c, is_ranged)
			instance_i += 1
		if instance_i >= visual_soldier_cap():
			break
	_gpu_crowd_count = instance_i
	_finalize_gpu_crowd_counts()


func board_px() -> int:
	return BoardCoordinates.board_px(self)

func _origin() -> Vector2:
	return BoardCoordinates.origin(self)

func _world_rect() -> Rect2:
	return BoardCoordinates.world_rect(self)

func _clamp_view_pan() -> void:
	BoardCoordinates.clamp_view_pan(self)

func _view_origin() -> Vector2:
	return BoardCoordinates.view_origin(self)

func _screen_to_board(screen_pos: Vector2) -> Vector2:
	return BoardCoordinates.screen_to_board(self, screen_pos)

func _board_to_screen(board_pos: Vector2) -> Vector2:
	return BoardCoordinates.board_to_screen(self, board_pos)

func battle_visual_visible(board_pos: Vector2, margin_px: float = 8.0) -> bool:
	return BoardCoordinates.battle_visual_visible(self, board_pos, margin_px)

func _zoom_at(screen_pos: Vector2, factor: float) -> void:
	BoardCoordinates.zoom_at(self, screen_pos, factor)

func reset_view() -> void:
	BoardCoordinates.reset_view(self)

func _castle_point_from_src(src: Vector2) -> Vector2:
	return BoardCoordinates.castle_point_from_src(self, src)

func _field_src_x_at(col: int, y_src: float) -> float:
	return BoardCoordinates.field_src_x_at(self, col, y_src)

func _field_src_y(row: int) -> float:
	return BoardCoordinates.field_src_y(self, row)

func cell_polygon(x: int, y: int) -> PackedVector2Array:
	return BoardCoordinates.cell_polygon(self, x, y)

func cell_rect(x: int, y: int) -> Rect2:
	return BoardCoordinates.cell_rect(self, x, y)

func cell_point(x: int, y: int, u: float, v: float) -> Vector2:
	return BoardCoordinates.cell_point(self, x, y, u, v)

func cell_center(x: int, y: int) -> Vector2:
	return BoardCoordinates.cell_center(self, x, y)

func to_px(c: int) -> float:
	return BoardCoordinates.to_px(self, c)

func to_py(r: int) -> float:
	return BoardCoordinates.to_py(self, r)

func mmf_to_px(mm: float) -> float:
	return BoardCoordinates.mmf_to_px(self, mm)

func mm_to_px(mm: int) -> float:
	return BoardCoordinates.mmf_to_px(self, float(mm))

func mmf_to_py(mm: float) -> float:
	return BoardCoordinates.mmf_to_py(self, mm)

func mm_to_py(mm: int) -> float:
	return BoardCoordinates.mmf_to_py(self, float(mm))

func interpolated_mm_to_px(prev_x: int, prev_y: int, x: int, y: int) -> Vector2:
	var a := interpolation_alpha()
	var ix := lerpf(float(prev_x), float(x), a)
	var iy := lerpf(float(prev_y), float(y), a)
	return Vector2(mmf_to_px(ix), mmf_to_py(iy))


func interpolated_invader_visual_px(inv) -> Vector2:
	# Outside armies need a visual coordinate system whose zero/contact point is
	# the *visible outer stone edge*, not the courtyard grid boundary.  This lets
	# a 10/15/20-second army visibly march across the exterior landscape for that
	# full time instead of being clamped against the wall as soon as it spawns.
	var a: float = interpolation_alpha()
	var ix: float = lerpf(float(inv.prev_x), float(inv.x), a)
	var iy: float = lerpf(float(inv.prev_y), float(inv.y), a)
	if inv.inside or match_ref == null:
		return Vector2(mmf_to_px(ix), mmf_to_py(iy))

	var contact = match_ref.invader_wall_contact_point(inv.wall, inv.wall_lane)
	var px_per_mm: float = float(px_cell) / float(CELL)
	match inv.wall:
		"N":
			var dist_n: float = maxf(0.0, float(contact.y) - iy)
			return Vector2(mmf_to_px(ix), _castle_outer_wall_visual_limit("N") - dist_n * px_per_mm)
		"S":
			var dist_s: float = maxf(0.0, iy - float(contact.y))
			return Vector2(mmf_to_px(ix), _castle_outer_wall_visual_limit("S") + dist_s * px_per_mm)
		"W":
			var dist_w: float = maxf(0.0, float(contact.x) - ix)
			return Vector2(_castle_outer_wall_visual_limit("W") - dist_w * px_per_mm, mmf_to_py(iy))
		_:
			var dist_e: float = maxf(0.0, ix - float(contact.x))
			return Vector2(_castle_outer_wall_visual_limit("E") + dist_e * px_per_mm, mmf_to_py(iy))


func _wall_blocks_invaders_for_view(d: String, rival = null) -> bool:
	if match_ref == null:
		return false
	if rival == null:
		var w = match_ref.walls[d]
		return not w.collapsed or w.hp() >= UpConfigRef.HP_PARTIAL
	return not bool(rival.wall_collapsed[d]) or int(rival.wall_hp[d]) >= UpConfigRef.HP_PARTIAL


func snap_melee_structure_visual(inv, p: Vector2) -> Vector2:
	# When a melee group is actually engaged with a structure, every represented
	# soldier is drawn on that structure's contact line. Formation spread remains
	# tangential only, so no member appears to stand several feet away while the
	# group is dealing or receiving melee damage.
	if match_ref == null or inv.def["cat"] != "melee":
		return p

	var margin := 1.0
	if not inv.inside and inv.at_wall:
		var w = match_ref.walls.get(inv.wall)
		if w != null and _wall_blocks_invaders_for_view(inv.wall):
			# Engaged melee stands flush against the visible OUTER castle edge.
			# Do not snap back to the abstract rectangular board boundary.
			if _use_exact_castle_art():
				match inv.wall:
					"N": p.y = _castle_outer_wall_visual_limit("N") - margin
					"S": p.y = _castle_outer_wall_visual_limit("S") + margin
					"W": p.x = _castle_outer_wall_visual_limit("W") - margin
					"E": p.x = _castle_outer_wall_visual_limit("E") + margin
			else:
				var off := float(wall_thick + gap)
				var inner := float(GRID * px_cell)
				var far_edge := off + inner
				match inv.wall:
					"N": p.y = -margin
					"S": p.y = far_edge + float(wall_thick) + margin
					"W": p.x = -margin
					"E": p.x = far_edge + float(wall_thick) + margin
			return p

	if inv.inside and inv.tgt_kind == "b":
		var b = match_ref.find_building(inv.tgt_id)
		if b == null:
			return p
		if match_ref._building_distance_sq(b, inv.x, inv.y) > UpConfigRef.MELEE_STRUCTURE_REACH * UpConfigRef.MELEE_STRUCTURE_REACH:
			return p

		var cp: Vector2i = match_ref._building_contact_point(b, inv.x, inv.y)
		var contact_px := Vector2(mm_to_px(cp.x), mm_to_py(cp.y))
		var center_px := Vector2(mm_to_px(b.cx), mm_to_py(b.cy))
		var inward := center_px - contact_px
		if inward.length_squared() < 0.001:
			return contact_px

		# Pick the dominant edge normal. Preserve only a tiny tangent spread so
		# groups remain readable while still looking physically flush.
		var tangent_offset := 0.0
		if absf(inward.x) >= absf(inward.y):
			tangent_offset = clampf(p.y - contact_px.y, -6.0, 6.0)
			p.x = contact_px.x - signf(inward.x) * margin
			p.y = contact_px.y + tangent_offset
		else:
			tangent_offset = clampf(p.x - contact_px.x, -6.0, 6.0)
			p.y = contact_px.y - signf(inward.y) * margin
			p.x = contact_px.x + tangent_offset
	return p


func clamp_invader_visual_outside_wall(inv, p: Vector2) -> Vector2:
	# Presentation mirror of authoritative collision. The simulation center is
	# already legal; this prevents per-soldier formation offsets from making a
	# rendered member appear across a standing wall/turret or inside a building.
	if match_ref == null:
		return p

	var off := float(wall_thick + gap)
	var inner := float(GRID * px_cell)
	var near_edge := off
	var far_edge := off + inner
	var outer_far := far_edge + float(wall_thick)
	var margin := 1.5
	var n_vis: Rect2 = _wall_rect("N", GRID * px_cell, wall_thick + gap)
	var s_vis: Rect2 = _wall_rect("S", GRID * px_cell, wall_thick + gap)
	var w_vis: Rect2 = _wall_rect("W", GRID * px_cell, wall_thick + gap)
	var e_vis: Rect2 = _wall_rect("E", GRID * px_cell, wall_thick + gap)

	# Hard half-plane barrier for an OUTSIDE invader's assigned wall. The older
	# rectangle-only clamp could fail when a formation offset was large enough to
	# jump completely across the wall band in one draw position. While the assigned
	# wall stands, an outside attacker is always rendered beyond its OUTER face.
	if not inv.inside:
		var assigned = match_ref.walls.get(inv.wall)
		if assigned != null and _wall_blocks_invaders_for_view(inv.wall):
			if _use_exact_castle_art():
				match inv.wall:
					"N": p.y = minf(p.y, _castle_outer_wall_visual_limit("N") - margin)
					"S": p.y = maxf(p.y, _castle_outer_wall_visual_limit("S") + margin)
					"W": p.x = minf(p.x, _castle_outer_wall_visual_limit("W") - margin)
					"E": p.x = maxf(p.x, _castle_outer_wall_visual_limit("E") + margin)
			else:
				match inv.wall:
					"N": p.y = minf(p.y, -margin)
					"S": p.y = maxf(p.y, outer_far + margin)
					"W": p.x = minf(p.x, -margin)
					"E": p.x = maxf(p.x, outer_far + margin)

	# First keep visuals on the correct side of every standing wall. This applies
	# to both outside attackers and invaders already inside the fiefdom.
	for d in UpMatch.DIRS:
		var w = match_ref.walls[d]
		if not _wall_blocks_invaders_for_view(d):
			continue
		match d:
			"N":
				if p.y >= 0.0 and p.y <= near_edge:
					p.y = near_edge + margin if inv.inside else -margin
			"S":
				if p.y >= far_edge and p.y <= outer_far:
					p.y = far_edge - margin if inv.inside else outer_far + margin
			"W":
				if p.x >= 0.0 and p.x <= near_edge:
					p.x = near_edge + margin if inv.inside else -margin
			"E":
				if p.x >= far_edge and p.x <= outer_far:
					p.x = far_edge - margin if inv.inside else outer_far + margin

	# Interior formation offsets must not make soldiers walk through intact
	# buildings. If a visual point lands inside an occupied grid cell, push it to
	# the nearest edge of that cell. The authoritative pathfinder already treats
	# occupied building cells as blocked.
	if inv.inside:
		var local_x := p.x - off
		var local_y := p.y - off
		if local_x >= 0.0 and local_y >= 0.0 and local_x < inner and local_y < inner:
			var cx := clampi(int(floor(local_x / float(px_cell))), 0, GRID - 1)
			var cy := clampi(int(floor(local_y / float(px_cell))), 0, GRID - 1)
			if match_ref.occupancy[cy * GRID + cx] != 0:
				var left := off + cx * px_cell
				var right := left + px_cell
				var top := off + cy * px_cell
				var bottom := top + px_cell
				var center := interpolated_mm_to_px(inv.prev_x, inv.prev_y, inv.x, inv.y)

				# Resolve against the face facing the authoritative group center.
				# This prevents a formation offset from being pushed through the
				# building to its far edge.
				if center.x <= left:
					p.x = left - margin
				elif center.x >= right:
					p.x = right + margin
				elif center.y <= top:
					p.y = top - margin
				elif center.y >= bottom:
					p.y = bottom + margin
				else:
					# Defensive fallback: the simulation center should never be
					# inside an occupied building cell.
					var dl := absf(center.x - left)
					var dr := absf(right - center.x)
					var dt := absf(center.y - top)
					var db := absf(bottom - center.y)
					var smallest := minf(minf(dl, dr), minf(dt, db))
					if smallest == dl: p.x = left - margin
					elif smallest == dr: p.x = right + margin
					elif smallest == dt: p.y = top - margin
					else: p.y = bottom + margin

	# Then keep visuals off any turret that still stands. A destroyed turret is
	# intentionally passable/overdrawable. Corner turrets overlap the wall band,
	# so this second pass catches formation offsets around the corners.
	var inner_i := GRID * px_cell
	var off_i := wall_thick + gap
	for tid in UpMatch.TURRETS:
		var tr = match_ref.turrets[tid]
		if tr.destroyed:
			continue
		var rr := _turret_rect(tid, inner_i, off_i)
		if not rr.has_point(p):
			continue

		if inv.inside:
			# Push toward the interior using the shorter displacement.
			var to_right := rr.end.x + margin - p.x
			var to_bottom := rr.end.y + margin - p.y
			var to_left := p.x - (rr.position.x - margin)
			var to_top := p.y - (rr.position.y - margin)

			match tid:
				"NW":
					if to_right <= to_bottom: p.x = rr.end.x + margin
					else: p.y = rr.end.y + margin
				"NE":
					if to_left <= to_bottom: p.x = rr.position.x - margin
					else: p.y = rr.end.y + margin
				"SW":
					if to_right <= to_top: p.x = rr.end.x + margin
					else: p.y = rr.position.y - margin
				"SE":
					if to_left <= to_top: p.x = rr.position.x - margin
					else: p.y = rr.position.y - margin
		else:
			# Outside attackers stay outside the corner fortification according to
			# the wall they approached from.
			match inv.wall:
				"N": p.y = rr.position.y - margin
				"S": p.y = rr.end.y + margin
				"W": p.x = rr.position.x - margin
				"E": p.x = rr.end.x + margin

	return snap_melee_structure_visual(inv, p)

func _static_world_signature() -> int:
	if match_ref == null:
		return 0
	var h: int = 146959810
	if recon_rival_index >= 0 and recon_rival_index < match_ref.rivals.size():
		var r: UpMatch.Rival = match_ref.rivals[recon_rival_index]
		h = h * 31 + r.buildings.size()
		for rec_value in r.buildings:
			var rec: Dictionary = rec_value
			h = h * 31 + int(rec.get("id", 0))
			h = h * 31 + int(rec.get("hp", 0))
		for d in UpMatch.DIRS:
			h = h * 31 + int(r.wall_hp[d])
			h = h * 31 + (1 if bool(r.wall_collapsed[d]) else 0)
	else:
		h = h * 31 + match_ref.buildings.size()
		for b: UpMatch.Building in match_ref.buildings:
			h = h * 31 + b.id
			h = h * 31 + b.hp
			h = h * 31 + b.flash
		for d in UpMatch.DIRS:
			var w: UpMatch.Wall = match_ref.walls[d]
			h = h * 31 + w.hp()
			h = h * 31 + (1 if w.collapsed else 0)
	return h


func _sync_dynamic_layer() -> void:
	if dynamic_layer == null:
		return
	dynamic_layer.match_ref = match_ref
	dynamic_layer.ghost_def = ghost_def
	dynamic_layer.ghost_rot = ghost_rot
	dynamic_layer.hover_cell = hover_cell
	dynamic_layer.hover_wall = hover_wall
	dynamic_layer.hover_turret = hover_turret
	dynamic_layer.arm_cat = arm_cat
	dynamic_layer.recon_rival_index = recon_rival_index
	dynamic_layer.local_player_id = local_player_id
	dynamic_layer.inset_top = inset_top
	dynamic_layer.inset_bottom = inset_bottom
	dynamic_layer.inset_left = inset_left
	dynamic_layer.inset_right = inset_right
	dynamic_layer.view_zoom = view_zoom
	dynamic_layer.view_pan = view_pan
	dynamic_layer.render_alpha = render_alpha
	if dynamic_layer.adaptive_quality_level != adaptive_quality_level:
		dynamic_layer.adaptive_quality_level = adaptive_quality_level
		dynamic_layer._gpu_crowd_last_usec = 0
	if dynamic_layer.adaptive_detail_stage != adaptive_detail_stage:
		dynamic_layer.adaptive_detail_stage = adaptive_detail_stage
		dynamic_layer._gpu_crowd_last_usec = 0
	dynamic_layer.gain_popups = gain_popups


func _sync_tooltip_layer() -> void:
	if tooltip_layer == null:
		return
	tooltip_layer.match_ref = match_ref
	tooltip_layer.hover_wall = hover_wall
	tooltip_layer.hover_turret = hover_turret
	tooltip_layer.hover_army_id = hover_army_id
	tooltip_layer.hover_army_screen_pos = hover_army_screen_pos
	tooltip_layer.recon_rival_index = recon_rival_index
	tooltip_layer.local_player_id = local_player_id
	tooltip_layer.inset_top = inset_top
	tooltip_layer.inset_bottom = inset_bottom
	tooltip_layer.inset_left = inset_left
	tooltip_layer.inset_right = inset_right
	tooltip_layer.view_zoom = view_zoom
	tooltip_layer.view_pan = view_pan
	tooltip_layer.font_body = font_body
	tooltip_layer.font_disp = font_disp


func _process(_d: float) -> void:
	if render_role != "static":
		return
	_update_adaptive_quality(_d)
	if match_ref == null:
		return
	# Only the moving/effect layer redraws at display cadence. Static world state
	# is sampled once per simulation tick; it redraws only when structures/walls
	# actually changed (or input/camera code explicitly invalidated it).
	if match_ref.tick != _last_static_check_tick:
		_last_static_check_tick = match_ref.tick
		var sig := _static_world_signature()
		if sig != _last_static_signature:
			_last_static_signature = sig
			queue_redraw()
	if _wall_collapse_animation_active():
		queue_redraw()
	_sync_dynamic_layer()
	_sync_tooltip_layer()
	if dynamic_layer != null:
		dynamic_layer.queue_redraw()
	if tooltip_layer != null:
		# A visible tooltip contains live combat data, so include the simulation tick
		# in its signature. This keeps defender counts/HP/status exact as casualties
		# happen without returning to unconditional per-frame redraws.
		var tooltip_tick: int = match_ref.tick if hover_wall != "" or hover_turret != "" or hover_army_id >= 0 else -1
		var tooltip_sig: int = hash([hover_wall, hover_turret, hover_army_id, hover_army_screen_pos, recon_rival_index, view_zoom, view_pan, size, tooltip_tick])
		if tooltip_sig != _last_tooltip_signature:
			_last_tooltip_signature = tooltip_sig
			tooltip_layer.queue_redraw()

func _draw() -> void:
	if match_ref == null:
		return

	if render_role == "tooltip":
		TooltipRenderer.draw(self)
		return

	var o := _view_origin()
	draw_set_transform(o, 0.0, Vector2.ONE * view_zoom)
	if render_role == "static":
		_draw_terrain()
		if _use_exact_castle_art():
			if recon_rival_index >= 0 and recon_rival_index < match_ref.rivals.size():
				_draw_exact_castle_art(match_ref.rivals[recon_rival_index])
			else:
				_draw_exact_castle_art()
		_draw_field()
		if recon_rival_index >= 0:
			# Grid linework sits above castle rubble but below courtyard buildings.
			_draw_courtyard_grid_overlay()
			_draw_rival_buildings()
			if _use_exact_castle_art():
				_draw_castle_damage_and_highlights(match_ref.rivals[recon_rival_index].crest, match_ref.rivals[recon_rival_index])
			else:
				_draw_rival_walls()
		else:
			# Grid linework sits above castle rubble but below courtyard buildings.
			_draw_courtyard_grid_overlay()
			_draw_buildings()
			if _use_exact_castle_art():
				_draw_castle_damage_and_highlights(C_BANNER)
			else:
				_draw_walls()
		draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
		return

	# Dynamic layer. Incoming attackers are drawn first, then any physical wall is
	# repainted as foreground occlusion, then parapet/turret defenders are drawn on
	# top. This prevents an attacker sprite from ever appearing to stand on an intact
	# or half-rebuilt wall while preserving visible defenders above the stone.
	if recon_rival_index >= 0:
		if _viewing_local_fiefdom():
			_draw_ghost()
		_draw_rival_battle()
		# Recon battles need the same wall occlusion even when viewing an AI-owned
		# fiefdom; otherwise attackers can visually sit on top of its wall art.
		_draw_standing_wall_foreground(match_ref.rivals[recon_rival_index])
		if _viewing_local_fiefdom():
			_draw_rival_wall_crowd()
			_draw_rival_turret_crowd()
			_draw_horizontal_parapet_foreground()
			_draw_gain_popups()
	else:
		_draw_ghost()
		_draw_units()
		_draw_standing_wall_foreground()
		_draw_wall_crowd()
		_draw_turret_crowd()
		_draw_horizontal_parapet_foreground()
		_draw_arrows()
		_draw_gain_popups()

	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


func _draw_horizontal_parapet_foreground() -> void:
	if not _use_exact_castle_art():
		return
	# The castle itself is already underneath the defenders.  Redraw ONLY the
	# raised stone merlons on the near/front parapet after the soldiers.  The old
	# implementation redrew an entire horizontal strip and hid too much of each
	# defender's body.  These small source rectangles keep only the actual stones
	# in front while the open gaps remain unobstructed.
	var north_merlons := [
		Rect2(306.0, 224.0, 31.0, 31.0), Rect2(366.0, 224.0, 31.0, 31.0),
		Rect2(426.0, 224.0, 31.0, 31.0), Rect2(486.0, 224.0, 31.0, 31.0),
		Rect2(546.0, 224.0, 31.0, 31.0), Rect2(606.0, 224.0, 31.0, 31.0),
		Rect2(666.0, 224.0, 31.0, 31.0), Rect2(726.0, 224.0, 31.0, 31.0),
		Rect2(786.0, 224.0, 31.0, 31.0)
	]
	var south_merlons := [
		Rect2(286.0, 1039.0, 34.0, 34.0), Rect2(350.0, 1039.0, 34.0, 34.0),
		Rect2(414.0, 1039.0, 34.0, 34.0), Rect2(478.0, 1039.0, 34.0, 34.0),
		Rect2(542.0, 1039.0, 34.0, 34.0), Rect2(606.0, 1039.0, 34.0, 34.0),
		Rect2(670.0, 1039.0, 34.0, 34.0), Rect2(734.0, 1039.0, 34.0, 34.0),
		Rect2(798.0, 1039.0, 34.0, 34.0), Rect2(838.0, 1039.0, 28.0, 34.0)
	]
	if not _wall_uses_damage_state("N"):
		for src in north_merlons:
			draw_texture_rect_region(FIEFDOM_CASTLE_ART, _castle_rect_from_src(src), src)
	if not _wall_uses_damage_state("S"):
		for src in south_merlons:
			draw_texture_rect_region(FIEFDOM_CASTLE_ART, _castle_rect_from_src(src), src)


func _viewing_local_fiefdom() -> bool:
	if local_player_id == 0:
		return recon_rival_index < 0
	return recon_rival_index == local_player_id - 1


func _draw_terrain() -> void:
	# Single continuous exterior landscape. The exact castle art is drawn on top,
	# so only the terrain outside the walls is changed.
	draw_texture_rect(FIEFDOM_LANDSCAPE_ART, _landscape_dest_rect(), false)


func _landscape_dest_rect() -> Rect2:
	# One single 6000x5360 landscape image. The castle is horizontally centered
	# and sits slightly above vertical center, matching the supplied composition.
	# The castle occupies about 21% of the landscape height in the reference.
	var visible_castle: Rect2 = _castle_rect_from_src(FIEFDOM_CASTLE_ART_VISIBLE_SRC)
	var castle_center: Vector2 = visible_castle.get_center()
	var castle_fraction_of_landscape_height: float = 0.21
	var world_h: float = visible_castle.size.y / castle_fraction_of_landscape_height
	var world_w: float = world_h * (6000.0 / 5360.0)
	# Reference composition: centered left/right; castle center about 46.5% down.
	var castle_world_anchor: Vector2 = Vector2(0.5, 0.465)
	return Rect2(
		castle_center - Vector2(world_w * castle_world_anchor.x, world_h * castle_world_anchor.y),
		Vector2(world_w, world_h))


func _minimum_view_zoom() -> float:
	# Never allow zooming out far enough to expose the Control background. The
	# landscape must cover the full playable viewport on both axes.
	var wr: Rect2 = _world_rect()
	var free_w: float = maxf(1.0, size.x - inset_left - inset_right)
	var free_h: float = maxf(1.0, size.y - inset_top - inset_bottom)
	var cover_zoom_x: float = free_w / maxf(1.0, wr.size.x)
	var cover_zoom_y: float = free_h / maxf(1.0, wr.size.y)
	return maxf(VIEW_ZOOM_MIN, maxf(cover_zoom_x, cover_zoom_y))


func _use_exact_castle_art() -> bool:
	return true


func _castle_art_dest_rect() -> Rect2:
	var inner: int = GRID * px_cell
	var off: int = wall_thick + gap
	var sx: float = float(inner) / FIEFDOM_CASTLE_ART_FIELD_SRC.size.x
	var sy: float = float(inner) / FIEFDOM_CASTLE_ART_FIELD_SRC.size.y
	return Rect2(
		float(off) - FIEFDOM_CASTLE_ART_FIELD_SRC.position.x * sx,
		float(off) - FIEFDOM_CASTLE_ART_FIELD_SRC.position.y * sy,
		float(FIEFDOM_CASTLE_ART.get_width()) * sx,
		float(FIEFDOM_CASTLE_ART.get_height()) * sy)


func _wall_uses_damage_state(d: String) -> bool:
	# The modular renderer supplies rubble/half-built/collapse art for these states.
	# Front parapet merlons from the intact reference must not be redrawn over them.
	if match_ref == null:
		return false
	if recon_rival_index >= 0 and recon_rival_index < match_ref.rivals.size():
		var rv: UpMatch.Rival = match_ref.rivals[recon_rival_index]
		return _rival_wall_visual_state(rv, d) in ["rubble", "half_rebuilt", "collapsing"]
	var w = match_ref.walls[d]
	return match_ref.wall_state(w) in ["rubble", "half_rebuilt", "collapsing"]


func _turret_destroyed_for_view(tid: String) -> bool:
	if match_ref == null:
		return false
	var adj: Array = UpMatch.TURRET_WALLS[tid]
	if recon_rival_index >= 0 and recon_rival_index < match_ref.rivals.size():
		var rv: UpMatch.Rival = match_ref.rivals[recon_rival_index]
		var a_down: bool = bool(rv.wall_collapsed[adj[0]]) and int(rv.wall_hp[adj[0]]) <= 0
		var b_down: bool = bool(rv.wall_collapsed[adj[1]]) and int(rv.wall_hp[adj[1]]) <= 0
		return a_down and b_down
	var aw = match_ref.walls[adj[0]]
	var bw = match_ref.walls[adj[1]]
	return aw.collapsed and aw.hp() <= 0 and bw.collapsed and bw.hp() <= 0


func _draw_exact_castle_art(rival = null) -> void:
	CastleRenderer.draw(self, rival)


func _draw_standing_wall_foreground(rival = null) -> void:
	# Physical wall stone belongs above incoming attackers. A half-rebuilt wall
	# becomes blocking again at HP_PARTIAL; rubble/collapse remains below troops so
	# the breach reads as open. Wall/turret garrisons are drawn after this pass.
	if _use_exact_castle_art():
		CastleRenderer.draw_wall_foreground(self, rival)
		return
	var inner: int = GRID * px_cell
	var off: int = wall_thick + gap
	for d in UpMatch.DIRS:
		if not _wall_blocks_invaders_for_view(d, rival):
			continue
		var rect: Rect2 = _wall_rect(d, inner, off)
		var wall_col: Color = C_STONE
		var banner_col: Color = C_BANNER
		if rival != null:
			var hp_frac: float = clampf(float(int(rival.wall_hp[d])) / float(UpConfigRef.HP_FULL), 0.0, 1.0)
			wall_col = C_DOWN.lerp(C_STONE, hp_frac)
			banner_col = rival.crest
		_draw_wall_25d(d, rect, wall_col, false, banner_col, false)


func _draw_gate_banners_overlay(banner_col: Color, device: int = 0) -> void:
	var inner: int = GRID * px_cell
	var off: int = wall_thick + gap
	var rect := _wall_rect("S", inner, off)
	var gate_w: float = clampf(rect.size.x * 0.17, 50.0, 78.0)
	var gate_h: float = clampf(rect.size.y * 0.56, 34.0, 48.0)
	var face_bottom: float = rect.end.y - 2.0
	var gate_y: float = face_bottom - gate_h
	var banner_dx: float = gate_w * 0.95
	var banner_y: float = gate_y + 6.0
	_draw_gate_banner(Vector2(rect.get_center().x - banner_dx, banner_y), 13.0, 29.0, banner_col, device)
	_draw_gate_banner(Vector2(rect.get_center().x + banner_dx, banner_y), 13.0, 29.0, banner_col, device)


func _wall_collapse_animation_active() -> bool:
	if match_ref == null:
		return false
	if recon_rival_index >= 0 and recon_rival_index < match_ref.rivals.size():
		var rv = match_ref.rivals[recon_rival_index]
		for d in UpMatch.DIRS:
			if bool(rv.wall_collapsed[d]):
				var ct: int = int(rv.wall_collapse_tick.get(d, -1))
				if ct >= 0 and match_ref.tick - ct < UpConfigRef.WALL_COLLAPSE_ANIM_TICKS:
					return true
		return false
	for d in UpMatch.DIRS:
		var w = match_ref.walls[d]
		if w.collapsed and w.collapse_tick >= 0 and match_ref.tick - w.collapse_tick < UpConfigRef.WALL_COLLAPSE_ANIM_TICKS:
			return true
	return false


func _rival_wall_visual_state(rival, d: String) -> String:
	if not bool(rival.wall_collapsed[d]):
		return "intact"
	var ct: int = int(rival.wall_collapse_tick.get(d, -1))
	if ct >= 0 and match_ref.tick - ct < UpConfigRef.WALL_COLLAPSE_ANIM_TICKS:
		return "collapsing"
	if int(rival.wall_hp[d]) >= UpConfigRef.HP_PARTIAL:
		return "half_rebuilt"
	return "rubble"


func _draw_wall_collapse_dust(d: String, progress: float) -> void:
	if progress <= 0.0 or progress >= 1.0:
		return
	var r: Rect2 = _castle_wall_hit_rect(d)
	var center: Vector2 = r.get_center()
	var spread: Vector2 = r.size * Vector2(0.56, 0.42)
	var fade: float = sin(progress * PI) * 0.42
	for i in 12:
		var seed: float = float(i + UpMatch.DIRS.find(d) * 17)
		var ox: float = sin(seed * 12.9898) * spread.x * 0.45
		var oy: float = cos(seed * 7.233) * spread.y * 0.45 - progress * 16.0
		var radius: float = 6.0 + float(i % 4) * 2.5 + progress * 4.0
		draw_circle(center + Vector2(ox, oy), radius, Color(0.66, 0.57, 0.43, fade))


func _draw_wall_state_overlay(d: String, state: String, collapse_tick: int = -1) -> void:
	# Modular wall textures provide all persistent damage states; this pass draws
	# only the transient dust used during the intact-to-rubble collapse dissolve.
	if state != "collapsing":
		return
	var alpha: float = 1.0
	if collapse_tick >= 0:
		alpha = clampf(float(match_ref.tick - collapse_tick + 1) / float(UpConfigRef.WALL_COLLAPSE_ANIM_TICKS), 0.0, 1.0)
	_draw_wall_collapse_dust(d, alpha)


func _draw_castle_damage_and_highlights(banner_col: Color, rival = null) -> void:
	var inner: int = GRID * px_cell
	var off: int = wall_thick + gap
	for d in UpMatch.DIRS:
		var visual_state: String = "intact"
		var collapse_tick: int = -1
		if rival == null:
			var w = match_ref.walls[d]
			visual_state = match_ref.wall_state(w)
			collapse_tick = w.collapse_tick
		else:
			visual_state = _rival_wall_visual_state(rival, d)
			collapse_tick = int(rival.wall_collapse_tick.get(d, -1))
		_draw_wall_state_overlay(d, visual_state, collapse_tick)
	for tid in UpMatch.TURRETS:
		var tr_rect: Rect2 = _turret_rect(tid, inner, off)
		var destroyed: bool = false
		var highlight_t: bool = false
		if rival == null:
			destroyed = _turret_destroyed_for_view(tid)
		else:
			var twalls: Array = UpMatch.TURRET_WALLS[tid]
			var a_down: bool = bool(rival.wall_collapsed[twalls[0]]) and int(rival.wall_hp[twalls[0]]) <= 0
			var b_down: bool = bool(rival.wall_collapsed[twalls[1]]) and int(rival.wall_hp[twalls[1]]) <= 0
			destroyed = a_down and b_down
		if destroyed:
			if not _use_exact_castle_art():
				_draw_round_turret_25d(tid, tr_rect, C_TURRET, true, banner_col, highlight_t)
		elif highlight_t:
			var c: Vector2 = tr_rect.get_center()
			var rad: float = minf(tr_rect.size.x, tr_rect.size.y) * 0.5 + 1.0
			draw_arc(c, rad, 0.0, TAU, 42, C_GOLD, 2.5)
	# The reference castle contains a generic baked gate banner. Draw the active
	# faction's crest color + heraldic device over it for both home and recon views.
	var banner_device: int = int(rival.device) if rival != null else 0
	_draw_gate_banners_overlay(banner_col, banner_device)


func _draw_field() -> void:
	var inner: int = GRID * px_cell
	var off: int = wall_thick + gap
	if not _use_exact_castle_art():
		draw_rect(Rect2(off, off, inner, inner), C_FIELD)
		for i in range(1, GRID):
			draw_line(Vector2(off + i * px_cell, off), Vector2(off + i * px_cell, off + inner),
				Color(1, 1, 1, 0.08), 1.0)
			draw_line(Vector2(off, off + i * px_cell), Vector2(off + inner, off + i * px_cell),
				Color(1, 1, 1, 0.08), 1.0)
	if hover_cell.x >= 0 and ghost_def.is_empty():
		var hover_poly: PackedVector2Array = cell_polygon(hover_cell.x, hover_cell.y)
		draw_colored_polygon(hover_poly, Color(1, 1, 1, 0.10))


func _draw_buildings() -> void:
	BuildingRenderer.draw(self)


func _draw_courtyard_grid_overlay() -> void:
	# The 12x12 courtyard grid is a gameplay guide, not part of the building art.
	# Redraw its linework after castle/rubble but before courtyard buildings.
	# Therefore rubble is underneath the grid, while buildings, soldiers/ghosts,
	# and the dedicated tooltip layer remain above the grid.
	if not _use_exact_castle_art():
		return
	var grid_col := Color(0.20, 0.23, 0.13, 0.62)
	var grid_hi := Color(0.93, 0.79, 0.36, 0.16)
	for y in range(GRID):
		for x in range(GRID):
			var poly: PackedVector2Array = cell_polygon(x, y)
			var outline := PackedVector2Array([poly[0], poly[1], poly[2], poly[3], poly[0]])
			draw_polyline(outline, grid_col, 1.15, true)
	# A very subtle highlight keeps the grid legible over the darkest building tiles.
	for i in range(1, GRID):
		var left_p: Vector2 = cell_polygon(0, i)[0]
		var right_p: Vector2 = cell_polygon(GRID - 1, i)[1]
		draw_line(left_p, right_p, grid_hi, 0.55, true)


func _building_health_color(frac: float) -> Color:
	return BuildingRenderer.health_color(frac)

func _draw_ghost() -> void:
	if ghost_def.is_empty() or hover_cell.x < 0: return
	var cells := UpMatch.rotate_cells(ghost_def["cells"], ghost_rot)
	var ok := match_ref.player_can_build(local_player_id, ghost_def)
	var col := Color(ghost_def["colour"])
	col.a = 0.55
	for c in cells:
		var x: int = c.x + hover_cell.x
		var y: int = c.y + hover_cell.y
		if x < 0 or y < 0 or x >= GRID or y >= GRID: continue
		var ghost_poly: PackedVector2Array = cell_polygon(x, y)
		draw_colored_polygon(ghost_poly, col)
		var outline: PackedVector2Array = PackedVector2Array([ghost_poly[0], ghost_poly[1], ghost_poly[2], ghost_poly[3], ghost_poly[0]])
		draw_polyline(outline, C_GOLD if ok else Color("d4392f"), 2.0)


func _castle_stone(base: Color, factor: float) -> Color:
	return Color(clampf(base.r * factor, 0.0, 1.0), clampf(base.g * factor, 0.0, 1.0), clampf(base.b * factor, 0.0, 1.0), base.a)


func _draw_masonry(rect: Rect2, base: Color, horizontal_courses: int = 4) -> void:
	if rect.size.x <= 1.0 or rect.size.y <= 1.0:
		return
	var mortar := _castle_stone(base, 0.72)
	var course_h := rect.size.y / float(maxi(1, horizontal_courses))
	for row in horizontal_courses + 1:
		var yy := rect.position.y + float(row) * course_h
		draw_line(Vector2(rect.position.x, yy), Vector2(rect.end.x, yy), mortar, 0.8)
	for row in horizontal_courses:
		var yy0 := rect.position.y + float(row) * course_h
		var yy1 := minf(rect.end.y, yy0 + course_h)
		var brick_w := maxf(12.0, course_h * 1.75)
		var offset := brick_w * 0.5 if (row & 1) == 1 else 0.0
		var x := rect.position.x - offset
		while x < rect.end.x:
			if x > rect.position.x:
				draw_line(Vector2(x, yy0), Vector2(x, yy1), mortar, 0.65)
			x += brick_w


func _draw_castle_banner(anchor: Vector2, width: float, height: float, col: Color, device: int = 0) -> void:
	var x0 := anchor.x - width * 0.5
	var top := anchor.y
	var pts := PackedVector2Array([
		Vector2(x0, top), Vector2(x0 + width, top),
		Vector2(x0 + width, top + height * 0.78),
		Vector2(anchor.x, top + height),
		Vector2(x0, top + height * 0.78)
	])
	draw_colored_polygon(pts, col.darkened(0.08))
	draw_polyline(PackedVector2Array([pts[0], pts[1], pts[2], pts[3], pts[4], pts[0]]), C_GOLD.darkened(0.08), 1.1)
	var emblem := C_GOLD.lightened(0.10)
	var ec := anchor + Vector2(0, height * 0.43)
	# Each faction gets a distinct heraldic device in addition to its crest color.
	# 0 = spear/fleur, 1 = cross, 2 = chevron, 3 = ring; higher ids repeat.
	match posmod(device, 4):
		0:
			draw_circle(ec, maxf(1.4, width * 0.10), emblem)
			draw_line(ec + Vector2(0, -height * 0.19), ec + Vector2(0, height * 0.19), emblem, 1.0)
			draw_line(ec + Vector2(-width * 0.16, -height * 0.08), ec, emblem, 1.0)
			draw_line(ec + Vector2(width * 0.16, -height * 0.08), ec, emblem, 1.0)
		1:
			draw_line(ec + Vector2(0, -height * 0.18), ec + Vector2(0, height * 0.18), emblem, 1.5)
			draw_line(ec + Vector2(-width * 0.20, -height * 0.02), ec + Vector2(width * 0.20, -height * 0.02), emblem, 1.5)
		2:
			draw_polyline(PackedVector2Array([ec + Vector2(-width * 0.22, -height * 0.10), ec + Vector2(0, height * 0.14), ec + Vector2(width * 0.22, -height * 0.10)]), emblem, 1.6)
		_:
			draw_arc(ec, maxf(2.0, width * 0.18), 0.0, TAU, 18, emblem, 1.5)


func _draw_gate_banner(anchor: Vector2, width: float, height: float, col: Color, device: int = 0) -> void:
	# Slightly larger heraldic banner for the gatehouse, matching the player's
	# faction crest colour so each kingdom reads clearly at the entrance.
	var pole_y := anchor.y - height * 0.06
	draw_line(Vector2(anchor.x - width * 0.62, pole_y), Vector2(anchor.x + width * 0.62, pole_y), C_GOLD.darkened(0.18), 2.0)
	draw_circle(Vector2(anchor.x - width * 0.62, pole_y), 1.8, C_GOLD)
	draw_circle(Vector2(anchor.x + width * 0.62, pole_y), 1.8, C_GOLD)
	_draw_castle_banner(anchor + Vector2(0, height * 0.04), width, height, col, device)


func _draw_front_gate_25d(rect: Rect2, wall_col: Color, banner_col: Color) -> void:
	# Gatehouse visuals inspired by the approved concept: central arched wooden
	# gate, flanking faction banners, and torches. Purely visual; no hitbox logic.
	var gate_w: float = clampf(rect.size.x * 0.17, 50.0, 78.0)
	var gate_h: float = clampf(rect.size.y * 0.56, 34.0, 48.0)
	var face_bottom: float = rect.end.y - 2.0
	var gate_x := rect.get_center().x - gate_w * 0.5
	var gate_y: float = face_bottom - gate_h
	var arch_r := gate_w * 0.5 + 8.0
	var surround := Rect2(gate_x - 10.0, gate_y - 4.0, gate_w + 20.0, gate_h + 4.0)
	# Opening shadow inside the arch.
	draw_rect(Rect2(gate_x + 3.0, gate_y + gate_w * 0.24, gate_w - 6.0, gate_h - gate_w * 0.24), Color(0.07, 0.05, 0.03, 0.78))
	# Stone jambs.
	draw_rect(Rect2(gate_x - 8.0, gate_y + 7.0, 7.0, gate_h - 7.0), _castle_stone(wall_col, 0.80))
	draw_rect(Rect2(gate_x + gate_w + 1.0, gate_y + 7.0, 7.0, gate_h - 7.0), _castle_stone(wall_col, 0.80))
	# Arch voussoirs.
	var arch_center := Vector2(rect.get_center().x, gate_y + arch_r)
	for i in 14:
		var a0 := PI + (PI * float(i) / 14.0)
		var a1 := PI + (PI * float(i + 1) / 14.0)
		var p0 := arch_center + Vector2(cos(a0), sin(a0)) * arch_r
		var p1 := arch_center + Vector2(cos(a1), sin(a1)) * arch_r
		var q0 := arch_center + Vector2(cos(a0), sin(a0)) * (arch_r - 7.0)
		var q1 := arch_center + Vector2(cos(a1), sin(a1)) * (arch_r - 7.0)
		draw_colored_polygon(PackedVector2Array([p0, p1, q1, q0]), _castle_stone(wall_col, 0.98 if (i & 1) == 0 else 0.88))
	# Wooden double doors.
	var door := Rect2(gate_x, gate_y + gate_w * 0.24, gate_w, gate_h - gate_w * 0.24)
	draw_rect(door, Color("6e4321"))
	draw_rect(Rect2(door.position.x + 1.5, door.position.y + 1.5, door.size.x * 0.5 - 3.0, door.size.y - 3.0), Color("7e4f28"))
	draw_rect(Rect2(door.position.x + door.size.x * 0.5 + 1.5, door.position.y + 1.5, door.size.x * 0.5 - 3.0, door.size.y - 3.0), Color("7e4f28"))
	# Planks.
	for i in 4:
		var yy := door.position.y + 5.0 + float(i) * (door.size.y - 10.0) / 4.0
		draw_line(Vector2(door.position.x + 2.0, yy), Vector2(door.end.x - 2.0, yy), Color("5d3518"), 1.0)
	# Seam, straps, handles.
	draw_line(Vector2(door.get_center().x, door.position.y + 2.0), Vector2(door.get_center().x, door.end.y - 2.0), Color("3a220f"), 1.2)
	for yi in [door.position.y + door.size.y * 0.28, door.position.y + door.size.y * 0.65]:
		draw_line(Vector2(door.position.x + 4.0, yi), Vector2(door.end.x - 4.0, yi), Color("2f2d2a"), 1.8)
	draw_circle(Vector2(door.get_center().x - 6.0, door.position.y + door.size.y * 0.58), 1.4, C_STONE)
	draw_circle(Vector2(door.get_center().x + 6.0, door.position.y + door.size.y * 0.58), 1.4, C_STONE)
	# Flanking faction banners by the door.
	var banner_dx: float = gate_w * 0.95
	var banner_y: float = gate_y + 6.0
	_draw_gate_banner(Vector2(rect.get_center().x - banner_dx, banner_y), 13.0, 29.0, banner_col)
	_draw_gate_banner(Vector2(rect.get_center().x + banner_dx, banner_y), 13.0, 29.0, banner_col)
	# Torch sconces.
	for tx in [rect.get_center().x - banner_dx * 0.54, rect.get_center().x + banner_dx * 0.54]:
		var s := Vector2(tx, door.position.y + 6.0)
		draw_line(s, s + Vector2(0, 7.0), C_GOLD.darkened(0.36), 1.4)
		draw_circle(s + Vector2(0, 8.5), 2.1, Color(1.0, 0.72, 0.26, 0.88))
		draw_circle(s + Vector2(0, 6.4), 1.2, Color(1.0, 0.95, 0.62, 0.92))


func _draw_wall_25d(d: String, rect: Rect2, wall_col: Color, breached: bool, banner_col: Color, highlighted: bool) -> void:
	var horiz := d == "N" or d == "S"
	var depth := maxf(12.0, float(wall_thick) * 0.26)
	var lip := maxf(5.0, float(wall_thick) * 0.08)
	var vis_rect := rect
	# Give the east and west walls a touch more courtyard breathing room by
	# pushing the rendered wall mass outward while keeping gameplay hitboxes and
	# pathing on the original rect.
	if not horiz:
		if d == "W":
			vis_rect.position.x -= 8.0
			vis_rect.size.x += 8.0
		else:
			vis_rect.position.x += 8.0
			vis_rect.size.x += 8.0
	var face := vis_rect
	var topwalk := vis_rect
	if horiz:
		# Keep the historical head-on orientation: horizontal walls remain perfectly
		# horizontal. The top parapet is a shallow band and the vertical stone face
		# gives the wall its 2.5D height without changing gameplay coordinates.
		if d == "N":
			topwalk.size.y = depth
			face.position.y += depth - lip
			face.size.y -= depth - lip
		else:
			topwalk.position.y = vis_rect.end.y - depth
			topwalk.size.y = depth
			face.size.y -= depth - lip
	else:
		if d == "W":
			topwalk.size.x = depth
			face.position.x += depth - lip
			face.size.x -= depth - lip
		else:
			topwalk.position.x = vis_rect.end.x - depth
			topwalk.size.x = depth
			face.size.x -= depth - lip

	if breached:
		draw_rect(rect, wall_col.darkened(0.18))
		var run := rect.size.x if horiz else rect.size.y
		var rubble_n := maxi(4, int(run / 18.0))
		for i in rubble_n:
			var t := (float(i) + 0.5) / float(rubble_n)
			var p := rect.position + (Vector2(run * t, rect.size.y * 0.56) if horiz else Vector2(rect.size.x * 0.56, run * t))
			draw_circle(p, 4.0 + float(i % 3), wall_col.darkened(0.30))
		draw_rect(rect, C_STONE_SH.darkened(0.25), false, 2.0)
		return

	# Vertical wall face with block masonry. The approved concept keeps the
	# courtyard bright and clean, so the side-wall faces use a lighter treatment.
	var face_col := _castle_stone(wall_col, 0.90 if horiz else 0.98)
	draw_rect(face, face_col)
	_draw_masonry(face, face_col, 4)
	if horiz:
		var base_band := face
		base_band.position.y = face.end.y - minf(10.0, face.size.y * 0.22)
		base_band.size.y = minf(10.0, face.size.y * 0.22)
		draw_rect(base_band, _castle_stone(banner_col, 0.62))

	# Walkable top surface.
	var top_col := _castle_stone(wall_col, 1.08)
	draw_rect(topwalk, top_col)
	_draw_masonry(topwalk, top_col, 2)

	# Stone lip/corbel seam creates the 2.5D break between top and face.
	if horiz:
		var sy := face.position.y if d == "N" else face.end.y
		draw_line(Vector2(vis_rect.position.x, sy), Vector2(vis_rect.end.x, sy), _castle_stone(wall_col, 0.62), 3.0)
	else:
		var sx := face.position.x if d == "W" else face.end.x
		draw_line(Vector2(sx, vis_rect.position.y), Vector2(sx, vis_rect.end.y), _castle_stone(wall_col, 0.82), 2.0)

	# Crenellations: chunky square merlons like the concept reference.
	var run2 := vis_rect.size.x if horiz else vis_rect.size.y
	var merlon := maxf(8.0, float(wall_thick) * 0.16)
	var step := merlon * 1.75
	var count := maxi(2, int(run2 / step))
	for i in count:
		var along := (float(i) + 0.35) / float(count) * run2
		var mr := Rect2()
		if horiz:
			var y := vis_rect.position.y + 2.0 if d == "N" else vis_rect.end.y - merlon - 2.0
			mr = Rect2(vis_rect.position.x + along - merlon * 0.5, y, merlon, merlon * 0.78)
		else:
			var x := vis_rect.position.x + 2.0 if d == "W" else vis_rect.end.x - merlon - 2.0
			mr = Rect2(x, vis_rect.position.y + along - merlon * 0.5, merlon * 0.78, merlon)
		draw_rect(mr, _castle_stone(wall_col, 1.06))
		draw_rect(mr, _castle_stone(wall_col, 0.66), false, 1.0)

	# Keep light pilaster detail on the north/south faces only. Remove the old
	# interior support pylons from the east/west walls to match the approved art.
	if horiz:
		var buttress_n := maxi(2, int(run2 / 130.0))
		for i in buttress_n + 1:
			var t := float(i) / float(maxi(1, buttress_n))
			var x := lerpf(vis_rect.position.x + 5.0, vis_rect.end.x - 5.0, t)
			var br := Rect2(x - 3.0, face.position.y + 2.0, 6.0, maxf(8.0, face.size.y - 4.0))
			draw_rect(br, _castle_stone(wall_col, 0.80))

	if run2 > 180.0:
		if horiz:
			var by := face.position.y + face.size.y * 0.16
			if d == "S":
				# Keep the south wall cleaner because the entrance uses the faction banners.
				pass
			else:
				_draw_castle_banner(Vector2(vis_rect.position.x + run2 * 0.33, by), 12.0, 22.0, banner_col)
				_draw_castle_banner(Vector2(vis_rect.position.x + run2 * 0.67, by), 12.0, 22.0, banner_col)
		else:
			# Rotate-free vertical walls retain the game's existing straight-on angle;
			# a compact shield-like banner reads better than a sideways hanging flag.
			var center := vis_rect.position + vis_rect.size * 0.5
			draw_circle(center, 7.0, banner_col.darkened(0.08))
			draw_circle(center, 7.0, C_GOLD.darkened(0.10), false, 1.0)

	if d == "S" and not breached:
		_draw_front_gate_25d(face, wall_col, banner_col)

	draw_rect(rect, C_STONE_SH.darkened(0.10), false, 2.0)
	if highlighted:
		draw_rect(rect, C_GOLD, false, 2.5)


func _ellipse_points(center: Vector2, rx: float, ry: float, segments: int = 24) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for i in segments:
		var a := TAU * float(i) / float(segments)
		pts.append(center + Vector2(cos(a) * rx, sin(a) * ry))
	return pts


func _draw_round_turret_25d(tid: String, rect: Rect2, col: Color, destroyed: bool, banner_col: Color, highlighted: bool) -> void:
	var center := rect.get_center()
	var radius := minf(rect.size.x, rect.size.y) * 0.5
	if destroyed:
		draw_circle(center, radius, C_DOWN)
		for i in 10:
			var ang := TAU * float(i) / 10.0
			var p := center + Vector2(cos(ang), sin(ang)) * radius * 0.70
			draw_circle(p, radius * 0.12, C_DOWN.darkened(0.18))
		draw_arc(center, radius, 0.0, TAU, 40, Color("7d3a33"), 2.0)
		return

	# Cylindrical body and lower shadow ring.
	draw_circle(center + Vector2(0, radius * 0.10), radius, _castle_stone(col, 0.76))
	draw_circle(center, radius * 0.94, _castle_stone(col, 0.92))
	# Open walkable top: no pointy roof. The inner platform remains clear so
	# garrison characters can occupy the tower visually later.
	var top_r := radius * 0.76
	draw_circle(center - Vector2(0, radius * 0.12), top_r, _castle_stone(col, 1.08))
	draw_arc(center - Vector2(0, radius * 0.12), top_r, 0.0, TAU, 40, _castle_stone(col, 0.58), 2.2)

	# Ring of crenellations around the open top.
	var merlons := 12
	for i in merlons:
		var ang := TAU * float(i) / float(merlons)
		var mp := center - Vector2(0, radius * 0.12) + Vector2(cos(ang), sin(ang)) * top_r
		draw_circle(mp, radius * 0.105, _castle_stone(col, 1.05))
		draw_circle(mp, radius * 0.105, _castle_stone(col, 0.62), false, 1.0)

	# Stone courses on the cylindrical face and small arrow slits.
	for ring in 3:
		var rr := radius * (0.90 - float(ring) * 0.16)
		draw_arc(center + Vector2(0, radius * 0.10), rr, 0.10, PI - 0.10, 24, _castle_stone(col, 0.66), 0.8)
	for i in 3:
		var ang := PI * (0.22 + float(i) * 0.28)
		var sp := center + Vector2(cos(ang), sin(ang)) * radius * 0.58 + Vector2(0, radius * 0.12)
		draw_line(sp + Vector2(0, -3.0), sp + Vector2(0, 3.0), _castle_stone(col, 0.36), 1.4)

	# Blue/crest-colour band and hanging banner on the tower face.
	draw_arc(center + Vector2(0, radius * 0.10), radius * 0.88, 0.06, PI - 0.06, 30, _castle_stone(banner_col, 0.58), 5.0)
	_draw_castle_banner(center + Vector2(0, radius * 0.18), radius * 0.30, radius * 0.46, banner_col)
	draw_arc(center, radius, 0.0, TAU, 42, C_STONE_SH.darkened(0.10), 2.2)
	if highlighted:
		draw_arc(center, radius + 1.0, 0.0, TAU, 42, C_GOLD, 2.5)


func _draw_walls() -> void:
	var m := match_ref
	var inner: int = GRID * px_cell
	var off: int = wall_thick + gap
	for d in UpMatch.DIRS:
		var w = m.walls[d]
		var st: String = m.wall_state(w)
		var r := _wall_rect(d, inner, off)
		var hp_frac: float = clampf(float(w.hp()) / float(UpConfigRef.HP_FULL), 0.0, 1.0)
		var wall_col: Color = C_DOWN.lerp(C_STONE, hp_frac)
		_draw_wall_25d(d, r, wall_col, st == "breach" or st == "rubble" or st == "collapsing" or st == "half_rebuilt", C_BANNER, false)
	for tid in UpMatch.TURRETS:
		var tr = m.turrets[tid]
		_draw_round_turret_25d(tid, _turret_rect(tid, inner, off), C_STONE.lightened(0.04), tr.destroyed, C_BANNER, false)


func _draw_units() -> void:
	ArmyRenderer.draw(self)

func _draw_arrows() -> void:
	EffectsRenderer.draw_arrows(self)
	EffectsRenderer.draw_melee_impacts(self)
	EffectsRenderer.draw_death_floats(self)

func show_gain_popup(building_id: int, text: String) -> void:
	if match_ref == null:
		return

	# Resolve the clicked building in the local player's fiefdom. Player 0 uses
	# Building objects; network players 1..3 use rival building records.
	var popup_x: int = 0
	var popup_y: int = 0
	var found: bool = false
	if local_player_id == 0:
		var b = match_ref.find_building(building_id)
		if b != null:
			popup_x = b.cx
			popup_y = b.cy
			found = true
	elif local_player_id - 1 >= 0 and local_player_id - 1 < match_ref.rivals.size():
		var rv: UpMatch.Rival = match_ref.rivals[local_player_id - 1]
		for rec in rv.buildings:
			if int(rec.get("rid", -1)) != building_id:
				continue
			var cells: Array = rec.get("cells", [])
			if cells.is_empty():
				break
			var sx: int = 0
			var sy: int = 0
			for c: Vector2i in cells:
				sx += c.x * CELL + CELL / 2
				sy += c.y * CELL + CELL / 2
			popup_x = sx / cells.size()
			popup_y = sy / cells.size()
			found = true
			break
	if not found:
		return

	_popup_serial += 1
	var now := Time.get_ticks_msec()

	# Cookie-Clicker-style click feedback: a quick floating gain number near the
	# clicked building instead of a framed notification bubble. A deterministic
	# horizontal offset keeps rapid clicks from drawing directly on top of one another.
	var jitter_seed := absi(_popup_serial * 1103515245 + building_id * 12345)
	var jitter_x := float((jitter_seed % 41) - 20)
	var jitter_y := float(((jitter_seed / 41) % 9) - 4)

	gain_popups.append({
		"x": popup_x,
		"y": popup_y,
		"text": text,
		"building_id": building_id,
		"born": now,
		"expires": now + 1350,
		"serial": _popup_serial,
		"jitter_x": jitter_x,
		"jitter_y": jitter_y,
	})
	queue_redraw()


func _draw_gain_popups() -> void:
	EffectsRenderer.draw_gain_popups(self)

func _draw_rival_buildings() -> void:
	var rv: UpMatch.Rival = match_ref.rivals[recon_rival_index]
	for rec in rv.buildings:
		var def: Dictionary = rec["def"]
		var cells: Array = rec.get("cells", [])
		BuildingRenderer.draw_building(self, def, cells, int(rec["hp"]), int(rec.get("flash", 0)))


func _draw_rival_walls() -> void:
	var rv: UpMatch.Rival = match_ref.rivals[recon_rival_index]
	var inner: int = GRID * px_cell
	var off: int = wall_thick + gap
	var crest: Color = rv.crest
	for d in UpMatch.DIRS:
		var hp_frac: float = clampf(float(int(rv.wall_hp[d])) / float(UpConfigRef.HP_FULL), 0.0, 1.0)
		var wall_col: Color = C_DOWN.lerp(C_STONE, hp_frac)
		var rect: Rect2 = _wall_rect(d, inner, off)
		var breached: bool = bool(rv.wall_collapsed[d])
		_draw_wall_25d(d, rect, wall_col, breached, crest, false)
	for tid in UpMatch.TURRETS:
		var twalls: Array = UpMatch.TURRET_WALLS[tid]
		var destroyed: bool = bool(rv.wall_collapsed[twalls[0]]) and bool(rv.wall_collapsed[twalls[1]])
		_draw_round_turret_25d(tid, _turret_rect(tid, inner, off), C_TURRET, destroyed, crest, false)


func _draw_rival_wall_crowd() -> void:
	if match_ref == null or recon_rival_index < 0 or recon_rival_index >= match_ref.rivals.size():
		return
	var rv: UpMatch.Rival = match_ref.rivals[recon_rival_index]
	var inner: int = GRID * px_cell
	var off: int = wall_thick + gap
	var now := float(Time.get_ticks_usec())
	_wall_crowd_count = 0
	for k in _wall_archer_pts:
		_wall_archer_pts[k].clear()

	for d in UpMatch.DIRS:
		if bool(rv.wall_collapsed[d]):
			continue
		var melee_count: int = match_ref._army_units(int(rv.wall_hp[d]), int(UpDefs.DEFENDERS["infantry"]["hp"]))
		var ranged_count: int = match_ref._army_units(int(rv.wall_ranged_hp[d]), int(UpDefs.DEFENDERS["archer"]["hp"]))
		var garrison: int = melee_count + ranged_count
		if garrison <= 0:
			continue
		var n: int = _wall_figure_count(garrison)
		var ranged_share: float = float(ranged_count) / float(garrison)
		var horiz: bool = d == "N" or d == "S"
		var rect: Rect2 = _wall_rect(d, inner, off)
		var walk_depth: float = maxf(12.0, float(wall_thick) * 0.26)
		var walk_rect: Rect2 = _castle_wall_walk_rect(d) if _use_exact_castle_art() else rect
		if not _use_exact_castle_art():
			if horiz:
				if d == "N":
					walk_rect.size.y = walk_depth
				else:
					walk_rect.position.y = rect.end.y - walk_depth
					walk_rect.size.y = walk_depth
			else:
				if d == "W":
					walk_rect.size.x = walk_depth
				else:
					walk_rect.position.x = rect.end.x - walk_depth
					walk_rect.size.x = walk_depth
		var span: float = (walk_rect.size.x if horiz else walk_rect.size.y) - 10.0
		var width: float = (walk_rect.size.y if horiz else walk_rect.size.x)
		# Leave visible personal space between parapet defenders.  If a huge
		# garrison would make sprites overlap, show fewer representative figures
		# rather than stacking them on top of one another.
		var wall_slot_spacing: float = 26.0
		n = mini(n, maxi(2, int(floor(maxf(1.0, span) / wall_slot_spacing))))
		var walk_quad: PackedVector2Array = _castle_wall_walk_quad(d) if _use_exact_castle_art() else PackedVector2Array()
		var under_attack: bool = _rival_wall_under_attack(rv, d)
		var attack_lane_f: float = _rival_wall_attack_lane_fraction(rv, d) if under_attack else 0.5
		var attack_move: float = _rival_wall_attack_move_progress(rv, d) if under_attack else 0.0
		var response: Dictionary = _wall_response("rival:%d:%s" % [rv.player_id, d], under_attack, attack_lane_f, attack_move, now)
		var response_blend: float = float(response["blend"])
		var response_lane_f: float = float(response["lane"])

		for i in n:
			var h: int = (i * 2654435761 + int(d.unicode_at(0)) * 40503) & 0x7FFFFFFF
			var beat: float = 0.56 + float(h % 31) / 100.0
			beat = minf(beat, 0.86)
			var slot_center_f: float = (float(i) + 0.5) / float(maxi(1, n))
			var slot_half_f: float = 0.34 / float(maxi(1, n))
			var startf: float = clampf(slot_center_f - slot_half_f, 0.0, 1.0)
			beat = minf(beat, slot_half_f * 2.0)
			var period: float = float(UpConfigRef.WALL_PATROL_SLOW_USEC
				- (h / 4343) % (UpConfigRef.WALL_PATROL_SLOW_USEC - UpConfigRef.WALL_PATROL_FAST_USEC))
			var phase: float = fmod(now / period + float((h / 7) % 100) / 100.0, 1.0)
			var moving_positive: bool = sin(phase * TAU) >= 0.0
			var travel: float = 0.5 - 0.5 * cos(phase * TAU)
			travel = lerpf(0.5, travel, patrol_motion_scale())
			var along: float = (startf + travel * beat) * maxf(1.0, span) + 6.0
			var lateral_range: float = width - 7.0
			var lateral: float = (float((h / 97) % 100) / 100.0 - 0.5) * lateral_range
			var pos: Vector2
			if _use_exact_castle_art():
				var patrol_along_f: float = clampf(startf + travel * beat, 0.015, 0.985)
				var patrol_across_f: float = 0.08 + float((h / 97) % 100) / 100.0 * 0.84
				var formation_step_f: float = minf(0.06, wall_slot_spacing / maxf(1.0, span))
				var formation_offset: float = (float(i) - float(n - 1) * 0.5) * formation_step_f
				var target_along_f: float = clampf(response_lane_f + formation_offset, 0.03, 0.97)
				var outer_across_f: float = 0.07 if d == "N" or d == "W" else 0.93
				var along_f: float = lerpf(patrol_along_f, target_along_f, response_blend)
				var across_f: float = lerpf(patrol_across_f, outer_across_f, response_blend)
				pos = _quad_bilerp(walk_quad, along_f, across_f) if horiz else _quad_bilerp(walk_quad, across_f, along_f)
			else:
				pos = Vector2(walk_rect.position.x + along, walk_rect.position.y + width * 0.5 + lateral) if horiz \
					else Vector2(walk_rect.position.x + width * 0.5 + lateral, walk_rect.position.y + along)
			var is_ranged: bool = float(i) / float(n) < ranged_share
			var facing_dir: String = _wall_outward_facing(d) if under_attack else (("E" if moving_positive else "W") if horiz else ("S" if moving_positive else "N"))
			var anim_state: String = "attack" if under_attack and attack_move >= 0.88 else "walk"
			if is_ranged:
				var face: float = -1.0 if facing_dir == "W" or facing_dir == "N" else 1.0
				ArmyRenderer.draw_detailed_archer(self, pos, C_BANNER.lightened(0.30), face, h, anim_state, -1.0, 1.15, facing_dir)
				_wall_archer_pts[d].append(pos)
			else:
				ArmyRenderer.draw_detailed_soldier(self, pos, C_BANNER, h, anim_state, -1.0, facing_dir == "W" or facing_dir == "N", 1.15, facing_dir)
			_wall_crowd_count += 1


func _draw_rival_turret_crowd() -> void:
	if match_ref == null or recon_rival_index < 0 or recon_rival_index >= match_ref.rivals.size():
		return
	var rv: UpMatch.Rival = match_ref.rivals[recon_rival_index]
	var inner: int = GRID * px_cell
	var off: int = wall_thick + gap
	var now := float(Time.get_ticks_usec())
	for tid in UpMatch.TURRETS:
		var adj: Array = UpMatch.TURRET_WALLS[tid]
		var destroyed: bool = bool(rv.wall_collapsed[adj[0]]) and bool(rv.wall_collapsed[adj[1]])
		if destroyed:
			continue
		var melee_count: int = match_ref._army_units(int(rv.turret_melee_hp[tid]), int(UpDefs.DEFENDERS["infantry"]["hp"]))
		var ranged_count: int = match_ref._army_units(int(rv.turret_ranged_hp[tid]), int(UpDefs.DEFENDERS["archer"]["hp"]))
		var garrison: int = melee_count + ranged_count
		if garrison <= 0:
			continue
		var n: int = mini(UpConfigRef.TURRET_VISUAL_MAX, _wall_figure_count(garrison))
		var ranged_share: float = float(ranged_count) / float(garrison)
		var rect: Rect2 = _turret_rect(tid, inner, off)
		var platform_center: Vector2 = _castle_turret_platform_center(tid) if _use_exact_castle_art() else rect.get_center() - Vector2(0, rect.size.y * 0.06)
		var platform_radii: Vector2 = _castle_turret_platform_radii(tid) if _use_exact_castle_art() else Vector2(minf(rect.size.x, rect.size.y) * 0.30, minf(rect.size.x, rect.size.y) * 0.30)
		var attack_wall: String = _rival_turret_attack_wall(rv, tid)
		for i in n:
			var hh: int = (i * 2654435761 + int(tid.unicode_at(0)) * 7919
				+ int(tid.unicode_at(1)) * 104729) & 0x7FFFFFFF
			var period: float = 7000000.0 + float((hh / 10007) % 5000000)
			var sway: float = sin(now / period * TAU + float(hh % 628) / 100.0) * 1.2 * patrol_motion_scale()
			var ang: float = TAU * float(hh % 1000) / 1000.0
			var radial: float = 0.20 + 0.70 * float((hh / 1000) % 100) / 100.0
			if _use_exact_castle_art():
				if n <= 1:
					ang = 0.0
					radial = 0.0
				else:
					# Deterministic rings keep turret defenders separated instead of
					# allowing several random radial posts to overlap.
					var outer_count: int = mini(n, 7)
					if i < outer_count:
						ang = -PI * 0.5 + TAU * float(i) / float(outer_count)
						radial = 0.78
					else:
						var inner_count: int = maxi(1, n - outer_count)
						ang = -PI * 0.5 + TAU * float(i - outer_count) / float(inner_count) + PI / float(maxi(2, inner_count))
						radial = 0.42
			var ellipse: Vector2 = Vector2(cos(ang) * platform_radii.x * radial, sin(ang) * platform_radii.y * radial)
			var pos: Vector2 = platform_center + ellipse + Vector2(sway, sway * 0.25)
			var is_ranged: bool = float(i) / float(n) < ranged_share
			var facing_dir: String = _wall_outward_facing(attack_wall) if attack_wall != "" else _scan_facing(now, hh)
			var anim_state: String = "attack" if attack_wall != "" else "idle"
			if is_ranged:
				var face: float = -1.0 if facing_dir == "W" or facing_dir == "N" else 1.0
				ArmyRenderer.draw_detailed_archer(self, pos, C_BANNER.lightened(0.30), face, hh, anim_state, -1.0, 1.15, facing_dir)
				_wall_archer_pts[tid].append(pos)
			else:
				ArmyRenderer.draw_detailed_soldier(self, pos, C_BANNER, hh, anim_state, -1.0, facing_dir == "W" or facing_dir == "N", 1.15, facing_dir)
			_wall_crowd_count += 1


func _draw_rival_battle() -> void:
	var rv: UpMatch.Rival = match_ref.rivals[recon_rival_index]
	var target_pid: int = rv.player_id
	# Recon battles share the same detailed-atlas MultiMesh renderer as home.
	# Offscreen fiefdoms do no presentation work at all; the currently viewed one
	# refreshes these batches at the local adaptive visual cadence.
	var rival_visual_total: int = 0
	for rinv: UpMatch.Invader in rv.invaders:
		if rinv.hp > 0:
			rival_visual_total += match_ref.invader_members(rinv)
	for ra: UpMatch.Army in match_ref.armies:
		if ra.target == target_pid and ra.phase == "travel":
			rival_visual_total += match_ref._army_units(ra.melee_hp, int(UpDefs.DEFENDERS["infantry"]["hp"]))
			rival_visual_total += match_ref._army_units(ra.ranged_hp, int(UpDefs.DEFENDERS["archer"]["hp"]))
	var rival_rebuilding: bool = ArmyRenderer._begin_detail_batches(self, rival_visual_total, hash(["rival", recon_rival_index, target_pid]))

	# Travelling armies use the same visual formation as invaders approaching the
	# player's fiefdom: grouped lanes across the selected wall, stable horde depth,
	# elongated outside-wall member spacing, and the same body/head soldier art.
	for a: UpMatch.Army in match_ref.armies:
		if a.target != target_pid or a.phase != "travel":
			continue
		var has_physical_approach: bool = false
		for approach_inv: UpMatch.Invader in rv.invaders:
			if approach_inv.hp > 0 and approach_inv.army_id == a.id:
				has_physical_approach = true
				break
		if has_physical_approach:
			continue
		var melee_count: int = match_ref._army_units(a.melee_hp, int(UpDefs.DEFENDERS["infantry"]["hp"]))
		var ranged_count: int = match_ref._army_units(a.ranged_hp, int(UpDefs.DEFENDERS["archer"]["hp"]))
		var total_count: int = melee_count + ranged_count
		if total_count <= 0:
			continue

		var dynamic_group_size: int = maxi(UpConfigRef.INVADER_GROUP_SIZE,
			int(ceil(float(total_count) / float(UpConfigRef.MAX_GROUPS_PER_ARMY))))
		var group_specs: Array = []
		var melee_left: int = melee_count
		var ranged_left: int = ranged_count
		while melee_left > 0:
			var mn: int = mini(dynamic_group_size, melee_left)
			group_specs.append({"count": mn, "cat": "melee"})
			melee_left -= mn
		while ranged_left > 0:
			var rn: int = mini(dynamic_group_size, ranged_left)
			group_specs.append({"count": rn, "cat": "ranged"})
			ranged_left -= rn

		var remaining_ticks: int = maxi(0, a.arrives - match_ref.tick)
		# Countdown represents time to first engagement. Mixed/ranged armies are
		# therefore drawn one archer firing envelope farther from the wall while the
		# timer is running, matching the authoritative physical spawn path.
		var first_engagement_standoff: int = UpConfigRef.INVADER_WALL_RANGED_MAX if ranged_count > 0 else 0
		var approach_dist: int = first_engagement_standoff + remaining_ticks * UpConfigRef.PREVIEW_APPROACH_SPEED
		var outward: Vector2i = match_ref.invader_outward_dir(a.target_wall)
		var lane_span: int = GRID * CELL - CELL
		var group_total: int = group_specs.size()
		var stride: int = maxi(1, int(ceil(float(total_count) / float(visual_soldier_cap()))))
		var member_serial: int = 0
		var army_color: Color = Color("4f74b5") if a.attacker == 0 else match_ref.rivals[a.attacker - 1].crest

		for gi in group_total:
			var spec: Dictionary = group_specs[gi]
			var lane: int = GRID * CELL / 2
			if group_total > 1:
				lane = CELL / 2 + gi * lane_span / (group_total - 1)
			var jitter_seed: int = a.id * 193 + gi * 389
			var lane_jitter: int = (absi(jitter_seed) % (2 * (CELL / 5) + 1)) - CELL / 5
			lane = clampi(lane + lane_jitter, CELL, GRID * CELL - CELL)

			var contact: Vector2i = match_ref.invader_wall_contact_point(a.target_wall, lane)
			var depth: int = absi((a.id * 977) + gi * 431) % 601
			var group_mm: Vector2i = contact + outward * (approach_dist + depth)
			var group_px: Vector2 = Vector2(mm_to_px(group_mm.x), mm_to_py(group_mm.y))
			var group_visual_id: int = a.id * 257 + gi * 17
			var cat: String = str(spec["cat"])
			var col: Color = army_color.lightened(0.18) if cat == "ranged" else army_color

			var spec_count: int = int(spec["count"])
			var visual_count: int = int(ceil(float(spec_count) / float(stride)))
			for vi in visual_count:
				var n: int = mini(spec_count - 1, vi * stride)
				member_serial += stride
				var offset: Vector2 = ArmyRenderer.member_offset(group_visual_id, n, true, a.target_wall)
				var facing_dir: String = ArmyRenderer._inward_facing_for_wall(a.target_wall)
				if cat == "ranged":
					ArmyRenderer._queue_detail_archer(self, group_px + offset, col, group_visual_id * 613 + n, "walk", -1.0, facing_dir == "W" or facing_dir == "N", facing_dir)
				else:
					ArmyRenderer._queue_detail_soldier(self, group_px + offset, col, group_visual_id * 613 + n, "walk", -1.0, facing_dir == "W" or facing_dir == "N", facing_dir)

	# Arrived attackers use exactly the same independent-agent crowd solver as the
	# home battlefield.  This removes the old recon-only packet-offset path that
	# produced different movement, wall overlap and geometric columns.
	if rival_rebuilding:
		crowd_presentation.sync_and_step(self, rv.invaders, rv, hash(["rival", recon_rival_index, target_pid]),
			mini(visual_soldier_cap(), UpConfigRef.CROWD_MAX_VISIBLE_AGENTS))
		for ai in crowd_presentation.active_indices:
			var pp: Vector2 = crowd_presentation.positions[ai]
			var damage_tick: int = int(crowd_presentation.damage_ticks[ai])
			var state: String = "hurt" if ArmyRenderer._is_recently_damaged(self, damage_tick) else ("attack" if int(crowd_presentation.states[ai]) == 1 else "walk")
			var damage_age: float = ArmyRenderer._damage_age(self, damage_tick) if state == "hurt" else -1.0
			var facing_dir: String = crowd_presentation.facing_string(ai)
			var flip: bool = facing_dir == "W" or facing_dir == "N"
			var col: Color = crowd_presentation.colors[ai]
			var seed: int = int(crowd_presentation.seeds[ai])
			if int(crowd_presentation.categories[ai]) == 1:
				ArmyRenderer._queue_detail_archer(self, pp, col, seed, state, damage_age, flip, facing_dir)
			else:
				ArmyRenderer._queue_detail_soldier(self, pp, col, seed, state, damage_age, flip, facing_dir)

	ArmyRenderer._finalize_detail_batches(self)

	# Recon-view combat effects for attacks on rival buildings/walls.
	var recon_shot_i := 0
	for shot in rv.shots:
		recon_shot_i += 1
		if (recon_shot_i - 1) % projectile_stride() != 0:
			continue
		var age: float = float(match_ref.tick - int(shot["fired"])) + interpolation_alpha()
		if age < 0.0 or age > float(UpConfigRef.ARROW_FLIGHT):
			continue
		var t: float = clampf(age / float(UpConfigRef.ARROW_FLIGHT), 0.0, 1.0)
		var aa: Vector2 = Vector2(mm_to_px(int(shot["fx"])), mm_to_py(int(shot["fy"])))
		var bb: Vector2 = Vector2(mm_to_px(int(shot["tx"])), mm_to_py(int(shot["ty"])))
		var pp: Vector2 = aa.lerp(bb, t)
		if not battle_visual_visible(pp, 14.0):
			continue
		EffectsRenderer.draw_stylized_arrow(self, aa, bb, t, bool(shot.get("hostile", true)))
	var recon_hit_i := 0
	for hit in rv.melee_impacts:
		recon_hit_i += 1
		if (recon_hit_i - 1) % impact_stride() != 0:
			continue
		var age2: float = float(match_ref.tick - int(hit["fired"])) + interpolation_alpha()
		if age2 < 0.0 or age2 > float(UpConfigRef.MELEE_IMPACT_TICKS):
			continue
		var t2: float = clampf(age2 / float(UpConfigRef.MELEE_IMPACT_TICKS), 0.0, 1.0)
		var hp: Vector2 = Vector2(mm_to_px(int(hit["x"])), mm_to_py(int(hit["y"])))
		if not battle_visual_visible(hp, 14.0):
			continue
		var alpha: float = 1.0 - t2
		var radius: float = 2.2 + 5.0 * t2
		draw_circle(hp, radius, Color(1.0, 0.52, 0.10, 0.52 * alpha))
		draw_circle(hp, maxf(1.2, radius * 0.48), Color(1.0, 0.92, 0.52, 0.92 * alpha))

	for death in rv.death_floats:
		var dage: float = float(match_ref.tick - int(death["fired"])) + interpolation_alpha()
		if dage < 0.0 or dage > float(UpConfigRef.DEATH_FLOAT_TICKS):
			continue
		var dt: float = clampf(dage / float(UpConfigRef.DEATH_FLOAT_TICKS), 0.0, 1.0)
		var dbase: Vector2 = Vector2(mm_to_px(int(death["x"])), mm_to_py(int(death["y"])))
		var dalpha: float = 1.0 if dt <= 0.48 else clampf(1.0 - (dt - 0.48) / 0.52, 0.0, 1.0)
		var casualty_count: int = maxi(1, int(death["count"]))
		var spread: float = minf(42.0, 7.0 + sqrt(float(casualty_count)) * 1.55)
		var visible_deaths: int = mini(casualty_count, death_visual_cap_per_event())
		var death_stride: int = maxi(1, int(ceil(float(casualty_count) / float(maxi(1, visible_deaths)))))
		for vi in visible_deaths:
			var n: int = mini(casualty_count - 1, vi * death_stride)
			var seed2: int = absi(int(death["seed"]) * 1103515245 + n * 977 + 12345)
			var rx: float = float((seed2 % 2001) - 1000) / 1000.0
			var ry_seed: int = absi(seed2 * 1664525 + 1013904223)
			var ry: float = float((ry_seed % 2001) - 1000) / 1000.0
			var drift_seed: int = absi(ry_seed * 1103515245 + 12345)
			var drift_sign: float = -1.0 if (drift_seed & 1) == 0 else 1.0
			var start_offset: Vector2 = Vector2(rx * spread, ry * spread * 0.42)
			var rise: float = 9.0 + 31.0 * dt + float(seed2 % 7) * 0.35 * dt
			var drift: float = drift_sign * (1.0 + float(seed2 % 9) * 0.22) * dt
			var dp: Vector2 = dbase + start_offset + Vector2(drift, -rise)
			if not battle_visual_visible(dp, 8.0):
				continue
			var bone: Color = Color(0.95, 0.91, 0.78, dalpha)
			var dark: Color = Color(0.12, 0.10, 0.08, 0.85 * dalpha)
			draw_line(dp + Vector2(-3.5, 3.0), dp + Vector2(3.5, -3.0), bone, 1.2)
			draw_line(dp + Vector2(-3.5, -3.0), dp + Vector2(3.5, 3.0), bone, 1.2)
			draw_circle(dp, 3.35, bone)
			draw_circle(dp + Vector2(-1.15, -0.35), 0.7, dark)
			draw_circle(dp + Vector2(1.15, -0.35), 0.7, dark)


func _castle_rect_from_src(src: Rect2) -> Rect2:
	var dest: Rect2 = _castle_art_dest_rect()
	var sx: float = dest.size.x / float(FIEFDOM_CASTLE_ART.get_width())
	var sy: float = dest.size.y / float(FIEFDOM_CASTLE_ART.get_height())
	return Rect2(dest.position.x + src.position.x * sx, dest.position.y + src.position.y * sy, src.size.x * sx, src.size.y * sy)


func _castle_wall_hit_rect(d: String) -> Rect2:
	# Click/destination zones follow the same traced walkable wall surfaces used
	# by the defenders, so interaction and movement stay aligned with the artwork.
	return _castle_wall_walk_rect(d)


func _castle_wall_walk_quad(d: String) -> PackedVector2Array:
	# These source-space boundaries are traced from the user's red guideline image.
	# They run tower-to-tower and remain inside the parapet edges.
	# Order is TL, TR, BR, BL in castle-source coordinates.
	var src := PackedVector2Array()
	match d:
		"N": src = PackedVector2Array([
			Vector2(302.6, 169.8), Vector2(822.9, 170.9),
			Vector2(822.4, 259.6), Vector2(302.8, 258.8)])
		"S": src = PackedVector2Array([
			Vector2(275.1, 975.9), Vector2(872.4, 974.8),
			Vector2(871.7, 1076.9), Vector2(275.4, 1078.3)])
		"W": src = PackedVector2Array([
			Vector2(143.4, 286.1), Vector2(235.0, 283.5),
			Vector2(210.0, 834.8), Vector2(88.9, 835.0)])
		_: src = PackedVector2Array([
			Vector2(899.3, 285.4), Vector2(995.4, 287.3),
			Vector2(1051.7, 836.5), Vector2(930.8, 834.0)])
	var out := PackedVector2Array()
	for pt in src:
		out.append(_castle_point_from_src(pt))
	return out


func _quad_bilerp(q: PackedVector2Array, u: float, v: float) -> Vector2:
	var top: Vector2 = q[0].lerp(q[1], clampf(u, 0.0, 1.0))
	var bottom: Vector2 = q[3].lerp(q[2], clampf(u, 0.0, 1.0))
	return top.lerp(bottom, clampf(v, 0.0, 1.0))


func _castle_wall_walk_rect(d: String) -> Rect2:
	# Axis-aligned walk-area bounds used by callers that need a Rect2. Defender
	# placement itself uses _castle_wall_walk_quad to follow the artwork perspective.
	var q: PackedVector2Array = _castle_wall_walk_quad(d)
	var min_x: float = minf(minf(q[0].x, q[1].x), minf(q[2].x, q[3].x))
	var max_x: float = maxf(maxf(q[0].x, q[1].x), maxf(q[2].x, q[3].x))
	var min_y: float = minf(minf(q[0].y, q[1].y), minf(q[2].y, q[3].y))
	var max_y: float = maxf(maxf(q[0].y, q[1].y), maxf(q[2].y, q[3].y))
	return Rect2(min_x, min_y, max_x - min_x, max_y - min_y)


func _castle_turret_hit_rect(id: String) -> Rect2:
	# True oval interiors traced from the red guideline reference on this exact
	# approved castle image. Rect2 is the ellipse bounding box in source pixels.
	match id:
		"NW": return _castle_rect_from_src(Rect2(97.3, 108.0, 182.8, 115.2))
		"NE": return _castle_rect_from_src(Rect2(842.8, 110.7, 188.4, 122.6))
		"SW": return _castle_rect_from_src(Rect2(41.2, 894.3, 205.6, 151.6))
		_: return _castle_rect_from_src(Rect2(902.2, 893.1, 218.6, 148.2))


func _castle_turret_platform_center(id: String) -> Vector2:
	return _castle_turret_hit_rect(id).get_center()


func _castle_turret_platform_radii(id: String) -> Vector2:
	# Rect2 stores the oval's full width/height. Half-size is the true ellipse
	# radius; a 4% inset keeps feet just inside the parapet without turning it
	# into a circle or artificially shrinking the usable top.
	return _castle_turret_hit_rect(id).size * 0.48


func _castle_turret_contains(id: String, p: Vector2) -> bool:
	var r: Rect2 = _castle_turret_hit_rect(id)
	var c: Vector2 = r.get_center()
	var rx: float = maxf(1.0, r.size.x * 0.5)
	var ry: float = maxf(1.0, r.size.y * 0.5)
	var dx: float = (p.x - c.x) / rx
	var dy: float = (p.y - c.y) / ry
	return dx * dx + dy * dy <= 1.0



func _castle_alpha_image_contains(img: Image, p: Vector2) -> bool:
	if img == null or img.is_empty():
		return false
	var dest: Rect2 = _castle_art_dest_rect()
	if not dest.has_point(p) or dest.size.x <= 0.0 or dest.size.y <= 0.0:
		return false
	var sx: float = float(img.get_width()) / dest.size.x
	var sy: float = float(img.get_height()) / dest.size.y
	var ix: int = clampi(int(floor((p.x - dest.position.x) * sx)), 0, img.get_width() - 1)
	var iy: int = clampi(int(floor((p.y - dest.position.y) * sy)), 0, img.get_height() - 1)
	return img.get_pixel(ix, iy).a > 0.06


func _castle_full_wall_contains(d: String, p: Vector2) -> bool:
	return CastleInteraction.full_wall_contains(self, d, p)


func _castle_full_turret_contains(tid: String, p: Vector2) -> bool:
	return CastleInteraction.full_turret_contains(self, tid, p)


func _castle_piece_at_local(p: Vector2) -> Dictionary:
	return CastleInteraction.piece_at_local(self, p)


func _castle_outer_wall_visual_limit(d: String) -> float:
	match d:
		# Stop outside invaders at the visible exterior edges of the artwork.
		# South uses the bottom/front edge of the gatehouse wall, not the courtyard-side parapet.
		"N": return _castle_rect_from_src(Rect2(0.0, 170.0, 0.0, 0.0)).position.y
		"S": return _castle_rect_from_src(Rect2(0.0, 1260.0, 0.0, 0.0)).position.y
		"W": return _castle_rect_from_src(Rect2(89.0, 0.0, 0.0, 0.0)).position.x
		_: return _castle_rect_from_src(Rect2(1052.0, 0.0, 0.0, 0.0)).position.x


func _wall_rect(d: String, inner: int, off: int) -> Rect2:
	if _use_exact_castle_art():
		return _castle_wall_hit_rect(d)
	match d:
		"N": return Rect2(off, 0, inner, wall_thick)
		"S": return Rect2(off, off + inner, inner, wall_thick)
		"W": return Rect2(0, off, wall_thick, inner)
		_:   return Rect2(off + inner, off, wall_thick, inner)


func _turret_rect(id: String, inner: int, off: int) -> Rect2:
	if _use_exact_castle_art():
		return _castle_turret_hit_rect(id)
	# Round open-top towers intentionally project beyond the wall faces, matching
	# the concept art while preserving the same clickable corner footprint.
	var t := float(wall_thick) * 1.34
	var over := (t - float(wall_thick)) * 0.5
	var x: float = -over - 8.0 if id == "NW" or id == "SW" else float(off + inner) - over + 8.0
	var y: float = -over if id == "NW" or id == "NE" else float(off + inner) - over
	return Rect2(x, y, t, t)


func _hovered_invader_army(screen_pos: Vector2) -> int:
	# Hovering any visible soldier in an invading War Camp reveals the composition
	# of that whole army. Use the same presentation spread as the army renderer so
	# the hit region follows the on-screen formation on both home and recon views.
	if match_ref == null:
		return -1
	var invaders: Array = match_ref.invaders
	if recon_rival_index >= 0 and recon_rival_index < match_ref.rivals.size():
		invaders = match_ref.rivals[recon_rival_index].invaders
	var local_pos: Vector2 = _screen_to_board(screen_pos)
	var best_army: int = -1
	var best_score: float = 999999.0
	for inv in invaders:
		if inv.hp <= 0 or inv.army_id < 0:
			continue
		var members: int = match_ref.invader_members(inv)
		if members <= 0:
			continue
		var base: Vector2 = interpolated_invader_visual_px(inv)
		var spread: float = minf(72.0, 10.0 + sqrt(float(members)) * 3.8)
		var rx: float = maxf(28.0, spread + 20.0)
		var ry: float = maxf(28.0, spread + 20.0)
		if not inv.inside:
			if inv.wall == "N" or inv.wall == "S":
				rx *= 1.45
				ry *= 1.10
			else:
				ry *= 1.45
				rx *= 1.10
		var dx: float = (local_pos.x - base.x) / rx
		var dy: float = (local_pos.y - base.y) / ry
		var score: float = dx * dx + dy * dy
		if score <= 1.0 and score < best_score:
			best_score = score
			best_army = inv.army_id
	return best_army


func _gui_input(ev: InputEvent) -> void:
	if match_ref == null:
		return

	# Mouse wheel zooms toward the cursor.
	if ev is InputEventMouseButton and ev.pressed:
		if ev.button_index == MOUSE_BUTTON_WHEEL_UP:
			_zoom_at(ev.position, VIEW_ZOOM_STEP)
			accept_event()
			return
		if ev.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_zoom_at(ev.position, 1.0 / VIEW_ZOOM_STEP)
			accept_event()
			return

	# Middle- or right-button drag pans without conflicting with gameplay clicks.
	if ev is InputEventMouseButton and (ev.button_index == MOUSE_BUTTON_MIDDLE or ev.button_index == MOUSE_BUTTON_RIGHT):
		_panning = ev.pressed
		_pan_last = ev.position
		accept_event()
		return

	# Native trackpad pinch/pan support on systems that emit gesture events.
	if ev is InputEventMagnifyGesture:
		_zoom_at(ev.position, ev.factor)
		accept_event()
		return
	if ev is InputEventPanGesture:
		view_pan -= ev.delta * 18.0
		_clamp_view_pan()
		queue_redraw()
		accept_event()
		return

	if ev is InputEventMouseMotion:
		if _panning:
			view_pan += ev.position - _pan_last
			_pan_last = ev.position
			_clamp_view_pan()
			queue_redraw()
			accept_event()
			return
		hover_army_id = _hovered_invader_army(ev.position)
		hover_army_screen_pos = ev.position
		hover_cell = _cell_at(ev.position)
		# Army hover takes visual-tooltip priority. Otherwise the courtyard grid owns
		# overlapping interaction space, so wall/tower tooltips cannot supersede it.
		if hover_army_id >= 0 or hover_cell.x >= 0:
			hover_turret = ""
			hover_wall = ""
		elif _use_exact_castle_art():
			var local_hover: Vector2 = _screen_to_board(ev.position)
			var piece_hit: Dictionary = _castle_piece_at_local(local_hover)
			hover_turret = str(piece_hit.get("id", "")) if str(piece_hit.get("kind", "")) == "tower" else ""
			hover_wall = str(piece_hit.get("id", "")) if str(piece_hit.get("kind", "")) == "wall" else ""
		else:
			hover_turret = _turret_at(ev.position)
			hover_wall = "" if hover_turret != "" else _wall_at(ev.position)
		queue_redraw()
		return

	if ev is InputEventMouseButton and ev.pressed and ev.button_index == MOUSE_BUTTON_LEFT:
		var editable_view: bool = _viewing_local_fiefdom()
		if not editable_view:
			# Other fiefdoms remain reconnaissance-only.
			return
		var local: Vector2 = _screen_to_board(ev.position)
		var inner: int = GRID * px_cell
		var off: int = wall_thick + gap

		# Grid clicks have absolute priority over wall/tower hit regions. Resolve
		# the courtyard cell first and handle buildings/placement immediately.
		var c := _cell_at(ev.position)
		if c.x >= 0:
			var bid: int = 0
			if local_player_id == 0:
				bid = int(match_ref.occupancy[c.y * GRID + c.x])
			else:
				var rv: UpMatch.Rival = match_ref.rivals[local_player_id - 1]
				var marker_value: int = int(rv.layout_occupancy[c.y * GRID + c.x])
				if marker_value > 0 and marker_value - 1 < rv.buildings.size():
					bid = int(rv.buildings[marker_value - 1].get("rid", 0))
			if bid != 0 and ghost_def.is_empty():
				building_clicked.emit(bid)
			else:
				cell_clicked.emit(c.x, c.y)
			return

		if _use_exact_castle_art():
			var piece_hit: Dictionary = _castle_piece_at_local(local)
			var piece_kind: String = str(piece_hit.get("kind", ""))
			var piece_id: String = str(piece_hit.get("id", ""))
			if piece_kind == "tower":
				turret_clicked.emit(piece_id)
				return
			if piece_kind == "wall":
				wall_clicked.emit(piece_id)
				return
		else:
			for tid in UpMatch.TURRETS:
				if _turret_rect(tid, inner, off).has_point(local):
					turret_clicked.emit(tid)
					return
			for d in UpMatch.DIRS:
				if _wall_rect(d, inner, off).has_point(local):
					wall_clicked.emit(d)
					return
		return


func _turret_at(mouse: Vector2) -> String:
	if _cell_at(mouse).x >= 0:
		return ""
	var local: Vector2 = _screen_to_board(mouse)
	var inner: int = GRID * px_cell
	var off: int = wall_thick + gap
	if _use_exact_castle_art():
		var hit: Dictionary = _castle_piece_at_local(local)
		return str(hit.get("id", "")) if str(hit.get("kind", "")) == "tower" else ""
	for tid in UpMatch.TURRETS:
		if _turret_rect(tid, inner, off).has_point(local):
			return tid
	return ""


func _wall_at(mouse: Vector2) -> String:
	if _cell_at(mouse).x >= 0:
		return ""
	var local: Vector2 = _screen_to_board(mouse)
	var inner: int = GRID * px_cell
	var off: int = wall_thick + gap
	if _use_exact_castle_art():
		var hit: Dictionary = _castle_piece_at_local(local)
		return str(hit.get("id", "")) if str(hit.get("kind", "")) == "wall" else ""
	for d in UpMatch.DIRS:
		if _wall_rect(d, inner, off).has_point(local):
			return d
	return ""


func _cell_at(mouse: Vector2) -> Vector2i:
	return BoardCoordinates.cell_at(self, mouse)

