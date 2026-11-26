package mapgen

// The automatic gameplay map from the terrain proxy (docs/map_spec.md,
// "Automatic map from the capture"), in a fixed order so the same capture
// always gives the same map:
//
//   1. align     the main direction of building edges becomes the frame's
//                yaw, so buildings come out square on the map's grid
//   2. sample    ground, surface, the lowest splats and the class, per map
//                cell, through the aligned frame
//   3. clean     structures: one-cell gaps closed, holes under `hole` filled,
//                specks under `speck` dropped
//   4. classify  each structure: a wall is thin, a tree shows ground under
//                it or is rough on top, the rest are buildings
//   5. features  buildings as squared footprints with one clean flat roof
//                height, trees as a trunk and a canopy, walls; low solids
//                (0.5..2 m: low walls, hedges, parked cars) as walls or
//                volumes; and the placed objects as props
//   6. ground    the bare ground is layer 0; slopes over `max_slope` are not
//                walkable
//
// Every feature gets an id from its kind and where it is ("b:12,40": a
// building centred near x 12 m, y 40 m), so an edit can still find it when a
// rebuild shifts things a little (retarget).
//
// The result is an automatic map: features listed, not stamped. Apply the
// level's edits to it with gamemap.apply_edits, which stamps them.
//
// No raylib: odin test mapgen -collection:cmd=../commandos

import "core:fmt"
import "core:math"
import "core:slice"
import "core:strconv"
import "core:strings"

import "../terrain"
import "cmd:gamemap"

Params :: struct {
	cell:        f32,        // map cell, metres
	yaw:         Maybe(f32), // degrees; nil: from the building edges
	max_slope:   f32,        // degrees: steeper ground is not walkable
	speck:       f32,        // m²: smaller structures are dropped
	hole:        f32,        // m²: smaller holes in structures are filled
	sees_ground: f32,        // metres: a structure cell whose lowest splats are this close to the ground shows ground under it
	tree_ground: f32,        // share of such cells that makes a structure a tree
	tree_rough:  f32,        // metres: a mean step between neighbouring cells' tops this big makes it a tree
	wall_width:  f32,        // metres: a structure this thin is a wall
	low_height:  f32,        // metres: a low solid (an object cell) this tall is cover
}

default_params :: proc() -> Params {
	return Params{
		cell        = 1,
		max_slope   = 35,
		speck       = 2,
		hole        = 1,
		sees_ground = 1.5,
		tree_ground = 0.35,
		tree_rough  = 0.6,
		wall_width  = 2.5,
		low_height  = 0.5,
	}
}

// A placed object as the map needs it: its footprint and its height.
Prop :: struct {
	id:      string,
	corners: [4][2]f32, // world x, z
	bottom:  f32,       // world y
	top:     f32,
}

Input :: struct {
	terrain:     ^terrain.Terrain,
	world_scale: f32,        // world units per metre
	origin:      [2]f32,     // the level's game region: world x, z of its corner
	size:        [2]f32,     // and its size, metres
	props:       []Prop,
	params:      Params,
}

Stats :: struct {
	yaw:       f32,
	w, h:      int,
	buildings: int,
	trees:     int,
	walls:     int,
	low:       int, // low walls, hedges, cars from the capture
	props:     int,
	walkable:  int, // ground cells
	steep:     int, // ground cells too steep to walk
}

// ---------------------------------------------------------------------------

