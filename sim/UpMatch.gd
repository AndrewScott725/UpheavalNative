class_name UpMatch
extends RefCounted
const UpConfigRef = preload("res://sim/UpConfig.gd")

const CombatSystem = preload("res://sim/CombatSystem.gd")
const InvaderSystem = preload("res://sim/InvaderSystem.gd")
const WallCombatSystem = preload("res://sim/WallCombatSystem.gd")
const ArmySystem = preload("res://sim/ArmySystem.gd")
const BattleSnapshotSystem = preload("res://sim/BattleSnapshotSystem.gd")
const RivalAISystem = preload("res://sim/RivalAISystem.gd")
const RivalBattleSystem = preload("res://sim/RivalBattleSystem.gd")
const FlowFieldRouter = preload("res://sim/FlowFieldRouter.gd")

## The authoritative simulation (§16).
##
## This class touches no scene tree, no rendering, no input. It exposes state to
## read and discrete actions to request; it decides every outcome itself (§16.1,
## §16.2). A match is a self-contained, disposable instance — create one, run it,
## throw it away (§16.4).
##
## All state is integer. Positions are in millicells (1 cell == 1000).

const S := UpConfigRef.S
const TPS := UpConfigRef.TPS
const GRID := UpConfigRef.GRID
const CELL := UpConfigRef.CELL

const DIRS := ["N", "E", "S", "W"]
## Hoisted: these were array literals inside the innermost placement-scoring
## loops, allocating roughly 83,000 arrays per AI building placed.
## Rings to expand before abandoning the bucket walk for a direct scan.
const SORTIE_RING_BAILOUT: int = 3
const NEIGHBOURS4: Array[Vector2i] = [Vector2i.LEFT, Vector2i.RIGHT, Vector2i.UP, Vector2i.DOWN]
const TURRETS := ["NW", "NE", "SE", "SW"]
const TURRET_WALLS := {"NW": ["N", "W"], "NE": ["N", "E"], "SE": ["S", "E"], "SW": ["S", "W"]}
const PLAYER_FACTION_NAME := "Ironcrest"

const INVADER_FORCE_COLORS := [
	Color("a9362f"), Color("b6652b"), Color("6f4b9b"), Color("39745a"),
	Color("8a3d68"), Color("416f91"), Color("7b5a32"), Color("8b2f3d")
]

# ---------------------------------------------------------------------------
# Inner state types
# ---------------------------------------------------------------------------

class Unit extends RefCounted:
	## Adaptive defender packet. One Unit may represent one soldier in a small
	## fight or many identical soldiers in a huge garrison. HP remains the exact
	## combined HP pool, so casualties stay granular even when CPU work is grouped.
	var id: int
	var def: Dictionary
	var hp: int
	var member_hp: int = 1
	var group_size: int = 1
	## Position along the wall this unit garrisons, in millicells (0..GRID*CELL).
	## Wall defenders previously shared a single wall-centre point, so every
	## archer on a wall got the same range answer and the whole garrison fired
	## or idled together. Derived from the id so it is stable across casualties
	## and identical on every machine.
	var lane: int = 0
	var next_attack: int = 0
	var pending_damage: int = 0
	var damage_mark_tick: int = -1
	func _init(p_id: int, p_def: Dictionary, p_count: int = 1) -> void:
		id = p_id
		def = p_def
		member_hp = maxi(1, int(p_def["hp"]))
		group_size = maxi(1, p_count)
		hp = group_size * member_hp

class Building extends RefCounted:
	var id: int
	var def: Dictionary
	var cells: Array          ## Array[Vector2i] in grid coords
	var hp: int
	var pending_damage: int = 0
	var damage_mark_tick: int = -1
	var cx: int               ## centroid, millicells
	var cy: int
	var flash: int = 0        ## presentation hint only
	func _init(p_id: int, p_def: Dictionary, p_cells: Array) -> void:
		id = p_id; def = p_def; cells = p_cells; hp = p_def["hp"]
		var sx: int = 0
		var sy: int = 0
		for c in cells:
			sx += c.x * CELL + CELL / 2
			sy += c.y * CELL + CELL / 2
		cx = sx / cells.size()
		cy = sy / cells.size()

class Wall extends RefCounted:
	var dir: String
	var collapsed: bool = false     ## §7.3 the flag that splits the two state tables
	var cooldown: int = 0
	var collapse_tick: int = -1
	var melee: Array = []           ## Array[Unit] — these ARE the wall's HP (§7.1)
	var ranged: Array = []          ## Array[Unit] — never count toward wall HP
	func _init(p_dir: String) -> void: dir = p_dir
	func hp() -> int:
		var h := 0
		for u in melee: h += u.hp
		return h

class Turret extends RefCounted:
	var id: String
	var destroyed: bool = false
	var melee: Array = []           ## parked reserve — sorties on breach (§6.7)
	var ranged: Array = []
	func _init(p_id: String) -> void: id = p_id

class Invader extends RefCounted:
	## Hybrid simulation entity. One Invader may represent several identical
	## soldiers. HP is the exact combined HP pool of the living group.
	var id: int
	var def: Dictionary
	var hp: int
	var member_hp: int = 1
	var group_size: int = 1
	var next_attack: int = 0
	var active_tick: int = 0          ## visible/marching before combat begins
	var pending_damage: int = 0
	var pending_attr: int = 0
	var damage_mark_tick: int = -1
	var x: int
	var y: int
	# Previous authoritative tick position, used only for render interpolation.
	var prev_x: int = 0
	var prev_y: int = 0
	var wall: String                ## the wall it was sent at — never changes (§6.6)
	var wall_lane: int = 0          ## millicell coordinate along that wall; keeps attackers spread out
	var inside: bool = false
	var at_wall: bool = false       ## once in engagement range, skip repeated distance/sqrt work
	var wall_contact_tick: int = -1   ## first tick physically flush with standing wall
	var structure_contact_tick: int = -1 ## first tick physically flush with building
	var tgt_kind: String = ""       ## "b" building, "s" sortied defender, "u" stationed defender
	var tgt_id: int = -1
	var hx: int = 0                 ## heading, for the clockwise tie-break (§8)
	var hy: int = 0
	var force_color: Color = Color("a9362f")
	var army_id: int = -1

	# Incremental spatial-index state.
	var indexed: bool = false
	var indexed_inside: bool = false
	var bucket_key: Vector2i = Vector2i.ZERO

	# Interior route/progress state.
	var path: Array = []              ## Array[Vector2i] world-space waypoints
	var path_index: int = 0
	var path_target_kind: String = ""
	var path_target_id: int = -1
	var last_progress_x: int = 0
	var last_progress_y: int = 0
	var stuck_ticks: int = 0

class Sortie extends RefCounted:
	## Mobile defender packet created from a turret garrison group.
	var id: int
	var def: Dictionary
	var hp: int
	var member_hp: int = 1
	var group_size: int = 1
	var next_attack: int = 0
	var origin_turret: String = ""
	var pending_damage: int = 0
	var damage_mark_tick: int = -1
	var x: int
	var y: int
	# Previous authoritative tick position, used only for render interpolation.
	var prev_x: int = 0
	var prev_y: int = 0
	var tgt_id: int = -1
	var hx: int = 0
	var hy: int = 0
	var dead: bool = false

class PendingAttack extends RefCounted:
	var dir: String
	var size: int
	var arrives: int
	var spawned_visible: bool = false
	var wave: int
	var force_color: Color = Color("a9362f")
	var device: int = 0
	var source_player: int = -1
	var army_id: int = -1
	var melee: int = 0
	var ranged: int = 0

class Rival extends RefCounted:
	## A lightweight but live AI-controlled fiefdom. It has its own economy,
	## buildings, soldier pools, walls, War Camps and strategic personality.
	var player_id: int
	var name: String
	var crest: Color
	var device: int
	var personality: String
	var defeated: bool = false
	var gold: int = 0
	var pool := {"melee": 0, "ranged": 0}
	var buildings: Array = []          ## Array[Dictionary] {def,hp}
	var purchases := {}
	var wall_hp := {"N": 0, "E": 0, "S": 0, "W": 0}
	var wall_ranged_hp := {"N": 0, "E": 0, "S": 0, "W": 0}
	var wall_collapsed := {"N": false, "E": false, "S": false, "W": false}
	var wall_cooldown := {"N": 0, "E": 0, "S": 0, "W": 0}
	var wall_collapse_tick := {"N": -1, "E": -1, "S": -1, "W": -1}
	var wall_next_melee := {"N": 0, "E": 0, "S": 0, "W": 0}
	var wall_next_ranged := {"N": 0, "E": 0, "S": 0, "W": 0}
	# Rival-backed human/AI fiefdoms keep independent turret garrisons just like
	# Ironcrest. Values are aggregate HP so the distributed rival battle sim can
	# remain compact while still exposing exact soldier counts to the owning UI.
	var turret_melee_hp := {"NW": 0, "NE": 0, "SE": 0, "SW": 0}
	var turret_ranged_hp := {"NW": 0, "NE": 0, "SE": 0, "SW": 0}
	var turret_next_melee := {"NW": 0, "NE": 0, "SE": 0, "SW": 0}
	var turret_next_ranged := {"NW": 0, "NE": 0, "SE": 0, "SW": 0}
	var invaders: Array = []           ## Physical enemy groups currently inside/at this fiefdom
	var shots: Array = []              ## Recon-view ranged presentation events
	var melee_impacts: Array = []      ## Recon-view melee presentation events
	var death_floats: Array = []       ## Recon-view casualty presentation events
	var camps: Array = []              ## Array[WarCamp]
	var next_build_tick: int = 0
	var next_attack_tick: int = 0
	var next_action_tick: int = 0
	var action_cursor: int = 0
	var click_window: int = -1
	var click_count: int = 0
	var camp_cursor: int = 0
	var recon_unlocked: bool = false
	var layout_occupancy: PackedInt32Array = PackedInt32Array()
	var layout_revision: int = 0
	var flow_field_cache: Dictionary = {}

class WarCamp extends RefCounted:
	var index: int
	var melee: int = 0
	var ranged: int = 0
	func total() -> int: return melee + ranged
	func empty() -> bool: return melee == 0 and ranged == 0

class Army extends RefCounted:
	## A complete deployed War Camp. Travel/return bookkeeping stays aggregate,
	## but arrival at either a human or AI fiefdom materializes physical Invader
	## groups on that target battlefield.
	var id: int
	var attacker: int                 ## 0 human, 1..3 AI
	var target: int                   ## 0 human, 1..3 AI
	var from_camp: int
	var target_wall: String
	var melee: int = 0
	var ranged: int = 0
	var melee_hp: int = 0
	var ranged_hp: int = 0
	var arrives: int = 0
	var travel_ticks: int = 0         ## departure duration chosen from current circular-chain distance
	var phase: String = "travel"      ## travel, human_field, rival_field, return
	var next_melee: int = 0
	var next_ranged: int = 0

class Shot extends RefCounted:
	## A resolved ranged attack, recorded for the view to animate. Presentation
	## only — nothing in the simulation reads these back.
	var fx: int
	var fy: int
	var tx: int
	var ty: int
	var fired: int
	var hostile: bool     ## true = an invader shooting in, false = a defender shooting out

class MeleeImpact extends RefCounted:
	## Presentation-only record of a melee strike landing on a structure.
	var x: int
	var y: int
	var fired: int


class DeathFloat extends RefCounted:
	## Presentation-only casualty event. `count` is the exact number of represented
	## soldiers killed at this position; the view draws one skull per casualty.
	var x: int
	var y: int
	var fired: int
	var seed: int
	var count: int = 1


class LogLine extends RefCounted:
	var tick: int
	var text: String
	var kind: String                ## "", "bad", "good"

# ---------------------------------------------------------------------------
# Match state
# ---------------------------------------------------------------------------

var tick: int = 0
var over: bool = false
var player_defeated: bool = false
var winner_name: String = ""

var gold: int = 0
var pool := {"melee": 0, "ranged": 0}

var buildings: Array = []           ## Array[Building]
var _building_by_id := {}            ## id -> Building, authoritative O(1) lookup
var rubble: Array = []              ## Array[Vector2i]
var occupancy: PackedInt32Array     ## GRID*GRID, building id or 0
var purchases := {}                 ## building id -> count (§3.3)

var walls := {}                     ## dir -> Wall
var turrets := {}                   ## id -> Turret

var invaders: Array = []            ## Array[Invader]
var _invader_by_id := {}             ## id -> Invader
var _inside_buckets := {}              ## Vector2i bucket -> Array[Invader]
## Cached shared flow fields are keyed by building id + occupancy revision.
## They are presentation-independent simulation acceleration only.
var occupancy_revision: int = 0
var flow_field_cache: Dictionary = {}
var _outside_buckets := {}             ## Vector2i bucket -> Array[Invader]
var _outside_by_wall := {"N": [], "E": [], "S": [], "W": []}
var _sortie_index := {}
var _sortie_buckets := {}              ## Vector2i bucket -> Array[Sortie]
var sortied: Array = []             ## Array[Sortie]
var _sortie_by_id := {}              ## id -> Sortie
var pending: Array = []             ## Array[PendingAttack]
var rivals: Array = []              ## Array[Rival]
var camps: Array = []               ## Array[WarCamp]
var armies: Array = []              ## Array[Army]

var next_attack_tick: int = 0
var wave_no: int = 0
var gap: int = 0
var wave_size: int = 0

var click_window: int = -1          ## §5.4 per-second bucket
var click_count: int = 0

var shots: Array = []               ## Array[Shot] — drained by age each tick
var melee_impacts: Array = []       ## Array[MeleeImpact] — presentation-only structure-hit bursts
var death_floats: Array = []        ## Array[DeathFloat] — presentation-only invader death feedback

## Reused simultaneous-damage queues. Combat writers add numeric damage directly
## to targets, avoiding thousands of temporary attack Dictionaries per tick.
var _dirty_units: Array = []
var _dirty_invaders: Array = []
var _dirty_sorties: Array = []
var _dirty_buildings: Array = []

## Stationed-defender attack scheduler. Wall/turret defenders remain individual
## Units for exact combat semantics, but we no longer scan every defender every
## tick just to discover that next_attack is still in the future.
##
## _defender_ready: slot -> Array[Unit] whose next_attack <= tick and who have
## not yet found/fired at a target.
## _defender_due: absolute tick -> Dictionary(unit_id -> Unit). Dictionaries make
## re-registration overwrite stale entries cleanly when a sortie returns.
## _defender_due_tick_by_id is the validity token for lazy stale-entry removal.
var _defender_ready := {}
var _defender_due := {}
var _defender_due_tick_by_id := {}
var _defender_slot_by_id := {}
var _stationed_unit_by_id := {}

var log_lines: Array = []
## Bumped on every log_msg so the view can skip rebuilding the event log when
## nothing has changed. Read by Main._refresh().
var log_version: int = 0
## Per-tick rotation cursor for spreading invader strikes across a defended
## array. Keyed by the array's instance id. Cleared at the start of each step.
var _strike_cursor := {}
var stat_killed: int = 0
var stat_lost: int = 0
var stat_peak_gold: int = 0
var started: bool = false       ## first building has been placed; starts the pre-match countdown
var game_started: bool = false  ## simulation clock/production/attacks begin after the countdown
var start_countdown: int = 0    ## ticks remaining before BEGIN
var ai_skill: String = "Standard" ## Easy / Standard / Hard
var multiplayer_mode: bool = false
var human_player_ids: Dictionary = {0: true}
var custom_player_names: Dictionary = {}

# Network battle authority. In distributed network matches, the expensive
# physical simulation for every fiefdom (including Player 0) runs only on the
# peer assigned to that battlefield. All peers still execute deterministic
# strategic/economy code and travel bookkeeping so ids/commands remain aligned.
# Authority peers publish compact battlefield snapshots for remote presentation
# and army lifecycle; Player 0 is owned exclusively by the host peer.
var distributed_battle_authority: bool = false
var local_battle_authority: Dictionary = {}

var _uid: int = 1
var _rng := RandomNumberGenerator.new()


func _init(seed_value: int = 0, skill_level: String = "Standard") -> void:
	ai_skill = skill_level if skill_level in ["Easy", "Standard", "Hard"] else "Standard"
	_rng.seed = seed_value if seed_value != 0 else 20260918
	gold = UpConfigRef.START_GOLD
	occupancy = PackedInt32Array()
	occupancy.resize(GRID * GRID)
	occupancy.fill(0)
	for d in DIRS:
		var w := Wall.new(d)
		# Match-start invariant: every wall begins standing and fully eligible
		# to block attacks. Collapse state is only entered later by _step_walls()
		# after combat reduces wall melee HP below HP_COLLAPSE.
		w.collapsed = false
		w.cooldown = 0
		w.collapse_tick = -1
		walls[d] = w
		_append_grouped_stationed(w.melee, UpConfigRef.WALL_START_MELEE,
			UpDefs.DEFENDERS["infantry"], _wall_melee_slot(d))
	for t in TURRETS:
		turrets[t] = Turret.new(t)
	_rebuild_defender_attack_schedule()
	for b in UpDefs.BUILDINGS:
		purchases[b["id"]] = 0
	for i in 3:
		var c := WarCamp.new(); c.index = i; camps.append(c)
	var names := ["Stonehelm", "Redhold", "Blackfen"]
	var crests := [Color("d8a13a"), Color("b8342c"), Color("2f6f55")]
	var personalities := ["Aggressor", "Fortifier", "Opportunist"]
	for i in 3:
		var r := Rival.new()
		r.player_id = i + 1
		r.name = names[i]; r.crest = crests[i]; r.device = i; r.personality = personalities[i]
		r.gold = UpConfigRef.START_GOLD - int(UpDefs.BUILDINGS[0]["cost"])
		_rival_layout_init(r)
		for bd in UpDefs.BUILDINGS: r.purchases[bd["id"]] = 0
		r.purchases["homestead"] = 1
		var first_def := UpDefs.building("homestead")
		var first_rec := _rival_place_record(r, first_def, int(first_def["hp"]))
		if not first_rec.is_empty():
			r.buildings.append(first_rec)
		for d in DIRS:
			r.wall_hp[d] = UpConfigRef.WALL_START_MELEE * int(UpDefs.DEFENDERS["infantry"]["hp"])
			r.wall_ranged_hp[d] = 0
			r.wall_collapsed[d] = false
			r.wall_cooldown[d] = 0
			r.wall_collapse_tick[d] = -1
		for tid in TURRETS:
			r.turret_melee_hp[tid] = 0
			r.turret_ranged_hp[tid] = 0
			r.turret_next_melee[tid] = 0
			r.turret_next_ranged[tid] = 0
		for ci in 3:
			var rc := WarCamp.new(); rc.index = ci; r.camps.append(rc)
		r.next_build_tick = (2 + i) * TPS
		r.next_attack_tick = (28 + i * 8) * TPS
		r.next_action_tick = i
		rivals.append(r)
	# Random/environmental invasions are disabled; active attacks originate
	# from participant War Camps, so the environmental scheduler stays inactive.
	next_attack_tick = 1 << 60
	log_msg("%s AI selected. Place your first building." % ai_skill, "good")



func configure_human_players(ids: Array) -> void:
	multiplayer_mode = true
	human_player_ids.clear()
	for pid_value in ids:
		var pid: int = int(pid_value)
		if pid >= 0 and pid <= rivals.size():
			human_player_ids[pid] = true
	for r: Rival in rivals:
		if human_player_ids.has(r.player_id):
			_prepare_human_rival(r)


func configure_player_names(names: Dictionary) -> void:
	custom_player_names.clear()
	for pid_value in names.keys():
		var pid: int = int(pid_value)
		if pid < 0 or pid > rivals.size():
			continue
		var kingdom_name := str(names[pid_value]).strip_edges()
		if kingdom_name.is_empty():
			continue
		custom_player_names[pid] = kingdom_name
		if pid > 0:
			rivals[pid - 1].name = kingdom_name


func _prepare_human_rival(r: Rival) -> void:
	r.defeated = false
	r.gold = UpConfigRef.START_GOLD
	r.pool["melee"] = 0
	r.pool["ranged"] = 0
	r.buildings.clear()
	r.purchases.clear()
	for bd in UpDefs.BUILDINGS:
		r.purchases[bd["id"]] = 0
	_rival_layout_init(r)
	for c: WarCamp in r.camps:
		c.melee = 0
		c.ranged = 0
	for d in DIRS:
		r.wall_hp[d] = UpConfigRef.WALL_START_MELEE * int(UpDefs.DEFENDERS["infantry"]["hp"])
		r.wall_ranged_hp[d] = 0
		r.wall_collapsed[d] = false
		r.wall_cooldown[d] = 0
		r.wall_collapse_tick[d] = -1
		r.wall_next_melee[d] = 0
		r.wall_next_ranged[d] = 0
	for tid in TURRETS:
		r.turret_melee_hp[tid] = 0
		r.turret_ranged_hp[tid] = 0
		r.turret_next_melee[tid] = 0
		r.turret_next_ranged[tid] = 0
	r.invaders.clear()
	r.shots.clear()
	r.melee_impacts.clear()
	r.death_floats.clear()
	r.recon_unlocked = false


