package main

// The gameplay map in the editor (docs/map_spec.md): built from the terrain
// proxy (mapgen/), the level's edits applied (gamemap.apply_edits), drawn as
// the fourth Tab view, and exported with the mission.
//
//   Tab (4th)   map view: floors by layer and surface, solids as boxes, and
//               one guard standing at the cursor, facing away from the
//               camera, with his vision cone from gamemap.visible: what the
//               game's guards will see, from the game's own code
//   ctrl+E      also writes <id>.map.json + .map.bin, and the mission points
//               at it with "map"
//
// The map is rebuilt on entering the view, on shift+Z in it, and on export.
// Edits are written in the level's "map" section by hand for now.

import "core:fmt"
import "core:math"
import "core:strings"

import rl "vendor:raylib"
import rlgl "vendor:raylib/rlgl"

import "cmd:gamemap"
import "mapgen"
import "scene"

CONE_FOV   :: f32(90)  // degrees
CONE_RANGE :: f32(24)  // metres, the game's VISION_DEFAULT

World_Map :: struct {
	m:        gamemap.Map,
	ok:       bool,
	stats:    mapgen.Stats,
	edits:    int,
	problems: int,
	moved:    int,
	box:      Greybox,
	cone:     []bool,
	cone_key: [4]i32, // the guard's cell, layer and facing (5° steps) it was computed for
	cone_ok:  bool,
	guard:    [3]f32, // map metres, his feet
}

world_map_destroy :: proc(wm: ^World_Map) {
	gamemap.destroy(&wm.m)
	greybox_unload(&wm.box)
	delete(wm.cone)
	wm^ = {}
}

// The level's map section, or the one the first export will create.
level_map_section :: proc(lv: ^Level_State) -> scene.Map_Section {
	if s, ok := lv.map_section.?; ok do return s
	id := lv.id if len(lv.id) > 0 else "level"
	return scene.Map_Section{file = fmt.tprintf("%s.map.json", id), cell = scene.MAP_DEFAULT_CELL}
}

// Replaces the map section (a copy is kept).
level_set_map :: proc(lv: ^Level_State, s: Maybe(scene.Map_Section)) {
	if old, ok := &lv.map_section.?; ok do scene.destroy_map_section(old)
	lv.map_section = nil
	if n, ok := s.?; ok do lv.map_section = scene.clone_map_section(n)
}

// Builds the automatic map from the terrain and the objects and applies the
// level's edits. Reports what the edits could not do on stderr.
world_map_build :: proc(wm: ^World_Map, lv: ^Level_State, p: ^Placement, wt: World_Terrain, shader: rl.Shader) -> bool {
	world_map_destroy(wm)
	if !wt.ok do return false
	g, ok := level_game(lv, p, wt)
	if !ok do return false
	sec := level_map_section(lv)
	params := mapgen.default_params()
	params.cell = scene.map_cell(sec)
	params.yaw = sec.yaw

	ws := p.world_scale
	props := make([dynamic]mapgen.Prop, context.temp_allocator)
	for inst in p.ed.instances {
		a := asset_of(p, inst)
		if a == nil || a.size == {} do continue
		size := a.size * inst.transform.scale * ws
		pos := inst.transform.position
		append(&props, mapgen.prop_from_box(fmt.tprintf("%d", inst.id), pos.xz, size.xz * 0.5, inst.transform.rotation.y, pos.y, pos.y + size.y))
	}

	ter := wt.t
	wm.m, wm.stats = mapgen.build(mapgen.Input{
		terrain = &ter, world_scale = ws, origin = g.origin, size = g.size,
		props = props[:], params = params,
	})
	edits, moved := mapgen.retarget(&wm.m, sec.edits)
	problems := gamemap.apply_edits(&wm.m, edits, context.temp_allocator)
	for mv in moved do fmt.printfln("map: edit %s: %s not found, using %s nearby", mv.edit, mv.from, mv.to)
	for pr in problems do fmt.eprintfln("map: edit %s: %s", pr.edit, pr.message)
	wm.edits, wm.problems, wm.moved = len(sec.edits), len(problems), len(moved)
	wm.box = map_mesh_build(&wm.m, shader)
	wm.cone = make([]bool, wm.m.w * wm.m.h)
	wm.ok = true
	s := wm.stats
	fmt.printfln("map: %dx%d cells of %.1f m, yaw %.1f | %d buildings, %d trees, %d walls, %d props | %d edits, %d problems",
		s.w, s.h, params.cell, s.yaw, s.buildings, s.trees, s.walls, s.props, wm.edits, wm.problems)
	return true
}

