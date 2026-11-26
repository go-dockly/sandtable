package mapgen_check

// The gameplay map from a terrain export, without the capture: what the
// editor's map view builds, on a machine that has only the files in out/.
// For reproducing a map from someone else's capture.
//
//   odin run tools/mapgen_check -collection:cmd=../commandos -collection:st=. -- \
//       levels/krakow/build/terrain.terrain.json [levels/krakow/level.json] [out prefix]
//
//   terrain.json  terrain.export's output (ctrl+E writes it into the level's
//                 build/, or --terrain-export): the PGMs beside it
//   level.json    optional: its game region, map cell, kept yaw and edits;
//                 without it, the whole export at 1 m with a measured yaw
//   out prefix    default: "check" beside the export. Writes
//                 <out>.map.json + .map.bin and <out>.ppm, a picture of the map
//
// Prints the terrain's classes, ground / floor / surface along a few rows
// (where the ground filter goes wrong shows as a street far above the ground),
// the map's stats and its features.

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"

import "st:mapgen"
import "st:scene"
import "st:terrain"
import "cmd:gamemap"

main :: proc() {
	args := os.args[1:]
	if len(args) < 1 || len(args) > 3 {
		fmt.eprintln("usage: mapgen_check <prefix>.terrain.json [level.json] [out prefix]")
		os.exit(2)
	}
	json_path := args[0]
	ter, ws, lerr := terrain.load_export(json_path)
	if lerr != .None {
		fmt.eprintfln("%s: %v", json_path, lerr)
		os.exit(1)
	}
	defer terrain.destroy(&ter)
	if ws <= 0 do ws = 1

	// ---- the level: region, cell, yaw, edits --------------------------------
	origin, size := scene.default_region(ter, ws)
	params := mapgen.default_params()
	edits: []gamemap.Edit
	if len(args) >= 2 {
		data, rerr := os.read_entire_file(args[1], context.allocator)
		if rerr != nil {
			fmt.eprintfln("%s: %v", args[1], rerr)
			os.exit(1)
		}
		lv, warnings, derr := scene.decode(data)
		if derr != nil {
			fmt.eprintfln("%s: %v", args[1], derr)
			os.exit(1)
		}
		for w in warnings do fmt.printfln("level: %s", w)
		if lv.world_scale > 0 && abs(lv.world_scale - ws) > 1e-6 * ws {
			fmt.printfln("level: world scale %v, the export's %v: using the export's", lv.world_scale, ws)
		}
		if g, ok := lv.game.?; ok {
			origin, size = g.origin, g.size
		}
		if s, ok := lv.map_section.?; ok {
			params.cell = scene.map_cell(s)
			params.yaw = s.yaw
			edits = s.edits
		}
	}
	out_prefix := os.dir(json_path)
	out_prefix = args[2] if len(args) >= 3 else fmt.tprintf("%s/check", out_prefix if out_prefix != "" else ".")

	// ---- the terrain --------------------------------------------------------
	n := ter.w * ter.h
	pct :: proc(k, n: int) -> f64 {return 100 * f64(k) / f64(max(n, 1))}
	st := ter.stats
	fmt.printfln("terrain %dx%d @ %.2f m | ground %.0f%% object %.0f%% structure %.0f%% no data %.0f%%",
		ter.w, ter.h, ter.cell / ws, pct(st.ground_cells, n), pct(st.object_cells, n),
		pct(st.structure_cells, n), pct(n - st.data_cells, n))
	fmt.printfln("heights %.1f..%.1f m (world %v..%v), structure from %.1f m above the ground",
		ter.lo / ws, ter.hi / ws, ter.lo, ter.hi, ter.params.structure_height / ws)
	if slice.equal(ter.floor, ter.ground) {
		fmt.println("NOTE: no floor layer in this export (made before floor.pgm): the floor is the ground, so every\n" +
			"      structure seems to show ground under it and reads as a tree. Re-export for a real map.")
	}
	print_rows(ter, ws)

	// ---- the map ------------------------------------------------------------
	m, stats := mapgen.build(mapgen.Input{terrain = &ter, world_scale = ws, origin = origin, size = size, params = params})
	defer gamemap.destroy(&m)
	moved_edits, moved := mapgen.retarget(&m, edits)
	problems := gamemap.apply_edits(&m, moved_edits, context.temp_allocator)
	for mv in moved do fmt.printfln("edit %s: %s not found, using %s nearby", mv.edit, mv.from, mv.to)
	for p in problems do fmt.printfln("edit %s: %s", p.edit, p.message)
	_, kept := params.yaw.?
	fmt.printfln("\nmap %dx%d @ %.1f m, yaw %.1f (%s) | %d buildings %d trees %d walls %d low | walkable %d, steep %d | %d edits, %d problems",
		stats.w, stats.h, m.cell, stats.yaw, "kept" if kept else "measured",
		stats.buildings, stats.trees, stats.walls, stats.low, stats.walkable, stats.steep, len(edits), len(problems))
	print_features(&m)

	map_path := fmt.tprintf("%s.map.json", out_prefix)
	if e := gamemap.save(m, map_path); e != .None {
		fmt.eprintfln("%s: %v", map_path, e)
		os.exit(1)
	}
	fmt.printfln("wrote %s (+ .bin)", map_path)
	ppm := fmt.tprintf("%s.ppm", out_prefix)
	if e := write_picture(&m, ppm); e != nil {
		fmt.eprintfln("%s: %v", ppm, e)
		os.exit(1)
	}
	fmt.printfln("wrote %s: ground grey by height, buildings red, trees green, walls yellow, low solids and volumes orange, props blue, not walkable black; row 0 is map y 0", ppm)
}

