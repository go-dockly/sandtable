package main

// Block 5 glue: builds the terrain proxy (terrain/terrain.odin) from the
// loaded cloud and shows it as a grey-box: the ground as a smooth surface,
// structures (buildings, walls, trees) as blocks standing on it. The grey-box
// goes through the same pass as GLB objects (model shader, depth tested
// against the splats, pixel-art post), so it can replace the splats or be
// seen through them.
//
//   Tab        view: splats / grey-box / both / gameplay map
//   shift+Z    rebuild the terrain at the current world scale

import "core:fmt"
import "core:math"
import "core:time"

import rl "vendor:raylib"
import rlgl "vendor:raylib/rlgl"

import "../terrain"

Terrain_View :: enum {
	Splats,
	Greybox,
	Both,
	Map, // the gameplay map (map_view.odin)
}

World_Terrain :: struct {
	t:           terrain.Terrain,
	ok:          bool,
	built_scale: f32, // world scale it was built with
	build_ms:    f64,
	view:        Terrain_View,
	box:         Greybox,
	cell_m:      f32,    // --cell: cell size in metres; 0 = automatic
	export:      string, // --terrain-export prefix; written after every build
}

terrain_params :: proc(world_scale, cell_m: f32) -> terrain.Params {
	p := terrain.default_params(world_scale)
	if cell_m > 0 {
		p.cell = cell_m * world_scale
		p.adapt_cell = false
	}
	return p
}

world_terrain_build :: proc(wt: ^World_Terrain, v: Splat_View, world_scale: f32, shader: rl.Shader) {
	terrain.destroy(&wt.t)
	greybox_unload(&wt.box)
	wt.ok = false
	wt.built_scale = world_scale
	if v.count == 0 do return

	t0 := time.now()
	t, ok := terrain.build(v.pos, v.opacity, terrain_params(world_scale, wt.cell_m))
	wt.build_ms = time.duration_milliseconds(time.since(t0))
	if !ok {
		fmt.eprintln("terrain: no usable splats, placement stays on the ground plane")
		return
	}
	wt.t, wt.ok = t, true
	wt.box = greybox_build(t, shader)

	s := t.stats
	fmt.printf(
		"terrain: %dx%d cells of %.2f m, %d splats, %.0f ms | ground %.0f%%, object %.0f%%, structure %.0f%%, no data %.0f%%\n",
		t.w, t.h, t.cell / world_scale, s.splats_used, wt.build_ms,
		pct(s.ground_cells, t.w * t.h), pct(s.object_cells, t.w * t.h),
		pct(s.structure_cells, t.w * t.h), pct(t.w * t.h - s.data_cells, t.w * t.h),
	)
	if len(wt.export) > 0 {
		names, err := terrain.export(t, wt.export, world_scale)
		if err != nil {
			fmt.eprintf("terrain export %s: %v\n", wt.export, err)
		} else {
			for name in names {
				fmt.printf("terrain: wrote %s\n", name)
				delete(name)
			}
		}
	}
}

world_terrain_destroy :: proc(wt: ^World_Terrain) {
	terrain.destroy(&wt.t)
	greybox_unload(&wt.box)
	wt.ok = false
}

pct :: proc(a, b: int) -> f32 {
	return 100 * f32(a) / f32(max(b, 1))
}

// ---------------------------------------------------------------------------
// Grey-box mesh. Ground: two triangles per cell between corner heights (the
// mean of the cells around each corner), so it is smooth and matches what
// sample_height returns to within the bilinear difference. Structures: a flat
// top at the surface height and walls down to whatever is next to them.
//
// Large grids are coarsened first (GREYBOX_MAX_CELLS): a block's structure
// height is the highest of its structure cells, its ground the mean.
// ---------------------------------------------------------------------------

GREYBOX_MAX_CELLS :: 200_000

GREYBOX_GROUND    :: [4]u8{150, 152, 140, 255}
GREYBOX_NO_DATA   :: [4]u8{112, 112, 108, 255}
GREYBOX_STRUCTURE :: [4]u8{210, 208, 200, 255}

Greybox :: struct {
	mesh:     rl.Mesh,
	material: rl.Material,
	ok:       bool,
}

