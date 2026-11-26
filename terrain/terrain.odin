package terrain

// Terrain proxy (Block 5): a heightmap built from the splat cloud, so placement
// can ask "how high is the ground here, and which way is up".
//
//   cloud positions (+ opacity)
//        |  bin into an x/z grid, per cell the lowest height a few splats agree
//        |  on & a high quantile of the heights
//        v
//   surface (DSM)  top of whatever is there: roofs, canopies, cars
//   ground  (DTM)  bare ground: a progressive morphological filter removes
//                  everything narrower than `max_object`, the holes it leaves
//                  (under buildings, under trees) are filled smoothly
//        |
//        v
//   sample_height / sample_normal / sample_surface / fit_footprint / raycast
//
// +Y is up (SPZ's RUB frame, as everywhere in sandtable). The grid lies in x/z.
// All lengths are world units; default_params converts metric defaults with
// the world scale (world units per metre), so the same defaults work for a
// metric capture and for Krakow at ~0.005 units/m.
//
// A heightmap has one height per x/z: walls are vertical steps between cells,
// overhangs, bridges and interiors are not represented. That is enough for
// standing objects on the ground and for a grey-box of the level.
//
// No raylib in here, so the package can be tested on its own:
//   odin test terrain

import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:os"
import "core:slice"
import "core:strings"

Layer :: enum u8 {
	Ground,  // DTM: bare ground, objects filtered out
	Surface, // DSM: top surface, roofs and canopies included
}

Class :: enum u8 {
	Empty,     // no (or too few) splats: heights are interpolated
	Ground,
	Object,    // removed by the ground filter, or object_height..structure_height tall: cars, hedges, rubble
	Structure, // structure_height or more above the ground: buildings, walls, trees
}

Terrain :: struct {
	origin:  [2]f32, // world x, z of the outer corner of cell (0, 0)
	cell:    f32,    // cell size, world units
	w, h:    int,    // cells along x and along z
	ground:  []f32,  // w * h heights, index z * w + x
	surface: []f32,
	floor:   []f32,  // the lowest height a few splats agree on, before the
	                 // ground filter: near the ground under a canopy, at the
	                 // roof under a roof. The ground where there is no data
	class:   []Class,
	count:   []u32,  // splats binned per cell
	lo, hi:  f32,    // lowest ground, highest surface
	params:  Params, // what it was built with, cell resolved
	stats:   Stats,
}

Stats :: struct {
	splats_used:     int,
	data_cells:      int,
	ground_cells:    int,
	object_cells:    int,
	structure_cells: int,
}

Params :: struct {
	cell:             f32, // cell size; <= 0: from max_cells
	max_cells:        int, // cells per axis at most; the cell grows to fit
	min_opacity:      f32, // splats below this are ignored (floaters, haze)
	min_count:        int, // fewer splats than this in a cell: no data
	ground_quantile:  f32, // per cell, the height taken as its lowest surface when
	                       // no GROUND_CLUSTER splats agree on one (lowest_cluster)
	surface_quantile: f32, // and as its top
	max_object:       f32, // widest thing the ground filter removes: a building
	slope:            f32, // steepest ground kept as ground, rise / run
	dh0:              f32, // ground filter height tolerance at the smallest window
	dh_max:           f32, // and its cap
	object_height:    f32, // surface this far above the ground is at least an Object
	structure_height: f32, // and this far a Structure
	smooth:           int, // 3x3 mean passes over the finished ground
	adapt_cell:       bool, // grow the cell until cells hold MIN_SPLATS_PER_CELL
}

// Metric defaults, in world units through world_scale (world units per metre).
default_params :: proc(world_scale: f32 = 1) -> Params {
	m := world_scale if world_scale > 0 else 1
	return Params{
		cell             = 0.5 * m,
		max_cells        = 1024,
		min_opacity      = 0.2,
		min_count        = 2,
		ground_quantile  = 0.05,
		surface_quantile = 0.9,
		max_object       = 40 * m,
		slope            = 0.15,
		dh0              = 0.2 * m,
		dh_max           = 2.5 * m,
		object_height    = 0.5 * m,
		structure_height = 2 * m,
		smooth           = 1,
		adapt_cell       = true,
	}
}

destroy :: proc(t: ^Terrain) {
	if t == nil do return
	delete(t.ground)
	delete(t.surface)
	delete(t.floor)
	delete(t.class)
	delete(t.count)
	t^ = {}
}

valid :: proc(t: Terrain) -> bool {
	return t.w > 0 && t.h > 0 && len(t.ground) == t.w * t.h
}

