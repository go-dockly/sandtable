package scene

// odin test scene: the Commandos export

import "core:encoding/json"
import "core:math"
import "core:math/rand"
import "core:strings"
import "core:testing"

import "../terrain"

// A 60 x 60 m square with a 20 x 20 m, 10 m tall building at x, z 30..50,
// s world units per metre, the capture's corner at world (5, -3) m.
CORNER :: [2]f32{5, -3}

town :: proc(t: ^testing.T, s: f32) -> terrain.Terrain {
	pos: [dynamic][3]f32
	op: [dynamic]f32
	defer delete(pos)
	defer delete(op)
	for z := f32(0); z <= 60; z += 0.25 {
		for x := f32(0); x <= 60; x += 0.25 {
			y := f32(0)
			if x >= 30 && x <= 50 && z >= 30 && z <= 50 do y = 10
			append(&pos, [3]f32{CORNER.x + x, y, CORNER.y + z} * s)
			append(&op, 1)
		}
	}
	ter, ok := terrain.build(pos[:], op[:], terrain.default_params(s))
	testing.expect(t, ok, "terrain build failed")
	return ter
}

@(test)
merged_rects_cover_the_mask_exactly :: proc(t: ^testing.T) {
	state := rand.create(3)
	r := rand.default_random_generator(&state)
	for trial in 0 ..< 50 {
		w, h := 1 + rand.int_max(30, r), 1 + rand.int_max(30, r)
		mask := make([]bool, w * h, context.temp_allocator)
		fill := rand.float32(r)
		for &m in mask do m = rand.float32(r) < fill
		rects := merge_rects(mask, w, h, context.temp_allocator)
		cover := make([]int, w * h, context.temp_allocator)
		for q in rects {
			testing.expect(t, q[2] > 0 && q[3] > 0 && q[0] + q[2] <= w && q[1] + q[3] <= h)
			for j in 0 ..< q[3] do for i in 0 ..< q[2] do cover[(q[1] + j) * w + q[0] + i] += 1
		}
		for m, i in mask {
			want := 1 if m else 0
			testing.expectf(t, cover[i] == want, "trial %d cell %d: covered %d times, set %v", trial, i, cover[i], m)
		}
	}
	// a solid block is one rectangle
	full := []bool{true, true, true, true, true, true}
	testing.expect(t, len(merge_rects(full, 3, 2, context.temp_allocator)) == 1)
}

@(test)
turned_footprints :: proc(t: ^testing.T) {
	// a 4 x 2 m car
	half := [2]f32{2, 1}
	rs := footprint_rects({10, 10}, half, 0, context.temp_allocator)
	testing.expect(t, len(rs) == 1 && rs[0] == Rect{8, 9, 4, 2}, "unturned: exact")
	rs = footprint_rects({10, 10}, half, math.PI / 2, context.temp_allocator)
	testing.expectf(t, len(rs) == 1 && rs[0] == Rect{9, 8, 2, 4}, "quarter turn: swapped, %v", rs)
	rs = footprint_rects({10, 10}, half, -3 * math.PI / 2, context.temp_allocator)
	testing.expectf(t, len(rs) == 1 && rs[0] == Rect{9, 8, 2, 4}, "minus three quarters: %v", rs)

	// 30 degrees: about the right area, everything near the true box
	yaw := f32(30) * math.RAD_PER_DEG
	rs = footprint_rects({10, 10}, half, yaw, context.temp_allocator)
	area: f32
	cs, sn := math.cos(yaw), math.sin(yaw)
	for r in rs {
		area += r.w * r.h
		for c in ([4][2]f32{{r.x, r.y}, {r.x + r.w, r.y}, {r.x, r.y + r.h}, {r.x + r.w, r.y + r.h}}) {
			d := c - {10, 10}
			u, v := cs * d.x - sn * d.y, sn * d.x + cs * d.y
			testing.expectf(t, abs(u) <= half.x + 0.36 && abs(v) <= half.y + 0.36, "corner %v outside the car", c)
		}
	}
	testing.expectf(t, abs(area - 8) < 8 * 0.1, "area %v, the car is 8 m²", area)
	testing.expectf(t, len(rs) < 40, "%d rectangles", len(rs))

	// the long axis follows the yaw: a car turned +30 (MatrixRotateY) points to -z at +x
	far := [2]f32{10 + cs * 1.8, 10 - sn * 1.8} // 1.8 m along its local +x
	inside := false
	for r in rs do if far.x >= r.x && far.x <= r.x + r.w && far.y >= r.y && far.y <= r.y + r.h do inside = true
	testing.expect(t, inside, "turned the wrong way")
}

