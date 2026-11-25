package main

// Placement: one GLB object, driven from the keyboard and the command line.
// No mouse picking yet (Block 2).
//
// Block 1 stood it on a horizontal ground plane: a single height, a first
// guess from the cloud corrected by eye. Block 5 stands it on the terrain
// proxy (terrain/terrain.odin) instead: the height under its footprint, and
// with alignment on, the slope of the ground under it. The plane stays as a
// snap mode, for clouds the terrain cannot be built from.
//
//   I J K L        move along the ground, relative to the view (shift: faster)
//   Y H            plane: raise / lower the ground plane (the object stays on it)
//                  terrain: raise / lower the object above the terrain (offset)
//   Z              snap: ground (DTM) / surface (DSM, roofs) / plane
//   U              align the object to the slope under it / keep it upright
//   , .            rotate 15 degrees left / right (shift: 90)
//   N M            object scale down / up (shift: faster)
//   ctrl+N M       world scale down / up: calibrate the capture against a
//                  known-size object (a car is ~4 m), then keep the value
//   T              back to the start transform
//   B              overlay: ground grid, bounds, pivot, +Z forward
//   V              hide / show the object
//   F              print the current transform as command-line flags

import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:slice"
import "core:strconv"
import "core:strings"

import rl "vendor:raylib"

import "terrain"

Transform :: struct {
	position: [3]f32, // world position of the pivot (bottom centre of the bounds)
	rotation: [3]f32, // Euler XYZ, radians. Upright objects only use .y
	scale:    [3]f32, // object scale: 1 = the GLB's own size, in metres
	up:       [3]f32, // the object's +Y after the rotation: the ground normal when
	                  // aligned. {0, 1, 0} (or zero): upright
}

// Where the object's height comes from.
Snap :: enum {
	Ground,  // terrain DTM: bare ground, under trees and between buildings
	Surface, // terrain DSM: the top, so roofs and walls
	Plane,   // a horizontal plane at `ground` (Block 1)
}

// Splat captures are not in metres (Krakow: ~0.005 units per metre), GLBs are.
// world_scale bridges the two, so objects keep scale 1 at real size and sizes
// can be shown in metres.
Placement :: struct {
	transform:   Transform,
	ground:      f32, // height of the placement plane; transform.position.y follows it
	world_scale: f32, // world units per metre
	overlay:     bool,
	visible:     bool,
	snap:        Snap,
	offset:      f32,  // terrain snap: height above the terrain, world units
	align:       bool, // terrain snap: tilt to the slope under the footprint
	max_tilt:    f32,  // radians
	on_terrain:  bool, // the pivot is over the terrain grid (else its edge is extended)
}

// Command line. The cloud is the first argument that is not a flag.
//
//   odin run . -- ../ospz/models/krakow.spz --model assets/models/car/volkswagen_typ-82.glb
//                 [--world-scale u] [--pos x,y,z] [--yaw degrees] [--scale s] [--ground y]
//                 [--snap ground|surface|plane] [--offset y] [--align] [--max-tilt degrees]
//                 [--cell metres] [--terrain-export prefix]
//
// --world-scale is world units per metre (default 1). --pos sets the ground
// plane to its y (snapping to the terrain ignores that y). --ground alone keeps
// x/z at the cloud centre.
Options :: struct {
	cloud:       string,
	model:       string,
	pos:         [3]f32,
	yaw:         f32, // degrees
	scale:       f32,
	world_scale: f32,
	ground:      f32,
	has_pos:     bool,
	has_ground:  bool,
	snap:        Snap,
	offset:      f32, // world units
	align:       bool,
	max_tilt:    f32, // degrees
	cell_m:      f32, // terrain cell, metres; 0 = automatic
	export:      string,
}

DEFAULT_MAX_TILT :: f32(20) // degrees; steeper than any street, flatter than a kerb edge


