package main

// Block 3 glue: the level file (scene/scene.odin) on the raylib side.
//
//   sandtable levels/krakow.json            reopen a level: capture, models,
//                                           objects, world scale and view
//   sandtable krakow.spz --level my.json    start from a capture, save to my.json
//                                           (loaded instead if it exists)
//   sandtable krakow.spz                    saves to levels/krakow.json
//
//   ctrl+S (cmd+S)   save
//   ctrl+R (cmd+R)   reload from disk, dropping unsaved changes
//   drop a .json     open that level
//
// Never loses work by accident: a level that exists but was not opened is
// only overwritten on a second ctrl+S, unsaved changes are only dropped on a
// second ctrl+R, and closing the window with unsaved changes writes them to
// <level>.autosave.json, next to the level.

import "core:fmt"
import "core:math"
import "core:os"
import "core:strings"
import "core:time"

import rl "vendor:raylib"

import "scene"

Level_State :: struct {
	path:      string, // where ctrl+S writes; owned
	saved:     string, // the level as last loaded / saved, without the view; owned. "" none
	ours:      bool,   // path was opened or written here (or does not exist): ctrl+S may write it
	id, title: string, // owned
	confirm:   enum { None, Overwrite, Discard }, // waiting for the second press (CONFIRM_S)
	confirm_at: time.Time,
	baseline:  bool, // just loaded: take `saved` after the objects have settled
	message:   [256]u8,
	msg_len:   int,
	msg_at:    time.Time,
	msg_bad:   bool,
}

level_destroy :: proc(lv: ^Level_State) {
	delete(lv.path)
	delete(lv.saved)
	delete(lv.id)
	delete(lv.title)
	lv^ = {}
}

level_say :: proc(lv: ^Level_State, bad: bool, format: string, args: ..any) {
	s := fmt.bprintf(lv.message[:], format, ..args)
	lv.msg_len = len(s)
	lv.msg_at = time.now()
	lv.msg_bad = bad
	if bad {
		fmt.eprintln(s)
	} else {
		fmt.println(s)
	}
}

// Sets where the level is saved; ours: whether it may be written without
// asking. A level that is there but was not opened is pointed out.
level_set_path :: proc(lv: ^Level_State, path: string) {
	delete(lv.path)
	lv.path = strings.clone(path)
	lv.ours = !os.exists(path)
	lv.confirm = .None
	if !lv.ours {
		level_say(lv, true, "%s exists but is not open: drop it on the window to open it (ctrl+S asks before overwriting)", path)
	}
	if len(lv.id) == 0 {
		lv.id = strings.clone(filepath_stem(path))
		lv.title = strings.clone(lv.id)
	}
}

filepath_stem :: proc(path: string) -> string {
	name := path
	if i := strings.last_index_any(name, "/\\"); i >= 0 do name = name[i + 1:]
	if i := strings.last_index_byte(name, '.'); i > 0 do name = name[:i]
	return name
}

// Reads and checks a level file; prints what it fixed. false: not usable (the
// reason is printed), and nothing should be written over it.
level_read :: proc(path: string) -> (l: scene.Level, ok: bool) {
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		fmt.eprintf("level %s: cannot read it (%v)\n", path, err)
		return {}, false
	}
	defer delete(data)
	lvl, warnings, derr := scene.decode(data)
	switch derr {
	case .None:
	case .Bad_Json:
		fmt.eprintf("level %s: not valid JSON\n", path)
		return {}, false
	case .Not_A_Level:
		fmt.eprintf("level %s: not a sandtable level (no \"format\": %q)\n", path, scene.FORMAT)
		return {}, false
	case .Newer_Version:
		fmt.eprintf("level %s: written by a newer sandtable (version > %d)\n", path, scene.VERSION)
		return {}, false
	}
	for w in warnings do fmt.eprintf("level %s: %s\n", path, w)
	return lvl, true
}

// The level as it would be written now. view nil: for comparing (a camera
// move is not an unsaved change). Temp allocator.
level_text :: proc(lv: ^Level_State, p: ^Placement, cloud_path: string, cell_m: f32, view: Maybe(scene.View)) -> string {
	context.allocator = context.temp_allocator
	paths := make([]string, len(p.assets))
	for a, i in p.assets do paths[i] = scene.relative(lv.path, a.path)
	h := scene.Header{
		id           = lv.id,
		title        = lv.title,
		terrain      = scene.relative(lv.path, cloud_path),
		world_scale  = p.world_scale,
		terrain_cell = cell_m,
		max_tilt     = p.max_tilt,
		view         = view,
	}
	l := scene.build(&p.ed, paths, h)
	return scene.encode(l)
}

