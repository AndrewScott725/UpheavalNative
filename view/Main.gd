extends Control
const UpConfigRef = preload("res://sim/UpConfig.gd")

## Wires the simulation to the presentation.
##
## Layout follows the reference mockup: a full-bleed board with opaque panels
## anchored over it. The UI only reads state and emits action requests (§16.1,
## §16.2) — it never mutates the match.

const BoardViewScene = preload("res://view/BoardView.tscn")
const S := UpConfigRef.S
const TPS := UpConfigRef.TPS

const W_LEFT := 285.0      ## Buildings column
const W_RIGHT := 285.0     ## Surrounding Fiefdoms column
const W_EVENT_LOG := W_RIGHT ## Event log aligns exactly under Surrounding Fiefdoms
const W_WARCAMP := 540.0   ## War Camps sit immediately left of Event Log
const H_TOP := 128.0       ## crest / treasury / banner / logo strip
const H_BOTTOM := 168.0    ## Barracks / War Camps / Event Log
const H_DATE_TIME := 72.0  ## Date/Time strip between fiefdoms and Event Log
const HUD_HEAVY_INTERVAL_MSEC := 300 ## expensive style/list refresh cadence

const C_PANEL := Color("13233a")
const C_PANEL_DK := Color("0d1a2c")
const C_PARCH := Color("f2ece0")
const C_PARCH_LOCK := Color("b9b8b4")
const C_GOLD := Color("f0c85f")
const C_GOLD_DK := Color("8d7433")
const C_BLOOD := Color("9e1f1f")
const C_TEXT := Color("fffaf0")
const C_DIM := Color("c7d1dd")

var m: UpMatch
var accum: float = 0.0

const NET_PORT := 27777
const NET_MAX_CLIENTS := 3
const NET_INPUT_DELAY_TICKS := 1
const NET_BATTLE_SNAPSHOT_INTERVAL_TICKS := 2 # 5 authoritative battlefield updates/sec while combat is active
const NET_BATTLE_IDLE_SNAPSHOT_INTERVAL_TICKS := 30 # 1 idle heartbeat every 3s; commands already replicate non-combat state

var local_player_id: int = 0
var match_active: bool = false
var is_network_host: bool = false
## True only while an actual ENet session is running. Solo matches against AI
## use no peer at all, and both the action path and the step gate below must
## take their offline branch or the match cannot start.
var is_network_match: bool = false
var peer_to_player: Dictionary = {}
var queued_net_actions: Array = []
var net_sequence: int = 0
var host_tick_seen: int = 0
var _last_tick_sync: int = -1
var battle_authority_peer: Dictionary = {} # player id -> ENet peer id
var last_battle_snapshot_tick: Dictionary = {}
var last_battle_snapshot_sent_tick: Dictionary = {}
var last_battle_snapshot_active: Dictionary = {}
var reported_rival_defeats: Dictionary = {} # pid -> true once reliable defeat was announced

var name_gate: PanelContainer
var name_input: LineEdit
var local_kingdom_name: String = ""
var player_kingdom_names: Dictionary = {}

var net_lobby: PanelContainer
var net_status: Label
var net_ip: LineEdit
var net_start_btn: Button
var net_slot_label: Label
var lbl_faction_name: Label
var home_crest: UpIcons.Herald
var ironcrest_target_row: Dictionary = {}

var sel_building: Dictionary = {}
var sel_rot: int = 0
var sel_cat: String = ""
var sel_camp: int = -1

var f_disp: Font
var f_logo: Font
var f_body: Font
var f_bold: Font

var board: BoardView
var battlefield_clip: Control
var hud_root: Control
var btn_home_fiefdom: Button
var lbl_treasury: Label
var lbl_treasury_rate: Label
var lbl_building_count: Label
var banner_box: GridContainer
var banner_rows := []
var build_rows := {}
var soldier_rows := {}
var camp_rows := []
var rival_rows := []
var rival_list: VBoxContainer
var log_box: VBoxContainer
var log_scroll: ScrollContainer
var log_rows := []
var displayed_log_version: int = -1
var lbl_day: Label
var lbl_remaining: Label
var lbl_ai_type: Label
var lbl_barracks_head: Label
var lbl_hint: Label
var viewed_fiefdom_name_row: HBoxContainer
var lbl_viewed_fiefdom_name: Label
var viewed_fiefdom_banner_left
var viewed_fiefdom_banner_right
var over_center: CenterContainer
var over_panel: PanelContainer
var lbl_over_title: Label
var start_panel: PanelContainer
var lbl_start_countdown: Label
var skill_blocker: ColorRect
var skill_center: CenterContainer
var skill_panel: PanelContainer
var selected_skill: String = ""
var lbl_over_1: Label
var lbl_over_2: Label
var sim_ms_avg: float = 0.0
var sim_ms_worst: float = 0.0
var _hud_force_heavy: bool = true
var _last_heavy_hud_msec: int = 0

# Audio presentation ---------------------------------------------------------
var audio_music: AudioStreamPlayer
var audio_trumpet: AudioStreamPlayer
var audio_crumble: AudioStreamPlayer
var audio_stone: AudioStreamPlayer
var audio_clash: AudioStreamPlayer
var audio_courtyard_battle: AudioStreamPlayer
var audio_wood: AudioStreamPlayer
var audio_place: AudioStreamPlayer
var audio_voice: AudioStreamPlayer
var _voice_queue: Array[AudioStream] = []
var _seen_incoming_audio: Dictionary = {}
var _prev_wall_down_audio: Dictionary = {}
var _prev_tower_down_audio: Dictionary = {}
var _last_stone_audio_msec: int = 0
var _last_clash_audio_msec: int = 0
var _last_wood_audio_msec: int = 0
var _wall_voice: Dictionary = {}
var _tower_voice: Dictionary = {}
var _kingdom_fallen_voice: AudioStream = null
var _prev_fiefdom_defeated: Dictionary = {} # player id -> last observed elimination state


func _ready() -> void:
	_load_fonts()
	_setup_audio()
	_build_ui()
	_build_network_lobby()
	_build_name_prompt()
	_show_name_prompt()
	set_process(true)
	get_viewport().size_changed.connect(_relayout)


func _load_fonts() -> void:
	f_disp = _font("res://fonts/Cinzel.ttf")
	f_logo = _font("res://fonts/PirataOne.ttf")
	f_body = _font("res://fonts/Barlow-Regular.ttf")
	f_bold = _font("res://fonts/Barlow-Bold.ttf")


func _font(path: String) -> Font:
	if ResourceLoader.exists(path):
		var f = load(path)
		if f is Font: return f
	return ThemeDB.fallback_font


func _start() -> void:
	# PLAY AGAIN returns everyone to the connection screen. Starting another
	# network match requires the host to create a fresh lobby.
	_disconnect_network()
	_show_network_lobby()


func _choose_skill(level: String) -> void:
	selected_skill = level
	_begin_match(level, 0, [0], {0: local_kingdom_name})
	skill_panel.visible = false
	skill_blocker.visible = false


func _begin_match(level: String, seed_value: int = 0, human_slots: Array = [0], kingdom_names: Dictionary = {}) -> void:
	var actual_seed: int = seed_value if seed_value != 0 else int(Time.get_ticks_msec())
	m = UpMatch.new(actual_seed, level)
	m.configure_human_players(human_slots)
	var applied_names: Dictionary = kingdom_names.duplicate(true)
	if applied_names.is_empty() and not local_kingdom_name.is_empty():
		applied_names[0] = local_kingdom_name
	m.configure_player_names(applied_names)
	match_active = true
	accum = 0.0
	sim_ms_avg = 0.0
	sim_ms_worst = 0.0
	displayed_log_version = -1
	sel_building = {}
	sel_cat = ""
	sel_camp = -1
	sel_rot = 0
	_reset_audio_tracking()
	_start_match_music()
	board.match_ref = m
	board.local_player_id = local_player_id
	board.recon_rival_index = -1 if local_player_id == 0 else local_player_id - 1
	board.reset_view()
	board.ghost_def = {}
	board.arm_cat = ""
	over_panel.visible = false
	_rebuild_rival_rows()
	_refresh(true)
	board.queue_redraw()


func _process(delta: float) -> void:
	if not match_active or m == null:
		return
	accum = min(accum + delta, UpConfigRef.MAX_ACCUM_SECONDS)
	var stept := 1.0 / float(TPS)
	var steps := 0
	var total_usec := 0
	while accum >= stept and steps < UpConfigRef.MAX_CATCHUP_STEPS:
		if not _network_can_step():
			break
		_apply_due_network_actions()
		var t0 := Time.get_ticks_usec()
		m.step()
		_maybe_broadcast_tick()
		_maybe_publish_battle_snapshots()
		total_usec += Time.get_ticks_usec() - t0
		accum -= stept
		steps += 1
	if steps >= UpConfigRef.MAX_CATCHUP_STEPS and accum >= stept:
		# Drop excess backlog rather than entering a death spiral of catch-up ticks.
		accum = fmod(accum, stept)

	# Presentation runs independently of the authoritative 10 TPS simulation.
	board.render_alpha = clampf(accum / stept, 0.0, 1.0)

	if steps > 0:
		var sample_ms := float(total_usec) / 1000.0 / float(steps)
		sim_ms_avg = sample_ms if sim_ms_avg <= 0.0 else lerpf(sim_ms_avg, sample_ms, 0.15)
		sim_ms_worst = maxf(sim_ms_worst * 0.995, sample_ms)
		_refresh(_hud_force_heavy)
		_hud_force_heavy = false
	elif _hud_force_heavy:
		# User interaction can demand an immediate style/selection refresh without
		# waiting for the next simulation tick.
		_refresh(true)
		_hud_force_heavy = false

	_update_audio_events()


func _new_audio_player(volume_db: float) -> AudioStreamPlayer:
	var p := AudioStreamPlayer.new()
	p.volume_db = volume_db
	add_child(p)
	return p


func _load_wav_runtime(path: String, should_loop: bool = false) -> AudioStreamWAV:
	# Load WAV bytes directly from res:// instead of relying on Godot's imported
	# .sample cache. This keeps audio working even when the editor has not yet
	# generated .import/.godot metadata for a freshly extracted prototype.
	var bytes: PackedByteArray = FileAccess.get_file_as_bytes(path)
	if bytes.is_empty():
		push_error("Unable to read audio file: %s" % path)
		return null
	var stream := AudioStreamWAV.load_from_buffer(bytes)
	if stream == null:
		push_error("Unable to decode WAV audio: %s" % path)
		return null
	if should_loop:
		stream.loop_mode = AudioStreamWAV.LOOP_FORWARD
	return stream


func _load_mp3_runtime(path: String, should_loop: bool = false) -> AudioStreamMP3:
	# Background music uses MP3's native runtime loader. Unlike an imported
	# resource, this reads the shipped file directly and does not depend on the
	# editor's .godot/import cache.
	var stream := AudioStreamMP3.load_from_file(path)
	if stream == null:
		push_error("Unable to decode MP3 audio: %s" % path)
		return null
	stream.loop = should_loop
	stream.loop_offset = 0.0
	return stream


func _setup_audio() -> void:
	audio_music = _new_audio_player(-21.0)
	audio_trumpet = _new_audio_player(-5.0)
	audio_crumble = _new_audio_player(-3.0)
	audio_stone = _new_audio_player(-8.0)
	audio_clash = _new_audio_player(-9.0)
	audio_courtyard_battle = _new_audio_player(-11.0)
	audio_wood = _new_audio_player(-9.0)
	audio_place = _new_audio_player(-7.0)
	audio_voice = _new_audio_player(-2.0)

	# Runtime byte loading avoids dependence on editor import caches.
	audio_music.stream = _load_mp3_runtime("res://audio/ambient_medieval_loop.mp3", true)
	audio_trumpet.stream = _load_wav_runtime("res://audio/incoming_trumpet.wav")
	audio_crumble.stream = _load_wav_runtime("res://audio/wall_crumble.wav")
	audio_stone.stream = _load_wav_runtime("res://audio/stone_strike.wav")
	audio_clash.stream = _load_wav_runtime("res://audio/sword_clash.wav")
	audio_courtyard_battle.stream = _load_wav_runtime("res://audio/courtyard_battle_loop.wav", true)
	audio_wood.stream = _load_wav_runtime("res://audio/wood_damage.wav")
	audio_place.stream = _load_wav_runtime("res://audio/building_place_click.wav")
	_wall_voice = {
		"N": _load_wav_runtime("res://audio/wall_n.wav"),
		"E": _load_wav_runtime("res://audio/wall_e.wav"),
		"S": _load_wav_runtime("res://audio/wall_s.wav"),
		"W": _load_wav_runtime("res://audio/wall_w.wav"),
	}
	_tower_voice = {
		"NW": _load_wav_runtime("res://audio/tower_nw.wav"),
		"NE": _load_wav_runtime("res://audio/tower_ne.wav"),
		"SE": _load_wav_runtime("res://audio/tower_se.wav"),
		"SW": _load_wav_runtime("res://audio/tower_sw.wav"),
	}
	_kingdom_fallen_voice = _load_mp3_runtime("res://audio/kingdom_fallen.mp3")
	audio_music.finished.connect(_on_music_finished)
	audio_voice.finished.connect(_on_voice_finished)


