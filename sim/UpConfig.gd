class_name UpConfig
extends RefCounted

## Every tunable number in Upheaval, in one place.
##
## IMPORTANT: the current rulebook defines no final roster, attack curve or
## unit statistics. Every value in this file and in UpDefs.gd is a PLACEHOLDER
## invented so the prototype runs. Tune here; nothing outside this file and
## UpDefs.gd should contain a magic number.

## Fixed-point scale (§16.3). Every simulation value is an integer scaled by S.
## Floating point is never used for state that affects outcomes.
const S: int = 1000

const TPS: int = 10            ## simulation ticks per second
const GRID: int = 12           ## §2.1 interior building grid

## --- positions -------------------------------------------------------------
## Unit positions are integers in millicells: one grid cell == 1000.
const CELL: int = 1000

## --- economy ---------------------------------------------------------------
const START_GOLD: int = 400 * S
const START_COUNTDOWN: int = 10 * TPS  ## first building placed -> 10 seconds before simulation clock begins
const COST_GROWTH_NUM: int = 155   ## §3.3 repeat purchase escalation, /100
const COST_GROWTH_DEN: int = 100

## --- clicking (§5) ---------------------------------------------------------
const CLICK_PCT: int = 100         ## §5.2 10% of a structure's per-second output, /1000
const CLICK_CAP: int = 10          ## §5.4 effective clicks per second
const TRANSFER_PCT: int = 20       ## §5.3 2% of the remaining pool, /1000

## --- walls (§7) ------------------------------------------------------------
const WALL_START_MELEE: int = 50   ## §7.2 starting garrison per wall
const HP_COLLAPSE: int = 10 * S    ## §7.3 below this the wall collapses
const HP_PARTIAL: int = 50 * S     ## §7.3 partial wall
const HP_FULL: int = 100 * S       ## §7.3 full wall
const REBUILD_COOLDOWN: int = 10 * TPS  ## §7.3 ten seconds before the outline accepts troops
const WALL_COLLAPSE_ANIM_TICKS: int = 8  ## presentation/state: 0.8-second collapse animation

## --- day cycle (§1.4) ------------------------------------------------------
const PHASE_DAY: int = 60 * TPS
const PHASE_TWILIGHT: int = 15 * TPS
const PHASE_NIGHT: int = 30 * TPS
const PHASE_DAWN: int = 15 * TPS
const DAY_TICKS: int = PHASE_DAY + PHASE_TWILIGHT + PHASE_NIGHT + PHASE_DAWN

## --- attacks (§7.5) --------------------------------------------------------
const FIRST_ATTACK: int = 40 * TPS
const GAP_START: int = 42 * TPS
const GAP_FLOOR: int = 16 * TPS
const GAP_REDUCTION_PER_MINUTE: int = 2 * TPS  ## time-based only; independent of defender strength
const SIZE_START: int = 26
const SIZE_GROWTH_PER_WAVE: int = 5            ## uncapped baseline growth
const SIZE_GROWTH_PER_MINUTE: int = 8          ## additional uncapped time pressure
## Environmental-invasion prototype constants. Environmental/random invasions
## are disabled in the active War Camp ruleset; these values are used only by
## the inactive `_schedule_attack()` prototype path.
const WARN_MIN: int = 10 * TPS
const WARN_MAX: int = 30 * TPS
const RANGED_SHARE_START_PCT: int = 28
const RANGED_SHARE_MAX_PCT: int = 45
const RANGED_SHARE_PER_2_MIN: int = 2          ## composition gets harder with match time

## --- movement --------------------------------------------------------------
const SPEED_APPROACH: int = 160    ## millicells per tick, outside the walls
const SPEED_INSIDE: int = 125      ## millicells per tick, inside the fiefdom

## Travelling armies are visible for their full journey. PREVIEW_APPROACH_SPEED
## maps remaining travel time directly to visible standoff distance: a 20-second
## army starts twice as far out as a 10-second army.
const PREVIEW_APPROACH_SPEED: int = 50
const REACH: int = 180             ## millicells: melee centers must visually touch/overlap before soldier-vs-soldier attacks
const MELEE_STRUCTURE_REACH: int = 0   ## Raiders must physically touch a structure before striking it

