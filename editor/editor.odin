package editor

// Block 2: placement interaction, without raylib, so it can be tested
// (`odin test editor`) like the terrain proxy.
//
// The level is a list of instances. Each one references a model asset by
// index (the assets themselves live in the main package: they are raylib
// meshes) and has its own transform and snap settings. Ids are stable: they
// start at 1, are never reused while the editor lives, and 0 means "none".
//
// Placement is a small state machine rather than ad-hoc mouse checks:
//
//   Select  click an object to select it, click empty ground to deselect.
//           The keyboard edits the selected object.
//   Place   a preview follows the cursor over the terrain; a click commits a
//           copy of it as a new instance and keeps placing (stamping), so a
//           row of cars is a row of clicks. Esc: back to Select.
//   Move    the selected object follows the cursor; a click puts it down,
//           Esc puts it back where it was.
//
//   Select --A--> Place --click--> Place (+1 instance) --Esc--> Select
//   Select --W--> Move  --click--> Select
//                       --Esc----> Select (move undone)
//   any    --Delete--> Select (selected instance removed)

import "core:math"

import "../terrain"

Transform :: struct {
	position: [3]f32, // world position of the pivot (bottom centre of the bounds)
	rotation: [3]f32, // Euler XYZ, radians. Upright objects only use .y
	scale:    [3]f32, // object scale: 1 = the GLB's own size, in metres
	up:       [3]f32, // the object's +Y after the rotation: the ground normal when
	                  // aligned. {0, 1, 0} (or zero): upright
}

// Where an object's height comes from.
Snap :: enum {
	Ground,  // terrain DTM: bare ground, under trees and between buildings
	Surface, // terrain DSM: the top, so roofs and walls
	Plane,   // a horizontal plane at `ground` (Block 1)
}

Instance :: struct {
	id:         u64, // 0 for the preview, which is not in the level yet
	asset:      int, // index into the main package's model assets
	transform:  Transform,
	snap:       Snap,
	offset:     f32,  // terrain snap: height above the terrain, world units
	align:      bool, // terrain snap: tilt to the slope under the footprint
	ground:     f32,  // plane snap: the plane's height. Follows the terrain
	                  // while snapped, so switching to the plane keeps the height
	on_terrain: bool, // the pivot is over the terrain grid (else its edge is extended)
}

Mode :: enum {
	Select,
	Place,
	Move,
}

Editor :: struct {
	instances: [dynamic]Instance, // in creation order
	next_id:   u64,
	mode:      Mode,
	selected:  u64,      // 0: nothing selected
	preview:   Instance, // Place: what a click commits
	backup:    Instance, // Move: the selected instance before the move, for Esc
}

destroy :: proc(e: ^Editor) {
	delete(e.instances)
	e^ = {}
}

// Empties the level (a new cloud is a new level). Ids keep counting up.
reset :: proc(e: ^Editor) {
	clear(&e.instances)
	e.mode = .Select
	e.selected = 0
	e.preview = {}
	e.backup = {}
}

find :: proc(e: ^Editor, id: u64) -> (inst: ^Instance, index: int) {
	if id == 0 do return nil, -1
	for &it, i in e.instances {
		if it.id == id do return &it, i
	}
	return nil, -1
}

// Adds a copy of `inst` with a fresh id. Pointers into e.instances do not
// survive this (the array may grow): look instances up again by id.
add :: proc(e: ^Editor, inst: Instance) -> u64 {
	if e.next_id == 0 do e.next_id = 1
	n := inst
	n.id = e.next_id
	e.next_id += 1
	append(&e.instances, n)
	return n.id
}

// Removes an instance, keeping the others in order. A removed selection is
// cleared.
remove :: proc(e: ^Editor, id: u64) -> bool {
	_, i := find(e, id)
	if i < 0 do return false
	ordered_remove(&e.instances, i)
	if e.selected == id do e.selected = 0
	return true
}