func is_human_player(pid: int) -> bool:
	return human_player_ids.has(pid)


func configure_battle_authority(local_player_ids: Array) -> void:
	distributed_battle_authority = true
	local_battle_authority.clear()
	for value in local_player_ids:
		local_battle_authority[int(value)] = true


func owns_battle_simulation(pid: int) -> bool:
	# Every battlefield, including Player 0's home fiefdom, follows the same
	# distributed-authority rule. In solo/non-network play authority is local.
	return not distributed_battle_authority or local_battle_authority.has(pid)


func player_name(pid: int) -> String:
	return _player_name(pid)


func player_is_defeated(pid: int) -> bool:
	# Public per-player terminal-state query for the presentation/network layer.
	# Player 0 stores defeat state directly; joined human players live in the
	# Rival array and must be treated as locally eliminated when their own rival
	# fiefdom is defeated even though the overall multiplayer match continues.
	if pid == 0:
		# An empty building list is normal before the player places their first
		# structure.  Only the explicit defeat flag represents a conquered
		# Player 0 fiefdom; _check_defeats() sets it when the final established
		# building is actually destroyed after play has begun.
		return player_defeated
	if pid < 1 or pid > rivals.size():
		return true
	return rivals[pid - 1].defeated


func player_gold(pid: int) -> int:
	return gold if pid == 0 else rivals[pid - 1].gold


func player_pool(pid: int) -> Dictionary:
	return pool if pid == 0 else rivals[pid - 1].pool


func player_camps(pid: int) -> Array:
	return camps if pid == 0 else rivals[pid - 1].camps


func player_building_records(pid: int) -> Array:
	return buildings if pid == 0 else rivals[pid - 1].buildings


func player_rate_of(pid: int, res: String) -> int:
	if pid == 0:
		return rate_of(res)
	return _ai_rate(rivals[pid - 1], res)


func player_building_type_count(pid: int, type_id: String) -> int:
	if pid == 0:
		return building_type_count(type_id)
	var n: int = 0
	for rec in rivals[pid - 1].buildings:
		if str(rec["def"]["id"]) == type_id:
			n += 1
	return n


func player_build_cost(pid: int, def: Dictionary) -> int:
	return build_cost(def) if pid == 0 else _ai_cost(rivals[pid - 1], def)


func player_meets_prereq(pid: int, def: Dictionary) -> bool:
	if pid == 0:
		return meets_prereq(def)
	var req = def.get("req")
	return req == null or _ai_rate(rivals[pid - 1], str(req["res"])) >= int(req["rate"])


func player_can_build(pid: int, def: Dictionary) -> bool:
	return player_gold(pid) >= player_build_cost(pid, def) and player_meets_prereq(pid, def)


func player_has_building(pid: int) -> bool:
	return not player_building_records(pid).is_empty()


func _maybe_start_multiplayer_countdown() -> void:
	if not multiplayer_mode or started:
		return
	for pid_value in human_player_ids.keys():
		if not player_has_building(int(pid_value)):
			return
	started = true
	start_countdown = UpConfigRef.START_COUNTDOWN
	log_msg("All human fiefdoms are ready — battle begins in 10 seconds.", "good")


func _next_id() -> int:
	_uid += 1
	return _uid


func _new_invader() -> Invader:
	# Factory used by the rival battlefield module so Invader construction stays
	# owned by the authoritative match class.
	return Invader.new()

# ---------------------------------------------------------------------------
# Queries
# ---------------------------------------------------------------------------

## Total per-second production of a resource across every standing building.
func rate_of(res: String) -> int:
	var r := 0
	for b: Building in buildings:
		r += int(b.def.get(res, 0))
	return r

## §3.3 escalating repeat cost.
func build_cost(def: Dictionary) -> int:
	var c: int = def["cost"]
	for i in int(purchases[def["id"]]):
		c = c * UpConfigRef.COST_GROWTH_NUM / UpConfigRef.COST_GROWTH_DEN
	return c

## §3.2 production-rate prerequisite. Checked at placement only.
func meets_prereq(def: Dictionary) -> bool:
	var req = def.get("req")
	if req == null:
		return true
	return rate_of(req["res"]) >= int(req["rate"])

func can_build(def: Dictionary) -> bool:
	return gold >= build_cost(def) and meets_prereq(def)

## §7.3 wall state. Depends on HP *and* the collapsed flag — the two tables
## never overlap, so no HP value is ambiguous.
func wall_state(w: Wall) -> String:
	var h := w.hp()
	if w.collapsed:
		if w.collapse_tick >= 0 and tick - w.collapse_tick < UpConfigRef.WALL_COLLAPSE_ANIM_TICKS:
			return "collapsing"
		if h >= UpConfigRef.HP_PARTIAL:
			return "half_rebuilt"
		return "rubble"
	if h >= UpConfigRef.HP_FULL: return "full"
	if h >= UpConfigRef.HP_PARTIAL: return "partial"
	if h >= UpConfigRef.HP_COLLAPSE: return "crumbling"
	return "breach"

func wall_blocks(w: Wall) -> bool:
	var s := wall_state(w)
	return s == "full" or s == "partial" or s == "crumbling"

func day_number() -> int:
	return tick / UpConfigRef.DAY_TICKS + 1

## §1.4 which phase of the day cycle we are in. Ambience only (§14.2).
func day_phase() -> String:
	var t := tick % UpConfigRef.DAY_TICKS
	if t < UpConfigRef.PHASE_DAY: return "day"
	t -= UpConfigRef.PHASE_DAY
	if t < UpConfigRef.PHASE_TWILIGHT: return "twilight"
	t -= UpConfigRef.PHASE_TWILIGHT
	if t < UpConfigRef.PHASE_NIGHT: return "night"
	return "dawn"

func find_building(id: int) -> Building:
	return _building_by_id.get(id)

func find_sortie(id: int) -> Sortie:
	return _sortie_by_id.get(id)

func _human_can_act() -> bool:
	return not over and not player_defeated


func _alive_player_ids() -> Array:
	var ids: Array = []
	# Player 0's authoritative elimination flag is the only thing that removes
	# the host fiefdom from the active chain.  A replicated client may briefly
	# have an incomplete/desynchronized building array; treating that as death
	# made a still-playing host silently disappear from human target lists.
	if not player_defeated:
		ids.append(0)
	for r: Rival in rivals:
		if not r.defeated:
			ids.append(r.player_id)
	return ids


func active_fiefdom_chain() -> Array:
	# Permanent chain order is player-id order. Eliminated fiefdoms are removed,
	# and the survivors close the circle without otherwise changing order.
	return _alive_player_ids()


func chain_distance_d() -> int:
	# D = ceil(ceil(active_fiefdoms / 3) / 2), exactly as defined by the design.
	var n := active_fiefdom_chain().size()
	if n <= 1:
		return 0
	var thirds := (n + 2) / 3
	return (thirds + 1) / 2


func chain_distance_links(attacker: int, target: int) -> int:
	if attacker == target:
		return 0
	var chain := active_fiefdom_chain()
	var n := chain.size()
	if n <= 1:
		return -1
	var ai := chain.find(attacker)
	var ti := chain.find(target)
	if ai < 0 or ti < 0:
		return -1
	var clockwise := absi(ti - ai)
	return mini(clockwise, n - clockwise)


func travel_seconds_between(attacker: int, target: int) -> int:
	var links := chain_distance_links(attacker, target)
	if links <= 0:
		return 0
	var d := chain_distance_d()
	if links <= d:
		return UpConfigRef.TRAVEL_NEAR_SECONDS
	if links <= 2 * d:
		return UpConfigRef.TRAVEL_MID_SECONDS
	return UpConfigRef.TRAVEL_FAR_SECONDS


func travel_ticks_between(attacker: int, target: int) -> int:
	return travel_seconds_between(attacker, target) * TPS


func surrounding_rival_indices_by_distance(origin_pid: int = 0) -> Array:
	# Active rivals first, closest to the viewing player's fiefdom first.
	# Equal-distance ties retain circular-chain order. The viewer's own rival row
	# is omitted; Ironcrest is represented separately for nonzero players.
	var active: Array = []
	var defeated: Array = []
	for i in rivals.size():
		var r: Rival = rivals[i]
		if r.player_id == origin_pid:
			continue
		if r.defeated:
			defeated.append(i)
		else:
			active.append(i)
	active.sort_custom(func(a, b):
		var ra: Rival = rivals[int(a)]
		var rb: Rival = rivals[int(b)]
		var da: int = chain_distance_links(origin_pid, ra.player_id)
		var db: int = chain_distance_links(origin_pid, rb.player_id)
		if da != db:
			return da < db
		return ra.player_id < rb.player_id
	)
	active.append_array(defeated)
	return active


func _check_eliminations_and_victory() -> void:
	if not game_started or over:
		return

	if owns_battle_simulation(0) and not player_defeated and buildings.is_empty():
		player_defeated = true
		log_msg("%s has been conquered." % _player_name(0), "bad")
		for a: Army in armies:
			if a.attacker == 0 and a.phase != "return":
				a.melee_hp = 0
				a.ranged_hp = 0
		# In a network match Ironcrest is just one participant. The match
		# continues until only one fiefdom remains.
		if not multiplayer_mode:
			winner_name = ""
			over = true
			return

	var alive := _alive_player_ids()
	if alive.size() == 1:
		winner_name = _player_name(int(alive[0]))
		over = true
		log_msg("%s wins the match." % winner_name, "good")
	elif alive.is_empty():
		winner_name = ""
		over = true
		log_msg("All fiefdoms were destroyed. The match ends in a draw.", "")


# ---------------------------------------------------------------------------
# Actions — discrete, serializable requests (§16.2)
# The client says what the player did; the simulation decides what it produced.
# ---------------------------------------------------------------------------

## §5.4 per-second click bucket. The first CLICK_CAP clicks in a second
## register; the rest are discarded, not queued.
func _consume_click() -> bool:
	var sec := tick / TPS
	if sec != click_window:
		click_window = sec
		click_count = 0
	if click_count >= UpConfigRef.CLICK_CAP:
		return false
	click_count += 1
	return true

func building_type_count(type_id: String) -> int:
	var count := 0
	for b: Building in buildings:
		if str(b.def["id"]) == type_id:
			count += 1
	return count


## Returns the exact cumulative gain from clicking any standing building of this
## type. One click collects the click-production of every active building of the
## same type in the fiefdom.
func click_gain_for_building(building_id: int) -> Dictionary:
	var b := find_building(building_id)
	if b == null:
		return {"gold": 0, "melee": 0, "ranged": 0, "count": 0}
	var type_id := str(b.def["id"])
	var count := building_type_count(type_id)
	return {
		"gold": int(b.def["gold"]) * UpConfigRef.CLICK_PCT / 1000 * count,
		"melee": int(b.def["melee"]) * UpConfigRef.CLICK_PCT / 1000 * count,
		"ranged": int(b.def["ranged"]) * UpConfigRef.CLICK_PCT / 1000 * count,
		"count": count,
	}


## §5.2 one production click collects 10% of per-second output from every
## active building of the clicked building's type.
## Never advances, resets or completes any production cycle.
func act_click_building(building_id: int) -> bool:
	if not _human_can_act() or not game_started: return false
	var b := find_building(building_id)
	if b == null: return false
	if not _consume_click(): return false
	var gain := click_gain_for_building(building_id)
	gold += int(gain["gold"])
	pool["melee"] += int(gain["melee"])
	pool["ranged"] += int(gain["ranged"])
	b.flash = 6
	return true

## §5.3 arm a soldier type, click a destination: 2% of that pool, rounded up.
func act_transfer(cat: String, dest_type: String, dest_id: String) -> bool:
	if not _human_can_act() or not game_started: return false
	if cat != "melee" and cat != "ranged": return false
	if dest_type != "wall" and dest_type != "turret" and dest_type != "camp": return false
	if not pool.has(cat): return false

	var wall: Wall = null
	var turret: Turret = null
	var camp: WarCamp = null
	if dest_type == "wall":
		if not walls.has(dest_id): return false
		wall = walls[dest_id]
		# §6.3 ranged cannot stand on a collapsed wall.
		if cat == "ranged" and wall.collapsed: return false
	elif dest_type == "turret":
		if not turrets.has(dest_id): return false
		turret = turrets[dest_id]
		if turret.destroyed: return false
	else:
		if not dest_id.is_valid_int(): return false
		var ci := int(dest_id)
		if ci < 0 or ci >= camps.size(): return false
		camp = camps[ci]

	var whole: int = int(pool[cat]) / S
	if whole <= 0: return false

	# §7.3: during the 10-second post-collapse cooldown, melee transfer clicks
	# are accepted by the click bucket but intentionally wasted.
	if dest_type == "wall" and wall.collapsed and wall.cooldown > 0:
		_consume_click()
		return false

	if not _consume_click(): return false
	var n := (whole * UpConfigRef.TRANSFER_PCT + 999) / 1000
	n = min(n, whole)
	pool[cat] -= n * S

	var def: Dictionary = UpDefs.DEFENDERS["infantry"] if cat == "melee" else UpDefs.DEFENDERS["archer"]
	if dest_type == "camp":
		if cat == "melee": camp.melee += n
		else: camp.ranged += n
		return true

	var target: Array = wall[cat] if dest_type == "wall" else turret[cat]
	var slot: String = _defender_slot(dest_type, dest_id, cat)
	_append_grouped_stationed(target, n, def, slot)
	_rebalance_stationed_slot(target, slot)
	return true

## §9 commit an entire War Camp to a specific rival wall. No partial deployment.
func act_deploy_camp(camp_index: int, rival_index: int, wall_dir: String) -> bool:
	if not _human_can_act() or not game_started: return false
	if camp_index < 0 or camp_index >= camps.size(): return false
	if rival_index < 0 or rival_index >= rivals.size(): return false
	if not (wall_dir in DIRS): return false
	var c: WarCamp = camps[camp_index]
	if c.empty(): return false
	var r: Rival = rivals[rival_index]
	if r.defeated: return false
	# Sending a War Camp permanently unlocks reconnaissance on this fiefdom.
	r.recon_unlocked = true
	var total_sent := c.total()
	_launch_army(0, r.player_id, camp_index, wall_dir, c.melee, c.ranged)
	c.melee = 0; c.ranged = 0
	log_msg("War Camp %d marches on %s's %s wall — %d soldiers." % [camp_index + 1, r.name, dir_name(wall_dir), total_sent], "good")
	return true

func fiefdoms_remaining() -> int:
	var n := 0 if (started and buildings.is_empty()) else 1
	for r: Rival in rivals:
		if not r.defeated: n += 1
	return n

func rival_building_count(r: Rival) -> int:
	return r.buildings.size()

## §3.1 place a building. Any overlapped building is destroyed and replaced.
func _invalidate_home_flow_fields() -> void:
	occupancy_revision += 1
	flow_field_cache.clear()


func _invalidate_rival_flow_fields(r: Rival) -> void:
	r.layout_revision += 1
	r.flow_field_cache.clear()


func act_place(building_id: String, ox: int, oy: int, rot: int) -> bool:
	if not _human_can_act(): return false
	if multiplayer_mode and not started and not buildings.is_empty(): return false
	# Once the first structure is down, construction is locked until BEGIN.
	# This makes the opening structure a real commitment rather than allowing a
	# ten-second pre-build burst.
	if started and not game_started: return false
	var def := UpDefs.building(building_id)
	if def.is_empty(): return false
	if rot < 0 or rot > 3: return false
	var cells := rotate_cells(def["cells"], rot)
	var placed: Array = []
	for c in cells:
		var x: int = c.x + ox
		var y: int = c.y + oy
		if x < 0 or y < 0 or x >= GRID or y >= GRID: return false
		placed.append(Vector2i(x, y))
	if not can_build(def): return false

	gold -= build_cost(def)
	purchases[def["id"]] = int(purchases[def["id"]]) + 1

	var hit := {}
	for c in placed:
		var o := occupancy[c.y * GRID + c.x]
		if o != 0: hit[o] = true
	for id in hit.keys():
		_destroy_building(int(id), true)

	var b := Building.new(_next_id(), def, placed)
	buildings.append(b)
	_building_by_id[b.id] = b
	if not started:
		if multiplayer_mode:
			_maybe_start_multiplayer_countdown()
		else:
			started = true
			start_countdown = UpConfigRef.START_COUNTDOWN
			log_msg("First building placed — battle begins in 10 seconds.", "good")
	for c in placed:
		occupancy[c.y * GRID + c.x] = b.id
	_invalidate_home_flow_fields()
	return true


func _rival_find_record_by_rid(r: Rival, rid: int) -> Dictionary:
	for rec in r.buildings:
		if int(rec.get("rid", -1)) == rid:
			return rec
	return {}


func _rival_click_gain(r: Rival, rid: int) -> Dictionary:
	var rec: Dictionary = _rival_find_record_by_rid(r, rid)
	if rec.is_empty():
		return {"gold": 0, "melee": 0, "ranged": 0, "count": 0}
	var type_id: String = str(rec["def"]["id"])
	var count: int = player_building_type_count(r.player_id, type_id)
	return {
		"gold": int(rec["def"]["gold"]) * UpConfigRef.CLICK_PCT / 1000 * count,
		"melee": int(rec["def"]["melee"]) * UpConfigRef.CLICK_PCT / 1000 * count,
		"ranged": int(rec["def"]["ranged"]) * UpConfigRef.CLICK_PCT / 1000 * count,
		"count": count,
	}


func _rival_act_click_building(r: Rival, rid: int) -> bool:
	if r.defeated or not game_started:
		return false
	var rec: Dictionary = _rival_find_record_by_rid(r, rid)
	if rec.is_empty() or not _ai_consume_click(r):
		return false
	var gain: Dictionary = _rival_click_gain(r, rid)
	r.gold += int(gain["gold"])
	r.pool["melee"] += int(gain["melee"])
	r.pool["ranged"] += int(gain["ranged"])
	rec["flash"] = 6
	return true


func _rival_manual_place(r: Rival, building_id: String, ox: int, oy: int, rot: int) -> bool:
	if r.defeated:
		return false
	if multiplayer_mode and not started and not r.buildings.is_empty():
		return false
	if started and not game_started:
		return false
	var def: Dictionary = UpDefs.building(building_id)
	if def.is_empty() or rot < 0 or rot > 3 or not player_can_build(r.player_id, def):
		return false
	var shape: Array = rotate_cells(def["cells"], rot)
	var placed: Array = []
	for off: Vector2i in shape:
		var x: int = ox + off.x
		var y: int = oy + off.y
		if x < 0 or y < 0 or x >= GRID or y >= GRID:
			return false
		placed.append(Vector2i(x, y))

	var hit_indices: Dictionary = {}
	for cell: Vector2i in placed:
		var marker_value: int = int(r.layout_occupancy[cell.y * GRID + cell.x])
		if marker_value > 0:
			hit_indices[marker_value - 1] = true
	var indices: Array = hit_indices.keys()
	indices.sort()
	indices.reverse()
	for idx_value in indices:
		var idx: int = int(idx_value)
		if idx >= 0 and idx < r.buildings.size():
			var old_rec: Dictionary = r.buildings[idx]
			var old_bid: String = str(old_rec["def"]["id"])
			r.purchases[old_bid] = maxi(0, int(r.purchases.get(old_bid, 0)) - 1)
			r.buildings.remove_at(idx)
	_rival_rebuild_layout_occupancy(r)

	r.gold -= _ai_cost(r, def)
	r.purchases[building_id] = int(r.purchases.get(building_id, 0)) + 1
	var rec := {"rid": _next_id(), "def": def, "hp": int(def["hp"]), "flash": 0,
		"x": ox, "y": oy, "rot": rot, "cells": placed}
	r.buildings.append(rec)
	_rival_rebuild_layout_occupancy(r)
	_maybe_start_multiplayer_countdown()
	return true


