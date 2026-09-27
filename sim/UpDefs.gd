class_name UpDefs
extends RefCounted
const UpConfigRef = preload("res://sim/UpConfig.gd")

## Data-driven definitions (§12, §16.6). Core systems never branch on a
## specific building or unit id — everything reads these dictionaries.
##
## ALL VALUES ARE PLACEHOLDERS. The rulebook defines no roster.

const S := UpConfigRef.S
const TPS := UpConfigRef.TPS

## ---------------------------------------------------------------------------
## Soldier definitions (§6.4)
##   cat      "melee" or "ranged" — the only two categories (§6.3)
##   hp       starting hit points
##   dmg      damage per successful attack
##   iv       attack interval in ticks
##   attr     Structural Attrition: self-damage per hit on a BUILDING (§8).
##            Never applies to soldier-vs-soldier, and never to walls.
##   ord      Attack Order — deterministic ordering value (§6.4)
## ---------------------------------------------------------------------------

const DEFENDERS := {
	"infantry": {
		"name": "Infantry", "cat": "melee",
		"hp": 3 * S, "dmg": 1 * S, "iv": 10, "attr": 1 * S, "ord": 1, "range": UpConfigRef.REACH,
	},
	"archer": {
		"name": "Archer", "cat": "ranged",
		"hp": 3 * S, "dmg": 1 * S, "iv": 8, "attr": 1 * S, "ord": 2, "range": 8 * UpConfigRef.CELL,
	},
}

const INVADERS := {
	"raider": {
		"name": "Raider", "cat": "melee",
		"hp": 3 * S, "dmg": 1 * S, "iv": 10, "attr": 1 * S, "ord": 1, "range": UpConfigRef.REACH,
	},
	"marksman": {
		"name": "Marksman", "cat": "ranged",
		"hp": 3 * S, "dmg": 1 * S, "iv": 8, "attr": 1 * S, "ord": 2, "range": 8 * UpConfigRef.CELL,
	},
}

## ---------------------------------------------------------------------------
## Building definitions (§3)
##   lvl      1-5. Breach tie-break priority AND draft category (§12.2)
##   cost     base Gold cost; escalates per purchase (§3.3)
##   hp       structural HP — the single durability stat (§3)
##   cells    polyomino footprint, rotatable (§3.1)
##   gold/melee/ranged  production PER SECOND (§4 — every building ticks once
##            per second; there are no fast-cycle or slow-cycle structures)
##   req      production-RATE prerequisite (§3.2), or null.
##            Checked at placement only; built structures are never re-locked.
## ---------------------------------------------------------------------------

const BUILDINGS := [
	{
		"id": "homestead", "name": "Homestead", "lvl": 1,
		"cost": 100 * S, "hp": 100 * S, "colour": "c9a227",
		"cells": [[0, 0], [1, 0]],
		"gold": 2 * S, "melee": 600, "ranged": 0,
		"req": null,
		"note": "Core production. Gold and a trickle of melee.",
	},
	{
		"id": "farm", "name": "Farm", "lvl": 1,
		"cost": 160 * S, "hp": 80 * S, "colour": "a8c04e",
		"cells": [[0, 0], [0, 1], [1, 1]],
		"gold": 4 * S, "melee": 0, "ranged": 0,
		"req": null,
		"note": "Gold only. Cheap and fragile.",
	},
	{
		"id": "drillyard", "name": "Drill Yard", "lvl": 2,
		"cost": 260 * S, "hp": 130 * S, "colour": "c2603f",
		"cells": [[0, 0], [1, 0], [1, 1], [2, 1]],
		"gold": 0, "melee": 2200, "ranged": 0,
		"req": {"res": "gold", "rate": 6 * S},
		"note": "Melee. The only troops that can rebuild a wall.",
	},
	{
		"id": "archery", "name": "Archery Range", "lvl": 2,
		"cost": 300 * S, "hp": 120 * S, "colour": "4f9e8a",
		"cells": [[0, 0], [1, 0], [2, 0], [1, 1]],
		"gold": 0, "melee": 0, "ranged": 1600,
		"req": {"res": "gold", "rate": 8 * S},
		"note": "Ranged. Turret garrisons and wall screens.",
	},
	{
		"id": "foundry", "name": "Foundry", "lvl": 3,
		"cost": 520 * S, "hp": 210 * S, "colour": "7a6cc4",
		"cells": [[0, 0], [1, 0], [0, 1], [1, 1]],
		"gold": 11 * S, "melee": 0, "ranged": 0,
		"req": {"res": "gold", "rate": 12 * S},
		"note": "Heavy gold. Big footprint, worth burying.",
	},
	{
		"id": "citadel", "name": "Citadel", "lvl": 4,
		"cost": 900 * S, "hp": 360 * S, "colour": "3b6fb5",
		"cells": [[0, 0], [1, 0], [2, 0], [0, 1], [1, 1]],
		"gold": 3 * S, "melee": 4500, "ranged": 2000,
		"req": {"res": "melee", "rate": 3 * S},
		"note": "Tough, produces both. Needs a melee economy first.",
	},
]

static func building(id: String) -> Dictionary:
	for b in BUILDINGS:
		if b["id"] == id:
			return b
	return {}
