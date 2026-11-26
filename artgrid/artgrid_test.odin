package artgrid

import "core:math"
import "core:math/rand"
import "core:testing"

// a turned, tilted view plane like the iso camera's (azimuth az, elevation 38°)
axes :: proc(az_deg: f32) -> (right, up: [3]f32) {
	az := az_deg * math.RAD_PER_DEG
	el := f32(38) * math.RAD_PER_DEG
	fwd := [3]f32{-math.sin(az) * math.cos(el), -math.sin(el), -math.cos(az) * math.cos(el)}
	right = norm(cross(fwd, {0, 1, 0}))
	up = cross(right, fwd)
	return
}
cross :: proc(a, b: [3]f32) -> [3]f32 {return {a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x}}
norm :: proc(a: [3]f32) -> [3]f32 {return a / math.sqrt(dot(a, a))}

// Where a world point shows on screen through the snapped render and the
// shifted picture, against where an unsnapped camera would put it.
@(test)
snap_and_shift_match_the_true_view :: proc(t: ^testing.T) {
	r := rand.create(7)
	context.random_generator = rand.default_random_generator(&r)
	win := [2]f32{1280, 720}
	worst: f32
	for _ in 0 ..< 2000 {
		right, up := axes(rand.float32_range(0, 360))
		density := rand.float32_range(20, 2000) // art pixels per world unit
		lo, hi := view_range(win.y, density, 2, 12)
		vh := rand.float32_range(lo, hi)
		target := [3]f32{rand.float32_range(-1, 1), rand.float32_range(-0.1, 0.1), rand.float32_range(-1, 1)}
		g := game(win, density, vh, target, right, up)
		testing.expect(t, g.scale >= 2 - 1e-3 && g.scale <= 12 + 1e-3)
		testing.expect(t, g.w % 2 == 0 && g.h % 2 == 0)
		for _ in 0 ..< 8 {
			p := target + right * rand.float32_range(-0.6, 0.6) * vh * 2 + up * rand.float32_range(-0.6, 0.6) * vh
			// the true view, screen pixels
			want := [2]f32{
				(dot(p, right) - dot(target, right)) * density * g.scale + win.x / 2,
				-(dot(p, up) - dot(target, up)) * density * g.scale + win.y / 2,
			}
			// the render: art pixel in the target, from its top-left
			tx := (dot(p, right) - dot(g.snapped, right)) * density + f32(g.w) / 2
			ty := -(dot(p, up) - dot(g.snapped, up)) * density + f32(g.h) / 2
			got := g.origin + [2]f32{tx, ty} * g.scale
			worst = max(worst, abs(got.x - want.x), abs(got.y - want.y))
		}
	}
	// f32 world coordinates at up to 2000 px per unit, times 12: well under a pixel
	testing.expectf(t, worst < 0.05, "off by %v screen pixels", worst)
}

@(test)
picture_covers_the_window :: proc(t: ^testing.T) {
	right, up := axes(45)
	win := [2]f32{1280, 720}
	for vh := f32(0.1); vh <= 0.6; vh += 0.0137 {
		for k in 0 ..< 10 {
			target := [3]f32{f32(k) * 0.00173, 0, -f32(k) * 0.00091}
			g := game(win, 1200, vh, target, right, up)
			testing.expectf(t, g.origin.x <= 0 && g.origin.y <= 0, "origin %v", g.origin)
			testing.expectf(t, g.origin.x + g.size.x >= win.x && g.origin.y + g.size.y >= win.y, "end %v", g.origin + g.size)
		}
	}
}

// A pan smaller than half an art pixel renders the same; the picture moves.
// Art pixel corners stay on the same world lattice at every zoom.
@(test)
grid_is_locked_to_the_world :: proc(t: ^testing.T) {
	right, up := axes(30)
	win := [2]f32{1280, 720}
	density := f32(1000)
	a := game(win, density, 0.3, {0.2, 0, 0.1}, right, up)
	b := game(win, density, 0.3, {0.2, 0, 0.1} + right * 0.2 / density, right, up)
	testing.expect_value(t, a.snapped, b.snapped)
	testing.expectf(t, abs((a.origin.x - b.origin.x) - 0.2 * a.scale) < 1e-2, "moved %v", a.origin.x - b.origin.x)

	// a world point's place within its art pixel, at two zooms (two target sizes)
	p := [3]f32{0.2137, 0, 0.0981}
	frac :: proc(g: Grid, p, right: [3]f32, density: f32) -> f32 {
		x := (dot(p, right) - dot(g.snapped, right)) * density + f32(g.w) / 2
		return x - math.floor(x)
	}
	c := game(win, density, 0.5, {0.2, 0, 0.1}, right, up)
	testing.expect(t, a.w != c.w)
	testing.expectf(t, abs(frac(a, p, right, density) - frac(c, p, right, density)) < 1e-3, "%v vs %v", frac(a, p, right, density), frac(c, p, right, density))
}

// A smooth zoom resizes the target every few steps, not every step.
@(test)
zoom_resizes_in_buckets :: proc(t: ^testing.T) {
	right, up := axes(45)
	win := [2]f32{1280, 720}
	lo, hi := view_range(win.y, 1000, 2, 12)
	steps, resizes := 0, 0
	last: [2]i32
	for vh := lo; vh <= hi; vh *= 1.01 {
		g := game(win, 1000, vh, {}, right, up)
		if (g.w != last.x || g.h != last.y) do resizes += 1
		last = {g.w, g.h}
		steps += 1
	}
	testing.expectf(t, resizes * 3 < steps, "%d resizes in %d steps", resizes, steps)
}

@(test)
fixed_is_whole_pixels :: proc(t: ^testing.T) {
	g := fixed({1280, 720}, 3, {1, 2, 3})
	testing.expect_value(t, g.w, 427)
	testing.expect_value(t, g.h, 240)
	testing.expect_value(t, g.scale, f32(3))
	testing.expect_value(t, g.origin, [2]f32{})
	testing.expect_value(t, g.snapped, [3]f32{1, 2, 3})
}