func _rival_manual_transfer(r: Rival, cat: String, dest_type: String, dest_id: String) -> bool:
	if r.defeated or not game_started:
		return false
	if cat != "melee" and cat != "ranged":
		return false
	if dest_type != "wall" and dest_type != "turret" and dest_type != "camp":
		return false
	var whole: int = int(r.pool[cat]) / S
	if whole <= 0:
		return false
	if dest_type == "wall":
		if not (dest_id in DIRS):
			return false
		if cat == "ranged" and bool(r.wall_collapsed[dest_id]):
			return false
		if bool(r.wall_collapsed[dest_id]) and int(r.wall_cooldown[dest_id]) > 0:
			_ai_consume_click(r)
			return false
	elif dest_type == "turret":
		if not (dest_id in TURRETS):
			return false
		var adj: Array = TURRET_WALLS[dest_id]
		var a_down: bool = bool(r.wall_collapsed[adj[0]]) and int(r.wall_hp[adj[0]]) <= 0
		var b_down: bool = bool(r.wall_collapsed[adj[1]]) and int(r.wall_hp[adj[1]]) <= 0
		if a_down and b_down:
			return false
	if not _ai_consume_click(r):
		return false
	var n: int = mini((whole * UpConfigRef.TRANSFER_PCT + 999) / 1000, whole)
	var hp_each: int = int(UpDefs.DEFENDERS["infantry"]["hp"]) if cat == "melee" else int(UpDefs.DEFENDERS["archer"]["hp"])
	if dest_type == "wall":
		r.pool[cat] -= n * S
		if cat == "melee":
			r.wall_hp[dest_id] = int(r.wall_hp[dest_id]) + n * hp_each
		else:
			r.wall_ranged_hp[dest_id] = int(r.wall_ranged_hp[dest_id]) + n * hp_each
		return true
	if dest_type == "turret":
		r.pool[cat] -= n * S
		if cat == "melee":
			r.turret_melee_hp[dest_id] = int(r.turret_melee_hp[dest_id]) + n * hp_each
		else:
			r.turret_ranged_hp[dest_id] = int(r.turret_ranged_hp[dest_id]) + n * hp_each
		return true
	if not dest_id.is_valid_int():
		return false
	var ci: int = int(dest_id)
	if ci < 0 or ci >= r.camps.size():
		return false
	r.pool[cat] -= n * S
	var camp: WarCamp = r.camps[ci]
	if cat == "melee":
		camp.melee += n
	else:
		camp.ranged += n
	return true


func _rival_manual_deploy(r: Rival, camp_index: int, target_pid: int, wall_dir: String) -> bool:
	if r.defeated or not game_started or target_pid == r.player_id or not _player_alive(target_pid):
		return false
	if camp_index < 0 or camp_index >= r.camps.size() or not (wall_dir in DIRS):
		return false
	var camp: WarCamp = r.camps[camp_index]
	if camp.empty():
		return false
	var total_sent: int = camp.total()
	_launch_army(r.player_id, target_pid, camp_index, wall_dir, camp.melee, camp.ranged)
	camp.melee = 0
	camp.ranged = 0
	if target_pid > 0:
		rivals[target_pid - 1].recon_unlocked = true
	log_msg("%s's War Camp %d marches on %s's %s wall — %d soldiers." % [
		r.name, camp_index + 1, _player_name(target_pid), dir_name(wall_dir), total_sent], "")
	return true


func apply_player_action(pid: int, action: String, args: Array) -> bool:
	if pid < 0 or pid > rivals.size() or not is_human_player(pid):
		return false
	match action:
		"click_building":
			return act_click_building(int(args[0])) if pid == 0 else _rival_act_click_building(rivals[pid - 1], int(args[0]))
		"place":
			return act_place(str(args[0]), int(args[1]), int(args[2]), int(args[3])) if pid == 0 else _rival_manual_place(rivals[pid - 1], str(args[0]), int(args[1]), int(args[2]), int(args[3]))
		"transfer":
			return act_transfer(str(args[0]), str(args[1]), str(args[2])) if pid == 0 else _rival_manual_transfer(rivals[pid - 1], str(args[0]), str(args[1]), str(args[2]))
		"deploy":
			var camp_index: int = int(args[0])
			var target_pid: int = int(args[1])
			var wall_dir: String = str(args[2])
			if pid == 0:
				if target_pid <= 0:
					return false
				return act_deploy_camp(camp_index, target_pid - 1, wall_dir)
			return _rival_manual_deploy(rivals[pid - 1], camp_index, target_pid, wall_dir)
	return false



static func rotate_cells(cells: Array, rot: int) -> Array:
	var out: Array = []
	for c in cells:
		out.append(Vector2i(int(c[0]), int(c[1])))
	for i in rot:
		var r: Array = []
		for c in out:
			r.append(Vector2i(-c.y, c.x))
		out = r
	var mx := 999
	var my := 999
	for c in out:
		mx = min(mx, c.x); my = min(my, c.y)
	var norm: Array = []
	for c in out:
		norm.append(Vector2i(c.x - mx, c.y - my))
	return norm

# ---------------------------------------------------------------------------
# Destruction
# ---------------------------------------------------------------------------

func _destroy_building(id: int, replaced: bool) -> void:
	var idx := -1
	for i in buildings.size():
		if buildings[i].id == id:
			idx = i; break
	if idx < 0: return
	var b: Building = buildings[idx]
	buildings.remove_at(idx)
	_building_by_id.erase(id)
	for c in b.cells:
		if occupancy[c.y * GRID + c.x] == id:
			occupancy[c.y * GRID + c.x] = 0
		rubble.append(c)
	# §3.3 destruction decrements the repeat-purchase counter — including
	# deliberate replacement. Never leaves the player ahead, only restored.
	purchases[b.def["id"]] = max(0, int(purchases[b.def["id"]]) - 1)
	if not replaced:
		stat_lost += 1
		log_msg("%s destroyed." % b.def["name"], "bad")
	for inv: Invader in invaders:
		if inv.tgt_kind == "b" and inv.tgt_id == id:
			inv.tgt_kind = ""; inv.tgt_id = -1

# ---------------------------------------------------------------------------
# Geometry — integer only
# ---------------------------------------------------------------------------

func wall_point(d: String) -> Vector2i:
	return WallCombatSystem.wall_point(d)

func wall_attack_point(d: String, lane: int) -> Vector2i:
	return WallCombatSystem.wall_attack_point(d, lane)

func invader_wall_contact_point(d: String, lane: int) -> Vector2i:
	return WallCombatSystem.invader_wall_contact_point(d, lane)

func invader_melee_wall_contact_point(d: String, lane: int) -> Vector2i:
	return WallCombatSystem.invader_melee_wall_contact_point(d, lane)

func melee_wall_impact_point(d: String, lane: int) -> Vector2i:
	return WallCombatSystem.melee_wall_impact_point(d, lane)

func invader_melee_ready_at_wall(inv: Invader, d: String) -> bool:
	return WallCombatSystem.invader_melee_ready_at_wall(self, inv, d)

func invader_entry_point(d: String, lane: int) -> Vector2i:
	return WallCombatSystem.invader_entry_point(d, lane)

func invader_outward_dir(d: String) -> Vector2i:
	return WallCombatSystem.invader_outward_dir(d)

func invader_horde_contact_point(inv: Invader) -> Vector2i:
	return WallCombatSystem.invader_horde_contact_point(inv)

func invader_combat_active(inv: Invader) -> bool:
	return WallCombatSystem.invader_combat_active(tick, inv)

func turret_point(id: String) -> Vector2i:
	return WallCombatSystem.turret_point(id)

static func dist_sq(ax: int, ay: int, bx: int, by: int) -> int:
	var dx := ax - bx
	var dy := ay - by
	return dx * dx + dy * dy

## §8 the standard spatial tie-break: first candidate clockwise from the unit's
## current heading. Exact integer comparison — no trigonometry, so it resolves
## identically on every machine.
static func _floor_div(v: int, d: int) -> int:
	if v >= 0: return v / d
	return -((-v + d - 1) / d)

static func _more_clockwise(hx: int, hy: int, ax: int, ay: int, bx: int, by: int) -> bool:
	# y grows downward, so a positive cross product means "clockwise of".
	var half_a := 0 if (hx * ay - hy * ax) > 0 else 1
	var half_b := 0 if (hx * by - hy * bx) > 0 else 1
	if half_a != half_b:
		return half_a < half_b
	return (ax * by - ay * bx) > 0

func _pick_clockwise(hx: int, hy: int, fx: int, fy: int, cands: Array) -> Dictionary:
	if hx == 0 and hy == 0: hx = 0; hy = 1
	var best: Dictionary = cands[0]
	for i in range(1, cands.size()):
		var c: Dictionary = cands[i]
		if _more_clockwise(hx, hy,
				int(best["px"]) - fx, int(best["py"]) - fy,
				int(c["px"]) - fx, int(c["py"]) - fy):
			continue
		best = c
	return best

static func _isqrt(v: int) -> int:
	if v <= 0: return 0
	var r := int(sqrt(float(v)))
	while r * r > v: r -= 1
	while (r + 1) * (r + 1) <= v: r += 1
	return r

# ---------------------------------------------------------------------------
# Attack scheduling (§7.5)
# ---------------------------------------------------------------------------

func _schedule_attack() -> void:
	wave_no += 1
	var elapsed_minutes: int = tick / (60 * TPS)

	# Pressure is authored from match time only. It never reads player troop count,
	# wall HP, production, or any other measure of how well the fiefdom is doing.
	# Army size remains uncapped, while frequency rises gradually to a practical
	# floor instead of compounding every wave.
	wave_size = (UpConfigRef.SIZE_START
		+ (wave_no - 1) * UpConfigRef.SIZE_GROWTH_PER_WAVE
		+ elapsed_minutes * UpConfigRef.SIZE_GROWTH_PER_MINUTE)
	gap = max(UpConfigRef.GAP_FLOOR,
		UpConfigRef.GAP_START - elapsed_minutes * UpConfigRef.GAP_REDUCTION_PER_MINUTE)

	var p := PendingAttack.new()
	p.dir = DIRS[_rng.randi_range(0, 3)]
	p.size = max(6, wave_size)
	p.arrives = tick + _rng.randi_range(UpConfigRef.WARN_MIN, UpConfigRef.WARN_MAX)
	p.wave = wave_no
	p.force_color = INVADER_FORCE_COLORS[(wave_no - 1) % INVADER_FORCE_COLORS.size()]
	p.device = (wave_no - 1) % 6
	pending.append(p)
	log_msg("%d invaders sighted — %s wall." % [p.size, dir_name(p.dir)], "bad")

	next_attack_tick = tick + gap

static func dir_name(d: String) -> String:
	return {"N": "North", "E": "East", "S": "South", "W": "West"}[d]

func _spawn_wave(p: PendingAttack) -> void:
	# Army size is uncapped, but simulation groups are bounded. As an army grows,
	# each group simply represents more soldiers.
	var live_groups: int = 0
	for existing: Invader in invaders:
		if existing.hp > 0:
			live_groups += 1
	var group_budget: int = clampi(UpConfigRef.MAX_INVADER_GROUPS_PER_BATTLEFIELD - live_groups, 1, UpConfigRef.MAX_GROUPS_PER_ARMY)
	var both_types: bool = p.melee > 0 and p.ranged > 0
	var effective_budget: int = maxi(1, group_budget - (1 if both_types and group_budget > 1 else 0))
	var dynamic_group_size := maxi(UpConfigRef.INVADER_GROUP_SIZE,
		int(ceil(float(maxi(1, p.size)) / float(effective_budget))))
	var group_specs: Array = []
	var melee_left := p.melee
	var ranged_left := p.ranged
	while melee_left > 0:
		var n := mini(dynamic_group_size, melee_left)
		group_specs.append({"count": n, "def": UpDefs.INVADERS["raider"]})
		melee_left -= n
	while ranged_left > 0:
		var n := mini(dynamic_group_size, ranged_left)
		group_specs.append({"count": n, "def": UpDefs.INVADERS["marksman"]})
		ranged_left -= n

	var lane_span := GRID * CELL - CELL
	var group_total := group_specs.size()
	for gi in group_total:
		var spec: Dictionary = group_specs[gi]
		var def: Dictionary = spec["def"]
		var count: int = int(spec["count"])
		var inv := Invader.new()
		inv.id = _next_id()
		inv.def = def
		inv.member_hp = int(def["hp"])
		inv.group_size = count
		inv.hp = count * inv.member_hp
		inv.wall = p.dir
		inv.force_color = p.force_color
		inv.army_id = p.army_id
		inv.active_tick = p.arrives

		var lane := GRID * CELL / 2
		if group_total > 1:
			lane = CELL / 2 + gi * lane_span / (group_total - 1)
		lane += _rng.randi_range(-CELL / 5, CELL / 5)
		inv.wall_lane = clampi(lane, CELL, GRID * CELL - CELL)

		# The banner countdown is time until the FIRST troop in the army can engage,
		# not time until every troop reaches the stone. If this army contains ranged
		# attackers, T-0 is when its leading marksmen enter their legal wall firing
		# envelope; infantry from the same army is still behind that firing line and
		# continues to the wall after the banner expires. Melee-only armies still hit
		# the wall at T-0.
		var preview_ticks := maxi(0, p.arrives - tick)
		var first_engagement_standoff: int = UpConfigRef.INVADER_WALL_RANGED_MAX if p.ranged > 0 else 0
		var approach_dist: int = first_engagement_standoff + preview_ticks * UpConfigRef.PREVIEW_APPROACH_SPEED
		var contact := invader_wall_contact_point(p.dir, inv.wall_lane)
		var outward := invader_outward_dir(p.dir)
		inv.x = contact.x + outward.x * approach_dist
		inv.y = contact.y + outward.y * approach_dist
		inv.prev_x = inv.x
		inv.prev_y = inv.y

		inv.last_progress_x = inv.x
		inv.last_progress_y = inv.y
		invaders.append(inv)
		_invader_by_id[inv.id] = inv
		_index_invader(inv)


# ---------------------------------------------------------------------------
# Main step
# ---------------------------------------------------------------------------

func _snapshot_mobile_positions() -> void:
	# Keep simulation fixed at 10 TPS while presentation interpolates smoothly.
	# These fields never affect targeting, damage, movement or any game outcome.
	for inv: Invader in invaders:
		inv.prev_x = inv.x
		inv.prev_y = inv.y
	for s: Sortie in sortied:
		s.prev_x = s.x
		s.prev_y = s.y


func step() -> void:
	if over: return

	# The first placed building starts a real 10-second pre-match countdown.
	# The gameplay clock, production, attacks and combat remain frozen until BEGIN.
	if not game_started:
		if started:
			if start_countdown > 0:
				start_countdown -= 1
			if start_countdown <= 0:
				game_started = true
				log_msg("BEGIN", "good")
		return

	tick += 1
	var owns_home_battle: bool = owns_battle_simulation(0)
	if owns_home_battle:
		_snapshot_mobile_positions()
		_advance_defender_attack_schedule()

	# §4 production is one exact deposit per second. This preserves every fixed-
	# point unit even when a rate is not divisible by TPS.
	if tick % TPS == 0:
		for b: Building in buildings:
			gold += int(b.def["gold"])
			pool["melee"] += int(b.def["melee"])
			pool["ranged"] += int(b.def["ranged"])
	for b: Building in buildings:
		if b.flash > 0: b.flash -= 1
	stat_peak_gold = max(stat_peak_gold, gold)

	# Incoming armies to Player 0 are advanced only by the peer that owns
	# Player 0's battlefield (normally the host). Other peers receive this state
	# through the same battle snapshot path used for every other fiefdom.
	if owns_home_battle:
		for i in range(pending.size() - 1, -1, -1):
			var p: PendingAttack = pending[i]
			if not p.spawned_visible:
				_spawn_wave(p)
				p.spawned_visible = true
			if tick >= p.arrives:
				if not p.spawned_visible:
					_spawn_wave(p)
					p.spawned_visible = true
				_mark_army_human_field(p.army_id)
				if p.source_player > 0:
					log_msg("%s's War Camp reached the %s wall with %d soldiers." % [
						rivals[p.source_player - 1].name, dir_name(p.dir), p.size], "bad")
				pending.remove_at(i)

	_step_ai_fiefdoms()

	if owns_home_battle:
		for i in range(shots.size() - 1, -1, -1):
			if tick - shots[i].fired > UpConfigRef.ARROW_FLIGHT:
				shots.remove_at(i)
		for i in range(melee_impacts.size() - 1, -1, -1):
			if tick - melee_impacts[i].fired > UpConfigRef.MELEE_IMPACT_TICKS:
				melee_impacts.remove_at(i)
		for i in range(death_floats.size() - 1, -1, -1):
			if tick - death_floats[i].fired > UpConfigRef.DEATH_FLOAT_TICKS:
				death_floats.remove_at(i)

	_step_armies()
	if owns_home_battle:
		_purge_dead_combatants() # no dead unit may begin a new resolution interval
		_deploy_sorties_if_needed()

		# §6.5 simultaneous combat: movement/target acquisition happens first.
		_strike_cursor.clear()
		_rebuild_sortie_buckets()
		_move_invaders_and_collect([])
		_move_sorties_and_collect([])
		_collect_defending_wall_melee([])
		_collect_defending_ranged([])
		_apply_combat([])
		_purge_dead_combatants()

		if tick % UpConfigRef.MERGE_GROUPS_INTERVAL == 0:
			_merge_invader_groups()
			_purge_dead_combatants()

		_step_walls()

	# A fiefdom with zero buildings is eliminated. The match itself continues
	# until exactly one active fiefdom remains.
	_check_eliminations_and_victory()


## ---------------------------------------------------------------------------
## AI economy, construction and War Camp warfare
## ---------------------------------------------------------------------------

func _skill_build_interval() -> int:
	return RivalAISystem.skill_build_interval(self)

func _skill_action_interval() -> int:
	return RivalAISystem.skill_action_interval(self)

func _schedule_next_ai_action(r: Rival) -> int:
	return RivalAISystem.schedule_next_action(self, r)

func _skill_offense_pct(base_pct: int) -> int:
	return RivalAISystem.skill_offense_pct(self, base_pct)

func _skill_attack_threshold(base_threshold: int) -> int:
	return RivalAISystem.skill_attack_threshold(self, base_threshold)

func _skill_attack_gap_seconds(base_gap: int) -> int:
	return RivalAISystem.skill_attack_gap_seconds(self, base_gap)

func _player_name(pid: int) -> String:
	if custom_player_names.has(pid):
		return str(custom_player_names[pid])
	return PLAYER_FACTION_NAME if pid == 0 else rivals[pid - 1].name


func _army_survivors(a: Army) -> int:
	return ArmySystem.survivors(a)

func _log_army_destroyed(a: Army) -> void:
	log_msg("%s's War Camp was destroyed attacking %s." % [_player_name(a.attacker), _player_name(a.target)],
		"good" if a.target == 0 else "")


func _ai_rate(r: Rival, res: String) -> int:
	var total := 0
	for rec in r.buildings:
		total += int(rec["def"].get(res, 0))
	return total

func _ai_cost(r: Rival, def: Dictionary) -> int:
	var c: int = int(def["cost"])
	for i in int(r.purchases[def["id"]]): c = c * UpConfigRef.COST_GROWTH_NUM / UpConfigRef.COST_GROWTH_DEN
	return c

func _rival_layout_init(r: Rival) -> void:
	r.layout_occupancy = PackedInt32Array()
	r.layout_occupancy.resize(GRID * GRID)
	r.layout_occupancy.fill(0)


func _rival_shape_key(shape: Array) -> String:
	var parts: Array[String] = []
	for c: Vector2i in shape:
		parts.append("%d,%d" % [c.x, c.y])
	parts.sort()
	return ";".join(parts)


func _rival_candidate_cells(shape: Array, ox: int, oy: int) -> Array:
	var placed: Array = []
	for off: Vector2i in shape:
		placed.append(Vector2i(ox + off.x, oy + off.y))
	return placed


func _rival_cells_fit(r: Rival, cells: Array) -> bool:
	for cell: Vector2i in cells:
		if cell.x < 0 or cell.y < 0 or cell.x >= GRID or cell.y >= GRID:
			return false
		if r.layout_occupancy[cell.y * GRID + cell.x] != 0:
			return false
	return true


func _rival_candidate_has(cells: Array, x: int, y: int) -> bool:
	for c: Vector2i in cells:
		if c.x == x and c.y == y:
			return true
	return false


func _rival_is_occupied_after(r: Rival, cells: Array, x: int, y: int) -> bool:
	if x < 0 or y < 0 or x >= GRID or y >= GRID:
		return true
	if _rival_candidate_has(cells, x, y):
		return true
	return r.layout_occupancy[y * GRID + x] != 0


