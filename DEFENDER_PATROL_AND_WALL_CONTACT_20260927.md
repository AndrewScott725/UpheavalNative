# Wall-contact and defender-patrol update — 2026-09-27

- Invader visual-agent contact now uses the actual detailed sprite footprint rather than only the foot/center anchor. On intact or partial walls, no visible part of an invading soldier can advance onto the wall artwork.
- South-wall contact accounts for the full foot-anchored sprite height; east/west contact accounts for half sprite width; north contact uses the foot edge.
- Ranged visual goals use the same footprint clearance plus their standoff distance.
- Wall defenders retain their last combat lane after an attack ends and smoothly release into the continuously running patrol path over about five seconds. They no longer snap back to their pre-attack procedural patrol positions.
- The same patrol release behavior is used for the home fiefdom and viewed surrounding-fiefdom battles.
