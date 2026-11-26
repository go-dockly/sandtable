package mapgen

// An old town like Krakow's: a block of houses wall to wall, one continuous
// region of structure, captured by a drone whose flight makes the data a
// diamond turned 45 degrees to the streets. The streets are turned 10
// degrees from the world axes.
//
//   z 20..40   block A, wall to wall along x:
//                ..20  8 m       20..30  18 m    30..40  gable 9 -> 15 -> 9 m
//                40..50  20 m    50..55  tower 38 m    55..  12 m
//   z 40..50   street
//   z 50..70   block B: one house, 10 m
//
// Both blocks run on past the edge of the data, |x - 40| + |z - 45| <= 52,
// so the capture's diagonal outline cuts through roofs, as in Krakow.

import "core:math"
import "core:math/rand"
import "core:testing"

import "../terrain"
import "cmd:gamemap"

@(private = "file")
OLD_YAW :: f32(10)

@(private = "file")
to_world :: proc(p: [3]f32) -> [3]f32 {
	s, c := math.sincos(OLD_YAW * math.RAD_PER_DEG)
	return {(c * p.x - s * p.z) * S, p.y * S, (s * p.x + c * p.z) * S}
}

// The roof height at a local point, 0 for the street.
@(private = "file")
roof_at :: proc(x, z: f32) -> f32 {
	if z >= 20 && z < 40 && x >= -10 && x < 90 {
		switch {
		case x < 20: return 8
		case x < 30: return 18
		case x < 40: return 15 - 6 * abs(z - 30) / 10 // the gable, its ridge along x
		case x < 50: return 20
		case x < 55: return 38
		case:        return 12
		}
	}
	if z >= 50 && z < 70 && x >= -10 && x < 90 do return 10
	return 0
}

@(private = "file")
old_town :: proc() -> terrain.Terrain {
	state := rand.create(5)
	r := rand.default_random_generator(&state)
	pos := make([dynamic][3]f32)
	op := make([dynamic]f32)
	defer delete(pos)
	defer delete(op)
	for _ in 0 ..< 16 * 100 * 100 {
		x, z := rand.float32(r) * 100 - 10, rand.float32(r) * 100 - 5
		if abs(x - 40) + abs(z - 45) > 52 do continue // the drone did not get there
		y := roof_at(x, z) + (rand.float32(r) - 0.5) * 0.06
		append(&pos, to_world({x, y, z}))
		append(&op, 0.9)
	}
	t, ok := terrain.build(pos[:], op[:], terrain.default_params(S))
	assert(ok)
	return t
}

@(private = "file")
local_map :: proc(m: ^gamemap.Map, x, z: f32) -> [2]f32 {
	return gamemap.world_to_map(m.frame, to_world({x, 0, z})).xy
}

@(test)
old_town_wall_to_wall :: proc(t: ^testing.T) {
	ter := old_town()
	defer terrain.destroy(&ter)

	// the region: the town's square around the diamond, axis-aligned in the world
	lo := [2]f32{max(f32), max(f32)}
	hi := [2]f32{-max(f32), -max(f32)}
	for c in ([4][2]f32{{-12, -7}, {92, -7}, {-12, 97}, {92, 97}}) {
		w := to_world({c.x, 0, c.y})
		lo = {min(lo.x, w.x), min(lo.y, w.z)}
		hi = {max(hi.x, w.x), max(hi.y, w.z)}
	}
	m, stats := build(Input{terrain = &ter, world_scale = S, origin = lo, size = (hi - lo) / S, params = default_params()})
	defer gamemap.destroy(&m)

	// the streets set the grid, not the edge of the capture
	off := math.mod(stats.yaw - OLD_YAW + 135, 90) - 45
	testing.expectf(t, abs(off) < 1.5, "yaw %.1f: the streets are turned %.0f, the capture's edge 55", stats.yaw, OLD_YAW)

	// six houses in block A, one in block B, no tree
	testing.expectf(t, stats.trees == 0, "no trees in an old town of roofs: %v", stats)
	expect := []struct {
		name:   string,
		at:     [2]f32,
		height: f32,
	}{
		{"8 m house", {15, 30}, 8},
		{"18 m house", {25, 30}, 18},
		{"gable", {35, 30}, 12},
		{"20 m house", {45, 30}, 20},
		{"tower", {52.5, 30}, 38},
		{"12 m house", {62.5, 30}, 12},
		{"block B", {40, 60}, 10},
	}
	ids := make(map[string]string, allocator = context.temp_allocator)
	for e in expect {
		p := local_map(&m, e.at.x, e.at.y)
		found := false
		for f in m.features {
			if f.kind != .Building || !gamemap.inside_rings(f.footprint, p) do continue
			found = true
			tol := f32(1.5) if e.name == "gable" else 0.5
			testing.expectf(t, abs(f.height - e.height) < tol, "%s: %.1f m, %.0f", e.name, f.height, e.height)
			if other, taken := ids[f.id]; taken {
				testing.expectf(t, false, "%s and %s are one building, %s", e.name, other, f.id)
			}
			ids[f.id] = e.name
		}
		testing.expectf(t, found, "%s: a building", e.name)
	}
	testing.expectf(t, stats.buildings >= 7 && stats.buildings <= 10, "about 7 buildings: %v", stats)
}

// The yaw of a town that is nearly all roof, as Krakow's capture is (59%
// structure): the only walls showing are steps between roofs, along a grid
// turned 10 degrees, and the data stops at a diamond turned 45. The
// diamond's outline must not win.
@(test)
yaw_from_roof_steps_not_the_capture_edge :: proc(t: ^testing.T) {
	W :: 240
	ter := terrain.Terrain{w = W, h = W, cell = 1, lo = 0, hi = 40}
	ter.params.structure_height = 2
	ter.class = make([]terrain.Class, W * W, context.temp_allocator)
	ter.surface = make([]f32, W * W, context.temp_allocator)
	s, c := math.sincos(OLD_YAW * math.RAD_PER_DEG)
	for z in 0 ..< W {
		for x in 0 ..< W {
			i := z * W + x
			fx, fz := f32(x) - W / 2, f32(z) - W / 2
			if abs(fx) + abs(fz) > W * 0.45 do continue // no data: Empty
			u := c * fx + s * fz
			v := -s * fx + c * fz
			ter.class[i] = .Structure
			ter.surface[i] = 10 + 4 * math.mod(math.floor(u / 12) + math.floor(v / 9) + 100, 3)
		}
	}
	yaw := edge_direction(ter)
	off := math.mod(yaw - OLD_YAW + 135, 90) - 45
	testing.expectf(t, abs(off) < 1.5, "yaw %.1f: the roofs are turned %.0f, the capture's edge 45", yaw, OLD_YAW)
}
