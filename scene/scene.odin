package scene

// Block 3: the level file. Without raylib, so it can be tested
// (`odin test scene`) like terrain/ and editor/.
//
// A level is a small JSON file that references the capture and the models; it
// never copies or rewrites them, so it stays tiny, diffs well in git and can be
// read by the game. Paths in it are relative to the level file, with forward
// slashes, so a folder of levels, captures and models can move as a whole.
//
//   {
//     "format": "sandtable-level",
//     "version": 1,
//     "id": "krakow",
//     "title": "krakow",
//     "terrain": "../models/terrain/krakow.spz",
//     "worldScale": 0.005,            world units per metre
//     "terrainCell": 0,               terrain cell in metres, 0 = automatic
//     "maxTilt": 20,                  degrees
//     "nextId": 4,                    ids are never reused, also across sessions
//     "view": { "target": [x, y, z], "azimuth": 45, "viewHeight": 0.8 },
//     "assets": [
//       { "id": "volkswagen_82", "path": "../models/car/volkswagen_82.glb" }
//     ],
//     "objects": [
//       { "id": 1, "asset": "volkswagen_82", "position": [x, y, z], "rotation": [0, 1.5708, 0],
//         "scale": [1, 1, 1], "up": [0, 1, 0], "snap": "ground", "offset": 0, "align": true, "ground": y }
//     ]
//   }
//
// Positions are world units (the capture's own), the pivot at the bottom
// centre of the model; rotation is Euler XYZ in radians; scale 1 is the GLB's
// real size, so metres times worldScale; `up` is the object's tilted +Y (the
// slope it stands on), so a reader without the terrain gets the same pose.
// Objects reference assets by id, so one path change re-points every object.

import "core:fmt"
import "core:math"
import "core:strings"
import "core:encoding/json"

import "../editor"

FORMAT  :: "sandtable-level"
VERSION :: 1

Asset_Ref :: struct {
	id:   string,
	path: string, // relative to the level file
}

Object :: struct {
	id:       u64,
	asset:    string, // an Asset_Ref id
	position: [3]f32,
	rotation: [3]f32,
	scale:    [3]f32,
	up:       [3]f32,
	snap:     string, // "ground", "surface" or "plane"
	offset:   f32,
	align:    bool,
	ground:   f32,
}

View :: struct {
	target:      [3]f32,
	azimuth:     f32 `json:"azimuth"`,
	view_height: f32 `json:"viewHeight"`,
}

Level :: struct {
	format:       string,
	version:      int,
	id:           string,
	title:        string,
	terrain:      string, // relative to the level file
	world_scale:  f32 `json:"worldScale"`,
	terrain_cell: f32 `json:"terrainCell"`,
	max_tilt:     f32 `json:"maxTilt"`, // degrees
	next_id:      u64 `json:"nextId"`,
	view:         Maybe(View),
	assets:       []Asset_Ref,
	objects:      []Object,
}

// Everything a Level allocated: decode's strings and slices, or build's.
destroy :: proc(l: ^Level) {
	for a in l.assets {
		delete(a.id)
		delete(a.path)
	}
	for o in l.objects {
		delete(o.asset)
		delete(o.snap)
	}
	delete(l.assets)
	delete(l.objects)
	delete(l.format)
	delete(l.id)
	delete(l.title)
	delete(l.terrain)
	l^ = {}
}

// ---------------------------------------------------------------------------
// Snap modes as text
// ---------------------------------------------------------------------------

snap_name :: proc(s: editor.Snap) -> string {
	switch s {
	case .Ground:  return "ground"
	case .Surface: return "surface"
	case .Plane:   return "plane"
	}
	return "ground"
}

snap_from_name :: proc(name: string) -> (s: editor.Snap, ok: bool) {
	switch name {
	case "ground", "": return .Ground, true // missing: the default
	case "surface":    return .Surface, true
	case "plane":      return .Plane, true
	}
	return .Ground, false
}

// ---------------------------------------------------------------------------
// Writing. By hand rather than json.marshal: a fixed key order, one object
// per line, so a moved car is a one-line diff.
// ---------------------------------------------------------------------------