## --- offensive warfare (§9) ---
## War Camp travel time is determined by circular-chain distance between active
## fiefdoms. UpMatch chooses one of these three durations at departure.
const TRAVEL_NEAR_SECONDS: int = 10
const TRAVEL_MID_SECONDS: int = 15
const TRAVEL_FAR_SECONDS: int = 20
const AI_BUILD_INTERVAL: int = 3 * TPS
## AI opponents use the same click bucket and per-click production/transfer rules
## as the human. Difficulty changes how often they attempt an action, not the
## amount produced by a building or transferred by a click.
# AI action cadence is intentionally below the mechanical click cap. Human
# players do not click with metronomic precision, so rivals act in uneven bursts
# and sometimes pause to "think". These are baseline delays; UpMatch adds seeded
# deterministic jitter and occasional attention pauses around them.
const AI_EASY_ACTION_TICKS: int = 6      ## baseline ~1.7 actions/sec
const AI_STANDARD_ACTION_TICKS: int = 4  ## baseline 2.5 actions/sec
const AI_HARD_ACTION_TICKS: int = 2      ## baseline 5 actions/sec
const AI_MIN_ATTACK_GAP: int = 18 * TPS

## --- combat feedback (presentation) ---
## Arrows are a visual record of a hit that has already been resolved. They
## carry no simulation weight: no travel time, no interception, no effect on
## damage. The simulation records where each shot came from and where it landed;
## the view animates it (§16.1).
const ARROW_FLIGHT: int = 5         ## ticks an arrow is drawn for
const MAX_SHOTS: int = 600          ## hard cap so a huge volley cannot stall the view
const MELEE_IMPACT_TICKS: int = 5   ## short melee contact burst lifetime (~0.5 sec)
const MAX_MELEE_IMPACTS: int = 240  ## presentation-only cap
const DEATH_FLOAT_TICKS: int = 14    ## ~1.4 sec skull-and-crossbones float
const MAX_DEATH_FLOAT_EVENTS: int = 600 ## event cap; each event may render one skull per actual casualty
const ARCHER_SPREAD: int = 420      ## millicells of lateral scatter along a wall
## Invading archers deliberately have a shorter wall-engagement envelope than
## defending archers (8 cells in UpDefs).  This one-cell defensive advantage
## guarantees that an invader cannot legally damage a standing wall/garrison
## from beyond the wall defenders' normal range.  This applies only to attacks
## against the perimeter wall; interior building combat keeps the unit's normal
## weapon range.
const INVADER_WALL_RANGED_MAX: int = 7 * CELL

## --- targeting -------------------------------------------------------------
const TURRET_SPREAD: int = 6       ## §6.8 how many nearest targets turret fire spreads across
const WALL_ARCHER_SPREAD: int = 8 ## nearby invader groups wall archers distribute fire across

## --- performance / presentation -------------------------------------------
const MAX_CATCHUP_STEPS: int = 1   ## never let catch-up monopolize the main thread/input
const MAX_ACCUM_SECONDS: float = 0.12
const UNIT_DETAIL_LIMIT: int = 1500 ## full-detail reference point; actual sprite atlases remain GPU-batched above this unless emergency fallback engages
const MAX_DRAWN_INVADERS: int = 2000 ## presentation cap only; simulation still tracks every invader
const SPATIAL_BUCKET: int = 2 * CELL ## interior nearest-target acceleration grid
const FLOW_FIELD_CACHE_MAX: int = 32 ## shared reverse-flow maps; normally invalidated immediately on layout changes

## --- hybrid large-army simulation -----------------------------------------
## Invading forces are simulated as small deterministic groups rather than one
## RefCounted object per visible soldier. Each group still tracks exact total HP,
## soldier type, wall assignment, position, attack timing and Structural
## Attrition. Presentation can draw many soldiers from one simulation group.
const INVADER_GROUP_SIZE: int = 1
const MAX_VISUAL_INVADERS: int = 30000  ## hard presentation ceiling; adaptive quality selects a lower live budget
const MAX_VISUALS_PER_GROUP: int = 3000   ## global cap, not CPU simulation count
const MAX_GROUP_ARROW_VISUALS: int = 4
## --- wall garrison presentation (§16.1 view-only) ---
## Decorative archers pacing the parapet. Like the invader crowd, the count is a
## representation rather than a census: a wall shows at most WALL_VISUAL_MAX
## figures however many thousands are actually stationed there.
const WALL_VISUAL_MAX: int = 30         ## visual figures per wall at full garrison
const WALL_VISUAL_MIN: int = 4
## A turret is a small platform: it shows at most this many figures however many
## soldiers are stationed there. Scaling below the cap uses the same sqrt ratio
## as the walls, so a turret reads as proportionally manned.
const TURRET_VISUAL_MAX: int = 10          ## a manned wall always shows a few
## Figures scale with the square root of the garrison, not linearly: real walls
## hold tens to hundreds of soldiers, and a linear divisor large enough for a
## 10,000-strong garrison renders a starting wall of 50 as a single figure.
## sqrt gives 50 -> 7, 500 -> 22, 10,000 -> capped at 30.
## Slowest and fastest full traverse of a figure's own beat, in microseconds.
## Each figure picks a speed in this range, so a wall never paces in unison.
const WALL_PATROL_SLOW_USEC: int = 17000000
const WALL_PATROL_FAST_USEC: int = 10000000

