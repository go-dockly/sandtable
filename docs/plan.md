# sandtable: the original plan

This is the plan sandtable was built from, kept as it was written before Block 1. Where things stand now is in the [README](../README.md#status): Blocks 1, 2, 3 and 5 are done, the export, undo and redo from Block 6 are done, and Block 4 is postponed.

The hard part of a viewer: loading & rendering a 3D Gaussian Splatting scene is in. The next step isn't to turn it into Blender, but to follow a focused mission:

> **A terrain-aware level editor for building Commandos-style environments by placing conventional 3D assets into reconstructed real-world scenes.**

`.spz` becomes the terrain/world. `.glb` become editable objects placed on top of it. Eventually we export a scene that our game engine consumes.

The fact that we already have `pixlsplat` doing something similar is a major advantage. We should reuse the concepts & lessons rather than invent another placement system.

## **1. What sandtable should become**

Make sandtable a **small, purpose-built 3D scene editor**, with the existing rendering pipeline retained as its core.

| Component        | Responsibility                              |
| ---------------- | ------------------------------------------- |
| Terrain          | Render `.spz` / `.ply` 3DGS                 |
| Asset browser    | Browse local GLB models                     |
| Placement        | Position, rotate, scale objects             |
| Terrain snapping | Place objects onto the reconstructed ground |
| Selection        | Select objects in viewport                  |
| Transform gizmos | Move, rotate, scale                         |
| Scene graph      | List placed objects                         |
| Persistence      | Save/load editable level files              |
| Export           | Produce game-ready scene descriptions       |

The editor must distinguish between two types of geometry:

- **Terrain** — the captured 3DGS world, visually rendered & not normally editable.
- **Objects** — GLB assets with real transforms, which we control & can later export, animate, collide with, or replace.

This is an important architectural decision: we don't modify the splat cloud to insert a vehicle. We create a scene containing the terrain plus a collection of independent GLB objects.

## **2. The first milestone: put the Volkswagen on Krakow**

First deliverable deliberately small:

**MVP: Terrain + one GLB + mouse placement**

- Load `krakow.spz`
- Load `assets/models/car/volkswagen_typ-82.glb`
- Show the car as an independent 3D model
- Move the mouse over the terrain
- Project the cursor to the ground
- Snap the car to that position
- Rotate with a keyboard shortcut
- Save placement
- Reload the saved scene

No complex gizmos, undo framework, materials editor, asset pipeline, or dozens of UI panels yet.

### **The interaction should feel like**

1. Start sandtable with the Krakow splat.
2. Press `O` or use a menu to load an object.
3. Select the Volkswagen.
4. Move the mouse across the terrain.
5. The vehicle follows the cursor & rests on the ground.
6. Left-click commits the placement.
7. `R` rotates the vehicle.
8. Click an existing vehicle to select it again.
9. Press `Delete` to remove the selected instance.
10. Save the level.

This one workflow proves that sandtable has become a level editor instead of simply a viewer.

## **3. The architecture: don't contaminate the splat renderer**

I'd keep the existing `splat.odin`, camera, palette & post-processing pipeline largely intact. The repository is already explicitly built around the Commandos aesthetic, orthographic/isometric viewing & the `pixlsplat` rendering approach.

**Editor / Application**

Input · UI · Selection · Tools · Undo later

**World**

Splat terrain + camera + ground sampling

**Objects**

GLB instances + transforms + selection

**Rendering**

Existing Gaussian renderer + conventional 3D models + pixel-art post processing

### **Suggested folder structure**

Keep existing files & start introducing editor modules as the functionality grows.

```
sandtable/
├── main.odin
├── cameras.odin
├── splat.odin
├── palette.odin
├── post.odin
├── targets.odin
│
├── editor/
│   ├── editor.odin       # editor state / lifecycle
│   ├── input.odin       # mouse & keyboard
│   ├── selection.odin   # selected entity
│   ├── placement.odin   # preview / commit / snapping
│   └── transform.odin   # position / rotation / scale
│
├── scene/
│   ├── scene.odin       # level data
│   ├── object.odin      # entity instances
│   ├── serialization.odin
│   └── assets.odin     # asset references & model cache
│
├── terrain/
│   ├── terrain.odin    # terrain representation
│   ├── picking.odin    # viewport ray / terrain intersection
│   └── surface.odin    # height & normal sampling
│
├── gizmos/
│   └── gizmos.odin    # later
│
└── ui/
    ├── toolbar.odin
    ├── hierarchy.odin
    └── inspector.odin
```

Don't create all these files immediately. The first milestone might only need `scene`, `object`, `placement` & a few additions to `main`.

## **4. The critical problem: how do we know where the ground is?**

This is probably the most important technical decision.

A 3D Gaussian Splat is a visual representation, not automatically a collision surface. The splat renderer can draw a road, grass, a car park or a building, but that doesn't necessarily mean it can tell us the exact surface height at a given mouse coordinate.

We should therefore separate **visual terrain** from **placement terrain**.

### **A — Ground plane**

Initially, use a simple ground plane or configurable ground elevation.

- Mouse ray intersects a plane.
- The intersection becomes the car's X/Z position.
- Y is fixed to the configured ground elevation plus the car's placement offset.
- User can adjust elevation manually.

This lets us test model loading, picking, transforms, camera behavior & persistence immediately.

It will not correctly follow the height of sloping roads.

### **B — Terrain heightmap (implemented, Block 5)**

Create a terrain sampling representation from the reconstruction.

Build a terrain proxy that can be sampled:

```
krakow.spz
     │
     ▼
 terrain extraction / preprocessing
     │
     ▼
 heightmap or triangulated terrain mesh
     │
     ▼
 sample_height(x, z)
 sample_normal(x, z)
```

The editor can then ask:

```
height, normal := terrain.sample_surface(world_x, world_z)
```

The placement system uses this to position & orient the vehicle.

For our use case, I'd start with a heightmap because it's simple, fast, compact & easy to query.

One caveat: a heightmap represents one surface per X/Z coordinate. It won't correctly represent vertical walls, overhangs, tunnels, bridges or multiple surfaces stacked above one another. That's acceptable for initial ground placement.

### **C — Surface-aware placement (later)**

Eventually we can use a more sophisticated surface representation:

- Spatial acceleration structure over reconstructed points.
- Ground classification / filtering.
- Ray-to-surface intersection.
- Nearest-surface query.
- Local surface normal estimation.

This would be much more robust when placing props against uneven terrain, embankments, building edges & other complex geometry.

**I'd not build this now.** it's a separate terrain-processing problem & shouldn't block our first editor.

## **5. Placement mechanics**

This should be implemented as a small state machine, not a collection of ad hoc mouse checks.

### **Object transforms**

Every placed object should have the same basic transform:

```
Transform :: struct {
    position: rl.Vector3,
    rotation: rl.Vector3, // Euler for MVP
    scale: rl.Vector3,
}
```

Each model instance references a shared model asset, rather than loading a separate GLB for every car.

```
Scene_Object :: struct {
    id: u64,
    asset_id: string,
    transform: Transform,
}
```

For the Volkswagen, the initial values could be:

```
position = mouse terrain position
rotation = (0, 0, 0)
scale    = (1, 1, 1)
```

The transform should ultimately use a proper matrix or quaternion for orientation, but Euler angles are sufficient for our initial upright ground objects.

### **Controls**

Initial controls are very simple:

| Input       | Action                   |
| ----------- | ------------------------ |
| Left-click  | Place / select           |
| Mouse move  | Move placement preview   |
| `R`         | Rotate 90°               |
| `Shift + R` | Rotate −90°              |
| `W`         | Move selected object     |
| `Delete`    | Delete selected          |
| `Escape`    | Cancel current operation |
| `Ctrl + S`  | Save level               |
| Mouse wheel | Zoom camera              |

Later, we can add transform gizmos & axis constraints.

## **6. Level format — keep independent of renderer**

Don't bake placed assets into `krakow.spz` & don't rewrite the splat.

Instead, create a lightweight scene file that references both the terrain & the GLB assets.

For example, as we do in `https://github.com/go-dockly/commandos/blob/main/mission/eagle/mission.json`:

```
{
  "id": "mission_01_krakow",
  "title": "Operation Eagle's Nest",
  "version": 1,
  "terrain": "../krakow.spz",
  "coordinateSpace": { "width": 100, "height": 100, "origin": "top-left", "plane": "top-down" },
  "playerSpawn": { "x": 12, "y": 82 },
  "extraction": { "x": 84, "y": 88, "radius": 5 },
  "objective": { "id": "documents", "type": "retrieve", "x": 51, "y": 29, "building": "barracks" },
  "objects": [
    {
      "id": 1,
      "asset": "assets/models/car/volkswagen_typ-82.glb",
      "position": [12.5, 0.3, -8.2],
      "rotation": [0, 0, 1.5708],
      "scale": [1, 1, 1]
    }
  ]
  "buildings": [
    { "id": "barracks", "x": 37, "y": 12, "w": 28, "h": 19 },
    { "id": "watchtower", "x": 78, "y": 25, "w": 8, "h": 8 }
  ],
  "walls": [
    { "id": "north-wall", "x": 12, "y": 8, "w": 76, "h": 3 },
    { "id": "west-wall", "x": 12, "y": 8, "w": 3, "h": 53, "openings": [{ "id": "west-breach", "y": 40, "h": 8 }] },
    { "id": "east-wall", "x": 85, "y": 8, "w": 3, "h": 63 },
    { "id": "south-wall-west", "x": 12, "y": 61, "w": 32, "h": 3 },
    { "id": "south-wall-east", "x": 60, "y": 61, "w": 28, "h": 3 }
  ],
  "cover": [
    { "type": "crate", "x": 33, "y": 42, "w": 4, "h": 3 },
    { "type": "crate", "x": 38, "y": 45, "w": 4, "h": 3 },
    { "type": "barrel", "x": 55, "y": 48, "r": 2 },
    { "type": "crate", "x": 66, "y": 39, "w": 4, "h": 3 },
    { "type": "tree", "x": 19, "y": 74, "r": 4 },
    { "type": "tree", "x": 28, "y": 81, "r": 4.5 },
    { "type": "tree", "x": 42, "y": 78, "r": 4 },
    { "type": "tree", "x": 60, "y": 84, "r": 4.5 },
    { "type": "tree", "x": 73, "y": 76, "r": 4 },
    { "type": "tree", "x": 82, "y": 86, "r": 3.5 }
  ],
  "guards": [
    {
      "id": "guard-west",
      "speed": 3.2,
      "pauseDuration": 1.0,
      "patrol": [
        {"x": 25, "y": 22},
        {"x": 25, "y": 48},
        {"x": 43.5, "y": 49.5}
      ]
    },
    {
      "id": "guard-courtyard",
      "speed": 4.0,
      "pauseDuration": 1.5,
      "patrol": [
        {"x": 46, "y": 36},
        {"x": 65, "y": 36},
        {"x": 65, "y": 54},
        {"x": 46, "y": 54}
      ]
    },
    {
      "id": "guard-east",
      "speed": 3.0,
      "pauseDuration": 1.25,
      "patrol": [
        {"x": 74, "y": 32},
        {"x": 82, "y": 48},
        {"x": 74, "y": 55}
      ]
    }
  ],
  "routes": [
    { "id": "west-breach", "risk": "high", "points": [{ "x": 8, "y": 48 }, { "x": 20, "y": 48 }, { "x": 25, "y": 42 }, { "x": 35, "y": 40 }] },
    { "id": "south-perimeter", "risk": "low", "points": [{ "x": 12, "y": 85 }, { "x": 25, "y": 75 }, { "x": 35, "y": 67 }, { "x": 45, "y": 58 }] },
    { "id": "east-service", "risk": "high", "points": [{ "x": 92, "y": 70 }, { "x": 86, "y": 60 }, { "x": 82, "y": 48 }, { "x": 72, "y": 40 }] }
  ]
}
```

This gives us a very important benefit: **the level is editable, versionable, lightweight & portable**. We can use Git to track mission changes without copying or modifying enormous reconstruction files.

Same scene format can be loaded directly by Commandos.

## **7. Rendering the GLB on top of the splat**

We already have two rendering worlds:

- The Gaussian renderer handles the captured environment.
- Raylib's conventional 3D model rendering handles the vehicle.

The editor render loop will evolve toward something like this:

```
begin_drawing()
{
    begin_texture_mode(target)

    clear_background(...)

    begin_mode_3d(camera)

    // Existing environment
    render_gaussian_terrain()

    // Conventional game objects
    for object in scene.objects {
        render_model(object)
    }

    // Editor-only visualization
    render_placement_preview()
    render_selection_outline()
    render_ground_grid()

    end_mode_3d()

    // Pixel-art pipeline stays intact
    render_post_processing()

    end_texture_mode()
}

render_editor_ui()
end_drawing()
```

The important ordering is that both the splats & the models go through the same camera & ideally the same final pixel-art treatment.

This is to avoid the Volkswagen looking like a high-res modern asset pasted into a pixl-art env.

## **8. The actual roadmap**

Split into six small blocks, with a working application at the end of every block.

## **Block 1 — Asset rendering**

First task

Goal: the Volkswagen exists in Krakow

- Load a single GLB.
- Render it through the existing camera.
- Implement a basic transform.
- Add an initial manual ground-plane placement.
- Verify depth & scale against the splat.

**Deliverable:** a Volkswagen visibly standing inside `krakow.spz`.

**Status:** implemented. The object is drawn into the splat target before the splats with the splat pass's own projection, so it is depth tested against the cloud (crisp & soft) and resolved by the same palette / outline pass; its colours join the extracted palette. Placement is keyboard + flags on a single-height ground plane. See `model.odin`, `placement.odin`.

## **Block 2 — Placement interaction**

- Mouse-to-world projection.
- Placement preview.
- Click to commit.
- Rotate.
- Move selected.
- Delete.

**Deliverable:** actually position several vehicles without restarting.

**Status:** implemented. Any number of objects, from any number of loaded GLBs (`--model`, then drop more). The cursor's ray is unprojected through the scene pass's own view & projection and meets the terrain's surface (`terrain.raycast`), so the object lands on what is drawn under the cursor and then stands on its own snap layer. `A` places with a preview that follows the cursor (each click stamps a copy), a click selects (ray against each object's oriented bounds, not through buildings), `W` moves the selection, `Delete` removes it, `Esc` cancels, `,` `.` rotate. Instances have stable ids for Block 3. The logic is in `editor/` without raylib and is unit tested. See `docs/placement.md`.

