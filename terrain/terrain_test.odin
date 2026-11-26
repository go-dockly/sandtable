package terrain

// odin test terrain
//
// A synthetic capture with what makes real ones hard: a sloped street, a
// building with no ground splats under it, a tree canopy, a car, haze
// (low-opacity splats everywhere), sky blobs and splats under the street.

import "core:math"
import "core:math/rand"
import "core:os"
import "core:strings"
import "core:testing"

SLOPE :: f32(0.1) // ground rises 10 cm per metre along +x

ground_at :: proc(x, z: f32) -> f32 {
	return 2 + SLOPE * x + 0.5 * math.sin(z * 0.05)
}

BUILDING_LO :: [2]f32{60, 20}
BUILDING_HI :: [2]f32{80, 35}
BUILDING_H  :: f32(12)
TREE        :: [2]f32{25, 70}
TREE_R      :: f32(4)
CAR_LO      :: [2]f32{28, 29}
CAR_HI      :: [2]f32{32, 31}
CAR_H       :: f32(1.5)

in_rect :: proc(x, z: f32, lo, hi: [2]f32) -> bool {
	return x >= lo.x && x <= hi.x && z >= lo.y && z <= hi.y
}

// 100 x 100 m, metres scaled by `s` (world units per metre). Returns
// positions and opacities.
make_scene :: proc(s: f32, density: int = 16, seed: u64 = 7) -> (pos: [dynamic][3]f32, op: [dynamic]f32) {
	state := rand.create(seed)
	r := rand.default_random_generator(&state)
	u :: proc(r: rand.Generator, a, b: f32) -> f32 {
		return a + (b - a) * rand.float32(r)
	}
	add :: proc(pos: ^[dynamic][3]f32, op: ^[dynamic]f32, q: [3]f32, o: f32, s: f32) {
		append(pos, q * s)
		append(op, o)
	}

	// street: `density` splats per square metre, 3 cm noise
	for _ in 0 ..< density * 10_000 {
		x, z := u(r, 0, 100), u(r, 0, 100)
		if in_rect(x, z, BUILDING_LO, BUILDING_HI) do continue // never seen
		if math.hypot(x - TREE.x, z - TREE.y) < TREE_R * 0.7 do continue // hidden by the canopy
		add(&pos, &op, {x, ground_at(x, z) + u(r, -0.03, 0.03), z}, u(r, 0.5, 1), s)
	}
	// building: flat roof and four walls
	b_ground := ground_at((BUILDING_LO.x + BUILDING_HI.x) / 2, (BUILDING_LO.y + BUILDING_HI.y) / 2)
	roof := b_ground + BUILDING_H
	for _ in 0 ..< 6_000 {
		x, z := u(r, BUILDING_LO.x, BUILDING_HI.x), u(r, BUILDING_LO.y, BUILDING_HI.y)
		add(&pos, &op, {x, roof + u(r, -0.03, 0.03), z}, 0.9, s)
	}
	for _ in 0 ..< 6_000 {
		side := rand.int_max(4, r)
		x, z: f32
		switch side {
		case 0: x, z = BUILDING_LO.x, u(r, BUILDING_LO.y, BUILDING_HI.y)
		case 1: x, z = BUILDING_HI.x, u(r, BUILDING_LO.y, BUILDING_HI.y)
		case 2: x, z = u(r, BUILDING_LO.x, BUILDING_HI.x), BUILDING_LO.y
		case: x, z = u(r, BUILDING_LO.x, BUILDING_HI.x), BUILDING_HI.y
		}
		add(&pos, &op, {x, u(r, ground_at(x, z), roof), z}, 0.9, s)
	}
	// tree: a canopy 5..9 m up, a trunk
	for _ in 0 ..< 3_000 {
		a, d := u(r, 0, 2 * math.PI), math.sqrt(rand.float32(r)) * TREE_R
		x, z := TREE.x + d * math.cos(a), TREE.y + d * math.sin(a)
		add(&pos, &op, {x, ground_at(x, z) + u(r, 5, 9), z}, 0.7, s)
	}
	for _ in 0 ..< 200 {
		add(&pos, &op, {TREE.x, ground_at(TREE.x, TREE.y) + u(r, 0, 5), TREE.y}, 0.9, s)
	}
	// car: a box, its top and sides
	for _ in 0 ..< 600 {
		x, z := u(r, CAR_LO.x, CAR_HI.x), u(r, CAR_LO.y, CAR_HI.y)
		add(&pos, &op, {x, ground_at(x, z) + CAR_H * u(r, 0.3, 1), z}, 0.95, s)
	}
	// haze: transparent splats anywhere
	for _ in 0 ..< 3_000 {
		add(&pos, &op, {u(r, 0, 100), u(r, -5, 40), u(r, 0, 100)}, 0.05, s)
	}
	// opaque sky blobs and splats under the street, one at a time
	for _ in 0 ..< 30 {
		add(&pos, &op, {u(r, 0, 100), 45, u(r, 0, 100)}, 0.9, s)
		add(&pos, &op, {u(r, 0, 100), -6, u(r, 0, 100)}, 0.9, s)
	}
	return
}