parse_options :: proc(args: []string) -> (o: Options, ok: bool) {
	o.scale = 1
	o.world_scale = 1
	o.max_tilt = DEFAULT_MAX_TILT
	ok = true
	i := 0
	for i < len(args) {
		arg := args[i]
		i += 1
		if !strings.has_prefix(arg, "--") {
			if len(o.cloud) == 0 {
				o.cloud = arg
			} else {
				fmt.eprintf("unexpected argument %q\n", arg)
				ok = false
			}
			continue
		}

		if arg == "--align" { // the one flag without a value
			o.align = true
			continue
		}
		name, value := arg, ""
		has_value := false
		if eq := strings.index_byte(arg, '='); eq >= 0 {
			name, value, has_value = arg[:eq], arg[eq + 1:], true
		} else if i < len(args) {
			value, has_value = args[i], true
			i += 1
		}
		if !has_value {
			fmt.eprintf("%s needs a value\n", name)
			ok = false
			continue
		}

		switch name {
		case "--model":
			o.model = value
		case "--scale":
			v, vok := strconv.parse_f32(value)
			if !vok || v <= 0 {
				fmt.eprintf("--scale %q: expected a positive number\n", value)
				ok = false
			} else {
				o.scale = v
			}
		case "--world-scale":
			v, vok := strconv.parse_f32(value)
			if !vok || v <= 0 {
				fmt.eprintf("--world-scale %q: expected world units per metre, > 0\n", value)
				ok = false
			} else {
				o.world_scale = v
			}
		case "--yaw":
			v, vok := strconv.parse_f32(value)
			if !vok {
				fmt.eprintf("--yaw %q: expected degrees\n", value)
				ok = false
			} else {
				o.yaw = v
			}
		case "--ground":
			v, vok := strconv.parse_f32(value)
			if !vok {
				fmt.eprintf("--ground %q: expected a height\n", value)
				ok = false
			} else {
				o.ground, o.has_ground = v, true
			}
		case "--snap":
			switch value {
			case "ground":  o.snap = .Ground
			case "surface": o.snap = .Surface
			case "plane":   o.snap = .Plane
			case:
				fmt.eprintf("--snap %q: expected ground, surface or plane\n", value)
				ok = false
			}
		case "--offset":
			v, vok := strconv.parse_f32(value)
			if !vok {
				fmt.eprintf("--offset %q: expected a height above the terrain, world units\n", value)
				ok = false
			} else {
				o.offset = v
			}
		case "--max-tilt":
			v, vok := strconv.parse_f32(value)
			if !vok || v < 0 || v > 90 {
				fmt.eprintf("--max-tilt %q: expected 0..90 degrees\n", value)
				ok = false
			} else {
				o.max_tilt = v
			}
		case "--cell":
			v, vok := strconv.parse_f32(value)
			if !vok || v < 0 {
				fmt.eprintf("--cell %q: expected the terrain cell in metres, 0 = automatic\n", value)
				ok = false
			} else {
				o.cell_m = v
			}
		case "--terrain-export":
			o.export = value
		case "--pos":
			parts := strings.split(value, ",", context.temp_allocator)
			good := len(parts) == 3
			if good {
				for part, k in parts {
					v, vok := strconv.parse_f32(strings.trim_space(part))
					if !vok {
						good = false
						break
					}
					o.pos[k] = v
				}
			}
			if !good {
				fmt.eprintf("--pos %q: expected x,y,z\n", value)
				ok = false
			} else {
				o.has_pos = true
			}
		case:
			fmt.eprintf("unknown flag %s\n", name)
			ok = false
		}
	}
	return
}

// A low percentile of the cloud's heights: a first guess at street level that
// ignores the odd stray splat below the capture. +Y is up (SPZ's RUB frame).
GROUND_PERCENTILE :: f32(0.05)

ground_guess :: proc(pos: [][3]f32) -> f32 {
	if len(pos) == 0 do return 0
	STEP :: 8
	m := (len(pos) + STEP - 1) / STEP
	tmp := make([]f32, m)
	defer delete(tmp)
	for i in 0 ..< m do tmp[i] = pos[i * STEP].y
	slice.sort(tmp)
	return tmp[int(f32(m - 1) * GROUND_PERCENTILE)]
}