func _start_match_music() -> void:
	if audio_music == null:
		return
	# Recover automatically if the stream was ever cleared or failed to survive
	# an editor reimport. The soundtrack is a shipped MP3 loaded directly from
	# disk and loops internally; this check also restarts it if playback stops.
	if audio_music.stream == null:
		audio_music.stream = _load_mp3_runtime("res://audio/ambient_medieval_loop.mp3", true)
	if audio_music.stream != null and not audio_music.playing:
		audio_music.play()


func _on_music_finished() -> void:
	if match_active and audio_music != null and audio_music.stream != null:
		audio_music.play()


func _reset_audio_tracking() -> void:
	_seen_incoming_audio.clear()
	_prev_wall_down_audio.clear()
	_prev_tower_down_audio.clear()
	_prev_fiefdom_defeated.clear()
	_voice_queue.clear()
	if audio_voice != null:
		audio_voice.stop()
	if audio_courtyard_battle != null:
		audio_courtyard_battle.stop()
	if m == null:
		return
	for d in UpMatch.DIRS:
		_prev_wall_down_audio[d] = _audio_wall_down(str(d))
	for tid in UpMatch.TURRETS:
		_prev_tower_down_audio[tid] = _audio_tower_down(str(tid))
	# Seed current elimination states so loading/starting a match never announces
	# kingdoms that were already defeated before this local presentation began.
	_prev_fiefdom_defeated[0] = m.player_is_defeated(0)
	for i in m.rivals.size():
		_prev_fiefdom_defeated[i + 1] = bool(m.rivals[i].defeated)


func _audio_wall_down(d: String) -> bool:
	if m == null:
		return false
	if local_player_id == 0:
		return bool(m.walls[d].collapsed)
	var ri: int = local_player_id - 1
	if ri >= 0 and ri < m.rivals.size():
		return bool(m.rivals[ri].wall_collapsed[d])
	return false


func _audio_tower_down(tid: String) -> bool:
	if m == null:
		return false
	if local_player_id == 0:
		return bool(m.turrets[tid].destroyed)
	var ri: int = local_player_id - 1
	if ri < 0 or ri >= m.rivals.size():
		return false
	var rv: UpMatch.Rival = m.rivals[ri]
	var adj: Array = UpMatch.TURRET_WALLS[tid]
	return (bool(rv.wall_collapsed[adj[0]]) and int(rv.wall_hp[adj[0]]) <= 0
		and bool(rv.wall_collapsed[adj[1]]) and int(rv.wall_hp[adj[1]]) <= 0)


func _queue_voice(stream: AudioStream) -> void:
	if stream == null:
		return
	_voice_queue.append(stream)
	if audio_voice != null and not audio_voice.playing:
		_play_next_voice()


func _play_next_voice() -> void:
	if audio_voice == null or _voice_queue.is_empty():
		return
	audio_voice.stream = _voice_queue.pop_front()
	audio_voice.play()


func _on_voice_finished() -> void:
	_play_next_voice()


func _incoming_audio_key(p: UpMatch.PendingAttack) -> String:
	if p.army_id >= 0:
		return "army:%d" % p.army_id
	return "%d:%d:%s:%d:%d" % [p.source_player, p.arrives, p.dir, p.size, p.wave]


func _local_audio_invaders() -> Array:
	if m == null:
		return []
	if local_player_id == 0:
		return m.invaders
	var ri: int = local_player_id - 1
	if ri >= 0 and ri < m.rivals.size():
		return m.rivals[ri].invaders
	return []


func _wall_has_local_melee(d: String) -> bool:
	if local_player_id == 0:
		return m.garrison_count(m.walls[d].melee) > 0
	var ri: int = local_player_id - 1
	if ri >= 0 and ri < m.rivals.size():
		return int(m.rivals[ri].wall_hp[d]) > 0
	return false



func _courtyard_melee_is_physically_engaged() -> bool:
	# The battle loop should follow actual sprite-contact melee, not target-state.
	# A defender can begin striking an invader before that invader retargets from
	# a building to the defender, so tgt_kind alone misses real courtyard fights.
	if m == null:
		return false

	# Player 0 owns the concrete Sortie objects used for courtyard infantry.
	# Start the loop whenever a living melee sortie and a living melee invader
	# are inside the courtyard and within the same REACH threshold the combat
	# simulation uses to permit soldier-vs-soldier strikes.
	if local_player_id == 0:
		var reach_sq: int = UpConfigRef.REACH * UpConfigRef.REACH
		for s: UpMatch.Sortie in m.sortied:
			if s == null or s.dead or s.hp <= 0:
				continue
			if str(s.def.get("cat", "")) != "melee":
				continue
			for inv: UpMatch.Invader in m.invaders:
				if inv == null or inv.hp <= 0 or not inv.inside:
					continue
				if str(inv.def.get("cat", "")) != "melee":
					continue
				var dx: int = inv.x - s.x
				var dy: int = inv.y - s.y
				if dx * dx + dy * dy <= reach_sq:
					return true
		return false

	# For a remote/local rival battlefield, fall back to the replicated target
	# state because that snapshot does not expose the home Sortie objects here.
	for inv in _local_audio_invaders():
		if inv == null or int(inv.hp) <= 0 or not bool(inv.inside):
			continue
		if str(inv.def.get("cat", "")) == "melee" and str(inv.tgt_kind) == "s":
			return true
	return false

func _update_audio_events() -> void:
	if m == null or not match_active:
		return
	_start_match_music()

	# A new incoming-banner event gets one short heraldic trumpet sting.
	for p: UpMatch.PendingAttack in _local_pending_attacks():
		var key := _incoming_audio_key(p)
		if not _seen_incoming_audio.has(key):
			_seen_incoming_audio[key] = true
			if audio_trumpet != null and not audio_trumpet.playing:
				audio_trumpet.play()

	# Detect collapse transitions. Queue all wall announcements first, then towers,
	# so a tower brought down by the same event is always announced afterward.
	var fallen_walls: Array[String] = []
	for d in UpMatch.DIRS:
		var ds := str(d)
		var down := _audio_wall_down(ds)
		var was_down := bool(_prev_wall_down_audio.get(ds, down))
		if down and not was_down:
			fallen_walls.append(ds)
		_prev_wall_down_audio[ds] = down
	for d in fallen_walls:
		if audio_crumble != null:
			audio_crumble.play()
		_queue_voice(_wall_voice.get(d, null) as AudioStream)

	var fallen_towers: Array[String] = []
	for tid in UpMatch.TURRETS:
		var ts := str(tid)
		var down := _audio_tower_down(ts)
		var was_down := bool(_prev_tower_down_audio.get(ts, down))
		if down and not was_down:
			fallen_towers.append(ts)
		_prev_tower_down_audio[ts] = down
	for tid in fallen_towers:
		_queue_voice(_tower_voice.get(tid, null) as AudioStream)

	# Global fiefdom-elimination announcement. This is presentation-only and
	# watches the authoritative defeat flags, so it works for the home kingdom,
	# AI rivals, and network-replicated rival defeats without changing simulation.
	for pid in range(m.rivals.size() + 1):
		var defeated_now: bool = m.player_is_defeated(pid)
		var defeated_before: bool = bool(_prev_fiefdom_defeated.get(pid, defeated_now))
		if defeated_now and not defeated_before:
			_queue_voice(_kingdom_fallen_voice)
		_prev_fiefdom_defeated[pid] = defeated_now

	# Contextual combat sounds. They are intentionally throttled so large armies
	# sound like a battle rather than hundreds of samples firing simultaneously.
	var wall_attack := false
	var soldier_fight := false
	var courtyard_soldier_fight: bool = _courtyard_melee_is_physically_engaged()
	var wood_attack := false
	for inv in _local_audio_invaders():
		if inv == null or int(inv.hp) <= 0:
			continue
		if bool(inv.inside):
			if str(inv.tgt_kind) == "b":
				wood_attack = true
		else:
			if bool(inv.at_wall):
				wall_attack = true
				if _wall_has_local_melee(str(inv.wall)):
					soldier_fight = true
	# Courtyard melee gets a continuous loop while an interior invader is physically
	# engaged with a mobile infantry defender. Stop it immediately when that
	# courtyard soldier-vs-soldier engagement ends.
	if audio_courtyard_battle != null:
		if courtyard_soldier_fight:
			if not audio_courtyard_battle.playing:
				audio_courtyard_battle.play()
		elif audio_courtyard_battle.playing:
			audio_courtyard_battle.stop()

	var now := Time.get_ticks_msec()
	if wall_attack and now - _last_stone_audio_msec >= 720:
		_last_stone_audio_msec = now
		if audio_stone != null:
			audio_stone.pitch_scale = randf_range(0.90, 1.08)
			audio_stone.play()
	if soldier_fight and now - _last_clash_audio_msec >= 610:
		_last_clash_audio_msec = now
		if audio_clash != null:
			audio_clash.pitch_scale = randf_range(0.91, 1.10)
			audio_clash.play()
	if wood_attack and now - _last_wood_audio_msec >= 760:
		_last_wood_audio_msec = now
		if audio_wood != null:
			audio_wood.pitch_scale = randf_range(0.90, 1.07)
			audio_wood.play()


func _unhandled_key_input(ev: InputEvent) -> void:
	if not (ev is InputEventKey and ev.pressed): return
	if ev.keycode == KEY_R:
		sel_rot = (sel_rot + 1) % 4
		board.ghost_rot = sel_rot
	elif ev.keycode == KEY_ESCAPE:
		_clear_selection()


func _clear_selection() -> void:
	sel_building = {}
	sel_cat = ""
	sel_camp = -1
	board.ghost_def = {}
	board.arm_cat = ""
	_hud_force_heavy = true


# ---------------------------------------------------------------------------
# Input -> actions
# ---------------------------------------------------------------------------

func _on_building_clicked(id: int) -> void:
	_submit_player_action("click_building", [id])


func _click_gain_text(gain: Dictionary) -> String:
	var parts: Array[String] = []
	var gold_gain: int = int(gain.get("gold", 0))
	var melee_gain: int = int(gain.get("melee", 0))
	var ranged_gain: int = int(gain.get("ranged", 0))
	if gold_gain > 0:
		parts.append("+%s gold" % _rate(gold_gain))
	if melee_gain > 0:
		parts.append("+%s melee" % _rate(melee_gain))
	if ranged_gain > 0:
		parts.append("+%s ranged" % _rate(ranged_gain))
	return "   ".join(parts)


func _apply_player_action_with_feedback(pid: int, action: String, args: Array) -> bool:
	# Capture click gain before applying the command, then show feedback only if
	# the authoritative action succeeds. This keeps the popup honest when the
	# per-second click cap rejects an input and works identically offline/networked.
	var click_id: int = 0
	var click_gain: Dictionary = {}
	if pid == local_player_id and action == "click_building" and not args.is_empty():
		click_id = int(args[0])
		if pid == 0:
			click_gain = m.click_gain_for_building(click_id)
		elif pid - 1 >= 0 and pid - 1 < m.rivals.size():
			click_gain = m._rival_click_gain(m.rivals[pid - 1], click_id)

	var applied: bool = m.apply_player_action(pid, action, args)
	# Static BoardView no longer redraws every frame. Placement and click-flash
	# changes can happen while the gameplay tick is frozen during the BEGIN
	# countdown, so explicitly invalidate the static layer for those commands.
	if applied and (action == "place" or action == "click_building"):
		board.queue_redraw()
	if applied and pid == local_player_id:
		# Refresh expensive affordability/count styles only after the authoritative
		# state actually changes. Forcing this rebuild on the initial mouse click
		# made network input feel hitchy while it was still waiting in the queue.
		_hud_force_heavy = true
		if action == "place":
			# Positive placement confirmation: a short dry click distinct from combat
			# impacts. It plays only after the authoritative placement succeeds.
			if audio_place != null and audio_place.stream != null:
				audio_place.pitch_scale = randf_range(0.97, 1.03)
				audio_place.play()
			# Placement is intentionally one-shot: after every successful courtyard
			# placement the player must choose the next piece from the building list.
			# This restores the original interaction requested for Upheaval.
			_clear_selection()
	if applied and click_id != 0:
		var popup_text := _click_gain_text(click_gain)
		if popup_text != "":
			board.show_gain_popup(click_id, popup_text)
	return applied