build_scene :: proc(t: ^testing.T, s: f32, density := 16) -> Terrain {
	pos, op := make_scene(s, density)
	defer delete(pos)
	defer delete(op)
	ter, ok := build(pos[:], op[:], default_params(s))
	testing.expect(t, ok, "build failed")
	return ter
}

@(test)
ground_follows_the_street :: proc(t: ^testing.T) {
	ter := build_scene(t, 1)
	defer destroy(&ter)
	testing.expectf(t, ter.cell == 1, "cell %v: 16 splats/m2 should give 1 m cells", ter.cell)
	worst: f32
	for z := f32(5); z < 95; z += 7 {
		for x := f32(5); x < 95; x += 7 {
			if in_rect(x, z, BUILDING_LO - 2, BUILDING_HI + 2) do continue
			if math.hypot(x - TREE.x, z - TREE.y) < TREE_R + 2 do continue
			if in_rect(x, z, CAR_LO - 2, CAR_HI + 2) do continue
			y, inside := sample_height(ter, x, z)
			testing.expect(t, inside)
			worst = max(worst, abs(y - ground_at(x, z)))
		}
	}
	testing.expectf(t, worst < 0.12, "street: worst ground error %.3f m", worst)
}

@(test)
ground_under_objects_is_filled :: proc(t: ^testing.T) {
	ter := build_scene(t, 1)
	defer destroy(&ter)

	// building: no splats under it, ground interpolated from the street around
	bc := (BUILDING_LO + BUILDING_HI) * 0.5
	g, _ := sample_height(ter, bc.x, bc.y)
	testing.expectf(t, abs(g - ground_at(bc.x, bc.y)) < 0.15, "under building: %.2f, want %.2f", g, ground_at(bc.x, bc.y))
	s, _ := sample_height(ter, bc.x, bc.y, .Surface)
	roof := ground_at(bc.x, bc.y) + BUILDING_H
	testing.expectf(t, abs(s - roof) < 0.2, "roof: %.2f, want %.2f", s, roof)
	c, _ := cell_index(ter, bc.x, bc.y)
	testing.expect_value(t, ter.class[c], Class.Structure)

	// tree
	g, _ = sample_height(ter, TREE.x, TREE.y)
	testing.expectf(t, abs(g - ground_at(TREE.x, TREE.y)) < 0.3, "under tree: %.2f, want %.2f", g, ground_at(TREE.x, TREE.y))
	c, _ = cell_index(ter, TREE.x + 2, TREE.y)
	testing.expect_value(t, ter.class[c], Class.Structure)

	// car: off the ground, but lower than a structure
	cc := (CAR_LO + CAR_HI) * 0.5
	g, _ = sample_height(ter, cc.x, cc.y)
	testing.expectf(t, abs(g - ground_at(cc.x, cc.y)) < 0.15, "under car: %.2f, want %.2f", g, ground_at(cc.x, cc.y))
	c, _ = cell_index(ter, cc.x, cc.y)
	testing.expect_value(t, ter.class[c], Class.Object)

	// sky blobs do not stick out of the surface, pits do not dent the ground
	testing.expectf(t, ter.hi < roof + 1, "surface max %.2f: sky blobs got in", ter.hi)
	testing.expectf(t, ter.lo > ground_at(0, 0) - 1, "ground min %.2f: pits got in", ter.lo)
}

@(test)
normals_and_footprints :: proc(t: ^testing.T) {
	ter := build_scene(t, 1)
	defer destroy(&ter)
	want := normal_from_gradient(SLOPE, 0)

	n := sample_normal(ter, 40, 50)
	testing.expectf(t, angle(n, want) < 3, "normal %v, %.1f deg off", n, angle(n, want))

	// a car-sized footprint, turned 30 degrees, on the slope
	h, fn, inside := fit_footprint(ter, {40, 50}, {1, 2}, math.PI / 6)
	testing.expect(t, inside)
	testing.expectf(t, abs(h - ground_at(40, 50)) < 0.1, "footprint height %.3f, want %.3f", h, ground_at(40, 50))
	testing.expectf(t, angle(fn, want) < 1.5, "footprint normal %v, %.1f deg off", fn, angle(fn, want))

	// tilt clamp
	steep := clamp_tilt(normal_from_gradient(2, 0), math.PI / 12)
	testing.expectf(t, abs(angle(steep, {0, 1, 0}) - 15) < 0.01, "clamped tilt %.2f deg", angle(steep, {0, 1, 0}))

	// zero footprint: a point sample
	h, _, _ = fit_footprint(ter, {40, 50}, {0, 0}, 0)
	g, _ := sample_height(ter, 40, 50)
	testing.expect(t, abs(h - g) < 1e-5)
}