@(test)
captured_buildings :: proc(t: ^testing.T) {
	for s in ([?]f32{1, 0.005}) {
		ter := town(t, s)
		defer terrain.destroy(&ter)
		origin, size := default_region(ter, s)
		g := Game{origin = origin, size = size}
		testing.expectf(t, size.x >= 60 && size.x <= 66, "scale %v: region %v m (the grid pads a little)", s, size)

		rects, heights := buildings_from_terrain(ter, g, s, context.temp_allocator)
		testing.expectf(t, len(rects) >= 1 && len(rects) <= 4, "scale %v: %d rects", s, len(rects))
		// in game units the building is at its metres minus the region's corner
		at := CORNER - origin / s
		lo, hi := [2]f32{1e9, 1e9}, [2]f32{-1e9, -1e9}
		area: f32
		for r, i in rects {
			lo = {min(lo.x, r.x), min(lo.y, r.y)}
			hi = {max(hi.x, r.x + r.w), max(hi.y, r.y + r.h)}
			area += r.w * r.h
			testing.expectf(t, abs(heights[i] - 10) < 1, "height %v", heights[i])
		}
		testing.expectf(t, abs(lo.x - (at.x + 30)) <= 1.5 && abs(hi.x - (at.x + 50)) <= 1.5, "scale %v: x %v..%v, want %v..%v", s, lo.x, hi.x, at.x + 30, at.x + 50)
		testing.expectf(t, abs(lo.y - (at.y + 30)) <= 1.5 && abs(hi.y - (at.y + 50)) <= 1.5, "scale %v: y %v..%v", s, lo.y, hi.y)
		testing.expectf(t, abs(area - 400) < 60, "scale %v: area %v, want ~400", s, area)

		g.buildings = false
		out, _ := export_mission(Export_Input{game = g, world_scale = s, ter = ter}, context.temp_allocator)
		m: Game_Mission
		testing.expect(t, json.unmarshal(transmute([]byte)out, &m, allocator = context.temp_allocator) == nil)
		testing.expect(t, len(m.buildings) == 0, "buildingsFromTerrain false")
	}
}

// The parts of commandos' mission.Mission (mission/mission.odin) the export
// writes, with the same JSON names.
Game_Point :: struct { x, y: f32 }
Game_Rect :: struct { id: string, x, y, w, h: f32 }
Game_Cover :: struct { kind: string `json:"type"`, x, y, w, h, r: f32 }
Game_Guard :: struct { id: string, speed: f32, pause_duration: f32 `json:"pauseDuration"`, patrol: []Game_Point }
Game_Mission :: struct {
	id:           string,
	bounds:       struct { width, height: f32 } `json:"coordinateSpace"`,
	player_spawn: Game_Point `json:"playerSpawn"`,
	extraction:   struct { x, y, radius: f32 },
	objective:    struct { id: string, kind: string `json:"type"`, x, y: f32 },
	buildings:    []Game_Rect,
	walls:        []Game_Rect,
	cover:        []Game_Cover,
	guards:       []Game_Guard,
	props:        []struct { id: u64, asset: string, x, y, elevation, yaw: f32 },
}

BASE :: `{
  "id": "krakow_01", "title": "Market square", "version": 3,
  "coordinateSpace": {"width": 10, "height": 10},
  "playerSpawn": {"x": 4, "y": 55},
  "extraction": {"x": 55, "y": 5, "radius": 4},
  "objective": {"id": "documents", "type": "retrieve", "x": 40, "y": 28},
  "buildings": [{"id": "kiosk", "x": 2, "y": 2, "w": 3, "h": 3}],
  "walls": [{"id": "fence", "x": 0, "y": 20, "w": 20, "h": 1, "openings": [{"id": "gate", "y": 8, "h": 3}]}],
  "cover": [{"type": "barrel", "x": 10, "y": 10, "r": 1}],
  "guards": [{"id": "g1", "speed": 3, "pauseDuration": 1, "patrol": [{"x": 10, "y": 50}, {"x": 20, "y": 50}]}],
  "routes": [{"id": "r", "points": [{"x": 1, "y": 1}]}],
  "notes": "designer's own"
}`