func _on_cell_clicked(x: int, y: int) -> void:
	if sel_building.is_empty(): return
	_submit_player_action("place", [str(sel_building["id"]), x, y, sel_rot])
	_hud_force_heavy = true

func _on_wall_clicked(dir: String) -> void:
	if sel_cat == "": return
	_submit_player_action("transfer", [sel_cat, "wall", dir])
	_hud_force_heavy = true

func _on_turret_clicked(id: String) -> void:
	if sel_cat == "": return
	_submit_player_action("transfer", [sel_cat, "turret", id])
	_hud_force_heavy = true

func _select_building(def: Dictionary) -> void:
	if m.started and not m.game_started: return
	if not m.player_can_build(local_player_id, def): return
	var same: bool = not sel_building.is_empty() and sel_building["id"] == def["id"]
	_clear_selection()
	if not same:
		sel_building = def
		board.ghost_def = def
		board.ghost_rot = 0
		sel_rot = 0

func _select_cat(cat: String) -> void:
	var same := sel_cat == cat
	_clear_selection()
	if not same:
		sel_cat = cat
		board.arm_cat = cat

func _select_camp(i: int) -> void:
	var same := sel_camp == i
	_clear_selection()
	if not same:
		sel_camp = i

func _on_camp_transfer(i: int) -> void:
	## Clicking a camp while a soldier type is armed routes soldiers into it.
	if sel_cat != "":
		_submit_player_action("transfer", [sel_cat, "camp", str(i)])
		_hud_force_heavy = true
	else:
		_select_camp(i)

func _view_rival(i: int) -> void:
	if i < 0 or i >= m.rivals.size():
		return
	var rv: UpMatch.Rival = m.rivals[i]
	if not rv.recon_unlocked:
		return
	board.recon_rival_index = i
	sel_building = {}
	sel_cat = ""
	sel_camp = -1
	board.ghost_def = {}
	board.arm_cat = ""
	_hud_force_heavy = true
	board.queue_redraw()


func _view_home() -> void:
	board.recon_rival_index = -1 if local_player_id == 0 else local_player_id - 1
	_hud_force_heavy = true
	board.queue_redraw()


func _on_rival_wall_clicked(i: int, dir: String) -> void:
	if sel_camp < 0: return
	var target_pid: int = i + 1
	if target_pid == local_player_id:
		return
	_submit_player_action("deploy", [sel_camp, target_pid, dir])
	sel_camp = -1
	_hud_force_heavy = true
	board.queue_redraw()


func _on_ironcrest_wall_clicked(dir: String) -> void:
	if sel_camp < 0 or local_player_id == 0:
		return
	_submit_player_action("deploy", [sel_camp, 0, dir])
	sel_camp = -1
	_hud_force_heavy = true
	board.queue_redraw()


# ---------------------------------------------------------------------------
# Refresh
# ---------------------------------------------------------------------------

func _num(v: int) -> String:
	return str(v / S)

func _rate(v: int) -> String:
	var whole := v / S
	if whole >= 10: return str(whole)
	return "%d.%d" % [whole, (v % S) / 100]


func _building_output_text(def: Dictionary) -> String:
	var parts: Array[String] = []
	if int(def["gold"]) > 0:
		parts.append("+%s\u00A0gold/sec" % _rate(int(def["gold"])))
	if int(def["melee"]) > 0:
		parts.append("+%s\u00A0melee/sec" % _rate(int(def["melee"])))
	if int(def["ranged"]) > 0:
		parts.append("+%s\u00A0ranged/sec" % _rate(int(def["ranged"])))
	# Each complete amount + resource stays together. Separate resources stack
	# tightly rather than wrapping around a centered dot.
	return "\n".join(parts)


func _building_output_count(def: Dictionary) -> int:
	var n := 0
	if int(def["gold"]) > 0: n += 1
	if int(def["melee"]) > 0: n += 1
	if int(def["ranged"]) > 0: n += 1
	return maxi(1, n)


func _local_pending_attacks() -> Array:
	if local_player_id == 0:
		return m.pending.duplicate()
	var result: Array = []
	for a: UpMatch.Army in m.armies:
		if a.target != local_player_id or a.phase != "travel":
			continue
		var p := UpMatch.PendingAttack.new()
		p.dir = a.target_wall
		p.melee = m._army_units(a.melee_hp, int(UpDefs.DEFENDERS["infantry"]["hp"]))
		p.ranged = m._army_units(a.ranged_hp, int(UpDefs.DEFENDERS["archer"]["hp"]))
		p.size = p.melee + p.ranged
		p.arrives = a.arrives
		p.source_player = a.attacker
		p.army_id = a.id
		if a.attacker == 0:
			p.force_color = Color("2f4f8f")
			p.device = 0
		else:
			var src: UpMatch.Rival = m.rivals[a.attacker - 1]
			p.force_color = src.crest
			p.device = src.device
		result.append(p)
	return result


func _refresh(force_heavy: bool = false) -> void:
	var now_msec := Time.get_ticks_msec()
	var do_heavy := force_heavy or now_msec - _last_heavy_hud_msec >= HUD_HEAVY_INTERVAL_MSEC
	if do_heavy:
		_last_heavy_hud_msec = now_msec
	lbl_treasury.text = _num(m.player_gold(local_player_id))
	lbl_treasury_rate.text = "+%s/sec" % _rate(m.player_rate_of(local_player_id, "gold"))
	lbl_building_count.text = "TOTAL BUILDINGS   %d" % m.player_building_records(local_player_id).size()
	if lbl_faction_name != null:
		lbl_faction_name.text = m.player_name(local_player_id)
	if btn_home_fiefdom != null:
		btn_home_fiefdom.tooltip_text = "View %s" % m.player_name(local_player_id)
	if btn_home_fiefdom != null:
		btn_home_fiefdom.tooltip_text = "Return to %s" % m.player_name(local_player_id)
	_update_viewed_fiefdom_name()
	if local_player_id > 0 and not ironcrest_target_row.is_empty():
		var host_defeated: bool = m.player_is_defeated(0)
		var host_name: Label = ironcrest_target_row["name"]
		host_name.text = m.player_name(0)
		host_name.add_theme_color_override("font_color", Color("8f9299") if host_defeated else Color("1a1a1a"))
		var host_defeat_label: Label = ironcrest_target_row["defeated"]
		host_defeat_label.visible = host_defeated
		var host_style: StyleBoxFlat = ironcrest_target_row["style"]
		host_style.bg_color = Color("2a2f38") if host_defeated else C_PARCH
		for d in UpMatch.DIRS:
			var iw: Button = ironcrest_target_row[d]
			iw.text = "%s  %d HP" % [d, m.walls[d].hp() / S]
			iw.disabled = host_defeated or sel_camp < 0

	# --- pre-match countdown ---
	if m.started and not m.game_started:
		start_panel.visible = true
		lbl_start_countdown.text = str(max(1, int(ceil(float(m.start_countdown) / TPS))))
	elif m.game_started and m.tick <= TPS:
		start_panel.visible = true
		lbl_start_countdown.text = "BEGIN"
	else:
		start_panel.visible = false

	# --- incoming attack banners: fill left-to-right, three per row ---
	var p_list := _local_pending_attacks()
	p_list.sort_custom(func(a, b): return a.arrives < b.arrives)
	_ensure_banner_slots(max(3, p_list.size()))
	banner_box.move_to_front()
	for i in banner_rows.size():
		var row: Dictionary = banner_rows[i]
		if i < p_list.size():
			var p: UpMatch.PendingAttack = p_list[i]
			var left: int = max(0, int(ceil(float(p.arrives - m.tick) / TPS)))
			row["panel"].visible = true
			row["header"].text = ("%s WAR CAMP" % m.rivals[p.source_player - 1].name.to_upper()) if p.source_player > 0 else "WAR CAMP INCOMING"
			row["count"].text = "%d INVADERS" % p.size
			row["wall"].text = "%s WALL" % UpMatch.dir_name(p.dir).to_upper()
			row["time"].text = "%02d:%02d" % [left / 60, left % 60]
			var style: StyleBoxFlat = row["style"]
			style.bg_color = p.force_color
			style.border_color = p.force_color.lightened(0.32)
			var crest: UpIcons.Herald = row["crest"]
			crest.base = p.force_color
			crest.device = p.device
			crest.queue_redraw()
		else:
			row["panel"].visible = false

	# --- buildings ---
	if do_heavy:
		for def in UpDefs.BUILDINGS:
			var row: Dictionary = build_rows[def["id"]]
			var req_ok: bool = m.player_meets_prereq(local_player_id, def)
			var afford: bool = m.player_can_build(local_player_id, def) and not (m.started and not m.game_started)
			var selected: bool = afford and not sel_building.is_empty() and sel_building["id"] == def["id"]
			var sb: StyleBoxFlat = row["style"]
			sb.bg_color = C_PARCH if afford else C_PARCH_LOCK
			sb.border_color = C_GOLD if selected else (Color("b6ab90") if afford else Color("9a9893"))
			sb.set_border_width_all(2 if selected else 1)
			row["btn"].disabled = not afford
			row["lock"].visible = not afford
			row["poly"].visible = afford
			row["icon"].locked = not afford
			row["icon"].queue_redraw()
			row["name"].add_theme_color_override("font_color",
				Color("2a2418") if afford else Color("6f6e6a"))
			row["count"].text = "×%d" % m.player_building_type_count(local_player_id, str(def["id"]))
			row["count"].add_theme_color_override("font_color",
				Color("5a503d") if afford else Color("81807c"))
			var tint := Color(1, 1, 1) if afford else Color(0.55, 0.5, 0.42)
			row["cost"].add_theme_color_override("font_color",
				Color("2a2418") if afford else Color("6f6e6a"))
			row["cost"].text = "Cost: %s" % _num(m.player_build_cost(local_player_id, def))
			row["prod"].text = _building_output_text(def)
			row["prod"].add_theme_color_override("font_color",
				Color("4a4436") if afford else Color("7c7b77"))
			var req_label: Label = row["req"]
			if def.get("req") != null:
				req_label.visible = true
				req_label.text = "🔒 Requires:\n%s\u00A0%s/sec" % [_rate(def["req"]["rate"]), def["req"]["res"]]
			else:
				req_label.visible = false
				req_label.text = ""

	# --- barracks ---
	var local_pool: Dictionary = m.player_pool(local_player_id)
	lbl_barracks_head.text = "BARRACKS   %d soldiers" % ((int(local_pool["melee"]) + int(local_pool["ranged"])) / S)
	for cat in ["melee", "ranged"]:
		var r: Dictionary = soldier_rows[cat]
		var whole: int = int(local_pool[cat]) / S
		r["count"].text = str(whole)
		r["count"].add_theme_color_override("font_color",
			C_GOLD if sel_cat != cat else Color("ffffff"))
		var per := (whole * UpConfigRef.TRANSFER_PCT + 999) / 1000 if whole > 0 else 0
		r["sub"].text = "%s/sec · %d per click" % [_rate(m.player_rate_of(local_player_id, cat)), per]
		var sb2: StyleBoxFlat = r["style"]
		sb2.bg_color = Color("1d3350") if sel_cat == cat else Color("0f2138")
		sb2.border_color = C_GOLD if sel_cat == cat else Color("2b4a6e")

	# --- war camps ---
	for i in camp_rows.size():
		var c: UpMatch.WarCamp = m.player_camps(local_player_id)[i]
		var r: Dictionary = camp_rows[i]
		r["melee"].text = str(c.melee)
		r["ranged"].text = str(c.ranged)
		r["total"].text = str(c.total())
		r["deploy"].disabled = c.empty()
		var sb3: StyleBoxFlat = r["style"]
		sb3.border_color = C_GOLD if sel_camp == i else Color("2b4a6e")
		sb3.set_border_width_all(2 if sel_camp == i else 1)

	# --- surrounding fiefdoms: active circular-chain distance order ---
	if do_heavy:
		if rival_list != null:
			var ordered: Array = m.surrounding_rival_indices_by_distance(local_player_id)
			for pos in ordered.size():
				var ri := int(ordered[pos])
				rival_list.move_child(rival_rows[ri]["panel"], pos)

		for i in rival_rows.size():
			var rv: UpMatch.Rival = m.rivals[i]
			var r: Dictionary = rival_rows[i]
			r["name"].add_theme_color_override("font_color", Color("8f9299") if rv.defeated else Color("1a1a1a"))
			r["meta"].text = "%s  ·  %d buildings" % [rv.personality, rv.buildings.size()]
			for d in UpMatch.DIRS:
				var wb: Button = r[d]
				wb.text = "%s  %d HP" % [d, int(rv.wall_hp[d]) / S]
				var wall_text_col := Color("2b2418") if not rv.defeated else Color("5e5b55")
				wb.add_theme_color_override("font_color", wall_text_col)
				wb.add_theme_color_override("font_hover_color", wall_text_col)
				wb.add_theme_color_override("font_pressed_color", wall_text_col)
				wb.add_theme_color_override("font_disabled_color", wall_text_col)
				wb.disabled = rv.defeated or sel_camp < 0 or rv.player_id == local_player_id
			r["defeated"].visible = rv.defeated
			r["spy"].visible = rv.recon_unlocked
			r["banner_btn"].disabled = not rv.recon_unlocked
			r["banner_btn"].tooltip_text = "View %s" % rv.name if rv.recon_unlocked else "Send a War Camp here to unlock reconnaissance"
			var sb4: StyleBoxFlat = r["style"]
			sb4.bg_color = Color("2a2f38") if rv.defeated else C_PARCH
			sb4.border_color = C_GOLD if (sel_camp >= 0 and not rv.defeated) else Color("b6ab90")

	lbl_day.text = "Day %d      %d:%02d" % [m.day_number(), (m.tick / TPS) / 60, (m.tick / TPS) % 60]
	lbl_remaining.text = "%d Fiefdoms Remaining" % m.fiefdoms_remaining()
	lbl_ai_type.text = "%s AI" % m.ai_skill

	# --- event log ---
	_update_event_log()

	if do_heavy:
		lbl_hint.text = _hint()

	var local_defeated: bool = m.player_is_defeated(local_player_id)
	if (m.over or local_defeated) and not over_panel.visible:
		over_panel.visible = true
		# Keep the victory/conquered panel centered over the entire viewport and
		# above all other HUD layers. A joined player's elimination is a terminal
		# state for that client even while the network match continues for others.
		over_center.move_to_front()
		var s2: int = m.tick / TPS
		if local_defeated:
			lbl_over_title.text = "YOU HAVE BEEN CONQUERED!"
			lbl_over_title.add_theme_color_override("font_color", Color("e06058"))
			lbl_over_1.text = "%s HAS FALLEN" % m.player_name(local_player_id).to_upper()
			lbl_over_2.text = "Match time %dm %ds   ·   Day %d\nYou have been eliminated from this match." % [s2 / 60, s2 % 60, m.day_number()]
		else:
			lbl_over_title.text = "VICTORY" if m.winner_name == m.player_name(local_player_id) else "MATCH OVER"
			lbl_over_title.add_theme_color_override("font_color", C_GOLD if m.winner_name == m.player_name(local_player_id) else C_TEXT)
			lbl_over_1.text = "%s WINS" % m.winner_name if m.winner_name != "" else "DRAW"
			lbl_over_2.text = "Match time %dm %ds   ·   Day %d\n%d fiefdoms defeated" % [
				s2 / 60, s2 % 60, m.day_number(), 4 - m.fiefdoms_remaining()]



