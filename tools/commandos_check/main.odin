package commandos_check

// The Commandos export (scene/game.odin) against the game's own code: a
// synthetic town exported by sandtable, then loaded with commandos'
// mission.load, baked, and walked with its collision and A*. Needs a
// commandos checkout next to sandtable:
//
//   dev/
//     commandos/
//     sandtable/    <- here
//
//   odin run tools/commandos_check -collection:cmd=../commandos -collection:st=.

import "core:fmt"
import "core:math"
import "core:os"

import "st:mapgen"
import "st:scene"
import "st:terrain"
import "cmd:actors"
import "cmd:game"
import "cmd:gamemap"
import "cmd:geom"
import "cmd:mission"
import "cmd:nav"

S :: f32(0.005) // Krakow's world scale
CORNER :: [2]f32{5, -3}

fails := 0
check :: proc(ok: bool, what: string, args: ..any) {
	fmt.printf("%s  ", "ok  " if ok else "FAIL")
	fmt.printfln(what, ..args)
	if !ok do fails += 1
}

main :: proc() {
	// the scene test's town: 60 x 60 m, a 20 x 20 m building 10 m tall at 30..50
	pos: [dynamic][3]f32
	op: [dynamic]f32
	for z := f32(0); z <= 60; z += 0.25 {
		for x := f32(0); x <= 60; x += 0.25 {
			y := f32(0)
			if x >= 30 && x <= 50 && z >= 30 && z <= 50 do y = 10
			if x >= 20 && x <= 21 && z >= 42 && z <= 58 do y = 1.2 // a low wall: not a building, cover
			append(&pos, [3]f32{CORNER.x + x, y, CORNER.y + z} * S)
			append(&op, 1)
		}
	}
	ter, ok := terrain.build(pos[:], op[:], terrain.default_params(S))
	check(ok, "terrain built")
	origin, size := scene.default_region(ter, S)
	g := scene.Game{origin = origin, size = size}
	at := CORNER - origin / S // the town's corner in game units
	fmt.printfln("region %v m, town corner at game %v", size, at)

	// a car west of the building, turned 30 degrees
	car := at + {20, 40}
	cw := scene.to_world(g, S, car)
	objects := []scene.Export_Object{{
		id = 1, asset = "../models/car/volkswagen_82.glb",
		position = {cw.x, 0, cw.y}, rotation = {0, 30 * math.RAD_PER_DEG, 0}, scale = {1, 1, 1}, up = {0, 1, 0},
		size_m = {4.1, 1.5, 1.7},
	}}
	spawn := at + {8, 40}
	exit := at + {57, 40}
	base_text := fmt.tprintf(`{{"id": "town", "playerSpawn": {{"x": %v, "y": %v}}, "extraction": {{"x": %v, "y": %v, "radius": 2}},
	  "guards": [{{"id": "g", "speed": 3, "pauseDuration": 1, "patrol": [{{"x": %v, "y": %v}}, {{"x": %v, "y": %v}}]}}]}}`,
		spawn.x, spawn.y, exit.x, exit.y, at.x + 10, at.y + 10, at.x + 55, at.y + 10)
	base, bok := scene.parse_mission(transmute([]byte)base_text)
	check(bok, "base parsed")

	text, stats := scene.export_mission(scene.Export_Input{
		game = g, world_scale = S, ground = ter.lo, ter = ter, objects = objects, base = base,
		id = "town", title = "Town", source_level = "town.json", terrain_path = "town.spz",
	})
	fmt.printfln("export: %v", stats)
	path := "commandos_check.mission.json"
	defer os.remove(path)
	check(os.write_entire_file(path, transmute([]byte)text) == nil, "written %s", path)

	// ---- the game's side ---------------------------------------------------------
	m, lok := mission.load(path)
	check(lok, "commandos mission.load")
	b := mission.bounds(&m)
	check(b.width == math.ceil(size.x) && b.height == math.ceil(size.y), "bounds %v", b)
	check(len(m.guards) == 1 && m.extraction.radius == 2, "gameplay from the base")
	fmt.printfln("baked: %d solids, %d circles", len(m.geometry.solids), len(m.geometry.circles))
	check(len(m.geometry.solids) == stats.buildings + stats.cover, "every building and cover rect is a solid")

	inside := at + {40, 40}
	check(mission.point_collides(&m, {inside.x, inside.y}, 0.4), "the captured building blocks at %v", inside)
	check(mission.point_collides(&m, {car.x, car.y}, 0.4), "the car blocks at its centre %v", car)
	nose := car + {math.cos(f32(30) * math.RAD_PER_DEG), -math.sin(f32(30) * math.RAD_PER_DEG)} * 1.8
	check(mission.point_collides(&m, {nose.x, nose.y}, 0.1), "and at its turned nose %v", nose)
	beside := car + {0, 3}
	check(!mission.point_collides(&m, {beside.x, beside.y}, 0.4), "the street beside it is open %v", beside)
	check(!mission.point_collides(&m, {spawn.x, spawn.y}, 0.8), "the spawn is open")

	// A*: spawn -> extraction must go round the building, not through it
	p := nav.find_path(&m, {spawn.x, spawn.y}, {exit.x, exit.y}, 0.8)
	check(p.found, "A* finds a way from the spawn to the extraction (%d points)", len(p.points))
	through := false
	length: f32
	for q, i in p.points {
		if q.x > at.x + 30.5 && q.x < at.x + 49.5 && q.y > at.y + 30.5 && q.y < at.y + 49.5 do through = true
		if i > 0 do length += math.hypot(q.x - p.points[i - 1].x, q.y - p.points[i - 1].y)
	}
	check(!through, "the path does not cross the building")
	check(length > (exit.x - spawn.x) + 1, "it detours: %.1f m against %.1f m straight", length, exit.x - spawn.x)
	_ = geom.Point{}

	gameplay_map(ter, g, at)

	fmt.printfln("\n%d failed", fails)
	if fails > 0 do os.exit(1)
}

