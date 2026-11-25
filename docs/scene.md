# Saving and reopening levels

**What it does:**
- **`ctrl+S`** (`cmd+S` on a Mac) saves the level to `levels/<capture>.json`, or to the file given with `--level`.
- **Reopen it** with `odin run . -o:speed -- levels/krakow.json`. That brings back:
  - the capture
  - the models
  - every object, with its id
  - the world scale and terrain cell, so the terrain is rebuilt as it was
  - the camera, so you start where you left off
- **`ctrl+R`** reloads the level from disk. Dropping a `.json` file on the window opens it.
- **Small, git-friendly files.** A level only references the capture and the GLBs, so it's small and fits in git. Each object sits on one line, so moving one car changes one line.
- **Models by id.** Objects refer to models through an `assets` list, so changing one path re-points every object that uses it.
- **Relative paths.** Paths are relative to the level file and use forward slashes, so the project folder can move or change machine.
- **Stable ids.** `nextId` is saved, so ids are never reused, even across sessions.

**Safety:**
- If a level exists but you didn't open it (say yesterday's `levels/krakow.json` when you start from `krakow.spz`), the app tells you at startup. `ctrl+S` only overwrites it on a second press.
- `ctrl+R` with unsaved changes asks for a second press too. The HUD shows saved or unsaved.
- Closing the window with unsaved changes writes `levels/krakow.autosave.json` next to the level. It never overwrites the level, and git ignores it.
- Saving writes a temporary file and then renames it, so a crash can't leave a half-written level.
- If a model fails to load, its objects stay in the level and are saved as they were, just not drawn. Dropping that `.glb` later brings them back.
- A file that isn't a level, has broken JSON or comes from a newer version stops the app at startup, so nothing gets saved over it.
- Duplicate or missing ids get fresh ones, and unknown fields are ignored. Each fix is printed as a warning.

**How it tested:**
- **Unit tests:** `odin test scene`, 7 pass.
  - Three cars of two models, one deleted: save, load into a fresh editor, and every object comes back exactly. Saving again gives the same text byte for byte, and the next id carries on.
  - Repairs: duplicate and missing ids, unknown snap modes, unknown assets, extra fields.
  - Rejecting non-levels, broken JSON and newer versions.
  - Asset ids from file names, relative paths both ways, and a real write and read on disk.
- `odin test editor` (13) and `odin test terrain` (9) still pass. `odin check .` is clean with `-vet -strict-style`.
- **Not run in a window.** As with Block 2, there was no display or GLB here. Worth trying:
  1. Place a few cars, press `ctrl+S`, and close the window.
  2. Run `odin run . -o:speed -- levels/krakow.json`. The cars and camera should be back.
  3. Move one car and check that the HUD says "unsaved changes".

**Things to know:**
- Positions are in world units, like everything else. Divide by `worldScale` for metres.
- Only models some object uses are written.
- If you pass a capture as well as a level, your capture wins, and the next save records it.
- The camera is saved but isn't counted as a change, so moving it doesn't mark the level unsaved.
- Changing the terrain (world scale or `shift+Z`) moves the objects' heights, which counts as a change.