func _update_event_log() -> void:
	if displayed_log_version == m.log_version:
		return
	for c in log_box.get_children():
		c.queue_free()
	log_rows.clear()

	# Simulation stores newest first; display oldest at the top so history reads
	# naturally downward and the newest event appears at the bottom.
	for idx in range(m.log_lines.size() - 1, -1, -1):
		var e: UpMatch.LogLine = m.log_lines[idx]
		var h := HBoxContainer.new()
		h.add_theme_constant_override("separation", 8)
		var t := _lbl("", f_body, 12, C_DIM)
		t.custom_minimum_size.x = 42
		var txt := _lbl("", f_body, 12, C_TEXT)
		txt.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		# The message label takes the remaining width; the timestamp stays at its
		# fixed 42px. Putting EXPAND_FILL on the timestamp instead squeezed the
		# autowrapping message to nothing and wrapped it one character per line.
		txt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var sec: int = e.tick / TPS
		t.text = "%d:%02d" % [sec / 60, sec % 60]
		txt.text = e.text
		var col := Color("e08078") if e.kind == "bad" else (Color("9fd07a") if e.kind == "good" else C_TEXT)
		txt.add_theme_color_override("font_color", col)
		h.add_child(t)
		h.add_child(txt)
		log_box.add_child(h)
		log_rows.append({"box": h, "time": t, "text": txt})

	displayed_log_version = m.log_version
	# New events always advance the log so the newest entry is visible on the
	# bottom line. The user can still scroll back between incoming events.
	call_deferred("_scroll_event_log_to_bottom")


func _scroll_event_log_to_bottom() -> void:
	if log_scroll == null:
		return
	var bar := log_scroll.get_v_scroll_bar()
	log_scroll.scroll_vertical = int(maxf(0.0, bar.max_value - bar.page))


func _hint() -> String:
	if not sel_building.is_empty():
		return "Placing %s — click the grid.  R rotates,  Esc cancels." % sel_building["name"]
	if sel_cat != "":
		var nm := "Infantry" if sel_cat == "melee" else "Archers"
		return "%s armed — click a wall, a turret, or a War Camp to send 2%% of the pool." % nm
	if sel_camp >= 0:
		return "War Camp %d selected — click a wall button on a surrounding fiefdom to deploy." % (sel_camp + 1)
	return "Click a building on the field for a production burst.  Pick a soldier card, then a destination."


# ---------------------------------------------------------------------------
# UI construction
# ---------------------------------------------------------------------------

func _lbl(txt: String, f: Font, sz: int, col: Color) -> Label:
	var l := Label.new()
	l.text = txt
	l.add_theme_font_override("font", f)
	l.add_theme_font_size_override("font_size", sz + 2)
	l.add_theme_color_override("font_color", col)
	return l


func _panel(bg: Color, border: Color = C_GOLD_DK, bw: int = 1) -> PanelContainer:
	var p := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.border_color = border
	sb.set_border_width_all(bw)
	sb.set_content_margin_all(8)
	p.add_theme_stylebox_override("panel", sb)
	return p


func _head(txt: String) -> PanelContainer:
	var p := _panel(C_PANEL_DK, C_GOLD_DK, 1)
	var sb: StyleBoxFlat = p.get_theme_stylebox("panel")
	sb.set_content_margin_all(4)
	sb.content_margin_left = 10
	p.add_child(_lbl(txt, f_disp, 14, C_GOLD))
	return p


func _make_banner() -> Control:
	var p := PanelContainer.new()
	p.custom_minimum_size = Vector2(200, 82)
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# Incoming-attack banners must remain the top-most HUD element so battlefield
	# soldiers can never overpaint them.
	p.z_as_relative = false
	p.z_index = 1001
	var sb := StyleBoxFlat.new()
	sb.bg_color = C_BLOOD
	sb.border_color = C_GOLD
	sb.set_border_width_all(2)
	sb.set_content_margin_all(5)
	p.add_theme_stylebox_override("panel", sb)

	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 6)
	var crest := UpIcons.Herald.new(C_BLOOD, 0, false)
	crest.custom_minimum_size = Vector2(34, 40)
	h.add_child(crest)

	var v := VBoxContainer.new()
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.add_theme_constant_override("separation", -2)
	var header := _lbl("INVASION WARNING", f_body, 9, Color("f3e8dc"))
	header.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	var l1 := _lbl("0 INVADERS", f_bold, 17, Color("ffffff"))
	l1.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	var l2 := _lbl("NORTH WALL", f_bold, 15, Color("fff0c8"))
	l2.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	var l3 := _lbl("00:00", f_bold, 17, Color("ffffff"))
	l3.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(header); v.add_child(l1); v.add_child(l2); v.add_child(l3)
	h.add_child(v)
	p.add_child(h)
	p.set_meta("header_label", header)
	p.set_meta("count_label", l1)
	p.set_meta("wall_label", l2)
	p.set_meta("time_label", l3)
	p.set_meta("banner_style", sb)
	p.set_meta("crest", crest)
	return p


func _ensure_banner_slots(count: int) -> void:
	while banner_rows.size() < count:
		var panel := _make_banner()
		panel.visible = false
		banner_box.add_child(panel)
		banner_rows.append({
			"panel": panel, "header": panel.get_meta("header_label"), "count": panel.get_meta("count_label"),
			"wall": panel.get_meta("wall_label"), "time": panel.get_meta("time_label"),
			"style": panel.get_meta("banner_style"), "crest": panel.get_meta("crest")
		})


func _build_ui() -> void:
	# Stable scene roots keep the battlefield and HUD lifecycles separate. The
	# detailed HUD content is still data-driven, but no longer owns the board node.
	battlefield_clip = get_node("BattlefieldRoot") as Control
	hud_root = get_node("HUDRoot") as Control
	battlefield_clip.set_meta("rect", Rect2(W_LEFT, 0, -W_RIGHT, -H_BOTTOM))
	board = battlefield_clip.get_node("BoardView") as BoardView
	board.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	board.building_clicked.connect(_on_building_clicked)
	board.cell_clicked.connect(_on_cell_clicked)
	board.wall_clicked.connect(_on_wall_clicked)
	board.turret_clicked.connect(_on_turret_clicked)
	# The board fills the center column all the way to the top so terrain can paint
	# behind the top HUD gap. Keep gameplay/castle centering below the top HUD.
	board.inset_top = H_TOP
	board.inset_bottom = 0.0
	board.inset_left = 0.0
	board.inset_right = 0.0

	_build_topleft()
	_build_topright()
	_build_banner_slot()
	_build_left()
	_build_right()
	_build_bottom()
	_build_viewed_fiefdom_name()
	_build_overlay()
	call_deferred("_relayout")


func _anchor(c: Control, l: float, t: float, r: float, b: float) -> void:
	c.set_anchors_preset(Control.PRESET_TOP_LEFT)
	c.anchor_left = 0; c.anchor_top = 0; c.anchor_right = 0; c.anchor_bottom = 0
	hud_root.add_child(c)
	c.set_meta("rect", Rect2(l, t, r, b))


func _relayout() -> void:
	var w := size.x
	var h := size.y
	var layout_nodes: Array = [battlefield_clip]
	layout_nodes.append_array(hud_root.get_children())
	for c in layout_nodes:
		if not (c is Control) or not c.has_meta("rect"): continue
		var spec: Rect2 = c.get_meta("rect")
		var x: float = spec.position.x if spec.position.x >= 0 else w + spec.position.x
		var y: float = spec.position.y if spec.position.y >= 0 else h + spec.position.y
		var sw: float = spec.size.x if spec.size.x > 0 else w + spec.size.x - x
		var sh: float = spec.size.y if spec.size.y > 0 else h + spec.size.y - y
		c.position = Vector2(x, y)
		c.size = Vector2(sw, sh)
	board.queue_redraw()


func _build_topleft() -> void:
	var p := _panel(C_PANEL)
	var info := VBoxContainer.new()
	info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	info.add_theme_constant_override("separation", 1)

	# The home-fiefdom identity now lives in the title panel. Keep this panel
	# dedicated to treasury information so the HUD reads consistently.
	var treasury_head := _lbl("TREASURY", f_disp, 13, C_TEXT)
	treasury_head.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	info.add_child(treasury_head)

	var gold_row := HBoxContainer.new()
	gold_row.alignment = BoxContainer.ALIGNMENT_CENTER
	gold_row.add_theme_constant_override("separation", 5)
	gold_row.add_child(UpIcons.CoinIcon.new())
	lbl_treasury = _lbl("0", f_disp, 24, C_GOLD)
	lbl_treasury.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	gold_row.add_child(lbl_treasury)
	info.add_child(gold_row)

	lbl_treasury_rate = _lbl("+0/sec  ·  +0/click", f_body, 11, C_DIM)
	lbl_treasury_rate.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	info.add_child(lbl_treasury_rate)

	lbl_building_count = _lbl("TOTAL BUILDINGS   0", f_bold, 12, C_TEXT)
	lbl_building_count.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	info.add_child(lbl_building_count)

	p.add_child(info)
	_anchor(p, 0, 0, W_LEFT, H_TOP)


func _build_topright() -> void:
	var p := _panel(C_PANEL)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 0)

	var l := _lbl("UPHEAVAL", f_logo, 36, C_TEXT)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.add_child(l)

	# Home-fiefdom selector. The 5 px inset mirrors the content margin used by
	# each Surrounding Fiefdom row below, so all herald banners share one x-axis.
	var home_inset := MarginContainer.new()
	home_inset.add_theme_constant_override("margin_left", 5)
	var home_row := HBoxContainer.new()
	home_row.add_theme_constant_override("separation", 6)

	btn_home_fiefdom = Button.new()
	btn_home_fiefdom.flat = true
	btn_home_fiefdom.tooltip_text = "View Ironcrest"
	btn_home_fiefdom.custom_minimum_size = Vector2(26, 66)
	btn_home_fiefdom.focus_mode = Control.FOCUS_NONE
	for st in ["normal", "hover", "pressed", "focus", "disabled"]:
		btn_home_fiefdom.add_theme_stylebox_override(st, StyleBoxEmpty.new())
	btn_home_fiefdom.pressed.connect(_view_home)

	home_crest = UpIcons.Herald.new(Color("2f4f8f"), 0, true)
	home_crest.custom_minimum_size = Vector2(22, 62)
	home_crest.position = Vector2(2, 2)
	home_crest.size = Vector2(22, 62)
	btn_home_fiefdom.add_child(home_crest)
	home_row.add_child(btn_home_fiefdom)

	lbl_faction_name = _lbl("Ironcrest", f_disp, 16, C_TEXT)
	lbl_faction_name.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	lbl_faction_name.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	home_row.add_child(lbl_faction_name)

	home_inset.add_child(home_row)
	v.add_child(home_inset)
	p.add_child(v)
	_anchor(p, -W_RIGHT, 0, W_RIGHT, H_TOP)


