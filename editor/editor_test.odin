package editor

// odin test editor
//
// The cameras are built with core:math/linalg the way raylib builds them
// (look-at view, OpenGL clip space), so the tests need no window.

import "core:math"
import "core:math/linalg"
import "core:testing"

import "../terrain"

// ---------------------------------------------------------------------------
// Cameras like sandtable's
// ---------------------------------------------------------------------------

Cam :: struct {
	view, proj: Mat4,
}

// The game camera: orthographic, 38 degrees down, from azimuth `az`.
iso_cam :: proc(target: [3]f32, az_deg, view_h, aspect: f32) -> Cam {
	az := az_deg * math.RAD_PER_DEG
	el := f32(38) * math.RAD_PER_DEG
	dist := view_h * 4
	eye := target + dist * [3]f32{math.cos(el) * math.sin(az), math.sin(el), math.cos(el) * math.cos(az)}
	hh := view_h * 0.5
	return Cam{
		view = Mat4(linalg.matrix4_look_at_f32(eye, target, {0, 1, 0})),
		proj = Mat4(linalg.matrix_ortho3d_f32(-hh * aspect, hh * aspect, -hh, hh, dist * 0.1, dist * 2)),
	}
}

persp_cam :: proc(eye, target: [3]f32, aspect: f32) -> Cam {
	return Cam{
		view = Mat4(linalg.matrix4_look_at_f32(eye, target, {0, 1, 0})),
		proj = Mat4(linalg.matrix4_perspective_f32(40 * math.RAD_PER_DEG, aspect, 0.05, 500)),
	}
}

to_ndc :: proc(c: Cam, p: [3]f32) -> [2]f32 {
	q := c.proj * c.view * [4]f32{p.x, p.y, p.z, 1}
	return q.xy / q.w
}

ray_of :: proc(t: ^testing.T, c: Cam, ndc: [2]f32) -> Ray {
	r, ok := screen_ray(linalg.inverse(c.proj * c.view), ndc)
	testing.expect(t, ok, "no ray")
	return r
}

dist_to_ray :: proc(r: Ray, p: [3]f32) -> f32 {
	v := p - r.origin
	return linalg.length(v - r.dir * linalg.dot(v, r.dir))
}

// ---------------------------------------------------------------------------
// A sloped street with a building, s world units per metre
// ---------------------------------------------------------------------------

SLOPE :: f32(0.1)
BLD_LO :: [2]f32{40, 40}
BLD_HI :: [2]f32{60, 60}
BLD_H :: f32(10)

street_y :: proc(x: f32) -> f32 {return 1 + SLOPE * x}

street :: proc(t: ^testing.T, s: f32) -> terrain.Terrain {
	pos: [dynamic][3]f32
	op: [dynamic]f32
	defer delete(pos)
	defer delete(op)
	for z := f32(0); z <= 100; z += 0.25 {
		for x := f32(0); x <= 100; x += 0.25 {
			y := street_y(x)
			if x >= BLD_LO.x && x <= BLD_HI.x && z >= BLD_LO.y && z <= BLD_HI.y {
				y = street_y(50) + BLD_H // flat roof, no ground under it
			}
			append(&pos, [3]f32{x, y, z} * s)
			append(&op, 1)
		}
	}
	ter, ok := terrain.build(pos[:], op[:], terrain.default_params(s))
	testing.expect(t, ok, "terrain build failed")
	return ter
}

// ---------------------------------------------------------------------------
// Rays
// ---------------------------------------------------------------------------