// Bounds are the 0.5th..99.5th percentile of the used splats in x and z, so a
// few strays far outside the capture do not stretch the grid.
BOUNDS_QUANTILE :: f32(0.005)
// Bounds are measured on at most this many splats.
BOUNDS_SAMPLES :: 200_000
// Cells of padding around the bounds.
PAD :: 2
// With adapt_cell, the median occupied cell holds at least this many splats.
MIN_SPLATS_PER_CELL :: 8
// Relaxation sweeps when filling holes (under buildings, outside the capture).
FILL_SWEEPS :: 128

// pos: splat centres. opacity: per splat, or nil to use every splat.
build :: proc(pos: [][3]f32, opacity: []f32, params: Params) -> (t: Terrain, ok: bool) {
	p := params
	n := len(pos)
	if n == 0 do return {}, false
	use_opacity := len(opacity) == n
	used :: #force_inline proc(pos: [][3]f32, opacity: []f32, use_opacity: bool, min_op: f32, i: int) -> bool {
		q := pos[i]
		if !finite(q.x) || !finite(q.y) || !finite(q.z) do return false
		return !use_opacity || opacity[i] >= min_op
	}

	// ---- grid bounds ---------------------------------------------------------
	step := max(1, n / BOUNDS_SAMPLES)
	xs := make([dynamic]f32, 0, n / step + 1)
	zs := make([dynamic]f32, 0, n / step + 1)
	defer delete(xs)
	defer delete(zs)
	for i := 0; i < n; i += step {
		if !used(pos, opacity, use_opacity, p.min_opacity, i) do continue
		append(&xs, pos[i].x)
		append(&zs, pos[i].z)
	}
	if len(xs) < 4 do return {}, false
	slice.sort(xs[:])
	slice.sort(zs[:])
	m := len(xs)
	x0 := xs[int(f32(m - 1) * BOUNDS_QUANTILE)]
	x1 := xs[int(f32(m - 1) * (1 - BOUNDS_QUANTILE))]
	z0 := zs[int(f32(m - 1) * BOUNDS_QUANTILE)]
	z1 := zs[int(f32(m - 1) * (1 - BOUNDS_QUANTILE))]
	span := max(x1 - x0, z1 - z0)

	max_cells := max(p.max_cells, 8)
	cell := p.cell
	fit := span / f32(max_cells - 2 * PAD)
	if cell <= 0 || cell < fit do cell = fit
	if cell <= 0 || !finite(cell) do cell = 1

	// Count splats per cell; while a typical occupied cell holds too few for
	// its quantiles to mean anything, double the cell.
	start: []u32
	defer delete(start)
	cells: int
	for {
		w := min(int(math.ceil((x1 - x0) / cell)) + 2 * PAD, max_cells)
		h := min(int(math.ceil((z1 - z0) / cell)) + 2 * PAD, max_cells)
		t.w, t.h = max(w, 1), max(h, 1)
		t.origin = {x0 - PAD * cell, z0 - PAD * cell}
		t.cell = cell
		cells = t.w * t.h
		start = make([]u32, cells + 1)
		for i in 0 ..< n {
			if !used(pos, opacity, use_opacity, p.min_opacity, i) do continue
			if c, in_grid := cell_index(t, pos[i].x, pos[i].z); in_grid do start[c + 1] += 1
		}
		if !p.adapt_cell || cell * 2 > span / 16 || median_occupied(start[1:]) >= MIN_SPLATS_PER_CELL do break
		delete(start)
		cell *= 2
	}
	p.cell = cell
	t.params = p
	w, h := t.w, t.h

	for c in 0 ..< cells do start[c + 1] += start[c]
	ys := make([]f32, start[cells])
	defer delete(ys)
	fill := make([]u32, cells)
	defer delete(fill)
	copy(fill, start[:cells])
	for i in 0 ..< n {
		if !used(pos, opacity, use_opacity, p.min_opacity, i) do continue
		if c, in_grid := cell_index(t, pos[i].x, pos[i].z); in_grid {
			ys[fill[c]] = pos[i].y
			fill[c] += 1
		}
	}
	t.stats.splats_used = len(ys)

	// ---- per cell: a low and a high quantile ---------------------------------
	t.count = make([]u32, cells)
	low := make([]f32, cells)
	defer delete(low)
	high := make([]f32, cells)
	defer delete(high)
	has := make([]bool, cells)
	defer delete(has)
	min_count := max(p.min_count, 1)
	for c in 0 ..< cells {
		a, b := int(start[c]), int(start[c + 1])
		k := b - a
		t.count[c] = u32(k)
		if k < min_count do continue
		seg := ys[a:b]
		slice.sort(seg)
		low[c] = lowest_cluster(seg, GROUND_CLUSTER, p.dh0) or_else seg[quantile_index(k, p.ground_quantile)]
		high[c] = seg[quantile_index(k, p.surface_quantile)]
		has[c] = true
	}

	// single-cell pits (splats under the street) would be spread wide by the
	// erosion below; single-cell spikes (sky blobs) would stick up in the DSM
	remove_outliers(low, has, w, h, p.dh_max, false)
	remove_outliers(high, has, w, h, p.dh_max, true)
	t.stats.data_cells = count_true(has)
	if t.stats.data_cells == 0 {
		delete(t.count)
		return {}, false
	}

	// ---- ground filter (Zhang et al. 2003, progressive morphological filter) --
	// Opening the low surface with growing windows removes anything narrower
	// than the window; a cell that drops by more than the height tolerance is
	// not ground. The tolerance grows with the window by the allowed slope, so a
	// slope survives where a box of the same width does not.
	surf := make([]f32, cells)
	defer delete(surf)
	copy(surf, low)
	fill_holes(surf, has, w, h)
	opened := make([]f32, cells)
	defer delete(opened)
	scratch := make([]f32, cells)
	defer delete(scratch)
	not_ground := make([]bool, cells)
	defer delete(not_ground)

	r, prev_win := 1, 1
	for {
		win := 2 * r + 1
		opening(surf, opened, scratch, w, h, r)
		dh := min(p.dh0 + p.slope * f32(win - prev_win) * cell, p.dh_max)
		for c in 0 ..< cells {
			if surf[c] - opened[c] > dh do not_ground[c] = true
		}
		surf, opened = opened, surf
		prev_win = win
		if f32(win) * cell >= p.max_object || r >= max(w, h) do break
		r *= 2
	}

	// ---- ground: the low surface where it is ground, filled in between -------
	is_ground := make([]bool, cells)
	defer delete(is_ground)
	t.ground = make([]f32, cells)
	any_ground := false
	for c in 0 ..< cells {
		is_ground[c] = has[c] && !not_ground[c]
		if is_ground[c] {
			t.ground[c] = low[c]
			any_ground = true
		}
	}
	if !any_ground {
		// everything was filtered: fall back to the low surface
		copy(t.ground, low)
		copy(is_ground, has)
	}
	fill_holes(t.ground, is_ground, w, h)
	for _ in 0 ..< max(p.smooth, 0) do mean_3x3(t.ground, scratch, w, h)

	// ---- surface: the high quantile, the ground where there is no data -------
	t.surface = make([]f32, cells)
	t.floor = make([]f32, cells)
	t.class = make([]Class, cells)
	t.lo, t.hi = max(f32), -max(f32)
	for c in 0 ..< cells {
		g := t.ground[c]
		s := high[c] if has[c] else g
		s = max(s, g)
		t.surface[c] = s
		t.floor[c] = clamp(low[c], g, s) if has[c] else g
		switch {
		case !has[c]:
			t.class[c] = .Empty
		case s - g >= p.structure_height:
			t.class[c] = .Structure
			t.stats.structure_cells += 1
		case not_ground[c] || s - g >= p.object_height:
			t.class[c] = .Object
			t.stats.object_cells += 1
		case:
			t.class[c] = .Ground
			t.stats.ground_cells += 1
		}
		t.lo = min(t.lo, g)
		t.hi = max(t.hi, s)
	}
	return t, true
}