@(test)
raycast_hits :: proc(t: ^testing.T) {
	ter := build_scene(t, 1)
	defer destroy(&ter)

	hit, _, ok := raycast(ter, {40, 100, 50}, {0, -1, 0})
	testing.expect(t, ok)
	g, _ := sample_height(ter, 40, 50)
	testing.expectf(t, abs(hit.y - g) < 1e-3, "vertical ray: %.3f, want %.3f", hit.y, g)

	// the Commandos view: 38 degrees down, at the building, surface layer hits the roof
	el := f32(38) * math.RAD_PER_DEG
	bc := (BUILDING_LO + BUILDING_HI) * 0.5
	dir := [3]f32{math.cos(el), -math.sin(el), 0}
	origin := [3]f32{bc.x, 0, bc.y} - dir * 60
	origin.y += ground_at(bc.x, bc.y) + BUILDING_H
	hit, _, ok = raycast(ter, origin, dir, .Surface)
	testing.expect(t, ok)
	testing.expectf(t, hit.x <= bc.x + 0.5 && hit.x >= BUILDING_LO.x - 0.5, "oblique ray hit x %.2f", hit.x)

	// pointing away misses
	_, _, ok = raycast(ter, {40, 100, 50}, {0, 1, 0})
	testing.expect(t, !ok)
}

@(test)
same_result_at_any_world_scale :: proc(t: ^testing.T) {
	S :: f32(0.005) // Krakow
	a := build_scene(t, 1)
	defer destroy(&a)
	b := build_scene(t, S)
	defer destroy(&b)
	testing.expect_value(t, b.w, a.w)
	testing.expect_value(t, b.h, a.h)
	worst: f32
	for z := f32(3); z < 97; z += 3.3 {
		for x := f32(3); x < 97; x += 3.3 {
			ya, _ := sample_height(a, x, z)
			yb, _ := sample_height(b, x * S, z * S)
			worst = max(worst, abs(ya - yb / S))
		}
	}
	testing.expectf(t, worst < 0.02, "scaled capture differs by %.3f m", worst)
}

// 4 splats per square metre: too few for 0.5 m cells, the cell grows to 2 m
// and the street still comes out right (a little low on the slope: a 2 m cell
// spans 20 cm of it and the ground quantile takes its low side)
@(test)
sparse_capture_coarsens_the_grid :: proc(t: ^testing.T) {
	ter := build_scene(t, 1, 4)
	defer destroy(&ter)
	testing.expectf(t, ter.cell == 2, "cell %v", ter.cell)
	worst: f32
	for z := f32(5); z < 95; z += 7 {
		for x := f32(5); x < 95; x += 7 {
			if in_rect(x, z, BUILDING_LO - 3, BUILDING_HI + 3) do continue
			if math.hypot(x - TREE.x, z - TREE.y) < TREE_R + 3 do continue
			if in_rect(x, z, CAR_LO - 3, CAR_HI + 3) do continue
			y, _ := sample_height(ter, x, z)
			worst = max(worst, abs(y - ground_at(x, z)))
		}
	}
	testing.expectf(t, worst < 0.2, "sparse street: worst ground error %.3f m", worst)
	bc := (BUILDING_LO + BUILDING_HI) * 0.5
	g, _ := sample_height(ter, bc.x, bc.y)
	testing.expectf(t, abs(g - ground_at(bc.x, bc.y)) < 0.5, "sparse, under building: %.2f, want %.2f", g, ground_at(bc.x, bc.y))
}

@(test)
lowest_cluster_skips_strays :: proc(t: ^testing.T) {
	// a stray under the street, three street splats, then a wall
	ys := []f32{-3, 1.00, 1.05, 1.1, 1.6, 2.4, 3.1, 4.0, 5.2, 6.0}
	y, ok := lowest_cluster(ys, 3, 0.2)
	testing.expect(t, ok)
	testing.expect_value(t, y, f32(1.05))
	_, ok = lowest_cluster(ys[:2], 3, 0.2)
	testing.expect(t, !ok)
}

