# Upheaval — Godot prototype

Current local gameplay prototype. Use Godot 4.7.x or a compatible Godot 4.x release.

This README is the single project reference for the current build. Historical fix
notes that previously lived in separate README files have been consolidated here
and rewritten to describe the current implementation rather than superseded states.

## Running it

Open this folder as a Godot project and press Play. `main.tscn` contains the root
Control node; the simulation, HUD, board and renderers are built in code.

## Current project layout

```text
project.godot
main.tscn
sim/
  UpConfig.gd          tunable prototype constants
  UpDefs.gd            building and soldier definitions
  UpMatch.gd           authoritative match state, economy, AI and warfare orchestration
  CombatSystem.gd      player-fiefdom combat collection/resolution
  InvaderSystem.gd     player-fiefdom invader movement, collision and targeting
  RivalBattleSystem.gd physical invasions of AI fiefdoms
view/
  Main.gd              fixed-step loop and HUD
  BoardView.gd         fiefdom/recon board and interaction presentation
  BuildingRenderer.gd  shared building art for player and rival fiefdoms
  ArmyRenderer.gd      soldier/crowd rendering
  EffectsRenderer.gd   arrows, melee impacts and casualty feedback
  UpIcons.gd           generated HUD/icon drawing
```

## Simulation architecture

### Fixed-point authoritative state

`UpConfig.S = 1000`. Economy, HP, damage, production and soldier pools are
integer fixed-point values. Unit world positions use integer millicells, where
one grid cell is `1000` millicells. Outcome-sensitive geometry returns integer
results; the integer-square-root helpers use `sqrt()` only for an initial estimate
and correct that estimate with integer arithmetic. Presentation uses floats freely.

### Disposable match state

`UpMatch` is a `RefCounted` containing one complete local match. The UI sends
actions/intent into the simulation and reads the resulting state; the view does
not decide costs, damage, movement legality or victory.

### Hybrid invading armies

War Camps can contain uncapped soldier quantities, but invading forces are
simulated as deterministic groups rather than one simulation object per soldier.
The baseline group size is 4 soldiers and large armies dynamically increase
group size so a deployed army stays near the `MAX_GROUPS_PER_ARMY` bound of 120.
Each group retains exact combined HP and therefore an exact represented survivor
count. Compatible groups may merge without counting the merge as a casualty.

The renderer expands simulation groups back into visible soldiers. Large crowds
use presentation limits/LOD only; visual sampling does not change authoritative
army strength.

## Current match

The source-9 prototype instantiates four fiefdoms:

- Ironcrest — human player
- Stonehelm — Aggressor AI
- Redhold — Fortifier AI
- Blackfen — Opportunist AI

The match continues until one active fiefdom remains. A fiefdom is eliminated
when its final building is destroyed. Environmental/random NPC invasions are
disabled in the active four-fiefdom match; offensive armies come from War Camps
owned by participating fiefdoms.

Joined network players receive their own local conquered terminal screen as soon as their fiefdom is defeated. Their client can no longer issue gameplay actions, while the surviving players continue the network match normally.

Before the opening building is placed, the player chooses Easy, Standard or Hard
AI. Difficulty changes AI action cadence and decision quality, not hidden unit,
building or combat-stat multipliers.

## Economy and construction

- 12×12 interior building grid.
- Six current placeholder buildings defined in `UpDefs.gd`.
- Rotatable polyomino footprints.
- Production is deposited once per second.
- Building clicks grant 10% of that building's per-second output.
- Effective production/transfer clicks are capped at 10 per second.
- Soldier-transfer clicks move 2% of the remaining pool, rounded up.
- Repeat purchases escalate in Gold cost.
- Production-rate prerequisites are checked when a building is placed.
- The first building starts a 10-second pre-match countdown; production, AI and
  warfare begin at `BEGIN`.
- Zero buildings eliminates the fiefdom.

The current building roster and all prototype balance values remain placeholders.
Tune gameplay values in `UpConfig.gd` and `UpDefs.gd` rather than scattering new
magic numbers through systems or views.

## AI construction and personalities

AI rivals use the same passive production, click percentage, transfer percentage,
purchase costs and prerequisites as the human economy.

When an AI decides to construct a building it evaluates all legal grid origins
and unique rotations, then scores those placements according to personality:

