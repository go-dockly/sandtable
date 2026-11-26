# Gameplay map spec: sandtable × commandos

Nov 26, 2026 · @enigma

## Why

The game plays on a gameplay map: a simplified, hand-edited copy of the capture that is invisible in the game and decides movement and sight. This spec fixes that map's model, its file, how sandtable builds and edits it, and the one package both repos share.

The pillars it serves, for a true successor to Commandos rather than another 3D remake:

1. **The capture is the painting.** Splats go through the pixel-art pass at four fixed isometric views, like Commandos 2.
2. **A layered grid, not a navmesh.** Ground, roofs, upper floors and interiors are layers, joined by stairs, ladders, doors and windows.
3. **Height decides sight.** A guard in a tower sees over a wall, a crouching commando hides behind a car, and someone prone stays unseen at range.
4. **Interiors through doors**, as small maps of their own.
5. **The editor is the game.** sandtable previews paths and vision cones with the game's own code.

Not covered here: characters and their art, mission scripting, or which specialists the team has beyond what links need (see Risks and open questions).

## Two layers: backdrop and gameplay map

The capture is used twice: drawn as the backdrop players see, and simplified into the gameplay map the rules use. The map is never drawn in the game; it only decides where characters can go and what guards can see.

&#91;embedded content: two layers from one capture · picture above, rules below\]

Your edits are re-applied to the automatic map after every terrain rebuild, and the gameplay map (the accent) is the one thing both repos share.

## Coordinates, units, views

One map unit is a metre, and the map frame is fixed per level, so nothing typed into a mission ever shifts.

- **Frame.** The level's game region: an origin (world x, z), a size in metres, and a new **yaw** that turns the map to the capture's street grid, so buildings come out square. World to map: subtract the origin, rotate by -yaw, divide by the world scale.
- **Axes.** Map x right and y down in the top view, height h up, all in metres. Heights are measured from the frame's ground reference (the terrain's lowest ground).
- **Cell.** 0.5 m by default (`cell` per map). A person is about 0.8 m across, and a 200 × 200 m map is 400 × 400 cells a layer.
- **Views.** Four isometric views at azimuth 45° + k × 90°, the 38° tilt fixed. The map never depends on the view; only drawing does.

## The map: layers, cells, heights

A map is a grid of W × H cells with one or more layers stacked on it. Each layer says, cell by cell, whether you can stand there, how high, and on what.

- **Layer 0 is the ground.** It covers every open cell of the map.
- **Higher layers** hold roofs, upper floors, platforms and towers. They are sparse: only the cells they cover are stored.
- **Interiors** are maps of their own (see Interiors).
- **Movement.** Two neighbouring cells of a layer join if both are walkable and their heights differ by at most 0.4 m (one step). A bigger difference is a ledge: only a link (see Links) gets you across.

Per cell, per layer:

| Field | Type | Holds |
| --- | --- | --- |
| `height` | i16, centimetres | standing height; a sentinel for not walkable |
| `surface` | u8 enum | ground, road, grass, gravel, roof, floor, water, deep (impassable) |
| `cover` | u8 enum | none, low (hides crouching), high (hides standing) |
| `flags` | u8 bits | crawl only, no guards, indoors |

The surface also feeds the sound system: gravel is louder than grass, as footsteps are now.

## Links

A link joins two (map, layer, cell) places that walking alone can't: it is how you get onto a roof, through a door or into an interior. Pathfinding runs over cells plus links, one A\* over (layer, x, y) nodes.

Each link has a kind, its two ends, a cost in seconds, a noise level, and who may use it (everyone, or named abilities such as climbing).

| Kind | Direction | Use |
| --- | --- | --- |
| stairs | both | walk, normal speed |
| ladder | both | climb, slow, hands busy |
| door | both | open, closed or locked; may lead into an interior |
| window | both | climb through, slow, loud |
| drop | down only | jump down at most 3 m |
| climb | both | an ability only: pipes, ropes, walls |

Doors carry state the game changes (open, locked), so the map stores the door and its starting state; the game keeps the current one.

## Occluders and line of sight

Sight is a 3D ray from the guard's eye to points on the target, checked against solid spans in each cell. That is what lets a tower see over a wall and a car hide a crouching man.

