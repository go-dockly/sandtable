package main

// Block 3 glue: the level file (scene/scene.odin) on the raylib side.
//
//   sandtable levels/krakow/level.json      reopen a level: capture, models,
//                                           objects, world scale and view
//   sandtable krakow.spz --level my.json    start from a capture, save to my.json
//                                           (loaded instead if it exists)
//   sandtable krakow.spz                    saves to levels/krakow/level.json
//
// A level's folder: see scene.default_level_path.
//
//   ctrl+S (cmd+S)   save
//   ctrl+R (cmd+R)   reload from disk, dropping unsaved changes
//   ctrl+E (cmd+E)   export the Commandos mission (scene/game.odin), the map
//                    and the terrain into the level's build/
//   drop a .json     open that level
//
// Never loses work by accident: a level that exists but was not opened is
// only overwritten on a second ctrl+S, unsaved changes are only dropped on a
// second ctrl+R, and closing the window with unsaved changes writes them to
// <level>.autosave.json, next to the level.

import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:os"
import "core:strings"
import "core:time"

import rl "vendor:raylib"

import "../mapgen"
import "../terrain"
import "../scene"

Level_State :: struct {
	path:      string, // where ctrl+S writes; owned
	saved:     string, // the level as last loaded / saved, without the view; owned. "" none
	ours:      bool,   // path was opened or written here (or does not exist): ctrl+S may write it
	id, title: string, // owned
	game:      Maybe(scene.Game), // the Commandos export; its strings owned
	map_section: Maybe(scene.Map_Section), // the gameplay map: cell, yaw, edits; owned
	pixel:     Maybe(scene.Pixel), // the game camera's art size and zoom band; nil: from framing
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
	level_set_game(lv, nil)
	level_set_map(lv, nil)
	lv^ = {}
}

// Replaces the game section (a copy is kept).
level_set_game :: proc(lv: ^Level_State, g: Maybe(scene.Game)) {
	if old, ok := lv.game.?; ok {
		delete(old.mission)
		delete(old.base)
	}
	lv.game = nil
	if n, ok := g.?; ok {
		n.mission = strings.clone(n.mission)
		n.base = strings.clone(n.base)
		lv.game = n
	}
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
		lv.id = strings.clone(scene.level_id(path))
		lv.title = strings.clone(lv.id)
	}
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
		game         = lv.game,
		map_section  = lv.map_section,
		pixel        = lv.pixel,
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
	lv.id = strings.clone(l.id if len(l.id) > 0 else scene.level_id(path))
	lv.title = strings.clone(l.title if len(l.title) > 0 else lv.id)
	level_set_game(lv, l.game)
	level_set_map(lv, l.map_section)
	lv.pixel = l.pixel
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
	level_set_game(lv, nil)
	level_set_map(lv, nil)
	lv.pixel = nil
	level_set_path(lv, scene.default_level_path(cloud_path, context.temp_allocator))
}

// ---------------------------------------------------------------------------
// Commandos export
// ---------------------------------------------------------------------------

// The level's game section, or the one the first export will create: the
// mission in the level's build/ (merged into mission.base.json next to the
// level if that exists) and the whole terrain as the region.
level_game :: proc(lv: ^Level_State, p: ^Placement, wt: World_Terrain) -> (g: scene.Game, ok: bool) {
	if have, has := lv.game.?; has do return have, true
	g.mission = scene.build_file("mission.json")
	g.base = "mission.base.json"
	if wt.ok {
		g.origin, g.size = scene.default_region(wt.t, p.world_scale)
		return g, true
	}
	// no terrain: around the objects, 20 m to spare
	if len(p.ed.instances) == 0 do return {}, false
	lo, hi := [2]f32{max(f32), max(f32)}, [2]f32{-max(f32), -max(f32)}
	for inst in p.ed.instances {
		q := inst.transform.position.xz
		lo = {min(lo.x, q.x), min(lo.y, q.y)}
		hi = {max(hi.x, q.x), max(hi.y, q.y)}
	}
	margin := 20 * p.world_scale
	g.origin = lo - margin
	g.size = {math.ceil((hi.x - lo.x + 2 * margin) / p.world_scale), math.ceil((hi.y - lo.y + 2 * margin) / p.world_scale)}
	return g, true
}

// Where the cursor is in game units, for typing spawns and patrols into the
// base mission.
level_cursor_game :: proc(lv: ^Level_State, p: ^Placement, wt: World_Terrain) -> Maybe([2]f32) {
	if !p.cursor_ok do return nil
	g, ok := level_game(lv, p, wt)
	if !ok do return nil
	// with a map (its yaw kept in the level), map metres: what the mission
	// is written in
	if sec, has := lv.map_section.?; has {
		if yaw, has_yaw := sec.yaw.?; has_yaw {
			f := mapgen.frame_for(g.origin, g.size, yaw, p.world_scale, wt.t.lo if wt.ok else 0)
			return scene.export_to_game(g, p.world_scale, f, p.cursor.xz)
		}
	}
	return scene.to_game(g, p.world_scale, p.cursor.xz)
}

