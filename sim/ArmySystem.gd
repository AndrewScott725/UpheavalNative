extends RefCounted

## Strategic army lifecycle extracted from UpMatch. Combat packet details remain
## authoritative on UpMatch/RivalBattleSystem; this module owns launch/return flow.

static func survivors(a) -> int:
	return maxi(0, a.melee) + maxi(0, a.ranged)

static func begin_return(m, a) -> void:
	a.phase = "return"
	a.arrives = m.tick + m.travel_ticks_between(a.target, a.attacker)

static func return_army_to_camp(m, a) -> void:
	var camps: Array = m.player_camps(a.attacker)
	if a.from_camp >= 0 and a.from_camp < camps.size():
		var c = camps[a.from_camp]
		c.melee += maxi(0, a.melee)
		c.ranged += maxi(0, a.ranged)
	a.phase = "dead"