median_occupied :: proc(counts: []u32) -> u32 {
	occupied := make([dynamic]u32, 0, len(counts))
	defer delete(occupied)
	for c in counts {
		if c > 0 do append(&occupied, c)
	}
	if len(occupied) == 0 do return 0
	slice.sort(occupied[:])
	return occupied[len(occupied) / 2]
}

// The lowest height at least n of the (sorted) heights agree on within tol:
// the street in a cell beside a wall, where the wall's splats outnumber the
// street's, and not a lone splat under the street.
GROUND_CLUSTER :: 3

lowest_cluster :: proc(sorted: []f32, n: int, tol: f32) -> (y: f32, ok: bool) {
	for i in 0 ..= len(sorted) - n {
		if sorted[i + n - 1] - sorted[i] <= tol do return sorted[i + (n - 1) / 2], true
	}
	return 0, false
}

quantile_index :: #force_inline proc(n: int, q: f32) -> int {
	return clamp(int(f32(n - 1) * q + 0.5), 0, n - 1)
}

// Cell containing world x, z.
cell_index :: proc(t: Terrain, x, z: f32) -> (c: int, inside: bool) {
	fx := (x - t.origin.x) / t.cell
	fz := (z - t.origin.y) / t.cell
	if !(fx >= 0 && fz >= 0) do return 0, false // also catches NaN
	ix, iz := int(fx), int(fz)
	if ix >= t.w || iz >= t.h do return 0, false
	return iz * t.w + ix, true
}

// World x, z of the centre of cell (ix, iz).
cell_center :: proc(t: Terrain, ix, iz: int) -> [2]f32 {
	return t.origin + {(f32(ix) + 0.5) * t.cell, (f32(iz) + 0.5) * t.cell}
}

