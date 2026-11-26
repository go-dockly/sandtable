package main

// Placement: GLB objects in the level, driven by the mouse, the keyboard and
// the command line.
//
// Block 1 stood one object on a horizontal ground plane. Block 5 stands it on
// the terrain proxy (terrain/terrain.odin): the height under its footprint and,
// with alignment on, the slope. Block 2 makes it a level: any number of
// instances of any number of loaded GLBs, placed and picked with the mouse.
// The state machine, the picking maths and the snapping are in editor/ (no
// raylib, `odin test editor`); this file is the raylib side: input, assets,
// drawing, overlay.
//
// Mouse
//   move           Place / Move: the object follows the cursor over the terrain
//   left-click     Place: put down a copy (and keep placing)
//                  Move: put the object down
//                  Select: select the object under the cursor, or deselect
//   (a left-drag still turns the camera: a press only clicks if the cursor
//    moved less than editor.CLICK_SLOP pixels)
//
// Keys
//   A              place: copies of the selected object (or of the last one)
//   W              move the selected object with the mouse
//   Delete / Bksp  delete the selected object
//   Esc            stop placing / undo the move / deselect
//   O              next loaded model for the selected object or the preview
//   ctrl+Z         undo (cmd+Z on a Mac); ctrl+shift+Z or ctrl+Y: redo
//   drop a .glb    load it and start placing it
//
// The keyboard edits the preview while placing, otherwise the selection:
//   I J K L        move along the ground, relative to the view (shift: faster).
//                  Select mode only: in Place and Move the mouse moves it
//   Y H            plane: raise / lower the object's plane
//                  terrain: raise / lower the object above the terrain (offset)
//   Z              snap: ground (DTM) / surface (DSM, roofs) / plane
//   U              align the object to the slope under it / keep it upright
//   , .            rotate 15 degrees left / right (shift: 90)
//   N M            object scale down / up (shift: faster)
//   T              back to the start transform (the command line's)
//   F              print it as command-line flags (shift+F: every object)
// Global:
//   ctrl+N M       world scale down / up: calibrate the capture against a
//                  known-size object (a car is ~4 m), then keep the value
//   B              overlay: ground grid, bounds of every object, pivot, +Z forward
//   V              hide / show the objects

import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:slice"
import "core:strconv"
import "core:strings"

import rl "vendor:raylib"

import "../editor"
import "../terrain"

Transform :: editor.Transform
Snap :: editor.Snap
Instance :: editor.Instance

Placement :: struct {
	ed:          editor.Editor,
	assets:      [dynamic]Model_Asset, // instances refer to these by index
	world_scale: f32,                  // world units per metre, for every object
	max_tilt:    f32,                  // radians
	overlay:     bool,
	visible:     bool,
	start:       Instance, // the command line's placement: the first object, and T
	template:    Instance, // what A places with nothing selected: the last placed
	click:       editor.Click,
	hover:       u64,    // Select: the object under the cursor, 0 if none
	cursor:      [3]f32, // where the cursor meets the ground
	cursor_ok:   bool,
}

// Splat captures are not in metres (Krakow: ~0.005 units per metre), GLBs are.
// world_scale bridges the two, so objects keep scale 1 at real size and sizes
// can be shown in metres.

// Command line. The cloud is the first argument that is not a flag.
//
//   odin run app -out:sandtable -collection:cmd=../commandos -- ../ospz/models/krakow.spz --model assets/models/car/volkswagen_typ-82.glb
//                 [--world-scale u] [--pos x,y,z] [--yaw degrees] [--scale s] [--ground y]
//                 [--snap ground|surface|plane] [--offset y] [--align] [--max-tilt degrees]
//                 [--cell metres] [--terrain-export prefix] [--level file.json]
//                 [--bench seconds] [--bench-out stats.json]
//   odin run app -out:sandtable -collection:cmd=../commandos -- levels/krakow/level.json    (a level: its capture, models and objects)
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
	level:       string, // level file: opened if it exists, saved to (ctrl+S)
	level_arg:   bool,   // the level was the positional argument: it must exist
	bench:       f32,    // seconds of the speed test (bench.odin); 0 none
	bench_out:   string, // where its stats go
}

