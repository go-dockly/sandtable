package main

// The speed test of the map spec's first slice: the splat backdrop plus 10
// characters, at 60 fps on the hardware you target.
//
//   odin run . -o:speed -collection:cmd=../commandos -- levels/krakow.json --bench 30
//
// For `--bench` seconds the window renders the level as the game would: the
// splats through the pixel-art pass, with the camera turning slowly the whole
// time (the worst case: the splats are re-sorted every frame, as when the
// camera follows a moving commando), and 10 characters walking the gameplay
// map. Each frame every character walks its gamemap path and checks
// can_see_body against the first, so the game's sight and movement cost is
// in the frame too. Characters are capsules 1.8 m tall: a stand-in for
// whatever the game draws them with.
//
// The frame rate is not capped. After the first second (warm-up), every
// frame's time is recorded; at the end the stats go to the console and to
// `--bench-out` (default bench.json), and the window closes.

import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:os"
import "core:slice"

import rl "vendor:raylib"

import "cmd:gamemap"

BENCH_CHARACTERS :: 10
BENCH_WARMUP     :: f32(1)  // seconds not recorded
BENCH_TURN       :: f32(6)  // degrees per second the camera turns
BENCH_BUDGET_MS  :: 1000.0 / 60

Bench_Character :: struct {
	path:  [][3]f32, // map metres
	index: int,
	pos:   [3]f32,
	seed:  u64,
}

Bench :: struct {
	seconds:    f32,
	out:        string,
	ok:         bool,
	elapsed:    f32,
	frames_ms:  [dynamic]f64,
	characters: [BENCH_CHARACTERS]Bench_Character,
	sight_checks: int,
	seen:       int,
	note:       string, // why it could not start
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
bench_start :: proc(b: ^Bench, wm: ^World_Map) {
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
	b.ok = true
}

// One frame: records its time, turns the camera, walks the characters and
// checks their sight. true when the test is over.
bench_frame :: proc(b: ^Bench, wm: ^World_Map, iso: ^Iso, dt: f32) -> bool {
	if !b.ok do return true
	b.elapsed += dt
	if b.elapsed > BENCH_WARMUP do append(&b.frames_ms, f64(dt) * 1000)
	iso.azimuth = math.mod(iso.azimuth + BENCH_TURN * dt, 360)

	m := &wm.m
	step := gamemap.DEFAULT_SPEED * dt
	for &c in b.characters {
		if c.index >= len(c.path) do replan(&c, m)
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
	// everyone looks at the first: the cost of 9 guards' sight a frame
	target := b.characters[0].pos
	for c in b.characters[1:] {
		b.sight_checks += 1
		if gamemap.can_see_body(m, gamemap.eye_point(c.pos, .Standing), target, .Standing) do b.seen += 1
	}
	return b.elapsed >= b.seconds + BENCH_WARMUP
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
	seconds:       f32    `json:"seconds"`,
	frames:        int    `json:"frames"`,
	window:        [2]i32 `json:"window"`,
	art:           [2]i32 `json:"art"`,
	supersample:   int    `json:"supersample"`,
	splats:        int    `json:"splats"`,
	characters:    int    `json:"characters"`,
	map_cells:     [2]int `json:"mapCells"`,
	mean_ms:       f64    `json:"meanMs"`,
	p50_ms:        f64    `json:"p50Ms"`,
	p95_ms:        f64    `json:"p95Ms"`,
	p99_ms:        f64    `json:"p99Ms"`,
	max_ms:        f64    `json:"maxMs"`,
	mean_fps:      f64    `json:"meanFps"`,
	over_budget:   f64    `json:"overBudget"`, // share of frames over 16.7 ms
	passes:        bool   `json:"passes60"`,   // p95 within 16.7 ms
	sight_checks:  int    `json:"sightChecks"`,
	renderer:      string `json:"renderer"`,
}

// The stats, to the console and to b.out.
bench_report :: proc(b: ^Bench, wm: ^World_Map, splats: int, art: [2]i32, ss: int) {
	if !b.ok {
		fmt.eprintfln("bench: did not run: %s", b.note)
		return
	}
	ms := b.frames_ms[:]
	if len(ms) == 0 {
		fmt.eprintln("bench: no frames recorded")
		return
	}
	sorted := slice.clone(ms, context.temp_allocator)
	slice.sort(sorted)
	q :: proc(s: []f64, f: f64) -> f64 {return s[min(int(f * f64(len(s) - 1) + 0.5), len(s) - 1)]}
	sum, over := 0.0, 0
	for v in ms {
		sum += v
		if v > BENCH_BUDGET_MS do over += 1
	}
	mean := sum / f64(len(ms))
	r := Bench_Report{
		seconds      = b.seconds,
		frames       = len(ms),
		window       = {rl.GetScreenWidth(), rl.GetScreenHeight()},
		art          = art,
		supersample  = ss,
		splats       = splats,
		characters   = BENCH_CHARACTERS,
		map_cells    = {wm.m.w, wm.m.h},
		mean_ms      = mean,
		p50_ms       = q(sorted, 0.5),
		p95_ms       = q(sorted, 0.95),
		p99_ms       = q(sorted, 0.99),
		max_ms       = sorted[len(sorted) - 1],
		mean_fps     = 1000 / mean,
		over_budget  = f64(over) / f64(len(ms)),
		passes       = q(sorted, 0.95) <= BENCH_BUDGET_MS,
		sight_checks = b.sight_checks,
		renderer     = fmt.tprintf("%s", rl.GetMonitorName(rl.GetCurrentMonitor())),
	}
	fmt.printfln("bench: %d frames, %d splats, %d characters, art %dx%d (ss %d) in a %dx%d window",
		r.frames, r.splats, r.characters, r.art.x, r.art.y, r.supersample, r.window.x, r.window.y)
	fmt.printfln("bench: mean %.2f ms (%.0f fps), p50 %.2f, p95 %.2f, p99 %.2f, max %.2f ms; %.1f%% of frames over 16.7 ms: %s",
		r.mean_ms, r.mean_fps, r.p50_ms, r.p95_ms, r.p99_ms, r.max_ms, 100 * r.over_budget,
		"60 fps holds" if r.passes else "60 fps does NOT hold (p95 over budget)")
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
}