// Ground, floor (the low layer the filter saw) and surface along five rows,
// every few metres, in metres; the class as a letter: . empty, g ground,
// o object, S structure.
print_rows :: proc(t: terrain.Terrain, ws: f32) {
	COLUMNS :: 24
	step := max(1, t.w / COLUMNS)
	letters := [terrain.Class]string{.Empty = ".", .Ground = "g", .Object = "o", .Structure = "S"}
	for k in 1 ..= 5 {
		z := k * t.h / 6
		fmt.printfln("\nrow z %d (%.0f m)", z, f32(z) * t.cell / ws)
		b := strings.builder_make(context.temp_allocator)
		line :: proc(b: ^strings.Builder, name: string) {
			strings.builder_reset(b)
			fmt.sbprintf(b, "  %-8s", name)
		}
		line(&b, "x m")
		for x := 0; x < t.w; x += step do fmt.sbprintf(&b, "%6.0f", f32(x) * t.cell / ws)
		fmt.println(strings.to_string(b))
		line(&b, "class")
		for x := 0; x < t.w; x += step do fmt.sbprintf(&b, "%6s", letters[t.class[z * t.w + x]])
		fmt.println(strings.to_string(b))
		layers := [3][]f32{t.surface, t.floor, t.ground}
		names := [3]string{"surface", "floor", "ground"}
		for v, i in layers {
			line(&b, names[i])
			for x := 0; x < t.w; x += step do fmt.sbprintf(&b, "%6.1f", v[z * t.w + x] / ws)
			fmt.println(strings.to_string(b))
		}
	}
}

// The features, biggest first, at most 40.
print_features :: proc(m: ^gamemap.Map) {
	Row :: struct {
		f:    ^gamemap.Feature,
		area: f32,
	}
	rows := make([dynamic]Row, context.temp_allocator)
	for &f in m.features do append(&rows, Row{&f, ring_area(f.footprint)})
	slice.sort_by(rows[:], proc(a, b: Row) -> bool {return a.area > b.area})
	fmt.printfln("\n%-12s %-9s %8s %7s %7s %6s", "feature", "kind", "area m²", "base", "height", "rings")
	for r, i in rows {
		if i == 40 {
			fmt.printfln("... %d more", len(rows) - 40)
			break
		}
		f := r.f
		fmt.printfln("%-12s %-9v %8.0f %7.1f %7.1f %6d", f.id, f.kind, r.area, f.base, f.height, len(f.footprint))
	}
}

