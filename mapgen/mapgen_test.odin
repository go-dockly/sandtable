package mapgen

// odin test mapgen -collection:cmd=../commandos
//
// A synthetic capture turned 20 degrees from the world axes, at Krakow's
// scale, through the real terrain build: a street, a 20 x 12 m building 10 m
// tall, an L-shaped building 7 m tall with a courtyard, a tree whose canopy
// lets some ground show through, a thin garden wall, and splats of haze.

import "core:math"
import "core:math/rand"
import "core:testing"

import "../terrain"
import "cmd:gamemap"

S    :: f32(0.005) // world units per metre
YAW  :: f32(20)    // the street grid, degrees
SIZE :: f32(80)    // metres

@(private = "file")
local_to_world :: proc(p: [3]f32) -> [3]f32 {
	s, c := math.sincos(YAW * math.RAD_PER_DEG)
	// turned like a map frame: local +x along (c, s) in world x, z
	return {(c * p.x - s * p.z) * S, p.y * S, (s * p.x + c * p.z) * S}
}

@(private = "file")
in_box :: proc(x, z: f32, b: [4]f32) -> bool {return x >= b[0] && x <= b[2] && z >= b[1] && z <= b[3]}

B1     :: [4]f32{10, 10, 30, 22}  // x0, z0, x1, z1 in local metres
B1_H   :: f32(10)
L_OUT  :: [4]f32{40, 8, 70, 38}   // the L / courtyard block's outline
L_HOLE :: [4]f32{48, 16, 62, 30}  // its courtyard, open to the sky
L_H    :: f32(7)
TREE_C :: [2]f32{20, 55}
TREE_R :: f32(4)
WALL   :: [4]f32{40, 50, 41, 70}  // a 2 m garden wall, 1 m thick
WALL_H :: f32(2)

@(private = "file")
town :: proc() -> (pos: [dynamic][3]f32, op: [dynamic]f32) {
	state := rand.create(11)
	r := rand.default_random_generator(&state)
	u :: proc(r: rand.Generator, a, b: f32) -> f32 {return a + (b - a) * rand.float32(r)}
	add :: proc(pos: ^[dynamic][3]f32, op: ^[dynamic]f32, p: [3]f32, o: f32) {
		append(pos, local_to_world(p))
		append(op, o)
	}
	in_l :: proc(x, z: f32) -> bool {return in_box(x, z, L_OUT) && !in_box(x, z, L_HOLE)}

	for _ in 0 ..< 16 * int(SIZE * SIZE) {
		x, z := u(r, 0, SIZE), u(r, 0, SIZE)
		if in_box(x, z, B1) || in_l(x, z) || in_box(x, z, WALL) do continue
		if math.hypot(x - TREE_C.x, z - TREE_C.y) < TREE_R && rand.float32(r) < 0.6 do continue // the canopy hides most
		add(&pos, &op, {x, u(r, -0.03, 0.03), z}, 0.9)
	}
	roof :: proc(pos: ^[dynamic][3]f32, op: ^[dynamic]f32, r: rand.Generator, b: [4]f32, h: f32, hole: Maybe([4]f32)) {
		area := (b[2] - b[0]) * (b[3] - b[1])
		for _ in 0 ..< int(area * 16) {
			x, z := u(r, b[0], b[2]), u(r, b[1], b[3])
			if hb, has := hole.?; has && in_box(x, z, hb) do continue
			add(pos, op, {x, h + u(r, -0.03, 0.03), z}, 0.9)
		}
	}
	roof(&pos, &op, r, B1, B1_H, nil)
	roof(&pos, &op, r, L_OUT, L_H, L_HOLE)
	roof(&pos, &op, r, WALL, WALL_H, nil)
	// the canopy: 3..8 m, rough
	canopy_splats := f32(math.PI * TREE_R * TREE_R * 30)
	for _ in 0 ..< int(canopy_splats) {
		a, d := u(r, 0, math.TAU), math.sqrt(rand.float32(r)) * TREE_R
		top := 8 - 4 * d / TREE_R
		add(&pos, &op, {TREE_C.x + d * math.cos(a), u(r, 3, top) if rand.float32(r) < 0.5 else top + u(r, -0.6, 0.6), TREE_C.y + d * math.sin(a)}, 0.7)
	}
	// haze
	for _ in 0 ..< 3000 do add(&pos, &op, {u(r, 0, SIZE), u(r, 0, 20), u(r, 0, SIZE)}, 0.05)
	return
}