func _build_banner_slot() -> void:
	banner_box = GridContainer.new()
	banner_box.columns = 3
	banner_box.add_theme_constant_override("h_separation", 4)
	banner_box.add_theme_constant_override("v_separation", 4)
	# The incoming-attack strip is a dedicated HUD overlay. Keep it above both
	# the board and the rest of the HUD so soldiers can never appear through it.
	banner_box.z_as_relative = false
	banner_box.z_index = 1000
	# The banner strip occupies only the top HUD.  The previous zero-height rect
	# was interpreted by _relayout() as "stretch to the bottom", leaving an
	# invisible Control over the battlefield and swallowing placement clicks.
	banner_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_anchor(banner_box, W_LEFT + 6, 4, -W_RIGHT - 6, H_TOP - 8)
	banner_box.set_meta("rect", Rect2(W_LEFT + 6, 4, -W_RIGHT - 6, H_TOP - 8))
	_ensure_banner_slots(3)


func _build_left() -> void:
	var p := _panel(C_PANEL)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 4)
	v.add_child(_head("BUILDINGS"))
	var sc := ScrollContainer.new()
	sc.size_flags_vertical = Control.SIZE_EXPAND_FILL
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	var building_list := VBoxContainer.new()
	building_list.add_theme_constant_override("separation", 3)
	building_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sc.add_child(building_list)
	v.add_child(sc)
	p.add_child(v)
	_anchor(p, 0, H_TOP, W_LEFT, -H_BOTTOM)

	for def in UpDefs.BUILDINGS:
		building_list.add_child(_make_building_row(def))


func _make_building_row(def: Dictionary) -> Control:
	var output_lines := _building_output_count(def)
	var has_req := def.get("req") != null

	# Rows size themselves to their actual content. One-output buildings stay
	# compact; Citadel gets the extra height it genuinely needs for three output
	# lines plus a prerequisite. This saves much more list height overall.
	var production_h := output_lines * 13
	var prereq_h := 34 if has_req else 0
	var row_h := 40 + production_h + prereq_h
	row_h = maxi(row_h, 66)

	var btn := Button.new()
	btn.custom_minimum_size.y = row_h
	btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn.flat = false
	var sb := StyleBoxFlat.new()
	sb.bg_color = C_PARCH
	sb.border_color = Color("b6ab90")
	sb.set_border_width_all(1)
	sb.set_content_margin_all(5)
	btn.add_theme_stylebox_override("normal", sb)
	btn.add_theme_stylebox_override("hover", sb)
	btn.add_theme_stylebox_override("pressed", sb)
	btn.add_theme_stylebox_override("disabled", sb)
	btn.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	btn.pressed.connect(_select_building.bind(def))

	var row := Control.new()
	row.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var icon := UpIcons.BuildingIcon.new(Color(def["colour"]), false)
	icon.position = Vector2(5, maxf(5.0, (float(row_h) - 38.0) * 0.5))
	icon.custom_minimum_size = Vector2(40, 38)
	icon.size = Vector2(40, 38)
	row.add_child(icon)

	# Fixed horizontal text column; vertical positions are calculated directly so
	# no VBox can push the prerequisite outside the card.
	var text_box := Control.new()
	text_box.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	text_box.offset_left = 51
	text_box.offset_right = -96
	text_box.offset_top = 2
	text_box.offset_bottom = row_h - 2
	text_box.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var nm := _lbl(str(def["name"]), f_disp, 14, Color("2a2418"))
	nm.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	nm.offset_top = 0
	nm.offset_bottom = 18
	nm.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS

	var cost := _lbl("Cost: 0", f_body, 11, Color("2a2418"))
	cost.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	cost.offset_top = 18
	cost.offset_bottom = 32
	cost.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS

	var prod := _lbl("", f_body, 10, Color("4a4436"))
	prod.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	prod.offset_top = 32
	prod.offset_bottom = 32 + production_h
	prod.autowrap_mode = TextServer.AUTOWRAP_OFF
	prod.text_overrun_behavior = TextServer.OVERRUN_NO_TRIMMING
	prod.add_theme_constant_override("line_spacing", -4)

	var req := _lbl("", f_body, 10, Color("6f6e6a"))
	req.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	req.offset_top = 34 + production_h
	req.offset_bottom = 34 + production_h + prereq_h
	# Never ellipsize prerequisites. They render as a two-line requires block,
	# and the amount/resource pair uses a non-breaking space so "3.0 melee/sec"
	# always stays together on one line.
	req.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	req.text_overrun_behavior = TextServer.OVERRUN_NO_TRIMMING
	req.add_theme_constant_override("line_spacing", -3)

	text_box.add_child(nm)
	text_box.add_child(cost)
	text_box.add_child(prod)
	text_box.add_child(req)
	row.add_child(text_box)

	# Count and footprint remain in exactly the same horizontal columns on every
	# row, regardless of dynamic row height.
	var count := _lbl("×0", f_bold, 13, Color("5a503d"))
	count.set_anchor(SIDE_LEFT, 1.0)
	count.set_anchor(SIDE_RIGHT, 1.0)
	count.offset_left = -96
	count.offset_right = -58
	count.offset_top = 7
	count.offset_bottom = 28
	count.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	count.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	count.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(count)

	var poly_slot := CenterContainer.new()
	poly_slot.set_anchor(SIDE_LEFT, 1.0)
	poly_slot.set_anchor(SIDE_RIGHT, 1.0)
	poly_slot.offset_left = -55
	poly_slot.offset_right = -5
	var poly_y := maxf(5.0, (float(row_h) - 44.0) * 0.5)
	poly_slot.offset_top = poly_y
	poly_slot.offset_bottom = poly_y + 44
	poly_slot.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var poly := UpIcons.PolyIcon.new(def["cells"], Color(def["colour"]), false)
	poly.custom_minimum_size = Vector2(46, 40)
	poly_slot.add_child(poly)

	var lock := UpIcons.LockIcon.new()
	lock.visible = false
	poly_slot.add_child(lock)

	row.add_child(poly_slot)
	btn.add_child(row)
	build_rows[def["id"]] = {
		"btn": btn, "style": sb, "icon": icon, "poly": poly, "lock": lock,
		"name": nm, "count": count, "cost": cost, "prod": prod, "req": req}
	return btn


func _build_right() -> void:
	# --- Surrounding Fiefdoms ---
	# This panel now uses all available space from the top HUD down to the
	# dedicated Date/Time strip, leaving substantially more room for future rivals.
	var p := _panel(C_PANEL)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 4)
	v.add_child(_head("SURROUNDING FIEFDOMS"))
	var sc := ScrollContainer.new()
	sc.size_flags_vertical = Control.SIZE_EXPAND_FILL
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	rival_list = VBoxContainer.new()
	rival_list.add_theme_constant_override("separation", 3)
	rival_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sc.add_child(rival_list)
	v.add_child(sc)
	p.add_child(v)
	_anchor(p, -W_RIGHT, H_TOP, W_RIGHT, -(H_BOTTOM + H_DATE_TIME))

	# Rival rows are populated only after UpMatch exists. _build_ui() runs before
	# _start(), so reading m.rivals here would dereference a Nil match.

	# --- Date / Time ---
	# Separate from the rival list so it stays fixed directly above Event Log.
	var dayp := _panel(C_PANEL_DK, C_GOLD_DK, 1)
	var dv := VBoxContainer.new()
	dv.add_theme_constant_override("separation", 0)
	lbl_day = _lbl("Day 1", f_disp, 18, C_TEXT)
	lbl_day.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl_day.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	lbl_remaining = _lbl("", f_disp, 13, C_DIM)
	lbl_remaining.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl_remaining.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	lbl_ai_type = _lbl("", f_body, 12, C_DIM)
	lbl_ai_type.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl_ai_type.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	dv.add_child(lbl_day)
	dv.add_child(lbl_remaining)
	dv.add_child(lbl_ai_type)
	dayp.add_child(dv)
	_anchor(dayp, -W_RIGHT, -(H_BOTTOM + H_DATE_TIME), W_RIGHT, H_DATE_TIME)


func _rebuild_rival_rows() -> void:
	# UI construction happens before the match is created. Build these dynamic
	# rows only after _begin_match() has assigned m, and rebuild them whenever a
	# new match starts so the UI can support a different number of fiefdoms.
	if rival_list == null or m == null:
		return
	for child in rival_list.get_children():
		child.free()
	rival_rows.clear()
	if local_player_id > 0:
		rival_list.add_child(_make_ironcrest_target_row())
	for i in m.rivals.size():
		var row_control: Control = _make_rival_row(i)
		if local_player_id > 0 and i == local_player_id - 1:
			row_control.visible = false
		rival_list.add_child(row_control)


func _make_ironcrest_target_row() -> Control:
	var p := PanelContainer.new()
	p.custom_minimum_size.y = 94
	var sb := StyleBoxFlat.new()
	sb.bg_color = C_PARCH
	sb.border_color = Color("b6ab90")
	sb.set_border_width_all(1)
	sb.set_content_margin_all(5)
	p.add_theme_stylebox_override("panel", sb)
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 6)
	var banner := UpIcons.Herald.new(Color("2f4f8f"), 0, true)
	banner.custom_minimum_size = Vector2(22, 62)
	h.add_child(banner)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 1)
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var nm := _lbl(m.player_name(0) if m != null else "Ironcrest", f_disp, 15, Color("1a1a1a"))
	v.add_child(nm)
	var grid := GridContainer.new()
	grid.columns = 2
	var row := {"panel": p, "style": sb, "name": nm, "banner": banner}
	for d in ["N", "E", "W", "S"]:
		var wb := Button.new()
		wb.text = "%s  100 HP" % d
		wb.custom_minimum_size = Vector2(92, 24)
		wb.pressed.connect(_on_ironcrest_wall_clicked.bind(d))
		grid.add_child(wb)
		row[d] = wb
	v.add_child(grid)
	var dl := _lbl("DEFEATED", f_disp, 13, Color("b8514a"))
	dl.visible = false
	v.add_child(dl)
	row["defeated"] = dl
	h.add_child(v)
	p.add_child(h)
	ironcrest_target_row = row
	return p


func _make_rival_row(i: int) -> Control:
	var p := PanelContainer.new()
	p.custom_minimum_size.y = 94
	var sb := StyleBoxFlat.new(); sb.bg_color = C_PARCH; sb.border_color = Color("b6ab90")
	sb.set_border_width_all(1); sb.set_content_margin_all(5); p.add_theme_stylebox_override("panel", sb)

	var h := HBoxContainer.new(); h.add_theme_constant_override("separation", 6)
	var rv: UpMatch.Rival = m.rivals[i]
	var banner_btn := Button.new()
	banner_btn.flat = true
	banner_btn.custom_minimum_size = Vector2(26, 66)
	banner_btn.tooltip_text = "Reconnaissance locked"
	banner_btn.focus_mode = Control.FOCUS_NONE
	for st in ["normal", "hover", "pressed", "focus", "disabled"]:
		banner_btn.add_theme_stylebox_override(st, StyleBoxEmpty.new())
	banner_btn.pressed.connect(_view_rival.bind(i))
	var banner := UpIcons.Herald.new(rv.crest, rv.device, true)
	banner.custom_minimum_size = Vector2(22, 62)
	banner.position = Vector2(2, 2)
	banner.size = Vector2(22, 62)
	banner_btn.add_child(banner)
	h.add_child(banner_btn)
	var v := VBoxContainer.new(); v.add_theme_constant_override("separation", 1); v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var name_row := HBoxContainer.new()
	name_row.add_theme_constant_override("separation", 4)
	var spy := UpIcons.SpyglassIcon.new()
	spy.custom_minimum_size = Vector2(20, 16)
	spy.visible = false
	name_row.add_child(spy)
	var nm := _lbl(rv.name, f_disp, 15, Color("1a1a1a"))
	nm.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_row.add_child(nm)
	v.add_child(name_row)
	var meta := _lbl("", f_body, 11, Color("555555")); v.add_child(meta)
	var grid := GridContainer.new(); grid.columns = 2; grid.add_theme_constant_override("h_separation", 4); grid.add_theme_constant_override("v_separation", 2)
	var row := {"panel": p, "style": sb, "name": nm, "meta": meta,
		"banner_btn": banner_btn, "spy": spy}
	for d in ["N", "E", "W", "S"]:
		var wb := Button.new(); wb.text = "%s  100 HP" % d; wb.custom_minimum_size = Vector2(92, 24)
		wb.add_theme_font_override("font", f_bold); wb.add_theme_font_size_override("font_size", 13)
		for state_name in ["font_color", "font_hover_color", "font_pressed_color", "font_disabled_color"]:
			wb.add_theme_color_override(state_name, Color("2b2418"))
		wb.pressed.connect(_on_rival_wall_clicked.bind(i, d)); grid.add_child(wb); row[d] = wb
	v.add_child(grid)
	var dl := _lbl("DEFEATED", f_disp, 13, Color("b8514a")); dl.visible = false; v.add_child(dl); row["defeated"] = dl
	h.add_child(v); p.add_child(h); rival_rows.append(row)
	return p



