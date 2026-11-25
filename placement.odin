package main

// Block 1 placement: one GLB object on a horizontal ground plane, driven from
// the keyboard and the command line. No mouse picking yet (Block 2) and no
// terrain sampling (Block 5): the plane is a single height, a first guess taken
// from the cloud that the user corrects by eye.
//
//   I J K L        move along the ground, relative to the view (shift: faster)
//   Y H            raise / lower the ground plane (the object stays on it)
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

Transform :: struct {
	position: [3]f32, // world position of the pivot (bottom centre of the bounds)
	rotation: [3]f32, // Euler XYZ, radians. Upright objects only use .y
	scale:    [3]f32, // object scale: 1 = the GLB's own size, in metres
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
}

// Command line. The cloud is the first argument that is not a flag.
//
//   odin run . -- ../ospz/models/krakow.spz --model assets/models/car/volkswagen_typ-82.glb
//                 [--world-scale u] [--pos x,y,z] [--yaw degrees] [--scale s] [--ground y]
//
// --world-scale is world units per metre (default 1). --pos sets the ground
// plane to its y. --ground alone keeps x/z at the cloud centre.
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
}

parse_options :: proc(args: []string) -> (o: Options, ok: bool) {
	o.scale = 1
	o.world_scale = 1
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
	}
}

ROTATE_STEP        :: f32(15)
ROTATE_STEP_COARSE :: f32(90)

// extent: the cloud's size, so movement speed scales with the capture.
placement_update :: proc(p: ^Placement, camera: rl.Camera3D, extent: f32, dt: f32) {
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

	if rl.IsKeyDown(.Y) do p.ground += speed
	if rl.IsKeyDown(.H) do p.ground -= speed
	p.transform.position.y = p.ground

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
	return fmt.aprintf(
		"--world-scale %.6f --pos %s,%s,%s --yaw %.1f --scale %.3f",
		p.world_scale,
		fmt.tprintf(f, t.position.x), fmt.tprintf(f, t.position.y), fmt.tprintf(f, t.position.z),
		yaw, t.scale.x,
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

// w, h: size of the drawn picture in screen pixels (art size * pixel size)
draw_placement_overlay :: proc(a: Model_Asset, p: Placement, view_m, proj_m: rl.Matrix, w, h: f32) {
	vp := proj_m * view_m
	t := p.transform
	g := p.ground

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
		overlay_line(vp, w, h, {c.x - half, g, c.z + o}, {c.x + half, g, c.z + o}, OVERLAY_GRID)
		overlay_line(vp, w, h, {c.x + o, g, c.z - half}, {c.x + o, g, c.z + half}, OVERLAY_GRID)
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

	// pivot cross on the ground, and the model's +Z as its "front"
	arm := foot * 0.15
	overlay_line(vp, w, h, c - {arm, 0, 0}, c + {arm, 0, 0}, OVERLAY_PIVOT, 2)
	overlay_line(vp, w, h, c - {0, 0, arm}, c + {0, 0, arm}, OVERLAY_PIVOT, 2)
	front := to_world(world, a.pivot + {0, 0, a.size.z * 0.5 + a.size.z * 0.25})
	overlay_line(vp, w, h, c, front, OVERLAY_FRONT, 2)
	if tip, ok := project_point(vp, w, h, front); ok {
		rl.DrawText("+Z", i32(tip.x) + 4, i32(tip.y) - 8, 16, OVERLAY_FRONT)
	}
}