@(private = "file")
Town :: struct {
	t:     terrain.Terrain,
	m:     gamemap.Map,
	stats: Stats,
}

@(private = "file")
build_town :: proc(cell := f32(1)) -> Town {
	pos, op := town()
	defer delete(pos)
	defer delete(op)
	tw: Town
	ok: bool
	tw.t, ok = terrain.build(pos[:], op[:], terrain.default_params(S))
	assert(ok)
	// the region: the town's local square, as an axis-aligned world box
	// around it (as a level's game section would be)
	lo := [2]f32{max(f32), max(f32)}
	hi := [2]f32{-max(f32), -max(f32)}
	for c in ([4][2]f32{{0, 0}, {SIZE, 0}, {0, SIZE}, {SIZE, SIZE}}) {
		w := local_to_world({c.x, 0, c.y})
		lo = {min(lo.x, w.x), min(lo.y, w.z)}
		hi = {max(hi.x, w.x), max(hi.y, w.z)}
	}
	p := default_params()
	p.cell = cell
	tw.m, tw.stats = build(Input{terrain = &tw.t, world_scale = S, origin = lo, size = (hi - lo) / S, params = p})
	return tw
}

@(private = "file")
destroy_town :: proc(tw: ^Town) {
	terrain.destroy(&tw.t)
	gamemap.destroy(&tw.m)
}

@(private = "file")
find :: proc(m: ^gamemap.Map, kind: gamemap.Feature_Kind, near: [2]f32) -> (^gamemap.Feature, f32) {
	best: ^gamemap.Feature
	best_d := max(f32)
	for &f in m.features {
		if f.kind != kind do continue
		_, at, _ := parse_id(f.id)
		d := math.hypot(at.x - near.x, at.y - near.y)
		if d < best_d {
			best, best_d = &f, d
		}
	}
	return best, best_d
}

// The local town point (x, z) in map metres.
@(private = "file")
to_map :: proc(m: ^gamemap.Map, x, z: f32) -> [2]f32 {
	return gamemap.world_to_map(m.frame, local_to_world({x, 0, z})).xy
}

@(private = "file")
area :: proc(m: ^gamemap.Map, f: ^gamemap.Feature) -> f32 {
	return f32(len(gamemap.cells_in(m, f.footprint))) * m.cell * m.cell
}

// ---------------------------------------------------------------------------

@(test)
aligns_to_the_street_grid :: proc(t: ^testing.T) {
	tw := build_town()
	defer destroy_town(&tw)
	testing.expectf(t, abs(tw.stats.yaw - YAW) < 1.5, "yaw %.1f, the town is turned %.0f", tw.stats.yaw, YAW)

	// the whole town is in the map, turned square
	testing.expect(t, tw.m.w >= int(SIZE) && tw.m.h >= int(SIZE), "the region covers the town")
	f := tw.m.frame
	a := gamemap.world_to_map(f, local_to_world({0, 0, 0}))
	b := gamemap.world_to_map(f, local_to_world({SIZE, 0, 0}))
	testing.expectf(t, abs(a.y - b.y) < 1.5, "the town's x axis is the map's: %v %v", a, b)
}