build :: proc(in_: Input) -> (m: gamemap.Map, stats: Stats) {
	p := in_.params
	if p.cell <= 0 do p = default_params()
	t := in_.terrain
	ws := in_.world_scale if in_.world_scale > 0 else 1

	// ---- 1. align -------------------------------------------------------------
	yaw, has_yaw := p.yaw.?
	if !has_yaw do yaw = edge_direction(t^)
	stats.yaw = yaw

	size := [2]f32{max(in_.size.x, p.cell), max(in_.size.y, p.cell)}
	frame := frame_for(in_.origin, size, yaw, ws, t.lo)
	w := int(math.ceil(size.x / p.cell))
	h := int(math.ceil(size.y / p.cell))
	m = gamemap.make_map(frame, p.cell, w, h)
	stats.w, stats.h = w, h

	// ---- 2. sample --------------------------------------------------------------
	n := w * h
	inside := make([]bool, n, context.temp_allocator)
	ground := make([]f32, n, context.temp_allocator)
	top := make([]f32, n, context.temp_allocator)
	seen := make([]bool, n, context.temp_allocator) // shows ground under a structure
	solid := make([]bool, n, context.temp_allocator)
	low := make([]bool, n, context.temp_allocator)  // a low solid: wall, hedge, car
	low_top := make([]f32, n, context.temp_allocator)

	t_cell_m := t.cell / ws
	k := clamp(int(math.round(p.cell / t_cell_m)), 1, 4) // subsamples per side
	for y in 0 ..< h {
		for x in 0 ..< w {
			c := y * w + x
			got, structure, saw, object := 0, 0, 0, 0
			so := f32(0)
			sg, st, ss := f32(0), f32(0), f32(0)
			for sy in 0 ..< k {
				for sx in 0 ..< k {
					q := [3]f32{(f32(x) + (f32(sx) + 0.5) / f32(k)) * p.cell, (f32(y) + (f32(sy) + 0.5) / f32(k)) * p.cell, 0}
					wp := gamemap.map_to_world(frame, q)
					tc, ok := terrain.cell_index(t^, wp.x, wp.z)
					if !ok do continue
					got += 1
					g := (t.ground[tc] - frame.ground) / ws
					s := (t.surface[tc] - frame.ground) / ws
					sg += g
					st += s
					if t.class[tc] == .Object && s - g >= p.low_height {
						object += 1
						so += s
					}
					if t.class[tc] == .Structure {
						structure += 1
						ss += s
						f := t.floor[tc] if len(t.floor) == len(t.ground) else t.surface[tc]
						if (f - t.ground[tc]) / ws < p.sees_ground do saw += 1
					}
				}
			}
			if got == 0 do continue
			inside[c] = true
			ground[c] = sg / f32(got)
			// a structure's top from its own samples, not the street beside it
			top[c] = ss / f32(structure) if structure > 0 else st / f32(got)
			solid[c] = 2 * structure >= got
			seen[c] = 2 * saw >= max(structure, 1)
			if !solid[c] && 2 * object >= got {
				low[c] = true
				low_top[c] = so / f32(object)
			}
		}
	}

	// ---- 3. clean ----------------------------------------------------------------
	close_gaps(solid, w, h)
	fill_small(solid, w, h, int(p.hole / (p.cell * p.cell)))
	labels, count := label(solid, w, h)

	// ---- 4, 5. classify, features ----------------------------------------------
	Comp :: struct {
		cells: [dynamic]int,
	}
	comps := make([]Comp, count, context.temp_allocator)
	for c in 0 ..< n {
		if labels[c] > 0 {
			comp := &comps[labels[c] - 1]
			if comp.cells == nil do comp.cells = make([dynamic]int, context.temp_allocator)
			append(&comp.cells, c)
		}
	}
	taken := make(map[string]int, allocator = context.temp_allocator)
	min_cells := int(math.ceil(p.speck / (p.cell * p.cell)))
	for comp, ci in comps {
		cells := comp.cells[:]
		if len(cells) < min_cells do continue

		gs := make([]f32, len(cells), context.temp_allocator)
		ts := make([]f32, len(cells), context.temp_allocator)
		x0, y0, x1, y1 := w, h, -1, -1
		saw, highest := 0, 0
		centre: [2]f32
		in_comp := make(map[int]bool, len(cells), context.temp_allocator)
		for c, i in cells {
			gs[i], ts[i] = ground[c], top[c]
			x, y := c % w, c / w
			x0, y0, x1, y1 = min(x0, x), min(y0, y), max(x1, x), max(y1, y)
			if top[c] > top[cells[highest]] do highest = i
			centre += gamemap.cell_centre(&m, x, y)
			in_comp[c] = true
		}
		centre /= f32(len(cells))
		base := median(gs)
		roof := median(ts)

		// ground seen under it and roughness, over the cells inside it (all
		// four neighbours in it too): its rim is half street. A thin thing
		// has no inside, and is no tree
		inner :: proc(in_comp: map[int]bool, c, w: int) -> bool {
			return (c - 1) in in_comp && (c + 1) in in_comp && (c - w) in in_comp && (c + w) in in_comp
		}
		rough, pairs, inners := f32(0), 0, 0
		for c in cells {
			if !inner(in_comp, c, w) do continue
			inners += 1
			if seen[c] do saw += 1
			if inner(in_comp, c + 1, w) {
				rough += abs(top[c] - top[c + 1])
				pairs += 1
			}
			if inner(in_comp, c + w, w) {
				rough += abs(top[c] - top[c + w])
				pairs += 1
			}
		}
		if pairs > 0 do rough /= f32(pairs)

		thin := thickness(len(cells), x1 - x0 + 1, y1 - y0 + 1, p.cell) <= p.wall_width
		f := gamemap.Feature{base = base}
		switch {
		case thin:
			f.kind = .Wall
			f.height = round_to(roof - base, 0.1)
			stats.walls += 1
		case inners > 0 && (f32(saw) >= p.tree_ground * f32(inners) || rough >= p.tree_rough):
			f.kind = .Tree
			hc := cells[highest]
			f.at = gamemap.cell_centre(&m, hc % w, hc / w)
			f.height = round_to(top[hc] - base, 0.1)
			f.bottom = min(gamemap.CANOPY_BASE, 0.4 * f.height)
			f.trunk = gamemap.TREE_TRUNK
			stats.trees += 1
		case:
			f.kind = .Building
			f.height = round_to(roof - base, 0.1)
			f.roof = .Flat
			stats.buildings += 1
		}
		if f.kind == .Building {
			square_up(labels, w, h, i32(ci + 1), x0, y0, x1, y1)
			to_rectangle(labels, w, h, i32(ci + 1), x0, y0, x1, y1)
		}
		f.footprint = trace(labels, w, h, i32(ci + 1), p.cell, m.allocator)
		if len(f.footprint) == 0 do continue
		f.id = feature_id(f.kind, centre, &taken, m.allocator)
		append(&m.features, f)
	}

	// ---- low solids: under structure_height, over low_height ----------------------
	// Walls, hedges, parked cars from the capture: cover, seen over standing,
	// hidden behind crouching. A wall when thin, else a volume.
	close_gaps(low, w, h)
	low_labels, low_count := label(low, w, h)
	low_cells := make([][dynamic]int, low_count, context.temp_allocator)
	for c in 0 ..< n {
		if l := low_labels[c]; l > 0 {
			if low_cells[l - 1] == nil do low_cells[l - 1] = make([dynamic]int, context.temp_allocator)
			append(&low_cells[l - 1], c)
		}
	}
	for cells, li in low_cells {
		if len(cells) < min_cells do continue
		gs := make([]f32, len(cells), context.temp_allocator)
		ts := make([]f32, len(cells), context.temp_allocator)
		x0, y0, x1, y1 := w, h, -1, -1
		centre: [2]f32
		for c, i in cells {
			// a gap closed in between has no top of its own: its neighbours'
			gs[i], ts[i] = ground[c], low_top[c] if low_top[c] > 0 else ground[c]
			x, y := c % w, c / w
			x0, y0, x1, y1 = min(x0, x), min(y0, y), max(x1, x), max(y1, y)
			centre += gamemap.cell_centre(&m, x, y)
		}
		centre /= f32(len(cells))
		base := median(gs)
		f := gamemap.Feature{base = base, height = round_to(median(ts) - base, 0.1)}
		if f.height < p.low_height do continue
		thin := thickness(len(cells), x1 - x0 + 1, y1 - y0 + 1, p.cell) <= p.wall_width
		f.kind = .Wall if thin else .Volume
		f.footprint = trace(low_labels, w, h, i32(li + 1), p.cell, m.allocator)
		if len(f.footprint) == 0 do continue
		f.id = feature_id(f.kind, centre, &taken, m.allocator)
		append(&m.features, f)
		stats.low += 1
	}

	// ---- props ---------------------------------------------------------------------
	for pr in in_.props {
		ring := make([][2]f32, 4, m.allocator)
		for corner, i in pr.corners {
			q := gamemap.world_to_map(frame, {corner.x, pr.bottom, corner.y})
			ring[i] = q.xy
		}
		rings := make([][][2]f32, 1, m.allocator)
		rings[0] = ring
		b := (pr.bottom - frame.ground) / ws
		top_m := (pr.top - frame.ground) / ws
		if top_m <= b do continue
		append(&m.features, gamemap.Feature{
			id = strings.clone(fmt.tprintf("prop:%s", pr.id), m.allocator),
			kind = .Prop, footprint = rings, base = b, height = top_m - b,
		})
		stats.props += 1
	}

	// ---- 6. ground --------------------------------------------------------------------
	max_rise := math.tan(p.max_slope * math.RAD_PER_DEG) * p.cell
	for y in 0 ..< h {
		for x in 0 ..< w {
			c := y * w + x
			if !inside[c] do continue
			steep := false
			for d in ([4][2]int{{1, 0}, {-1, 0}, {0, 1}, {0, -1}}) {
				nx, ny := x + d.x, y + d.y
				if nx < 0 || ny < 0 || nx >= w || ny >= h || !inside[ny * w + nx] do continue
				if abs(ground[ny * w + nx] - ground[c]) > max_rise do steep = true
			}
			if steep {
				stats.steep += 1
				continue
			}
			gamemap.set_cell(&m, 0, x, y, ground[c], .Ground)
			stats.walkable += 1
		}
	}
	gamemap.reindex(&m)
	return m, stats
}