- **Aggressor:** favors outward/perimeter development, particularly for military
  production, and is less concerned with compact protection.
- **Fortifier:** is willing to use cheap structures as an outer buffer while
  pulling higher-level/important buildings toward a compact protected core.
- **Opportunist:** emphasizes efficient adjacency and use of space while
  distributing repeated/important structures rather than concentrating them in
  one exposed cluster.

All personalities reject overlaps and penalize isolated one-cell gaps. Placement
tie-breaking is deterministic. Gold is spent only after a legal placement has
been found.

Player and rival fiefdoms use the same `BuildingRenderer`, so reconnaissance
shows the actual rival polyomino layouts rather than the older cottage symbols.

## Circular fiefdom distance and War Camp travel

Active fiefdoms form a circular chain in player-id order. Eliminated fiefdoms are
removed from the active chain and the remaining links close together without
otherwise changing order.

Distance is the shortest number of links clockwise or counter-clockwise between
two active fiefdoms.

For `N` active fiefdoms:

```text
A = ceil(N / 3)
D = ceil(A / 2)
```

Travel time at deployment is:

- distance `1..D` → 10 seconds
- distance `D+1..2D` → 15 seconds
- distance `>2D` → 20 seconds

This applies to human→AI, AI→human and AI→AI attacks. A deployed army keeps the
travel duration selected when it left; newly launched armies use the currently
recalculated active chain. A surviving army's return trip uses its departure
route duration.

The Surrounding Fiefdoms panel sorts active opponents by current chain distance
from Ironcrest, closest first. Equal-distance opponents retain circular-chain
order. Defeated opponents remain listed after active opponents.

## Travelling armies

Travelling armies are visible for their entire journey, not only during the last
few seconds. Their visible standoff distance is proportional to remaining travel
time, so an army 20 seconds away begins twice as far from its destination as an
army 10 seconds away.

Incoming armies approaching Ironcrest and armies seen approaching a scouted rival
use the same soldier silhouettes, grouped wall lanes, formation spacing and
horde-depth presentation. Travelling armies are presentation-visible but cannot
be targeted or deal damage before their authoritative arrival tick.

## Player-fiefdom invasion rules

The physical battlefield obeys these movement/combat invariants:

- Raiders cannot deal or receive wall melee damage until they are visibly at the
  authoritative wall-contact position and at least one simulation tick has
  passed after contact.
- Invaders never occupy an intact wall, turret or building footprint.
- An invader entering after a collapse crosses only through its assigned breach.
- Interior movement performs collision/path checks against intact building
  footprints and includes recovery if a future/save-state error places a group
  illegally inside a building.
- A Raider attacking a building must physically touch that building's occupied
  footprint before melee damage can resolve.
- Marksmen obey the same collision/path rules but may stop at their ranged attack
  distance when line of sight is valid.

Defender and invader ranged attacks are resolved authoritatively and then recorded
for arrow animation. Melee structure/wall hits record a short impact burst.
Casualty feedback is soldier-accurate: if a grouped army loses 30 represented
soldiers, the presentation event can render 30 skulls rather than one skull for
the whole simulation group.

## Walls, turrets and rebuilding

- A wall's authoritative HP is the combined HP of its stationed melee defenders.
- Walls collapse below the collapse threshold and remain passable until rebuilt
  to the standing threshold.
- Melee defenders rebuild walls after the rebuild cooldown; ranged soldiers
  cannot rebuild a collapsed wall.
- A turret is destroyed only while both of its connected walls are collapsed and
  becomes operational again when at least one connected wall stands.
- Turret melee defenders sortie into the fiefdom after a breach and can return to
  the closest standing turret.
- Wall rendering changes uniformly across the whole wall with HP: light→dark as
  it is destroyed and dark→light as it is rebuilt. It does not fill from one
  side like a progress bar.

## Physical invasions of AI fiefdoms

AI fiefdoms no longer resolve incoming War Camps as an abstract wall/interior
exchange. `RivalBattleSystem.gd` maintains physical invader groups on each rival
battlefield.

After arrival, attackers:

- reach and fight the selected wall;
- wait for authoritative wall collapse;
- enter through that breach;
- path around intact rival building footprints;
- choose real placed buildings as interior targets;
- require exact structure contact for Raider melee attacks;
- allow Marksmen to stop at range with line-of-sight checks;
- remove destroyed buildings from the rival's actual occupancy/pathing data; and
- eliminate the rival only after its final building is destroyed.