@(test)
features_from_the_capture :: proc(t: ^testing.T) {
	tw := build_town()
	defer destroy_town(&tw)
	m := &tw.m
	testing.expectf(t, tw.stats.buildings == 2 && tw.stats.trees == 1 && tw.stats.walls == 1,
		"2 buildings, 1 tree, 1 wall: %v", tw.stats)

	c1 := to_map(m, 20, 16)
	b1, d1 := find(m, .Building, c1)
	testing.expectf(t, b1 != nil && d1 < 2, "the 20 x 12 building, %.1f m from where it is", d1)
	if b1 != nil {
		testing.expectf(t, abs(b1.height - B1_H) < 0.3, "one clean roof height: %.2f", b1.height)
		testing.expectf(t, abs(area(m, b1) - 240) < 25, "its footprint %.0f m², 240", area(m, b1))
		testing.expectf(t, len(b1.footprint) == 1 && len(b1.footprint[0]) == 4, "a rectangle: %d rings, %d corners", len(b1.footprint), len(b1.footprint[0]) if len(b1.footprint) > 0 else 0)
		testing.expect(t, !b1.walkable_roof, "roofs are walked only after an edit")
	}

	bl, _ := find(m, .Building, to_map(m, 55, 23))
	testing.expect(t, bl != nil, "the courtyard block")
	if bl != nil {
		testing.expectf(t, len(bl.footprint) == 2, "outline and courtyard: %d rings", len(bl.footprint))
		testing.expectf(t, abs(bl.height - L_H) < 0.3, "7 m: %.2f", bl.height)
		yard := to_map(m, 55, 23)
		testing.expect(t, !gamemap.inside_rings(bl.footprint, yard), "the courtyard is not inside the building")
	}

	tree, dt := find(m, .Tree, to_map(m, TREE_C.x, TREE_C.y))
	testing.expectf(t, tree != nil && dt < 3, "the tree, %.1f m off", dt)
	if tree != nil {
		testing.expectf(t, tree.height > 6 && tree.height < 9, "tree top %.1f", tree.height)
		testing.expect(t, tree.bottom > 2, "a canopy you see under")
	}

	wall, dw := find(m, .Wall, to_map(m, 40.5, 60))
	testing.expectf(t, wall != nil && dw < 3, "the garden wall, %.1f m off", dw)
	if wall != nil do testing.expectf(t, abs(wall.height - WALL_H) < 0.4, "wall %.1f m", wall.height)

	// the ground is walkable, flat, and the street is open
	n, ok := gamemap.node_at(m, {to_map(m, 5, 5).x, to_map(m, 5, 5).y, 0})
	testing.expect(t, ok, "street")
	if ok {
		h, _ := gamemap.height(m, n)
		testing.expectf(t, abs(h) < 0.2, "street at %.2f m", h)
	}
}

@(test)
edits_on_the_automatic_map :: proc(t: ^testing.T) {
	tw := build_town()
	defer destroy_town(&tw)
	m := &tw.m
	b1, _ := find(m, .Building, to_map(m, 20, 16))
	if b1 == nil {
		testing.fail_now(t, "no building")
	}
	// a ladder against its south wall (local z = 10), up onto the roof
	foot := to_map(m, 20, 9.2)
	top := to_map(m, 20, 11)
	edits := []gamemap.Edit{
		{id = "e1", kind = .Building, target = b1.id, walkable_roof = true},
		{id = "e2", kind = .Link, link = .Ladder, a = {foot.x, foot.y, 0}, b = {top.x, top.y, B1_H}},
		{id = "e3", kind = .Flatten, region = {to_map(m, 0, 0), to_map(m, 8, 0), to_map(m, 8, 8), to_map(m, 0, 8)}, fit = true},
	}
	problems := gamemap.apply_edits(m, edits, context.temp_allocator)
	for p in problems do testing.expectf(t, false, "%s: %s", p.edit, p.message)

	street := to_map(m, 5, 30)
	on_roof := to_map(m, 25, 18)
	from, fok := gamemap.node_at(m, {street.x, street.y, 0})
	to, tok := gamemap.node_at(m, {on_roof.x, on_roof.y, B1_H})
	testing.expect(t, fok && tok, "ends on floors")
	if !fok || !tok do return
	testing.expect(t, int(to.layer) > 0, "the roof is a layer")
	path := gamemap.find_path(m, from, to, gamemap.Agent{radius = 0.4}, context.temp_allocator)
	testing.expect(t, path.found, "street to roof by the ladder")

	// a guard on that roof sees over the garden wall, one in the street
	// doesn't see someone crouching right behind it
	behind := to_map(m, 48.5, 60) // 7.5 m behind the wall
	roof_eye := gamemap.eye_point({on_roof.x, on_roof.y, B1_H}, .Standing)
	street_eye := gamemap.eye_point({to_map(m, 30, 60).x, to_map(m, 30, 60).y, 0}, .Standing)
	testing.expect(t, !gamemap.can_see_body(m, street_eye, {behind.x, behind.y, 0}, .Crouching), "hidden behind the wall")
	close := to_map(m, 42, 60)
	testing.expect(t, !gamemap.can_see_body(m, street_eye, {close.x, close.y, 0}, .Standing), "a 2 m wall hides someone standing right behind it")
	testing.expect(t, gamemap.can_see_body(m, roof_eye, {behind.x, behind.y, 0}, .Crouching), "the roof sees over the wall")
}