// The map frame of a game region turned by yaw about its centre, so the
// region keeps its size and stays where it was.
frame_for :: proc(origin, size: [2]f32, yaw, world_scale, ground: f32) -> gamemap.Frame {
	s, c := math.sincos(yaw * math.RAD_PER_DEG)
	half := size * world_scale / 2
	centre := origin + half
	return gamemap.Frame{
		origin      = centre - [2]f32{c * half.x - s * half.y, s * half.x + c * half.y},
		size        = size,
		yaw         = yaw,
		world_scale = world_scale,
		ground      = ground,
	}
}

// ---------------------------------------------------------------------------
// 1. Align: the main direction of building edges
// ---------------------------------------------------------------------------

// The direction of structure edges in the terrain, degrees in (-45, 45]:
// the turn at which the structures' boundary cells line up best. For each
// angle the boundary cells are projected on both turned axes and binned a
// cell wide; buildings' walls pile up in few bins when the angle is right,
// so the angle with the most piled-up bins (sum of squared counts) wins.
// Searched in 1 degree steps, then 0.1 around the best with half-cell bins;
// where several angles tie, the middle of them. 0 when there are no
// structures.
edge_direction :: proc(t: terrain.Terrain) -> f32 {
	w, h := t.w, t.h
	pts := make([dynamic][2]f32, context.temp_allocator)
	for z in 1 ..< h - 1 {
		for x in 1 ..< w - 1 {
			c := z * w + x
			if t.class[c] != .Structure do continue
			edge := false
			for d in ([4]int{1, -1, w, -w}) do if t.class[c + d] != .Structure do edge = true
			if edge do append(&pts, [2]f32{f32(x), f32(z)})
		}
	}
	if len(pts) < 8 do return 0

	bins := make(map[i32]i32, allocator = context.temp_allocator)
	score :: proc(pts: [][2]f32, deg: f32, bins: ^map[i32]i32, bin := f32(1)) -> f64 {
		s, c := math.sincos(deg * math.RAD_PER_DEG)
		total := 0.0
		for axis in 0 ..< 2 {
			clear(bins)
			for p in pts {
				u := c * p.x + s * p.y if axis == 0 else -s * p.x + c * p.y
				bins[i32(math.round(u / bin))] += 1 // points sit on whole cells: bins centred on them
			}
			for _, n in bins do total += f64(n) * f64(n)
		}
		return total
	}
	// the middle of the run of angles that score best: with few edges a
	// whole range of angles bins them equally well
	plateau :: proc(pts: [][2]f32, bins: ^map[i32]i32, start, step: f32, count: int, bin: f32) -> f32 {
		scores := make([]f64, count, context.temp_allocator)
		top := -1.0
		for i in 0 ..< count {
			scores[i] = score(pts, start + f32(i) * step, bins, bin)
			top = max(top, scores[i])
		}
		first := 0
		for scores[first] < top do first += 1
		last := first
		for last + 1 < count && scores[last + 1] >= top do last += 1
		return start + f32(first + last) * 0.5 * step
	}
	coarse := plateau(pts[:], &bins, -44, 1, 90, 1)
	best := plateau(pts[:], &bins, coarse - 1.5, 0.1, 31, 0.5)
	if best <= -45 do best += 90
	if best > 45 do best -= 90
	return round_to(best, 0.1)
}