// Writes the map next to the level and keeps its frame's yaw in the level,
// so the next build lands on the same grid. Returns the map's path relative
// to `relative_to` (the mission), "" on failure.
world_map_export :: proc(wm: ^World_Map, lv: ^Level_State, relative_to: string) -> (rel: string, err: gamemap.Error) {
	if !wm.ok do return "", .Write
	sec := level_map_section(lv)
	path := scene.resolve(lv.path, sec.file, context.temp_allocator)
	if e := gamemap.save(wm.m, path); e != .None do return "", e
	if _, has := sec.yaw.?; !has {
		sec.yaw = wm.stats.yaw
	}
	level_set_map(lv, sec)
	return scene.relative(relative_to, path, context.temp_allocator), .None
}

// ---------------------------------------------------------------------------
// Drawing
// ---------------------------------------------------------------------------

MAP_COLOURS := [gamemap.Surface][4]u8{
	.Ground = {150, 152, 140, 255},
	.Road   = {128, 128, 124, 255},
	.Grass  = {110, 150, 90, 255},
	.Gravel = {170, 160, 130, 255},
	.Roof   = {196, 120, 84, 255},
	.Floor  = {170, 150, 120, 255},
	.Water  = {80, 120, 170, 255},
	.Deep   = {40, 60, 110, 255},
}
MAP_UPPER  :: [4]u8{214, 140, 90, 255}  // floors above the ground
MAP_SOLID  :: [4]u8{210, 208, 200, 255}
MAP_CANOPY :: [4]u8{90, 130, 80, 255}
MAP_CONE   :: [4]u8{220, 70, 60, 255}