// Start transform: the command line where given, otherwise the cloud centre on
// the guessed ground.
placement_reset :: proc(p: ^Placement, o: Options, v: Splat_View) {
	ground := ground_guess(v.pos)
	if o.has_ground do ground = o.ground
	position := [3]f32{v.center.x, ground, v.center.z}
	if o.has_pos {
		position = o.pos
		ground = o.pos.y
	}
	p.ground = ground
	p.world_scale = o.world_scale
	p.transform = Transform{
		position = position,
		rotation = {0, o.yaw * math.RAD_PER_DEG, 0},
		scale    = {o.scale, o.scale, o.scale},
		up       = {0, 1, 0},
	}
	p.snap = o.snap
	p.offset = o.offset
	p.align = o.align
	p.max_tilt = o.max_tilt * math.RAD_PER_DEG
}

snapped :: proc(p: Placement, has_terrain: bool) -> bool {
	return p.snap != .Plane && has_terrain
}

snap_layer :: proc(s: Snap) -> terrain.Layer {
	return .Surface if s == .Surface else .Ground
}

// Height (and with align, tilt) from the terrain under the footprint. Call
// after placement_update, every frame: the object follows the terrain as it
// moves. Without a terrain, or in plane mode, it stands on the plane.
placement_settle :: proc(p: ^Placement, a: Model_Asset, ter: terrain.Terrain, has_terrain: bool) {
	t := &p.transform
	if !snapped(p^, has_terrain) {
		t.position.y = p.ground
		t.up = {0, 1, 0}
		p.on_terrain = false
		return
	}
	half := object_size_m(a, t^).xz * p.world_scale * 0.5
	h, n, inside := terrain.fit_footprint(
		ter, t.position.xz, half, t.rotation.y, snap_layer(p.snap),
		p.max_tilt if p.align else 0,
	)
	t.position.y = h + p.offset
	t.up = n if p.align else {0, 1, 0}
	p.on_terrain = inside
	p.ground = h // the plane follows, so switching to plane mode keeps the height
}

ROTATE_STEP        :: f32(15)
ROTATE_STEP_COARSE :: f32(90)

// extent: the cloud's size, so movement speed scales with the capture.
// has_terrain: Y/H move the offset above it rather than the plane.
placement_update :: proc(p: ^Placement, camera: rl.Camera3D, extent: f32, dt: f32, has_terrain: bool) {
	shift := rl.IsKeyDown(.LEFT_SHIFT) || rl.IsKeyDown(.RIGHT_SHIFT)
	speed := extent * 0.1 * dt * (f32(5) if shift else f32(1))

	// view direction flattened onto the ground: I moves "up the screen"
	f := camera.target - camera.position
	f.y = 0
	if linalg.vector_length(f) < 1e-6 {
		f = {0, 0, -1}
	}
	f = linalg.normalize(f)
	r := [3]f32{-f.z, 0, f.x}

	move: [3]f32
	if rl.IsKeyDown(.I) do move += f
	if rl.IsKeyDown(.K) do move -= f
	if rl.IsKeyDown(.L) do move += r
	if rl.IsKeyDown(.J) do move -= r
	p.transform.position += move * speed

	// Y/H: the plane, or the height above the terrain (slower: it is a fine
	// correction, a few centimetres for a car's tyres)
	if snapped(p^, has_terrain) {
		fine := speed * 0.1
		if rl.IsKeyDown(.Y) do p.offset += fine
		if rl.IsKeyDown(.H) do p.offset -= fine
	} else {
		if rl.IsKeyDown(.Y) do p.ground += speed
		if rl.IsKeyDown(.H) do p.ground -= speed
		p.transform.position.y = p.ground
	}
	if rl.IsKeyPressed(.Z) && !shift do p.snap = Snap((int(p.snap) + 1) % len(Snap))
	if rl.IsKeyPressed(.U) do p.align = !p.align

	step := (ROTATE_STEP_COARSE if shift else ROTATE_STEP) * math.RAD_PER_DEG
	if rl.IsKeyPressed(.COMMA) do p.transform.rotation.y += step // counter-clockwise seen from above
	if rl.IsKeyPressed(.PERIOD) do p.transform.rotation.y -= step
	p.transform.rotation.y = math.mod(p.transform.rotation.y, 2 * math.PI)

	// exponential, so a held key feels the same at any size: x2 per second.
	// ctrl: the world scale instead, for calibrating a capture
	rate := f32(math.LN2) * dt * (f32(4) if shift else f32(1))
	ctrl := rl.IsKeyDown(.LEFT_CONTROL) || rl.IsKeyDown(.RIGHT_CONTROL)
	factor: f32 = 1
	if rl.IsKeyDown(.M) do factor = math.exp(rate)
	if rl.IsKeyDown(.N) do factor = math.exp(-rate)
	if ctrl {
		p.world_scale *= factor
	} else {
		p.transform.scale *= factor
	}

	if rl.IsKeyPressed(.B) do p.overlay = !p.overlay
	if rl.IsKeyPressed(.V) do p.visible = !p.visible
	if rl.IsKeyPressed(.F) do fmt.println(placement_flags(p^, context.temp_allocator))
}