heights :: proc(t: Terrain, layer: Layer) -> []f32 {
	return t.ground if layer == .Ground else t.surface
}

// Height at world x, z, bilinear between cell centres. Outside the grid the
// edge is extended and `inside` is false.
sample_height :: proc(t: Terrain, x, z: f32, layer := Layer.Ground) -> (y: f32, inside: bool) {
	if !valid(t) do return 0, false
	v := heights(t, layer)
	gx := (x - t.origin.x) / t.cell
	gz := (z - t.origin.y) / t.cell
	inside = gx >= 0 && gz >= 0 && gx <= f32(t.w) && gz <= f32(t.h)
	fx := clamp(gx - 0.5, 0, f32(t.w - 1))
	fz := clamp(gz - 0.5, 0, f32(t.h - 1))
	ix := min(int(fx), t.w - 1)
	iz := min(int(fz), t.h - 1)
	ix1 := min(ix + 1, t.w - 1)
	iz1 := min(iz + 1, t.h - 1)
	tx := fx - f32(ix)
	tz := fz - f32(iz)
	a := v[iz * t.w + ix]
	b := v[iz * t.w + ix1]
	c := v[iz1 * t.w + ix]
	d := v[iz1 * t.w + ix1]
	y = math.lerp(math.lerp(a, b, tx), math.lerp(c, d, tx), tz)
	return
}

// Unit normal at world x, z from central differences one cell apart.
sample_normal :: proc(t: Terrain, x, z: f32, layer := Layer.Ground) -> [3]f32 {
	if !valid(t) do return {0, 1, 0}
	e := t.cell
	xa, _ := sample_height(t, x - e, z, layer)
	xb, _ := sample_height(t, x + e, z, layer)
	za, _ := sample_height(t, x, z - e, layer)
	zb, _ := sample_height(t, x, z + e, layer)
	return normal_from_gradient((xb - xa) / (2 * e), (zb - za) / (2 * e))
}

sample_surface :: proc(t: Terrain, x, z: f32, layer := Layer.Ground) -> (height: f32, normal: [3]f32, inside: bool) {
	height, inside = sample_height(t, x, z, layer)
	normal = sample_normal(t, x, z, layer)
	return
}

normal_from_gradient :: proc(dydx, dydz: f32) -> [3]f32 {
	n := [3]f32{-dydx, 1, -dydz}
	return n / math.sqrt(n.x * n.x + n.y * n.y + n.z * n.z)
}

// Where an object with this footprint rests: a least-squares plane through the
// terrain under it, so a car on a slope takes the slope of the road rather
// than of the single point under its pivot.
//
//   center   world x, z of the pivot
//   half     half size of the footprint in the object's own x and z, world units
//   yaw      the object's rotation around +Y, radians (raylib's MatrixRotateY)
//   max_tilt the normal is clamped to this angle from vertical, radians
//
// height is the plane at the pivot; normal is the plane's, clamped.
FOOTPRINT_SAMPLES :: 5 // per side

fit_footprint :: proc(
	t: Terrain,
	center: [2]f32,
	half: [2]f32,
	yaw: f32,
	layer := Layer.Ground,
	max_tilt: f32 = math.PI / 6,
) -> (height: f32, normal: [3]f32, inside: bool) {
	if !valid(t) do return 0, {0, 1, 0}, false
	_, inside = sample_height(t, center.x, center.y, layer)
	if half.x <= 0 && half.y <= 0 {
		height, normal, _ = sample_surface(t, center.x, center.y, layer)
		return height, clamp_tilt(normal, max_tilt), inside
	}

	cs, sn := math.cos(yaw), math.sin(yaw)
	K :: FOOTPRINT_SAMPLES
	sum_y, sxx, sxz, szz, sxy, szy: f32
	for j in 0 ..< K {
		for i in 0 ..< K {
			u := (f32(i) / f32(K - 1) * 2 - 1) * half.x
			v := (f32(j) / f32(K - 1) * 2 - 1) * half.y
			// object x/z -> world offset, as MatrixRotateY(yaw)
			dx := cs * u + sn * v
			dz := -sn * u + cs * v
			y, _ := sample_height(t, center.x + dx, center.y + dz, layer)
			sum_y += y
			sxx += dx * dx
			sxz += dx * dz
			szz += dz * dz
			sxy += dx * y
			szy += dz * y
		}
	}
	// the sample pattern is symmetric about the pivot, so the offsets sum to
	// zero and the plane's height at the pivot is the mean
	// (and Σdx·(y - mean) = Σdx·y, so the slopes need no centring of y)
	height = sum_y / f32(K * K)
	det := sxx * szz - sxz * sxz
	if det <= 1e-12 * max(sxx * szz, 1e-30) {
		// a line, not an area: tilt along it from the terrain normal
		normal = sample_normal(t, center.x, center.y, layer)
	} else {
		b := (sxy * szz - szy * sxz) / det
		c := (szy * sxx - sxy * sxz) / det
		normal = normal_from_gradient(b, c)
	}
	return height, clamp_tilt(normal, max_tilt), inside
}