encode :: proc(l: Level, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	w :: strings.write_string

	w(&b, "{\n")
	fmt.sbprintf(&b, "  \"format\": %s,\n", quote(FORMAT))
	fmt.sbprintf(&b, "  \"version\": %d,\n", VERSION)
	fmt.sbprintf(&b, "  \"id\": %s,\n", quote(l.id))
	fmt.sbprintf(&b, "  \"title\": %s,\n", quote(l.title))
	fmt.sbprintf(&b, "  \"terrain\": %s,\n", quote(l.terrain))
	fmt.sbprintf(&b, "  \"worldScale\": %s,\n", num(l.world_scale))
	fmt.sbprintf(&b, "  \"terrainCell\": %s,\n", num(l.terrain_cell))
	fmt.sbprintf(&b, "  \"maxTilt\": %s,\n", num(l.max_tilt))
	fmt.sbprintf(&b, "  \"nextId\": %d,\n", l.next_id)
	if v, ok := l.view.?; ok {
		fmt.sbprintf(&b, "  \"view\": {{ \"target\": %s, \"azimuth\": %s, \"viewHeight\": %s }},\n",
			vec(v.target), num(v.azimuth), num(v.view_height))
	}

	w(&b, "  \"assets\": [")
	for a, i in l.assets {
		w(&b, "\n" if i == 0 else ",\n")
		fmt.sbprintf(&b, "    {{ \"id\": %s, \"path\": %s }}", quote(a.id), quote(a.path))
	}
	w(&b, "\n  ],\n" if len(l.assets) > 0 else "],\n")

	w(&b, "  \"objects\": [")
	for o, i in l.objects {
		w(&b, "\n" if i == 0 else ",\n")
		fmt.sbprintf(&b,
			"    {{ \"id\": %d, \"asset\": %s, \"position\": %s, \"rotation\": %s, \"scale\": %s, \"up\": %s, \"snap\": %s, \"offset\": %s, \"align\": %v, \"ground\": %s }}",
			o.id, quote(o.asset), vec(o.position), vec(o.rotation), vec(o.scale), vec(o.up),
			quote(o.snap), num(o.offset), o.align, num(o.ground),
		)
	}
	w(&b, "\n  ]\n" if len(l.objects) > 0 else "]\n")
	w(&b, "}\n")
	return strings.to_string(b)
}

// Shortest text that reads back as the same f32. NaN and infinities are not
// JSON: written as 0.
@(private)
num :: proc(x: f32) -> string {
	if math.is_nan(x) || math.is_inf(x) do return "0"
	if x == 0 do return "0" // also -0
	return fmt.tprint(x)
}

@(private)
vec :: proc(v: [3]f32) -> string {
	return fmt.tprintf("[%s, %s, %s]", num(v.x), num(v.y), num(v.z))
}

@(private)
quote :: proc(s: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_byte(&b, '"')
	for r in s {
		switch r {
		case '"':  strings.write_string(&b, `\"`)
		case '\\': strings.write_string(&b, `\\`)
		case '\n': strings.write_string(&b, `\n`)
		case '\r': strings.write_string(&b, `\r`)
		case '\t': strings.write_string(&b, `\t`)
		case:
			if r < 0x20 {
				fmt.sbprintf(&b, `\u%04x`, int(r))
			} else {
				strings.write_rune(&b, r)
			}
		}
	}
	strings.write_byte(&b, '"')
	return strings.to_string(b)
}

// ---------------------------------------------------------------------------
// Reading
// ---------------------------------------------------------------------------

Decode_Error :: enum {
	None,
	Bad_Json,
	Not_A_Level,       // "format" is missing or something else
	Newer_Version,     // written by a newer sandtable
}

// Parses a level and checks it. Fixes what can be fixed without losing work,
// and says so in `warnings` (temp allocator):
//   - an object without an id, or with one already taken, gets a fresh one
//   - nextId is raised above every id, so ids are never reused
//   - a zero scale becomes 1, a zero `up` upright, an unknown snap "ground"
//   - an object whose asset id is not in "assets" is kept and reported: its
//     model is missing, it is not dropped
decode :: proc(data: []byte, allocator := context.allocator) -> (l: Level, warnings: []string, err: Decode_Error) {
	warn := make([dynamic]string, context.temp_allocator)
	if uerr := json.unmarshal(data, &l, json.DEFAULT_SPECIFICATION, allocator); uerr != nil {
		destroy(&l)
		return {}, nil, .Bad_Json
	}
	if l.format != FORMAT {
		destroy(&l)
		return {}, nil, .Not_A_Level
	}
	if l.version > VERSION {
		destroy(&l)
		return {}, nil, .Newer_Version
	}
	if !(l.world_scale > 0) {
		append(&warn, "worldScale missing: 1")
		l.world_scale = 1
	}
	if !(l.max_tilt > 0) do l.max_tilt = 20

	highest: u64
	for o in l.objects do highest = max(highest, o.id)
	l.next_id = max(l.next_id, highest + 1, 1)

	seen := make(map[u64]bool, len(l.objects), context.temp_allocator)
	for &o in l.objects {
		if o.id == 0 || o.id in seen {
			old := o.id
			o.id = l.next_id
			l.next_id += 1
			append(&warn, fmt.tprintf("object id %d is taken: now %d", old, o.id))
		}
		seen[o.id] = true
		if o.scale == {} do o.scale = {1, 1, 1}
		if o.up == {} do o.up = {0, 1, 0}
		if _, ok := snap_from_name(o.snap); !ok {
			append(&warn, fmt.tprintf("object %d: unknown snap %q, ground", o.id, o.snap))
		}
		if find_asset(l, o.asset) < 0 {
			append(&warn, fmt.tprintf("object %d: asset %q is not in \"assets\"", o.id, o.asset))
		}
	}
	return l, warn[:], .None
}

