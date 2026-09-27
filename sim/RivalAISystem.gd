extends RefCounted
const UpConfigRef = preload("res://sim/UpConfig.gd")

## Difficulty pacing and strategic target selection. Placement/economy mechanics
## remain in UpMatch for now; this module owns the AI policy decisions.

static func skill_build_interval(m) -> int:
	match m.ai_skill:
		"Easy": return 6 * m.TPS
		"Hard": return 2 * m.TPS
		_: return 3 * m.TPS

static func skill_action_interval(m) -> int:
	match m.ai_skill:
		"Easy": return UpConfigRef.AI_EASY_ACTION_TICKS
		"Hard": return UpConfigRef.AI_HARD_ACTION_TICKS
		_: return UpConfigRef.AI_STANDARD_ACTION_TICKS

static func schedule_next_action(m, _r) -> int:
	var base := skill_action_interval(m)
	var jitter := 0; var pause_chance := 0; var pause_min := 0; var pause_max := 0
	match m.ai_skill:
		"Easy": jitter=3; pause_chance=18; pause_min=10; pause_max=24
		"Hard": jitter=1; pause_chance=5; pause_min=4; pause_max=10
		_: jitter=2; pause_chance=10; pause_min=7; pause_max=16
	var delay := maxi(1, base + m._rng.randi_range(-jitter, jitter))
	if m._rng.randi_range(1,100) <= pause_chance: delay += m._rng.randi_range(pause_min,pause_max)
	return m.tick + delay

static func skill_offense_pct(m, base_pct:int)->int:
	match m.ai_skill:
		"Easy": return maxi(20,base_pct-22)
		"Hard": return mini(88,base_pct+8)
		_: return base_pct

static func skill_attack_threshold(m, base_threshold:int)->int:
	match m.ai_skill:
		"Easy": return base_threshold+14
		"Hard": return maxi(12,base_threshold-5)
		_: return base_threshold

static func skill_attack_gap_seconds(m, base_gap:int)->int:
	match m.ai_skill:
		"Easy": return base_gap+18
		"Hard": return maxi(12,base_gap-5)
		_: return base_gap

static func weakest_wall(m, r)->String:
	var best := "N"; var hp := int(r.wall_hp[best])
	for d in m.DIRS:
		if int(r.wall_hp[d]) < hp: best=d; hp=int(r.wall_hp[d])
	return best

static func choose_target(m, r)->int:
	var choices:Array=[]
	for pid in m.active_fiefdom_chain():
		if int(pid)!=r.player_id: choices.append(int(pid))
	if choices.is_empty(): return -1
	if m.ai_skill=="Easy": return int(choices[m._rng.randi_range(0,choices.size()-1)])
	var best:int=int(choices[0])
	if r.personality=="Aggressor":
		for pid in choices:
			if m._player_buildings(int(pid)) > m._player_buildings(best): best=int(pid)
	else:
		for pid in choices:
			if m._player_buildings(int(pid)) < m._player_buildings(best): best=int(pid)
	return best

static func choose_target_wall(m, pid:int)->String:
	if m.ai_skill=="Easy": return m.DIRS[m._rng.randi_range(0,3)]
	var best: String = "N"; var hp: int = int(m._player_wall_hp(pid, best))
	for d in m.DIRS:
		if int(m._player_wall_hp(pid, d)) < hp: best = String(d); hp = int(m._player_wall_hp(pid, d))
	return best