const GPU_CROWD_REFRESH_USEC: int = 50000 ## baseline refresh interval; adaptive quality may choose 10-40 Hz locally

## Adaptive local presentation quality. These settings NEVER affect simulation,
## authoritative troop counts, damage, networking, or battle outcomes. Every PC
## independently selects a tier from sustained frame time.
const ADAPTIVE_QUALITY_MIN: int = 0
const ADAPTIVE_QUALITY_MAX: int = 4
const ADAPTIVE_QUALITY_START: int = 2
const ADAPTIVE_QUALITY_EVAL_SECONDS: float = 0.75
const ADAPTIVE_QUALITY_UP_HOLD_SECONDS: float = 3.0
const ADAPTIVE_QUALITY_DOWN_HOLD_SECONDS: float = 0.9

## Conservative emergency fallback for mobile troop presentation. Detailed atlas
## MultiMesh batching is preferred even above 1500.  These thresholds are only
## consulted after cosmetic/adaptive update throttling has already bottomed out
## and visibly distracting lag persists; recovery is deliberately slow.
const ADAPTIVE_DETAIL_STAGE1_LIMIT: int = 1250
const ADAPTIVE_DETAIL_STAGE2_LIMIT: int = 900
const ADAPTIVE_DETAIL_LAG_FRAME_MS: float = 32.0
const ADAPTIVE_DETAIL_LAG_WORK_MS: float = 25.0
const ADAPTIVE_DETAIL_LAG_FPS: int = 30
const ADAPTIVE_DETAIL_DOWN_HOLD_SECONDS: float = 4.5
const ADAPTIVE_DETAIL_STAGE2_HOLD_SECONDS: float = 6.0
const ADAPTIVE_DETAIL_RECOVER_FRAME_MS: float = 22.0
const ADAPTIVE_DETAIL_RECOVER_WORK_MS: float = 14.0
const ADAPTIVE_DETAIL_RECOVER_FPS: int = 50
const ADAPTIVE_DETAIL_RECOVER_HOLD_SECONDS: float = 12.0
const ADAPTIVE_DETAIL_CHANGE_COOLDOWN_SECONDS: float = 5.0

## Adaptive simulation budgets. Small fights remain nearly 1:1; as troop totals
## grow, each simulation entity represents more soldiers while exact HP/counts
## are retained. Stationed defenders are capped per wall/turret slot so a castle
## with tens of thousands of defenders never creates tens of thousands of timers.
const MAX_GROUPS_PER_ARMY: int = 80
const MAX_INVADER_GROUPS_PER_BATTLEFIELD: int = 80
const MAX_DEFENDER_GROUPS_PER_SLOT: int = 15
const TARGET_BATTLE_GROUPS: int = 160
const MAX_BATTLE_GROUPS: int = 200
const MERGE_GROUPS_INTERVAL: int = 1 * TPS

## Interior movement recovery/pathing. Paths are computed only on target change
## or when a group stops making progress.
const STUCK_REPATH_TICKS: int = 15
const STUCK_MOVE_EPSILON: int = 70
const PATH_WAYPOINT_REACH: int = 180

## --- DINO-style crowd contact / presentation --------------------------------
## A rendered infantry sprite is about this many simulation millicells deep from
## its center to its leading edge.  This lets the first soldier in a packed
## group begin melee the instant its body reaches stone/structure rather than
## waiting for the packet center.
const CROWD_MELEE_FRONT_REACH: int = 220
## Once the front rank has made contact, additional members feed into the attack
## at a deterministic frontage rate.  This preserves exact troop counts while
## avoiding the old all-at-once packet strike.
const CROWD_CONTACT_JOIN_PER_TICK_MIN: int = 2
const CROWD_CONTACT_JOIN_PER_TICK_MAX: int = 48
## Presentation crowd solver.  The solver itself is local/view-only; combat
## remains deterministic in the authoritative fixed-point simulation.
const CROWD_PRESENTATION_HZ: int = 24
const CROWD_PERSONAL_RADIUS_PX: float = 12.0
const CROWD_HASH_CELL_PX: float = 28.0
const CROWD_MAX_NEIGHBORS: int = 12
const CROWD_MAX_VISIBLE_AGENTS: int = 7000