## **Block 3 — Scene persistence**

- Scene data structures.
- Save JSON.
- Reload JSON.
- Asset references.
- Stable object IDs.

**Deliverable:** reopen yesterday's mission & continue editing.

**Status:** implemented. `ctrl+S` writes `levels/<capture>.json` (or `--level`); `odin run . -- levels/krakow.json` reopens it with its capture, models, objects, ids, world scale and camera. Objects refer to models through an asset table, by id; paths are relative to the level file. Ids are stable across sessions (`nextId`). Overwrites and discards ask twice, closing with unsaved changes autosaves next to the level, missing models are kept. The format is in `scene/` without raylib and is unit tested. See *Levels* above and `docs/scene.md`.

## **Block 4 — Asset browser + inspector**

- Browse `assets/models/`.
- Load & instantiate.
- Hierarchy list.
- Selected object inspector.
- Position, rotation, scale fields.

**Deliverable:** a usable basic editor instead of a developer-only prototype.

## **Block 5 — Terrain snapping**

- Terrain proxy.
- Height sampling.
- Ground alignment.
- Optional normal alignment.
- Manual elevation override.

**Deliverable:** objects naturally sit on Krakow's uneven terrain.

**Status:** implemented ahead of Blocks 2–4. Ground & surface heightmaps are built from the cloud at load; each object snaps to the ground (or the surface, or the old plane) with an offset and optional slope alignment from its footprint. Grey-box view (`Tab`) and an export of the heightmaps as 16-bit PGMs + JSON. `terrain.raycast` does Block 2's mouse picking. See *Terrain* above.