// ---------------------------------------------------------------------------
// 3. Clean
// ---------------------------------------------------------------------------

// Closes gaps of exactly one cell: an empty cell between two structure
// cells, across or along, becomes structure. Wider gaps (alleys) stay.
close_gaps :: proc(mask: []bool, w, h: int) {
	src := make([]bool, len(mask), context.temp_allocator)
	copy(src, mask)
	at :: #force_inline proc(m: []bool, w, h, x, y: int) -> bool {
		return x >= 0 && y >= 0 && x < w && y < h && m[y * w + x]
	}
	for y in 0 ..< h {
		for x in 0 ..< w {
			if src[y * w + x] do continue
			if (at(src, w, h, x - 1, y) && at(src, w, h, x + 1, y)) || (at(src, w, h, x, y - 1) && at(src, w, h, x, y + 1)) {
				mask[y * w + x] = true
			}
		}
	}
}

// Fills holes (background regions not touching the border) of at most
// max_cells cells.
fill_small :: proc(mask: []bool, w, h, max_cells: int) {
	if max_cells <= 0 do return
	bg := make([]bool, len(mask), context.temp_allocator)
	for v, i in mask do bg[i] = !v
	labels, count := label(bg, w, h)
	size := make([]int, count + 1, context.temp_allocator)
	border := make([]bool, count + 1, context.temp_allocator)
	for l, i in labels {
		if l == 0 do continue
		size[l] += 1
		x, y := i % w, i / w
		if x == 0 || y == 0 || x == w - 1 || y == h - 1 do border[l] = true
	}
	for l, i in labels {
		if l > 0 && !border[l] && size[l] <= max_cells do mask[i] = true
	}
}