CONFIRM_S :: 4 // a second press counts within this many seconds

// true if this is the second press; otherwise arms it.
level_confirmed :: proc(lv: ^Level_State, what: type_of(Level_State{}.confirm)) -> bool {
	if lv.confirm == what && time.duration_seconds(time.since(lv.confirm_at)) < CONFIRM_S {
		lv.confirm = .None
		return true
	}
	lv.confirm = what
	lv.confirm_at = time.now()
	return false
}

level_dirty :: proc(lv: ^Level_State, p: ^Placement, cloud_path: string, cell_m: f32) -> bool {
	now := level_text(lv, p, cloud_path, cell_m, nil)
	if len(lv.saved) == 0 do return len(p.ed.instances) > 0 // nothing on disk yet
	return now != lv.saved
}

iso_view :: proc(iso: Iso) -> scene.View {
	return scene.View{target = iso.target, azimuth = iso.azimuth, view_height = iso.view_height}
}

// Writes the level, via a temporary file and a rename, so a crash mid-write
// leaves the old file whole.
write_level :: proc(path, text: string) -> os.Error {
	dir := scene.level_dir(path)
	if dir != "." && !os.exists(dir) do os.make_directory_all(dir) or_return
	tmp := strings.concatenate({path, ".tmp"}, context.temp_allocator)
	os.write_entire_file(tmp, transmute([]byte)text) or_return
	return os.rename(tmp, path)
}

// ctrl+S.
level_save :: proc(lv: ^Level_State, p: ^Placement, cloud_path: string, cell_m: f32, iso: Iso) {
	if !lv.ours && !level_confirmed(lv, .Overwrite) {
		level_say(lv, true, "%s exists and was not opened here: ctrl+S again to overwrite it", lv.path)
		return
	}
	text := level_text(lv, p, cloud_path, cell_m, iso_view(iso))
	if err := write_level(lv.path, text); err != nil {
		level_say(lv, true, "save %s failed: %v", lv.path, err)
		return
	}
	delete(lv.saved)
	lv.saved = strings.clone(level_text(lv, p, cloud_path, cell_m, nil))
	lv.ours = true
	lv.confirm = .None
	n := len(p.ed.instances)
	level_say(lv, false, "saved %s: %d object%s", lv.path, n, "" if n == 1 else "s")
}

// Closing with unsaved changes: they go next to the level, not over it.
level_autosave :: proc(lv: ^Level_State, p: ^Placement, cloud_path: string, cell_m: f32, iso: Iso) {
	if len(lv.path) == 0 || !level_dirty(lv, p, cloud_path, cell_m) do return
	path := scene.autosave_path(lv.path, context.temp_allocator)
	// paths inside are relative to the level's folder, which is the same
	text := level_text(lv, p, cloud_path, cell_m, iso_view(iso))
	if err := write_level(path, text); err != nil {
		fmt.eprintf("unsaved changes: writing %s failed: %v\n", path, err)
		return
	}
	fmt.printf("unsaved changes written to %s (open it, or rename it over %s)\n", path, lv.path)
}

// Puts a level into the placement: its models (a model that does not load
// becomes a placeholder that keeps its path, so the objects keep their
// reference and a save loses nothing), objects, ids, world scale and tilt.
// Returns how many models are missing.
placement_apply_level :: proc(p: ^Placement, l: scene.Level, level_path: string, shader: rl.Shader) -> (missing: int) {
	index := make([]int, len(l.assets), context.temp_allocator)
	for a, i in l.assets {
		path := scene.resolve(level_path, a.path, context.temp_allocator)
		if idx, ok := placement_load_asset(p, path, shader); ok {
			index[i] = idx
		} else {
			index[i] = placement_add_placeholder(p, path)
			missing += 1
		}
	}
	scene.apply(l, &p.ed, index)
	p.world_scale = l.world_scale
	p.max_tilt = l.max_tilt * math.RAD_PER_DEG
	p.hover = 0
	p.ed.selected = 0
	// A places more of the first object's model, as it was set up
	if len(p.ed.instances) > 0 {
		p.template = p.ed.instances[0]
		p.template.id = 0
	}
	return
}

