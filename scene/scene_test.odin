package scene

// odin test scene

import "core:math"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

import "../editor"
import "cmd:gamemap"

car :: proc(x, z: f32, asset: int) -> editor.Instance {
	return editor.Instance{
		asset     = asset,
		transform = {position = {x, 0.0123456, z}, rotation = {0, 1.5707964, 0}, scale = {1, 1, 1}, up = {0.05, 0.99875, 0}},
		snap      = .Ground,
		offset    = 0.00025,
		align     = true,
		ground    = 0.0123456,
	}
}

header :: proc() -> Header {
	return Header{
		id = "krakow", title = "Krakow \"old town\"", terrain = "../models/terrain/krakow.spz",
		world_scale = 0.005, terrain_cell = 0, max_tilt = 20 * math.RAD_PER_DEG,
		view = View{target = {1, 2, 3}, azimuth = 45, view_height = 0.8},
	}
}

// Three cars of two models, one deleted: what Block 2 leaves behind.
three_cars :: proc(ed: ^editor.Editor) {
	editor.add(ed, car(0.1, 0.2, 0))
	gone := editor.add(ed, car(0.3, 0.4, 0))
	editor.add(ed, car(0.5, 0.6, 1))
	editor.add(ed, car(0.7, 0.8, 0))
	editor.remove(ed, gone)
	ed.instances[2].snap = .Surface
	ed.instances[2].align = false
	ed.instances[1].transform.scale = {1.25, 1.25, 1.25}
}

PATHS :: []string{"../models/car/volkswagen_82.glb", "../models/car/kubelwagen.glb", "../models/unused.glb"}

@(test)
round_trip :: proc(t: ^testing.T) {
	ed: editor.Editor
	defer editor.destroy(&ed)
	three_cars(&ed)

	l := build(&ed, PATHS, header())
	defer destroy(&l)
	testing.expect(t, len(l.assets) == 2, "only the models in use")
	testing.expect(t, l.assets[0].id == "volkswagen_82" && l.assets[1].id == "kubelwagen")
	testing.expect(t, l.next_id == 5, "nextId past the deleted one")

	text := encode(l)
	defer delete(text)

	back, warnings, err := decode(transmute([]byte)text)
	defer destroy(&back)
	testing.expectf(t, err == .None, "decode: %v\n%s", err, text)
	testing.expectf(t, len(warnings) == 0, "warnings: %v", warnings)
	testing.expect(t, back.title == `Krakow "old town"`)
	testing.expect(t, back.terrain == "../models/terrain/krakow.spz")
	testing.expect(t, back.world_scale == 0.005 && back.next_id == 5)
	testing.expect(t, abs(back.max_tilt - 20) < 1e-4)
	v, has_view := back.view.?
	testing.expect(t, has_view && v.target == {1, 2, 3} && v.azimuth == 45 && v.view_height == 0.8)

	// into a fresh editor: the same instances, exactly
	ed2: editor.Editor
	defer editor.destroy(&ed2)
	apply(back, &ed2, {0, 1})
	testing.expect(t, len(ed2.instances) == len(ed.instances))
	for a, i in ed.instances {
		b := ed2.instances[i]
		testing.expectf(t, a == b, "object %d:\n  saved  %v\n  loaded %v", i, a, b)
	}
	// saving again writes the same text: a reload and save is no diff
	l2 := build(&ed2, PATHS, header())
	defer destroy(&l2)
	text2 := encode(l2)
	defer delete(text2)
	testing.expectf(t, text == text2, "not stable across a round trip:\n%s\n---\n%s", text, text2)

	// and ids go on where they left off
	testing.expect(t, editor.add(&ed2, car(0, 0, 0)) == 5)
}

@(test)
one_object_per_line :: proc(t: ^testing.T) {
	ed: editor.Editor
	defer editor.destroy(&ed)
	three_cars(&ed)
	l := build(&ed, PATHS, header())
	defer destroy(&l)
	text := encode(l)
	defer delete(text)
	n := 0
	for line in strings.split_lines(text, context.temp_allocator) {
		if strings.contains(line, `"position"`) {
			n += 1
			testing.expect(t, strings.contains(line, `"id"`) && strings.contains(line, `"ground"`), line)
		}
	}
	testing.expect(t, n == 3)

	empty: editor.Editor
	le := build(&empty, nil, header())
	defer destroy(&le)
	te := encode(le)
	defer delete(te)
	testing.expect(t, strings.contains(te, `"objects": []`), te)
	back, _, err := decode(transmute([]byte)te)
	defer destroy(&back)
	testing.expect(t, err == .None && len(back.objects) == 0)
}