func _build_viewed_fiefdom_name() -> void:
	# Reconnaissance identifies the viewed surrounding fiefdom at the lower-right
	# edge of the battlefield. The faction's own heraldic banner brackets the name
	# on both sides; the full group is right-justified flush with the side column.
	viewed_fiefdom_name_row = HBoxContainer.new()
	viewed_fiefdom_name_row.alignment = BoxContainer.ALIGNMENT_END
	viewed_fiefdom_name_row.add_theme_constant_override("separation", 5)
	viewed_fiefdom_name_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	viewed_fiefdom_name_row.visible = false

	viewed_fiefdom_banner_left = UpIcons.Herald.new(Color("2f4f8f"), 0, true)
	viewed_fiefdom_banner_left.custom_minimum_size = Vector2(20, 20)
	viewed_fiefdom_name_row.add_child(viewed_fiefdom_banner_left)

	lbl_viewed_fiefdom_name = _lbl("", f_disp, 20, C_TEXT)
	lbl_viewed_fiefdom_name.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	lbl_viewed_fiefdom_name.mouse_filter = Control.MOUSE_FILTER_IGNORE
	lbl_viewed_fiefdom_name.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.85))
	lbl_viewed_fiefdom_name.add_theme_constant_override("shadow_offset_x", 2)
	lbl_viewed_fiefdom_name.add_theme_constant_override("shadow_offset_y", 2)
	viewed_fiefdom_name_row.add_child(lbl_viewed_fiefdom_name)

	viewed_fiefdom_banner_right = UpIcons.Herald.new(Color("2f4f8f"), 0, true)
	viewed_fiefdom_banner_right.custom_minimum_size = Vector2(20, 20)
	viewed_fiefdom_name_row.add_child(viewed_fiefdom_banner_right)

	# 420 px provides room for long names. The right edge remains exactly flush
	# with the Surrounding Fiefdoms panel and the row sits directly above War Camps.
	_anchor(viewed_fiefdom_name_row, -(W_RIGHT + 420.0), -(H_BOTTOM + 30.0), 420.0, 30.0)


func _update_viewed_fiefdom_name() -> void:
	if viewed_fiefdom_name_row == null or lbl_viewed_fiefdom_name == null or m == null or board == null:
		return
	var ri: int = board.recon_rival_index
	# Network players use their own Rival record as their home battlefield, so do
	# not label that as a surrounding fiefdom.
	var home_ri: int = local_player_id - 1 if local_player_id > 0 else -1
	var show_name: bool = ri >= 0 and ri < m.rivals.size() and ri != home_ri
	viewed_fiefdom_name_row.visible = show_name
	if show_name:
		var rv: UpMatch.Rival = m.rivals[ri]
		lbl_viewed_fiefdom_name.text = rv.name
		for herald in [viewed_fiefdom_banner_left, viewed_fiefdom_banner_right]:
			if herald != null:
				herald.base = rv.crest
				herald.device = rv.device
				herald.queue_redraw()

func _build_bottom() -> void:
	# --- Barracks ---
	var bp := _panel(C_PANEL)
	var bv := VBoxContainer.new()
	bv.add_theme_constant_override("separation", 4)
	lbl_barracks_head = _lbl("BARRACKS", f_disp, 14, C_GOLD)
	bv.add_child(lbl_barracks_head)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	bv.add_child(row)
	lbl_hint = _lbl("", f_body, 12, C_DIM)
	bv.add_child(lbl_hint)
	bp.add_child(bv)
	# Barracks takes all remaining bottom-row width to the left of War Camps.
	# Using a negative width makes it expand with the window for future soldier types.
	_anchor(bp, 0, -H_BOTTOM, -(W_WARCAMP + W_EVENT_LOG), H_BOTTOM)

	for cat in ["melee", "ranged"]:
		row.add_child(_make_soldier_card(cat))

	# --- War Camps ---
	var wp := _panel(C_PANEL)
	var wv := VBoxContainer.new()
	wv.add_theme_constant_override("separation", 4)
	wv.add_child(_lbl("WAR CAMPS   (fill a camp · select DEPLOY · then click a rival wall)",
		f_disp, 12, C_GOLD))
	var crow := HBoxContainer.new()
	crow.add_theme_constant_override("separation", 6)
	crow.size_flags_vertical = Control.SIZE_EXPAND_FILL
	wv.add_child(crow)
	wp.add_child(wv)
	# Flush against the Event Log with no gap.
	_anchor(wp, -(W_EVENT_LOG + W_WARCAMP), -H_BOTTOM, W_WARCAMP, H_BOTTOM)

	for i in 3:
		crow.add_child(_make_camp_card(i))

	# --- Event log ---
	var lp := _panel(C_PANEL)
	var lv := VBoxContainer.new()
	lv.add_theme_constant_override("separation", 2)
	lv.add_child(_lbl("EVENT LOG", f_disp, 14, C_GOLD))
	log_scroll = ScrollContainer.new()
	log_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	log_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	log_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	log_box = VBoxContainer.new()
	log_box.add_theme_constant_override("separation", 1)
	log_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	log_scroll.add_child(log_box)
	lv.add_child(log_scroll)
	lp.add_child(lv)
	# Match the Surrounding Fiefdoms column exactly and align directly below it.
	_anchor(lp, -W_EVENT_LOG, -H_BOTTOM, W_EVENT_LOG, H_BOTTOM)


func _make_soldier_card(cat: String) -> Control:
	var btn := Button.new()
	btn.custom_minimum_size = Vector2(220, 112)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color("0f2138")
	sb.border_color = Color("2b4a6e")
	sb.set_border_width_all(1)
	sb.set_content_margin_all(5)
	for st in ["normal", "hover", "pressed", "disabled"]:
		btn.add_theme_stylebox_override(st, sb)
	btn.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	btn.pressed.connect(_select_cat.bind(cat))

	var h := HBoxContainer.new()
	h.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	h.add_theme_constant_override("separation", 6)
	h.mouse_filter = Control.MOUSE_FILTER_IGNORE
	h.add_child(UpIcons.SoldierIcon.new(
		Color("2f4f8f") if cat == "melee" else Color("3f6f4a"), cat == "ranged"))
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", -3)
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.add_child(_lbl("Infantry" if cat == "melee" else "Archer", f_disp, 14, C_TEXT))
	var cnt := _lbl("0", f_disp, 22, C_GOLD)
	v.add_child(cnt)
	var sub := _lbl("", f_body, 11, C_DIM)
	v.add_child(sub)
	h.add_child(v)
	btn.add_child(h)
	soldier_rows[cat] = {"btn": btn, "style": sb, "count": cnt, "sub": sub}
	return btn


func _make_camp_card(i: int) -> Control:
	var p := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color("14335e")
	sb.border_color = Color("2b4a6e")
	sb.set_border_width_all(1)
	sb.set_content_margin_all(5)
	p.add_theme_stylebox_override("panel", sb)
	p.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 1)
	var title := Button.new()
	title.text = "War Camp %d" % (i + 1)
	title.add_theme_font_override("font", f_disp)
	title.add_theme_font_size_override("font_size", 16)
	title.add_theme_color_override("font_color", C_TEXT)
	var tsb := StyleBoxFlat.new()
	tsb.bg_color = Color("1d4585")
	tsb.set_content_margin_all(2)
	for st in ["normal", "hover", "pressed"]:
		title.add_theme_stylebox_override(st, tsb)
	title.pressed.connect(_on_camp_transfer.bind(i))
	v.add_child(title)

	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 6)
	h.add_child(UpIcons.CampIcon.new())
	var g := GridContainer.new()
	g.columns = 2
	g.add_theme_constant_override("h_separation", 6)
	g.add_theme_constant_override("v_separation", -3)
	g.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var lm := _lbl("0", f_disp, 15, C_GOLD)
	var lr := _lbl("0", f_disp, 15, C_GOLD)
	var lt := _lbl("0", f_disp, 15, C_TEXT)
	g.add_child(_lbl("melee", f_body, 11, C_DIM)); g.add_child(lm)
	g.add_child(_lbl("ranged", f_body, 11, C_DIM)); g.add_child(lr)
	g.add_child(_lbl("total", f_body, 11, C_DIM)); g.add_child(lt)
	h.add_child(g)
	v.add_child(h)

	var dep := Button.new()
	dep.text = "DEPLOY CAMP"
	dep.add_theme_font_override("font", f_disp)
	dep.add_theme_font_size_override("font_size", 14)
	dep.pressed.connect(_select_camp.bind(i))
	v.add_child(dep)

	p.add_child(v)
	camp_rows.append({"panel": p, "style": sb, "melee": lm, "ranged": lr,
		"total": lt, "deploy": dep})
	return p


func _build_overlay() -> void:
	# Full-screen container guarantees the final result panel is centered in the
	# actual window instead of being centered relative to its own minimum size.
	over_center = CenterContainer.new()
	over_center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	over_center.grow_horizontal = Control.GROW_DIRECTION_BOTH
	over_center.grow_vertical = Control.GROW_DIRECTION_BOTH
	over_center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(over_center)

	over_panel = PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.04, 0.05, 0.07, 0.95)
	sb.border_color = C_GOLD
	sb.set_border_width_all(2)
	sb.set_content_margin_all(34)
	over_panel.add_theme_stylebox_override("panel", sb)
	over_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 10)
	lbl_over_title = _lbl("MATCH OVER", f_disp, 32, C_TEXT)
	lbl_over_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(lbl_over_title)
	lbl_over_1 = _lbl("", f_disp, 17, C_TEXT)
	lbl_over_1.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl_over_2 = _lbl("", f_body, 14, C_DIM)
	lbl_over_2.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(lbl_over_1); v.add_child(lbl_over_2)
	var again := Button.new()
	again.text = "PLAY AGAIN"
	again.add_theme_font_override("font", f_disp)
	again.add_theme_font_size_override("font_size", 18)
	again.pressed.connect(_start)
	v.add_child(again)
	over_panel.add_child(v)
	over_panel.visible = false
	over_center.add_child(over_panel)
	over_center.move_to_front()

	# Pre-match countdown / BEGIN flash, centered on the entire screen.
	# A full-screen CenterContainer owns the countdown panel so the panel's
	# minimum size is centered around the viewport midpoint instead of beginning
	# at the midpoint and extending down/right.
	var start_center := CenterContainer.new()
	start_center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	start_center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(start_center)

	start_panel = PanelContainer.new()
	start_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var ssb := StyleBoxFlat.new()
	ssb.bg_color = Color(0.04, 0.05, 0.07, 0.86)
	ssb.border_color = C_GOLD
	ssb.set_border_width_all(2)
	ssb.set_content_margin_all(22)
	start_panel.add_theme_stylebox_override("panel", ssb)

	lbl_start_countdown = _lbl("10", f_disp, 64, C_GOLD)
	lbl_start_countdown.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl_start_countdown.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	start_panel.add_child(lbl_start_countdown)
	start_panel.visible = false
	start_center.add_child(start_panel)
	start_center.move_to_front()

	# Full-screen mouse blocker makes the pre-game skill choice truly modal.
	skill_blocker = ColorRect.new()
	skill_blocker.color = Color(0, 0, 0, 0.45)
	skill_blocker.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	skill_blocker.mouse_filter = Control.MOUSE_FILTER_STOP
	skill_blocker.visible = false
	add_child(skill_blocker)

	# Full-screen centering container keeps the chooser centered at any
	# resolution and regardless of its calculated minimum size.
	skill_center = CenterContainer.new()
	skill_center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	skill_center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(skill_center)

	# Modal pre-game AI skill choice.
	skill_panel = PanelContainer.new()
	var ksb := StyleBoxFlat.new()
	ksb.bg_color = Color(0.04, 0.05, 0.07, 0.97)
	ksb.border_color = C_GOLD
	ksb.set_border_width_all(2)
	ksb.set_content_margin_all(28)
	skill_panel.add_theme_stylebox_override("panel", ksb)
	var kv := VBoxContainer.new()
	kv.add_theme_constant_override("separation", 12)
	var kt := _lbl("CHOOSE AI SKILL", f_disp, 28, C_GOLD)
	kt.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	kv.add_child(kt)
	var ks := _lbl("AI personalities stay distinct. Skill changes how competently they build, defend, target, and launch War Camps.", f_body, 13, C_TEXT)
	ks.custom_minimum_size.x = 440
	ks.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	ks.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	kv.add_child(ks)
	for level in ["Easy", "Standard", "Hard"]:
		var kb := Button.new()
		kb.text = level.to_upper()
		kb.custom_minimum_size = Vector2(0, 46)
		kb.add_theme_font_override("font", f_disp)
		kb.add_theme_font_size_override("font_size", 20)
		kb.pressed.connect(_choose_skill.bind(level))
		kv.add_child(kb)
	var kh := _lbl("Easy: less efficient AI   ·   Standard: intended baseline   ·   Hard: sharper decisions and pressure", f_body, 11, C_DIM)
	kh.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	kh.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	kv.add_child(kh)
	skill_panel.add_child(kv)
	skill_panel.visible = false
	skill_center.add_child(skill_panel)
	skill_center.move_to_front()