func _rival_isolated_gap_penalty(r: Rival, cells: Array) -> int:
	# Avoid layouts that strand a single unusable empty cell between structures or
	# the perimeter. This is a cheap proxy for preserving usable interior space.
	# Only cells in or adjacent to the candidate can change hole status, so this
	# evaluates that neighbourhood instead of all 144 cells. The full-grid count
	# differs from this by a baseline that is identical for every candidate of
	# this placement, and subtracting a constant cannot change which candidate
	# scores highest - so the chosen placement is unchanged.
	var local: Dictionary = {}
	for c: Vector2i in cells:
		local[c.y * GRID + c.x] = c
		for d in NEIGHBOURS4:
			var nx: int = c.x + d.x
			var ny: int = c.y + d.y
			if nx < 0 or ny < 0 or nx >= GRID or ny >= GRID:
				continue
			local[ny * GRID + nx] = Vector2i(nx, ny)

	var delta: int = 0
	var empty: Array = []
	for k in local:
		var p: Vector2i = local[k]
		# after placement
		if not _rival_is_occupied_after(r, cells, p.x, p.y):
			var blocked_after: int = 0
			for d in NEIGHBOURS4:
				if _rival_is_occupied_after(r, cells, p.x + d.x, p.y + d.y):
					blocked_after += 1
			if blocked_after == 4:
				delta += 1
		# before placement (same helper, empty candidate = identical edge rules)
		if not _rival_is_occupied_after(r, empty, p.x, p.y):
			var blocked_before: int = 0
			for d in NEIGHBOURS4:
				if _rival_is_occupied_after(r, empty, p.x + d.x, p.y + d.y):
					blocked_before += 1
			if blocked_before == 4:
				delta -= 1
	return delta * 600


func _rival_record_center(rec: Dictionary) -> Vector2i:
	var cells: Array = rec.get("cells", [])
	if cells.is_empty():
		return Vector2i(int(rec.get("x", GRID / 2)), int(rec.get("y", GRID / 2)))
	var sx: int = 0
	var sy: int = 0
	for c: Vector2i in cells:
		sx += c.x
		sy += c.y
	return Vector2i(int(sx / cells.size()), int(sy / cells.size()))


func _rival_placement_score(r: Rival, def: Dictionary, cells: Array) -> int:
	# Every AI obeys the same legal-placement rules, but each personality values
	# the resulting position differently. Scores use only integer grid geometry so
	# placement is deterministic and replay/seed friendly.
	var edge_depth_sum: int = 0
	var center_distance_sum: int = 0
	var occupied_adjacencies: int = 0
	var sx: int = 0
	var sy: int = 0
	for c: Vector2i in cells:
		sx += c.x
		sy += c.y
		edge_depth_sum += mini(mini(c.x, GRID - 1 - c.x), mini(c.y, GRID - 1 - c.y))
		# Doubled coordinates avoid floats: lower means closer to fiefdom center.
		center_distance_sum += absi(2 * c.x - (GRID - 1)) + absi(2 * c.y - (GRID - 1))
		for d in NEIGHBOURS4:
			var nx: int = c.x + d.x
			var ny: int = c.y + d.y
			if nx < 0 or ny < 0 or nx >= GRID or ny >= GRID:
				continue
			if _rival_candidate_has(cells, nx, ny):
				continue
			if r.layout_occupancy[ny * GRID + nx] != 0:
				occupied_adjacencies += 1

	var center: Vector2i = Vector2i(int(sx / cells.size()), int(sy / cells.size()))
	var nearest_same: int = GRID * 2
	var nearest_important: int = GRID * 2
	for rec in r.buildings:
		var rc: Vector2i = _rival_record_center(rec)
		var dist: int = absi(center.x - rc.x) + absi(center.y - rc.y)
		if str(rec["def"]["id"]) == str(def["id"]):
			nearest_same = mini(nearest_same, dist)
		if int(rec["def"].get("lvl", 1)) >= 3:
			nearest_important = mini(nearest_important, dist)

	var lvl: int = int(def.get("lvl", 1))
	var military: bool = int(def.get("melee", 0)) > 0 or int(def.get("ranged", 0)) > 0
	var score: int = -_rival_isolated_gap_penalty(r, cells)

	match r.personality:
		"Aggressor":
			# Build outward and accept exposure. Military production is pushed most
			# strongly toward the perimeter so the fiefdom reads as expansion-first.
			score -= edge_depth_sum * (34 if military else 18)
			score += center_distance_sum * (7 if military else 3)
			score -= occupied_adjacencies * 8
			# Repeated copies spread along the perimeter instead of forming one blob.
			score += nearest_same * 5
		"Fortifier":
			# Cheap level-1 economy is willing to form an outer buffer. From level 2
			# upward, protection rises sharply and valuable structures are pulled
			# inward into a compact defended core.
			if lvl <= 1:
				score -= edge_depth_sum * 14
				score += center_distance_sum * 3
				score += occupied_adjacencies * 8
			else:
				var protection: int = 18 + lvl * 12
				score += edge_depth_sum * protection
				score -= center_distance_sum * (7 + lvl * 6)
				score += occupied_adjacencies * 14
				if lvl >= 3:
					score -= nearest_important * 7
		_:
			# Opportunist: efficient, adaptable use of space. It likes useful contact
			# with the existing town but distributes repeated/high-value structures so
			# one breach direction is less likely to expose everything important.
			score += occupied_adjacencies * 18
			score += edge_depth_sum * 10
			score -= center_distance_sum * (2 + lvl * 2)
			score += nearest_same * 9
			if lvl >= 2:
				score += nearest_important * 5

	return score


func _rival_place_record(r: Rival, def: Dictionary, hp_value: int) -> Dictionary:
	# Evaluate every legal origin and unique rotation, then choose the highest
	# scoring placement for this AI personality. Equal scores keep scan/rotation
	# order, making tie-breaking deterministic.
	var best_score: int = -2147483648
	var best_cells: Array = []
	var best_x: int = 0
	var best_y: int = 0
	var best_rot: int = 0
	var seen_shapes: Dictionary = {}

	for rot in 4:
		var shape: Array = rotate_cells(def["cells"], rot)
		var shape_key: String = _rival_shape_key(shape)
		if seen_shapes.has(shape_key):
			continue
		seen_shapes[shape_key] = true
		for y in GRID:
			for x in GRID:
				var cells: Array = _rival_candidate_cells(shape, x, y)
				if not _rival_cells_fit(r, cells):
					continue
				var score: int = _rival_placement_score(r, def, cells)
				if score > best_score:
					best_score = score
					best_cells = cells
					best_x = x
					best_y = y
					best_rot = rot

	if best_cells.is_empty():
		return {}

	var rec := {"rid": _next_id(), "def": def, "hp": hp_value, "flash": 0, "x": best_x, "y": best_y, "rot": best_rot, "cells": best_cells}
	var marker: int = r.buildings.size() + 1
	for cell: Vector2i in best_cells:
		r.layout_occupancy[cell.y * GRID + cell.x] = marker
	return rec


func _rival_rebuild_layout_occupancy(r: Rival) -> void:
	r.layout_occupancy.fill(0)
	var marker: int = 1
	for rec in r.buildings:
		for cell: Vector2i in rec.get("cells", []):
			if cell.x >= 0 and cell.y >= 0 and cell.x < GRID and cell.y < GRID:
				r.layout_occupancy[cell.y * GRID + cell.x] = marker
		marker += 1
	_invalidate_rival_flow_fields(r)


func _ai_can_build(r: Rival, def: Dictionary) -> bool:
	if r.gold < _ai_cost(r, def): return false
	var req = def.get("req")
	return req == null or _ai_rate(r, req["res"]) >= int(req["rate"])

func _ai_try_build(r: Rival) -> void:
	var order: Array
	if ai_skill == "Easy":
		match r.personality:
			"Aggressor": order = ["archery", "drillyard", "foundry", "homestead", "farm", "citadel"]
			"Fortifier": order = ["foundry", "farm", "citadel", "homestead", "archery", "drillyard"]
			_: order = ["archery", "foundry", "homestead", "drillyard", "farm", "citadel"]
	else:
		match r.personality:
			"Aggressor": order = ["drillyard", "archery", "homestead", "farm", "citadel", "foundry"]
			"Fortifier": order = ["farm", "homestead", "foundry", "archery", "citadel", "drillyard"]
			_: order = ["homestead", "farm", "archery", "drillyard", "foundry", "citadel"]
	for bid in order:
		var def := UpDefs.building(bid)
		if _ai_can_build(r, def):
			var rec := _rival_place_record(r, def, int(def["hp"]))
			if rec.is_empty():
				continue
			r.gold -= _ai_cost(r, def)
			r.purchases[bid] = int(r.purchases[bid]) + 1
			r.buildings.append(rec)
			return

func _ai_consume_click(r: Rival) -> bool:
	# Same per-second click bucket as the human, but tracked independently for
	# each rival fiefdom. No AI action can exceed CLICK_CAP effective clicks/sec.
	var sec := tick / TPS
	if sec != r.click_window:
		r.click_window = sec
		r.click_count = 0
	if r.click_count >= UpConfigRef.CLICK_CAP:
		return false
	r.click_count += 1
	return true


func _ai_building_type_count(r: Rival, type_id: String) -> int:
	var count := 0
	for rec in r.buildings:
		if str(rec["def"]["id"]) == type_id:
			count += 1
	return count


func _ai_click_gain(r: Rival, rec: Dictionary) -> Dictionary:
	# Exact counterpart of click_gain_for_building(): one production click
	# collects CLICK_PCT of the per-second output of every standing building of
	# the clicked type.
	var def: Dictionary = rec["def"]
	var count := _ai_building_type_count(r, str(def["id"]))
	return {
		"gold": int(def["gold"]) * UpConfigRef.CLICK_PCT / 1000 * count,
		"melee": int(def["melee"]) * UpConfigRef.CLICK_PCT / 1000 * count,
		"ranged": int(def["ranged"]) * UpConfigRef.CLICK_PCT / 1000 * count,
	}


func _ai_click_building(r: Rival) -> bool:
	if r.buildings.is_empty():
		return false
	var productive: Array = []
	for rec in r.buildings:
		var def: Dictionary = rec["def"]
		if int(def["gold"]) > 0 or int(def["melee"]) > 0 or int(def["ranged"]) > 0:
			productive.append(rec)
	if productive.is_empty():
		return false

	var chosen: Dictionary = productive[0]
	if ai_skill == "Easy":
		# Easy behaves like an inexperienced player and clicks whatever productive
		# building happens to have their attention.
		chosen = productive[_rng.randi_range(0, productive.size() - 1)]
	elif ai_skill == "Standard":
		# Standard notices productive choices but is not perfectly optimal. Track
		# the two strongest click targets, then choose between them. This keeps
		# decisions competent while preserving normal human inconsistency.
		var best: Dictionary = productive[0]
		var second: Dictionary = productive[0]
		var best_score := -1
		var second_score := -1
		for rec in productive:
			var gain := _ai_click_gain(r, rec)
			var score := int(gain["gold"]) + int(gain["melee"]) + int(gain["ranged"])
			if score > best_score:
				second = best
				second_score = best_score
				best = rec
				best_score = score
			elif score > second_score:
				second = rec
				second_score = score
		chosen = best if productive.size() == 1 or _rng.randi_range(0, 1) == 0 else second
	else:
		# Hard generally identifies the highest-value click, but still remains bound
		# by the same production formula and shared per-second click cap.
		var best_score := -1
		for rec in productive:
			var gain := _ai_click_gain(r, rec)
			var score := int(gain["gold"]) + int(gain["melee"]) + int(gain["ranged"])
			if score > best_score:
				best_score = score
				chosen = rec

	if not _ai_consume_click(r):
		return false
	var gain := _ai_click_gain(r, chosen)
	r.gold += int(gain["gold"])
	r.pool["melee"] += int(gain["melee"])
	r.pool["ranged"] += int(gain["ranged"])
	return true


func _ai_transfer_click(r: Rival, cat: String, dest_type: String, dest_id: String) -> bool:
	# Same 2%-of-remaining-pool transfer rule and rounding as act_transfer().
	if cat != "melee" and cat != "ranged":
		return false
	if dest_type != "wall" and dest_type != "camp":
		return false
	var whole: int = int(r.pool[cat]) / S
	if whole <= 0:
		return false
	if not _ai_consume_click(r):
		return false
	var n := (whole * UpConfigRef.TRANSFER_PCT + 999) / 1000
	n = mini(n, whole)
	r.pool[cat] -= n * S

	if dest_type == "camp":
		if not dest_id.is_valid_int():
			r.pool[cat] += n * S
			return false
		var ci := int(dest_id)
		if ci < 0 or ci >= r.camps.size():
			r.pool[cat] += n * S
			return false
		var c: WarCamp = r.camps[ci]
		if cat == "melee": c.melee += n
		else: c.ranged += n
		return true

	if not (dest_id in DIRS):
		r.pool[cat] += n * S
		return false
	# Match the player's rebuild rule: melee cannot be transferred into a
	# collapsed wall during its post-collapse cooldown. Ranged troops likewise
	# cannot stand on an open breach.
	if bool(r.wall_collapsed[dest_id]) and (int(r.wall_cooldown[dest_id]) > 0 or cat == "ranged"):
		r.pool[cat] += n * S
		return false
	if cat == "melee":
		r.wall_hp[dest_id] = int(r.wall_hp[dest_id]) + n * int(UpDefs.DEFENDERS["infantry"]["hp"])
	else:
		r.wall_ranged_hp[dest_id] = int(r.wall_ranged_hp[dest_id]) + n * int(UpDefs.DEFENDERS["archer"]["hp"])
	return true


func _ai_try_transfer_action(r: Rival) -> bool:
	var melee := int(r.pool["melee"]) / S
	var ranged := int(r.pool["ranged"]) / S
	if melee <= 0 and ranged <= 0:
		return false

	var offense_pct := 72 if r.personality == "Aggressor" else (35 if r.personality == "Fortifier" else 58)
	offense_pct = _skill_offense_pct(offense_pct)
	var camp: WarCamp = r.camps[r.camp_cursor % r.camps.size()]

	# Decide where the next *single* transfer click goes. The actual amount moved
	# is still exactly 2% of the remaining source pool, rounded up.
	var prefer_offense := ((r.action_cursor * 37 + r.player_id * 17) % 100) < offense_pct
	var cat := "melee"
	if melee <= 0:
		cat = "ranged"
	elif ranged > 0 and int(r.action_cursor / 2) % 2 == 1:
		cat = "ranged"

	if prefer_offense:
		return _ai_transfer_click(r, cat, "camp", str(camp.index))
	var wd: String = DIRS[_rng.randi_range(0, 3)] if ai_skill == "Easy" else _weakest_ai_wall(r)
	return _ai_transfer_click(r, cat, "wall", wd)


func _ai_take_action(r: Rival) -> void:
	# Production clicks and transfer clicks compete for the same per-rival click
	# cap, just as they do for the human player. Roughly 60% of attempted actions
	# accelerate production and 40% move soldiers; failed transfer attempts fall
	# back to a legal production click.
	r.action_cursor += 1
	var production_turn := (r.action_cursor % 5) < 3
	if production_turn:
		if _ai_click_building(r):
			return
		_ai_try_transfer_action(r)
	else:
		if _ai_try_transfer_action(r):
			return
		_ai_click_building(r)

func _weakest_ai_wall(r: Rival) -> String:
	return RivalAISystem.weakest_wall(self, r)

func _player_alive(pid: int) -> bool:
	if pid == 0: return not player_defeated
	var r: Rival = rivals[pid - 1]
	return not r.defeated

func _player_buildings(pid: int) -> int:
	return buildings.size() if pid == 0 else rivals[pid - 1].buildings.size()

func _player_wall_hp(pid: int, d: String) -> int:
	return walls[d].hp() if pid == 0 else int(rivals[pid - 1].wall_hp[d])

func _ai_choose_target(r: Rival) -> int:
	return RivalAISystem.choose_target(self, r)

func _choose_target_wall(pid: int) -> String:
	return RivalAISystem.choose_target_wall(self, pid)

func _step_ai_fiefdoms() -> void:
	for r: Rival in rivals:
		if r.defeated: continue
		if tick % TPS == 0:
			for rec in r.buildings:
				r.gold += int(rec["def"]["gold"]); r.pool["melee"] += int(rec["def"]["melee"]); r.pool["ranged"] += int(rec["def"]["ranged"])
		if is_human_player(r.player_id):
			continue
		if tick >= r.next_build_tick:
			_ai_try_build(r); r.next_build_tick = tick + _skill_build_interval()
		if tick >= r.next_action_tick:
			_ai_take_action(r)
			r.next_action_tick = _schedule_next_ai_action(r)
		if tick < r.next_attack_tick: continue
		var threshold := 18 if r.personality == "Aggressor" else (42 if r.personality == "Fortifier" else 28)
		threshold = _skill_attack_threshold(threshold)
		var chosen: WarCamp = null
		for c: WarCamp in r.camps:
			if c.total() >= threshold: chosen = c; break
		if chosen == null:
			r.next_attack_tick = tick + 5 * TPS
			continue
		var target := _ai_choose_target(r)
		if target < 0: continue
		var wd := _choose_target_wall(target)
		_launch_army(r.player_id, target, chosen.index, wd, chosen.melee, chosen.ranged)
		chosen.melee = 0; chosen.ranged = 0
		r.camp_cursor = (chosen.index + 1) % 3
		var gap := 18 if r.personality == "Aggressor" else (36 if r.personality == "Fortifier" else 25)
		gap = _skill_attack_gap_seconds(gap)
		r.next_attack_tick = tick + gap * TPS

func _launch_army(attacker: int, target: int, camp_index: int, wall_dir: String, melee: int, ranged: int) -> void:
	if melee + ranged <= 0: return
	var a := Army.new(); a.id = _next_id(); a.attacker = attacker; a.target = target; a.from_camp = camp_index
	a.target_wall = wall_dir; a.melee = melee; a.ranged = ranged
	a.melee_hp = melee * int(UpDefs.DEFENDERS["infantry"]["hp"]); a.ranged_hp = ranged * int(UpDefs.DEFENDERS["archer"]["hp"])
	a.travel_ticks = travel_ticks_between(attacker, target)
	if a.travel_ticks <= 0:
		return
	a.arrives = tick + a.travel_ticks; a.next_melee = a.arrives; a.next_ranged = a.arrives
	armies.append(a)
	log_msg("%s launched War Camp %d: %d soldiers toward %s's %s wall." % [
		_player_name(attacker), camp_index + 1, melee + ranged, _player_name(target), dir_name(wall_dir)],
		"bad" if target == 0 else "")
	if target == 0:
		var src: Rival = rivals[attacker - 1]
		var p := PendingAttack.new(); p.dir = wall_dir; p.size = melee + ranged; p.arrives = a.arrives; p.wave = 0
		p.force_color = src.crest; p.device = src.device; p.source_player = attacker; p.army_id = a.id; p.melee = melee; p.ranged = ranged
		pending.append(p)
		# Only Player 0's battlefield authority materializes the physical groups.
		# Other peers receive them from the authoritative battlefield snapshot.
		if owns_battle_simulation(0):
			_spawn_wave(p)
			p.spawned_visible = true
	elif target > 0 and target <= rivals.size() and owns_battle_simulation(target):
		# Rival fiefdoms use the same visible pre-arrival march as the home field.
		# Materialize the physical groups now, at their announced travel distance,
		# rather than teleporting them onto the wall when the timer reaches zero.
		RivalBattleSystem.spawn_army(self, a, rivals[target - 1])

func _mark_army_human_field(aid: int) -> void:
	for a: Army in armies:
		if a.id == aid: a.phase = "human_field"; return

func _army_units(hp: int, unit_hp: int) -> int:
	return 0 if hp <= 0 else (hp + unit_hp - 1) / unit_hp


func invader_members(inv: Invader) -> int:
	return _army_units(inv.hp, maxi(1, inv.member_hp))


func invader_contact_members(inv: Invader, contact_tick: int = -1) -> int:
	## Progressive frontage: the first bodies attack immediately when they touch,
	## then the ranks behind them feed into the contact line over subsequent ticks.
	## This replaces the old packet-wide all-or-nothing strike without creating one
	## RefCounted combat object per soldier.
	var members: int = invader_members(inv)
	if members <= 0:
		return 0
	var started: int = contact_tick
	if started < 0:
		started = inv.wall_contact_tick if not inv.inside else inv.structure_contact_tick
	if started < 0:
		return 0
	var frontage: int = clampi(int(ceil(sqrt(float(members)))),
		UpConfigRef.CROWD_CONTACT_JOIN_PER_TICK_MIN, UpConfigRef.CROWD_CONTACT_JOIN_PER_TICK_MAX)
	var elapsed: int = maxi(0, tick - started)
	return mini(members, frontage * (elapsed + 1))

func unit_members(u: Unit) -> int:
	if u == null:
		return 0
	return _army_units(u.hp, maxi(1, u.member_hp))


func sortie_members(s: Sortie) -> int:
	if s == null or s.dead:
		return 0
	return _army_units(s.hp, maxi(1, s.member_hp))