// 4-connected components in scan order, 1-based; 0 for unset cells.
label :: proc(mask: []bool, w, h: int) -> (labels: []i32, count: int) {
	labels = make([]i32, len(mask), context.temp_allocator)
	stack := make([dynamic]int, context.temp_allocator)
	for start in 0 ..< len(mask) {
		if !mask[start] || labels[start] != 0 do continue
		count += 1
		labels[start] = i32(count)
		append(&stack, start)
		for len(stack) > 0 {
			c := pop(&stack)
			x, y := c % w, c / w
			for d in ([4][2]int{{1, 0}, {-1, 0}, {0, 1}, {0, -1}}) {
				nx, ny := x + d.x, y + d.y
				if nx < 0 || ny < 0 || nx >= w || ny >= h do continue
				q := ny * w + nx
				if mask[q] && labels[q] == 0 {
					labels[q] = i32(count)
					append(&stack, q)
				}
			}
		}
	}
	return
}

// Squares up a building's cells (labelled id, within x0..x1, y0..y1) on the
// aligned grid: a cell sticking out with one neighbour in the building goes,
// a notch with three neighbours in it is filled; twice. Long straight walls
// stay straight, one-cell jags along them do not survive.
square_up :: proc(labels: []i32, w, h: int, id: i32, x0, y0, x1, y1: int) {
	for _ in 0 ..< 2 {
		change := make([dynamic][3]int, context.temp_allocator) // x, y, set
		for y in max(y0 - 1, 0) ..= min(y1 + 1, h - 1) {
			for x in max(x0 - 1, 0) ..= min(x1 + 1, w - 1) {
				c := y * w + x
				n := 0
				for d in ([4][2]int{{1, 0}, {-1, 0}, {0, 1}, {0, -1}}) {
					nx, ny := x + d.x, y + d.y
					if nx >= 0 && ny >= 0 && nx < w && ny < h && labels[ny * w + nx] == id do n += 1
				}
				if labels[c] == id && n <= 1 do append(&change, [3]int{x, y, 0})
				if labels[c] == 0 && n >= 3 do append(&change, [3]int{x, y, 1})
			}
		}
		for ch in change do labels[ch.y * w + ch.x] = id if ch.z == 1 else 0
	}
}

