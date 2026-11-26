package splatsort

import "core:log"
import "core:math"
import "core:math/rand"
import "core:testing"
import "core:time"

// The sort as it was in splat.odin, one thread, no culling: the reference.
@(private = "file")
serial :: proc(pos: [][3]f32, cam, fwd: [3]f32, far: f32, depth: []f32, order: []u32) -> int {
	counts := new([BUCKETS]u32, context.temp_allocator)
	lo, hi := max(f32), -max(f32)
	for p, i in pos {
		d := (p.x - cam.x) * fwd.x + (p.y - cam.y) * fwd.y + (p.z - cam.z) * fwd.z
		depth[i] = d
		if d > NEAR && d < far {
			lo = min(lo, d)
			hi = max(hi, d)
		}
	}
	if hi <= lo do return 0
	scale := f32(BUCKETS - 1) / (hi - lo)
	for d in depth do if d > NEAR && d < far do counts[bucket(d, lo, scale)] += 1
	sum: u32
	for i in 0 ..< BUCKETS {
		c := counts[i]
		counts[i] = sum
		sum += c
	}
	for d, i in depth {
		if d > NEAR && d < far {
			b := bucket(d, lo, scale)
			order[counts[b]] = u32(i)
			counts[b] += 1
		}
	}
	return int(sum)
}

@(private = "file")
cloud :: proc(n: int, seed: u64) -> (pos: [][3]f32, radius: []f32) {
	state := rand.create(seed)
	r := rand.default_random_generator(&state)
	pos = make([][3]f32, n, context.temp_allocator)
	radius = make([]f32, n, context.temp_allocator)
	for i in 0 ..< n {
		pos[i] = {rand.float32(r) * 100 - 50, rand.float32(r) * 20, rand.float32(r) * 100 - 50}
		radius[i] = rand.float32(r) * 0.5
	}
	return
}

@(private = "file")
Buffers :: struct {
	depth:    []f32,
	order:    []u32,
	order_px: []u8,
}

@(private = "file")
buffers :: proc(n: int) -> Buffers {
	return {
		depth    = make([]f32, n, context.temp_allocator),
		order    = make([]u32, n, context.temp_allocator),
		order_px = make([]u8, n * 4, context.temp_allocator),
	}
}

@(private = "file")
CAM :: [3]f32{60, 50, 60}

@(private = "file")
fwd_of :: proc() -> [3]f32 {
	f := -CAM
	l := math.sqrt(f.x * f.x + f.y * f.y + f.z * f.z)
	return f / l
}

@(test)
same_order_as_the_serial_sort :: proc(t: ^testing.T) {
	N :: 300_000 // over PARALLEL_FROM
	pos, _ := cloud(N, 7)
	fwd := fwd_of()
	ref := buffers(N)
	want := serial(pos, CAM, fwd, 1000, ref.depth, ref.order)
	testing.expect(t, want == N, "all in front")

	for workers in ([]int{1, 3, 8, 13}) {
		s: Sorter
		sorter_init(&s, workers)
		defer sorter_destroy(&s)
		b := buffers(N)
		got := sort(&s, {pos = pos, cam = CAM, fwd = fwd, far = 1000}, {b.depth, b.order, b.order_px})
		testing.expectf(t, got == want, "%d workers: %d visible, serial %d", workers, got, want)
		same := true
		for k in 0 ..< want {
			if b.order[k] != ref.order[k] {
				same = false
				testing.expectf(t, false, "%d workers: order differs at %d", workers, k)
				break
			}
		}
		if same {
			// and packed for the shader
			k := want / 2
			id := ref.order[k]
			px := b.order_px[k * 4:]
			testing.expect(t, px[0] == u8(id) && px[1] == u8(id >> 8) && px[2] == u8(id >> 16) && px[3] == 255, "packed")
		}
	}
}