@(test)
ray_through_a_projected_point :: proc(t: ^testing.T) {
	target := [3]f32{3, 1, -2}
	cams := [?]Cam{
		iso_cam(target, 45, 20, 16.0 / 9),
		iso_cam(target, 200, 3, 1.3),
		persp_cam({12, 9, 14}, target, 16.0 / 9),
	}
	points := [?][3]f32{target, {0, 0, 0}, {5, 2, -4}, {-3, 0.5, 1}}
	for c, ci in cams {
		for p in points {
			r := ray_of(t, c, to_ndc(c, p))
			d := dist_to_ray(r, p)
			testing.expectf(t, d < 1e-3, "camera %d, point %v: ray misses it by %v", ci, p, d)
			testing.expectf(t, abs(linalg.length(r.dir) - 1) < 1e-5, "dir not unit: %v", r.dir)
		}
	}
	// orthographic: every ray is the view direction
	c := cams[0]
	a := ray_of(t, c, {-0.8, 0.6})
	b := ray_of(t, c, {0.7, -0.9})
	testing.expectf(t, linalg.dot(a.dir, b.dir) > 0.99999, "ortho rays not parallel: %v %v", a.dir, b.dir)
	testing.expect(t, a.dir.y < 0, "the game camera looks down")
}

@(test)
screen_pixels_to_ndc :: proc(t: ^testing.T) {
	testing.expect(t, ndc_from_screen({0, 0}, 1280, 720) == {-1, 1})
	testing.expect(t, ndc_from_screen({1280, 720}, 1280, 720) == {1, -1})
	testing.expect(t, ndc_from_screen({640, 360}, 1280, 720) == {0, 0})
}

@(test)
plane_hits :: proc(t: ^testing.T) {
	r := Ray{{0, 10, 0}, linalg.normalize([3]f32{1, -1, 0})}
	hit, d, ok := ray_plane_y(r, 2)
	testing.expect(t, ok)
	testing.expectf(t, linalg.length(hit - {8, 2, 0}) < 1e-4, "hit %v", hit)
	testing.expectf(t, abs(d - 8 * math.SQRT_TWO) < 1e-4, "t %v", d)
	_, _, ok = ray_plane_y(r, 20) // behind
	testing.expect(t, !ok)
	_, _, ok = ray_plane_y(Ray{{0, 1, 0}, {1, 0, 0}}, 0) // parallel
	testing.expect(t, !ok)
}

// A 4 x 1.5 x 2 m car (x long), turned 90 degrees and doubled: in the world
// it is long along z.
car_matrix :: proc() -> Mat4 {
	return Mat4(
		linalg.matrix4_translate_f32({10, 0, 10}) *
		linalg.matrix4_rotate_f32(math.PI / 2, {0, 1, 0}) *
		linalg.matrix4_scale_f32({2, 2, 2}),
	)
}
CAR_LO :: [3]f32{-2, 0, -1}
CAR_HI :: [3]f32{2, 1.5, 1}

@(test)
box_hits_follow_the_transform :: proc(t: ^testing.T) {
	m := car_matrix()
	down :: proc(x, z: f32) -> Ray {return Ray{{x, 50, z}, {0, -1, 0}}}

	// turned: 4 m wide in x (2 * 2 * 1), 8 m long in z
	d, ok := ray_box(down(10, 13.5), m, CAR_LO, CAR_HI)
	testing.expect(t, ok, "inside the turned footprint")
	testing.expectf(t, abs(d - (50 - 3)) < 1e-3, "roof at 3 m (1.5 * 2): t %v", d)
	_, ok = ray_box(down(13.5, 10), m, CAR_LO, CAR_HI)
	testing.expect(t, !ok, "inside the unturned footprint only")

	// from inside: t 0
	d, ok = ray_box(Ray{{10, 1, 10}, {1, 0, 0}}, m, CAR_LO, CAR_HI)
	testing.expect(t, ok && d == 0)
	// pointing away
	_, ok = ray_box(Ray{{10, 1, 30}, {0, 0, 1}}, m, CAR_LO, CAR_HI)
	testing.expect(t, !ok)
	// a slanted ray: distance along the world ray, not object space
	r := Ray{{10, 13, 0}, linalg.normalize([3]f32{0, -1, 1})}
	d, ok = ray_box(r, m, CAR_LO, CAR_HI)
	testing.expect(t, ok)
	hit := r.origin + r.dir * d
	testing.expectf(t, abs(hit.y - 3) < 1e-3 && abs(hit.z - 10) < 1e-3, "slanted hit %v (t %v)", hit, d)
}