// A model that could not be loaded: no mesh, just its path. Drawn and picked as
// nothing, saved as it was.
placement_add_placeholder :: proc(p: ^Placement, path: string) -> int {
	for a, i in p.assets {
		if a.path == path do return i
	}
	append(&p.assets, Model_Asset{path = strings.clone(path), missing = true})
	return len(p.assets) - 1
}

// One line under the HUD: where the level goes and whether it is saved, and
// the last message for a few seconds.
draw_level_hud :: proc(lv: ^Level_State, dirty: bool, missing: int, x, y: i32) {
	state := "unsaved changes" if dirty else ("saved" if len(lv.saved) > 0 else "not saved yet")
	col := rl.Color{230, 170, 90, 255} if dirty else rl.Color{150, 200, 150, 255}
	miss := fmt.tprintf(" | %d model%s missing (kept in the level)", missing, "" if missing == 1 else "s") if missing > 0 else ""
	rl.DrawText(
		fmt.ctprintf("level %s | %s%s | [ctrl+S] save  [ctrl+R] reload", lv.path, state, miss),
		x, y, 16, col,
	)
	if lv.msg_len > 0 && time.duration_seconds(time.since(lv.msg_at)) < CONFIRM_S {
		mc := rl.Color{230, 110, 90, 255} if lv.msg_bad else rl.Color{230, 230, 230, 255}
		rl.DrawText(fmt.ctprintf("%s", string(lv.message[:lv.msg_len])), x, y + 20, 16, mc)
	}
}

// Opens a level: its capture (if not the one loaded), its terrain (if the
// world scale or cell differ), models, objects and view. Nothing changes if it
// cannot be read or its capture cannot be loaded.
open_level :: proc(
	path: string,
	view: ^Splat_View, cloud_path: ^string, free_cam: ^rl.Camera3D, iso: ^Iso,
	p: ^Placement, wt: ^World_Terrain, lv: ^Level_State, shader: rl.Shader,
	keep_cloud := false, // the capture was given on the command line: it wins
) -> (missing: int, ok: bool) {
	l := level_read(path) or_return
	defer scene.destroy(&l)

	cloud := scene.resolve(path, l.terrain, context.temp_allocator)
	new_cloud := !keep_cloud && len(cloud) > 0 && !scene.same_path(cloud, cloud_path^)
	if new_cloud {
		next, e := load_view(cloud)
		if e != .None {
			level_say(lv, true, "level %s: capture %s: %v", path, cloud, e)
			return 0, false
		}
		release_view(view)
		view^ = next
		delete(cloud_path^)
		cloud_path^ = strings.clone(cloud)
		frame_views(free_cam, iso, view^)
	}
	if new_cloud || wt.cell_m != l.terrain_cell || abs(wt.built_scale / l.world_scale - 1) > 1e-6 || !wt.ok {
		wt.cell_m = l.terrain_cell
		world_terrain_build(wt, view^, l.world_scale, shader)
	}

	missing = placement_apply_level(p, l, path, shader)
	if v, has := l.view.?; has && v.view_height > 0 {
		iso.target, iso.azimuth = v.target, v.azimuth
		iso.view_height = clamp(v.view_height, iso.min_height, iso.max_height)
	}

	delete(lv.path)
	lv.path = strings.clone(path)
	lv.ours = true
	lv.confirm = .None
	delete(lv.id)
	delete(lv.title)
	lv.id = strings.clone(l.id if len(l.id) > 0 else filepath_stem(path))
	lv.title = strings.clone(l.title if len(l.title) > 0 else lv.id)
	lv.baseline = true
	n := len(p.ed.instances)
	level_say(lv, missing > 0, "opened %s: %d object%s%s", path, n, "" if n == 1 else "s",
		fmt.tprintf(", %d model%s missing", missing, "" if missing == 1 else "s") if missing > 0 else "")
	return missing, true
}

// A new capture dropped on the window is a new level: it saves to the
// capture's default level, not over the level that was open.
level_new :: proc(lv: ^Level_State, cloud_path: string) {
	delete(lv.saved)
	delete(lv.id)
	delete(lv.title)
	lv.saved, lv.id, lv.title = {}, {}, {}
	level_set_path(lv, scene.default_level_path(cloud_path, context.temp_allocator))
}
