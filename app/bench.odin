package main

// The speed test of the map spec's first slice: the splat backdrop plus 10
// characters, at 60 fps on the hardware you target.
//
//   odin run app -out:sandtable -o:speed -collection:cmd=../commandos -- levels/krakow/level.json --bench 30
//
// The window renders the level as the game would, uncapped and without
// vsync, with 10 characters walking the gameplay map (9 of them checking
// can_see_body against the first every frame, so the game's sight and
// movement cost is in the frame too; capsules 1.8 m tall stand in for
// whatever the game draws them with). The time is split into phases that
// each change one thing, so the stats say where a frame goes:
//
//   still        camera still: no sorting, the draw and the post pass alone
//   still ss1    the same at supersampling 1: how much is fill rate
//   still half   the same drawing half the splats: how much is per splat
//   pan          the camera following a running commando: the game's case
//   turn         the camera turning 6° a second: re-sorts as often as it can
//
// The camera ignores the mouse and keys while it runs. Every phase starts
// with a second of warm-up that is not recorded. Frames are timed with the
// wall clock; the CPU sort, the characters' walk and sight (sim) and each
// path search (replan) on their own, so a hitch can be put on one of them. The stats go
// to the console and to `--bench-out` (default bench.json); then the window
// closes.

import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:os"
import "core:slice"
import "core:time"

import rl "vendor:raylib"

import "cmd:gamemap"

BENCH_CHARACTERS :: 10
BENCH_WARMUP     :: f64(1)    // seconds per phase, not recorded
BENCH_TURN       :: f32(6)    // degrees per second the camera turns
BENCH_RUN        :: f32(5)    // metres per second the panning camera moves: a running commando
BENCH_PAN        :: f32(25)   // metres it pans to and fro
BENCH_BUDGET_MS  :: 1000.0 / 60

Bench_Motion :: enum {
	Still,
	Pan,
	Turn,
}

Bench_Phase :: struct {
	name:     string,
	motion:   Bench_Motion,
	ss:       int, // 0: as set
	fraction: f32, // of the splats drawn
}

BENCH_PHASES := [?]Bench_Phase{
	{"still", .Still, 0, 1},
	{"still ss1", .Still, 1, 1},
	{"still half splats", .Still, 0, 0.5},
	{"pan (follow)", .Pan, 0, 1},
	{"turn", .Turn, 0, 1},
}

Bench_Character :: struct {
	path:  [][3]f32, // map metres
	index: int,
	pos:   [3]f32,
	seed:  u64,
}

Bench_Stats :: struct {
	name:        string `json:"name"`,
	frames:      int    `json:"frames"`,
	mean_ms:     f64    `json:"meanMs"`,
	p50_ms:      f64    `json:"p50Ms"`,
	p95_ms:      f64    `json:"p95Ms"`,
	p99_ms:      f64    `json:"p99Ms"`,
	max_ms:      f64    `json:"maxMs"`,
	mean_fps:    f64    `json:"meanFps"`,
	over_budget: f64    `json:"overBudget"`, // share of frames over 16.7 ms
	passes:      bool   `json:"passes60"`,   // p95 within 16.7 ms
	sorts:       int    `json:"sorts"`,
	sort_ms:     f64    `json:"sortMs"`,     // mean CPU time of one sort and its upload
	sort_max_ms: f64    `json:"sortMaxMs"`,
	sim_ms:      f64    `json:"simMs"`,      // mean per frame: walking, sight, replans
	sim_max_ms:  f64    `json:"simMaxMs"`,
	replans:     int    `json:"replans"`,
	replan_ms:   f64    `json:"replanMs"`,   // mean of one path search
	replan_max_ms: f64  `json:"replanMaxMs"`,
	ss:          int    `json:"supersample"`,
	splats:      int    `json:"splatsDrawn"`,
}