// Navigation scans the grid (commandos nav/navigation.odin): past this many
// cells a guard's replanning gets slow. A hint, not a limit.
NAV_CELLS_HINT :: 200 * 200

// ctrl+E: writes the mission, and the gameplay map next to it. The level
// keeps the game section (region and paths) and the map's yaw, so the next
// export maps to the same coordinates; save the level to keep them.
level_export :: proc(lv: ^Level_State, p: ^Placement, cloud_path: string, wt: World_Terrain, wm: ^World_Map, shader: rl.Shader) {
	g, ok := level_game(lv, p, wt)
	if !ok {
		level_say(lv, true, "export: no terrain and no objects, nothing to map")
		return
	}
	mission_path := scene.resolve(lv.path, g.mission, context.temp_allocator)
	base_path := scene.resolve(lv.path, g.base, context.temp_allocator) if len(g.base) > 0 else ""

	base: json.Value
	has_base := len(base_path) > 0 && os.exists(base_path)
	if has_base {
		data, err := os.read_entire_file(base_path, context.temp_allocator)
		if err != nil {
			level_say(lv, true, "export: cannot read %s (%v): nothing written", base_path, err)
			return
		}
		v, vok := scene.parse_mission(data, context.temp_allocator)
		if !vok {
			level_say(lv, true, "export: %s is not a JSON object: nothing written", base_path)
			return
		}
		base = v
	}

	objects := make([dynamic]scene.Export_Object, 0, len(p.ed.instances), context.temp_allocator)
	for inst in p.ed.instances {
		e := scene.Export_Object{
			id       = inst.id,
			position = inst.transform.position,
			rotation = inst.transform.rotation,
			scale    = inst.transform.scale,
			up       = inst.transform.up,
		}
		if a := asset_of(p, inst); a != nil {
			e.asset = scene.relative(mission_path, a.path, context.temp_allocator)
			e.size_m = a.size // 0 for a missing model: a prop without a footprint
		}
		append(&objects, e)
	}

	// the gameplay map first, so the mission can point at it
	map_rel := ""
	map_note := ""
	if world_map_build(wm, lv, p, wt, shader) {
		rel, merr := world_map_export(wm, lv, mission_path)
		if merr != .None {
			map_note = fmt.tprintf("map not written: %v", merr)
		} else {
			map_rel = rel
			map_note = fmt.tprintf("map %s: %d buildings, %d trees%s", rel, wm.stats.buildings, wm.stats.trees,
				fmt.tprintf(", %d edit problems", wm.problems) if wm.problems > 0 else "")
		}
	}

	text, stats := scene.export_mission(scene.Export_Input{
		game         = g,
		world_scale  = p.world_scale,
		ground       = wt.t.lo if wt.ok else 0,
		ter          = wt.t if wt.ok else {},
		objects      = objects[:],
		base         = base,
		id           = lv.id,
		title        = lv.title,
		source_level = scene.relative(mission_path, lv.path, context.temp_allocator),
		terrain_path = scene.relative(mission_path, cloud_path, context.temp_allocator),
		map_path     = map_rel,
		map_frame    = wm.m.frame if map_rel != "" else nil,
		pixel        = lv.pixel,
	}, context.temp_allocator)
	if err := write_level(mission_path, text); err != nil {
		level_say(lv, true, "export %s failed: %v", mission_path, err)
		return
	}
	new_section := lv.game == nil
	level_set_game(lv, g)

	notes := make([dynamic]string, context.temp_allocator)
	if !has_base do append(&notes, fmt.tprintf("no %s: no guards or objective yet", g.base))
	if stats.outside > 0 do append(&notes, fmt.tprintf("%d object%s outside the region", stats.outside, "" if stats.outside == 1 else "s"))
	if stats.grid_w * stats.grid_h > NAV_CELLS_HINT do append(&notes, fmt.tprintf("%dx%d m: large for the game's navigation, shrink \"size\" in the level", stats.grid_w, stats.grid_h))
	if new_section do append(&notes, "region set: ctrl+S keeps it")
	if len(map_note) > 0 do append(&notes, map_note)
	// the terrain beside them, for tools/mapgen_check (not in git)
	if wt.ok {
		prefix := scene.resolve(lv.path, scene.build_file("terrain"), context.temp_allocator)
		names, terr := terrain.export(wt.t, prefix, p.world_scale)
		if terr != nil {
			append(&notes, fmt.tprintf("terrain not written: %v", terr))
		} else {
			for n in names do delete(n)
		}
	}
	level_say(lv, false, "exported %s: %d props, %d cover, %d buildings, %dx%d m%s%s",
		mission_path, stats.props, stats.cover, stats.buildings, stats.grid_w, stats.grid_h,
		" | " if len(notes) > 0 else "", strings.join(notes[:], " | ", context.temp_allocator))
}