@(test)
running_filter_matches_brute_force :: proc(t: ^testing.T) {
	W, H :: 23, 17
	state := rand.create(3)
	r := rand.default_random_generator(&state)
	src := make([]f32, W * H)
	defer delete(src)
	for &v in src do v = rand.float32(r)
	got := make([]f32, W * H)
	defer delete(got)
	for rad in ([]int{1, 2, 5, 30}) {
		for along_x in ([]bool{true, false}) {
			for take_max in ([]bool{true, false}) {
				filter_1d(src, got, W, H, rad, along_x, take_max)
				for z in 0 ..< H {
					for x in 0 ..< W {
						want := -max(f32) if take_max else max(f32)
						for k in -rad ..= rad {
							nx, nz := x, z
							if along_x do nx += k
							else do nz += k
							if nx < 0 || nz < 0 || nx >= W || nz >= H do continue
							v := src[nz * W + nx]
							want = max(want, v) if take_max else min(want, v)
						}
						if got[z * W + x] != want {
							testing.expectf(t, false, "r %d x? %v max? %v at %d,%d", rad, along_x, take_max, x, z)
							return
						}
					}
				}
			}
		}
	}
}

@(test)
export_writes_files :: proc(t: ^testing.T) {
	ter := build_scene(t, 1)
	defer destroy(&ter)
	prefix := "/tmp/sandtable_terrain_test"
	names, err := export(ter, prefix, 1)
	testing.expect_value(t, err, nil)
	defer for s in names do delete(s)
	data, rerr := os.read_entire_file(names[0], context.allocator)
	testing.expect_value(t, rerr, nil)
	defer delete(data)
	header := strings.concatenate({"P5\n", fmt_int(ter.w), " ", fmt_int(ter.h), "\n65535\n"}, context.temp_allocator)
	testing.expect(t, strings.has_prefix(string(data), header))
	testing.expect_value(t, len(data), len(header) + ter.w * ter.h * 2)
	json, jerr := os.read_entire_file(names[4], context.allocator)
	testing.expect_value(t, jerr, nil)
	defer delete(json)
	testing.expect(t, strings.contains(string(json), `"ground": "sandtable_terrain_test.ground.pgm"`))
}

fmt_int :: proc(n: int) -> string {
	buf: [32]u8
	i := len(buf)
	v := n
	for {
		i -= 1
		buf[i] = u8('0' + v % 10)
		v /= 10
		if v == 0 do break
	}
	return strings.clone(string(buf[i:]), context.temp_allocator)
}

angle :: proc(a, b: [3]f32) -> f32 {
	d := clamp(a.x * b.x + a.y * b.y + a.z * b.z, -1, 1)
	return math.acos(d) * math.DEG_PER_RAD
}

@(test)
load_export_round_trip :: proc(t: ^testing.T) {
	ter := build_scene(t, 1)
	defer destroy(&ter)
	prefix := "/tmp/sandtable_terrain_load/sub/scene" // the folder is made
	os.remove_all("/tmp/sandtable_terrain_load")
	defer os.remove_all("/tmp/sandtable_terrain_load")
	names, err := export(ter, prefix, 0.005)
	testing.expect_value(t, err, nil)
	defer for s in names do delete(s)

	got, ws, lerr := load_export(names[4])
	defer destroy(&got)
	testing.expect_value(t, lerr, Load_Error.None)
	testing.expect_value(t, ws, f32(0.005))
	testing.expect_value(t, got.w, ter.w)
	testing.expect_value(t, got.h, ter.h)
	testing.expect_value(t, got.origin, ter.origin)
	testing.expect_value(t, got.cell, ter.cell)
	testing.expect_value(t, got.params.structure_height, ter.params.structure_height)
	// quantised to 1/65535 of the range
	tol := (ter.hi - ter.lo) / 65535 + 1e-6
	worst: f32
	for i in 0 ..< ter.w * ter.h {
		worst = max(worst, abs(got.ground[i] - ter.ground[i]), abs(got.surface[i] - ter.surface[i]), abs(got.floor[i] - ter.floor[i]))
		if got.class[i] != ter.class[i] {
			testing.expectf(t, false, "class at %d: %v, want %v", i, got.class[i], ter.class[i])
			return
		}
	}
	testing.expectf(t, worst <= tol, "heights within %v: %v", tol, worst)
	testing.expect_value(t, got.stats.structure_cells, ter.stats.structure_cells)

	_, _, merr := load_export("/tmp/sandtable_terrain_load/none.terrain.json")
	testing.expect_value(t, merr, Load_Error.Read)
}