func garrison_count(arr: Array) -> int:
	var total: int = 0
	for u: Unit in arr:
		total += unit_members(u)
	return total


func _append_grouped_stationed(target: Array, count: int, def: Dictionary, slot: String) -> void:
	## Keep tiny garrisons granular and progressively widen packets as a transfer
	## grows. The slot rebalancer below enforces the hard per-slot CPU budget.
	if count <= 0:
		return
	var packet_size: int = maxi(1, int(ceil(float(count) / float(UpConfigRef.MAX_DEFENDER_GROUPS_PER_SLOT))))
	var left: int = count
	while left > 0:
		var n: int = mini(packet_size, left)
		var u := Unit.new(_next_id(), def, n)
		_stagger_first_attack(u)
		_assign_lane(u)
		target.append(u)
		_register_stationed_unit(u, slot)
		left -= n


func _rebalance_stationed_slot(arr: Array, slot: String) -> void:
	## Compact an oversized garrison into at most N phase/lane packets. Exact
	## combined HP is preserved, so this does not create or remove a casualty.
	if arr.size() <= UpConfigRef.MAX_DEFENDER_GROUPS_PER_SLOT:
		return
	var total_hp: int = 0
	var def: Dictionary = {}
	for u: Unit in arr:
		if u.hp <= 0:
			continue
		if def.is_empty():
			def = u.def
		total_hp += u.hp
		_unregister_stationed_unit(u)
	arr.clear()
	if total_hp <= 0 or def.is_empty():
		return
	var member_hp: int = maxi(1, int(def["hp"]))
	var total_members: int = _army_units(total_hp, member_hp)
	var groups: int = mini(UpConfigRef.MAX_DEFENDER_GROUPS_PER_SLOT, total_members)
	var base_members: int = total_members / groups
	var extra_members: int = total_members % groups
	var hp_left: int = total_hp
	for gi in groups:
		var represented: int = base_members + (1 if gi < extra_members else 0)
		var capacity_hp: int = represented * member_hp
		var group_hp: int = mini(capacity_hp, hp_left)
		if group_hp <= 0:
			break
		var u := Unit.new(_next_id(), def, represented)
		u.hp = group_hp
		u.group_size = unit_members(u)
		_stagger_first_attack(u)
		_assign_lane(u)
		arr.append(u)
		_register_stationed_unit(u, slot)
		hp_left -= group_hp


func live_invader_count() -> int:
	var total := 0
	for inv: Invader in invaders:
		if inv.hp > 0:
			total += invader_members(inv)
	return total


func live_inside_invader_count() -> int:
	var total := 0
	for inv: Invader in invaders:
		if inv.hp > 0 and inv.inside:
			total += invader_members(inv)
	return total

func live_sortie_count() -> int:
	var total: int = 0
	for s: Sortie in sortied:
		total += sortie_members(s)
	return total


func turret_melee_total(turret_id: String) -> int:
	if not turrets.has(turret_id):
		return 0
	var total: int = garrison_count(turrets[turret_id].melee)
	# Melee from a turret may be actively sortied into the fiefdom after a
	# breach. They still belong to that turret for status/tooltip purposes.
	for s: Sortie in sortied:
		if not s.dead and s.hp > 0 and s.origin_turret == turret_id:
			total += sortie_members(s)
	return total


func _step_armies() -> void:
	# First resolve journey arrivals. Human-target armies are represented by the
	# player-fiefdom InvaderSystem. AI-target armies materialize into the target
	# rival's physical battlefield and use the same spatial battle model.
	for a: Army in armies:
		if a.phase != "travel" or tick < a.arrives:
			continue
		if a.target == 0:
			continue # pending banner/spawn changes this to human_field
		if a.target < 1 or a.target > rivals.size():
			continue
		var arrival_rival: Rival = rivals[a.target - 1]
		if arrival_rival.defeated:
			_begin_return(a)
			continue
		var already_spawned: bool = false
		for inv: Invader in arrival_rival.invaders:
			if inv.army_id == a.id and inv.hp > 0:
				already_spawned = true
				break
		if not already_spawned:
			RivalBattleSystem.spawn_army(self, a, arrival_rival)
		a.phase = "rival_field"
		log_msg("%s's War Camp reached %s's %s wall with %d soldiers." % [
			_player_name(a.attacker), arrival_rival.name, dir_name(a.target_wall), _army_survivors(a)], "")

	# Every AI fiefdom with an active battle advances its invaders using the same
	# physical phases: wall contact -> assigned breach -> interior path -> exact
	# structure contact/ranged standoff -> destruction.
	for r: Rival in rivals:
		if not r.defeated and owns_battle_simulation(r.player_id):
			# Only the peer assigned to this fiefdom advances its expensive physical
			# battle. Other peers receive authoritative snapshots from that owner.
			RivalBattleSystem.step(self, r)
			if r.buildings.is_empty():
				_defeat_rival(r)

	# Then resolve army lifecycle/returns from the authoritative physical groups.
	for i in range(armies.size() - 1, -1, -1):
		var a2: Army = armies[i]
		if a2.phase == "dead":
			armies.remove_at(i)
			continue
		if a2.phase == "travel":
			continue
		if a2.phase == "human_field":
			if not owns_battle_simulation(0):
				continue
			var alive: bool = false
			for inv: Invader in invaders:
				if inv.army_id == a2.id and inv.hp > 0:
					alive = true
					break
			if not alive:
				_log_army_destroyed(a2)
				armies.remove_at(i)
			continue
		if a2.phase == "return":
			if tick < a2.arrives:
				continue
			_return_army_to_camp(a2)
			armies.remove_at(i)
			continue
		if a2.phase != "rival_field" or a2.target < 1 or a2.target > rivals.size():
			continue
		var target_rival: Rival = rivals[a2.target - 1]
		if not owns_battle_simulation(a2.target):
			# The target fiefdom's owner is authoritative for casualties and the
			# return/death transition. A snapshot will update this Army in-place.
			continue
		RivalBattleSystem.sync_army_hp(self, a2, target_rival)
		if target_rival.defeated:
			RivalBattleSystem.remove_army(target_rival, a2.id)
			_begin_return(a2)
			continue
		if a2.melee_hp <= 0 and a2.ranged_hp <= 0:
			RivalBattleSystem.remove_army(target_rival, a2.id)
			_log_army_destroyed(a2)
			armies.remove_at(i)



func _snapshot_unit(u: Unit) -> Dictionary:
	return BattleSnapshotSystem.snapshot_unit(u)

func _restore_unit(data: Dictionary) -> Unit:
	var u := Unit.new(int(data.get("id", -1)), data.get("def", UpDefs.DEFENDERS["infantry"]), maxi(1, int(data.get("group_size", 1))))
	u.hp = int(data.get("hp", u.hp))
	u.member_hp = maxi(1, int(data.get("member_hp", u.member_hp)))
	u.group_size = maxi(1, int(data.get("group_size", unit_members(u))))
	u.lane = int(data.get("lane", 0))
	u.next_attack = int(data.get("next_attack", tick))
	return u


func _snapshot_invader(inv: Invader) -> Dictionary:
	return BattleSnapshotSystem.snapshot_invader(inv)

func _restore_invader(data: Dictionary, existing: Invader = null) -> Invader:
	var inv: Invader = existing if existing != null else Invader.new()
	inv.id = int(data.get("id", -1)); inv.def = data.get("def", inv.def)
	inv.hp = int(data.get("hp", inv.hp)); inv.member_hp = maxi(1, int(data.get("member_hp", inv.member_hp)))
	inv.group_size = maxi(1, int(data.get("group_size", inv.group_size))); inv.next_attack = int(data.get("next_attack", inv.next_attack))
	inv.active_tick = int(data.get("active_tick", inv.active_tick)); inv.x = int(data.get("x", inv.x)); inv.y = int(data.get("y", inv.y))
	inv.prev_x = int(data.get("prev_x", inv.x)); inv.prev_y = int(data.get("prev_y", inv.y)); inv.wall = str(data.get("wall", inv.wall))
	inv.wall_lane = int(data.get("wall_lane", inv.wall_lane)); inv.inside = bool(data.get("inside", inv.inside)); inv.at_wall = bool(data.get("at_wall", inv.at_wall))
	inv.wall_contact_tick = int(data.get("wall_contact_tick", inv.wall_contact_tick)); inv.structure_contact_tick = int(data.get("structure_contact_tick", inv.structure_contact_tick))
	inv.tgt_kind = str(data.get("tgt_kind", inv.tgt_kind)); inv.tgt_id = int(data.get("tgt_id", inv.tgt_id)); inv.hx = int(data.get("hx", inv.hx)); inv.hy = int(data.get("hy", inv.hy))
	inv.force_color = data.get("force_color", inv.force_color); inv.army_id = int(data.get("army_id", inv.army_id)); inv.path = data.get("path", inv.path).duplicate(true)
	inv.path_index = int(data.get("path_index", inv.path_index)); inv.path_target_kind = str(data.get("path_target_kind", inv.path_target_kind)); inv.path_target_id = int(data.get("path_target_id", inv.path_target_id))
	inv.last_progress_x = int(data.get("last_progress_x", inv.last_progress_x)); inv.last_progress_y = int(data.get("last_progress_y", inv.last_progress_y)); inv.stuck_ticks = int(data.get("stuck_ticks", inv.stuck_ticks))
	return inv


func home_battle_is_active() -> bool:
	return BattleSnapshotSystem.home_battle_is_active(self)

func battle_is_active(pid: int) -> bool:
	return home_battle_is_active() if pid == 0 else rival_battle_is_active(pid)


func make_battle_snapshot(pid: int) -> Dictionary:
	return make_home_battle_snapshot() if pid == 0 else make_rival_battle_snapshot(pid)


func apply_battle_snapshot(pid: int, snap: Dictionary) -> void:
	if pid == 0:
		apply_home_battle_snapshot(snap)
	else:
		apply_rival_battle_snapshot(pid, snap)


func make_home_battle_snapshot() -> Dictionary:
	var building_data: Array = []
	for b: Building in buildings:
		building_data.append({"id": b.id, "def": b.def, "cells": b.cells.duplicate(true), "hp": b.hp, "cx": b.cx, "cy": b.cy, "flash": b.flash})
	var wall_data: Dictionary = {}
	for d in DIRS:
		var w: Wall = walls[d]
		var melee_hp: int = 0
		var ranged_hp: int = 0
		for u: Unit in w.melee: melee_hp += maxi(0, u.hp)
		for u: Unit in w.ranged: ranged_hp += maxi(0, u.hp)
		wall_data[d] = {"collapsed": w.collapsed, "cooldown": w.cooldown, "collapse_tick": w.collapse_tick, "melee_hp": melee_hp, "ranged_hp": ranged_hp}
	var turret_data: Dictionary = {}
	for tid in TURRETS:
		var tr: Turret = turrets[tid]
		var melee_hp: int = 0
		var ranged_hp: int = 0
		for u: Unit in tr.melee: melee_hp += maxi(0, u.hp)
		for u: Unit in tr.ranged: ranged_hp += maxi(0, u.hp)
		turret_data[tid] = {"destroyed": tr.destroyed, "melee_hp": melee_hp, "ranged_hp": ranged_hp}
	var inv_data: Array = []
	for inv: Invader in invaders:
		inv_data.append(_snapshot_invader(inv))
	var sortie_data: Array = []
	for so: Sortie in sortied:
		sortie_data.append({
			"id": so.id, "def": so.def, "hp": so.hp, "member_hp": so.member_hp, "group_size": so.group_size,
			"next_attack": so.next_attack, "origin_turret": so.origin_turret,
			"x": so.x, "y": so.y, "prev_x": so.prev_x, "prev_y": so.prev_y,
			"tgt_id": so.tgt_id, "hx": so.hx, "hy": so.hy, "dead": so.dead,
		})
	var pending_data: Array = []
	for p: PendingAttack in pending:
		pending_data.append({
			"dir": p.dir, "size": p.size, "arrives": p.arrives, "spawned_visible": p.spawned_visible,
			"wave": p.wave, "force_color": p.force_color, "device": p.device, "source_player": p.source_player,
			"army_id": p.army_id, "melee": p.melee, "ranged": p.ranged,
		})
	var shot_data: Array = []
	for sh: Shot in shots:
		shot_data.append({"fx": sh.fx, "fy": sh.fy, "tx": sh.tx, "ty": sh.ty, "fired": sh.fired, "hostile": sh.hostile})
	var impact_data: Array = []
	for hit: MeleeImpact in melee_impacts:
		impact_data.append({"x": hit.x, "y": hit.y, "fired": hit.fired})
	var death_data: Array = []
	for df: DeathFloat in death_floats:
		death_data.append({"x": df.x, "y": df.y, "fired": df.fired, "seed": df.seed, "count": df.count})
	var army_data: Array = []
	for a: Army in armies:
		if a.target == 0:
			army_data.append({
				"id": a.id, "attacker": a.attacker, "target": a.target, "from_camp": a.from_camp,
				"target_wall": a.target_wall, "melee": a.melee, "ranged": a.ranged,
				"melee_hp": a.melee_hp, "ranged_hp": a.ranged_hp, "arrives": a.arrives,
				"travel_ticks": a.travel_ticks, "phase": a.phase, "next_melee": a.next_melee, "next_ranged": a.next_ranged,
			})
	return {
		"tick": tick, "buildings": building_data, "occupancy": occupancy, "rubble": rubble.duplicate(true),
		"walls": wall_data, "turrets": turret_data, "invaders": inv_data, "sortied": sortie_data,
		"pending": pending_data, "shots": shot_data, "melee_impacts": impact_data, "death_floats": death_data,
		"armies": army_data,
	}


func apply_home_battle_snapshot(snap: Dictionary) -> void:
	if snap.is_empty() or owns_battle_simulation(0):
		return
	var existing_buildings: Dictionary = {}
	for b: Building in buildings:
		existing_buildings[b.id] = b
	var rebuilt_buildings: Array = []
	for value in snap.get("buildings", []):
		var data: Dictionary = value
		var bid: int = int(data.get("id", -1))
		var b = existing_buildings.get(bid, null) as Building
		if b == null:
			b = Building.new(bid, data.get("def", {}), data.get("cells", []).duplicate(true))
		b.hp = int(data.get("hp", b.hp)); b.flash = int(data.get("flash", b.flash))
		b.cx = int(data.get("cx", b.cx)); b.cy = int(data.get("cy", b.cy))
		rebuilt_buildings.append(b)
	buildings = rebuilt_buildings
	_building_by_id.clear()
	for b: Building in buildings:
		_building_by_id[b.id] = b
	var occ = snap.get("occupancy", occupancy)
	if occ is PackedInt32Array:
		occupancy = occ
		_invalidate_home_flow_fields()
	rubble = snap.get("rubble", rubble).duplicate(true)
	for d in DIRS:
		var wd: Dictionary = snap.get("walls", {}).get(d, {})
		if wd.is_empty(): continue
		var w: Wall = walls[d]
		w.collapsed = bool(wd.get("collapsed", w.collapsed)); w.cooldown = int(wd.get("cooldown", w.cooldown)); w.collapse_tick = int(wd.get("collapse_tick", w.collapse_tick))
		w.melee.clear(); w.ranged.clear()
		var mhp: int = int(wd.get("melee_hp", 0)); var rhp: int = int(wd.get("ranged_hp", 0))
		if mhp > 0:
			var mu := Unit.new(-1000 - DIRS.find(d), UpDefs.DEFENDERS["infantry"], _army_units(mhp, int(UpDefs.DEFENDERS["infantry"]["hp"])))
			mu.hp = mhp; w.melee.append(mu)
		if rhp > 0:
			var ru := Unit.new(-1100 - DIRS.find(d), UpDefs.DEFENDERS["archer"], _army_units(rhp, int(UpDefs.DEFENDERS["archer"]["hp"])))
			ru.hp = rhp; w.ranged.append(ru)
	for tid in TURRETS:
		var td: Dictionary = snap.get("turrets", {}).get(tid, {})
		if td.is_empty(): continue
		var tr: Turret = turrets[tid]
		tr.destroyed = bool(td.get("destroyed", tr.destroyed)); tr.melee.clear(); tr.ranged.clear()
		var tmhp: int = int(td.get("melee_hp", 0)); var trhp: int = int(td.get("ranged_hp", 0))
		if tmhp > 0:
			var tmu := Unit.new(-1200 - TURRETS.find(tid), UpDefs.DEFENDERS["infantry"], _army_units(tmhp, int(UpDefs.DEFENDERS["infantry"]["hp"])))
			tmu.hp = tmhp; tr.melee.append(tmu)
		if trhp > 0:
			var tru := Unit.new(-1300 - TURRETS.find(tid), UpDefs.DEFENDERS["archer"], _army_units(trhp, int(UpDefs.DEFENDERS["archer"]["hp"])))
			tru.hp = trhp; tr.ranged.append(tru)

	var old_inv: Dictionary = {}
	for inv: Invader in invaders: old_inv[inv.id] = inv
	invaders.clear(); _invader_by_id.clear(); _inside_buckets.clear(); _outside_buckets.clear()
	for d in DIRS: _outside_by_wall[d].clear()
	for value in snap.get("invaders", []):
		var data: Dictionary = value
		var iid: int = int(data.get("id", -1))
		var inv: Invader = _restore_invader(data, old_inv.get(iid, null) as Invader)
		invaders.append(inv); _invader_by_id[inv.id] = inv; inv.indexed = false

	sortied.clear(); _sortie_by_id.clear()
	for value in snap.get("sortied", []):
		var data: Dictionary = value
		var so := Sortie.new(); so.id = int(data.get("id", -1)); so.def = data.get("def", {})
		so.hp = int(data.get("hp", 0)); so.member_hp = maxi(1, int(data.get("member_hp", 1))); so.group_size = maxi(1, int(data.get("group_size", 1)))
		so.next_attack = int(data.get("next_attack", tick)); so.origin_turret = str(data.get("origin_turret", ""))
		so.x = int(data.get("x", 0)); so.y = int(data.get("y", 0)); so.prev_x = int(data.get("prev_x", so.x)); so.prev_y = int(data.get("prev_y", so.y))
		so.tgt_id = int(data.get("tgt_id", -1)); so.hx = int(data.get("hx", 0)); so.hy = int(data.get("hy", 0)); so.dead = bool(data.get("dead", false))
		sortied.append(so); _sortie_by_id[so.id] = so

	pending.clear()
	for value in snap.get("pending", []):
		var data: Dictionary = value; var pa := PendingAttack.new()
		pa.dir = str(data.get("dir", "N")); pa.size = int(data.get("size", 0)); pa.arrives = int(data.get("arrives", tick)); pa.spawned_visible = bool(data.get("spawned_visible", false))
		pa.wave = int(data.get("wave", 0)); pa.force_color = data.get("force_color", pa.force_color); pa.device = int(data.get("device", 0)); pa.source_player = int(data.get("source_player", -1))
		pa.army_id = int(data.get("army_id", -1)); pa.melee = int(data.get("melee", 0)); pa.ranged = int(data.get("ranged", 0)); pending.append(pa)
	shots.clear()
	for value in snap.get("shots", []):
		var data: Dictionary = value; var sh := Shot.new(); sh.fx = int(data.get("fx", 0)); sh.fy = int(data.get("fy", 0)); sh.tx = int(data.get("tx", 0)); sh.ty = int(data.get("ty", 0)); sh.fired = int(data.get("fired", tick)); sh.hostile = bool(data.get("hostile", false)); shots.append(sh)
	melee_impacts.clear()
	for value in snap.get("melee_impacts", []):
		var data: Dictionary = value; var hit := MeleeImpact.new(); hit.x = int(data.get("x", 0)); hit.y = int(data.get("y", 0)); hit.fired = int(data.get("fired", tick)); melee_impacts.append(hit)
	death_floats.clear()
	for value in snap.get("death_floats", []):
		var data: Dictionary = value; var df := DeathFloat.new(); df.x = int(data.get("x", 0)); df.y = int(data.get("y", 0)); df.fired = int(data.get("fired", tick)); df.seed = int(data.get("seed", 0)); df.count = int(data.get("count", 1)); death_floats.append(df)

	var army_by_id: Dictionary = {}
	for a: Army in armies: army_by_id[a.id] = a
	var authoritative_ids: Dictionary = {}
	for value in snap.get("armies", []):
		var ad: Dictionary = value; var aid: int = int(ad.get("id", -1)); authoritative_ids[aid] = true
		var a = army_by_id.get(aid, null) as Army
		if a == null: a = Army.new(); a.id = aid; armies.append(a)
		a.attacker = int(ad.get("attacker", a.attacker)); a.target = 0; a.from_camp = int(ad.get("from_camp", a.from_camp)); a.target_wall = str(ad.get("target_wall", a.target_wall))
		a.melee = int(ad.get("melee", a.melee)); a.ranged = int(ad.get("ranged", a.ranged)); a.melee_hp = int(ad.get("melee_hp", a.melee_hp)); a.ranged_hp = int(ad.get("ranged_hp", a.ranged_hp))
		a.arrives = int(ad.get("arrives", a.arrives)); a.travel_ticks = int(ad.get("travel_ticks", a.travel_ticks)); a.phase = str(ad.get("phase", a.phase)); a.next_melee = int(ad.get("next_melee", a.next_melee)); a.next_ranged = int(ad.get("next_ranged", a.next_ranged))
	for i in range(armies.size() - 1, -1, -1):
		var old: Army = armies[i]
		if old.target == 0 and not authoritative_ids.has(old.id): armies.remove_at(i)


