package splatsort

// Back-to-front order of the splats for one view, on every core, and only
// of the splats the view can show.
//
// The same stable counting sort as before (65536 depth buckets, far splats
// first), split into chunks of splats, one per worker:
//
//   1. depth along the view, and whether the splat is kept: in front of the
//      near plane, before the far one, and (orthographic views) its radius
//      reaching the view's box. The depth range of what is kept.
//   2. a histogram of buckets per chunk
//   3. offsets: bucket by bucket, chunk by chunk, so the order is exactly the
//      serial sort's, whatever the number of workers
//   4. each chunk scatters its splats, then the order is packed into the
//      texture the shader reads
//
// The workers meet at a barrier between passes; one sort starts them once.
//
//   odin test splatsort

import "core:os"
import "core:sync"
import "core:thread"

BUCKETS :: 1 << 16
NEAR    :: f32(0.01)

// Skipped below this many splats: threads would cost more than they save.
PARALLEL_FROM :: 200_000

// An orthographic view's box, world units: splats that cannot reach it are
// left out of the order, so they are neither sorted nor drawn.
Cull :: struct {
	enabled:   bool,
	centre:    [3]f32, // the view's centre (the camera's target)
	right, up: [3]f32, // unit, across the screen
	half:      [2]f32, // half its width and height, any margin included
}

Sorter :: struct {
	workers: int,
	counts:  [][BUCKETS]u32, // per chunk
	lo, hi:  []f32,          // per chunk
	kept:    []int,          // per chunk
}

// workers 0: one per core, at most 16.
sorter_init :: proc(s: ^Sorter, workers := 0) {
	n := workers if workers > 0 else clamp(os.get_processor_core_count(), 1, 16)
	s.workers = n
	s.counts = make([][BUCKETS]u32, n)
	s.lo = make([]f32, n)
	s.hi = make([]f32, n)
	s.kept = make([]int, n)
}

sorter_destroy :: proc(s: ^Sorter) {
	delete(s.counts)
	delete(s.lo)
	delete(s.hi)
	delete(s.kept)
	s^ = {}
}

Input :: struct {
	pos:    [][3]f32,
	radius: []f32, // per splat, world units: how far it reaches; nil: 0
	cam:    [3]f32,
	fwd:    [3]f32,
	far:    f32,
	cull:   Cull,
}

Output :: struct {
	depth:    []f32, // scratch, one per splat
	order:    []u32, // the splats, back to front; the first `visible`
	order_px: []u8,  // the same packed for the shader: RGB = index, A = 255
}

@(private)
Job :: struct {
	s:       ^Sorter,
	in_:     ^Input,
	out:     ^Output,
	barrier: sync.Barrier,
	scale:   f32,
	lo:      f32,
	visible: int,
	chunks:  int,
}

// Sorts and returns how many splats are visible: order[:visible].
sort :: proc(s: ^Sorter, in_: Input, out: Output) -> (visible: int) {
	in_, out := in_, out
	n := len(in_.pos)
	chunks := s.workers if n >= PARALLEL_FROM else 1
	chunks = max(min(chunks, len(s.counts)), 1)
	job := Job{s = s, in_ = &in_, out = &out, chunks = chunks}
	sync.barrier_init(&job.barrier, chunks)
	threads := make([]^thread.Thread, chunks - 1, context.temp_allocator)
	for i in 1 ..< chunks {
		threads[i - 1] = thread.create_and_start_with_poly_data2(&job, i, work)
	}
	work(&job, 0)
	for t in threads {
		thread.join(t)
		thread.destroy(t)
	}
	return job.visible
}

@(private)
span :: #force_inline proc(n, chunks, c: int) -> (int, int) {
	return n * c / chunks, n * (c + 1) / chunks
}

@(private)
bucket :: #force_inline proc(d, lo, scale: f32) -> int {
	// far splats land in low buckets, so they are drawn first
	return (BUCKETS - 1) - min(int((d - lo) * scale), BUCKETS - 1)
}

@(private)
work :: proc(job: ^Job, c: int) {
	s, in_, out := job.s, job.in_, job.out
	n := len(in_.pos)
	a, b := span(n, job.chunks, c)
	cull := in_.cull
	has_radius := len(in_.radius) == n

	// 1. depth, kept, range
	lo, hi := max(f32), -max(f32)
	for i in a ..< b {
		p := in_.pos[i]
		q := p - in_.cam
		d := q.x * in_.fwd.x + q.y * in_.fwd.y + q.z * in_.fwd.z
		keep := d > NEAR && d < in_.far
		if keep && cull.enabled {
			r := in_.radius[i] if has_radius else 0
			o := p - cull.centre
			x := o.x * cull.right.x + o.y * cull.right.y + o.z * cull.right.z
			y := o.x * cull.up.x + o.y * cull.up.y + o.z * cull.up.z
			keep = abs(x) <= cull.half.x + r && abs(y) <= cull.half.y + r
		}
		if keep {
			lo = min(lo, d)
			hi = max(hi, d)
		} else {
			d = -1 // not kept: below NEAR
		}
		out.depth[i] = d
	}
	s.lo[c], s.hi[c] = lo, hi
	sync.barrier_wait(&job.barrier)

	if c == 0 {
		glo, ghi := max(f32), -max(f32)
		for k in 0 ..< job.chunks {
			glo = min(glo, s.lo[k])
			ghi = max(ghi, s.hi[k])
		}
		job.lo = glo
		job.scale = f32(BUCKETS - 1) / (ghi - glo) if ghi > glo else 0
		job.visible = -1 if ghi < glo else 0 // nothing kept
	}
	sync.barrier_wait(&job.barrier)
	if job.visible < 0 {
		sync.barrier_wait(&job.barrier) // keep step with pass 3's barrier
		if c == 0 do job.visible = 0
		return
	}

	// 2. histogram
	counts := &s.counts[c]
	counts^ = {}
	base, scale := job.lo, job.scale
	for i in a ..< b {
		d := out.depth[i]
		if d > NEAR do counts[bucket(d, base, scale)] += 1
	}
	sync.barrier_wait(&job.barrier)

	// 3. offsets, bucket-major then chunk: the serial sort's order
	if c == 0 {
		sum: u32
		for bk in 0 ..< BUCKETS {
			for k in 0 ..< job.chunks {
				v := s.counts[k][bk]
				s.counts[k][bk] = sum
				sum += v
			}
		}
		job.visible = int(sum)
	}
	sync.barrier_wait(&job.barrier)

	// 4. scatter, then pack
	for i in a ..< b {
		d := out.depth[i]
		if d > NEAR {
			bk := bucket(d, base, scale)
			out.order[counts[bk]] = u32(i)
			counts[bk] += 1
		}
	}
	sync.barrier_wait(&job.barrier)
	pa, pb := span(job.visible, job.chunks, c)
	for k in pa ..< pb {
		id := out.order[k]
		px := out.order_px[k * 4:]
		px[0] = u8(id)
		px[1] = u8(id >> 8)
		px[2] = u8(id >> 16)
		px[3] = 255
	}
}

// The reach of a splat from its scales: three standard deviations of its
// widest axis, what the shader draws.
radius_of :: proc(sx, sy, sz: f32) -> f32 {
	return 3 * max(sx, sy, sz)
}