@(test)
pick_takes_the_nearest :: proc(t: ^testing.T) {
	id1 := Mat4(linalg.matrix4_translate_f32({0, 0, 0}))
	id2 := Mat4(linalg.matrix4_translate_f32({0, 5, 0})) // stacked above: nearer from above
	cands := []Candidate{
		{id = 1, world = id1, lo = {-1, 0, -1}, hi = {1, 1, 1}},
		{id = 2, world = id2, lo = {-1, 0, -1}, hi = {1, 1, 1}},
	}
	r := Ray{{0, 20, 0}, {0, -1, 0}}
	id, d := pick(r, cands)
	testing.expectf(t, id == 2 && abs(d - 14) < 1e-4, "id %v t %v", id, d)
	// something in front of both (a roof at 10): nothing pickable
	id, _ = pick(r, cands, 10)
	testing.expect(t, id == 0)
	// only the far one is under this ray
	cands[1].world = Mat4(linalg.matrix4_translate_f32({5, 5, 0}))
	id, _ = pick(r, cands)
	testing.expect(t, id == 1)
	id, _ = pick(Ray{{30, 20, 0}, {0, -1, 0}}, cands)
	testing.expect(t, id == 0)
}

@(test)
cursor_lands_on_what_is_drawn :: proc(t: ^testing.T) {
	for s in ([?]f32{1, 0.005}) {
		ter := street(t, s)
		defer terrain.destroy(&ter)
		cam := iso_cam({50, 6, 50} * s, 45, 80 * s, 16.0 / 9)

		// street: the cursor over a street point finds that point
		q := [3]f32{20, street_y(20), 70} * s
		p, ts, ok := cursor_point(ray_of(t, cam, to_ndc(cam, q)), ter, true, 0)
		testing.expect(t, ok)
		testing.expectf(t, linalg.length(p - q) < 0.3 * s, "scale %v: street %v, cursor %v", s, q, p)
		testing.expect(t, ts < max(f32))

		// roof: the cursor stops on it, not on the ground behind
		roof := [3]f32{50, street_y(50) + BLD_H, 50} * s
		p, _, ok = cursor_point(ray_of(t, cam, to_ndc(cam, roof)), ter, true, 0)
		testing.expect(t, ok)
		testing.expectf(t, linalg.length(p - roof) < 0.5 * s, "scale %v: roof %v, cursor %v", s, roof, p)

		// no terrain: the plane
		p, ts, ok = cursor_point(ray_of(t, cam, to_ndc(cam, {20, 0, 20} * s)), ter, false, 0)
		testing.expect(t, ok && ts == max(f32))
		testing.expectf(t, linalg.length(p - [3]f32{20, 0, 20} * s) < 1e-3 * s, "plane: %v", p)
	}
}

// ---------------------------------------------------------------------------
// Click or drag
// ---------------------------------------------------------------------------

@(test)
clicks_and_drags :: proc(t: ^testing.T) {
	c: Click
	testing.expect(t, !click_update(&c, false, {100, 100}))
	testing.expect(t, !click_update(&c, true, {100, 100}), "press")
	testing.expect(t, !click_update(&c, true, {103, 102}), "jitter")
	testing.expect(t, !c.dragged)
	testing.expect(t, click_update(&c, false, {103, 102}), "release: a click")
	testing.expect(t, !click_update(&c, false, {103, 102}), "one click per press")

	testing.expect(t, !click_update(&c, true, {100, 100}))
	click_update(&c, true, {120, 100})
	testing.expect(t, c.dragged, "moved 20 px: a drag")
	click_update(&c, true, {101, 100}) // back near the start: still a drag
	testing.expect(t, !click_update(&c, false, {101, 100}), "a drag is not a click")
	testing.expect(t, !c.dragged)
}

// ---------------------------------------------------------------------------
// Instances and modes
// ---------------------------------------------------------------------------