@(test)
near_and_far :: proc(t: ^testing.T) {
	pos := [][3]f32{{0, 0, -5}, {0, 0, 5}, {0, 0, 50}, {0, 0, 20}}
	s: Sorter
	sorter_init(&s, 2)
	defer sorter_destroy(&s)
	b := buffers(len(pos))
	n := sort(&s, {pos = pos, cam = {}, fwd = {0, 0, 1}, far = 30}, {b.depth, b.order, b.order_px})
	testing.expect_value(t, n, 2)
	testing.expect_value(t, b.order[0], u32(3)) // the far one first
	testing.expect_value(t, b.order[1], u32(1))

	none := sort(&s, {pos = pos, cam = {0, 0, 100}, fwd = {0, 0, 1}, far = 30}, {b.depth, b.order, b.order_px})
	testing.expect_value(t, none, 0)
}

@(test)
culling_keeps_what_reaches_the_view :: proc(t: ^testing.T) {
	N :: 250_000
	pos, radius := cloud(N, 3)
	fwd := fwd_of()
	up0 := [3]f32{0, 1, 0}
	right := [3]f32{fwd.y * up0.z - fwd.z * up0.y, fwd.z * up0.x - fwd.x * up0.z, fwd.x * up0.y - fwd.y * up0.x}
	rl := math.sqrt(right.x * right.x + right.y * right.y + right.z * right.z)
	right /= rl
	up := [3]f32{right.y * fwd.z - right.z * fwd.y, right.z * fwd.x - right.x * fwd.z, right.x * fwd.y - right.y * fwd.x}
	cull := Cull{enabled = true, centre = {10, 0, -5}, right = right, up = up, half = {12, 7}}

	s: Sorter
	sorter_init(&s, 6)
	defer sorter_destroy(&s)
	b := buffers(N)
	n := sort(&s, {pos = pos, radius = radius, cam = CAM, fwd = fwd, far = 1000, cull = cull}, {b.depth, b.order, b.order_px})

	expected := 0
	inside := make([]bool, N, context.temp_allocator)
	for p, i in pos {
		o := p - cull.centre
		x := o.x * right.x + o.y * right.y + o.z * right.z
		y := o.x * up.x + o.y * up.y + o.z * up.z
		if abs(x) <= cull.half.x + radius[i] && abs(y) <= cull.half.y + radius[i] {
			expected += 1
			inside[i] = true
		}
	}
	testing.expect_value(t, n, expected)
	testing.expectf(t, n < N / 3, "most of the cloud culled: %d of %d", n, N)
	for k in 0 ..< n do if !inside[b.order[k]] {
		testing.expectf(t, false, "splat %d drawn but outside", b.order[k])
		break
	}
	// still back to front
	for k in 1 ..< n {
		if b.depth[b.order[k]] > b.depth[b.order[k - 1]] + 0.01 {
			testing.expectf(t, false, "not back to front at %d", k)
			break
		}
	}
}

// Not pass / fail: the serial sort against the parallel one on 2.85 M
// splats, as in the Krakow capture, with and without culling. Logged.
@(test)
speed :: proc(t: ^testing.T) {
	N :: 2_850_000
	pos, radius := cloud(N, 1)
	fwd := fwd_of()
	ref := buffers(N)
	t0 := time.tick_now()
	serial(pos, CAM, fwd, 1000, ref.depth, ref.order)
	serial_ms := time.duration_milliseconds(time.tick_since(t0))

	s: Sorter
	sorter_init(&s)
	defer sorter_destroy(&s)
	b := buffers(N)
	run :: proc(s: ^Sorter, in_: Input, b: Buffers) -> f64 {
		best := max(f64)
		for _ in 0 ..< 3 {
			t := time.tick_now()
			sort(s, in_, {b.depth, b.order, b.order_px})
			best = min(best, time.duration_milliseconds(time.tick_since(t)))
		}
		return best
	}
	all_ms := run(&s, {pos = pos, cam = CAM, fwd = fwd, far = 1000}, b)
	cull := Cull{enabled = true, centre = {}, right = {0.707, 0, -0.707}, up = {0, 1, 0}, half = {20, 12}}
	cull_ms := run(&s, {pos = pos, radius = radius, cam = CAM, fwd = fwd, far = 1000, cull = cull}, b)
	log.infof("2.85 M splats: serial %.1f ms (without packing), %d workers %.1f ms, culled to a third of the view %.1f ms", serial_ms, s.workers, all_ms, cull_ms)
}