RECT_FILL :: f32(0.8)  // a building filling this much of its box is a rectangle
EDGE_FILL :: f32(0.75) // of which the rows and columns this full

// A building that nearly fills its box becomes the rectangle of its rows and
// columns at least EDGE_FILL full, trimmed in from the box's edges: what
// spills out along a wall goes, what is missing inside is filled. Others
// (an L, a courtyard block) keep their squared outline.
to_rectangle :: proc(labels: []i32, w, h: int, id: i32, x0, y0, x1, y1: int) {
	bw, bh := x1 - x0 + 1, y1 - y0 + 1
	if bw <= 0 || bh <= 0 do return
	rows := make([]int, bh, context.temp_allocator)
	cols := make([]int, bw, context.temp_allocator)
	total := 0
	for y in y0 ..= y1 {
		for x in x0 ..= x1 {
			if labels[y * w + x] != id do continue
			rows[y - y0] += 1
			cols[x - x0] += 1
			total += 1
		}
	}
	if f32(total) < RECT_FILL * f32(bw * bh) do return
	ry0, ry1, rx0, rx1 := 0, bh - 1, 0, bw - 1
	for ry0 < ry1 && f32(rows[ry0]) < EDGE_FILL * f32(bw) do ry0 += 1
	for ry1 > ry0 && f32(rows[ry1]) < EDGE_FILL * f32(bw) do ry1 -= 1
	for rx0 < rx1 && f32(cols[rx0]) < EDGE_FILL * f32(bh) do rx0 += 1
	for rx1 > rx0 && f32(cols[rx1]) < EDGE_FILL * f32(bh) do rx1 -= 1
	for y in y0 ..= y1 {
		for x in x0 ..= x1 {
			c := y * w + x
			in_rect := y - y0 >= ry0 && y - y0 <= ry1 && x - x0 >= rx0 && x - x0 <= rx1
			if in_rect && labels[c] == 0 do labels[c] = id
			if !in_rect && labels[c] == id do labels[c] = 0
		}
	}
}

// ---------------------------------------------------------------------------
// Outlines
// ---------------------------------------------------------------------------