at :: proc(x, z: f32, asset := 0) -> Instance {
	return Instance{asset = asset, transform = {position = {x, 0, z}, scale = {1, 1, 1}, up = {0, 1, 0}}}
}

@(test)
ids_are_stable :: proc(t: ^testing.T) {
	e: Editor
	defer destroy(&e)
	a := add(&e, at(1, 1))
	b := add(&e, at(2, 2))
	c := add(&e, at(3, 3))
	testing.expect(t, a == 1 && b == 2 && c == 3)
	testing.expect(t, remove(&e, b))
	testing.expect(t, !remove(&e, b), "already gone")
	d := add(&e, at(4, 4))
	testing.expectf(t, d == 4, "ids are not reused: %v", d)
	testing.expect(t, len(e.instances) == 3)
	testing.expect(t, e.instances[0].id == a && e.instances[1].id == c && e.instances[2].id == d, "order kept")
	inst, _ := find(&e, c)
	testing.expect(t, inst != nil && inst.transform.position.x == 3)
	inst, _ = find(&e, 0)
	testing.expect(t, inst == nil)

	reset(&e)
	testing.expect(t, len(e.instances) == 0)
	testing.expect(t, add(&e, at(0, 0)) == 5, "ids keep counting after a reset")
}

@(test)
stamping_several_vehicles :: proc(t: ^testing.T) {
	e: Editor
	defer destroy(&e)
	template := at(0, 0)
	template.transform.rotation.y = 1
	begin_place(&e, template)
	testing.expect(t, e.mode == .Place)
	testing.expect(t, active(&e) == &e.preview, "the keyboard edits the preview")

	for i in 0 ..< 3 {
		e.preview.transform.position.x = f32(i) * 5 // the cursor moved
		id := commit(&e)
		testing.expect(t, id != 0)
		testing.expect(t, e.selected == id, "the new one is selected")
		testing.expect(t, e.mode == .Place, "and placing goes on")
	}
	testing.expect(t, len(e.instances) == 3)
	for inst, i in e.instances {
		testing.expect(t, inst.transform.position.x == f32(i) * 5)
		testing.expect(t, inst.transform.rotation.y == 1, "rotation comes from the template")
	}
	select(&e, e.instances[0].id)
	testing.expect(t, e.selected == e.instances[2].id, "no selecting while placing")

	cancel(&e)
	testing.expect(t, e.mode == .Select && len(e.instances) == 3, "Esc stops placing, keeps what was placed")
	select(&e, e.instances[0].id)
	testing.expect(t, e.selected == e.instances[0].id)
	select(&e, 0)
	testing.expect(t, e.selected == 0, "click on nothing deselects")
}

@(test)
move_commit_and_cancel :: proc(t: ^testing.T) {
	e: Editor
	defer destroy(&e)
	testing.expect(t, !begin_move(&e), "nothing selected")
	id := add(&e, at(1, 1))
	select(&e, id)
	testing.expect(t, begin_move(&e))
	testing.expect(t, e.mode == .Move)
	active(&e).transform.position = {7, 0, 8}
	active(&e).transform.rotation.y = 2
	cancel(&e)
	inst := selected(&e)
	testing.expect(t, e.mode == .Select)
	testing.expectf(t, inst.transform.position == {1, 0, 1} && inst.transform.rotation.y == 0, "Esc undoes the move: %v", inst.transform)
	testing.expect(t, e.selected == id, "and keeps the selection")

	begin_move(&e)
	active(&e).transform.position = {7, 0, 8}
	testing.expect(t, commit(&e) == id)
	testing.expect(t, e.mode == .Select && selected(&e).transform.position == {7, 0, 8})

	// starting to place mid-move puts the object back first
	begin_move(&e)
	active(&e).transform.position = {50, 0, 50}
	begin_place(&e, selected(&e)^)
	testing.expect(t, e.mode == .Place)
	testing.expect(t, selected(&e).transform.position == {7, 0, 8})
	testing.expect(t, e.preview.id == 0, "the preview is not an instance")
}