placement_flags :: proc(p: Placement, allocator := context.allocator) -> string {
	t := p.transform
	yaw := t.rotation.y * math.DEG_PER_RAD
	if yaw < 0 do yaw += 360
	f := world_fmt(p.world_scale)
	snap := " --snap plane"
	if p.snap != .Plane {
		snap = fmt.tprintf(
			" --snap %s --offset %s%s --max-tilt %.0f",
			"ground" if p.snap == .Ground else "surface",
			fmt.tprintf(f, p.offset), " --align" if p.align else "", p.max_tilt * math.DEG_PER_RAD,
		)
	}
	return fmt.aprintf(
		"--world-scale %.6f --pos %s,%s,%s --yaw %.1f --scale %.3f%s",
		p.world_scale,
		fmt.tprintf(f, t.position.x), fmt.tprintf(f, t.position.y), fmt.tprintf(f, t.position.z),
		yaw, t.scale.x, snap,
		allocator = allocator,
	)
}

// Format for world-unit values that resolves about a centimetre: Krakow at
// ~0.005 units/m needs 5 decimals where a metric capture needs 2.
world_fmt :: proc(world_scale: f32) -> string {
	d := int(math.ceil(math.log10(100 / max(world_scale, 1e-9))))
	switch {
	case d <= 2: return "%.2f"
	case d == 3: return "%.3f"
	case d == 4: return "%.4f"
	case d == 5: return "%.5f"
	case d == 6: return "%.6f"
	}
	return "%.7f"
}

// Object size in metres: the GLB's bounds times the object scale.
object_size_m :: proc(a: Model_Asset, t: Transform) -> [3]f32 {
	return a.size * t.scale
}

// Grid cell in metres, a power of ten giving 2..10 cells either side of the
// object. 1 m for anything car-sized.
grid_cell_m :: proc(half_m: f32) -> f32 {
	cell: f32 = 1
	for half_m / cell > 10 do cell *= 10
	for half_m / cell < 2 && cell > 0.01 do cell /= 10
	return cell
}

// ---------------------------------------------------------------------------
// Editor overlay, drawn at screen resolution on top of the upscaled art so it
// stays crisp and is never palette-snapped. Points are projected with the same
// view/projection the scene pass used, so they line up with what was rendered.
// ---------------------------------------------------------------------------

OVERLAY_GRID   :: rl.Color{120, 200, 255, 90}
OVERLAY_BOUNDS :: rl.Color{255, 220, 90, 200}
OVERLAY_PIVOT  :: rl.Color{255, 90, 90, 255}
OVERLAY_FRONT  :: rl.Color{120, 255, 140, 255}

project_point :: proc(vp: rl.Matrix, w, h: f32, q: [3]f32) -> (rl.Vector2, bool) {
	c := vp * [4]f32{q.x, q.y, q.z, 1}
	if c.w <= 1e-6 do return {}, false
	ndc := c.xy / c.w
	return {(ndc.x * 0.5 + 0.5) * w, (0.5 - ndc.y * 0.5) * h}, true
}

overlay_line :: proc(vp: rl.Matrix, w, h: f32, a, b: [3]f32, col: rl.Color, thick: f32 = 1) {
	pa, oka := project_point(vp, w, h, a)
	pb, okb := project_point(vp, w, h, b)
	if oka && okb do rl.DrawLineEx(pa, pb, thick, col)
}