- **Spans.** Each cell holds up to two solid spans, bottom and top in metres. A building is one span from the ground to its roof. A wall is one span to its height. A tree canopy is a span from about 3 m to its top, so you can see under it but not through it. A car is a span to about 1.5 m.
- **The ray.** It steps cell by cell (a grid walk) and is blocked where its height at that cell falls inside a span.
- **Heights by stance.**

| Stance | Eye | Body points checked |
| --- | --- | --- |
| standing | 1.7 m | 0.2, 1.0, 1.6 m |
| crouching | 1.0 m | 0.2, 0.8 m |
| prone | 0.3 m | 0.2 m |

Vision cones (range, angle, a near zone that sees prone targets and a far zone that doesn't, as in the original) are game rules, not map data. They call the map's one `can_see`.

GLB props add their own spans and cover from their footprint and height, so a placed car blocks sight without any hand editing.

## Interiors

An interior is a small map of its own, with its own grid, layers and links, stored in the same file and entered through a door link. That is the classic Commandos model: you step through a door into a separate room view.

- **Tied to a building.** Each interior names the building it belongs to, so its doors line up with that building's walls.
- **Doors on both sides.** A door link has one end on the street map and one inside the interior.
- **What v1 holds.** The hook and the format. Drawing interiors (GLB interior kits or painted panels) and whether time runs on outside are open questions below.

## Automatic map from the capture

sandtable builds a first map from the terrain proxy it already makes, in a fixed order, so the same capture always gives the same map. This is the starting point the edits work on.

1. **Terrain proxy (exists).** Ground and surface heights and a class per 0.5 m cell.
2. **Align.** Find the main direction of building edges and store it as the frame's yaw.
3. **Tell trees from buildings.** Under a canopy the capture still shows ground, while under a roof it shows nothing. Canopies are rough rather than flat, and green. Each structure becomes building, tree, wall or other.
4. **Buildings.** Each one becomes a footprint at the aligned angle, squared up, with a fitted roof (flat or two-sided) at one clean height. Roofs are not walkable until an edit says so.
5. **Ground.** The bare-ground heights, smoothed, become layer 0. Slopes over 35° are not walkable. Roads and grass are told apart by colour, roughly.
6. **Trees.** A trunk circle of about 0.4 m that blocks movement, and a canopy span that blocks sight.
7. **Clean up.** Specks under 2 m² go, holes under 1 m² are filled, and one-cell gaps are closed.
8. **Placed objects.** Each GLB adds spans and cover from its footprint and height.

Every automatic feature (building, tree, wall) gets an id, so edits can point at it.

## Edits stored in the level

Manual work is a list of edits in the level file, applied in order on top of the automatic map every time it is rebuilt. Rebuilding the terrain never loses your work, and each edit is one line in git.

An edit has an id, a kind, its settings, and a target: a region (a polygon in map metres) or an automatic feature's id. If a rebuild loses the feature an edit points at, the edit is flagged in the editor, never dropped.

| Edit | Settings | Does |
| --- | --- | --- |
| flatten | region, height or "fit" | one clean height over the region |
| surface | region, kind | sets road, grass, gravel, water and so on |
| block / unblock | region, layer | closes or opens cells |
| building | feature, footprint, height, roof, walkable roof | fixes what detection got wrong; makes a roof a layer |
| volume | box, height, cover | adds a wall, crate stack or other solid by hand |
| remove | feature | drops a wrong building or tree |
| tree | point, trunk, canopy | adds or fixes a tree |
| link | kind, two ends, abilities | stairs, ladder, door, window, drop, climb |
| interior | building, its map, doors | ties an interior to a building |

In sandtable, edits are made with grid tools on the map view and undone like objects are now.

## File format

The level stays the source of truth; the map files are built from it, and the mission points at the map.

| File | Written by | Holds |
| --- | --- | --- |
| `levels/krakow.json` | sandtable, saved | capture, models, objects, the map edits, the frame |
| `krakow.map.json` | sandtable, exported | format and version, frame, cell size, layer names, buildings and trees (ids, footprints, heights), links, interiors, props |
| `krakow.map.bin` | sandtable, exported | the grids, little-endian: per layer heights, surface, cover, flags; the spans |
| `krakow.mission.json` | the designer | `"map": "krakow.map.json"`, then spawn, guards, objectives, in map metres |

The grids go in a binary file because a 400 × 400 map with three layers is half a million cells; JSON would be large and slow. Everything a person reads or diffs stays JSON. A reader refuses a newer version, as levels do now.

This replaces today's export, which writes 2D rectangles into the mission. That export stays until the first slice below works.

## Shared package: gamemap

One Odin package, `gamemap`, holds the format, movement and sight. The game runs on it and sandtable previews with it, so what you see in the editor is what guards will do.

- **Where it lives.** My pick is inside commandos (`commandos/gamemap`), since the game owns its rules. sandtable imports it the way CI already imports commandos (`-collection:cmd=../commandos`). A repo of its own is the alternative; see open questions.
- **Rules.** No raylib, no clock, no randomness: the same map and inputs give the same answer on every machine. Tested in its own package, run by both repos' CI.
- **Not in it.** Building the map from a capture needs the terrain proxy, so that stays in sandtable. gamemap never imports sandtable.

The API, roughly:

```odin
Map    :: struct { frame: Frame, cell: f32, w, h: int, layers: []Layer, spans: []Span, links: []Link, interiors: []Map, ... }
Node   :: struct { layer: u8, x, y: i32 }
Agent  :: struct { radius: f32, abilities: bit_set[Ability] }

load        :: proc(json_path: string) -> (Map, Error)      // reads .map.json + .map.bin
save        :: proc(m: Map, json_path: string) -> Error
node_at     :: proc(m: ^Map, p: [3]f32) -> (Node, bool)     // a world point in map metres to the cell under it
height      :: proc(m: ^Map, n: Node) -> (f32, bool)
find_path   :: proc(m: ^Map, from, to: Node, agent: Agent) -> Path   // cells + links, A* with a heap
can_see     :: proc(m: ^Map, eye, target: [3]f32) -> bool              // ray against spans
visible     :: proc(m: ^Map, eye: [3]f32, facing, fov, range: f32, out: []bool)  // per cell, for drawing a cone
apply_edits :: proc(m: ^Map, edits: []Edit) -> []Edit_Problem
```

## Work split and the first slice

The first slice is one Krakow street end to end: an automatic map with two kinds of edit, previewed in sandtable and played in commandos. Everything past that waits until the slice works.

| Repo | Owns |
| --- | --- |
| commandos | gamemap (format, layered A\*, sight); missions in map metres; actors with heights and stances; the splat backdrop, using sandtable's renderer; interiors later |
| sandtable | building the automatic map; edits and their grid tools; the map view under `Tab`; path and vision-cone previews through gamemap; exporting the map files |

The slice:

- [ ] gamemap v0 in commandos: format, load and save, layered A\*, `can_see`, with tests
- [ ] sandtable builds ground, square buildings with flat roofs and trees from the Krakow terrain, with the aligned frame
- [ ] Edits: flatten, building height and walkable roof, a ladder link
- [ ] `Tab` shows the layers; one guard's vision cone is drawn with `gamemap.visible`
- [ ] commandos loads the Krakow map: a guard patrols the street, sees over a low wall, and the player climbs a ladder onto a roof
- [ ] Speed test: the splat backdrop plus 10 characters at 60 fps on the hardware you target

The current 2D export stays until the last two boxes are ticked.

## Risks and open questions

The biggest risk is the speed of drawing splats in the game; the speed test in the slice settles it before anything depends on it.

| Risk | Fallback |
| --- | --- |
| Splats plus characters too slow in the game | Bake each of the four views into a pixel-art image plus a depth image, the way pre-rendered games did |
| Automatic feature ids change when the terrain is rebuilt, so edits lose their target | Match features by position and kind; flag an edit that matches nothing, never drop it |
| Trees and buildings told apart wrongly | Edits fix them (remove, tree, building); the map view makes mistakes easy to spot |
| Complex roofs don't fit flat or two-sided | Fit what we can; the building edit sets the rest |
| Layered A\* too slow on big maps | Sparse upper layers and a heap; a hierarchical pass only if measured |

For us to decide:

1. Does gamemap live inside commandos or in a repo of its own?
2. Is 0.5 m the right cell, or is 1 m enough for the feel you want?
3. Interiors: drawn with GLB kits or painted panels? Does time run on outside?
4. Which specialists use which links (climb, swim, window)? This needs the team list.
5. Is four fixed views the camera, or do you want a free turn as sandtable has now?