DEFAULT_MAX_TILT :: f32(20) // degrees; steeper than any street, flatter than a kerb edge


parse_options :: proc(args: []string) -> (o: Options, ok: bool) {
	o.scale = 1
	o.world_scale = 1
	o.max_tilt = DEFAULT_MAX_TILT
	o.bench_out = "bench.json"
	ok = true
	i := 0
	for i < len(args) {
		arg := args[i]
		i += 1
		if !strings.has_prefix(arg, "--") {
			if strings.has_suffix(strings.to_lower(arg, context.temp_allocator), ".json") && len(o.level) == 0 {
				o.level, o.level_arg = arg, true
			} else if len(o.cloud) == 0 {
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
		case "--bench":
			v, vok := strconv.parse_f32(value)
			if !vok || v <= 0 {
				fmt.eprintf("--bench %q: expected seconds\n", value)
				ok = false
			} else {
				o.bench = v
			}
		case "--bench-out":
			o.bench_out = value
		case "--level":
			o.level = value
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

// A new level: empties it and, if a model is loaded, stands the first object
// where the command line says, otherwise at the cloud centre on the guessed
// ground, selected.
placement_reset :: proc(p: ^Placement, o: Options, v: Splat_View) {
	ground := ground_guess(v.pos)
	if o.has_ground do ground = o.ground
	position := [3]f32{v.center.x, ground, v.center.z}
	if o.has_pos {
		position = o.pos
		ground = o.pos.y
	}
	p.world_scale = o.world_scale
	p.max_tilt = o.max_tilt * math.RAD_PER_DEG
	p.start = Instance{
		asset     = 0,
		transform = {
			position = position,
			rotation = {0, editor.wrap_yaw(o.yaw * math.RAD_PER_DEG), 0},
			scale    = {o.scale, o.scale, o.scale},
			up       = {0, 1, 0},
		},
		snap      = o.snap,
		offset    = o.offset,
		align     = o.align,
		ground    = ground,
	}
	p.template = p.start
	p.hover = 0
	editor.reset(&p.ed)
	if len(p.assets) > 0 {
		p.ed.selected = editor.add(&p.ed, p.start)
	}
}

placement_destroy :: proc(p: ^Placement) {
	for &a in p.assets do release_model_asset(&a)
	delete(p.assets)
	editor.destroy(&p.ed)
	p^ = {}
}

// Loads a GLB, or finds it already loaded: instances share their asset.
placement_load_asset :: proc(p: ^Placement, path: string, shader: rl.Shader) -> (index: int, ok: bool) {
	for &a, i in p.assets {
		if a.path != path do continue
		if !a.missing do return i, true
		// a level's model that was missing: try again, in its place, so the
		// objects that use it get it
		m := load_model_asset(path, shader) or_return
		release_model_asset(&a)
		a = m
		return i, true
	}
	a := load_model_asset(path, shader) or_return
	append(&p.assets, a)
	return len(p.assets) - 1, true
}

asset_of :: proc(p: ^Placement, inst: Instance) -> ^Model_Asset {
	if inst.asset < 0 || inst.asset >= len(p.assets) do return nil
	return &p.assets[inst.asset]
}

// Every loaded model's colours, for the extracted palette. Temp allocator.
placement_colors :: proc(p: ^Placement) -> [][4]u8 {
	if len(p.assets) == 1 do return p.assets[0].colors
	out := make([dynamic][4]u8, context.temp_allocator)
	for a in p.assets do append(&out, ..a.colors)
	return out[:]
}

// Something to draw: an object in the level, or the preview.
placement_has_objects :: proc(p: ^Placement) -> bool {
	return len(p.ed.instances) > 0 || p.ed.mode == .Place
}

// Every object (and the preview) on the terrain under it. Every frame: they
// follow the terrain as they move, and a world scale or terrain change.
placement_settle :: proc(p: ^Placement, ter: terrain.Terrain, has_terrain: bool) {
	for &inst in p.ed.instances {
		a := asset_of(p, inst)
		if a == nil do continue
		editor.settle(&inst, object_size_m(a^, inst.transform), p.world_scale, p.max_tilt, ter, has_terrain)
	}
	if p.ed.mode == .Place {
		if a := asset_of(p, p.ed.preview); a != nil {
			editor.settle(&p.ed.preview, object_size_m(a^, p.ed.preview.transform), p.world_scale, p.max_tilt, ter, has_terrain)
		}
	}
}

// Model-space bounds, the pivot at the bottom centre.
asset_bounds :: proc(a: Model_Asset) -> (lo, hi: [3]f32) {
	lo = a.pivot - {a.size.x * 0.5, 0, a.size.z * 0.5}
	hi = a.pivot + {a.size.x * 0.5, a.size.y, a.size.z * 0.5}
	return
}

// How far behind the first surface the cursor meets an object may still be
// picked, metres: a car under a low canopy or against a wall stays clickable,
// one behind a building does not.
PICK_OCCLUSION_M :: f32(2)

placement_pick :: proc(p: ^Placement, ray: editor.Ray, t_surface: f32) -> u64 {
	cands := make([dynamic]editor.Candidate, 0, len(p.ed.instances), context.temp_allocator)
	for inst in p.ed.instances {
		a := asset_of(p, inst)
		if a == nil || a.model.meshCount <= 0 do continue
		lo, hi := asset_bounds(a^)
		append(&cands, editor.Candidate{id = inst.id, world = model_matrix(a^, inst.transform, p.world_scale), lo = lo, hi = hi})
	}
	max_t := max(f32)
	if t_surface < max(f32) do max_t = t_surface + PICK_OCCLUSION_M * p.world_scale
	id, _ := editor.pick(ray, cands[:], max_t)
	return id
}

// The mouse, once a frame, after the camera has moved. ray: the cursor's ray
// through the scene as drawn (see main), ray_ok false when the cursor is off
// the picture.
placement_mouse :: proc(
	p: ^Placement, ray: editor.Ray, ray_ok: bool, mouse: [2]f32,
	ter: terrain.Terrain, has_terrain: bool,
) {
	clicked := editor.click_update(&p.click, rl.IsMouseButtonDown(.LEFT), mouse)
	p.cursor_ok = false
	p.hover = 0
	if !ray_ok || len(p.assets) == 0 do return

	plane_y := p.start.ground
	if act := editor.active(&p.ed); act != nil do plane_y = act.ground
	cursor, t_surface, ok := editor.cursor_point(ray, ter, has_terrain, plane_y)
	p.cursor, p.cursor_ok = cursor, ok

	switch p.ed.mode {
	case .Place, .Move:
		act := editor.active(&p.ed)
		if act != nil && ok do act.transform.position.xz = cursor.xz
		if clicked && ok {
			editor.commit(&p.ed)
			if p.ed.mode == .Place do p.template = p.ed.preview
		}
	case .Select:
		if p.visible do p.hover = placement_pick(p, ray, t_surface)
		if clicked do editor.select(&p.ed, p.hover)
	}
}

// Starts placing `template`, at the cursor if it is on the ground.
placement_begin_place :: proc(p: ^Placement, template: Instance) {
	t := template
	if p.cursor_ok do t.transform.position.xz = p.cursor.xz
	editor.begin_place(&p.ed, t)
}

ROTATE_STEP        :: f32(15)
ROTATE_STEP_COARSE :: f32(90)

// The keyboard, once a frame, before the mouse.
// extent: the cloud's size, so movement speed scales with the capture.
// has_terrain: Y/H move the offset above it rather than the plane.
placement_keys :: proc(p: ^Placement, camera: rl.Camera3D, extent: f32, dt: f32, has_terrain: bool) {
	shift := rl.IsKeyDown(.LEFT_SHIFT) || rl.IsKeyDown(.RIGHT_SHIFT)
	ctrl := rl.IsKeyDown(.LEFT_CONTROL) || rl.IsKeyDown(.RIGHT_CONTROL)
	cmd := ctrl || rl.IsKeyDown(.LEFT_SUPER) || rl.IsKeyDown(.RIGHT_SUPER)

	// ---- undo / redo ---------------------------------------------------------
	if cmd && rl.IsKeyPressed(.Z) {
		if shift {
			editor.redo(&p.ed)
		} else {
			editor.undo(&p.ed)
		}
		p.hover = 0
		return
	}
	if cmd && rl.IsKeyPressed(.Y) {
		editor.redo(&p.ed)
		p.hover = 0
		return
	}

	// ---- editor actions --------------------------------------------------
	if rl.IsKeyPressed(.A) && len(p.assets) > 0 {
		template := p.template
		if sel := editor.selected(&p.ed); sel != nil do template = sel^
		placement_begin_place(p, template)
	}
	if rl.IsKeyPressed(.W) do editor.begin_move(&p.ed)
	if rl.IsKeyPressed(.DELETE) || rl.IsKeyPressed(.BACKSPACE) do editor.delete_selected(&p.ed)
	if rl.IsKeyPressed(.ESCAPE) do editor.cancel(&p.ed)

	// ---- global ------------------------------------------------------------
	// exponential, so a held key feels the same at any size: x2 per second
	rate := f32(math.LN2) * dt * (f32(4) if shift else f32(1))
	factor: f32 = 1
	if rl.IsKeyDown(.M) do factor = math.exp(rate)
	if rl.IsKeyDown(.N) do factor = math.exp(-rate)
	if ctrl do p.world_scale *= factor // calibrating the capture
	if rl.IsKeyPressed(.B) do p.overlay = !p.overlay
	if rl.IsKeyPressed(.V) do p.visible = !p.visible
	if rl.IsKeyPressed(.F) && shift {
		for inst in p.ed.instances {
			fmt.printf("#%d %s\n", inst.id, instance_flags(p, inst, context.temp_allocator))
		}
	}

	// ---- the active object: the preview, or the selection -------------------
	act := editor.active(&p.ed)
	if act == nil do return

	// An edit of an object in the level is an undo step, taken at the key
	// press: holding a key for a second is one step. (The preview is not in
	// the level: placing it is the step.)
	if p.ed.mode != .Place && !cmd {
		pressed := false
		for k in ([?]rl.KeyboardKey{.I, .J, .K, .L, .Y, .H, .Z, .U, .COMMA, .PERIOD, .T, .O}) {
			if rl.IsKeyPressed(k) do pressed = true
		}
		if !ctrl && (rl.IsKeyPressed(.N) || rl.IsKeyPressed(.M)) do pressed = true
		if pressed {
			editor.checkpoint(&p.ed)
			act = editor.active(&p.ed)
		}
	}
	// held keys below: none of them with ctrl / cmd, which belong to the
	// shortcuts (ctrl+Y redo, ctrl+N/M world scale)

	if rl.IsKeyPressed(.O) && len(p.assets) > 1 do act.asset = (act.asset + 1) % len(p.assets)

	speed := extent * 0.1 * dt * (f32(5) if shift else f32(1))
	if p.ed.mode == .Select { // in Place and Move the mouse moves it
		// view direction flattened onto the ground: I moves "up the screen"
		f := camera.target - camera.position
		f.y = 0
		if linalg.vector_length(f) < 1e-6 do f = {0, 0, -1}
		f = linalg.normalize(f)
		r := [3]f32{-f.z, 0, f.x}
		move: [3]f32
		if rl.IsKeyDown(.I) do move += f
		if rl.IsKeyDown(.K) do move -= f
		if rl.IsKeyDown(.L) do move += r
		if rl.IsKeyDown(.J) do move -= r
		act.transform.position += move * speed
	}

	// Y/H: the plane, or the height above the terrain (slower: it is a fine
	// correction, a few centimetres for a car's tyres)
	if editor.snapped(act^, has_terrain) {
		fine := speed * 0.1
		if rl.IsKeyDown(.Y) && !cmd do act.offset += fine
		if rl.IsKeyDown(.H) && !cmd do act.offset -= fine
	} else {
		if rl.IsKeyDown(.Y) && !cmd do act.ground += speed
		if rl.IsKeyDown(.H) && !cmd do act.ground -= speed
		act.transform.position.y = act.ground
	}
	if rl.IsKeyPressed(.Z) && !shift && !cmd do act.snap = Snap((int(act.snap) + 1) % len(Snap))
	if rl.IsKeyPressed(.U) do act.align = !act.align

	step := (ROTATE_STEP_COARSE if shift else ROTATE_STEP) * math.RAD_PER_DEG
	if rl.IsKeyPressed(.COMMA) do act.transform.rotation.y += step // counter-clockwise seen from above
	if rl.IsKeyPressed(.PERIOD) do act.transform.rotation.y -= step
	act.transform.rotation.y = editor.wrap_yaw(act.transform.rotation.y)

	if !cmd do act.transform.scale *= factor

	if rl.IsKeyPressed(.T) {
		// the start transform and snap settings; the model stays
		s := p.start
		act.transform, act.snap, act.offset, act.align, act.ground = s.transform, s.snap, s.offset, s.align, s.ground
	}
	if rl.IsKeyPressed(.F) && !shift do fmt.println(instance_flags(p, act^, context.temp_allocator))
}

// An object as the command-line flags that reproduce it.
instance_flags :: proc(p: ^Placement, inst: Instance, allocator := context.allocator) -> string {
	t := inst.transform
	yaw := editor.wrap_yaw(t.rotation.y) * math.DEG_PER_RAD
	f := world_fmt(p.world_scale)
	snap := " --snap plane"
	if inst.snap != .Plane {
		snap = fmt.tprintf(
			" --snap %s --offset %s%s --max-tilt %.0f",
			"ground" if inst.snap == .Ground else "surface",
			fmt.tprintf(f, inst.offset), " --align" if inst.align else "", p.max_tilt * math.DEG_PER_RAD,
		)
	}
	model := ""
	if a := asset_of(p, inst); a != nil do model = fmt.tprintf("--model %s ", a.path)
	return fmt.aprintf(
		"%s--world-scale %.6f --pos %s,%s,%s --yaw %.1f --scale %.3f%s",
		model, p.world_scale,
		fmt.tprintf(f, t.position.x), fmt.tprintf(f, t.position.y), fmt.tprintf(f, t.position.z),
		yaw, t.scale.x, snap,
		allocator = allocator,
	)
}

// Every object, and the preview, into the scene pass (see main).
placement_draw :: proc(p: ^Placement) {
	if !p.visible do return
	for inst in p.ed.instances {
		if a := asset_of(p, inst); a != nil do model_draw(a^, inst.transform, p.world_scale)
	}
	if p.ed.mode == .Place {
		if a := asset_of(p, p.ed.preview); a != nil do model_draw(a^, p.ed.preview.transform, p.world_scale)
	}
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
//
// Always: the selection's bounds, the preview's (or the object being moved),
// and the object under the cursor. With B: every object's bounds, and the
// ground grid, pivot and +Z of the active one.
// ---------------------------------------------------------------------------

OVERLAY_GRID     :: rl.Color{120, 200, 255, 90}
OVERLAY_BOUNDS   :: rl.Color{255, 220, 90, 90}   // other objects, with B
OVERLAY_SELECTED :: rl.Color{255, 220, 90, 255}
OVERLAY_PREVIEW  :: rl.Color{110, 230, 255, 255} // placing, or moving
OVERLAY_HOVER    :: rl.Color{255, 255, 255, 200}
OVERLAY_PIVOT    :: rl.Color{255, 90, 90, 255}
OVERLAY_FRONT    :: rl.Color{120, 255, 140, 255}

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

to_world :: proc(m: rl.Matrix, q: [3]f32) -> [3]f32 {
	r := m * [4]f32{q.x, q.y, q.z, 1}
	return r.xyz
}

// The model-space bounds, through the full object transform.
overlay_bounds :: proc(a: Model_Asset, t: Transform, world_scale: f32, vp: rl.Matrix, w, h: f32, col: rl.Color, thick: f32) {
	if a.model.meshCount <= 0 do return
	world := model_matrix(a, t, world_scale)
	lo, hi := asset_bounds(a)
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
		overlay_line(vp, w, h, corners[e[0]], corners[e[1]], col, thick)
	}
}

// Ground grid around the object in whole metres (grid_cell_m), so the world
// scale can be checked against the object at a glance; its pivot cross and the
// model's +Z as its "front".
overlay_details :: proc(
	a: Model_Asset, inst: Instance, world_scale: f32, vp: rl.Matrix, w, h: f32,
	ter: terrain.Terrain, has_terrain: bool,
) {
	t := inst.transform
	drape := editor.snapped(inst, has_terrain)
	layer := editor.snap_layer(inst.snap)
	size_m := object_size_m(a, t)
	foot_m := max(size_m.x, size_m.z)
	if foot_m <= 0 do foot_m = 1
	cell_m := grid_cell_m(foot_m * 2)
	n := int(math.ceil(foot_m * 2 / cell_m))
	cell := cell_m * world_scale
	half := f32(n) * cell
	c := t.position
	for k in -n ..= n {
		o := f32(k) * cell
		overlay_ground_line(vp, w, h, {c.x - half, c.z + o}, {c.x + half, c.z + o}, inst.ground, ter, layer, drape, OVERLAY_GRID)
		overlay_ground_line(vp, w, h, {c.x + o, c.z - half}, {c.x + o, c.z + half}, inst.ground, ter, layer, drape, OVERLAY_GRID)
	}

	if a.model.meshCount <= 0 do return
	foot := foot_m * world_scale
	world := model_matrix(a, t, world_scale)
	arm := foot * 0.15 / max(t.scale.x * world_scale, 1e-12) // model units
	pv := a.pivot
	overlay_line(vp, w, h, to_world(world, pv - {arm, 0, 0}), to_world(world, pv + {arm, 0, 0}), OVERLAY_PIVOT, 2)
	overlay_line(vp, w, h, to_world(world, pv - {0, 0, arm}), to_world(world, pv + {0, 0, arm}), OVERLAY_PIVOT, 2)
	front := to_world(world, a.pivot + {0, 0, a.size.z * 0.5 + a.size.z * 0.25})
	overlay_line(vp, w, h, c, front, OVERLAY_FRONT, 2)
	if tip, ok := project_point(vp, w, h, front); ok {
		rl.DrawText("+Z", i32(tip.x) + 4, i32(tip.y) - 8, 16, OVERLAY_FRONT)
	}
}

// w, h: size of the drawn picture in screen pixels (art size * pixel size)
draw_placement_overlay :: proc(
	p: ^Placement, view_m, proj_m: rl.Matrix, w, h: f32,
	ter: terrain.Terrain, has_terrain: bool,
) {
	if !p.visible do return
	vp := proj_m * view_m
	moving := p.ed.mode == .Move
	for inst in p.ed.instances {
		a := asset_of(p, inst)
		if a == nil do continue
		switch {
		case inst.id == p.ed.selected:
			overlay_bounds(a^, inst.transform, p.world_scale, vp, w, h, OVERLAY_PREVIEW if moving else OVERLAY_SELECTED, 2)
		case inst.id == p.hover:
			overlay_bounds(a^, inst.transform, p.world_scale, vp, w, h, OVERLAY_HOVER, 1)
		case p.overlay:
			overlay_bounds(a^, inst.transform, p.world_scale, vp, w, h, OVERLAY_BOUNDS, 1)
		}
	}
	if p.ed.mode == .Place {
		if a := asset_of(p, p.ed.preview); a != nil {
			overlay_bounds(a^, p.ed.preview.transform, p.world_scale, vp, w, h, OVERLAY_PREVIEW, 2)
		}
	}
	if p.overlay {
		if act := editor.active(&p.ed); act != nil {
			if a := asset_of(p, act^); a != nil do overlay_details(a^, act^, p.world_scale, vp, w, h, ter, has_terrain)
		}
	}
}