func rival_battle_is_active(pid: int) -> bool:
	return BattleSnapshotSystem.rival_battle_is_active(self, pid)

func make_rival_battle_snapshot(pid: int) -> Dictionary:
	if pid < 1 or pid > rivals.size():
		return {}
	var r: Rival = rivals[pid - 1]
	var inv_data: Array = []
	for inv: Invader in r.invaders:
		inv_data.append({
			"id": inv.id, "def": inv.def, "hp": inv.hp, "member_hp": inv.member_hp,
			"group_size": inv.group_size, "next_attack": inv.next_attack, "active_tick": inv.active_tick,
			"x": inv.x, "y": inv.y, "prev_x": inv.prev_x, "prev_y": inv.prev_y,
			"wall": inv.wall, "wall_lane": inv.wall_lane, "inside": inv.inside, "at_wall": inv.at_wall,
			"wall_contact_tick": inv.wall_contact_tick, "structure_contact_tick": inv.structure_contact_tick,
			"tgt_kind": inv.tgt_kind, "tgt_id": inv.tgt_id, "hx": inv.hx, "hy": inv.hy,
			"force_color": inv.force_color, "army_id": inv.army_id,
			"path": inv.path.duplicate(true), "path_index": inv.path_index,
			"path_target_kind": inv.path_target_kind, "path_target_id": inv.path_target_id,
			"last_progress_x": inv.last_progress_x, "last_progress_y": inv.last_progress_y,
			"stuck_ticks": inv.stuck_ticks,
		})
	var army_data: Array = []
	for a: Army in armies:
		if a.target == pid and a.phase != "travel":
			army_data.append({
				"id": a.id, "attacker": a.attacker, "target": a.target, "from_camp": a.from_camp,
				"target_wall": a.target_wall, "melee": a.melee, "ranged": a.ranged,
				"melee_hp": a.melee_hp, "ranged_hp": a.ranged_hp, "arrives": a.arrives,
				"travel_ticks": a.travel_ticks, "phase": a.phase,
				"next_melee": a.next_melee, "next_ranged": a.next_ranged,
			})
	return {
		"tick": tick,
		"defeated": r.defeated,
		"buildings": r.buildings.duplicate(true),
		"layout_occupancy": r.layout_occupancy,
		"wall_hp": r.wall_hp.duplicate(true),
		"wall_ranged_hp": r.wall_ranged_hp.duplicate(true),
		"wall_collapsed": r.wall_collapsed.duplicate(true),
		"wall_cooldown": r.wall_cooldown.duplicate(true),
		"wall_collapse_tick": r.wall_collapse_tick.duplicate(true),
		"wall_next_melee": r.wall_next_melee.duplicate(true),
		"wall_next_ranged": r.wall_next_ranged.duplicate(true),
		"turret_melee_hp": r.turret_melee_hp.duplicate(true),
		"turret_ranged_hp": r.turret_ranged_hp.duplicate(true),
		"turret_next_melee": r.turret_next_melee.duplicate(true),
		"turret_next_ranged": r.turret_next_ranged.duplicate(true),
		"invaders": inv_data,
		"shots": r.shots.duplicate(true),
		"melee_impacts": r.melee_impacts.duplicate(true),
		"death_floats": r.death_floats.duplicate(true),
		"armies": army_data,
	}


func apply_rival_battle_snapshot(pid: int, snap: Dictionary) -> void:
	if pid < 1 or pid > rivals.size() or snap.is_empty():
		return
	# Never overwrite the authoritative copy with its own network echo.
	if owns_battle_simulation(pid):
		return
	var r: Rival = rivals[pid - 1]
	# Defeat is participant-presence state, not a lossy battlefield-visual state.
	# It is synchronized separately over a reliable RPC by Main.gd.  Never let
	# an unreliable/stale battle snapshot remove a living human fiefdom from the
	# active chain.
	r.buildings = snap.get("buildings", r.buildings).duplicate(true)
	var occ = snap.get("layout_occupancy", r.layout_occupancy)
	if occ is PackedInt32Array:
		r.layout_occupancy = occ
	r.wall_hp = snap.get("wall_hp", r.wall_hp).duplicate(true)
	r.wall_ranged_hp = snap.get("wall_ranged_hp", r.wall_ranged_hp).duplicate(true)
	r.wall_collapsed = snap.get("wall_collapsed", r.wall_collapsed).duplicate(true)
	r.wall_cooldown = snap.get("wall_cooldown", r.wall_cooldown).duplicate(true)
	r.wall_collapse_tick = snap.get("wall_collapse_tick", r.wall_collapse_tick).duplicate(true)
	r.wall_next_melee = snap.get("wall_next_melee", r.wall_next_melee).duplicate(true)
	r.wall_next_ranged = snap.get("wall_next_ranged", r.wall_next_ranged).duplicate(true)
	r.turret_melee_hp = snap.get("turret_melee_hp", r.turret_melee_hp).duplicate(true)
	r.turret_ranged_hp = snap.get("turret_ranged_hp", r.turret_ranged_hp).duplicate(true)
	r.turret_next_melee = snap.get("turret_next_melee", r.turret_next_melee).duplicate(true)
	r.turret_next_ranged = snap.get("turret_next_ranged", r.turret_next_ranged).duplicate(true)
	r.shots = snap.get("shots", r.shots).duplicate(true)
	r.melee_impacts = snap.get("melee_impacts", r.melee_impacts).duplicate(true)
	r.death_floats = snap.get("death_floats", r.death_floats).duplicate(true)

	var existing_inv: Dictionary = {}
	for inv: Invader in r.invaders:
		existing_inv[inv.id] = inv
	var rebuilt_inv: Array = []
	for data_value in snap.get("invaders", []):
		var data: Dictionary = data_value
		var iid: int = int(data.get("id", -1))
		var inv = existing_inv.get(iid, null) as Invader
		if inv == null:
			inv = Invader.new()
		inv.id = iid
		inv.def = data.get("def", inv.def)
		inv.hp = int(data.get("hp", inv.hp))
		inv.member_hp = int(data.get("member_hp", inv.member_hp))
		inv.group_size = int(data.get("group_size", inv.group_size))
		inv.next_attack = int(data.get("next_attack", inv.next_attack))
		inv.active_tick = int(data.get("active_tick", inv.active_tick))
		inv.x = int(data.get("x", inv.x)); inv.y = int(data.get("y", inv.y))
		inv.prev_x = int(data.get("prev_x", inv.x)); inv.prev_y = int(data.get("prev_y", inv.y))
		inv.wall = str(data.get("wall", inv.wall)); inv.wall_lane = int(data.get("wall_lane", inv.wall_lane))
		inv.inside = bool(data.get("inside", inv.inside)); inv.at_wall = bool(data.get("at_wall", inv.at_wall))
		inv.wall_contact_tick = int(data.get("wall_contact_tick", inv.wall_contact_tick))
		inv.structure_contact_tick = int(data.get("structure_contact_tick", inv.structure_contact_tick))
		inv.tgt_kind = str(data.get("tgt_kind", inv.tgt_kind)); inv.tgt_id = int(data.get("tgt_id", inv.tgt_id))
		inv.hx = int(data.get("hx", inv.hx)); inv.hy = int(data.get("hy", inv.hy))
		inv.force_color = data.get("force_color", inv.force_color); inv.army_id = int(data.get("army_id", inv.army_id))
		inv.path = data.get("path", inv.path).duplicate(true); inv.path_index = int(data.get("path_index", inv.path_index))
		inv.path_target_kind = str(data.get("path_target_kind", inv.path_target_kind))
		inv.path_target_id = int(data.get("path_target_id", inv.path_target_id))
		inv.last_progress_x = int(data.get("last_progress_x", inv.last_progress_x))
		inv.last_progress_y = int(data.get("last_progress_y", inv.last_progress_y))
		inv.stuck_ticks = int(data.get("stuck_ticks", inv.stuck_ticks))
		rebuilt_inv.append(inv)
	r.invaders = rebuilt_inv

	var army_by_id: Dictionary = {}
	for a: Army in armies:
		army_by_id[a.id] = a
	var authoritative_ids: Dictionary = {}
	for ad_value in snap.get("armies", []):
		var ad: Dictionary = ad_value
		var aid: int = int(ad.get("id", -1))
		authoritative_ids[aid] = true
		var a = army_by_id.get(aid, null) as Army
		if a == null:
			a = Army.new(); a.id = aid; armies.append(a)
		a.attacker = int(ad.get("attacker", a.attacker)); a.target = int(ad.get("target", pid))
		a.from_camp = int(ad.get("from_camp", a.from_camp)); a.target_wall = str(ad.get("target_wall", a.target_wall))
		a.melee = int(ad.get("melee", a.melee)); a.ranged = int(ad.get("ranged", a.ranged))
		a.melee_hp = int(ad.get("melee_hp", a.melee_hp)); a.ranged_hp = int(ad.get("ranged_hp", a.ranged_hp))
		a.arrives = int(ad.get("arrives", a.arrives)); a.travel_ticks = int(ad.get("travel_ticks", a.travel_ticks))
		a.phase = str(ad.get("phase", a.phase)); a.next_melee = int(ad.get("next_melee", a.next_melee)); a.next_ranged = int(ad.get("next_ranged", a.next_ranged))
	for i in range(armies.size() - 1, -1, -1):
		var old_a: Army = armies[i]
		if old_a.target == pid and old_a.phase == "rival_field" and not authoritative_ids.has(old_a.id):
			armies.remove_at(i)



func _defeat_rival(r: Rival) -> void:
	if r.defeated: return
	r.defeated = true
	for a: Army in armies:
		if a.attacker == r.player_id and a.phase != "return":
			a.melee = 0
			a.ranged = 0
			a.melee_hp = 0
			a.ranged_hp = 0
			# A defeated fiefdom loses control of any deployed army it owns. Remove
			# those physical groups from whichever battlefield they occupy.
			for battlefield: Rival in rivals:
				RivalBattleSystem.remove_army(battlefield, a.id)
			if a.phase == "human_field":
				for inv: Invader in invaders:
					if inv.army_id == a.id:
						inv.hp = 0
			a.phase = "dead"
	log_msg("%s has been defeated." % r.name, "good")

func _begin_return(a: Army) -> void:
	ArmySystem.begin_return(self, a)

func _return_army_to_camp(a: Army) -> void:
	ArmySystem.return_army_to_camp(self, a)

func _deploy_sorties_if_needed() -> void:
	var any_inside := false
	for inv: Invader in invaders:
		if inv.hp > 0 and inv.inside:
			any_inside = true
			break
	if not any_inside: return

	for tid in TURRETS:
		var tr: Turret = turrets[tid]
		if tr.destroyed or tr.melee.is_empty(): continue
		var p := turret_point(tid)
		_defender_ready[_turret_melee_slot(tid)] = []
		while not tr.melee.is_empty():
			var u: Unit = tr.melee.pop_back()
			_unregister_stationed_unit(u)
			var s := Sortie.new()
			s.id = u.id; s.def = u.def; s.hp = u.hp; s.next_attack = u.next_attack
			s.member_hp = u.member_hp; s.group_size = unit_members(u)
			s.origin_turret = tid
			s.x = clampi(p.x, CELL / 2, GRID * CELL - CELL / 2)
			s.y = clampi(p.y, CELL / 2, GRID * CELL - CELL / 2)
			s.prev_x = s.x
			s.prev_y = s.y
			sortied.append(s)
			_sortie_by_id[s.id] = s


func _cell_from_world(x: int, y: int) -> Vector2i:
	return InvaderSystem.cell_from_world(x, y)

func _world_from_cell(c: Vector2i) -> Vector2i:
	return InvaderSystem.world_from_cell(c)

func _cell_walkable(c: Vector2i, start: Vector2i) -> bool:
	return InvaderSystem.cell_walkable(self, c, start)

func _path_goal_ok(inv: Invader, c: Vector2i, target: Vector2i, attack_range: int) -> bool:
	return InvaderSystem.path_goal_ok(self, inv, c, target, attack_range)

func _build_interior_path(inv: Invader, target: Vector2i, attack_range: int) -> Array:
	return InvaderSystem.build_interior_path(self, inv, target, attack_range)

func _reset_invader_path(inv: Invader) -> void:
	InvaderSystem.reset_path(inv)

func _ensure_invader_path(inv: Invader, target: Vector2i, attack_range: int) -> void:
	InvaderSystem.ensure_path(self, inv, target, attack_range)

func _move_invader_toward(inv: Invader, dest: Vector2i, speed: int) -> void:
	InvaderSystem.move_invader_toward(self, inv, dest, speed)

func _check_invader_progress(inv: Invader) -> bool:
	return InvaderSystem.check_progress(self, inv)

func _defender_slot(kind: String, id: String, cat: String) -> String:
	var prefix: String = "W" if kind == "wall" else "T"
	var arm: String = "M" if cat == "melee" else "R"
	return "%s%s:%s" % [prefix, arm, id]


func _wall_melee_slot(d: String) -> String:
	return "WM:" + d


func _wall_ranged_slot(d: String) -> String:
	return "WR:" + d


func _turret_melee_slot(tid: String) -> String:
	return "TM:" + tid


func _turret_ranged_slot(tid: String) -> String:
	return "TR:" + tid


## Spread a unit's first attack across its own interval instead of leaving every
## defender due on the same tick. Without this the whole garrison is created with
## next_attack = 0, fires in lockstep, and then keeps its lockstep forever because
## firing sets next_attack = tick + iv for all of them at once. That produced
## alternating cheap and very expensive ticks: thousands of archers resolving in a
## single tick, which is the p95 spike. The offset is derived from the unit id, so
## it is deterministic and identical on every machine.
## Spread a unit along the wall it garrisons. Stable per unit, deterministic.
func _assign_lane(u: Unit) -> void:
	u.lane = (u.id * 2654435761) % (GRID * CELL)


func _stagger_first_attack(u: Unit) -> void:
	var iv: int = int(u.def["iv"])
	if iv > 1:
		u.next_attack = tick + (u.id % iv)
	else:
		u.next_attack = tick


func _queue_defender_due(u: Unit, due_tick: int) -> void:
	if u == null:
		return
	_defender_due_tick_by_id[u.id] = due_tick
	var bucket: Dictionary
	if _defender_due.has(due_tick):
		bucket = _defender_due[due_tick]
	else:
		bucket = {}
		_defender_due[due_tick] = bucket
	bucket[u.id] = u


func _register_stationed_unit(u: Unit, slot: String) -> void:
	if u == null or slot == "":
		return
	_defender_slot_by_id[u.id] = slot
	_stationed_unit_by_id[u.id] = u
	_defender_due_tick_by_id.erase(u.id)
	if u.hp <= 0:
		return
	if u.next_attack <= tick:
		if not _defender_ready.has(slot):
			_defender_ready[slot] = []
		var ready: Array = _defender_ready[slot]
		ready.append(u)
	else:
		_queue_defender_due(u, u.next_attack)


func _unregister_stationed_unit(u: Unit) -> void:
	if u == null:
		return
	_defender_slot_by_id.erase(u.id)
	_stationed_unit_by_id.erase(u.id)
	_defender_due_tick_by_id.erase(u.id)
	# Ready/due arrays use lazy stale removal. The identity maps above make any
	# stale entry inert without an O(garrison) erase at movement/death time.


func _rebuild_defender_attack_schedule() -> void:
	_defender_ready.clear()
	_defender_due.clear()
	_defender_due_tick_by_id.clear()
	_defender_slot_by_id.clear()
	_stationed_unit_by_id.clear()
	for d in DIRS:
		var w: Wall = walls[d]
		for u: Unit in w.melee:
			_register_stationed_unit(u, _wall_melee_slot(d))
		for u: Unit in w.ranged:
			_register_stationed_unit(u, _wall_ranged_slot(d))
	for tid in TURRETS:
		var tr: Turret = turrets[tid]
		for u: Unit in tr.melee:
			_register_stationed_unit(u, _turret_melee_slot(tid))
		for u: Unit in tr.ranged:
			_register_stationed_unit(u, _turret_ranged_slot(tid))


func _advance_defender_attack_schedule() -> void:
	if not _defender_due.has(tick):
		return
	var bucket: Dictionary = _defender_due[tick]
	_defender_due.erase(tick)
	for uid in bucket:
		var id: int = int(uid)
		if int(_defender_due_tick_by_id.get(id, -1)) != tick:
			continue
		_defender_due_tick_by_id.erase(id)
		var u: Unit = bucket[uid]
		var slot: String = str(_defender_slot_by_id.get(id, ""))
		if slot == "" or u == null or u.hp <= 0:
			continue
		if _stationed_unit_by_id.get(id) != u:
			continue
		if u.next_attack > tick:
			_queue_defender_due(u, u.next_attack)
			continue
		if not _defender_ready.has(slot):
			_defender_ready[slot] = []
		var ready: Array = _defender_ready[slot]
		ready.append(u)


func _has_ready_defenders(slot: String) -> bool:
	if not _defender_ready.has(slot):
		return false
	var ready: Array = _defender_ready[slot]
	return not ready.is_empty()


func _take_ready_defenders(slot: String) -> Array:
	if not _defender_ready.has(slot):
		return []
	var ready: Array = _defender_ready[slot]
	_defender_ready[slot] = []
	return ready


func _keep_defender_ready(slot: String, u: Unit) -> void:
	if u == null or u.hp <= 0:
		return
	if str(_defender_slot_by_id.get(u.id, "")) != slot:
		return
	if _stationed_unit_by_id.get(u.id) != u:
		return
	if not _defender_ready.has(slot):
		_defender_ready[slot] = []
	var ready: Array = _defender_ready[slot]
	ready.append(u)


func _defender_is_current(u: Unit, slot: String) -> bool:
	if u == null or u.hp <= 0:
		return false
	if str(_defender_slot_by_id.get(u.id, "")) != slot:
		return false
	return _stationed_unit_by_id.get(u.id) == u


func _schedule_defender_after_attack(u: Unit) -> void:
	if u == null:
		return
	u.next_attack = tick + int(u.def["iv"])
	if not _defender_slot_by_id.has(u.id):
		return
	if _stationed_unit_by_id.get(u.id) != u:
		return
	_queue_defender_due(u, u.next_attack)


func _defender_slot_for_unit(u: Unit) -> String:
	if u == null:
		return ""
	if _stationed_unit_by_id.get(u.id) != u:
		return ""
	return str(_defender_slot_by_id.get(u.id, ""))


func _purge_dead_defender_slots(slots: Array) -> void:
	# Only garrisons that actually took lethal damage are scanned, keeping cleanup
	# proportional to affected defender slots rather than all stationed troops.
	for slot_variant in slots:
		var slot: String = str(slot_variant)
		var live: Array = []
		if slot.begins_with("WM:"):
			var wall_melee_dir: String = slot.substr(3)
			for u: Unit in walls[wall_melee_dir].melee:
				if u.hp > 0: live.append(u)
			walls[wall_melee_dir].melee = live
		elif slot.begins_with("WR:"):
			var wall_ranged_dir: String = slot.substr(3)
			for u: Unit in walls[wall_ranged_dir].ranged:
				if u.hp > 0: live.append(u)
			walls[wall_ranged_dir].ranged = live
		elif slot.begins_with("TM:"):
			var turret_melee_id: String = slot.substr(3)
			for u: Unit in turrets[turret_melee_id].melee:
				if u.hp > 0: live.append(u)
			turrets[turret_melee_id].melee = live
		elif slot.begins_with("TR:"):
			var turret_ranged_id: String = slot.substr(3)
			for u: Unit in turrets[turret_ranged_id].ranged:
				if u.hp > 0: live.append(u)
			turrets[turret_ranged_id].ranged = live


func _unregister_stationed_array(arr: Array) -> void:
	for u: Unit in arr:
		_unregister_stationed_unit(u)


func _clear_stationed_slot(arr: Array, slot: String) -> void:
	_unregister_stationed_array(arr)
	_defender_ready[slot] = []