Reconnaissance renders those authoritative rival-battle positions, along with
ranged arrows, melee impacts, building damage and casualty feedback. It is not
an aggregate placeholder battle visualization.

## Combat and targeting highlights

- Attack resolution is simultaneous within a simulation tick: due attacks are
  collected before damage/deaths are applied.
- Structural Attrition applies to attacks on buildings, not soldier-vs-soldier
  combat or walls.
- Invading ranged soldiers prioritize defending ranged targets before melee where
  the current targeting rule calls for defenders.
- Defender ranged attacks enforce range and building line of sight.
- Interior invader building selection uses physical footprint distance, building
  level and deterministic clockwise tie-breaking.
- Wall/turret targeting and retained-target checks use spatial/indexed helpers to
  avoid full-population work where possible.

## HUD and reconnaissance

The current HUD includes:

- Buildings and construction list on the left.
- Barracks and three War Camps along the bottom.
- Incoming War Camp banners with invader count, target wall and countdown.
- Surrounding Fiefdoms on the right, ordered by circular-chain distance.
- Date/time and fiefdoms-remaining status.
- Event Log aligned beneath the surrounding-fiefdom list.
- Reconnaissance of a rival fiefdom after it has been unlocked by sending a War
  Camp there.
- Live wall HP/building counts and physical rival battles in recon view.

Treasury shows passive Gold/sec and total building count. Building production
clicks use floating gain text near the clicked building.

## Performance protections

The prototype currently uses several safeguards for large battles:

- bounded simulation groups per deployed army;
- periodic compatible-group merging;
- exterior/interior spatial buckets;
- O(1) invader-id maps for retained targets;
- nearby-candidate limits for wall/turret ranged fire;
- attack-tick buckets for stationed wall/turret defenders, so defenders whose
  attack cooldown has not expired are not visited every simulation tick;
- targeted dead-defender cleanup, so only garrisons that actually suffered a
  lethal hit are compacted after combat;
- path recomputation mainly on target changes or lack of progress;
- one fixed simulation step of catch-up per rendered frame;
- a GPU `MultiMesh` path for large visible crowds;
- an adaptive local visual-soldier budget (roughly 3,000–30,000 depending on
  sustained frame headroom) while authoritative soldier quantities remain unchanged.

Source 9 now simulates physical battles on rival fiefdoms as well as Ironcrest,
so multi-fiefdom performance should be treated as an active playtest/profiling
area as the project moves beyond the current four-fiefdom test match.

## Direct-IP multiplayer

The four-fiefdom prototype now supports host-authoritative direct-IP multiplayer
using Godot ENet transport.

- One player hosts on UDP port `27777`.
- Up to three additional players connect to the host's IP address.
- Every connected peer is assigned a unique fiefdom: Ironcrest, Stonehelm,
  Redhold or Blackfen.
- Any unfilled fiefdom slots remain AI-controlled.
- All peers create the same deterministic match from the host-provided seed.
- Human input is sent to the host, assigned an authoritative simulation tick,
  then broadcast to every peer and executed in deterministic order.
- Clients stay within a small tick window of the host so actions resolve on the
  same simulation tick without making rendering wait for every network round trip.
- Human-controlled rival slots use the existing rival-fiefdom economy, building,
  wall and War Camp state. AI decision-making is disabled for those slots.
- Physical battlefield simulation is distributed for **all** fiefdoms. Each
  connected human owns the defending/invading troop simulation for their own
  fiefdom, including Player 0/the host, and unfilled AI battlefields are
  load-balanced across connected peers. The host relays authoritative battlefield
  snapshots but does not step battles owned by another peer. Player 0 is no longer
  redundantly simulated by every joined client. Active battles publish at 5 Hz for
  smooth remote presentation;
  idle fiefdoms publish only a 3-second safety heartbeat, avoiding continuous
  serialization/rebroadcast of unchanged battlefield state. Remote-owner snapshots
  are not echoed back to the source peer.
- Strategic AI/economy decisions remain lightweight deterministic replicated work
  on every peer so command/id ordering stays aligned; the expensive AI troop
  movement, targeting, wall/building combat and casualty processing runs only on
  the peer assigned to that AI fiefdom.