@(test)
repairs_on_load :: proc(t: ^testing.T) {
	text := `{
	  "format": "sandtable-level", "version": 1, "worldScale": 0.005, "nextId": 2,
	  "assets": [{"id": "vw", "path": "vw.glb"}],
	  "objects": [
	    {"id": 7, "asset": "vw", "position": [1, 2, 3]},
	    {"id": 7, "asset": "vw", "snap": "roof"},
	    {"asset": "tank"},
	    {"id": 3, "asset": "vw", "scale": [2, 2, 2], "futureField": {"x": 1}}
	  ],
	  "futureSection": [1, 2]
	}`
	l, warnings, err := decode(transmute([]byte)text)
	defer destroy(&l)
	testing.expect(t, err == .None)
	ids := [4]u64{l.objects[0].id, l.objects[1].id, l.objects[2].id, l.objects[3].id}
	testing.expectf(t, ids == {7, 8, 9, 3}, "ids %v: duplicates and missing ones get fresh ids above all", ids)
	testing.expect(t, l.next_id == 10)
	testing.expect(t, l.objects[0].scale == {1, 1, 1} && l.objects[0].up == {0, 1, 0}, "defaults")
	testing.expect(t, l.objects[3].scale == {2, 2, 2})
	testing.expectf(t, len(warnings) == 4, "warnings: %v", warnings) // 2 ids, the snap, the asset

	ed: editor.Editor
	defer editor.destroy(&ed)
	apply(l, &ed, {0})
	testing.expect(t, ed.instances[1].snap == .Ground, "unknown snap: ground")
	testing.expect(t, ed.instances[2].asset == -1, "unknown asset: kept, without a model")
	testing.expect(t, editor.add(&ed, {}) == 10)
}

@(test)
rejects_what_is_not_a_level :: proc(t: ^testing.T) {
	cases := [?]struct{ text: string, want: Decode_Error }{
		{`{"version": 1}`, .Not_A_Level},
		{`{"format": "something-else", "version": 1}`, .Not_A_Level},
		{`{"format": "sandtable-level", "version": 99}`, .Newer_Version},
		{`{"format": "sandtable-level", "objects": [`, .Bad_Json},
		{`not json`, .Bad_Json},
	}
	for c in cases {
		l, _, err := decode(transmute([]byte)c.text)
		destroy(&l)
		testing.expectf(t, err == c.want, "%q: %v, want %v", c.text, err, c.want)
	}
}

@(test)
asset_ids :: proc(t: ^testing.T) {
	id := asset_id("models/car/Volkswagen Typ-82.GLB", nil, context.temp_allocator)
	testing.expectf(t, id == "volkswagen_typ-82", "%q", id)
	taken := []string{"crate", "crate_2"}
	id = asset_id(`C:\props\crate.glb`, taken, context.temp_allocator)
	testing.expectf(t, id == "crate_3", "%q", id)
	id = asset_id(".glb", nil, context.temp_allocator)
	testing.expectf(t, id == "model", "%q", id)
}

@(test)
paths_relative_to_the_level :: proc(t: ^testing.T) {
	testing.expect(t, relative("levels/krakow.json", "models/car/vw.glb", context.temp_allocator) == "../models/car/vw.glb")
	testing.expect(t, relative("krakow.json", "models/car/vw.glb", context.temp_allocator) == "models/car/vw.glb")
	testing.expect(t, relative("levels/a/b.json", "levels/a/vw.glb", context.temp_allocator) == "vw.glb")

	testing.expect(t, resolve("levels/krakow.json", "../models/car/vw.glb", context.temp_allocator) == "models/car/vw.glb")
	testing.expect(t, resolve("krakow.json", "vw.glb", context.temp_allocator) == "vw.glb")
	testing.expect(t, resolve("levels/krakow.json", "/abs/vw.glb", context.temp_allocator) == "/abs/vw.glb")

	// both ways: what a level writes, it reads back as the same file
	for p in ([]string{"models/terrain/krakow.spz", "../ospz/models/tree.ply", "levels/x.glb"}) {
		r := resolve("levels/krakow.json", relative("levels/krakow.json", p, context.temp_allocator), context.temp_allocator)
		testing.expectf(t, r == p, "%q -> %q", p, r)
	}

	testing.expect(t, same_path("./models/terrain/krakow.spz", "models/x/../terrain/krakow.spz"))
	testing.expect(t, !same_path("models/a.spz", "levels/a.spz"))

	testing.expect(t, default_level_path("./models/terrain/krakow.spz", context.temp_allocator) == "levels/krakow.json")
	testing.expect(t, autosave_path("levels/krakow.json", context.temp_allocator) == "levels/krakow.autosave.json")
}