clamp_tilt :: proc(n: [3]f32, max_tilt: f32) -> [3]f32 {
	if max_tilt <= 0 do return {0, 1, 0}
	if n.y >= math.cos(max_tilt) do return n
	hl := math.sqrt(n.x * n.x + n.z * n.z)
	if hl < 1e-9 do return {0, 1, 0}
	s := math.sin(max_tilt) / hl
	return {n.x * s, math.cos(max_tilt), n.z * s}
}

// First hit of a ray with the heightmap, for picking. Marches half a cell at a
// time inside the grid's box and refines the crossing by bisection. A ray that
// starts below the surface hits at its origin.
raycast :: proc(
	t: Terrain,
	origin, dir: [3]f32,
	layer := Layer.Ground,
	max_dist: f32 = max(f32),
) -> (hit: [3]f32, dist: f32, ok: bool) {
	if !valid(t) do return {}, 0, false
	dl := math.sqrt(dir.x * dir.x + dir.y * dir.y + dir.z * dir.z)
	if dl < 1e-12 do return {}, 0, false
	d := dir / dl

	// clip to the grid's box, heights padded by a cell
	lo := [3]f32{t.origin.x, t.lo - t.cell, t.origin.y}
	hi := [3]f32{t.origin.x + f32(t.w) * t.cell, t.hi + t.cell, t.origin.y + f32(t.h) * t.cell}
	t0, t1 := f32(0), max_dist
	for axis in 0 ..< 3 {
		if abs(d[axis]) < 1e-12 {
			if origin[axis] < lo[axis] || origin[axis] > hi[axis] do return {}, 0, false
			continue
		}
		a := (lo[axis] - origin[axis]) / d[axis]
		b := (hi[axis] - origin[axis]) / d[axis]
		if a > b do a, b = b, a
		t0 = max(t0, a)
		t1 = min(t1, b)
	}
	if t0 > t1 do return {}, 0, false

	above :: proc(t: Terrain, layer: Layer, q: [3]f32) -> f32 {
		y, _ := sample_height(t, q.x, q.z, layer)
		return q.y - y
	}
	stride := t.cell * 0.5
	s := t0
	prev := above(t, layer, origin + d * s)
	if prev <= 0 do return origin + d * s, s, true
	for s < t1 {
		next_s := min(s + stride, t1)
		cur := above(t, layer, origin + d * next_s)
		if cur <= 0 {
			a, b := s, next_s
			for _ in 0 ..< 20 {
				mid := (a + b) * 0.5
				if above(t, layer, origin + d * mid) > 0 {
					a = mid
				} else {
					b = mid
				}
			}
			return origin + d * b, b, true
		}
		s = next_s
	}
	return {}, 0, false
}

// ---------------------------------------------------------------------------
// Grid filters. Rows are z, columns x; edges clamp.
// ---------------------------------------------------------------------------

// Opening (erosion then dilation) with a (2r+1)^2 square window, separable.
opening :: proc(src, dst, scratch: []f32, w, h, r: int) {
	filter_1d(src, scratch, w, h, r, true, false)
	filter_1d(scratch, dst, w, h, r, false, false)
	filter_1d(dst, scratch, w, h, r, true, true)
	filter_1d(scratch, dst, w, h, r, false, true)
}

// Running min (or max) over 2r+1 cells along x (along_x) or z. Monotonic
// deque, O(cells) whatever the window.
filter_1d :: proc(src, dst: []f32, w, h, r: int, along_x, take_max: bool) {
	lines, length := h, w
	if !along_x do lines, length = w, h
	q := make([]int, length)
	defer delete(q)
	for line in 0 ..< lines {
		at :: #force_inline proc(line, k, w: int, along_x: bool) -> int {
			return line * w + k if along_x else k * w + line
		}
		head, tail := 0, 0
		next := 0 // next index to push
		for k in 0 ..< length {
			hi := min(k + r, length - 1)
			for next <= hi {
				v := src[at(line, next, w, along_x)]
				for tail > head {
					back := src[at(line, q[tail - 1], w, along_x)]
					worse := back <= v if take_max else back >= v
					if !worse do break
					tail -= 1
				}
				q[tail] = next
				tail += 1
				next += 1
			}
			for q[head] < k - r do head += 1
			dst[at(line, k, w, along_x)] = src[at(line, q[head], w, along_x)]
		}
	}
}

