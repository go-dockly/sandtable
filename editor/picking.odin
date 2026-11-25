package editor

// Mouse to world: a ray from the cursor through the scene, where it meets the
// terrain, and which object it hits first.
//
// The matrices are raylib's (row-major storage, column-vector maths: M * v),
// the same ones the scene pass draws with, so a pick lines up with the picture
// whatever the camera (orthographic game view or perspective free view).

import "core:math"
import "core:math/linalg"

import "../terrain"

Mat4 :: #row_major matrix[4, 4]f32 // = rl.Matrix

Ray :: struct {
	origin: [3]f32,
	dir:    [3]f32, // unit length
}

// The ray under a point of the picture.
//
//   inv_vp  inverse(projection * view)
//   ndc     -1..1 across the picture, +y up (see ndc_from_screen)
//
// It starts on the near plane and points at the far plane, so in the
// orthographic game camera all rays are parallel and in the perspective one
// they fan out from the eye.
screen_ray :: proc(inv_vp: Mat4, ndc: [2]f32) -> (r: Ray, ok: bool) {
	a := inv_vp * [4]f32{ndc.x, ndc.y, -1, 1}
	b := inv_vp * [4]f32{ndc.x, ndc.y, 1, 1}
	if abs(a.w) < 1e-12 || abs(b.w) < 1e-12 do return {}, false
	near := a.xyz / a.w
	far := b.xyz / b.w
	d := far - near
	l := linalg.length(d)
	if !(l > 1e-20) do return {}, false // also NaN
	return Ray{near, d / l}, true
}

// Screen pixel -> ndc, for a picture drawn at (0, 0) with size w x h (it may
// run past the window: the art grid rounds up).
ndc_from_screen :: proc(p: [2]f32, w, h: f32) -> [2]f32 {
	return {p.x / max(w, 1) * 2 - 1, 1 - p.y / max(h, 1) * 2}
}

// Hit with the horizontal plane at height y, in front of the ray's origin.
ray_plane_y :: proc(r: Ray, y: f32) -> (hit: [3]f32, t: f32, ok: bool) {
	if abs(r.dir.y) < 1e-9 do return {}, 0, false
	t = (y - r.origin.y) / r.dir.y
	if t < 0 do return {}, 0, false
	return r.origin + r.dir * t, t, true
}

// Hit with a box: lo..hi in an object's own space, `world` its model matrix
// (any affine transform, scaled, rotated, tilted). t is the distance along the
// world ray: an affine map keeps the ray parameter, so the slabs are tested in
// object space and no distance needs converting back. A ray starting inside
// hits at 0.
ray_box :: proc(r: Ray, world: Mat4, lo, hi: [3]f32) -> (t: f32, ok: bool) {
	inv := linalg.inverse(world)
	o := (inv * [4]f32{r.origin.x, r.origin.y, r.origin.z, 1}).xyz
	d := (inv * [4]f32{r.dir.x, r.dir.y, r.dir.z, 0}).xyz
	t0, t1 := f32(0), max(f32)
	for axis in 0 ..< 3 {
		if abs(d[axis]) < 1e-20 {
			if o[axis] < lo[axis] || o[axis] > hi[axis] do return 0, false
			continue
		}
		a := (lo[axis] - o[axis]) / d[axis]
		b := (hi[axis] - o[axis]) / d[axis]
		if a > b do a, b = b, a
		t0 = max(t0, a)
		t1 = min(t1, b)
		if t0 > t1 do return 0, false
	}
	if math.is_nan(t0) do return 0, false
	return t0, true
}

// An object as picking sees it: its model matrix and its bounds in model space.
Candidate :: struct {
	id:     u64,
	world:  Mat4,
	lo, hi: [3]f32,
}

// The nearest object under the ray, nearer than max_t (what the terrain hides
// beyond that). 0 if none.
pick :: proc(r: Ray, candidates: []Candidate, max_t: f32 = max(f32)) -> (id: u64, t: f32) {
	best := max_t
	for c in candidates {
		if ct, ok := ray_box(r, c.world, c.lo, c.hi); ok && ct <= best {
			id, best = c.id, ct
		}
	}
	return id, best if id != 0 else 0
}

// Where the cursor is on the ground: the first thing it meets, so the top of
// what is drawn there (the surface, roofs included) - the instance's own snap
// mode then decides what it stands on. Outside the terrain, or without one, the
// horizontal plane at plane_y.
//
// t_surface is the distance to the surface hit (max if none): objects further
// away than that are behind something, see pick.
cursor_point :: proc(
	r: Ray, ter: terrain.Terrain, has_terrain: bool, plane_y: f32,
) -> (p: [3]f32, t_surface: f32, ok: bool) {
	t_surface = max(f32)
	if has_terrain {
		if hit, d, hok := terrain.raycast(ter, r.origin, r.dir, .Surface); hok {
			return hit, d, true
		}
	}
	hit, _, pok := ray_plane_y(r, plane_y)
	return hit, t_surface, pok
}

// ---------------------------------------------------------------------------
// Click or drag. The left button also turns the camera, so a press only counts
// as a click if the cursor stayed put; once it has moved further than
// CLICK_SLOP it is a drag, and the camera may turn.
// ---------------------------------------------------------------------------

CLICK_SLOP :: f32(5) // screen pixels

Click :: struct {
	down:    bool,
	start:   [2]f32,
	dragged: bool, // this press has moved further than CLICK_SLOP
}

// Feed the button state and the cursor once a frame. true on the release of a
// press that did not drag.
click_update :: proc(c: ^Click, down: bool, pos: [2]f32) -> (clicked: bool) {
	switch {
	case down && !c.down:
		c.down, c.start, c.dragged = true, pos, false
	case down:
		if linalg.length(pos - c.start) > CLICK_SLOP do c.dragged = true
	case c.down:
		c.down = false
		clicked = !c.dragged
		c.dragged = false
	}
	return
}
