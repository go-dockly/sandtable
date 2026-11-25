# Placing objects with the mouse

**What it does:**
- **Several objects, several models.** Start with `--model`, then drop more `.glb` files on the window. Objects of the same model share it, and each one has its own position, rotation, scale and snap settings.
- **The cursor finds the ground.** The mouse ray goes through the same camera the scene is drawn with, then meets the terrain's surface. The object lands on what you see under the cursor, then stands on its own layer: ground, roof or plane.
- **Three modes:**
  - *Select:* click an object to select it, click empty ground to deselect.
  - *Place* (`A`): a preview follows the cursor. Each click puts a copy down, so a row of cars is a row of clicks. `Esc` stops.
  - *Move* (`W`): the selected object follows the cursor. A click puts it down, `Esc` puts it back.
- **Delete** (or Backspace on a Mac) removes the selected object. `,` `.` rotate it; the other keys work as before, on the preview while placing and on the selected object otherwise.
- **Picking** tests each object's turned and tilted box. An object more than 2 m behind the first surface under the cursor (behind a building, say) can't be clicked.
- **Stable ids** (#1, #2, …) are never reused, ready for saving levels in Block 3.

**In the editor:**
- Yellow box: selected. Cyan: the preview, or the object being moved. White: under the cursor.
- A left press is a click only if the mouse moves less than 5 px. A longer drag still turns the camera, which now waits for those 5 px, so a click doesn't nudge the view.
- `Esc` no longer quits; close the window instead.
- `O` swaps the selected object (or the preview) to the next loaded model. Dropping a `.glb` now starts placing it rather than replacing the object.
- `F` prints the selected object as flags, now with `--model`. `shift+F` prints every object.
- `T` resets the selected object to the command line's placement.

**How it tested:**
- **Unit tests:** `odin test editor`, 13 pass. They cover:
  - Cursor rays through orthographic and perspective cameras, rebuilt with `core:math/linalg` like raylib's. A ray from any projected point passes within 1 mm of it.
  - Rays against turned, scaled boxes, including slanted rays and rays that start inside.
  - Nearest-object picking, and objects hidden behind the terrain.
  - The cursor on a sloped street with a building, at Krakow's 0.005 scale: it lands on the street, on the roof (not the ground behind it), or on the plane when there's no terrain.
  - Click or drag, ids, stamping, move with commit and undo, and deleting mid-move.
  - Settling on the slope, the roof, and under the building.
- `odin test terrain`: still 9 pass. `odin check .` is clean.
- **Not run in a window.** There was no display or GLB where this was built. Worth a try on Krakow: place three cars, select the middle one, move it, delete it.

**Things to know:**
- Over a building with ground snap, the object goes to the ground under the roof, inside the building. Press `Z` for surface snap to put it on the roof.
- Levels aren't saved yet (Block 3). `F` / `shift+F` print what you'd need to rebuild one.

```
odin run . -o:speed -- ./models/terrain/krakow.spz --world-scale 0.005 --model ./models/car/volkswagen_82.glb --align
```

Press `A`, then click a few times along the street.