@(test)
deleting :: proc(t: ^testing.T) {
	e: Editor
	defer destroy(&e)
	testing.expect(t, !delete_selected(&e))
	a := add(&e, at(1, 1))
	b := add(&e, at(2, 2))
	select(&e, a)
	testing.expect(t, delete_selected(&e))
	testing.expect(t, e.selected == 0 && len(e.instances) == 1 && e.instances[0].id == b)

	select(&e, b)
	begin_move(&e)
	testing.expect(t, delete_selected(&e), "mid-move")
	testing.expect(t, e.mode == .Select && len(e.instances) == 0)
	testing.expect(t, active(&e) == nil)

	// while placing: removes the one just stamped, keeps placing
	begin_place(&e, at(0, 0))
	commit(&e)
	commit(&e)
	testing.expect(t, delete_selected(&e))
	testing.expect(t, len(e.instances) == 1 && e.mode == .Place)
}

// ---------------------------------------------------------------------------
// Settling on the terrain
// ---------------------------------------------------------------------------

@(test)
settles_on_the_slope :: proc(t: ^testing.T) {
	s := f32(0.005)
	ter := street(t, s)
	defer terrain.destroy(&ter)
	size := [3]f32{4, 1.5, 2} // metres

	// the ground map reads a cell's lowest cluster of splats, so on a 10% slope
	// it sits up to half a 0.5 m cell's rise (2.5 cm) low, and the footprint
	// samples a little more: 8 cm tolerance
	TOL :: f32(0.08)
	inst := at(20 * s, 70 * s)
	settle(&inst, size, s, 20 * math.RAD_PER_DEG, ter, true)
	testing.expect(t, inst.on_terrain)
	testing.expectf(t, abs(inst.transform.position.y - street_y(20) * s) < TOL * s, "y %v, street %v", inst.transform.position.y / s, street_y(20))
	testing.expect(t, inst.transform.up == {0, 1, 0}, "upright without align")

	inst.align = true
	inst.offset = 0.1 * s
	settle(&inst, size, s, 20 * math.RAD_PER_DEG, ter, true)
	tilt := math.acos(inst.transform.up.y) * math.DEG_PER_RAD
	testing.expectf(t, abs(tilt - math.atan(SLOPE) * math.DEG_PER_RAD) < 0.5, "tilt %v", tilt)
	testing.expectf(t, abs(inst.transform.position.y - (street_y(20) + 0.1) * s) < TOL * s, "offset: y %v", inst.transform.position.y / s)

	// the plane keeps the last terrain height
	inst.snap = .Plane
	settle(&inst, size, s, 20 * math.RAD_PER_DEG, ter, true)
	testing.expectf(t, abs(inst.transform.position.y - street_y(20) * s) < TOL * s, "plane at %v", inst.transform.position.y / s)
	testing.expect(t, inst.transform.up == {0, 1, 0} && !inst.on_terrain)

	// surface: on the roof
	inst.snap = .Surface
	inst.offset = 0
	inst.transform.position.xz = [2]f32{50, 50} * s
	settle(&inst, size, s, 20 * math.RAD_PER_DEG, ter, true)
	testing.expectf(t, abs(inst.transform.position.y - (street_y(50) + BLD_H) * s) < 0.1 * s, "roof: y %v", inst.transform.position.y / s)
	// ground: under the building, from the street around it
	inst.snap = .Ground
	settle(&inst, size, s, 20 * math.RAD_PER_DEG, ter, true)
	testing.expectf(t, abs(inst.transform.position.y - street_y(50) * s) < 0.3 * s, "under the roof: y %v", inst.transform.position.y / s)
}

@(test)
yaw_wraps :: proc(t: ^testing.T) {
	testing.expect(t, abs(wrap_yaw(-math.PI / 2) - 3 * math.PI / 2) < 1e-5)
	testing.expect(t, abs(wrap_yaw(5 * math.PI) - math.PI) < 1e-5)
	testing.expect(t, wrap_yaw(0) == 0)
}