func _mark_unit_damage(u: Unit, dmg: int) -> void:
	if dmg <= 0: return
	if u.damage_mark_tick != tick:
		u.damage_mark_tick = tick
		u.pending_damage = 0
		_dirty_units.append(u)
	u.pending_damage += dmg


func _mark_invader_damage(inv: Invader, dmg: int) -> void:
	if dmg <= 0: return
	if inv.damage_mark_tick != tick:
		inv.damage_mark_tick = tick
		inv.pending_damage = 0
		inv.pending_attr = 0
		_dirty_invaders.append(inv)
	inv.pending_damage += dmg


## If an interior invader is tearing down a building and a defender actually
## damages it, that defender becomes the invader's combat target. This makes
## intervention readable: soldier attacks soldier, and building destruction
## resumes only after the defender is gone or otherwise invalid.
func _retarget_invader_to_sortie_if_attacking_building(inv: Invader, s: Sortie) -> void:
	if not inv.inside or inv.tgt_kind != "b" or s == null or s.dead or s.hp <= 0:
		return
	inv.tgt_kind = "s"
	inv.tgt_id = s.id
	_reset_invader_path(inv)


func _retarget_invader_to_stationed_if_attacking_building(inv: Invader, u: Unit) -> void:
	# Stationed wall/turret defenders that can shoot an interior attacker are ranged.
	# A melee Raider keeps destroying its building rather than abandoning it for a
	# distant Archer it may never reach safely. A ranged Marksman can answer that
	# fire from range, so it retaliates normally.
	if not inv.inside or inv.tgt_kind != "b" or u == null or u.hp <= 0:
		return
	if inv.def["cat"] != "ranged":
		return
	inv.tgt_kind = "u"
	inv.tgt_id = u.id
	_reset_invader_path(inv)


func _mark_invader_attr(inv: Invader, dmg: int) -> void:
	if dmg <= 0: return
	if inv.damage_mark_tick != tick:
		inv.damage_mark_tick = tick
		inv.pending_damage = 0
		inv.pending_attr = 0
		_dirty_invaders.append(inv)
	inv.pending_attr += dmg


func _mark_sortie_damage(s: Sortie, dmg: int) -> void:
	if dmg <= 0: return
	if s.damage_mark_tick != tick:
		s.damage_mark_tick = tick
		s.pending_damage = 0
		_dirty_sorties.append(s)
	s.pending_damage += dmg


func _mark_building_damage(b: Building, dmg: int) -> void:
	if dmg <= 0: return
	if b.damage_mark_tick != tick:
		b.damage_mark_tick = tick
		b.pending_damage = 0
		_dirty_buildings.append(b)
	b.pending_damage += dmg


func _queue_group_melee_wall_strikes(inv: Invader, w: Wall, attacks: Array) -> void:
	CombatSystem.queue_group_melee_wall_strikes(self, inv, w, attacks)

func _move_invaders_and_collect(attacks: Array) -> void:
	InvaderSystem.move_and_collect(self, attacks)

func _collect_invader_ranged_strike(inv: Invader, w: Wall, attacks: Array) -> void:
	CombatSystem.collect_invader_ranged_strike(self, inv, w, attacks)

func _acquire_interior_target(inv: Invader) -> void:
	# Compare candidates in place. This previously allocated one Dictionary per
	# building AND per sortie on every call, then called find_building() - a
	# linear scan - once per candidate inside the distance loop. With thousands
	# of sortied defenders that dominated the simulation. Iteration order and
	# tie order are unchanged (buildings first, then live sorties), so target
	# choice and clockwise tie-breaking are identical.
	var best := 1 << 62
	var ties: Array = []
	var found := false
	for b: Building in buildings:
		found = true
		var dd := _building_distance_sq(b, inv.x, inv.y)
		if dd < best:
			best = dd
			ties = [{"kind": "b", "id": b.id, "px": b.cx, "py": b.cy, "lvl": int(b.def["lvl"])}]
		elif dd == best:
			ties.append({"kind": "b", "id": b.id, "px": b.cx, "py": b.cy, "lvl": int(b.def["lvl"])})
	if not sortied.is_empty():
		var bkt := UpConfigRef.SPATIAL_BUCKET
		var ctr := Vector2i(_floor_div(inv.x, bkt), _floor_div(inv.y, bkt))
		var mring := (GRID * CELL + bkt - 1) / bkt + 2
		var near: Array = []
		var prune := best
		for ring in range(mring + 1):
			for by in range(ctr.y - ring, ctr.y + ring + 1):
				for bx in range(ctr.x - ring, ctr.x + ring + 1):
					if ring > 0 and absi(bx - ctr.x) != ring and absi(by - ctr.y) != ring: continue
					var key := Vector2i(bx, by)
					if not _sortie_buckets.has(key): continue
					for s: Sortie in _sortie_buckets[key]:
						var dd0: int = dist_sq(inv.x, inv.y, s.x, s.y)
						if dd0 <= prune:
							if dd0 < prune: prune = dd0
							near.append(s)
			if prune < (1 << 62):
				var l := (ctr.x - ring) * bkt
				var rr := (ctr.x + ring + 1) * bkt
				var tp := (ctr.y - ring) * bkt
				var bt := (ctr.y + ring + 1) * bkt
				var edge: int = min(min(inv.x - l, rr - inv.x), min(inv.y - tp, bt - inv.y))
				if edge > 0 and edge * edge > prune: break
		if not near.is_empty():
			near.sort_custom(func(a, b): return int(_sortie_index.get(a.id, 0)) < int(_sortie_index.get(b.id, 0)))
			for s: Sortie in near:
				if s.dead or s.hp <= 0: continue
				found = true
				var dd := dist_sq(inv.x, inv.y, s.x, s.y)
				if dd < best:
					best = dd
					ties = [{"kind": "s", "id": s.id, "px": s.x, "py": s.y, "lvl": -1}]
				elif dd == best:
					ties.append({"kind": "s", "id": s.id, "px": s.x, "py": s.y, "lvl": -1})
	if not found:
		for s: Sortie in sortied:
			if not s.dead and s.hp > 0:
				found = true
				break
	if not found:
		inv.tgt_kind = ""; inv.tgt_id = -1; return

	var chosen: Dictionary
	if ties.size() == 1:
		chosen = ties[0]
	else:
		var all_b := true
		for c in ties:
			if c["kind"] != "b": all_b = false; break
		var pool_t := ties
		if all_b:
			var top := -1
			for c in ties: top = max(top, int(c["lvl"]))
			var filtered: Array = []
			for c in ties:
				if int(c["lvl"]) == top: filtered.append(c)
			pool_t = filtered
		chosen = pool_t[0] if pool_t.size() == 1 else _pick_clockwise(inv.hx, inv.hy, inv.x, inv.y, pool_t)
	inv.tgt_kind = chosen["kind"]
	inv.tgt_id = int(chosen["id"])


func _wall_inner_target_point(d: String) -> Vector2i:
	var mid := GRID * CELL / 2
	match d:
		"N": return Vector2i(mid, CELL / 2)
		"S": return Vector2i(mid, GRID * CELL - CELL / 2)
		"W": return Vector2i(CELL / 2, mid)
		_: return Vector2i(GRID * CELL - CELL / 2, mid)


func _turret_inner_target_point(id: String) -> Vector2i:
	match id:
		"NW": return Vector2i(CELL / 2, CELL / 2)
		"NE": return Vector2i(GRID * CELL - CELL / 2, CELL / 2)
		"SE": return Vector2i(GRID * CELL - CELL / 2, GRID * CELL - CELL / 2)
		_: return Vector2i(CELL / 2, GRID * CELL - CELL / 2)


## Stationed wall/turret soldiers do not have their own world coordinates, so
## retaliation resolves them to the interior-facing point of their station.
func _find_stationed_defender(id: int) -> Dictionary:
	for d in DIRS:
		var w: Wall = walls[d]
		for u: Unit in w.melee:
			if u.id == id and u.hp > 0:
				return {"u": u, "p": _wall_inner_target_point(d)}
		for u: Unit in w.ranged:
			if u.id == id and u.hp > 0:
				return {"u": u, "p": _wall_inner_target_point(d)}
	for tid in TURRETS:
		var tr: Turret = turrets[tid]
		if tr.destroyed:
			continue
		for u: Unit in tr.melee:
			if u.id == id and u.hp > 0:
				return {"u": u, "p": _turret_inner_target_point(tid)}
		for u: Unit in tr.ranged:
			if u.id == id and u.hp > 0:
				return {"u": u, "p": _turret_inner_target_point(tid)}
	return {}


func _target_valid(inv: Invader) -> bool:
	if inv.tgt_kind == "b":
		return find_building(inv.tgt_id) != null
	if inv.tgt_kind == "s":
		var s := find_sortie(inv.tgt_id)
		return s != null and not s.dead and s.hp > 0
	if inv.tgt_kind == "u":
		return not _find_stationed_defender(inv.tgt_id).is_empty()
	return false

func _target_point(inv: Invader) -> Vector2i:
	if inv.tgt_kind == "b":
		var b := find_building(inv.tgt_id)
		return Vector2i(b.cx, b.cy) if b else Vector2i(GRID * CELL / 2, GRID * CELL / 2)
	if inv.tgt_kind == "s":
		var s := find_sortie(inv.tgt_id)
		return Vector2i(s.x, s.y) if s else Vector2i(GRID * CELL / 2, GRID * CELL / 2)
	if inv.tgt_kind == "u":
		var rec := _find_stationed_defender(inv.tgt_id)
		return rec["p"] if not rec.is_empty() else Vector2i(GRID * CELL / 2, GRID * CELL / 2)
	return Vector2i(GRID * CELL / 2, GRID * CELL / 2)


func _building_distance_sq(b: Building, px: int, py: int) -> int:
	# Distance to the nearest point on any occupied building cell.
	var best: int = 1 << 62
	for c: Vector2i in b.cells:
		var left := c.x * CELL
		var right := (c.x + 1) * CELL
		var top := c.y * CELL
		var bottom := (c.y + 1) * CELL
		var qx := clampi(px, left, right)
		var qy := clampi(py, top, bottom)
		best = mini(best, dist_sq(px, py, qx, qy))
	return best


func _building_contact_point(b: Building, px: int, py: int) -> Vector2i:
	# Nearest point on the building footprint to the attacker. This is the
	# authoritative final melee destination and also the impact-effect position.
	var best_d: int = 1 << 62
	var best := Vector2i(px, py)
	for c: Vector2i in b.cells:
		var left := c.x * CELL
		var right := (c.x + 1) * CELL
		var top := c.y * CELL
		var bottom := (c.y + 1) * CELL
		var qx := clampi(px, left, right)
		var qy := clampi(py, top, bottom)
		var d := dist_sq(px, py, qx, qy)
		if d < best_d:
			best_d = d
			best = Vector2i(qx, qy)
	return best


func _target_distance_sq(inv: Invader, px: int, py: int) -> int:
	if inv.tgt_kind == "b":
		var b := find_building(inv.tgt_id)
		return _building_distance_sq(b, px, py) if b != null else (1 << 62)
	if inv.tgt_kind == "s":
		var s := find_sortie(inv.tgt_id)
		return dist_sq(px, py, s.x, s.y) if s != null else (1 << 62)
	if inv.tgt_kind == "u":
		var rec := _find_stationed_defender(inv.tgt_id)
		if rec.is_empty():
			return 1 << 62
		var p: Vector2i = rec["p"]
		return dist_sq(px, py, p.x, p.y)
	return 1 << 62


func _move_sorties_and_collect(attacks: Array) -> void:
	var any_inside := false
	for i: Invader in invaders:
		if i.hp > 0 and i.inside:
			any_inside = true
			break

	for s: Sortie in sortied:
		if s.dead or s.hp <= 0: continue
		var inv: Invader = _invader_by_id.get(s.tgt_id) if s.tgt_id >= 0 else null
		if inv == null or inv.hp <= 0 or not inv.inside:
			s.tgt_id = _nearest_invader(s)
			inv = _invader_by_id.get(s.tgt_id) if s.tgt_id >= 0 else null

		if inv == null:
			if not any_inside: _return_to_turret(s)
			continue

		var dx: int = inv.x - s.x
		var dy: int = inv.y - s.y
		var d: int = _isqrt(dx * dx + dy * dy)
		if d > UpConfigRef.REACH:
			s.hx = dx; s.hy = dy
			s.x += dx * UpConfigRef.SPEED_INSIDE / max(1, d)
			s.y += dy * UpConfigRef.SPEED_INSIDE / max(1, d)
			continue
		if tick < s.next_attack: continue
		s.next_attack = tick + int(s.def["iv"])
		_mark_invader_damage(inv, int(s.def["dmg"]) * sortie_members(s))
		_retarget_invader_to_sortie_if_attacking_building(inv, s)


func _bucket_key(x: int, y: int) -> Vector2i:
	return Vector2i(_floor_div(x, UpConfigRef.SPATIAL_BUCKET),
		_floor_div(y, UpConfigRef.SPATIAL_BUCKET))


func _remove_from_bucket(dict: Dictionary, key: Vector2i, inv: Invader) -> void:
	if not dict.has(key):
		return
	var arr: Array = dict[key]
	var idx := arr.find(inv)
	if idx >= 0:
		arr.remove_at(idx)
	if arr.is_empty():
		dict.erase(key)


func _index_invader(inv: Invader) -> void:
	if inv.hp <= 0:
		return
	# During its pre-arrival travel approach the army is presentation-visible
	# but remains non-combat until the authoritative arrival tick.
	# Do not put it in combat target buckets until its announced arrival tick.
	if inv.active_tick > 0 and tick < inv.active_tick:
		inv.indexed = false
		return
	var key := _bucket_key(inv.x, inv.y)
	var dict: Dictionary = _inside_buckets if inv.inside else _outside_buckets
	if not dict.has(key):
		dict[key] = []
	dict[key].append(inv)
	inv.bucket_key = key
	inv.indexed_inside = inv.inside
	inv.indexed = true


func _unindex_invader(inv: Invader) -> void:
	if not inv.indexed:
		return
	var dict: Dictionary = _inside_buckets if inv.indexed_inside else _outside_buckets
	_remove_from_bucket(dict, inv.bucket_key, inv)
	inv.indexed = false


func _sync_invader_index(inv: Invader) -> void:
	if inv.hp <= 0:
		_unindex_invader(inv)
		return
	if inv.active_tick > 0 and tick < inv.active_tick:
		_unindex_invader(inv)
		return
	var key := _bucket_key(inv.x, inv.y)
	if not inv.indexed:
		_index_invader(inv)
		return
	if inv.indexed_inside == inv.inside and inv.bucket_key == key:
		return
	_unindex_invader(inv)
	_index_invader(inv)


func _rebuild_invader_indices() -> void:
	# Debug/full-recovery path only. Normal play uses _sync_invader_index() as
	# groups move, so this O(all groups) rebuild is no longer paid every tick.
	_inside_buckets.clear()
	_outside_buckets.clear()
	for inv: Invader in invaders:
		inv.indexed = false
		_index_invader(inv)


func _rebuild_sortie_buckets() -> void:
	_sortie_buckets.clear()
	_sortie_index.clear()
	var _i: int = 0
	for s0: Sortie in sortied:
		_sortie_index[s0.id] = _i
		_i += 1
	for s: Sortie in sortied:
		if s.dead or s.hp <= 0: continue
		var key := _bucket_key(s.x, s.y)
		if not _sortie_buckets.has(key): _sortie_buckets[key] = []
		_sortie_buckets[key].append(s)


## Exact nearest lookup over a tiny uniform grid. It expands bucket rings until
## the nearest possible point outside the searched square is farther than the
## best unit already found, preserving the same targeting result as a full scan.
func _nearest_invader(s: Sortie) -> int:
	if _inside_buckets.is_empty(): return -1
	var bucket := UpConfigRef.SPATIAL_BUCKET
	var center := Vector2i(_floor_div(s.x, bucket), _floor_div(s.y, bucket))
	var best := 1 << 62
	var ties: Array = []
	var max_ring := (GRID * CELL + bucket - 1) / bucket + 2

	for ring in range(max_ring + 1):
		for by in range(center.y - ring, center.y + ring + 1):
			for bx in range(center.x - ring, center.x + ring + 1):
				if ring > 0 and absi(bx - center.x) != ring and absi(by - center.y) != ring:
					continue
				var key := Vector2i(bx, by)
				if not _inside_buckets.has(key): continue
				for i: Invader in _inside_buckets[key]:
					if i.hp <= 0 or not invader_combat_active(i): continue
					var dd: int = dist_sq(s.x, s.y, i.x, i.y)
					if dd < best: best = dd; ties = [i]
					elif dd == best: ties.append(i)

		if best < (1 << 62):
			var left := (center.x - ring) * bucket
			var right := (center.x + ring + 1) * bucket
			var top := (center.y - ring) * bucket
			var bottom := (center.y + ring + 1) * bucket
			var edge_dist: int = min(min(s.x - left, right - s.x), min(s.y - top, bottom - s.y))
			if edge_dist > 0 and edge_dist * edge_dist > best:
				break
		elif ring >= SORTIE_RING_BAILOUT:
			# Nothing found within a few rings: the targets are far away, and
			# continuing would probe hundreds of empty bucket coordinates (39us
			# per call, ~150ms across thousands of sorties on the tick they
			# deploy). The live inside set is only a few hundred groups, so scan
			# it directly instead. This is a bailout, not a replacement - the
			# fast near-target path above is untouched.
			for i: Invader in invaders:
				if not i.inside or i.hp <= 0 or not invader_combat_active(i): continue
				var dd2: int = dist_sq(s.x, s.y, i.x, i.y)
				if dd2 < best: best = dd2; ties = [i]
				elif dd2 == best: ties.append(i)
			break

	if ties.is_empty(): return -1
	if ties.size() == 1: return ties[0].id
	var cands: Array = []
	for i: Invader in ties:
		cands.append({"kind": "i", "id": i.id, "px": i.x, "py": i.y})
	return int(_pick_clockwise(s.hx, s.hy, s.x, s.y, cands)["id"])


## §6.7 interior clear: return to the closest standing turret. If none stands,
## hold position as an interior garrison until one becomes operational again.
func _return_to_turret(s: Sortie) -> void:
	var best := ""
	var bd := 1 << 62
	for tid in TURRETS:
		if turrets[tid].destroyed: continue
		var p := turret_point(tid)
		var dd: int = dist_sq(s.x, s.y, p.x, p.y)
		if dd < bd: bd = dd; best = tid
	if best == "": return

	var p := turret_point(best)
	var dx: int = p.x - s.x
	var dy: int = p.y - s.y
	var d: int = _isqrt(dx * dx + dy * dy)
	if d < UpConfigRef.REACH:
		var u := Unit.new(s.id, s.def, sortie_members(s))
		u.hp = s.hp; u.group_size = unit_members(u); u.next_attack = s.next_attack
		turrets[best].melee.append(u)
		var slot: String = _turret_melee_slot(best)
		_register_stationed_unit(u, slot)
		_rebalance_stationed_slot(turrets[best].melee, slot)
		s.dead = true
	else:
		s.x += dx * UpConfigRef.SPEED_INSIDE / max(1, d)
		s.y += dy * UpConfigRef.SPEED_INSIDE / max(1, d)


# ---------------------------------------------------------------------------
# Defending wall melee
# ---------------------------------------------------------------------------

func _collect_defending_wall_melee(attacks: Array) -> void:
	CombatSystem.collect_defending_wall_melee(self, attacks)

func _collect_defending_ranged(attacks: Array) -> void:
	CombatSystem.collect_defending_ranged(self, attacks)

func _collect_wall_ranged(arr: Array, wall_dir: String, from: Vector2i, axis: Vector2i, attacks: Array) -> void:
	CombatSystem.collect_wall_ranged(self, arr, wall_dir, from, axis, attacks)

func _collect_turret_ranged(arr: Array, tid: String, from: Vector2i, attacks: Array) -> void:
	CombatSystem.collect_turret_ranged(self, arr, tid, from, attacks)

func _turret_range_sq(tid: String, from: Vector2i) -> int:
	# Normal turret range for interior targets and exterior troops that are not yet
	# attacking the wall. Wall-attacking ranged invaders get a separate guaranteed
	# response rule below so they can never sit in an unanswered firing pocket.
	var mid: Vector2i = wall_point(TURRET_WALLS[tid][0])
	return dist_sq(from.x, from.y, mid.x, mid.y)