// The outline of the cells labelled `id` as rings in map metres: the outer
// boundary and each hole, along cell edges, straight runs merged. Cells that
// only touch at a corner get separate rings, as 4-connectivity has them.
trace :: proc(labels: []i32, w, h: int, id: i32, cell: f32, allocator := context.allocator) -> [][][2]f32 {
	is :: #force_inline proc(labels: []i32, w, h, x, y: int, id: i32) -> bool {
		return x >= 0 && y >= 0 && x < w && y < h && labels[y * w + x] == id
	}
	// directed boundary edges, the inside on their right (y down)
	Edge :: struct {
		from, to: [2]i32,
	}
	out := make(map[[2]i32][dynamic][2]i32, allocator = context.temp_allocator)
	add :: proc(out: ^map[[2]i32][dynamic][2]i32, a, b: [2]i32) {
		if a not_in out^ do out[a] = make([dynamic][2]i32, context.temp_allocator)
		append(&out[a], b)
	}
	edges := 0
	for y in 0 ..< h {
		for x in 0 ..< w {
			if labels[y * w + x] != id do continue
			X, Y := i32(x), i32(y)
			if !is(labels, w, h, x, y - 1, id) { add(&out, {X, Y}, {X + 1, Y}); edges += 1 }
			if !is(labels, w, h, x + 1, y, id) { add(&out, {X + 1, Y}, {X + 1, Y + 1}); edges += 1 }
			if !is(labels, w, h, x, y + 1, id) { add(&out, {X + 1, Y + 1}, {X, Y + 1}); edges += 1 }
			if !is(labels, w, h, x - 1, y, id) { add(&out, {X, Y + 1}, {X, Y}); edges += 1 }
		}
	}

	// start each ring from the smallest remaining vertex, so the output does
	// not depend on map iteration order
	starts := make([dynamic][2]i32, context.temp_allocator)
	for v in out do append(&starts, v)
	slice.sort_by(starts[:], proc(a, b: [2]i32) -> bool {return a.y < b.y || (a.y == b.y && a.x < b.x)})

	rings := make([dynamic][][2]f32, allocator)
	for s in starts {
		for len(out[s]) > 0 {
			pts := make([dynamic][2]i32, context.temp_allocator)
			cur := s
			dir := [2]i32{0, 0}
			for {
				nexts := &out[cur]
				if len(nexts) == 0 do break
				pick := 0
				if len(nexts) > 1 && dir != {} {
					// prefer a right turn, then straight, then left
					want := [3][2]i32{{-dir.y, dir.x}, dir, {dir.y, -dir.x}}
					found := false
					for wnt in want {
						for nx, i in nexts {
							if nx - cur == wnt {
								pick = i
								found = true
								break
							}
						}
						if found do break
					}
				}
				nxt := nexts[pick]
				unordered_remove(nexts, pick)
				append(&pts, cur)
				dir = nxt - cur
				cur = nxt
				if cur == s && len(out[s]) == 0 do break
				if cur == s do break
			}
			// merge straight runs
			ring := make([dynamic][2]f32, allocator)
			np := len(pts)
			for i in 0 ..< np {
				prev, here, next := pts[(i + np - 1) % np], pts[i], pts[(i + 1) % np]
				if here - prev == next - here do continue
				if (here - prev).x * (next - here).y == (here - prev).y * (next - here).x do continue
				append(&ring, [2]f32{f32(here.x) * cell, f32(here.y) * cell})
			}
			if len(ring) >= 3 do append(&rings, ring[:])
		}
	}
	return rings[:]
}

// ---------------------------------------------------------------------------
// Ids
// ---------------------------------------------------------------------------

KIND_LETTER := [gamemap.Feature_Kind]string{
	.Building = "b",
	.Tree     = "t",
	.Wall     = "w",
	.Volume   = "v",
	.Prop     = "p",
}

// "b:12,40": the kind and the centre in whole metres; ".2", ".3" when taken.
feature_id :: proc(kind: gamemap.Feature_Kind, centre: [2]f32, taken: ^map[string]int, allocator := context.allocator) -> string {
	base := fmt.tprintf("%s:%d,%d", KIND_LETTER[kind], int(math.round(centre.x)), int(math.round(centre.y)))
	id := base
	if n, has := taken[base]; has {
		taken[base] = n + 1
		id = fmt.tprintf("%s.%d", base, n + 1)
	} else {
		taken[strings.clone(base, context.temp_allocator)] = 1
	}
	return strings.clone(id, allocator)
}