- If a client disconnects during a match, the host temporarily assumes any rival
  battlefields owned by that peer and broadcasts the new authority assignment.
- The match countdown begins after every connected human has committed their
  first building.
- For internet play outside a LAN, the host will normally need UDP port 27777
  forwarded through their router/firewall.

The current multiplayer layer is prototype networking rather than a production
online service. It does not yet include matchmaking, relay/NAT traversal,
reconnection/state resynchronization, host migration, anti-cheat, or late join.

Human-controlled rival-backed fiefdoms model independent wall and turret
melee/ranged garrisons. Their owning player gets the full home-defense presentation
and authoritative transfer/combat behavior, while scouting players retain the
reduced reconnaissance view.

## Current scope / not yet implemented

The current build still does **not** yet include:

- a 30-fiefdom match configuration (the current initializer creates four);
- solo mission/progression content;
- Kaiju systems;
- a pre-match faction/building draft; or
- final production art/audio/balance.

The circular-distance, dynamic rival-list and warfare code is written around the
active fiefdom set rather than assuming all distance calculations are permanently
four-player, but larger match creation and the surrounding content/UI required
for a 30-fiefdom game are future work.

## Player-chosen kingdom names
On application startup, each player is prompted to name their kingdom before entering the multiplayer lobby. In network matches the client submits that name to the host, the host binds it to the assigned human player slot, and the complete name map is included in the authoritative match-start RPC. Human-controlled fiefdoms use those names throughout the HUD, surrounding-fiefdom list, targeting, combat/event logs, victory/conquest messaging, and home-fiefdom banner. AI-only fiefdoms retain the original generated/premade names.

## Adaptive large-battle architecture (2026-09-24)

Large battles use a hybrid scene/code architecture designed to keep simulation cost bounded while preserving exact troop totals:

- `BoardView` is now instantiated from `view/BoardView.tscn`; high-count battlefield rendering remains code-driven inside that scene rather than creating one scene/node per soldier.
- Invading armies use adaptive `Invader` packets. Small armies can remain one soldier per packet; large armies widen packets automatically (max 80 groups per army).
- Player-0 wall/turret defenders now use adaptive `Unit` packets too. Each wall/turret/type slot is capped at 15 simulation groups. A packet retains exact combined HP and therefore exact casualty/headcount accounting.
- Turret melee sorties preserve the same grouped representation when they enter the field and when survivors return to a turret.
- Defender attack/damage resolution scales by represented member count, so grouped units preserve aggregate damage while avoiding per-soldier timers and target work.
- Small mobile battles (<= `UNIT_DETAIL_LIMIT`) still render detailed figures. Larger battles are expanded visually through one `MultiMesh` batch, with up to 20,000 visible attackers/sorties while the CPU simulates only the much smaller group set.
- Wall/turret garrison figures remain intentionally representative rather than a literal census; tooltips still report exact soldier counts.

This architecture intentionally separates **simulation entities** from **visual soldiers**. Do not replace adaptive packets with one `Node2D`/`Sprite2D` per soldier; that would reintroduce the large-battle CPU/node overhead this system is designed to avoid.


## Adaptive local visual quality

Large battles now use a local five-tier adaptive presentation controller. It watches sustained frame time with hysteresis and changes only presentation; simulation, troop totals, damage, network authority, and battle outcomes are identical on every peer. Lower tiers first reduce projectile/effect density, casualty particles, shadows, wall/turret crowd density, animation variation, and interpolation/update frequency. The mobile visual-soldier budget ranges from roughly 3,000 on the performance tier through 30,000 on the ultra tier. Quality drops quickly if responsiveness is threatened and rises only after several seconds of clear frame-time headroom, so stronger machines automatically render richer battles while weaker machines preserve input responsiveness.


## Split static/dynamic BoardView rendering (2026-09-24)

`BoardView` now uses two CanvasItem layers that share the same renderer implementation.
The root/static layer owns input and draws terrain, field, buildings and walls only when
those structures, camera state or reconnaissance target actually change. A mouse-ignoring
child `BoardView` draws continuously moving soldiers, wall/turret crowds, arrows, impacts,
casualty effects, placement ghosts, gain popups and tooltips at display cadence. This avoids
re-running the full terrain/building/wall custom-draw path every rendered frame merely
because troops are moving.