// The map as one mesh, in world space: each floor a quad at its height, each
// solid span a box (tops, the sides that show, the undersides of canopies).
map_mesh_build :: proc(m: ^gamemap.Map, shader: rl.Shader) -> (g: Greybox) {
	verts := make([dynamic][3]f32, context.temp_allocator)
	cols := make([dynamic][4]u8, context.temp_allocator)
	f := m.frame
	cell := m.cell
	world :: proc(f: gamemap.Frame, x, y, h: f32) -> [3]f32 {return gamemap.map_to_world(f, {x, y, h})}
	// a quad facing `want` (world), wound counter-clockwise seen from there
	quad :: proc(verts: ^[dynamic][3]f32, cols: ^[dynamic][4]u8, a, b, c, d, want: [3]f32, col: [4]u8) {
		n := cross3(b - a, c - a)
		if n.x * want.x + n.y * want.y + n.z * want.z < 0 {
			append(verts, a, d, c, a, c, b) // the other way round
		} else {
			append(verts, a, b, c, a, c, d)
		}
		for _ in 0 ..< 6 do append(cols, col)
	}
	up := [3]f32{0, 1, 0}
	ex := world(f, 1, 0, 0) - world(f, 0, 0, 0) // map +x, +y in world
	ey := world(f, 0, 1, 0) - world(f, 0, 0, 0)

	for &l, li in m.layers {
		for ly in 0 ..< l.h {
			for lx in 0 ..< l.w {
				i := ly * l.w + lx
				if l.height[i] == gamemap.NO_FLOOR do continue
				x, y := f32(l.x + lx) * cell, f32(l.y + ly) * cell
				h := gamemap.metres(l.height[i])
				col := MAP_COLOURS[l.surface[i]] if li == 0 else MAP_UPPER
				if .Crawl_Only in l.flags[i] do col.rgb = col.rgb / 4 * 3
				quad(&verts, &cols, world(f, x, y, h), world(f, x + cell, y, h), world(f, x + cell, y + cell, h), world(f, x, y + cell, h), up, col)
			}
		}
	}

	top_of :: proc(m: ^gamemap.Map, x, y: int) -> f32 {
		t := -max(f32)
		for s in gamemap.spans_at(m, x, y) do if s.top > s.bottom do t = max(t, gamemap.metres(s.top))
		return t
	}
	for y in 0 ..< m.h {
		for x in 0 ..< m.w {
			ground, _ := gamemap.height(m, {0, i32(x), i32(y)})
			for s in gamemap.spans_at(m, x, y) {
				if s.top <= s.bottom do continue
				lo, hi := gamemap.metres(s.bottom), gamemap.metres(s.top)
				canopy := lo > ground + 1
				col := MAP_CANOPY if canopy else MAP_SOLID
				x0, y0, x1, y1 := f32(x) * cell, f32(y) * cell, f32(x + 1) * cell, f32(y + 1) * cell
				quad(&verts, &cols, world(f, x0, y0, hi), world(f, x1, y0, hi), world(f, x1, y1, hi), world(f, x0, y1, hi), up, col)
				if canopy do quad(&verts, &cols, world(f, x0, y0, lo), world(f, x1, y0, lo), world(f, x1, y1, lo), world(f, x0, y1, lo), -up, col)
				side := col
				side.rgb = side.rgb / 10 * 9
				for d in ([4][2]int{{1, 0}, {-1, 0}, {0, 1}, {0, -1}}) {
					nb := top_of(m, x + d.x, y + d.y)
					bottom := max(lo, nb) if !canopy else lo
					if bottom >= hi do continue
					// the shared edge
					ax, ay, bx, by: f32
					switch d {
					case {1, 0}:  ax, ay, bx, by = x1, y0, x1, y1
					case {-1, 0}: ax, ay, bx, by = x0, y1, x0, y0
					case {0, 1}:  ax, ay, bx, by = x1, y1, x0, y1
					case:         ax, ay, bx, by = x0, y0, x1, y0
					}
					out := ex * f32(d.x) + ey * f32(d.y)
					quad(&verts, &cols, world(f, ax, ay, bottom), world(f, bx, by, bottom), world(f, bx, by, hi), world(f, ax, ay, hi), out, side)
				}
			}
		}
	}

	n := len(verts)
	if n == 0 do return
	vbuf := ([^]f32)(rl.MemAlloc(u32(n * 3 * size_of(f32))))
	nbuf := ([^]f32)(rl.MemAlloc(u32(n * 3 * size_of(f32))))
	tbuf := ([^]f32)(rl.MemAlloc(u32(n * 2 * size_of(f32))))
	cbuf := ([^]u8)(rl.MemAlloc(u32(n * 4)))
	for k := 0; k + 2 < n; k += 3 {
		a, b, c := verts[k], verts[k + 1], verts[k + 2]
		nn := cross3(b - a, c - a)
		ln := math.sqrt(nn.x * nn.x + nn.y * nn.y + nn.z * nn.z)
		nn = nn / ln if ln > 1e-20 else {0, 1, 0}
		for j in 0 ..< 3 {
			v := verts[k + j]
			vbuf[(k + j) * 3 + 0], vbuf[(k + j) * 3 + 1], vbuf[(k + j) * 3 + 2] = v.x, v.y, v.z
			nbuf[(k + j) * 3 + 0], nbuf[(k + j) * 3 + 1], nbuf[(k + j) * 3 + 2] = nn.x, nn.y, nn.z
			col := cols[k + j]
			cbuf[(k + j) * 4 + 0], cbuf[(k + j) * 4 + 1], cbuf[(k + j) * 4 + 2], cbuf[(k + j) * 4 + 3] = col[0], col[1], col[2], col[3]
		}
	}
	for i in 0 ..< n * 2 do tbuf[i] = 0
	g.mesh.vertexCount = i32(n)
	g.mesh.triangleCount = i32(n / 3)
	g.mesh.vertices = vbuf
	g.mesh.normals = nbuf
	g.mesh.texcoords = tbuf
	g.mesh.colors = cbuf
	rl.UploadMesh(&g.mesh, false)
	g.material = rl.LoadMaterialDefault()
	g.material.shader = shader
	g.ok = true
	return
}