func _invader_ranged_attacking_wall(inv: Invader, wall_dir: String) -> bool:
	if inv == null or inv.hp <= 0 or inv.inside:
		return false
	if str(inv.def.get("cat", "")) != "ranged" or inv.wall != wall_dir:
		return false
	if not _invader_physically_outside_wall(inv, wall_dir):
		return false
	var wp: Vector2i = wall_point(wall_dir)
	var perp: int = absi(inv.y - wp.y) if wall_dir == "N" or wall_dir == "S" else absi(inv.x - wp.x)
	var attack_range: int = mini(int(inv.def.get("range", UpConfigRef.REACH)), UpConfigRef.INVADER_WALL_RANGED_MAX)
	return perp <= attack_range


func _exterior_invader_engagement_eligible(inv: Invader, wall_dir: String) -> bool:
	# One authoritative exterior engagement boundary. Before a particular invading
	# group reaches the point where it can legally attack, defenders may not damage
	# it either. This keeps the banner countdown, attacker range and defender reply
	# range synchronized instead of allowing pre-arrival kills.
	if inv == null or inv.hp <= 0 or inv.inside or inv.wall != wall_dir:
		return false
	if not invader_combat_active(inv):
		return false
	if not _invader_physically_outside_wall(inv, wall_dir):
		return false
	if str(inv.def.get("cat", "")) == "ranged":
		return _invader_ranged_attacking_wall(inv, wall_dir)
	# Melee has zero ranged envelope: it becomes targetable at the same instant it
	# becomes able to strike the wall — physical first contact.
	if not inv.at_wall or inv.wall_contact_tick < 0:
		return false
	var contact: Vector2i = invader_melee_wall_contact_point(wall_dir, inv.wall_lane)
	return inv.x == contact.x and inv.y == contact.y


func _turret_covers_lane(tid: String, wall: String, lane: int) -> bool:
	if not (wall in TURRET_WALLS[tid]): return false
	var mid := GRID * CELL / 2
	match tid:
		"NW": return lane <= mid  # west half of N, north half of W
		"NE": return lane >= mid if wall == "N" else lane <= mid
		"SE": return lane >= mid
		"SW": return lane <= mid if wall == "S" else lane >= mid
	return false


func _nearest_turret_invaders(tid: String, from: Vector2i, limit: int) -> Array:
	# Interior targets retain the turret's normal radial coverage. Exterior targets
	# use that coverage too, EXCEPT for a ranged invader that is already close
	# enough to damage one of this turret's connected walls. In that case the
	# appropriate corner turret is guaranteed to be able to answer it. This makes
	# the rule reciprocal: an invading archer cannot damage a defended wall from a
	# position where both adjacent turrets are unable to return fire.
	if limit <= 0:
		return []
	var max_sq: int = _turret_range_sq(tid, from)
	var combined: Array = []
	combined.append_array(_nearest_bucketed_visible(from, max_sq, true, limit, tid))

	for inv: Invader in invaders:
		if inv.hp <= 0 or inv.inside:
			continue
		if not (inv.wall in TURRET_WALLS[tid]):
			continue
		if not _turret_covers_lane(tid, inv.wall, inv.wall_lane):
			continue
		if not _exterior_invader_engagement_eligible(inv, inv.wall):
			continue
		var d: int = dist_sq(from.x, from.y, inv.x, inv.y)
		var guaranteed_reply: bool = _invader_ranged_attacking_wall(inv, inv.wall)
		if not guaranteed_reply and d > max_sq:
			continue
		combined.append({"d": d, "u": inv})

	combined.sort_custom(func(a, b):
		if int(a["d"]) != int(b["d"]):
			return int(a["d"]) < int(b["d"])
		return int(a["u"].id) < int(b["u"].id))
	if combined.size() > limit:
		combined.resize(limit)
	return combined


func _nearest_wall_front_invaders_combined(from: Vector2i, wall_dir: String, range_limit: int, limit: int) -> Array:
	# Wall archers likewise consider interior and exterior threats together.
	# Exterior candidates must be physically in front of this wall; interior
	# candidates can be anywhere inside the fiefdom if range/LOS permits.
	if limit <= 0:
		return []
	var combined: Array = []
	combined.append_array(_nearest_wall_front_invaders(from, wall_dir, range_limit, true, limit))
	combined.append_array(_nearest_wall_front_invaders(from, wall_dir, range_limit, false, limit))
	combined.sort_custom(func(a, b):
		if int(a["d"]) != int(b["d"]):
			return int(a["d"]) < int(b["d"])
		return int(a["u"].id) < int(b["u"].id))
	if combined.size() > limit:
		combined.resize(limit)
	return combined


func _max_ranged_range(arr: Array) -> int:
	var r := 0
	for u: Unit in arr:
		r = max(r, int(u.def.get("range", 0)))
	return r


func _nearest_visible_invader(from: Vector2i, range_limit: int) -> Invader:
	var inside := _nearest_visible_invaders_filtered(from, range_limit, true, 1)
	if not inside.is_empty(): return inside[0]["u"]
	var outside := _nearest_visible_invaders_filtered(from, range_limit, false, 1)
	return null if outside.is_empty() else outside[0]["u"]


func _nearest_visible_invaders(from: Vector2i, range_limit: int, limit: int) -> Array:
	var inside := _nearest_visible_invaders_filtered(from, range_limit, true, limit)
	if not inside.is_empty(): return inside
	return _nearest_visible_invaders_filtered(from, range_limit, false, limit)


func _nearest_visible_invaders_filtered(from: Vector2i, range_limit: int, inside_only: bool, limit: int) -> Array:
	return _nearest_bucketed_visible(from, range_limit * range_limit, inside_only, limit, "")


func _invader_physically_inside_fiefdom(inv: Invader) -> bool:
	# Use authoritative world coordinates as the final source of truth for wall
	# archer targeting.  The `inside` flag is useful for movement/indexing, but a
	# stale or transitional flag must never let a wall shoot across the fortress.
	var span: int = GRID * CELL
	return inv.x >= 0 and inv.x <= span and inv.y >= 0 and inv.y <= span


func _invader_physically_outside_wall(inv: Invader, wall_dir: String) -> bool:
	var span: int = GRID * CELL
	match wall_dir:
		"N": return inv.y < 0 and inv.x >= 0 and inv.x <= span
		"S": return inv.y > span and inv.x >= 0 and inv.x <= span
		"W": return inv.x < 0 and inv.y >= 0 and inv.y <= span
		"E": return inv.x > span and inv.y >= 0 and inv.y <= span
		_: return false


func _in_front_of_wall(inv: Invader, wall_dir: String, inside_only: bool) -> bool:
	if inside_only:
		# Once an invader has actually breached the perimeter, every wall archer may
		# shoot it if normal range/LOS permits.  Interior enemies are no longer
		# artificially divided into wall wedges.
		return _invader_physically_inside_fiefdom(inv)

	# Outside the perimeter, a wall may ONLY engage attackers assigned to that
	# same wall AND physically standing outside that wall face.  The geometric
	# check prevents stale state or corner transitions from making North-wall
	# archers shoot a group visibly in front of West/East/South.
	return inv.wall == wall_dir and _invader_physically_outside_wall(inv, wall_dir)


func _nearest_wall_front_invaders(from: Vector2i, wall_dir: String, range_limit: int, inside_only: bool, limit: int) -> Array:
	if limit <= 0:
		return []
	var buckets: Dictionary = _inside_buckets if inside_only else _outside_buckets
	if buckets.is_empty():
		return []

	var max_sq := range_limit * range_limit
	var bucket := UpConfigRef.SPATIAL_BUCKET
	var min_bx := _floor_div(from.x - range_limit, bucket)
	var max_bx := _floor_div(from.x + range_limit, bucket)
	var min_by := _floor_div(from.y - range_limit, bucket)
	var max_by := _floor_div(from.y + range_limit, bucket)
	var best: Array = []

	for by in range(min_by, max_by + 1):
		for bx in range(min_bx, max_bx + 1):
			var key := Vector2i(bx, by)
			if not buckets.has(key):
				continue
			for inv: Invader in buckets[key]:
				if inv.hp <= 0 or not invader_combat_active(inv) or not _in_front_of_wall(inv, wall_dir, inside_only):
					continue
				if not inside_only and not _exterior_invader_engagement_eligible(inv, wall_dir):
					continue
				# For exterior threats a wall garrison spans the whole parapet, so the
				# cheapest possible shot is perpendicular to the wall.  Do not prefilter
				# from the wall midpoint: that used to create untargetable end-of-wall
				# pockets even though a defender stood much closer along the parapet.
				var horiz: bool = wall_dir == "N" or wall_dir == "S"
				var inv_lane: int = inv.x if horiz else inv.y
				var inv_perp: int = absi(inv.y - from.y) if horiz else absi(inv.x - from.x)
				var d: int = dist_sq(from.x, from.y, inv.x, inv.y) if inside_only else inv_perp * inv_perp
				if d > max_sq:
					continue
				# Interior invaders are valid wall-archer targets anywhere inside normal
				# range. Buildings do not shield them from parapet fire; this matches the
				# gameplay rule that wall archers may fire on any invader in the fiefdom.
				# Keep the LOS gate only for exterior candidates.
				if not inside_only and not _has_building_los(from.x, from.y, inv.x, inv.y):
					continue
				var entry := {"d": d, "u": inv, "lane": inv_lane, "perp": inv_perp}
				var pos := best.size()
				for j in best.size():
					if d < int(best[j]["d"]):
						pos = j
						break
				best.insert(pos, entry)
				if best.size() > limit:
					best.pop_back()
	return best


func _nearest_bucketed_visible(from: Vector2i, max_sq: int, inside_only: bool, limit: int, turret_id: String) -> Array:
	if limit <= 0: return []
	var buckets: Dictionary = _inside_buckets if inside_only else _outside_buckets
	if buckets.is_empty(): return []

	var bucket: int = UpConfigRef.SPATIAL_BUCKET
	var radius: int = _isqrt(max_sq)
	var min_bx: int = _floor_div(from.x - radius, bucket)
	var max_bx: int = _floor_div(from.x + radius, bucket)
	var min_by: int = _floor_div(from.y - radius, bucket)
	var max_by: int = _floor_div(from.y + radius, bucket)
	var best: Array = []

	for by in range(min_by, max_by + 1):
		for bx in range(min_bx, max_bx + 1):
			var key := Vector2i(bx, by)
			if not buckets.has(key): continue
			for inv: Invader in buckets[key]:
				if inv.hp <= 0: continue
				if not invader_combat_active(inv): continue
				if turret_id != "" and not inv.inside:
					if not (inv.wall in TURRET_WALLS[turret_id]): continue
					if not _turret_covers_lane(turret_id, inv.wall, inv.wall_lane): continue
				var d: int = dist_sq(from.x, from.y, inv.x, inv.y)
				if d > max_sq: continue
				# Turret archers also keep full interior coverage within their half-wall
				# radius; courtyard buildings do not make an invader untargetable.
				if not inside_only and not _has_building_los(from.x, from.y, inv.x, inv.y): continue
				var entry := {"d": d, "u": inv}
				var pos := best.size()
				for j in best.size():
					if d < int(best[j]["d"]):
						pos = j
						break
				best.insert(pos, entry)
				if best.size() > limit:
					best.pop_back()
	return best


## Integer grid traversal for §6.6 line of sight. The shooter's cell and the
## target's cell are ignored; any occupied cell strictly between them blocks fire.
func _has_building_los(ax: int, ay: int, bx: int, by: int) -> bool:
	var x0 := _floor_div(ax, CELL)
	var y0 := _floor_div(ay, CELL)
	var x1 := _floor_div(bx, CELL)
	var y1 := _floor_div(by, CELL)
	var dx := absi(x1 - x0)
	var sx := 1 if x0 < x1 else -1
	var dy := -absi(y1 - y0)
	var sy := 1 if y0 < y1 else -1
	var err := dx + dy
	var first := true
	while true:
		if not first and not (x0 == x1 and y0 == y1):
			if x0 >= 0 and y0 >= 0 and x0 < GRID and y0 < GRID:
				if occupancy[y0 * GRID + x0] != 0: return false
		if x0 == x1 and y0 == y1: break
		first = false
		var e2 := 2 * err
		if e2 >= dy:
			err += dy; x0 += sx
		if e2 <= dx:
			err += dx; y0 += sy
	return true


func _apply_combat(attacks: Array) -> void:
	CombatSystem.apply_combat(self, attacks)

## True when (x, y) lies strictly within the union of building cells. Tests the
## four diagonal neighbours rather than the point itself: a point on a building's
## OUTER edge has at least one empty neighbour (touching, which Raiders need for
## MELEE_STRUCTURE_REACH = 0), while a point on an INTERNAL edge between two cells
## of the same building is surrounded and correctly counts as inside.
func _point_inside_building(x: int, y: int) -> bool:
	for dx in [-1, 1]:
		for dy in [-1, 1]:
			var px: int = x + dx
			var py: int = y + dy
			if px < 0 or py < 0:
				return false
			var cx: int = px / CELL
			var cy: int = py / CELL
			if cx >= GRID or cy >= GRID:
				return false
			if occupancy[cy * GRID + cx] == 0:
				return false
	return true


func _merge_invader_groups() -> void:
	var reps := {}
	for inv: Invader in invaders:
		if inv.hp <= 0:
			continue
		# Keep approaching and wall-fighting groups separate. Combining them here
		# makes many visible soldiers disappear together when that merged group's
		# HP reaches zero. Interior groups may still merge for performance.
		if not inv.inside:
			continue
		# Merge only genuinely equivalent groups in the SAME grid cell. A 2-cell
		# spatial bucket is too coarse for collision semantics: averaging groups
		# from opposite sides of a building could effectively teleport strength
		# through that building.
		var cell_x := clampi(inv.x / CELL, 0, GRID - 1)
		var cell_y := clampi(inv.y / CELL, 0, GRID - 1)
		var key := "%d|%s|%s|%s|%s|%d|%d|%d" % [
			inv.army_id, str(inv.def["cat"]), inv.wall,
			"1" if inv.inside else "0", inv.tgt_kind, inv.tgt_id,
			cell_x, cell_y]
		if not reps.has(key):
			reps[key] = inv
			continue
		var rep: Invader = reps[key]
		var rep_members := invader_members(rep)
		var add_members := invader_members(inv)
		var total_members := rep_members + add_members
		if total_members <= 0:
			continue
		# Do not average positions when merging. The representative stays at a
		# position already proven legal by movement/collision rules; only its
		# represented strength changes.
		rep.hp += inv.hp
		rep.group_size = invader_members(rep)
		rep.next_attack = mini(rep.next_attack, inv.next_attack)
		inv.hp = 0
		_sync_invader_index(rep)
		_unindex_invader(inv)
		_invader_by_id.erase(inv.id) # merge bookkeeping, not a kill


## Remove dead defenders from every wall and turret garrison. Damage is now
## deferred and applied in bulk, so dead units linger in these arrays until this
## runs. It must run after each resolution interval: Wall.hp() sums every unit in
## .melee, so a corpse left behind at negative HP would lower the wall's total,
## inflate the melee count shown to the player, and misfire the collapse check.
## (Restored — it was removed in the performance pass but its call site remained.)
func _purge_defender_units() -> void:
	# Compatibility/full-rebuild path for diagnostics. Normal combat uses
	# _purge_dead_defender_slots() so untouched garrisons are never scanned.
	var all_slots: Array = []
	for d in DIRS:
		all_slots.append(_wall_melee_slot(d))
		all_slots.append(_wall_ranged_slot(d))
	for tid in TURRETS:
		all_slots.append(_turret_melee_slot(tid))
		all_slots.append(_turret_ranged_slot(tid))
	_purge_dead_defender_slots(all_slots)


func _purge_dead_combatants() -> void:
	var inv_live: Array = []
	for inv: Invader in invaders:
		if inv.hp > 0:
			inv_live.append(inv)
		else:
			# Casualties and skull feedback are recorded at the exact damage
			# transition in CombatSystem.apply_combat(). Purging only removes the
			# now-empty simulation object; merged-away groups therefore never count
			# as deaths.
			_unindex_invader(inv)
			_invader_by_id.erase(inv.id)
	invaders = inv_live

	var sortie_live: Array = []
	for s: Sortie in sortied:
		if not s.dead and s.hp > 0:
			sortie_live.append(s)
		else:
			_sortie_by_id.erase(s.id)
	sortied = sortie_live

# ---------------------------------------------------------------------------
# Wall collapse, restoration, turrets (§7.3, §7.4)
# ---------------------------------------------------------------------------

func _player_turret_should_be_destroyed(tid: String) -> bool:
	for d in TURRET_WALLS[tid]:
		var support_wall: Wall = walls[d]
		if not support_wall.collapsed or support_wall.hp() > 0:
			return false
	return true


func _step_walls() -> void:
	for d in DIRS:
		var w: Wall = walls[d]
		if w.cooldown > 0: w.cooldown -= 1

		if not w.collapsed and w.hp() < UpConfigRef.HP_COLLAPSE:
			w.collapsed = true
			w.collapse_tick = tick
			w.cooldown = UpConfigRef.REBUILD_COOLDOWN
			_clear_stationed_slot(w.melee, _wall_melee_slot(d))
			_clear_stationed_slot(w.ranged, _wall_ranged_slot(d))
			w.melee.clear()                       # remaining defenders go down with it
			var lost_ranged := garrison_count(w.ranged)
			w.ranged.clear()                      # §6.6 ranged on the wall die too
			var extra := "" if lost_ranged == 0 else " — %d ranged lost" % lost_ranged
			log_msg("The %s wall has collapsed%s." % [dir_name(d), extra], "bad")
			for inv: Invader in invaders:
				if inv.wall == d and not inv.inside:
					inv.at_wall = false


		if w.collapsed and w.hp() >= UpConfigRef.HP_FULL:
			w.collapsed = false
			w.collapse_tick = -1
			log_msg("The %s wall is fully rebuilt and standing again." % dir_name(d), "good")

	# §7.4 a turret falls only when BOTH connected walls are completely down.
	# A single standing wall can support it. Once rebuilding has actually begun
	# on either collapsed wall (melee HP > 0 after the cooldown), the round tower
	# is rebuilt with that wall immediately; the wall itself can remain collapsed
	# until it reaches HP_FULL.
	for tid in TURRETS:
		var tr: Turret = turrets[tid]
		var down: bool = _player_turret_should_be_destroyed(tid)
		if down and not tr.destroyed:
			tr.destroyed = true
			var n := garrison_count(tr.melee) + garrison_count(tr.ranged)
			_clear_stationed_slot(tr.melee, _turret_melee_slot(tid))
			_clear_stationed_slot(tr.ranged, _turret_ranged_slot(tid))
			tr.melee.clear(); tr.ranged.clear()
			var extra := "" if n == 0 else " — %d lost" % n
			log_msg("%s turret destroyed%s." % [tid, extra], "bad")
		elif not down and tr.destroyed:
			tr.destroyed = false
			log_msg("%s turret is operational again." % tid, "good")
		else:
			# Keep the stored state synchronized every tick so load/rollback or other
			# code paths can never leave a tower visually standing after both support
			# walls are down.
			tr.destroyed = down

# ---------------------------------------------------------------------------

func _record_invader_death_floats(inv: Invader, casualties: int) -> void:
	if inv == null or casualties <= 0:
		return
	var d := DeathFloat.new()
	d.x = inv.x
	d.y = inv.y
	d.fired = tick
	d.seed = inv.id * 1009 + tick * 9176
	d.count = casualties
	death_floats.append(d)
	# Cap lightweight EVENTS, not skulls. A single event representing 500 actual
	# casualties still renders all 500 skull-and-crossbones.
	if death_floats.size() > UpConfigRef.MAX_DEATH_FLOAT_EVENTS:
		death_floats.pop_front()


func _record_melee_impact(x: int, y: int) -> void:
	var hit := MeleeImpact.new()
	hit.x = x
	hit.y = y
	hit.fired = tick
	melee_impacts.append(hit)
	if melee_impacts.size() > UpConfigRef.MAX_MELEE_IMPACTS:
		melee_impacts.pop_front()


func _record_shot(fx: int, fy: int, tx: int, ty: int, hostile: bool) -> void:
	if shots.size() >= UpConfigRef.MAX_SHOTS: return
	var sh := Shot.new()
	sh.fx = fx; sh.fy = fy; sh.tx = tx; sh.ty = ty
	sh.fired = tick; sh.hostile = hostile
	shots.append(sh)


## Deterministic lateral scatter so a rank of archers does not fire from one point.
static func _scatter(id: int, amount: int) -> Vector2i:
	return Vector2i(((id * 37) % 101 - 50) * amount / 50, ((id * 61) % 101 - 50) * amount / 50)


func log_msg(text: String, kind: String = "") -> void:
	var l := LogLine.new()
	l.tick = tick
	l.text = text
	l.kind = kind
	log_lines.push_front(l)
	if log_lines.size() > 300:
		log_lines.pop_back()
	log_version += 1