// The gameplay map (docs/map_spec.md) through the game: sandtable builds the
// map from the same capture, applies a walkable roof and a ladder, writes the
// map and a mission in map metres; commandos loads both and plays the slice:
// a guard sees over the low wall but not someone crouching behind it, and
// the player climbs the ladder onto the roof.
gameplay_map :: proc(ter: terrain.Terrain, g: scene.Game, at: [2]f32) {
	fmt.println("\n-- gameplay map")
	ter := ter
	params := mapgen.default_params()
	m, stats := mapgen.build({terrain = &ter, world_scale = S, origin = g.origin, size = g.size, params = params})
	defer gamemap.destroy(&m)
	fmt.printfln("mapgen: %v", stats)
	check(abs(stats.yaw) < 1, "an axis-aligned town gives yaw 0: %.1f", stats.yaw)
	check(stats.buildings == 1, "the building")
	check(stats.low == 1, "the low wall, from object cells")

	// local town metres -> map metres
	mp :: proc(m: ^gamemap.Map, local: [2]f32) -> [2]f32 {
		w := (CORNER + local) * S
		return gamemap.world_to_map(m.frame, {w.x, 0, w.y}).xy
	}
	// the ladder against the building's west wall as the map has it (its
	// footprint, not the capture's exact edge): foot a cell outside, top a
	// cell inside
	building := ""
	west := max(f32)
	for f in m.features {
		if f.kind != .Building do continue
		building = f.id
		for ring in f.footprint do for q in ring do west = min(west, q.x)
	}
	mid := mp(&m, {29.5, 40.5}).y
	foot, top := [2]f32{west - m.cell * 0.5, mid}, [2]f32{west + m.cell * 0.5, mid}
	problems := gamemap.apply_edits(&m, []gamemap.Edit{
		{id = "e1", kind = .Building, target = building, walkable_roof = true},
		{id = "e2", kind = .Link, link = .Ladder, a = {foot.x, foot.y, 0}, b = {top.x, top.y, 10}},
	}, context.temp_allocator)
	for p in problems do check(false, "edit %s: %s", p.edit, p.message)

	map_path := "commandos_check.map.json"
	check(gamemap.save(m, map_path) == .None, "written %s", map_path)
	defer os.remove(map_path)
	defer os.remove(gamemap.bin_path(map_path, context.temp_allocator))

	spawn := [2]f32{west - 5, mid}
	post := mp(&m, {6.5, 50.5})
	base_text := fmt.tprintf(`{{"id": "slice", "playerSpawn": {{"x": %v, "y": %v}},
	  "guards": [{{"id": "g", "speed": 0, "patrol": [{{"x": %v, "y": %v}}]}}]}}`, spawn.x, spawn.y, post.x, post.y)
	base, _ := scene.parse_mission(transmute([]byte)base_text)
	text, _ := scene.export_mission(scene.Export_Input{
		game = g, world_scale = S, ground = ter.lo, ter = ter, base = base,
		id = "slice", source_level = "town.json", terrain_path = "town.spz",
		map_path = map_path, map_frame = m.frame,
	})
	path := "commandos_check.slice.mission.json"
	defer os.remove(path)
	check(os.write_entire_file(path, transmute([]byte)text) == nil, "written %s", path)

	lvl, ok := mission.load(path)
	check(ok && lvl.has_map, "commandos mission.load with its map")
	if !ok || !lvl.has_map do return
	b := mission.bounds(&lvl)
	check(b.width == f32(m.w) * m.cell, "bounds from the map: %v", b)

	DT :: f32(1.0 / 60)
	run :: proc(w: ^game.World, input: game.Input, seconds: f32) {
		for _ in 0 ..< int(seconds / DT) do game.update(w, input, DT)
	}

	// the guard looks east at the low wall; the player stands, then crouches, behind it
	look :: proc(lvl: mission.Mission, player: [2]f32, crouch: bool) -> bool {
		l := lvl
		l.player_spawn = {player.x, player.y}
		w := game.world_init(l)
		defer actorless_destroy(&w)
		w.guards[0].facing = {1, 0}
		run(&w, {sneak = crouch}, 0.1)
		return w.guards[0].player_visible
	}
	behind := mp(&m, {22.5, 50.5})
	check(look(lvl, behind, false), "the guard sees a man standing behind the 1.2 m wall")
	check(!look(lvl, behind, true), "not one crouching behind it")

	w := game.world_init(lvl)
	defer game.world_destroy(&w)
	run(&w, {move = {1, 0}}, 1)
	update_interact(&w)
	check(w.player.climb.active, "at the wall, E takes the ladder")
	run(&w, {}, 5)
	check(abs(w.player.h - 10) < 0.2, "the player is on the roof: %.2f m", w.player.h)
	before := w.player.position
	run(&w, {move = {1, 0}}, 1)
	check(w.player.position.x > before.x + 3 && abs(w.player.h - 10) < 0.2, "and walks across it")
}

// A world sharing the mission's geometry and map: free its guards only.
actorless_destroy :: proc(w: ^game.World) {
	actors.guards_destroy(w.guards)
	w.guards = nil
}

update_interact :: proc(w: ^game.World) {
	game.update(w, {interact = true}, 1.0 / 60)
}