# ---------------------------------------------------------------------------
# Kingdom naming
# ---------------------------------------------------------------------------

func _build_name_prompt() -> void:
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(center)

	name_gate = PanelContainer.new()
	name_gate.mouse_filter = Control.MOUSE_FILTER_STOP
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.04, 0.05, 0.07, 0.98)
	sb.border_color = C_GOLD
	sb.set_border_width_all(2)
	sb.set_content_margin_all(30)
	name_gate.add_theme_stylebox_override("panel", sb)

	var v := VBoxContainer.new()
	v.custom_minimum_size.x = 420
	v.add_theme_constant_override("separation", 12)
	var title := _lbl("NAME YOUR KINGDOM", f_disp, 28, C_GOLD)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(title)
	var sub := _lbl("Choose the name your fiefdom will use throughout the match.", f_body, 14, C_TEXT)
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	sub.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	v.add_child(sub)

	name_input = LineEdit.new()
	name_input.placeholder_text = "Kingdom name"
	name_input.max_length = 24
	name_input.custom_minimum_size.y = 44
	name_input.text_submitted.connect(func(_text: String): _confirm_kingdom_name())
	v.add_child(name_input)

	var go := Button.new()
	go.text = "CONTINUE"
	go.custom_minimum_size.y = 44
	go.pressed.connect(_confirm_kingdom_name)
	v.add_child(go)

	name_gate.add_child(v)
	center.add_child(name_gate)
	center.move_to_front()


func _show_name_prompt() -> void:
	match_active = false
	if net_lobby != null:
		net_lobby.visible = false
	if name_gate != null:
		name_gate.visible = true
	if name_input != null:
		name_input.text = local_kingdom_name
		name_input.grab_focus()


func _confirm_kingdom_name() -> void:
	if name_input == null:
		return
	var cleaned := _clean_kingdom_name(name_input.text)
	if cleaned.is_empty():
		name_input.placeholder_text = "Please enter a kingdom name"
		name_input.grab_focus()
		return
	local_kingdom_name = cleaned
	player_kingdom_names.clear()
	player_kingdom_names[0] = local_kingdom_name
	if name_gate != null:
		name_gate.visible = false
	_show_network_lobby()


func _clean_kingdom_name(raw: String) -> String:
	var cleaned := raw.strip_edges()
	cleaned = cleaned.replace("\n", " ").replace("\r", " ").replace("\t", " ")
	while "  " in cleaned:
		cleaned = cleaned.replace("  ", " ")
	if cleaned.length() > 24:
		cleaned = cleaned.left(24)
	return cleaned


# ---------------------------------------------------------------------------
# Direct-IP multiplayer
# ---------------------------------------------------------------------------

func _build_network_lobby() -> void:
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(center)

	net_lobby = PanelContainer.new()
	net_lobby.mouse_filter = Control.MOUSE_FILTER_STOP
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.04, 0.05, 0.07, 0.97)
	sb.border_color = C_GOLD
	sb.set_border_width_all(2)
	sb.set_content_margin_all(28)
	net_lobby.add_theme_stylebox_override("panel", sb)

	var v := VBoxContainer.new()
	v.custom_minimum_size.x = 440
	v.add_theme_constant_override("separation", 10)
	var title := _lbl("UPHEAVAL MULTIPLAYER", f_disp, 28, C_GOLD)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(title)
	var sub := _lbl("Host a four-fiefdom match or connect directly to the host's IP address. Each connected player receives a different fiefdom; unfilled fiefdoms remain AI-controlled.", f_body, 13, C_TEXT)
	sub.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(sub)

	var host_btn := Button.new()
	host_btn.text = "HOST GAME"
	host_btn.custom_minimum_size.y = 44
	host_btn.pressed.connect(_host_game)
	v.add_child(host_btn)

	var join_row := HBoxContainer.new()
	net_ip = LineEdit.new()
	net_ip.placeholder_text = "Host IP address (for example 192.168.1.25)"
	net_ip.text = "127.0.0.1"
	net_ip.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	join_row.add_child(net_ip)
	var join_btn := Button.new()
	join_btn.text = "JOIN"
	join_btn.pressed.connect(_join_game)
	join_row.add_child(join_btn)
	v.add_child(join_row)

	net_slot_label = _lbl("", f_body, 13, C_GOLD)
	net_slot_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(net_slot_label)
	net_status = _lbl("Not connected", f_body, 12, C_DIM)
	net_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	net_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	v.add_child(net_status)

	net_start_btn = Button.new()
	net_start_btn.text = "START MATCH"
	net_start_btn.custom_minimum_size.y = 44
	net_start_btn.visible = false
	net_start_btn.pressed.connect(_host_start_match)
	v.add_child(net_start_btn)

	var note := _lbl("Direct internet hosting normally requires UDP port %d to be forwarded to the host. LAN play usually works with the host's local IP." % NET_PORT, f_body, 11, C_DIM)
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	note.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(note)

	net_lobby.add_child(v)
	center.add_child(net_lobby)
	center.move_to_front()


func _show_network_lobby() -> void:
	match_active = false
	if name_gate != null:
		name_gate.visible = false
	if net_lobby != null:
		net_lobby.visible = true
	if skill_blocker != null:
		skill_blocker.visible = false
	if skill_panel != null:
		skill_panel.visible = false
	if over_panel != null:
		over_panel.visible = false
	if net_start_btn != null:
		net_start_btn.visible = false
	if net_status != null:
		net_status.text = "Not connected"
	if net_slot_label != null:
		net_slot_label.text = ""


func _disconnect_network() -> void:
	match_active = false
	queued_net_actions.clear()
	peer_to_player.clear()
	player_kingdom_names.clear()
	if not local_kingdom_name.is_empty():
		player_kingdom_names[0] = local_kingdom_name
	local_player_id = 0
	is_network_host = false
	is_network_match = false
	host_tick_seen = 0
	if multiplayer.multiplayer_peer is ENetMultiplayerPeer:
		multiplayer.multiplayer_peer.close()
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()


func _connect_multiplayer_signals() -> void:
	if not multiplayer.peer_connected.is_connected(_on_peer_connected):
		multiplayer.peer_connected.connect(_on_peer_connected)
	if not multiplayer.peer_disconnected.is_connected(_on_peer_disconnected):
		multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	if not multiplayer.connected_to_server.is_connected(_on_connected_to_server):
		multiplayer.connected_to_server.connect(_on_connected_to_server)
	if not multiplayer.connection_failed.is_connected(_on_connection_failed):
		multiplayer.connection_failed.connect(_on_connection_failed)
	if not multiplayer.server_disconnected.is_connected(_on_server_disconnected):
		multiplayer.server_disconnected.connect(_on_server_disconnected)


func _host_game() -> void:
	_disconnect_network()
	_connect_multiplayer_signals()
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_server(NET_PORT, NET_MAX_CLIENTS)
	if err != OK:
		net_status.text = "Could not host: %s" % error_string(err)
		return
	multiplayer.multiplayer_peer = peer
	is_network_host = true
	is_network_match = true
	local_player_id = 0
	peer_to_player[1] = 0
	player_kingdom_names[0] = local_kingdom_name
	net_slot_label.text = "Your kingdom: %s" % local_kingdom_name
	net_status.text = "Hosting on UDP port %d. Waiting for players…" % NET_PORT
	net_start_btn.visible = true


func _join_game() -> void:
	_disconnect_network()
	_connect_multiplayer_signals()
	var address := net_ip.text.strip_edges()
	if address.is_empty():
		address = "127.0.0.1"
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_client(address, NET_PORT)
	if err != OK:
		net_status.text = "Could not connect: %s" % error_string(err)
		return
	multiplayer.multiplayer_peer = peer
	is_network_match = true
	is_network_host = false
	net_status.text = "Connecting to %s:%d…" % [address, NET_PORT]
	net_start_btn.visible = false


func _on_connected_to_server() -> void:
	net_status.text = "Connected. Waiting for the host to assign your kingdom…"
	_rpc_submit_kingdom_name.rpc_id(1, local_kingdom_name)


func _on_connection_failed() -> void:
	net_status.text = "Connection failed."
	_disconnect_network()
	if net_lobby != null:
		net_lobby.visible = true


func _on_server_disconnected() -> void:
	net_status.text = "Host disconnected."
	_disconnect_network()
	if net_lobby != null:
		net_lobby.visible = true


func _on_peer_connected(peer_id: int) -> void:
	if not is_network_host:
		return
	if match_active:
		var active_peer = multiplayer.multiplayer_peer
		if active_peer is ENetMultiplayerPeer:
			active_peer.disconnect_peer(peer_id)
		return
	var used: Dictionary = {}
	for value in peer_to_player.values():
		used[int(value)] = true
	var slot := -1
	for pid in range(1, 4):
		if not used.has(pid):
			slot = pid
			break
	if slot < 0:
		var mp = multiplayer.multiplayer_peer
		if mp is ENetMultiplayerPeer:
			mp.disconnect_peer(peer_id)
		return
	peer_to_player[peer_id] = slot
	_rpc_assign_slot.rpc_id(peer_id, slot)
	net_status.text = "%d connected player(s). Unfilled slots will be AI." % (peer_to_player.size() - 1)


func _on_peer_disconnected(peer_id: int) -> void:
	if is_network_host and peer_to_player.has(peer_id):
		var pid: int = int(peer_to_player[peer_id])
		peer_to_player.erase(peer_id)
		player_kingdom_names.erase(pid)
		net_status.text = "Player %d disconnected. Host temporarily assumed that peer's battle simulations." % pid
		if match_active:
			var changed := false
			for owned_pid in battle_authority_peer.keys():
				if int(battle_authority_peer[owned_pid]) == peer_id:
					battle_authority_peer[owned_pid] = 1
					changed = true
			if changed:
				_configure_local_battle_authority()
				_rpc_update_battle_authority.rpc(battle_authority_peer)


@rpc("authority", "call_remote", "reliable")
func _rpc_assign_slot(pid: int) -> void:
	local_player_id = pid
	net_slot_label.text = "Your kingdom: %s" % local_kingdom_name
	net_status.text = "Assigned to a unique fiefdom. Waiting for host to start…"
	_rpc_submit_kingdom_name.rpc_id(1, local_kingdom_name)


@rpc("any_peer", "call_remote", "reliable")
func _rpc_submit_kingdom_name(kingdom_name: String) -> void:
	if not is_network_host:
		return
	var sender := multiplayer.get_remote_sender_id()
	if not peer_to_player.has(sender):
		return
	var cleaned := _clean_kingdom_name(kingdom_name)
	if cleaned.is_empty():
		return
	var pid: int = int(peer_to_player[sender])
	player_kingdom_names[pid] = cleaned


func _host_start_match() -> void:
	if not is_network_host:
		return
	var human_slots: Array = peer_to_player.values()
	human_slots.sort()
	for pid_value in human_slots:
		var pid: int = int(pid_value)
		if not player_kingdom_names.has(pid) or str(player_kingdom_names[pid]).is_empty():
			net_status.text = "Waiting for every connected player to submit a kingdom name…"
			return
	var seed_value: int = int(Time.get_ticks_msec() & 0x7fffffff)
	battle_authority_peer = _build_battle_authority_map(human_slots)
	_start_network_match(seed_value, "Standard", human_slots, battle_authority_peer, player_kingdom_names)
	_rpc_start_match.rpc(seed_value, "Standard", human_slots, battle_authority_peer, player_kingdom_names)


