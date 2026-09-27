# Wall occlusion + one-shot building selection (2026-09-27)

- Restored one-shot courtyard placement: after a successful placement, the selected building is cleared and the player must choose the next building from the list.
- Kept the placement confirmation click sound.
- Intact and half-rebuilt walls now physically block incoming invaders. A rebuild becomes solid again at `HP_PARTIAL`; rubble below that threshold remains an open breach.
- Applied the same blocking rule to home and surrounding-fiefdom battles.
- Crowd presentation now uses the same passability rule, so visual agents do not flow through a half-rebuilt wall.
- Added a dynamic foreground wall pass so physical wall pixels render above incoming attackers, then defenders render above the wall. This prevents invader sprites from appearing to stand on intact/half-built wall artwork.
- Recon/surrounding-fiefdom battles receive the same wall-foreground occlusion.