// Outliers against the 5x5 neighbourhood: a data cell lower (or, for the
// top surface, higher) than every data neighbour by more than tol takes the
// nearest of their values. A data cell with fewer than 3 data neighbours is
// dropped. A cell beside a building keeps its value: some neighbour is on the
// same side of it.
remove_outliers :: proc(v: []f32, has: []bool, w, h: int, tol: f32, high: bool) {
	orig := slice.clone(v)
	defer delete(orig)
	orig_has := slice.clone(has)
	defer delete(orig_has)
	for z in 0 ..< h {
		for x in 0 ..< w {
			c := z * w + x
			if !orig_has[c] do continue
			nearest := -max(f32) if high else max(f32)
			k := 0
			for dz in -2 ..= 2 {
				for dx in -2 ..= 2 {
					if dx == 0 && dz == 0 do continue
					nx, nz := x + dx, z + dz
					if nx < 0 || nz < 0 || nx >= w || nz >= h do continue
					nc := nz * w + nx
					if !orig_has[nc] do continue
					nearest = max(nearest, orig[nc]) if high else min(nearest, orig[nc])
					k += 1
				}
			}
			if k < 3 {
				has[c] = false
			} else if high ? orig[c] > nearest + tol : orig[c] < nearest - tol {
				v[c] = nearest
			}
		}
	}
}

mean_3x3 :: proc(v, scratch: []f32, w, h: int) {
	copy(scratch, v)
	for z in 0 ..< h {
		for x in 0 ..< w {
			sum: f32
			k: f32
			for dz in -1 ..= 1 {
				for dx in -1 ..= 1 {
					nx := clamp(x + dx, 0, w - 1)
					nz := clamp(z + dz, 0, h - 1)
					sum += scratch[nz * w + nx]
					k += 1
				}
			}
			v[z * w + x] = sum / k
		}
	}
}

// Fills the cells where known is false: nearest known value (breadth first),
// then relaxation towards a smooth membrane, so a hole under a building
// becomes a gentle surface between the streets around it rather than a step.
fill_holes :: proc(v: []f32, known: []bool, w, h: int) -> bool {
	cells := w * h
	assigned := slice.clone(known)
	defer delete(assigned)
	queue := make([dynamic]int, 0, cells)
	defer delete(queue)
	for c in 0 ..< cells {
		if known[c] do append(&queue, c)
	}
	if len(queue) == 0 do return false
	if len(queue) == cells do return true

	for head := 0; head < len(queue); head += 1 {
		c := queue[head]
		x, z := c % w, c / w
		NB :: [4][2]int{{1, 0}, {-1, 0}, {0, 1}, {0, -1}}
		for d in NB {
			nx, nz := x + d.x, z + d.y
			if nx < 0 || nz < 0 || nx >= w || nz >= h do continue
			nc := nz * w + nx
			if assigned[nc] do continue
			assigned[nc] = true
			v[nc] = v[c]
			append(&queue, nc)
		}
	}

	unknown := make([dynamic]int, 0, cells - int(count_true(known)))
	defer delete(unknown)
	for c in 0 ..< cells {
		if !known[c] do append(&unknown, c)
	}
	for _ in 0 ..< FILL_SWEEPS {
		for c in unknown {
			x, z := c % w, c / w
			sum: f32
			k: f32
			if x > 0 { sum += v[c - 1]; k += 1 }
			if x < w - 1 { sum += v[c + 1]; k += 1 }
			if z > 0 { sum += v[c - w]; k += 1 }
			if z < h - 1 { sum += v[c + w]; k += 1 }
			if k > 0 do v[c] = sum / k
		}
	}
	return true
}

count_true :: proc(b: []bool) -> (n: int) {
	for x in b do n += int(x)
	return
}

finite :: #force_inline proc(x: f32) -> bool {
	u := transmute(u32)x
	return (u & 0x7fffffff) < 0x7f800000
}

// ---------------------------------------------------------------------------
// Export: heights as 16-bit PGMs plus a JSON description, for the game and
// for looking at in an image viewer.
//
//   <prefix>.ground.pgm    DTM, 16 bit, 0..65535 = heightMin..heightMax
//   <prefix>.surface.pgm   DSM, same scale
//   <prefix>.class.pgm     8 bit: 0 empty, 85 ground, 170 object, 255 structure
//   <prefix>.floor.pgm     the low layer before the ground filter, same scale
//                          as ground: what the filter saw
//   <prefix>.terrain.json  grid placement, height range, world scale
//
// The prefix's folder is made if missing. load_export reads the files back.
//
// Row 0 is the lowest z, column 0 the lowest x. A cell's world height is
// heightMin + value / 65535 * (heightMax - heightMin); divide by worldScale
// for metres.
// ---------------------------------------------------------------------------

EXPORT_FILES :: 5

