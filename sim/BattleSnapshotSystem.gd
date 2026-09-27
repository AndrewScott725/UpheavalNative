extends RefCounted

## Small, allocation-heavy serialization helpers kept out of UpMatch's gameplay
## loop. Full snapshot application remains coordinated by UpMatch because it owns
## the nested simulation types and indexes.

static func snapshot_unit(u) -> Dictionary:
	return {"id":u.id,"def":u.def,"hp":u.hp,"member_hp":u.member_hp,"group_size":u.group_size,"lane":u.lane,"next_attack":u.next_attack}

static func snapshot_invader(inv) -> Dictionary:
	return {
		"id":inv.id,"def":inv.def,"hp":inv.hp,"member_hp":inv.member_hp,"group_size":inv.group_size,
		"next_attack":inv.next_attack,"active_tick":inv.active_tick,"x":inv.x,"y":inv.y,"prev_x":inv.prev_x,"prev_y":inv.prev_y,
		"wall":inv.wall,"wall_lane":inv.wall_lane,"inside":inv.inside,"at_wall":inv.at_wall,
		"wall_contact_tick":inv.wall_contact_tick,"structure_contact_tick":inv.structure_contact_tick,
		"tgt_kind":inv.tgt_kind,"tgt_id":inv.tgt_id,"hx":inv.hx,"hy":inv.hy,"force_color":inv.force_color,"army_id":inv.army_id,
		"path":inv.path.duplicate(true),"path_index":inv.path_index,"path_target_kind":inv.path_target_kind,"path_target_id":inv.path_target_id,
		"last_progress_x":inv.last_progress_x,"last_progress_y":inv.last_progress_y,"stuck_ticks":inv.stuck_ticks}

static func home_battle_is_active(m) -> bool:
	if not m.invaders.is_empty() or not m.sortied.is_empty() or not m.shots.is_empty() or not m.melee_impacts.is_empty() or not m.death_floats.is_empty(): return true
	if not m.pending.is_empty(): return true
	for a in m.armies:
		if a.target == 0 and a.phase != "dead" and a.phase != "return": return true
	return false

static func rival_battle_is_active(m, pid:int) -> bool:
	if pid < 1 or pid > m.rivals.size(): return false
	var r = m.rivals[pid-1]
	if not r.invaders.is_empty() or not r.shots.is_empty() or not r.melee_impacts.is_empty() or not r.death_floats.is_empty(): return true
	for a in m.armies:
		if a.target == pid and a.phase == "rival_field": return true
	return false