@(test)
mission_from_a_level :: proc(t: ^testing.T) {
	s := f32(0.005)
	ter := town(t, s)
	defer terrain.destroy(&ter)
	origin, size := default_region(ter, s)
	g := Game{origin = origin, size = size}

	// a car at game (12, 15), turned 90 degrees, and one outside the region
	car_world := to_world(g, s, {12, 15})
	objects := []Export_Object{
		{id = 1, asset = "../models/car/vw.glb", position = {car_world.x, 0.5 * s, car_world.y}, rotation = {0, math.PI / 2, 0},
		 scale = {1, 1, 1}, up = {0, 1, 0}, size_m = {4, 1.5, 2}},
		{id = 2, asset = "../models/car/vw.glb", position = {origin.x - 50 * s, 0, origin.y}, scale = {1, 1, 1}, size_m = {4, 1.5, 2}},
	}
	base, pok := parse_mission(transmute([]byte)string(BASE), context.temp_allocator)
	testing.expect(t, pok)
	_, bad := parse_mission(transmute([]byte)string(`[1, 2]`), context.temp_allocator)
	testing.expect(t, !bad, "a mission is an object")

	out, stats := export_mission(Export_Input{
		game = g, world_scale = s, ground = 0, ter = ter, objects = objects, base = base,
		id = "krakow", title = "krakow", source_level = "../levels/krakow.json", terrain_path = "../models/krakow.spz",
	}, context.temp_allocator)
	testing.expectf(t, stats.props == 1 && stats.outside == 1 && stats.cover == 1 && stats.buildings >= 1, "stats %v", stats)

	m: Game_Mission
	uerr := json.unmarshal(transmute([]byte)out, &m, allocator = context.temp_allocator)
	testing.expectf(t, uerr == nil, "the game cannot read it: %v\n%s", uerr, out)

	testing.expect(t, m.id == "krakow_01", "the base's id")
	testing.expectf(t, m.bounds.width == math.ceil(size.x) && m.bounds.height == math.ceil(size.y), "coordinateSpace %v: the region, not the base's", m.bounds)
	testing.expect(t, m.player_spawn == {4, 55} && m.extraction.radius == 4 && m.objective.id == "documents", "gameplay from the base")
	testing.expect(t, len(m.guards) == 1 && len(m.guards[0].patrol) == 2 && m.guards[0].pause_duration == 1)
	testing.expect(t, len(m.walls) == 1)
	testing.expect(t, m.buildings[0].id == "kiosk" && len(m.buildings) == 1 + stats.buildings, "base buildings first, then the capture's")
	testing.expect(t, m.cover[0].kind == "barrel" && len(m.cover) == 2)
	car := m.cover[1]
	testing.expectf(t, car.kind == "crate" && car == Game_Cover{"crate", 11, 13, 2, 4, 0}, "the car's footprint: %v", car)
	testing.expect(t, len(m.props) == 1 && m.props[0].asset == "../models/car/vw.glb")
	p := m.props[0]
	testing.expectf(t, abs(p.x - 12) < 1e-3 && abs(p.y - 15) < 1e-3 && abs(p.elevation - 0.5) < 1e-3, "prop %v", p)

	// the designer's other keys survive
	v, _ := json.parse(transmute([]byte)out, allocator = context.temp_allocator)
	obj := v.(json.Object)
	testing.expect(t, "routes" in obj && "notes" in obj && "sandtable" in obj)
	testing.expect(t, strings.contains(out, "\"version\": 3,\n"), "the version stays an integer")
	testing.expectf(t, strings.contains(out, `{"id":"g1","patrol":[{"x":10,"y":50},{"x":20,"y":50}],"pauseDuration":1,"speed":3}`), "a guard, one line, as it was\n%s", out)

	// the same input writes the same file
	again, _ := export_mission(Export_Input{
		game = g, world_scale = s, ter = ter, objects = objects, base = base,
		id = "krakow", title = "krakow", source_level = "../levels/krakow.json", terrain_path = "../models/krakow.spz",
	}, context.temp_allocator)
	testing.expect(t, again == out)
}

@(test)
mission_without_a_base :: proc(t: ^testing.T) {
	s := f32(1)
	ter := town(t, s)
	defer terrain.destroy(&ter)
	origin, size := default_region(ter, s)
	g := Game{origin = origin, size = size}
	out, _ := export_mission(Export_Input{game = g, world_scale = s, ter = ter, id = "town", title = "Town"}, context.temp_allocator)
	m: Game_Mission
	testing.expect(t, json.unmarshal(transmute([]byte)out, &m, allocator = context.temp_allocator) == nil, out)
	testing.expect(t, m.id == "town" && len(m.guards) == 0 && m.extraction.radius == 0)
	// a spawn outside every building
	sp := m.player_spawn
	for b in m.buildings {
		testing.expectf(t, !(sp.x >= b.x && sp.x <= b.x + b.w && sp.y >= b.y && sp.y <= b.y + b.h), "spawn %v inside %v", sp, b)
	}
}

@(test)
game_section_round_trips :: proc(t: ^testing.T) {
	l := Level{format = FORMAT, version = VERSION, world_scale = 0.005, max_tilt = 20, next_id = 1}
	l.game = Game{mission = "krakow.mission.json", base = "krakow.mission.base.json", origin = {-0.25, 0.125}, size = {120, 90}, buildings = false}
	text := encode(l)
	defer delete(text)
	back, _, err := decode(transmute([]byte)text)
	defer destroy(&back)
	testing.expect(t, err == .None)
	g, ok := back.game.?
	testing.expectf(t, ok && g.mission == "krakow.mission.json" && g.base == "krakow.mission.base.json" && g.origin == {-0.25, 0.125} && g.size == {120, 90} && !game_buildings(g), "%v", back.game)
}