## **Block 6 — Commandos workflow**

- Grid snapping.
- Rotation increments.
- Prop/vehicle categories.
- Duplicate.
- Undo/redo.
- Export to game scene format.
- Game camera preview.

**Deliverable:** construct an actual playable mission layout.

**Status:** export done ahead of the rest. `ctrl+E` writes a commandos `mission.json` with the capture's buildings and the objects' footprints merged into the designer's base mission; checked against commandos' own loader, collision and A* (`tools/commandos_check`). Next: undo/redo. See *Commandos export* above and `docs/game_export.md`.

## **9. What I'd deliberately postpone**

This is where we avoid turning this into an eight-month Cascadeur/Blender-style project.

| Feature                      | Decision                  |
| ---------------------------- | ------------------------- |
| Full 3D modeling             | No                        |
| Mesh editing                 | No                        |
| Animation editor             | No                        |
| Material authoring           | No                        |
| Complex multi-axis gizmos    | Later                     |
| Terrain sculpting            | Later                     |
| Physics sim                  | No                        |
| Collision editor             | Later                     |
| AI-assisted scene generation | Maybe                     |
| Mission scripting            | Separate system           |

Sandtable is a **composition tool**, not a content-creation suite.

## **10. The first task to implement**

I wouldn't start by building the asset browser or UI framework. I'd start with the single most satisfying proof of concept:

### `Block 1 — GLB integration`

1. Load `krakow.spz` as we do now.
2. Load `volkswagen_typ-82.glb`.
3. Render the model using the existing isometric camera (check: https://github.com/algo-boyz/pixlsplat -> toad.glb).
4. Add a hardcoded temporary transform.
5. Add position, rotation & scale controls via keyboard.
6. Verify that the vehicle participates in the existing pixel-art post-process.
7. Confirm the correct model orientation, pivot & scale.

The first test shouldn't even require mouse placement.

Something like:

```
odin run . -o:speed -- \
    ../ospz/models/krakow.spz \
    --model assets/models/car/volkswagen_typ-82.glb
```

We don't need to commit to this CLI syntax yet, but the ability to debug a level with explicit model arguments before building the editor UI is priceless.

Once we see the Volkswagen sitting convincingly in Krakow, we'll know we're on the right track & the next step — making it follow the mouse — is much easier to reason about.

**Start with Block 1 & reuse the model/rendering lessons from pixlsplat rather than changing sandtable's existing rendering pipe.**

I'd treat this as a new layer of functionality, not a rewrite. Within a relatively small first milestone, sandtable can go from a beautiful terrain viewer to the beginning of a genuine Commandos mission editor.

Once placing a Kübelwagen on Krakow works, buildings, crates, soldiers, trees, barriers & the rest of our asset library all become the same problem: **load asset, place instance, save transform.**

That is the architectural breakthrough that makes this project manageable. Let's get to work...
