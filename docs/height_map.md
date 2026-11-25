# Heightmap from 3DGS

**What it computes:**
- **Two height maps.** A *ground* map has buildings, trees and cars filtered out, with the ground under them filled in smoothly from the streets around. A *surface* map follows the top of whatever is there, roofs and treetops included.
- **A class for each cell:** empty, ground, object (0.5–2 m tall, like cars) or structure (2 m and up, like buildings and trees).
- **Speed:** building the maps takes about 0.25 s for 0.5 M splats and about 0.6 s for 3 M.
- **Settings are in metres** and converted with `--world-scale`, so set it to 0.005 for Krakow.

**In the editor:**
- `Z` switches what the object sits on: ground, surface (roofs) or the old flat plane.
- `Y`/`H` raise or lower the object above the terrain.
- `U` tilts the object to the slope under it.
- `Tab` switches between splats, the grey-box and both. The grey-box shows the ground as a smooth surface and structures as blocks, and goes through the same pixel-art pass as the GLB.
- `shift+Z` rebuilds the terrain after you change the world scale.
- `--terrain-export out/krakow` saves the height maps as 16-bit PGM images plus a JSON file with the grid position and height range.

**How it tested:**
- **Unit tests:** 9 pass, using a synthetic street with a 10% slope, a building with no ground under it, a tree, a car, stray splats in the sky and under the street. Pass at Krakow's 0.005 world scale.
- **Synthetic town:**
  - Open ground is within 3 cm of the true height (99th percentile), and ground under buildings averages 2 cm high.
  - The car tilts 5.7° on the 10% slope, as it should.
- **Wall fix:** the tests showed that wall splats beside a building pushed the ground up by about 25 cm. I changed how each cell's ground height is picked, and that error dropped to 2 cm.

**Things to know:**
- Each map has one height per spot, so bridges, overhangs and interiors aren't represented.
- Flat roofs wider than 40 m count as ground.

```
odin run . -o:speed -- ../ospz/models/krakow.spz --world-scale 0.005 --model assets/models/car/volkswagen_typ-82.glb --align
```

Press `Tab` to see the grey-box.