greybox_build :: proc(t: terrain.Terrain, shader: rl.Shader) -> (g: Greybox) {
	if !terrain.valid(t) do return

	// coarsen
	step := 1
	for (t.w / step) * (t.h / step) > GREYBOX_MAX_CELLS do step += 1
	w := (t.w + step - 1) / step
	h := (t.h + step - 1) / step
	cell := t.cell * f32(step)
	ground := make([]f32, w * h)
	defer delete(ground)
	top := make([]f32, w * h) // structure top, or ground
	defer delete(top)
	solid := make([]bool, w * h) // has a structure
	defer delete(solid)
	data := make([]bool, w * h) // any splats
	defer delete(data)
	for bz in 0 ..< h {
		for bx in 0 ..< w {
			sum: f32
			k: int
			hi := -max(f32)
			for z in bz * step ..< min((bz + 1) * step, t.h) {
				for x in bx * step ..< min((bx + 1) * step, t.w) {
					c := z * t.w + x
					sum += t.ground[c]
					k += 1
					if t.class[c] == .Structure do hi = max(hi, t.surface[c])
					if t.class[c] != .Empty do data[bz * w + bx] = true
				}
			}
			b := bz * w + bx
			ground[b] = sum / f32(max(k, 1))
			solid[b] = hi > -max(f32)
			top[b] = max(hi, ground[b]) if solid[b] else ground[b]
		}
	}

	// corner heights of the ground
	corner := make([]f32, (w + 1) * (h + 1))
	defer delete(corner)
	for cz in 0 ..= h {
		for cx in 0 ..= w {
			sum: f32
			k: f32
			for dz in -1 ..= 0 {
				for dx in -1 ..= 0 {
					x, z := cx + dx, cz + dz
					if x < 0 || z < 0 || x >= w || z >= h do continue
					sum += ground[z * w + x]
					k += 1
				}
			}
			corner[cz * (w + 1) + cx] = sum / k
		}
	}

	// count triangles: 2 per cell of ground, 2 per structure top, 2 per wall
	tris := 0
	for z in 0 ..< h {
		for x in 0 ..< w {
			b := z * w + x
			tris += 2
			if !solid[b] do continue
			tris += 2
			tris += 2 * 4
		}
	}

	verts := ([^]f32)(rl.MemAlloc(u32(tris * 3 * 3 * size_of(f32))))
	norms := ([^]f32)(rl.MemAlloc(u32(tris * 3 * 3 * size_of(f32))))
	uvs := ([^]f32)(rl.MemAlloc(u32(tris * 3 * 2 * size_of(f32))))
	cols := ([^]u8)(rl.MemAlloc(u32(tris * 3 * 4)))
	nv := 0

	vert :: proc(verts, norms: [^]f32, cols: [^]u8, nv: ^int, p, n: [3]f32, c: [4]u8) {
		i := nv^
		verts[i * 3 + 0], verts[i * 3 + 1], verts[i * 3 + 2] = p.x, p.y, p.z
		norms[i * 3 + 0], norms[i * 3 + 1], norms[i * 3 + 2] = n.x, n.y, n.z
		cols[i * 4 + 0], cols[i * 4 + 1], cols[i * 4 + 2], cols[i * 4 + 3] = c[0], c[1], c[2], c[3]
		nv^ = i + 1
	}
	// a quad a b c d, counter-clockwise seen from where n points
	quad :: proc(verts, norms: [^]f32, cols: [^]u8, nv: ^int, a, b, c, d: [3]f32, n: [3]f32, col: [4]u8) {
		vert(verts, norms, cols, nv, a, n, col)
		vert(verts, norms, cols, nv, b, n, col)
		vert(verts, norms, cols, nv, c, n, col)
		vert(verts, norms, cols, nv, a, n, col)
		vert(verts, norms, cols, nv, c, n, col)
		vert(verts, norms, cols, nv, d, n, col)
	}
	face_normal :: proc(a, b, c: [3]f32) -> [3]f32 {
		n := cross3(b - a, c - a)
		l := math.sqrt(n.x * n.x + n.y * n.y + n.z * n.z)
		return n / l if l > 1e-20 else {0, 1, 0}
	}

	ox, oz := t.origin.x, t.origin.y
	for z in 0 ..< h {
		for x in 0 ..< w {
			b := z * w + x
			x0, x1 := ox + f32(x) * cell, ox + f32(x + 1) * cell
			z0, z1 := oz + f32(z) * cell, oz + f32(z + 1) * cell
			p00 := [3]f32{x0, corner[z * (w + 1) + x], z0}
			p10 := [3]f32{x1, corner[z * (w + 1) + x + 1], z0}
			p01 := [3]f32{x0, corner[(z + 1) * (w + 1) + x], z1}
			p11 := [3]f32{x1, corner[(z + 1) * (w + 1) + x + 1], z1}
			gc := GREYBOX_GROUND if data[b] else GREYBOX_NO_DATA
			// +Y up, x right, z towards the viewer: p00 p01 p11 is counter-clockwise from above
			n0 := face_normal(p00, p01, p11)
			vert(verts, norms, cols, &nv, p00, n0, gc)
			vert(verts, norms, cols, &nv, p01, n0, gc)
			vert(verts, norms, cols, &nv, p11, n0, gc)
			n1 := face_normal(p00, p11, p10)
			vert(verts, norms, cols, &nv, p00, n1, gc)
			vert(verts, norms, cols, &nv, p11, n1, gc)
			vert(verts, norms, cols, &nv, p10, n1, gc)

			if !solid[b] do continue
			y := top[b]
			quad(verts, norms, cols, &nv, {x0, y, z0}, {x0, y, z1}, {x1, y, z1}, {x1, y, z0}, {0, 1, 0}, GREYBOX_STRUCTURE)

			// walls: down to the neighbour's top, or to this cell's lowest
			// ground corner at the edge of the grid
			floor := min(p00.y, p10.y, p01.y, p11.y)
			below :: proc(top: []f32, solid: []bool, w, h, x, z: int, floor: f32) -> f32 {
				if x < 0 || z < 0 || x >= w || z >= h do return floor
				return top[z * w + x] if solid[z * w + x] else floor
			}
			wall := GREYBOX_STRUCTURE
			wall.rgb = wall.rgb / 10 * 9 // the shader lights them; keep the tops readable
			if yb := below(top, solid, w, h, x - 1, z, floor); yb < y {
				quad(verts, norms, cols, &nv, {x0, yb, z0}, {x0, yb, z1}, {x0, y, z1}, {x0, y, z0}, {-1, 0, 0}, wall)
			}
			if yb := below(top, solid, w, h, x + 1, z, floor); yb < y {
				quad(verts, norms, cols, &nv, {x1, yb, z1}, {x1, yb, z0}, {x1, y, z0}, {x1, y, z1}, {1, 0, 0}, wall)
			}
			if yb := below(top, solid, w, h, x, z - 1, floor); yb < y {
				quad(verts, norms, cols, &nv, {x1, yb, z0}, {x0, yb, z0}, {x0, y, z0}, {x1, y, z0}, {0, 0, -1}, wall)
			}
			if yb := below(top, solid, w, h, x, z + 1, floor); yb < y {
				quad(verts, norms, cols, &nv, {x0, yb, z1}, {x1, yb, z1}, {x1, y, z1}, {x0, y, z1}, {0, 0, 1}, wall)
			}
		}
	}
	for i in 0 ..< nv * 2 do uvs[i] = 0

	g.mesh.vertexCount = i32(nv)
	g.mesh.triangleCount = i32(nv / 3)
	g.mesh.vertices = verts
	g.mesh.normals = norms
	g.mesh.texcoords = uvs
	g.mesh.colors = cols
	rl.UploadMesh(&g.mesh, false)
	g.material = rl.LoadMaterialDefault()
	g.material.shader = shader
	g.ok = true
	return
}

greybox_unload :: proc(g: ^Greybox) {
	if !g.ok do return
	rl.UnloadMesh(g.mesh)
	g.material.shader = {} // shared with the GLB objects, not ours to unload
	rl.UnloadMaterial(g.material)
	g^ = {}
}

// Same place in the frame as model_draw: before the splats, depth written.
greybox_draw :: proc(g: Greybox) {
	if !g.ok do return
	rlgl.EnableDepthTest()
	rlgl.EnableDepthMask()
	rl.DrawMesh(g.mesh, g.material, rl.Matrix(1))
	rlgl.DrawRenderBatchActive()
}

cross3 :: proc(a, b: [3]f32) -> [3]f32 {
	return {a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x}
}