Bench :: struct {
	seconds:    f32, // in all
	out:        string,
	ok:         bool,
	note:       string, // why it could not start
	phase:      int,
	phase_start: time.Tick,
	last:       time.Tick,
	frames_ms:  [dynamic]f64,
	sorts_ms:   [dynamic]f64,
	sims_ms:    [dynamic]f64,
	replans_ms: [dynamic]f64,
	results:    [dynamic]Bench_Stats,
	characters: [BENCH_CHARACTERS]Bench_Character,
	start_target: [3]f32,
	start_azimuth: f32,
	pan_t:      f32,
	ss_set:     int, // supersampling as the user set it
	splats:     int,
	art:        [2]i32,
	sight_checks: int,
}

// A deterministic stream of numbers: the same level, the same walk.
@(private = "file")
next_rand :: proc(seed: ^u64) -> u64 {
	seed^ = seed^ * 6364136223846793005 + 1442695040888963407
	return seed^ >> 33
}

// A random walkable ground cell, map metres; false if the map has few.
@(private = "file")
random_floor :: proc(m: ^gamemap.Map, seed: ^u64) -> ([3]f32, bool) {
	for _ in 0 ..< 2000 {
		x := int(next_rand(seed) % u64(m.w))
		y := int(next_rand(seed) % u64(m.h))
		n := gamemap.Node{0, i32(x), i32(y)}
		if gamemap.standable(m, n, {radius = 0.4}) do return gamemap.node_point(m, n), true
	}
	return {}, false
}

// Times replan into b.replans_ms once the phase's warm-up is over.
@(private = "file")
replan_timed :: proc(b: ^Bench, c: ^Bench_Character, m: ^gamemap.Map, record: bool) {
	t := time.tick_now()
	replan(c, m)
	if record do append(&b.replans_ms, time.duration_milliseconds(time.tick_since(t)))
}

@(private = "file")
replan :: proc(c: ^Bench_Character, m: ^gamemap.Map) {
	delete(c.path)
	c.path = nil
	c.index = 0
	for _ in 0 ..< 8 {
		goal, ok := random_floor(m, &c.seed)
		if !ok do return
		from, fok := gamemap.node_at(m, c.pos)
		to, tok := gamemap.node_at(m, goal)
		if !fok || !tok do continue
		p := gamemap.find_path(m, from, to, {radius = 0.4}, context.temp_allocator)
		if !p.found || len(p.nodes) < 2 do continue
		c.path = gamemap.path_points(m, p)
		return
	}
}

// Puts the characters on the map. The map must be built.
bench_start :: proc(b: ^Bench, wm: ^World_Map, iso: Iso, ss, splats: int) {
	if !wm.ok {
		b.note = "no gameplay map (the level needs a terrain)"
		return
	}
	m := &wm.m
	for &c, i in b.characters {
		c.seed = u64(i + 1) * 0x9E3779B97F4A7C15
		pos, ok := random_floor(m, &c.seed)
		if !ok {
			b.note = "the map has too little walkable ground"
			return
		}
		c.pos = pos
		replan(&c, m)
	}
	b.start_target, b.start_azimuth = iso.target, iso.azimuth
	b.ss_set, b.splats = ss, splats
	b.phase_start = time.tick_now()
	b.last = b.phase_start
	b.ok = true
}

bench_phase_seconds :: proc(b: ^Bench) -> f64 {
	return f64(b.seconds) / len(BENCH_PHASES)
}

// The current phase's supersampling.
bench_ss :: proc(b: ^Bench) -> int {
	ph := BENCH_PHASES[b.phase]
	return ph.ss if ph.ss > 0 else b.ss_set
}

// How many splats the current phase draws of those sorted.
bench_visible :: proc(b: ^Bench, visible: int) -> int {
	return int(f32(visible) * BENCH_PHASES[b.phase].fraction)
}