// Puts the preview guard at the cursor, facing along the camera's view
// (world forward), and recomputes his cone when he moved or turned.
world_map_guard :: proc(wm: ^World_Map, cursor: [3]f32, cursor_ok: bool, forward: [3]f32) {
	if !wm.ok || !cursor_ok {
		wm.cone_ok = false
		return
	}
	m := &wm.m
	p := gamemap.world_to_map(m.frame, cursor)
	node, on := gamemap.node_at(m, p)
	if !on {
		wm.cone_ok = false
		return
	}
	a := gamemap.world_to_map(m.frame, cursor)
	b := gamemap.world_to_map(m.frame, cursor + {forward.x, 0, forward.z})
	facing := math.atan2(b.y - a.y, b.x - a.x)
	step := i32(math.round(facing * math.DEG_PER_RAD / 5))
	key := [4]i32{node.x, node.y, i32(node.layer), step}
	if wm.cone_ok && key == wm.cone_key do return
	wm.cone_key = key
	wm.guard = gamemap.node_point(m, node)
	gamemap.visible(m, gamemap.eye_point(wm.guard, .Standing), f32(step) * 5 * math.RAD_PER_DEG, CONE_FOV * math.RAD_PER_DEG, CONE_RANGE, wm.cone)
	wm.cone_ok = true
}

world_map_draw :: proc(wm: ^World_Map) {
	if !wm.ok do return
	greybox_draw(wm.box)
	if !wm.cone_ok do return
	m := &wm.m
	f := m.frame
	c := rl.Color{MAP_CONE[0], MAP_CONE[1], MAP_CONE[2], MAP_CONE[3]}
	lift := f32(0.05)
	rlgl.DisableBackfaceCulling()
	for y in 0 ..< m.h {
		for x in 0 ..< m.w {
			if !wm.cone[y * m.w + x] do continue
			floors := gamemap.layers_at(m, x, y)
			if len(floors) == 0 do continue
			h, _ := gamemap.height(m, {floors[len(floors) - 1], i32(x), i32(y)})
			x0, y0 := f32(x) * m.cell, f32(y) * m.cell
			x1, y1 := x0 + m.cell, y0 + m.cell
			a := gamemap.map_to_world(f, {x0, y0, h + lift})
			b := gamemap.map_to_world(f, {x1, y0, h + lift})
			cc := gamemap.map_to_world(f, {x1, y1, h + lift})
			d := gamemap.map_to_world(f, {x0, y1, h + lift})
			rl.DrawTriangle3D(a, cc, b, c)
			rl.DrawTriangle3D(a, d, cc, c)
		}
	}
	// the guard: a post 1.7 m tall
	g0 := gamemap.map_to_world(f, wm.guard)
	g1 := gamemap.map_to_world(f, wm.guard + {0, 0, gamemap.EYE[.Standing]})
	rl.DrawCylinderEx(g0, g1, 0.3 * f.world_scale, 0.3 * f.world_scale, 8, {240, 220, 60, 255})
	rlgl.DrawRenderBatchActive()
	rlgl.EnableBackfaceCulling()
}

draw_map_hud :: proc(wm: ^World_Map, lv: ^Level_State, x, y: i32) {
	col := rl.Color{170, 200, 220, 255}
	if !wm.ok {
		rl.DrawText("map: not built (no terrain)", x, y, 16, {200, 150, 120, 255})
		return
	}
	s := wm.stats
	sec := level_map_section(lv)
	yaw_note := "" if sec.yaw != nil else " (measured: ctrl+E keeps it)"
	problems := strings.clone_to_cstring(fmt.tprintf(" | %d edit%s could not be applied (see the console)", wm.problems, "" if wm.problems == 1 else "s") if wm.problems > 0 else "", context.temp_allocator)
	rl.DrawText(
		fmt.ctprintf("map %dx%d @ %.1f m, yaw %.1f%s | %d buildings  %d trees  %d walls  %d props | %d edits%s | guard at the cursor: %d m cone",
			s.w, s.h, wm.m.cell, s.yaw, yaw_note, s.buildings, s.trees, s.walls, s.props, wm.edits, problems, int(CONE_RANGE)),
		x, y, 16, col if wm.problems == 0 else rl.Color{230, 160, 90, 255},
	)
}