Player 0 now uses the same distributed battle-authority contract as every other battlefield.
The host exclusively advances Player 0's incoming armies, invaders, sorties, defender combat,
wall collapse and destruction state. Joined peers receive compact Player-0 snapshots; wall and
turret defender state is sent as exact aggregate HP/count information rather than per-packet
defender simulation objects, reducing snapshot size while preserving remote visuals/tooltips.

## Current castle presentation

The fiefdom uses the approved modular fortress assembled from exactly nine independent
full-canvas transparent PNG layers: four walls, four round towers, and the courtyard
grid. `CastleRenderer.gd` swaps each wall/tower slot between intact, rubble, and
half-built art without destructive image masking.

Authoritative castle overlap order, bottom to top:

1. North wall.
2. Northwest and Northeast towers.
3. South wall.
4. West and East walls.
5. Southwest and Southeast towers.
6. Courtyard grid.

This ordering applies to intact, rubble, and half-built states. The courtyard grid is
always above all castle wall/tower art. Buildings and units are rendered above the
courtyard where gameplay requires them.

Wall state presentation:

- Damage does not use half-built artwork.
- A collapsing wall dissolves directly from intact to rubble.
- A collapsed wall remains rubble until rebuilding reaches the half-built threshold.
- Rebuilding then uses half-built art until the wall returns to full standing state.

Tower state presentation:

- A round tower remains intact while at least one connected wall is standing.
- A tower collapses only when both supporting walls are down.
- Collapse dissolves directly from intact to rubble.
- The half-built tower art is used only on the rebuild path.
- When a supporting wall is fully standing again, the tower returns to intact art.

`CastleInteraction.gd` uses alpha-derived `BitMap` hit masks for wall/tower interaction.
Those masks are for click/hover geometry only; they do not crop or compose visible
castle artwork.

## Current wall and tower interaction

- The full visible wall/tower piece is clickable for troop deployment and hover tooltips.
- Courtyard-grid interaction takes priority where the grid overlaps wall/tower hit areas.
- Wall and tower tooltips are semi-translucent.
- Wall tooltips do not include a Status row.
- South-wall melee invaders stop at the visible outside/front gate edge and may attack
  immediately on graphical contact; they do not walk onto the wall first.
- Melee soldier-vs-soldier reach is close-contact only (`REACH = 180` millicells).
- Melee building contact is exact (`MELEE_STRUCTURE_REACH = 0`).
- Wall/tower stationed defenders retain their special defensive combat rules.

## Archer targeting

Wall archers consider both valid target pools at the same time:

- incoming invaders in front of their own wall and within range;
- invaders already inside the fiefdom and within range/line of sight.

Turret archers likewise consider both pools simultaneously:

- incoming invaders on either connected wall, limited to the half of each wall adjacent
  to that turret;
- invaders inside the fiefdom within the turret's half-wall radius.

Interior targets do not suppress valid incoming targets. The same rules apply to rival/AI
fiefdom defenders.

## Current audio set

The prototype currently uses the selected audio assets in `audio/`:

- `ambient_medieval_loop.wav` — user-selected cinematic orchestral background music;
  restarted when it finishes so gameplay music continues through the match.
- `incoming_trumpet.wav` — Royal News Style incoming-invader banner fanfare.
- `courtyard_battle_loop.wav` — swords, shields, grunts, and pain reactions; loops only
  while living melee defenders and melee invaders are physically engaged in the courtyard.
- `wood_damage.wav` — selected building-damage sound.
- `stone_strike.wav` — selected wall-hit sound.
- `wall_crumble.wav` — selected wall-collapse sound.
- `wall_n.wav`, `wall_e.wav`, `wall_s.wav`, `wall_w.wav` — individual Tom announcements
  for the corresponding fallen wall.
- `tower_ne.wav`, `tower_nw.wav`, `tower_se.wav`, `tower_sw.wav` — individual Kirk
  announcements for the corresponding fallen tower.

The courtyard battle loop is triggered by physical melee contact using the same `REACH`
threshold as combat, not by an invader target-state string. Building-damage audio checks
the simulation's actual building target code (`"b"`).

## Landscape and courtyard color treatment

The existing landscape and courtyard-grid artwork is retained at its original dimensions
and geometry:

- `fiefdom_landscape_reference.webp`: 6000 × 5360.
- `castle_grid_exact.png`: 1122 × 1402.