// Where an id says its feature is, and of what kind.
parse_id :: proc(id: string) -> (kind: gamemap.Feature_Kind, at: [2]f32, ok: bool) {
	colon := strings.index_byte(id, ':')
	if colon < 0 do return
	found := false
	for letter, k in KIND_LETTER {
		if letter == id[:colon] {
			kind = k
			found = true
		}
	}
	if !found do return
	rest := id[colon + 1:]
	if dot := strings.index_byte(rest, '.'); dot >= 0 do rest = rest[:dot]
	comma := strings.index_byte(rest, ',')
	if comma < 0 do return
	x, xok := strconv.parse_int(rest[:comma])
	y, yok := strconv.parse_int(rest[comma + 1:])
	if !xok || !yok do return
	return kind, {f32(x), f32(y)}, true
}

RETARGET_DISTANCE :: f32(4) // metres

Retarget :: struct {
	edit:     string,
	from, to: string,
}

// Points edits whose target is gone at the nearest feature of the same kind
// within RETARGET_DISTANCE of where the old id says it was. Returns the
// edits to apply (temp-allocated copies) and what was moved; an edit that
// matches nothing is left as it is, for apply_edits to report.
retarget :: proc(m: ^gamemap.Map, edits: []gamemap.Edit) -> (out: []gamemap.Edit, moved: []Retarget) {
	out = make([]gamemap.Edit, len(edits), context.temp_allocator)
	copy(out, edits)
	mv := make([dynamic]Retarget, context.temp_allocator)
	for &e in out {
		if e.target == "" || gamemap.feature_index(m, e.target) >= 0 do continue
		kind, at, ok := parse_id(e.target)
		if !ok do continue
		best, best_d := -1, RETARGET_DISTANCE
		for f, i in m.features {
			if f.kind != kind do continue
			fk, fat, fok := parse_id(f.id)
			if !fok || fk != kind do continue
			d := math.sqrt((fat.x - at.x) * (fat.x - at.x) + (fat.y - at.y) * (fat.y - at.y))
			if d <= best_d {
				best, best_d = i, d
			}
		}
		if best < 0 do continue
		append(&mv, Retarget{edit = e.id, from = e.target, to = m.features[best].id})
		e.target = m.features[best].id
	}
	return out, mv[:]
}

// ---------------------------------------------------------------------------

// How thick a thing is, metres: its area over its length (the long side of
// its box), so a wall a little off the grid's angle still reads as thin.
thickness :: proc(cells, bw, bh: int, cell: f32) -> f32 {
	return f32(cells) * cell / f32(max(bw, bh, 1))
}

@(private)
median :: proc(v: []f32) -> f32 {
	if len(v) == 0 do return 0
	slice.sort(v)
	return v[len(v) / 2]
}

@(private)
round_to :: proc(x, step: f32) -> f32 {
	return math.round(x / step) * step
}

// A placed object's box as a Prop: centre and half size in world x, z, yaw
// as raylib's MatrixRotateY (local (u, v) lands at (cs u + sn v, -sn u + cs v)),
// standing from bottom to top (world y).
prop_from_box :: proc(id: string, centre, half: [2]f32, yaw, bottom, top: f32) -> Prop {
	cs, sn := math.cos(yaw), math.sin(yaw)
	p := Prop{id = id, bottom = bottom, top = top}
	for c, i in ([4][2]f32{{-1, -1}, {1, -1}, {1, 1}, {-1, 1}}) {
		u, v := c.x * half.x, c.y * half.y
		p.corners[i] = centre + {cs * u + sn * v, -sn * u + cs * v}
	}
	return p
}