@(test)
ids_survive_a_shift :: proc(t: ^testing.T) {
	tw := build_town()
	defer destroy_town(&tw)
	m := &tw.m
	b1, _ := find(m, .Building, to_map(m, 20, 16))
	if b1 == nil do testing.fail_now(t, "no building")
	k, at, ok := parse_id(b1.id)
	testing.expect(t, ok && k == .Building, "ids read back")

	// an edit made against an earlier build, when the building's centre
	// rounded 2 m away
	old := fmtid(at + {2, -1})
	edits := []gamemap.Edit{
		{id = "e1", kind = .Building, target = old, height = 12},
		{id = "e2", kind = .Remove, target = "t:900,900"},
	}
	fixed, moved := retarget(m, edits)
	testing.expect_value(t, len(moved), 1)
	testing.expect_value(t, fixed[0].target, b1.id)
	testing.expect_value(t, fixed[1].target, "t:900,900")
	testing.expect_value(t, edits[0].target, old) // the level's list is left alone
	problems := gamemap.apply_edits(m, fixed, context.temp_allocator)
	testing.expect_value(t, len(problems), 1) // the far tree, flagged
	testing.expect_value(t, b1.height, f32(12))
}

@(private = "file")
fmtid :: proc(at: [2]f32) -> string {
	taken := make(map[string]int, allocator = context.temp_allocator)
	return feature_id(.Building, at, &taken, context.temp_allocator)
}

@(test)
same_capture_same_map :: proc(t: ^testing.T) {
	a := build_town()
	defer destroy_town(&a)
	b := build_town()
	defer destroy_town(&b)
	testing.expect_value(t, len(a.m.features), len(b.m.features))
	for f, i in a.m.features {
		if i >= len(b.m.features) do break
		testing.expect_value(t, f.id, b.m.features[i].id)
	}
	same := true
	for v, i in a.m.layers[0].height do if v != b.m.layers[0].height[i] do same = false
	testing.expect(t, same, "same ground")
}

@(test)
outlines :: proc(t: ^testing.T) {
	// a 3 x 3 block with its centre missing, and a cell touching it only at a
	// corner: two components, the block with a hole
	W :: 6
	mask := [W * W]bool{}
	for y in 0 ..< 3 do for x in 0 ..< 3 do mask[y * W + x] = !(x == 1 && y == 1)
	mask[3 * W + 3] = true
	labels, n := label(mask[:], W, W)
	testing.expect_value(t, n, 2)
	rings := trace(labels, W, W, labels[0], 1, context.temp_allocator)
	testing.expect_value(t, len(rings), 2)
	for r in rings do testing.expect_value(t, len(r), 4)
	corner := trace(labels, W, W, labels[3 * W + 3], 0.5, context.temp_allocator)
	testing.expect_value(t, len(corner), 1)
	if len(corner) == 1 do testing.expect_value(t, corner[0][0], [2]f32{1.5, 1.5})

	// a gap of one cell closes, two cells stays
	g := [10]bool{true, true, false, true, true, false, false, true, true, true}
	close_gaps(g[:], 10, 1)
	testing.expect(t, g[2], "one cell gap closed")
	testing.expect(t, !g[5] && !g[6], "two cells stay open")
}

@(test)
half_metre_cells :: proc(t: ^testing.T) {
	tw := build_town(0.5)
	defer destroy_town(&tw)
	testing.expectf(t, tw.stats.buildings == 2 && tw.stats.trees == 1 && tw.stats.walls == 1, "at 0.5 m too: %v", tw.stats)
	b1, _ := find(&tw.m, .Building, to_map(&tw.m, 20, 16))
	if b1 != nil {
		testing.expectf(t, abs(area(&tw.m, b1) - 240) < 20, "footprint %.0f m²", area(&tw.m, b1))
		testing.expectf(t, len(b1.footprint) == 1 && len(b1.footprint[0]) == 4, "a rectangle: %v", b1.footprint)
	}
}