// Called after a sort and its upload, with the time they took.
bench_sorted :: proc(b: ^Bench, ms: f64) {
	if !b.ok do return
	if time.duration_seconds(time.tick_since(b.phase_start)) > BENCH_WARMUP do append(&b.sorts_ms, ms)
}

// One frame, at its start: records the last frame's wall-clock time, moves
// the camera as the phase wants, walks the characters and checks their
// sight. true when the test is over.
bench_frame :: proc(b: ^Bench, wm: ^World_Map, iso: ^Iso, world_scale: f32) -> bool {
	if !b.ok do return true
	now := time.tick_now()
	dt := time.duration_seconds(time.tick_diff(b.last, now))
	b.last = now
	in_phase := time.duration_seconds(time.tick_diff(b.phase_start, now))
	record := in_phase > BENCH_WARMUP
	if record do append(&b.frames_ms, dt * 1000)
	if in_phase >= BENCH_WARMUP + bench_phase_seconds(b) {
		bench_close_phase(b)
		b.phase += 1
		if b.phase >= len(BENCH_PHASES) do return true
		b.phase_start = now
		iso.target, iso.azimuth = b.start_target, b.start_azimuth
		b.pan_t = 0
		record = false
	}

	switch BENCH_PHASES[b.phase].motion {
	case .Still:
	case .Turn:
		iso.azimuth = math.mod(iso.azimuth + BENCH_TURN * f32(dt), 360)
	case .Pan:
		// to and fro along the view's right, at a run
		b.pan_t += f32(dt)
		s, c := math.sincos(iso.azimuth * math.RAD_PER_DEG)
		right := [3]f32{c, 0, -s}
		period := 2 * BENCH_PAN / BENCH_RUN
		phase := math.mod(b.pan_t, period) / period
		tri := 1 - abs(2 * phase - 1) // 0 -> 1 -> 0
		iso.target = b.start_target + right * (tri - 0.5) * BENCH_PAN * world_scale
	}

	t_sim := time.tick_now()
	m := &wm.m
	step := gamemap.DEFAULT_SPEED * f32(dt)
	for &c in b.characters {
		if c.index >= len(c.path) do replan_timed(b, &c, m, record)
		left := step
		for left > 0 && c.index < len(c.path) {
			d := c.path[c.index] - c.pos
			dist := math.sqrt(d.x * d.x + d.y * d.y)
			if dist <= left {
				c.pos = c.path[c.index]
				c.index += 1
				left -= dist
			} else {
				c.pos += d * (left / dist)
				left = 0
			}
		}
	}
	target := b.characters[0].pos
	for c in b.characters[1:] {
		b.sight_checks += 1
		_ = gamemap.can_see_body(m, gamemap.eye_point(c.pos, .Standing), target, .Standing)
	}
	if record do append(&b.sims_ms, time.duration_milliseconds(time.tick_since(t_sim)))
	return false
}

