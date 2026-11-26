# sandtable

[![tests](https://github.com/go-dockly/sandtable/actions/workflows/tests.yml/badge.svg)](https://github.com/go-dockly/sandtable/actions/workflows/tests.yml)

A level editor for [Commandos](https://github.com/algo-boyz/commandos)-style missions, built on real places. It takes a 3D Gaussian Splatting capture (`.spz` / `.ply`, loaded with [ospz](https://github.com/algo-boyz/ospz)) as the world and lets you place ordinary GLB models on it: cars, crates, props. You see everything through the game's own look, the pixel-art pipeline from [pixlsplat](https://github.com/algo-boyz/pixlsplat): a low-resolution supersampled target, palette quantisation, ink outline and a fixed isometric camera. Levels save as small JSON files and export to missions the game plays.

The capture is the terrain and is never edited; the GLBs are the editable objects. sandtable composes levels; it does not model, sculpt or animate.

## The workflow

1. **Open a capture.** `odin run . -o:speed -- ../models/terrain/krakow.spz --world-scale 0.005 --model ../models/car/volkswagen_82.glb --align`. sandtable builds a terrain proxy from the cloud (ground and roof heightmaps) in under a second.
2. **Place objects.** `A`, then click along the street: each click stamps a car that stands on the ground and tilts to the slope. Click a car to select it, `W` to move it, `,` `.` to turn it, `Delete` to remove it, `ctrl+Z` to undo.
3. **Save.** `ctrl+S` writes `levels/krakow.json`. Reopen it tomorrow with `odin run . -o:speed -- levels/krakow.json`.
4. **Write the gameplay** (spawn, guards, objective) in `levels/krakow.mission.base.json`, by hand; the HUD shows the cursor in game coordinates.
5. **Export.** `ctrl+E` writes `levels/krakow.mission.json`: your gameplay, plus the capture's buildings and the cars as collision and cover.
6. **Play it.** `cd ../commandos && odin run . -- ../sandtable/levels/krakow.mission.json`.

## Setup

Sibling checkouts:

```
dev/
  commandos/    the game (only for playing, and for the export check)
  ospz/         .spz / .ply loading
  ozstd/        zstd, used by ospz
  sandtable/
```

```
cd sandtable
odin run . -- ../ospz/models/tree.ply
```

Use `-o:speed` for big captures: sorting millions of splats is slow in a debug build.

| Flag | Does |
|------|------|
| `cloud.spz` / `cloud.ply` | the capture (or drop one on the window) |
| `level.json` | open a level: its capture, models, objects, world scale and camera |
| `--level file.json` | the level to save to (`ctrl+S`), opened if it exists. Default: `levels/<capture>.json` |
| `--model file.glb` | a model to place (`.glb` / `.gltf`); more can be dropped on the window |
| `--world-scale u` | world units per metre of the capture, default 1; Krakow is ~0.005. GLBs are in metres and multiplied by this |
| `--pos x,y,z` | where the first object's pivot (bottom centre) stands; `y` sets the ground plane |
| `--yaw deg` | its rotation around the vertical axis |
| `--scale s` | its scale on top of the world scale, default 1 = real size |
| `--snap m` | where objects get their height: `ground` (terrain, default), `surface` (terrain with roofs), `plane` |
| `--ground y` | the plane's height; default the 5th percentile of the cloud's heights |
| `--offset y` | height above the terrain, world units |
| `--align` | tilt objects to the slope under their footprint |
| `--max-tilt deg` | steepest tilt, default 20 |
| `--cell m` | terrain cell in metres; default 0.5, coarser for sparse clouds |
| `--terrain-export prefix` | write the heightmaps after each terrain build (see *Terrain*) |

With a level, a capture given as well wins over the level's, and `--model` is what `A` places in an empty level. `F` prints the selected object as these flags (`shift+F`: every object).

## Keys

Objects, with the mouse:

| Input | Does |
|-------|------|
| `A` | place: a preview follows the cursor, each left-click puts a copy down. Copies the selected object, or the last one placed |
| left-click | select the object under the cursor, or deselect |
| `W` | move the selected object with the mouse; click to put it down |
| `Delete` / `Backspace` | delete the selected object |
| `Esc` | stop placing / put a moved object back / deselect (it no longer quits: close the window) |
| `O` | next loaded model for the selected object or the preview |
| drop a `.glb` | load it and start placing it |

A left press only clicks if the cursor stays within 5 px; a longer drag turns the camera. Outlines: yellow selected, cyan the preview or the object being moved, white under the cursor.

Editing the selected object (or the preview while placing):

| Key | Does |
|-----|------|
| `I` `J` `K` `L` | nudge along the ground, relative to the view (shift: faster). Not while placing or moving: the mouse moves it then |
| `,` `.` | rotate 15° (shift: 90°) |
| `Y` `H` | raise / lower above the terrain (on the plane: move the plane) |
| `Z` | snap: ground / surface (roofs) / plane |
| `U` | tilt to the slope / upright |
| `N` `M` | scale (shift: faster) |
| `T` | back to the command line's placement, keeping the model |
| `F` | print as command-line flags (`shift+F`: every object) |

Level (`cmd` instead of `ctrl` on a Mac):

| Key | Does |
|-----|------|
| `ctrl+Z` | undo: placing, moving, deleting and every key edit, up to 200 steps |
| `ctrl+shift+Z`, `ctrl+Y` | redo |
| `ctrl+S` | save |
| `ctrl+R` | reload from disk, dropping unsaved changes (asks with a second press) |
| `ctrl+E` | export the Commandos mission |
| drop a `.json` | open that level |
| `ctrl` + `N` `M` | world scale: calibrate the capture against a known-size object (a car is ~4 m), then `shift+Z` |
| `B` | overlay: every object's bounds; the selected one's ground grid in whole metres, pivot and +Z |
| `V` | hide / show the objects |

Undo leaves alone what isn't an edit of the level: the world scale, the camera, and ids, so an undone object's id is never handed out again.

Terrain:

| Key | Does |
|-----|------|
| `Tab` | view: splats / grey-box / both |
| `shift+Z` | rebuild the terrain, e.g. after calibrating the world scale |

Look:

| Key | Does |
|-----|------|
| `C` | game camera (isometric, orthographic) / free orbit camera |
| `Q` `X` `E` `S` `D` | palette quantise, hard splats, outline, supersample 1x/2x, dither 0 / 0.5 / 1 |
| `-` `+` | art pixel size |
| `P` | palette: extracted from the cloud / fixed Commandos colour script |
| `G` | Commandos colour grade 1 / 0.5 / 0 (Commandos palette only) |
| `[` `]` | hard mode: drop splats below this opacity |
| `R` | reframe |

Game camera: the 38° Commandos tilt stays fixed. Left-drag or a sideways two-finger swipe turns it, `←` `→` by 90°; shift + left-drag (or right / middle drag) pans; scroll zooms; `R` returns to 45°. Free camera: left-drag orbits, scroll zooms.

The HUD shows the object's size in metres, positions to ~1 cm at the current world scale, how many art pixels the object spans in the game camera (sprite readability), whether the level is saved, and the cursor in game coordinates.

## Levels

A level is a small JSON file next to the project (default `levels/<capture>.json`) that references the capture and the models and lists the objects. It never copies or changes the capture or the GLBs, so it diffs well in git. Paths in it are relative to the level file, with forward slashes. One object per line:

```json
{
  "format": "sandtable-level",
  "version": 1,
  "id": "krakow",
  "title": "krakow",
  "terrain": "../models/terrain/krakow.spz",
  "worldScale": 0.005,
  "terrainCell": 0,
  "maxTilt": 20,
  "nextId": 4,
  "view": { "target": [0.1, 0.02, -0.3], "azimuth": 45, "viewHeight": 0.8 },
  "assets": [
    { "id": "volkswagen_82", "path": "../models/car/volkswagen_82.glb" }
  ],
  "objects": [
    { "id": 1, "asset": "volkswagen_82", "position": [0.1, 0.0123, 0.2], "rotation": [0, 1.5707964, 0], "scale": [1, 1, 1], "up": [0.05, 0.99875, 0], "snap": "ground", "offset": 0, "align": true, "ground": 0.0123 }
  ]
}
```

| Field | Holds |
|-------|-------|
| `terrain` | the capture |
| `worldScale`, `terrainCell` | world units per metre; terrain cell in metres (0 automatic): the terrain is rebuilt as the level was made |
| `nextId` | the next object id. Ids are never reused, also across sessions |
| `view` | the game camera, so a level reopens where you left it |
| `assets` | the models, by id; objects refer to these ids, so one path change re-points every object of that model |
| `position` | the pivot (bottom centre), world units |
| `rotation` | Euler XYZ, radians |
| `scale` | 1 = the GLB's real size |
| `up` | the object's tilted +Y, so a reader without the terrain gets the same pose |
| `snap`, `offset`, `align`, `ground` | how the editor stands it on the terrain (see *Terrain*) |

Safe by default:
- A level that exists but was not opened is only overwritten on a second `ctrl+S`.
- Unsaved changes are only dropped on a second `ctrl+R`.
- Closing the window with unsaved changes writes `<level>.autosave.json` next to the level.
- Saving goes through a temporary file, so a crash leaves the old level whole.
- A model that does not load stays in the level (its objects are kept, just not drawn), and dropping that model later brings them back.
- Duplicate or missing ids get fresh ones, and unknown fields are ignored, with a warning for each fix.

## Commandos export

`ctrl+E` (`cmd+E`) writes a mission that [commandos](https://github.com/algo-boyz/commandos) loads as it is (`mission/mission.odin`), next to the level by default: `levels/krakow.mission.json`.

The game plays in 2D, top-down, one unit a metre (a guard is 0.8 across). The export maps one metre of the capture to one game unit: game x, y = world x, z minus the region's corner, divided by the world scale. The axes are the same, so nothing is mirrored. The region (corner and size) is kept in the level's `game` section, so adding a car later doesn't move every coordinate a designer has typed. It defaults to the whole terrain; edit `origin` and `size` in the level to cut out a smaller map. The HUD shows the cursor in game units, for typing spawns and patrols.

| Mission field | From |
|---------------|------|
| `buildings` | the base mission's, then the capture's structures (terrain cells 2 m and more above the ground) on the game's 1 m grid, merged into rectangles. `height` (metres) is extra |
| `cover` | the base mission's, then each object's footprint as `crate` rectangles. The game's solids are axis-aligned, so a turned car is traced on a 25 cm grid; crates block movement and sight |
| `props` | every object, for drawing its GLB in the game later: asset, x, y, elevation (m), yaw, scale, tilt, size. The game ignores it for now |
| `coordinateSpace` | the region |
| `playerSpawn`, `extraction`, `objective`, `walls`, `guards`, anything else | the designer's `levels/krakow.mission.base.json`, untouched. Without one: no guards, and a spawn on open ground near the middle |
| `sandtable` | the level it came from, the region's corner, world scale, ground height: how to map back |

Gameplay is never written by sandtable: keep it in the base file and re-export. The generated mission says so in its `sandtable.note`.

To play it (commandos takes the mission as its argument):

```
cd ../commandos
odin run . -- ../sandtable/levels/krakow.mission.json
```

Limits: trees are structures too, so their canopies become blocks, and a region much over 200 × 200 m makes the game's grid A* slow.

## Terrain

At load the cloud is turned into two heightmaps over an x/z grid (`terrain/terrain.odin`; ~0.25 s for 0.5 M splats, ~0.6 s for 3 M):

- **surface** (DSM): the top of whatever is there, roofs and canopies included. A high quantile of the splat heights per cell, single-cell spikes (sky blobs) removed.
- **ground** (DTM): bare ground. Per cell, the lowest height at least 3 splats agree on, so a street cell beside a wall still finds the street and a stray splat under it does not count. A progressive morphological filter (Zhang et al. 2003) then removes everything narrower than 40 m (buildings, trees, cars), and the holes are filled smoothly from the ground around them.

Each cell is classed *empty* (no splats), *ground*, *object* (0.5–2 m above the ground: cars, hedges) or *structure* (2 m and more: buildings, walls, trees). Splats below 0.2 opacity are ignored. The defaults are in metres and go through the world scale, so set `--world-scale` (or calibrate with ctrl+N/M, then shift+Z) before trusting the terrain of a non-metric capture. Cells are 0.5 m; a sparse cloud gets coarser cells until a typical cell holds 8 splats.

The object stands on the plane fitted through 5×5 terrain samples under its footprint (turned with its yaw): the plane's height at the pivot plus the offset, and with `U` its normal, clamped to `--max-tilt`.

`Tab` shows the terrain as a grey-box drawn like a GLB object (lit, depth tested against the splats, through the pixel-art pass): the ground as a smooth surface, structures as blocks. It is the quickest check of what placement sees, and the start of a grey-box of the level.

`--terrain-export out/krakow` writes:

| File | Holds |
|------|-------|
| `krakow.ground.pgm` | ground, 16 bit, 0..65535 = `heightMin`..`heightMax` |
| `krakow.surface.pgm` | surface, same scale |
| `krakow.class.pgm` | 8 bit: 0 empty, 85 ground, 170 object, 255 structure |
| `krakow.terrain.json` | origin (world x, z of the corner of cell (0, 0)), cell size, grid size, height range, world scale, build parameters |

Row 0 is the lowest z, column 0 the lowest x; heights are world units (divide by `worldScale` for metres).

Limits: one height per x/z, so walls are steps between cells and bridges, overhangs and interiors are not represented. Flat roofs wider than 40 m count as ground. The ground under a parked car is only as good as the street splats around it.

## Code

The parts that can be tested without a window are packages without raylib; the rest is the app.

| Package | Holds | Tests |
|---------|-------|-------|
| `terrain/` | the terrain proxy: heightmaps from the cloud, height / normal / footprint sampling, ray picking, heightmap export | `odin test terrain` |
| `editor/` | objects with stable ids, the select / place / move state machine, undo / redo, cursor rays, picking, click-or-drag, terrain snapping | `odin test editor` |
| `scene/` | the level file (read, write, repair, asset references, relative paths) and the Commandos export | `odin test scene` |
| `tools/commandos_check/` | an export through commandos' own loader, collision and A* | `odin run tools/commandos_check -collection:cmd=../commandos -collection:st=.` |

| App file | Does | From |
|----------|------|------|
| `main.odin` | window, input, the frame: splats and objects into one target, then the pixel-art pass | pass order from `pixlsplat/src/main.odin` |
| `placement.odin` | loaded models, mouse and keyboard editing, drawing, overlay, command line | |
| `level.odin` | open, save, reload, autosave, missing models, export, level HUD | |
| `terrain_view.odin` | terrain build at load, grey-box, terrain HUD | |
| `model.odin` | GLBs as raylib meshes in the splat pass | pivot, palette & lighting lessons from pixlsplat |
| `splat.odin` | loading, sorting and the splat shader, with ortho projection and a hard mode | `ospz/viewer/main.odin` |
| `cameras.odin` | isometric game camera scaled to the cloud; free orbit | `commandos/camera/isometric.odin`, the ospz viewer |
| `post.odin` | the pixel-art pass | `pixlsplat/src/post.odin`, verbatim |
| `palette.odin` | k-means palette, plus a hand-picked Commandos colour script | `pixlsplat/src/palette.odin` |
| `targets.odin` | render targets; the art grid rounds up and is drawn at an exact integer scale | `pixlsplat/src/view.odin` |

## Tests

```
odin test terrain     # 9: a synthetic street with a slope, a building with no ground under it, a tree, a car, haze, sky blobs, at Krakow's scale too
odin test editor      # 16: rays through both cameras, picking, cursor on street and roof, modes, ids, undo / redo, settling
odin test scene       # 13: level round trip, repairs, paths, the export's buildings, footprints and merge
odin run tools/commandos_check -collection:cmd=../commandos -collection:st=.   # 15 checks in the game's own code
```

[CI](.github/workflows/tests.yml) runs all four on every pull request and on `main`, with the latest Odin release and commandos' `main`. The app itself also needs ospz, ozstd and raylib, and isn't built there.

## Status

| Block | | State |
|-------|-|-------|
| 1 | GLB rendering: a Volkswagen in Krakow, through the same camera, depth and pixel-art pass as the splats | done |
| 2 | Placement: mouse picking, preview, click to place, select, move, rotate, delete, several objects | done ([docs](docs/placement.md)) |
| 3 | Levels: save, reopen, asset references, stable ids | done ([docs](docs/scene.md)) |
| 4 | Asset browser and inspector | postponed: the keyboard does it for now |
| 5 | Terrain: heightmaps, snapping, slope alignment, offset | done, before 2–4 ([docs](docs/height_map.md)) |
| 6 | Commandos workflow | export ([docs](docs/game_export.md)) and undo / redo done; grid snapping, categories, duplicate and game camera preview to come |

Known limits:
- **One height per spot.** The terrain proxy has one height per x/z, so bridges, overhangs and interiors are missing, and flat roofs wider than 40 m count as ground.
- **Ground on slopes.** On a 10% slope the ground reads about 5 cm low.
- **Trees in the export.** Tree canopies become buildings in the export, which can block tree-lined streets.
- **Map size.** A game region much over 200 × 200 m makes the game's pathfinding slow.
- **Building heights.** The game draws every building 4 m tall. The export writes the real height, but the game doesn't use it yet.

The plan sandtable was built from: [docs/plan.md](docs/plan.md).