// Selects an instance; 0 or an unknown id deselects. Only in Select mode: in
// Place and Move a click commits instead.
select :: proc(e: ^Editor, id: u64) {
	if e.mode != .Select do return
	if inst, _ := find(e, id); inst != nil {
		e.selected = id
	} else {
		e.selected = 0
	}
}

selected :: proc(e: ^Editor) -> ^Instance {
	inst, _ := find(e, e.selected)
	return inst
}

// What the keyboard edits: the preview while placing, the selected instance
// otherwise (moving or not). nil if nothing.
active :: proc(e: ^Editor) -> ^Instance {
	if e.mode == .Place do return &e.preview
	return selected(e)
}

// Starts placing copies of `template` (its id is ignored). A move in progress
// is cancelled first, so the object goes back to where it was.
begin_place :: proc(e: ^Editor, template: Instance) {
	if e.mode == .Move do cancel(e)
	e.preview = template
	e.preview.id = 0
	e.mode = .Place
}

// Picks up the selected instance. false if nothing is selected.
begin_move :: proc(e: ^Editor) -> bool {
	if e.mode == .Move do return true
	inst := selected(e)
	if inst == nil do return false
	e.backup = inst^
	e.mode = .Move
	return true
}

// Place: adds the preview as a new instance, selects it and keeps placing.
// Move: puts the object down and goes back to Select.
// Returns the id of the instance committed, 0 in Select mode.
commit :: proc(e: ^Editor) -> u64 {
	switch e.mode {
	case .Place:
		id := add(e, e.preview)
		e.selected = id
		return id
	case .Move:
		e.mode = .Select
		return e.selected
	case .Select:
	}
	return 0
}

// Esc. Place: stop placing. Move: undo the move. Select: deselect.
cancel :: proc(e: ^Editor) {
	switch e.mode {
	case .Place:
		e.mode = .Select
	case .Move:
		if inst := selected(e); inst != nil do inst^ = e.backup
		e.mode = .Select
	case .Select:
		e.selected = 0
	}
}

// Deletes the selected instance, also mid-move. false if nothing is selected.
// Placing goes on: Delete while placing removes the last one stamped.
delete_selected :: proc(e: ^Editor) -> bool {
	if e.selected == 0 do return false
	if e.mode == .Move do e.mode = .Select
	return remove(e, e.selected)
}

// ---------------------------------------------------------------------------
// Snapping (Block 5), per instance
// ---------------------------------------------------------------------------

snapped :: proc(inst: Instance, has_terrain: bool) -> bool {
	return inst.snap != .Plane && has_terrain
}

snap_layer :: proc(s: Snap) -> terrain.Layer {
	return .Surface if s == .Surface else .Ground
}

// Height (and with align, tilt) from the terrain under the footprint. Call
// every frame, after the instance has moved: it follows the terrain. Without
// a terrain, or in plane mode, it stands on its plane.
//
//   size_m       the object's size in metres (its asset's bounds * scale)
//   world_scale  world units per metre
//   max_tilt     radians
settle :: proc(
	inst: ^Instance, size_m: [3]f32, world_scale, max_tilt: f32,
	ter: terrain.Terrain, has_terrain: bool,
) {
	t := &inst.transform
	if !snapped(inst^, has_terrain) {
		t.position.y = inst.ground
		t.up = {0, 1, 0}
		inst.on_terrain = false
		return
	}
	half := size_m.xz * world_scale * 0.5
	h, n, inside := terrain.fit_footprint(
		ter, t.position.xz, half, t.rotation.y, snap_layer(inst.snap),
		max_tilt if inst.align else 0,
	)
	t.position.y = h + inst.offset
	t.up = n if inst.align else {0, 1, 0}
	inst.on_terrain = inside
	inst.ground = h
}

// Yaw kept in [0, 2pi), so printed and saved angles are stable.
wrap_yaw :: proc(yaw: f32) -> f32 {
	y := math.mod(yaw, 2 * math.PI)
	if y < 0 do y += 2 * math.PI
	return y
}