@(private = "file")
bench_close_phase :: proc(b: ^Bench) {
	ph := BENCH_PHASES[b.phase]
	st := Bench_Stats{name = ph.name, ss = bench_ss(b), splats = int(f32(b.splats) * ph.fraction)}
	ms := b.frames_ms[:]
	if len(ms) > 0 {
		sorted := slice.clone(ms, context.temp_allocator)
		slice.sort(sorted)
		q :: proc(s: []f64, f: f64) -> f64 {return s[min(int(f * f64(len(s) - 1) + 0.5), len(s) - 1)]}
		sum, over := 0.0, 0
		for v in ms {
			sum += v
			if v > BENCH_BUDGET_MS do over += 1
		}
		st.frames = len(ms)
		st.mean_ms = sum / f64(len(ms))
		st.p50_ms, st.p95_ms, st.p99_ms = q(sorted, 0.5), q(sorted, 0.95), q(sorted, 0.99)
		st.max_ms = sorted[len(sorted) - 1]
		st.mean_fps = 1000 / st.mean_ms
		st.over_budget = f64(over) / f64(len(ms))
		st.passes = st.p95_ms <= BENCH_BUDGET_MS
	}
	mean_max :: proc(v: []f64) -> (mean, top: f64) {
		if len(v) == 0 do return
		for x in v {
			mean += x
			top = max(top, x)
		}
		return mean / f64(len(v)), top
	}
	st.sorts = len(b.sorts_ms)
	st.sort_ms, st.sort_max_ms = mean_max(b.sorts_ms[:])
	st.sim_ms, st.sim_max_ms = mean_max(b.sims_ms[:])
	st.replans = len(b.replans_ms)
	st.replan_ms, st.replan_max_ms = mean_max(b.replans_ms[:])
	append(&b.results, st)
	clear(&b.frames_ms)
	clear(&b.sorts_ms)
	clear(&b.sims_ms)
	clear(&b.replans_ms)
	fmt.printfln("bench: %-18s %5d frames  mean %6.2f ms (%3.0f fps)  p50 %6.2f  p95 %6.2f  p99 %6.2f  max %7.2f  | %4d sorts of %6.2f ms (max %.2f) | sim %.2f ms (max %.2f), %d replans of %.2f ms (max %.2f) | %s",
		st.name, st.frames, st.mean_ms, st.mean_fps, st.p50_ms, st.p95_ms, st.p99_ms, st.max_ms, st.sorts, st.sort_ms, st.sort_max_ms,
		st.sim_ms, st.sim_max_ms, st.replans, st.replan_ms, st.replan_max_ms,
		"60 fps holds" if st.passes else "under 60 fps")
}

bench_draw :: proc(b: ^Bench, wm: ^World_Map) {
	if !b.ok do return
	f := wm.m.frame
	r := 0.3 * f.world_scale
	for c, i in b.characters {
		foot := gamemap.map_to_world(f, c.pos + {0, 0, 0.3})
		head := gamemap.map_to_world(f, c.pos + {0, 0, 1.5})
		col := rl.Color{60, 90, 200, 255} if i == 0 else rl.Color{200, 60, 50, 255}
		rl.DrawCapsule(foot, head, r, 6, 4, col)
	}
}

Bench_Report :: struct {
	window:       [2]i32        `json:"window"`,
	art:          [2]i32        `json:"art"`,
	splats:       int           `json:"splats"`,
	characters:   int           `json:"characters"`,
	map_cells:    [2]int        `json:"mapCells"`,
	sight_checks: int           `json:"sightChecks"`,
	phases:       []Bench_Stats `json:"phases"`,
}

// The stats, to the console and to b.out.
bench_report :: proc(b: ^Bench, wm: ^World_Map) {
	if !b.ok {
		fmt.eprintfln("bench: did not run: %s", b.note)
		return
	}
	r := Bench_Report{
		window       = {rl.GetScreenWidth(), rl.GetScreenHeight()},
		art          = b.art,
		splats       = b.splats,
		characters   = BENCH_CHARACTERS,
		map_cells    = {wm.m.w, wm.m.h},
		sight_checks = b.sight_checks,
		phases       = b.results[:],
	}
	fmt.printfln("bench: %d splats, %d characters, art %dx%d in a %dx%d window", r.splats, r.characters, r.art.x, r.art.y, r.window.x, r.window.y)
	text, err := json.marshal(r, {pretty = true}, context.temp_allocator)
	if err != nil do return
	if werr := os.write_entire_file(b.out, text); werr != nil {
		fmt.eprintfln("bench: cannot write %s: %v", b.out, werr)
	} else {
		fmt.printfln("bench: wrote %s", b.out)
	}
}

bench_destroy :: proc(b: ^Bench) {
	for &c in b.characters do delete(c.path)
	delete(b.frames_ms)
	delete(b.sorts_ms)
	delete(b.sims_ms)
	delete(b.replans_ms)
	delete(b.results)
}