@(test)
save_and_load_a_file :: proc(t: ^testing.T) {
	dir := "scene_test_tmp/levels"
	defer os.remove_all("scene_test_tmp")
	testing.expect(t, os.make_directory_all(dir) == nil)
	path, _ := filepath.join({dir, "krakow.json"}, context.temp_allocator)

	ed: editor.Editor
	defer editor.destroy(&ed)
	three_cars(&ed)
	l := build(&ed, PATHS, header())
	defer destroy(&l)
	text := encode(l)
	defer delete(text)
	testing.expect(t, os.write_entire_file(path, transmute([]byte)text) == nil)

	data, rerr := os.read_entire_file(path, context.allocator)
	defer delete(data)
	testing.expect(t, rerr == nil)
	back, _, err := decode(data)
	defer destroy(&back)
	testing.expect(t, err == .None && len(back.objects) == 3)
}

@(test)
map_section_round_trip :: proc(t: ^testing.T) {
	ed: editor.Editor
	defer editor.destroy(&ed)
	three_cars(&ed)

	h := header()
	region := [][2]f32{{0, 0}, {8, 0}, {8, 8}, {0, 8}}
	h.map_section = Map_Section{
		file = "krakow.map.json",
		cell = 1,
		yaw  = 19.5,
		edits = []gamemap.Edit{
			{id = "e1", kind = .Building, target = "b:31,27", walkable_roof = true, height = 10.5},
			{id = "e2", kind = .Link, link = .Ladder, a = {24, 9.25, 0}, b = {24, 11, 10.5}},
			{id = "e3", kind = .Flatten, region = region, fit = true},
			{id = "e1", kind = .Remove, target = "t:4,4"}, // a taken id
		},
	}
	l := build(&ed, PATHS, h)
	defer destroy(&l)
	text := encode(l)
	defer delete(text)

	// one line per edit, only what it sets
	testing.expect(t, strings.contains(text, `{ "id": "e1", "kind": "Building", "target": "b:31,27", "height": 10.5, "walkableRoof": true }`), text)
	testing.expect(t, strings.contains(text, `{ "id": "e2", "kind": "Link", "link": "Ladder", "a": [24, 9.25, 0], "b": [24, 11, 10.5] }`), text)
	testing.expect(t, strings.contains(text, `"region": [[0, 0], [8, 0], [8, 8], [0, 8]], "fit": true }`), text)
	testing.expect(t, strings.contains(text, `"yaw": 19.5`), "the frame's yaw is kept")

	back, warnings, err := decode(transmute([]byte)text)
	defer destroy(&back)
	testing.expect_value(t, err, Decode_Error.None)
	ms, has := back.map_section.?
	testing.expect(t, has, "the map section reads back")
	if !has do return
	testing.expect_value(t, ms.file, "krakow.map.json")
	y, has_yaw := ms.yaw.?
	testing.expect(t, has_yaw && y == 19.5, "yaw")
	testing.expect_value(t, len(ms.edits), 4)
	if len(ms.edits) < 4 do return
	e1 := ms.edits[0]
	testing.expect_value(t, e1.kind, gamemap.Edit_Kind.Building)
	wr, has_wr := e1.walkable_roof.?
	testing.expect(t, has_wr && wr, "walkable roof")
	hh, has_h := e1.height.?
	testing.expect(t, has_h && hh == 10.5, "height")
	testing.expect_value(t, ms.edits[1].link, gamemap.Link_Kind.Ladder)
	testing.expect_value(t, ms.edits[1].b, [3]f32{24, 11, 10.5})
	testing.expect_value(t, len(ms.edits[2].region), 4)
	testing.expect(t, ms.edits[2].fit, "fit")
	testing.expect_value(t, ms.edits[3].id, "e4") // e1 was taken, e2 and e3 too
	testing.expect_value(t, len(warnings), 1)

	// and it writes back the same
	again := encode(back)
	defer delete(again)
	testing.expect(t, strings.count(again, "\"kind\"") == 4, "four edits")
}
