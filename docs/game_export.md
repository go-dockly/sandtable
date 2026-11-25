# Exporting a level to Commandos

**What it does:**
- **`ctrl+E`** (`cmd+E` on a Mac) writes `levels/krakow.mission.json`, a mission commandos loads unchanged with its own `mission.load`.
- **Krakow's buildings become solid in the game.** The terrain's structure cells (2 m and more above the ground) are put on the game's 1 m grid and merged into rectangles, so the player can't walk through them and guards can't see through them.
- **Cars block movement and sight.** The game only has axis-aligned boxes, so each car's turned footprint is traced as `crate` rectangles at 25 cm. A car turned by a multiple of 90° is exactly one rectangle.
- **Your gameplay stays yours.** Put spawn, extraction, objective, walls and guards in `levels/krakow.mission.base.json`. The export merges into it and never changes it, so you can re-export any time. Without a base file you get a walkable map with a spawn on open ground near the middle.
- **`props`** lists every car with its model, position, height, yaw and size, ready for drawing the GLBs in the game later. The game ignores it for now.
- **1 game unit = 1 metre.** That matches the game, where a guard is 0.8 across.
- **Fixed coordinates.** The game region is saved in the level, so adding a car later doesn't shift anything. By default it's the whole terrain. Edit `origin` and `size` under `game` in the level to cut out a smaller map.
- **The HUD shows the cursor in game coordinates**, so you can read off spawn and patrol points to type into the base file.

**To play it** (commandos takes the mission as its argument):

```
cd ../commandos
odin run . -- ../sandtable/levels/krakow.mission.json
```

**How it tested:**
- **Unit tests:** `odin test scene`, 13 pass (6 new). They cover:
  - Merged rectangles cover random masks exactly.
  - Turned footprints have the right area and stay within the car, and quarter turns are exact.
  - The captured building appears in the right place with the right height, at scale 1 and at Krakow's 0.005.
  - The merge with a base mission keeps the gameplay, other keys and integers.
  - Saving the region in the level round-trips.
- **Against the game itself:** `odin run tools/commandos_check -collection:cmd=../commandos -collection:st=.` runs 15 checks, all passing. It exports a town with a building and a car turned 30°, then uses commandos' own code to:
  - load the mission with `mission.load` and bake it
  - check that the building, the car's centre and its nose block, and the street beside the car is open
  - find a route with the game's A* from spawn to extraction, around the building, 63 m against 49 m in a straight line
- `odin test editor` (13) and `odin test terrain` (9) still pass, and `odin check .` is clean.

**Things to know:**
- Trees count as structures too, so a tree canopy becomes a block. A tree-lined street may need a hand-drawn region, or a later filter.
- Pathfinding in the game scans the whole grid, so a region much over 200 × 200 m makes guards slow to replan. The export warns you.
- The game draws every building 4 m tall. The export writes the real `height`, but the game doesn't use it yet.
- The first export records the region in the level; save the level (`ctrl+S`) to keep it.