find_asset :: proc(l: Level, id: string) -> int {
	for a, i in l.assets {
		if a.id == id do return i
	}
	return -1
}

// ---------------------------------------------------------------------------
// Editor <-> level
// ---------------------------------------------------------------------------

// An asset id from a model path: its file name without the extension,
// lower case, anything but [a-z0-9_-] as '_', made unique against `taken`.
asset_id :: proc(path: string, taken: []string, allocator := context.allocator) -> string {
	name := path
	if i := strings.last_index_any(name, "/\\"); i >= 0 do name = name[i + 1:]
	if i := strings.last_index_byte(name, '.'); i >= 0 do name = name[:i]
	b := strings.builder_make(context.temp_allocator)
	for r in strings.to_lower(name, context.temp_allocator) {
		ok := (r >= 'a' && r <= 'z') || (r >= '0' && r <= '9') || r == '_' || r == '-'
		strings.write_rune(&b, r if ok else '_')
	}
	base := strings.to_string(b)
	if len(base) == 0 do base = "model"

	is_taken :: proc(id: string, taken: []string) -> bool {
		for t in taken do if t == id do return true
		return false
	}
	id := base
	for n := 2; is_taken(id, taken); n += 1 {
		id = fmt.tprintf("%s_%d", base, n)
	}
	return strings.clone(id, allocator)
}

// What a level holds apart from the objects; build fills in the rest.
Header :: struct {
	id, title:    string,
	terrain:      string, // already relative to the level file
	world_scale:  f32,
	terrain_cell: f32,
	max_tilt:     f32, // radians, as the editor keeps it
	view:         Maybe(View),
}

// A level from the editor's instances. asset_paths[i] is asset i's path,
// already relative to the level file. Only assets some object uses are
// written. The Level owns its strings (allocator): destroy it.
build :: proc(ed: ^editor.Editor, asset_paths: []string, h: Header, allocator := context.allocator) -> Level {
	context.allocator = allocator
	l := Level{
		format       = strings.clone(FORMAT),
		version      = VERSION,
		id           = strings.clone(h.id),
		title        = strings.clone(h.title),
		terrain      = strings.clone(h.terrain),
		world_scale  = h.world_scale,
		terrain_cell = h.terrain_cell,
		max_tilt     = h.max_tilt * math.DEG_PER_RAD,
		next_id      = max(ed.next_id, 1),
		view         = h.view,
	}

	// asset index -> id, for the assets in use, in order of first use
	ids := make([]string, len(asset_paths), context.temp_allocator)
	assets := make([dynamic]Asset_Ref)
	taken := make([dynamic]string, context.temp_allocator)
	objects := make([dynamic]Object, 0, len(ed.instances))
	for inst in ed.instances {
		ref := ""
		if inst.asset >= 0 && inst.asset < len(asset_paths) {
			if ids[inst.asset] == "" {
				id := asset_id(asset_paths[inst.asset], taken[:])
				ids[inst.asset] = id
				append(&taken, id)
				append(&assets, Asset_Ref{id = id, path = strings.clone(asset_paths[inst.asset])})
			}
			ref = ids[inst.asset]
		}
		t := inst.transform
		append(&objects, Object{
			id       = inst.id,
			asset    = strings.clone(ref),
			position = t.position,
			rotation = t.rotation,
			scale    = t.scale,
			up       = t.up if t.up != {} else {0, 1, 0},
			snap     = strings.clone(snap_name(inst.snap)),
			offset   = inst.offset,
			align    = inst.align,
			ground   = inst.ground,
		})
	}
	l.assets = assets[:]
	l.objects = objects[:]
	return l
}

// Puts a level's objects into the editor, replacing what is there.
// asset_index maps l.assets[i] to the main package's asset index. A model that
// failed to load should still get an index (placement keeps a placeholder
// with its path), so the object keeps its reference and a save loses nothing.
// Ids and nextId carry over.
apply :: proc(l: Level, ed: ^editor.Editor, asset_index: []int) {
	editor.reset(ed)
	for o in l.objects {
		a := find_asset(l, o.asset)
		snap, _ := snap_from_name(o.snap)
		inst := editor.Instance{
			id        = o.id,
			asset     = asset_index[a] if a >= 0 && a < len(asset_index) else -1,
			transform = {position = o.position, rotation = o.rotation, scale = o.scale, up = o.up},
			snap      = snap,
			offset    = o.offset,
			align     = o.align,
			ground    = o.ground,
		}
		append(&ed.instances, inst)
	}
	ed.next_id = max(l.next_id, ed.next_id, 1)
	for inst in ed.instances do ed.next_id = max(ed.next_id, inst.id + 1)
}