Only color balance/saturation/contrast were adjusted: less yellow/red cast, greener grass,
richer brown earth, and modestly stronger saturation/contrast to match the approved mockups.
No replacement art, crop, scale, or layout change is used.

## Rendering structure

Presentation code is split by responsibility without changing simulation authority:

- `CastleRenderer.gd` — modular castle draw ordering and state presentation.
- `CastleInteraction.gd` — wall/tower hit testing.
- `TooltipRenderer.gd` — wall/tower and incoming-army tooltip presentation.
- `BuildingRenderer.gd` — building presentation.
- `ArmyRenderer.gd` — detailed and batched troop rendering.
- `EffectsRenderer.gd` — arrows, melee impacts, casualty effects.
- `BoardView.gd` — board/recon composition, input routing, terrain/grid presentation,
  and presentation-layer coordination.

`BoardView` no longer contains the obsolete damaged-castle alpha-erasure caches, erase
rectangles, or wall-overlay masking/compositing helpers. Persistent wall/tower damage states
are represented solely by swapping the modular PNG for that slot.

## Godot import/cache note

The project ZIP intentionally excludes stale `.godot` cache content and generated `.import`
metadata. On first open, Godot rebuilds imports locally. Extract the ZIP to a normal writable
local folder before opening `project.godot`; do not run the project from inside an archive or
a read-only location.


## 2026-09-27 gameplay/view fixes
- Tooltip panels are slightly more translucent.
- Wall/turret archers may engage any interior invader within their normal range; courtyard buildings no longer make an interior attacker immune to parapet fire.
- Surrounding fiefdom attacks now use the same visible pre-arrival march and graphic wall-contact timing as the home fiefdom.
- Surrounding fiefdom gate banners are overlaid with each faction's own crest color and heraldic device.

## Surrounding fiefdom view name
When reconnaissance is displaying a surrounding fiefdom, its fiefdom name is shown at the lower-right edge of the battlefield, directly above the War Camps row. The name group is right-aligned flush with the Surrounding Fiefdoms column and is bracketed by that faction's own heraldic banner on both sides, with the banners sized to the label text. The local/home fiefdom does not show this reconnaissance label.

## Incoming-army hover tooltip
Hovering a visible invading War Camp formation on either the home battlefield or a surrounding-fiefdom reconnaissance view shows the exact surviving composition of that army. The tooltip contains only Infantry and Archers counts; it intentionally omits Total and Target. Hover detection follows the same visual spread used to draw the formation so the entire visible army can be inspected, not only its center point.


## Soldier visibility after a breach (2026-09-27)
- Large exterior armies may still use the batched crowd renderer for performance.
- Once invaders cross a breached wall, they remain represented by detailed infantry/archer sprites in the courtyard.
- Turret melee defenders that sortie into the courtyard remain represented by detailed defender sprites.
- Wall and turret garrison figures remain driven by the authoritative surviving garrison counts; troops are removed only when the simulation actually kills/removes them under the wall/tower rules.
- This prevents the prior visual-mode switch from making soldiers appear to disappear when a breach occurs.

## Mass-army performance architecture (2026-09-27)

The prototype now preserves the detailed infantry/archer artwork throughout the
runtime performance stack. It no longer degrades soldiers into geometric crowd shapes.

- **Detailed GPU MultiMesh batching:** mobile infantry and archers use the actual sprite
  atlases, grouped by unit type, facing, state/frame and faction tint. Simulation units
  remain authoritative and independent from rendering.
- **Hybrid/data-oriented simulation:** large armies are represented by bounded deterministic
  combat packets with exact aggregate HP and soldier counts. A battlefield processes at most
  the configured packet budget rather than one heavyweight script object per visible soldier.
- **Shared flow fields:** melee packets attacking the same courtyard building reuse one cached
  reverse flow field for the 12x12 courtyard. The field is invalidated only when building
  occupancy changes. This replaces repeated per-packet A* work for the dominant siege path.
- **Direct-line bypass:** an interior packet with an unobstructed segment moves directly toward
  its target; A* is reserved for genuinely obstructed routes.
- **Spatial hashing:** home-battle nearest-target/contact searches use the existing incremental
  uniform-grid buckets, so local combat searches inspect nearby groups instead of the entire army.
- **Simple 2D contact:** soldiers use fixed-point X/Y positions and squared-distance/contact
  checks rather than thousands of physics bodies. Visual personal-space offsets remain
  mathematical rather than physics-driven.