// Even-odd area: holes subtract.
ring_area :: proc(rings: [][][2]f32) -> f32 {
	total: f32
	for ring, i in rings {
		a: f32
		for p, k in ring {
			q := ring[(k + 1) % len(ring)]
			a += p.x * q.y - q.x * p.y
		}
		a = abs(a) * 0.5
		total += a if i == 0 else -a
	}
	return abs(total)
}

inside :: proc(rings: [][][2]f32, p: [2]f32) -> bool {
	in_ := false
	for ring in rings {
		for a, k in ring {
			b := ring[(k + 1) % len(ring)]
			if (a.y > p.y) != (b.y > p.y) && p.x < a.x + (p.y - a.y) / (b.y - a.y) * (b.x - a.x) do in_ = !in_
		}
	}
	return in_
}

// One pixel per map cell, the top view: the topmost feature's colour where
// one covers the cell, else the ground layer's height in grey, black where
// it cannot be walked.
write_picture :: proc(m: ^gamemap.Map, path: string) -> os.Error {
	w, h := m.w, m.h
	header := fmt.tprintf("P6\n%d %d\n255\n", w, h)
	buf := make([]u8, len(header) + w * h * 3, context.temp_allocator)
	copy(buf, header)
	px := buf[len(header):]

	ground := m.layers[0]
	lo, hi := i16(max(i16)), i16(min(i16))
	for v in ground.height {
		if v == gamemap.NO_FLOOR do continue
		lo, hi = min(lo, v), max(hi, v)
	}
	if hi <= lo do hi = lo + 1
	for y in 0 ..< h {
		for x in 0 ..< w {
			c := y * w + x
			v := ground.height[c]
			col := [3]u8{0, 0, 0}
			if v != gamemap.NO_FLOOR {
				g := u8(70 + 150 * f32(v - lo) / f32(hi - lo))
				col = {g, g, g}
			}
			px[c * 3 + 0], px[c * 3 + 1], px[c * 3 + 2] = col[0], col[1], col[2]
		}
	}
	colours := [gamemap.Feature_Kind][3]u8{
		.Building = {200, 70, 60},
		.Tree     = {70, 160, 70},
		.Wall     = {220, 200, 60},
		.Volume   = {230, 140, 50},
		.Prop     = {80, 120, 220},
	}
	// smallest last, so a building inside a tree's ring still shows
	order := make([]int, len(m.features), context.temp_allocator)
	areas := make([]f32, len(m.features), context.temp_allocator)
	for &f, i in m.features {
		order[i] = i
		areas[i] = ring_area(f.footprint)
	}
	context.user_ptr = &areas
	slice.stable_sort_by(order, proc(a, b: int) -> bool {
		areas := (^[]f32)(context.user_ptr)^
		return areas[a] > areas[b]
	})
	for i in order {
		f := &m.features[i]
		if len(f.footprint) == 0 do continue
		lo2, hi2 := [2]f32{max(f32), max(f32)}, [2]f32{-max(f32), -max(f32)}
		for ring in f.footprint do for p in ring {
			lo2 = {min(lo2.x, p.x), min(lo2.y, p.y)}
			hi2 = {max(hi2.x, p.x), max(hi2.y, p.y)}
		}
		x0 := clamp(int(lo2.x / m.cell), 0, w - 1)
		x1 := clamp(int(hi2.x / m.cell), 0, w - 1)
		y0 := clamp(int(lo2.y / m.cell), 0, h - 1)
		y1 := clamp(int(hi2.y / m.cell), 0, h - 1)
		col := colours[f.kind]
		for y in y0 ..= y1 {
			for x in x0 ..= x1 {
				if !inside(f.footprint, {(f32(x) + 0.5) * m.cell, (f32(y) + 0.5) * m.cell}) do continue
				c := y * w + x
				px[c * 3 + 0], px[c * 3 + 1], px[c * 3 + 2] = col[0], col[1], col[2]
			}
		}
	}
	return os.write_entire_file(path, buf)
}