export :: proc(t: Terrain, prefix: string, world_scale: f32) -> (written: [EXPORT_FILES]string, err: os.Error) {
	if !valid(t) do return {}, .Invalid_File
	if folder := os.dir(prefix); folder != "" && folder != "." && !os.is_directory(folder) {
		os.make_directory_all(folder) or_return
	}
	names := [EXPORT_FILES]string{
		fmt.aprintf("%s.ground.pgm", prefix),
		fmt.aprintf("%s.surface.pgm", prefix),
		fmt.aprintf("%s.class.pgm", prefix),
		fmt.aprintf("%s.floor.pgm", prefix),
		fmt.aprintf("%s.terrain.json", prefix),
	}
	defer if err != nil {
		for s in names do delete(s)
	}
	lo, hi := t.lo, t.hi
	if hi <= lo do hi = lo + 1

	write_pgm16 :: proc(name: string, v: []f32, w, h: int, lo, hi: f32) -> os.Error {
		header := fmt.tprintf("P5\n%d %d\n65535\n", w, h)
		buf := make([]u8, len(header) + w * h * 2)
		defer delete(buf)
		copy(buf, header)
		o := len(header)
		for x, i in v {
			q := u16(clamp((x - lo) / (hi - lo), 0, 1) * 65535 + 0.5)
			buf[o + i * 2 + 0] = u8(q >> 8) // PGM is big-endian
			buf[o + i * 2 + 1] = u8(q)
		}
		return os.write_entire_file(name, buf)
	}
	write_pgm16(names[0], t.ground, t.w, t.h, lo, hi) or_return
	write_pgm16(names[1], t.surface, t.w, t.h, lo, hi) or_return
	// a terrain built before the floor layer existed: the ground stands in
	write_pgm16(names[3], t.floor if len(t.floor) == len(t.ground) else t.ground, t.w, t.h, lo, hi) or_return
	{
		header := fmt.tprintf("P5\n%d %d\n255\n", t.w, t.h)
		buf := make([]u8, len(header) + t.w * t.h)
		defer delete(buf)
		copy(buf, header)
		for c, i in t.class do buf[len(header) + i] = u8(c) * 85
		os.write_entire_file(names[2], buf) or_return
	}

	base :: proc(path: string) -> string {
		i := strings.last_index_any(path, "/\\")
		return path[i + 1:]
	}
	p := t.params
	json := fmt.tprintf(
		`{{
  "version": 1,
  "upAxis": "+y",
  "worldScale": %.9g,
  "origin": [%.9g, %.9g],
  "cell": %.9g,
  "width": %d,
  "height": %d,
  "rowAxis": "+z",
  "columnAxis": "+x",
  "heightMin": %.9g,
  "heightMax": %.9g,
  "ground": %q,
  "surface": %q,
  "class": %q,
  "floor": %q,
  "classes": {{"0": "empty", "85": "ground", "170": "object", "255": "structure"}},
  "params": {{
    "minOpacity": %.9g, "minCount": %d,
    "groundQuantile": %.9g, "surfaceQuantile": %.9g,
    "maxObject": %.9g, "slope": %.9g, "dh0": %.9g, "dhMax": %.9g,
    "objectHeight": %.9g, "structureHeight": %.9g, "smooth": %d
  }}
}}
`,
		world_scale, t.origin.x, t.origin.y, t.cell, t.w, t.h, lo, hi,
		base(names[0]), base(names[1]), base(names[2]), base(names[3]),
		p.min_opacity, p.min_count, p.ground_quantile, p.surface_quantile,
		p.max_object, p.slope, p.dh0, p.dh_max, p.object_height, p.structure_height, p.smooth,
	)
	os.write_entire_file(names[4], json) or_return
	return names, nil
}

// Export_Header is <prefix>.terrain.json as export writes it.
Export_Header :: struct {
	version:     int,
	world_scale: f32 `json:"worldScale"`,
	origin:      [2]f32,
	cell:        f32,
	width:       int,
	height:      int,
	height_min:  f32 `json:"heightMin"`,
	height_max:  f32 `json:"heightMax"`,
	ground:      string,
	surface:     string,
	class:       string,
	floor:       string, // "" in exports made before the floor layer
	params:      struct {
		min_opacity:      f32 `json:"minOpacity"`,
		min_count:        int `json:"minCount"`,
		ground_quantile:  f32 `json:"groundQuantile"`,
		surface_quantile: f32 `json:"surfaceQuantile"`,
		max_object:       f32 `json:"maxObject"`,
		slope:            f32,
		dh0:              f32,
		dh_max:           f32 `json:"dhMax"`,
		object_height:    f32 `json:"objectHeight"`,
		structure_height: f32 `json:"structureHeight"`,
		smooth:           int,
	},
}

Load_Error :: enum {
	None,
	Read,   // a file is missing or unreadable
	Header, // the JSON does not parse or describes no grid
	Image,  // a PGM is not the size or depth the JSON says
}