func _build_battle_authority_map(human_slots: Array) -> Dictionary:
	# Every human fiefdom belongs to its own machine, including Player 0 on the
	# host. Remaining AI fiefdoms are spread across connected peers by load.
	var result: Dictionary = {}
	var load: Dictionary = {}
	for peer_id in peer_to_player.keys():
		load[int(peer_id)] = 1 # each connected peer already has its own human/home responsibility
	for peer_id in peer_to_player.keys():
		var pid: int = int(peer_to_player[peer_id])
		result[pid] = int(peer_id)
	for pid in range(1, 4):
		if result.has(pid):
			continue
		var best_peer: int = 1
		var best_load: int = 1 << 30
		for peer_id in load.keys():
			var peer_int: int = int(peer_id)
			var l: int = int(load[peer_id])
			if l < best_load or (l == best_load and peer_int < best_peer):
				best_load = l
				best_peer = peer_int
		result[pid] = best_peer
		load[best_peer] = int(load.get(best_peer, 0)) + 1
	return result


@rpc("authority", "call_remote", "reliable")
func _rpc_start_match(seed_value: int, level: String, human_slots: Array, authority_map: Dictionary, kingdom_names: Dictionary) -> void:
	_start_network_match(seed_value, level, human_slots, authority_map, kingdom_names)


func _start_network_match(seed_value: int, level: String, human_slots: Array, authority_map: Dictionary = {}, kingdom_names: Dictionary = {}) -> void:
	queued_net_actions.clear()
	net_sequence = 0
	host_tick_seen = 0
	_last_tick_sync = -1
	last_battle_snapshot_tick.clear()
	last_battle_snapshot_sent_tick.clear()
	last_battle_snapshot_active.clear()
	reported_rival_defeats.clear()
	battle_authority_peer = authority_map.duplicate(true)
	player_kingdom_names = kingdom_names.duplicate(true)
	_begin_match(level, seed_value, human_slots, kingdom_names)
	_configure_local_battle_authority()
	board.local_player_id = local_player_id
	board.recon_rival_index = -1 if local_player_id == 0 else local_player_id - 1
	if net_lobby != null:
		net_lobby.visible = false
	if lbl_faction_name != null:
		lbl_faction_name.text = m.player_name(local_player_id)
	if btn_home_fiefdom != null:
		btn_home_fiefdom.tooltip_text = "View %s" % m.player_name(local_player_id)
	if home_crest != null:
		if local_player_id == 0:
			home_crest.base = Color("2f4f8f")
			home_crest.device = 0
		else:
			var own_rival: UpMatch.Rival = m.rivals[local_player_id - 1]
			home_crest.base = own_rival.crest
			home_crest.device = own_rival.device
		home_crest.queue_redraw()
	_rebuild_rival_rows()
	_refresh(true)
	board.queue_redraw()


func _configure_local_battle_authority() -> void:
	if m == null or not is_network_match:
		return
	var my_peer: int = multiplayer.get_unique_id()
	var owned: Array = []
	for pid_value in battle_authority_peer.keys():
		var pid: int = int(pid_value)
		if int(battle_authority_peer[pid_value]) == my_peer:
			owned.append(pid)
	m.configure_battle_authority(owned)


@rpc("authority", "call_remote", "reliable")
func _rpc_update_battle_authority(authority_map: Dictionary) -> void:
	battle_authority_peer = authority_map.duplicate(true)
	_configure_local_battle_authority()


func _maybe_publish_battle_snapshots() -> void:
	if not is_network_match or m == null or not m.game_started:
		return
	var my_peer: int = multiplayer.get_unique_id()
	for pid_value in battle_authority_peer.keys():
		var pid: int = int(pid_value)
		if int(battle_authority_peer[pid_value]) != my_peer:
			continue

		# Rival defeat is a reliable participant-state transition. Player 0's
		# defeat flag is already carried by the host tick synchronization path.
		if pid > 0 and m.rivals[pid - 1].defeated and not reported_rival_defeats.has(pid):
			reported_rival_defeats[pid] = true
			if is_network_host:
				_host_commit_rival_defeat(pid)
			else:
				_rpc_report_rival_defeat.rpc_id(1, pid)

		# Combat snapshots are intentionally event-sensitive. Before this, every
		# authority serialized its entire battlefield five times per second even
		# while completely idle, and the host then deserialized/rebroadcast every
		# one of those large dictionaries. Player actions already execute on every
		# peer, so idle fiefdoms only need an occasional safety heartbeat.
		var active: bool = m.battle_is_active(pid)
		var was_active: bool = bool(last_battle_snapshot_active.get(pid, false))
		var last_sent: int = int(last_battle_snapshot_sent_tick.get(pid, -1000000))
		var interval: int = NET_BATTLE_SNAPSHOT_INTERVAL_TICKS if active else NET_BATTLE_IDLE_SNAPSHOT_INTERVAL_TICKS
		var due: bool = (m.tick - last_sent) >= interval
		# Always send the transition snapshot when combat ends so destruction,
		# casualties, and returning-army state settle immediately on every peer.
		if was_active and not active:
			due = true
		if not due:
			last_battle_snapshot_active[pid] = active
			continue

		var snap: Dictionary = m.make_battle_snapshot(pid)
		if snap.is_empty():
			continue
		last_battle_snapshot_sent_tick[pid] = m.tick
		last_battle_snapshot_active[pid] = active
		if is_network_host:
			_relay_battle_snapshot(pid, m.tick, snap)
		else:
			_rpc_submit_battle_snapshot.rpc_id(1, pid, m.tick, snap)


@rpc("any_peer", "call_remote", "reliable")
func _rpc_report_rival_defeat(pid: int) -> void:
	if not is_network_host or m == null:
		return
	var sender: int = multiplayer.get_remote_sender_id()
	if int(battle_authority_peer.get(pid, -1)) != sender:
		return
	_host_commit_rival_defeat(pid)


func _host_commit_rival_defeat(pid: int) -> void:
	if not is_network_host or m == null or pid < 1 or pid > m.rivals.size():
		return
	reported_rival_defeats[pid] = true
	m.rivals[pid - 1].defeated = true
	_rpc_set_rival_defeated.rpc(pid)


@rpc("authority", "call_remote", "reliable")
func _rpc_set_rival_defeated(pid: int) -> void:
	if m == null or pid < 1 or pid > m.rivals.size():
		return
	reported_rival_defeats[pid] = true
	m.rivals[pid - 1].defeated = true
	_hud_force_heavy = true


@rpc("any_peer", "call_remote", "unreliable")
func _rpc_submit_battle_snapshot(pid: int, snapshot_tick: int, snap: Dictionary) -> void:
	if not is_network_host or m == null:
		return
	var sender: int = multiplayer.get_remote_sender_id()
	if int(battle_authority_peer.get(pid, -1)) != sender:
		return
	_relay_battle_snapshot(pid, snapshot_tick, snap, sender)


func _relay_battle_snapshot(pid: int, snapshot_tick: int, snap: Dictionary, source_peer: int = -1) -> void:
	# The host is only a relay when another peer owns this fiefdom. It does not
	# execute RivalBattleSystem for that fiefdom. Apply once locally, then send
	# only to the clients that actually need the snapshot. Do not echo a remote
	# authority's own large snapshot straight back to it.
	_apply_battle_snapshot(pid, snapshot_tick, snap)
	if not is_network_host:
		return
	for peer_value in peer_to_player.keys():
		var peer_id: int = int(peer_value)
		if peer_id == 1 or peer_id == source_peer:
			continue
		_rpc_battle_snapshot.rpc_id(peer_id, pid, snapshot_tick, snap)


@rpc("authority", "call_remote", "unreliable")
func _rpc_battle_snapshot(pid: int, snapshot_tick: int, snap: Dictionary) -> void:
	_apply_battle_snapshot(pid, snapshot_tick, snap)


func _apply_battle_snapshot(pid: int, snapshot_tick: int, snap: Dictionary) -> void:
	if m == null:
		return
	var previous: int = int(last_battle_snapshot_tick.get(pid, -1))
	if snapshot_tick <= previous:
		return
	last_battle_snapshot_tick[pid] = snapshot_tick
	m.apply_battle_snapshot(pid, snap)
	# Remote structure/wall damage may arrive between local simulation-tick
	# signature checks. Invalidate only the static layer at snapshot cadence.
	board.queue_redraw()



func _submit_player_action(action: String, args: Array) -> void:
	if not match_active or m == null:
		return
	# A conquered player's client remains connected long enough to receive/relay
	# network state, but it is no longer allowed to issue gameplay commands.
	# The modal conquered panel supplies the terminal Play Again / lobby flow.
	if m.player_is_defeated(local_player_id):
		return
	if not is_network_match:
		# Solo: no peer exists, so there is nobody to queue through. Previously
		# this fell to the rpc_id(1, ...) branch and the action was silently
		# dropped - which is why no building could be placed.
		_apply_player_action_with_feedback(local_player_id, action, args)
		return
	if is_network_host:
		_host_queue_action(1, action, args)
	else:
		_rpc_request_action.rpc_id(1, action, args)


@rpc("any_peer", "call_remote", "reliable")
func _rpc_request_action(action: String, args: Array) -> void:
	if not is_network_host or not match_active:
		return
	var sender: int = multiplayer.get_remote_sender_id()
	_host_queue_action(sender, action, args)


func _host_queue_action(peer_id: int, action: String, args: Array) -> void:
	if not peer_to_player.has(peer_id):
		return
	var pid: int = int(peer_to_player[peer_id])
	net_sequence += 1
	# The authoritative gameplay tick is frozen not only before the first building
	# but throughout the 10-second BEGIN countdown. Never schedule countdown
	# inputs into a future gameplay tick or they would sit queued until BEGIN.
	# Once gameplay is live, one tick of runway is enough because clients trail
	# the host clock instead of being allowed to run ahead of it.
	var execute_tick: int = m.tick + (NET_INPUT_DELAY_TICKS if m.game_started else 0)
	_queue_network_action(execute_tick, net_sequence, pid, action, args)
	_rpc_queue_action.rpc(execute_tick, net_sequence, pid, action, args)


@rpc("authority", "call_remote", "reliable")
func _rpc_queue_action(execute_tick: int, sequence: int, pid: int, action: String, args: Array) -> void:
	_queue_network_action(execute_tick, sequence, pid, action, args)


func _queue_network_action(execute_tick: int, sequence: int, pid: int, action: String, args: Array) -> void:
	queued_net_actions.append({
		"tick": execute_tick,
		"seq": sequence,
		"pid": pid,
		"action": action,
		"args": args.duplicate(true),
	})
	queued_net_actions.sort_custom(func(a, b):
		if int(a["tick"]) != int(b["tick"]):
			return int(a["tick"]) < int(b["tick"])
		return int(a["seq"]) < int(b["seq"])
	)


func _apply_due_network_actions() -> void:
	while not queued_net_actions.is_empty() and int(queued_net_actions[0]["tick"]) <= m.tick:
		var cmd: Dictionary = queued_net_actions.pop_front()
		_apply_player_action_with_feedback(int(cmd["pid"]), str(cmd["action"]), cmd["args"])


func _network_can_step() -> bool:
	if not is_network_match or is_network_host:
		# Offline/host simulation owns its clock.
		return true
	if not m.game_started:
		# Countdown uses step() calls but deliberately leaves m.tick at zero, so it
		# cannot be gated by host_tick_seen. All peers advance this deterministic
		# countdown locally.
		return true
	# Keep joined clients at or just behind the last host tick they have seen.
	# Previously clients could run three ticks AHEAD of the host, which forced a
	# four-tick (400 ms) input delay to guarantee ordered commands arrived in
	# time. Trailing the authority gives reliable commands a runway while letting
	# normal actions execute after only one 100 ms simulation tick.
	return m.tick < host_tick_seen


func _maybe_broadcast_tick() -> void:
	if not is_network_host or m == null:
		return
	if m.tick == _last_tick_sync:
		return
	if m.tick <= 5 or m.tick % 2 == 0:
		_last_tick_sync = m.tick
		_rpc_tick_sync.rpc(m.tick, m.player_defeated)


@rpc("authority", "call_remote", "unreliable")
func _rpc_tick_sync(authority_tick: int, host_defeated: bool) -> void:
	host_tick_seen = maxi(host_tick_seen, authority_tick)
	# The host is authoritative for Player 0's terminal state. Repeated tick
	# heartbeats repair any local divergence instead of allowing a client to
	# silently remove a still-playing host from its active fiefdom chain.
	m.player_defeated = host_defeated