- **FX throttling first:** projectiles, impact/death effects, particles, shadows and animation
  variation reduce before soldier presentation is touched.
- **Adaptive update throttling:** under sustained load, detailed MultiMesh transforms/animation
  refresh less frequently and representative density is reduced while keeping the same detailed
  sprite art. Unviewed surrounding fiefdoms do no rendering work.
- **Conservative emergency behavior:** 1,500 remains the preferred full-detail reference, but it
  is no longer a switch to low-detail geometry. Even emergency stages keep detailed sprites and
  use slower refresh/sampling only after sustained distracting lag.
- **Dynamic resolution:** still reserved rather than forced. The current bottleneck strategy
  attacks CPU simulation/submission work first; 2D SubViewport resolution scaling should only be
  added if profiling later proves fill-rate is the remaining bottleneck.
- The selected orchestral soundtrack remains a directly loaded looping MP3 and is automatically
  restarted if playback stops.

## Incoming-army tooltip origin identity

- Hovering a visible incoming army shows the source fiefdom's name and heraldic banner.
- The banner uses that fiefdom's current crest color and device.
- The composition remains Infantry and Archers only; Total and Target are intentionally omitted.
- The same tooltip behavior applies on the home battlefield and surrounding-fiefdom reconnaissance views.

## Soldier visual spacing

- Mobile infantry and archers now use a deterministic spaced formation instead of the old near-random 3-pixel offsets that caused sprites to pile on top of each other.
- Invading armies, breached courtyard invaders, and courtyard sortie defenders preserve visible personal space between representative sprites.
- Very large packets are visually sampled rather than forcing hundreds of detailed sprites into the same small courtyard footprint; all logical soldiers remain individual in the simulation.
- Wall defenders are assigned separated patrol/attack slots along the parapet.
- Turret defenders use deterministic rings so their sprite positions do not stack randomly.
- These are presentation-only changes: combat positions, reach, targeting, HP, and simulation counts are unchanged.

## Practical Godot equivalent of large-horde architecture

This prototype does not attempt to reproduce Unity DOTS/Burst inside Godot. Instead it
uses the equivalent optimizations that fit the existing deterministic GDScript design:
bounded aggregate combat packets rather than one simulation object per visible soldier,
shared flow fields, spatial buckets, direct-line movement, fixed-point 2D contact, detailed
GPU MultiMesh rendering, and conservative adaptive presentation throttling. This keeps the
current rules/network state model intact while moving the expensive horde work away from
per-soldier script/pathfinding/draw calls.

Dynamic resolution scaling remains intentionally dormant because the requested policy was
"only if needed." The adaptive stack first exhausts FX and update-frequency savings while
retaining detailed sprites; a 2D SubViewport render-scale path should only be enabled after
profiling demonstrates a true GPU fill-rate bottleneck.

## Kingdom-fall announcement

When any fiefdom transitions from alive to defeated, the presentation queues the selected voice line **“A Kingdom has fallen!”** once. The announcement is driven by authoritative defeat flags, so it applies to the home fiefdom, AI rivals, and replicated multiplayer rival defeats. The supplied audio is stored as `audio/kingdom_fallen.mp3` and loaded directly at runtime rather than relying on Godot import-cache metadata.

## 2026-09-27 crowd/frontage performance pass

This build replaces the old packet-centered exterior square/spiral visual formations that produced rigid vertical soldier columns. All visible members belonging to the same attacking army now share a wall-wide frontage layout with deterministic personal spacing, depth ranks, small per-agent stride drift, and stable jitter. Authoritative combat packets remain unchanged, so combat determinism and exact troop totals are preserved.

The detailed sprite MultiMesh path was also tightened for large battles: transform/animation batch rebuilds are capped to 10-30 Hz by quality tier instead of trying to rebuild at render-frame frequency, visible-soldier budgets are reduced to practical detailed-sprite ceilings (3k/5k/8k/12k/16k), animation clock reads are performed once per batch rebuild rather than once per soldier, body MultiMeshes no longer allocate/write unused per-instance colors, and repeated faction tint calculations are cached.

Interior packet visuals now use staggered personal-space offsets instead of square spirals, reducing obvious geometric carpets while the existing authoritative flow-field/path collision continues to keep groups out of intact buildings.