// Reads an export back (export's <prefix>.terrain.json and the images it
// names, next to it), so mapgen can run without the capture: on a machine
// without the splats, or in a test. Heights come back quantised to 1/65535
// of the height range (under a millimetre for a town). count stays empty.
// Without a floor image (older exports) the floor is the ground.
load_export :: proc(json_path: string, allocator := context.allocator) -> (t: Terrain, world_scale: f32, err: Load_Error) {
	context.allocator = allocator
	data, rerr := os.read_entire_file(json_path, context.temp_allocator)
	if rerr != nil do return {}, 0, .Read
	hd: Export_Header
	if json.unmarshal(data, &hd, json.DEFAULT_SPECIFICATION, context.temp_allocator) != nil do return {}, 0, .Header
	if hd.width <= 0 || hd.height <= 0 || hd.cell <= 0 || len(hd.ground) == 0 || len(hd.surface) == 0 || len(hd.class) == 0 {
		return {}, 0, .Header
	}
	folder := os.dir(json_path)
	beside :: proc(folder, name: string) -> string {
		if folder == "" || folder == "." do return name
		return strings.concatenate({folder, "/", name}, context.temp_allocator)
	}

	w, h := hd.width, hd.height
	cells := w * h
	t.origin, t.cell, t.w, t.h = hd.origin, hd.cell, w, h
	t.lo, t.hi = hd.height_min, hd.height_max
	pp := hd.params
	t.params = Params{
		cell = hd.cell, min_opacity = pp.min_opacity, min_count = pp.min_count,
		ground_quantile = pp.ground_quantile, surface_quantile = pp.surface_quantile,
		max_object = pp.max_object, slope = pp.slope, dh0 = pp.dh0, dh_max = pp.dh_max,
		object_height = pp.object_height, structure_height = pp.structure_height, smooth = pp.smooth,
	}
	t.ground = make([]f32, cells)
	t.surface = make([]f32, cells)
	t.floor = make([]f32, cells)
	t.class = make([]Class, cells)
	defer if err != .None do destroy(&t)

	read_pgm(beside(folder, hd.ground), t.ground, nil, w, h, t.lo, t.hi) or_return
	read_pgm(beside(folder, hd.surface), t.surface, nil, w, h, t.lo, t.hi) or_return
	if len(hd.floor) > 0 {
		read_pgm(beside(folder, hd.floor), t.floor, nil, w, h, t.lo, t.hi) or_return
	} else {
		copy(t.floor, t.ground)
	}
	read_pgm(beside(folder, hd.class), nil, t.class, w, h, 0, 0) or_return

	for c in t.class {
		switch c {
		case .Empty:
		case .Ground:    t.stats.ground_cells += 1
		case .Object:    t.stats.object_cells += 1
		case .Structure: t.stats.structure_cells += 1
		}
		if c != .Empty do t.stats.data_cells += 1
	}
	return t, hd.world_scale, .None
}

// One binary PGM as export writes it: 16 bit heights into `heights`, or
// 8 bit classes (0, 85, 170, 255) into `class`.
@(private = "file")
read_pgm :: proc(path: string, heights: []f32, class: []Class, w, h: int, lo, hi: f32) -> Load_Error {
	data, rerr := os.read_entire_file(path, context.temp_allocator)
	if rerr != nil do return .Read
	is_space :: proc(b: u8) -> bool {return b == ' ' || b == '\n' || b == '\r' || b == '\t'}
	parse :: proc(s: string) -> int {
		n := 0
		for ch in transmute([]u8)s {
			if ch < '0' || ch > '9' do return -1
			n = n * 10 + int(ch - '0')
		}
		return n if len(s) > 0 else -1
	}
	// header: "P5", width, height, maxval, each after whitespace, then one
	// whitespace byte before the pixels
	fields: [4]string
	at := 0
	for k in 0 ..< 4 {
		for at < len(data) && is_space(data[at]) do at += 1
		start := at
		for at < len(data) && !is_space(data[at]) do at += 1
		fields[k] = string(data[start:at])
	}
	at += 1
	if fields[0] != "P5" || parse(fields[1]) != w || parse(fields[2]) != h do return .Image
	maxval := parse(fields[3])
	if heights != nil {
		if maxval != 65535 || len(data) - at < w * h * 2 do return .Image
		scale := (hi - lo) / 65535
		for i in 0 ..< w * h {
			q := u16(data[at + 2 * i]) << 8 | u16(data[at + 2 * i + 1])
			heights[i] = lo + f32(q) * scale
		}
	} else {
		if maxval != 255 || len(data) - at < w * h do return .Image
		for i in 0 ..< w * h do class[i] = Class(min(int(data[at + i]) / 85, int(max(Class))))
	}
	return .None
}