// A grid line from a to b: straight on the plane, or draped over the terrain
// in steps of about a cell, so the grid shows the heightmap under the object.
overlay_ground_line :: proc(
	vp: rl.Matrix, w, h: f32, a, b: [2]f32, plane_y: f32,
	ter: terrain.Terrain, layer: terrain.Layer, drape: bool, col: rl.Color,
) {
	if !drape {
		overlay_line(vp, w, h, {a.x, plane_y, a.y}, {b.x, plane_y, b.y}, col)
		return
	}
	d := b - a
	steps := clamp(int(math.ceil(math.sqrt(d.x * d.x + d.y * d.y) / ter.cell)), 1, 64)
	prev: [3]f32
	for k in 0 ..= steps {
		q := a + d * (f32(k) / f32(steps))
		y, _ := terrain.sample_height(ter, q.x, q.y, layer)
		cur := [3]f32{q.x, y, q.y}
		if k > 0 do overlay_line(vp, w, h, prev, cur, col)
		prev = cur
	}
}

// w, h: size of the drawn picture in screen pixels (art size * pixel size)
draw_placement_overlay :: proc(
	a: Model_Asset, p: Placement, view_m, proj_m: rl.Matrix, w, h: f32,
	ter: terrain.Terrain, has_terrain: bool,
) {
	vp := proj_m * view_m
	t := p.transform
	g := p.ground
	drape := snapped(p, has_terrain)
	layer := snap_layer(p.snap)

	// ground grid around the object in whole metres (grid_cell_m), so the
	// world scale can be checked against the object at a glance
	size_m := object_size_m(a, t)
	foot_m := max(size_m.x, size_m.z)
	if foot_m <= 0 do foot_m = 1
	cell_m := grid_cell_m(foot_m * 2)
	n := int(math.ceil(foot_m * 2 / cell_m))
	cell := cell_m * p.world_scale
	half := f32(n) * cell
	c := t.position
	for k in -n ..= n {
		o := f32(k) * cell
		overlay_ground_line(vp, w, h, {c.x - half, c.z + o}, {c.x + half, c.z + o}, g, ter, layer, drape, OVERLAY_GRID)
		overlay_ground_line(vp, w, h, {c.x + o, c.z - half}, {c.x + o, c.z + half}, g, ter, layer, drape, OVERLAY_GRID)
	}

	if a.model.meshCount <= 0 do return
	foot := foot_m * p.world_scale
	world := model_matrix(a, t, p.world_scale)
	to_world :: proc(m: rl.Matrix, q: [3]f32) -> [3]f32 {
		r := m * [4]f32{q.x, q.y, q.z, 1}
		return r.xyz
	}

	// model-space bounds, through the full object transform
	lo := a.pivot - {a.size.x * 0.5, 0, a.size.z * 0.5}
	hi := a.pivot + {a.size.x * 0.5, a.size.y, a.size.z * 0.5}
	corners: [8][3]f32
	for k in 0 ..< 8 {
		q := [3]f32{
			hi.x if k & 1 != 0 else lo.x,
			hi.y if k & 2 != 0 else lo.y,
			hi.z if k & 4 != 0 else lo.z,
		}
		corners[k] = to_world(world, q)
	}
	EDGES :: [12][2]int{
		{0, 1}, {2, 3}, {4, 5}, {6, 7}, // x
		{0, 2}, {1, 3}, {4, 6}, {5, 7}, // y
		{0, 4}, {1, 5}, {2, 6}, {3, 7}, // z
	}
	edges := EDGES
	for e in edges {
		overlay_line(vp, w, h, corners[e[0]], corners[e[1]], OVERLAY_BOUNDS)
	}

	// pivot cross in the object's base plane, and the model's +Z as its "front"
	arm := foot * 0.15 / max(t.scale.x * p.world_scale, 1e-12) // model units
	pv := a.pivot
	overlay_line(vp, w, h, to_world(world, pv - {arm, 0, 0}), to_world(world, pv + {arm, 0, 0}), OVERLAY_PIVOT, 2)
	overlay_line(vp, w, h, to_world(world, pv - {0, 0, arm}), to_world(world, pv + {0, 0, arm}), OVERLAY_PIVOT, 2)
	front := to_world(world, a.pivot + {0, 0, a.size.z * 0.5 + a.size.z * 0.25})
	overlay_line(vp, w, h, c, front, OVERLAY_FRONT, 2)
	if tip, ok := project_point(vp, w, h, front); ok {
		rl.DrawText("+Z", i32(tip.x) + 4, i32(tip.y) - 8, 16, OVERLAY_FRONT)
	}
}
