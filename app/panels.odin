package main

// The panels: two windows of collapsible sections, sized to what they hold.
//
//   sandtable (left)   Level: the file, save / reload / export, the other
//                      levels to open; Object: the selection; Terrain & map
//   View (right)       Look: camera and pixel-art settings; Pixel: the zoom
//                      ends and tuning; Keys: every shortcut
//
// The panels show state and change it through the same shortcuts as the
// keys (ui_press) or, for plain settings, directly. They never load or write
// files themselves: opening a level, a view change and a rebuild come back
// to main in Panels.

import "core:fmt"
import "core:math"
import "core:time"

import mu "vendor:microui"
import rl "vendor:raylib"

import "../artgrid"
import "../editor"
import "../scene"

LEVELS_ROOT    :: "levels"
LEVELS_RESCAN  :: 2.0 // seconds between looks at levels/ while the list is open
UI_LEFT_W      :: 400
UI_RIGHT_W     :: 340
UI_KEY_W       :: 104 // the label column of key / value rows
UI_MARGIN      :: 10

// What the panels keep between frames, and what they ask main to do.
Panels :: struct {
	levels:      []string, // levels/<name>/level.json, sorted
	levels_at:   time.Tick,
	open_level:  string,   // a level to open (temp allocated); "" none
	want_view:   Maybe(Terrain_View),
	rebuild:     bool,     // rebuild the terrain (shift+Z)
}

panels_destroy :: proc(ps: ^Panels) {
	for s in ps.levels do delete(s)
	delete(ps.levels)
	ps^ = {}
}

// Everything the panels show, from main's frame.
Ui_Env :: struct {
	lv:          ^Level_State,
	p:           ^Placement,
	wt:          ^World_Terrain,
	wm:          ^World_Map,
	cfg:         ^Post_Settings,
	crisp_alpha: ^f32,
	grade:       ^f32,
	tune:        ^Pixel_Tune,
	palette:     Palette_Mode,
	game_cam:    bool,
	px:          scene.Pixel,
	grid:        artgrid.Grid,
	view_height: f32, // world units
	world_scale: f32,
	win:         [2]f32,
	splats:      int,
	title:       string,
	load_err:    string,
	model_err:   string,
	dirty:       bool,
	missing:     int,
	cursor_game: Maybe([2]f32),
}

COL_OK    :: mu.Color{150, 205, 150, 255}
COL_WARN  :: mu.Color{235, 175, 95, 255}
COL_BAD   :: mu.Color{235, 110, 95, 255}
COL_DIM   :: mu.Color{150, 154, 165, 255}
COL_VALUE :: mu.Color{230, 214, 160, 255}

panels :: proc(ui: ^Ui, ps: ^Panels, e: Ui_Env) {
	ps.open_level = ""
	ps.want_view = nil
	ps.rebuild = false
	if !ui.visible do return
	ctx := ui.ctx
	opts := mu.Options{.NO_CLOSE, .NO_RESIZE}

	fit_window(ctx, "sandtable", UI_LEFT_W, e.win.y)
	if mu.begin_window(ctx, "sandtable", {UI_MARGIN, UI_MARGIN, UI_LEFT_W, 200}, opts) {
		panel_level(ui, ps, e)
		panel_object(ctx, e)
		panel_terrain(ctx, ps, e)
		mu.end_window(ctx)
	}
	right := i32(e.win.x) - UI_RIGHT_W - UI_MARGIN
	fit_window(ctx, "View", UI_RIGHT_W, e.win.y)
	if mu.begin_window(ctx, "View", {max(right, UI_LEFT_W + 2 * UI_MARGIN), UI_MARGIN, UI_RIGHT_W, 200}, opts) {
		panel_look(ui, e)
		if e.game_cam do panel_pixel(ui, e)
		panel_keys(ctx)
		mu.end_window(ctx)
	}
}

// A window's size before microui lays it out: a fixed width, and as tall as
// what it held last frame, but not past the bottom of the screen (it scrolls
// then). microui's AUTO_SIZE does this from the content's width too, which
// drifts a few pixels a frame with rows that fill the width: the windows
// shrank and flickered.
fit_window :: proc(ctx: ^mu.Context, title: string, w: i32, win_h: f32) {
	cnt := mu.get_container(ctx, title)
	if cnt == nil || cnt.rect.w == 0 do return // first frame: begin_window takes its rect
	chrome := ctx.style.title_height + 2 * ctx.style.padding
	room := i32(win_h) - cnt.rect.y - UI_MARGIN
	cnt.rect.w = w
	cnt.rect.h = clamp(cnt.content_size.y + chrome, chrome, max(room, chrome))
}

// The level's message line (level_say), bottom left, for a few seconds.
draw_message :: proc(ui: ^Ui, lv: ^Level_State, win: [2]f32) {
	if lv.msg_len == 0 || time.duration_seconds(time.since(lv.msg_at)) >= CONFIRM_S do return
	text := string(lv.message[:lv.msg_len])
	w := ui_measure(ui, text)
	x, y := f32(10), win.y - UI_TEXT - 18
	rl.DrawRectangleRec({x - 6, y - 5, w + 12, UI_TEXT + 10}, {20, 21, 25, 220})
	ui_text(ui, text, x, y, {235, 110, 95, 255} if lv.msg_bad else {232, 233, 236, 255}, shadow = false)
}

// ---------------------------------------------------------------------------
// sandtable
// ---------------------------------------------------------------------------

panel_level :: proc(ui: ^Ui, ps: ^Panels, e: Ui_Env) {
	ctx := ui.ctx
	lv := e.lv
	if .ACTIVE not_in mu.header(ctx, "Level", {.EXPANDED}) do return
	value_row(ctx, "level", lv.id if len(lv.id) > 0 else "new")
	value_row(ctx, "file", lv.path)
	mu.layout_row(ctx, {-1})
	state, col := "not saved yet", COL_WARN
	switch {
	case e.dirty:          state = "unsaved changes"
	case len(lv.saved) > 0: state, col = "saved", COL_OK
	}
	if e.missing > 0 do state = fmt.tprintf("%s, %d model%s missing", state, e.missing, "" if e.missing == 1 else "s")
	coloured(ctx, state, col)
	if len(e.load_err) > 0 do coloured(ctx, e.load_err, COL_BAD)

	mu.layout_row(ctx, {-1})
	if c, ok := e.cursor_game.?; ok {
		value_row(ctx, "cursor", fmt.tprintf("%.1f, %.1f m", c.x, c.y))
	}
	third := (UI_LEFT_W - 2 * ctx.style.padding - 2 * ctx.style.spacing - 12) / 3
	mu.layout_row(ctx, {third, third, -1})
	if .SUBMIT in mu.button(ctx, "Save") do ui_press(ui, .S, cmd = true)
	if .SUBMIT in mu.button(ctx, "Reload") do ui_press(ui, .R, cmd = true)
	if .SUBMIT in mu.button(ctx, "Export") do ui_press(ui, .E, cmd = true)

	if .ACTIVE in mu.treenode(ctx, "Levels") {
		since := time.duration_seconds(time.tick_since(ps.levels_at))
		if ps.levels == nil || since > LEVELS_RESCAN {
			for s in ps.levels do delete(s)
			delete(ps.levels)
			ps.levels = scene.list_levels(LEVELS_ROOT)
			ps.levels_at = time.tick_now()
		}
		mu.layout_row(ctx, {-1})
		if len(ps.levels) == 0 do coloured(ctx, "none in levels/", COL_DIM)
		for path in ps.levels {
			current := scene.same_path(path, lv.path)
			name := scene.level_id(path)
			label := fmt.tprintf("%s%s", name, "  (open)" if current else "")
			mu.push_id(ctx, path)
			if .SUBMIT in mu.button(ctx, label, opt = {}) && !current do ps.open_level = path
			mu.pop_id(ctx)
		}
		mu.end_treenode(ctx)
	}
}

panel_object :: proc(ctx: ^mu.Context, e: Ui_Env) {
	p := e.p
	ed := &p.ed
	n := len(ed.instances)
	if .ACTIVE not_in mu.header(ctx, "Objects", {.EXPANDED}) do return
	value_row(ctx, "objects", fmt.tprintf("%d", n))
	mu.layout_row(ctx, {-1})
	if len(e.model_err) > 0 do coloured(ctx, fmt.tprintf("model failed: %s", e.model_err), COL_BAD)
	if len(p.assets) == 0 {
		coloured(ctx, "no model: --model file.glb, or drop a .glb", COL_DIM)
		return
	}
	mode: string
	switch ed.mode {
	case .Place:
		a := asset_of(p, ed.preview)
		mode = fmt.tprintf("placing %s", short_path(a.path) if a != nil else "?")
	case .Move:   mode = fmt.tprintf("moving #%d", ed.selected)
	case .Select: mode = fmt.tprintf("#%d selected", ed.selected) if ed.selected != 0 else "nothing selected"
	}
	value_row(ctx, "mode", mode)
	if ed.mode == .Place && !p.cursor_ok do value_row(ctx, "", "cursor off the ground")
	if !p.visible do value_row(ctx, "", "objects hidden (V)")
	value_row(ctx, "history", fmt.tprintf("%d undo, %d redo", editor.can_undo(ed), editor.can_redo(ed)))

	act := editor.active(ed)
	a: ^Model_Asset
	if act != nil do a = asset_of(p, act^)
	if act == nil || a == nil do return
	t := act.transform
	sz := object_size_m(a^, t)
	value_row(ctx, "model", short_path(a.path))
	value_row(ctx, "size", fmt.tprintf("%.2f × %.2f × %.2f m", sz.x, sz.y, sz.z))
	value_row(ctx, "scale, yaw", fmt.tprintf("%.3f, %.0f°", t.scale.x, editor.wrap_yaw(t.rotation.y) * math.DEG_PER_RAD))
	if e.game_cam && e.grid.scale > 0 && e.view_height > 0 {
		density := e.win.y / (e.view_height * e.grid.scale) // art pixels per world unit
		long_px := max(sz.x, sz.z) * p.world_scale * density
		value_row(ctx, "on screen", fmt.tprintf("~%.0f art px long", long_px))
	}
	// position in metres from the world origin: shorter than world units
	m := t.position / max(p.world_scale, 1e-12)
	value_row(ctx, "position", fmt.tprintf("%.2f, %.2f, %.2f m", m.x, m.y, m.z))
	tilt := math.acos(clamp(act.transform.up.y, -1, 1)) * math.DEG_PER_RAD if act.align else 0
	value_row(ctx, "snap", fmt.tprintf("%v, offset %+.2f m", act.snap, act.offset / max(p.world_scale, 1e-12)))
	value_row(ctx, "align", fmt.tprintf("on, tilt %.1f°", tilt) if act.align else "off")
	if !act.on_terrain && act.snap != .Plane do value_row(ctx, "", "off the terrain: edge extended")
}

panel_terrain :: proc(ctx: ^mu.Context, ps: ^Panels, e: Ui_Env) {
	wt := e.wt
	if .ACTIVE not_in mu.header(ctx, "Terrain & map", {.EXPANDED}) do return
	mu.layout_row(ctx, {-1})
	if !wt.ok {
		coloured(ctx, "no terrain: objects stand on a plane", COL_WARN)
		return
	}
	t := wt.t
	s := t.stats
	n := t.w * t.h
	value_row(ctx, "grid", fmt.tprintf("%d × %d @ %.2f m", t.w, t.h, t.cell / wt.built_scale))
	value_row(ctx, "cells", fmt.tprintf("ground %.0f%%, struct. %.0f%%", pct(s.ground_cells, n), pct(s.structure_cells, n)))
	value_row(ctx, "", fmt.tprintf("empty %.0f%%, built in %.0f ms", pct(n - s.data_cells, n), wt.build_ms))
	if abs(e.p.world_scale / max(wt.built_scale, 1e-12) - 1) > 0.01 {
		mu.layout_row(ctx, {-1})
		coloured(ctx, "world scale changed: rebuild", COL_WARN)
	}

	// the view: Tab cycles it; here each one
	quarter := (UI_LEFT_W - 2 * ctx.style.padding - 3 * ctx.style.spacing - 12) / 4
	mu.layout_row(ctx, {quarter, quarter, quarter, -1})
	names := [Terrain_View]string{.Splats = "Splats", .Greybox = "Grey-box", .Both = "Both", .Map = "Map"}
	for v in Terrain_View {
		label := fmt.tprintf("[%s]", names[v]) if v == wt.view else names[v]
		if .SUBMIT in mu.button(ctx, label) do ps.want_view = v
	}
	mu.layout_row(ctx, {-1})
	if .SUBMIT in mu.button(ctx, "Rebuild terrain") do ps.rebuild = true

	wm := e.wm
	if wt.view != .Map do return
	if !wm.ok {
		coloured(ctx, "map not built", COL_WARN)
		return
	}
	ms := wm.stats
	sec := level_map_section(e.lv)
	value_row(ctx, "map", fmt.tprintf("%d × %d @ %.1f m", ms.w, ms.h, wm.m.cell))
	value_row(ctx, "yaw", fmt.tprintf("%.1f°%s", ms.yaw, "" if sec.yaw != nil else ", measured"))
	value_row(ctx, "features", fmt.tprintf("%d buildings, %d trees", ms.buildings, ms.trees))
	value_row(ctx, "", fmt.tprintf("%d walls, %d props", ms.walls, ms.props))
	value_row(ctx, "edits", fmt.tprintf("%d", wm.edits))
	if wm.problems > 0 {
		mu.layout_row(ctx, {-1})
		coloured(ctx, fmt.tprintf("%d edit%s not applied (console)", wm.problems, "" if wm.problems == 1 else "s"), COL_WARN)
	}
	mu.layout_row(ctx, {-1})
	coloured(ctx, fmt.tprintf("the cone: a guard at the cursor, %d m", int(CONE_RANGE)), COL_DIM)
}

// ---------------------------------------------------------------------------
// View
// ---------------------------------------------------------------------------

panel_look :: proc(ui: ^Ui, e: Ui_Env) {
	ctx := ui.ctx
	if .ACTIVE not_in mu.header(ctx, "Look", {.EXPANDED}) do return
	value_row(ctx, "capture", short_path(e.title))
	value_row(ctx, "splats", fmt.tprintf("%.2f M, %d fps", f32(e.splats) / 1e6, rl.GetFPS()))
	value_row(ctx, "art", fmt.tprintf("%d × %d, ss %d", e.grid.w, e.grid.h, e.cfg.ss))

	half := (UI_RIGHT_W - 2 * ctx.style.padding - ctx.style.spacing - 12) / 2
	mu.layout_row(ctx, {half, -1})
	if .SUBMIT in mu.button(ctx, "Game camera" if e.game_cam else "Free camera") do ui_press(ui, .C)
	if .SUBMIT in mu.button(ctx, fmt.tprintf("%v palette", e.palette)) do ui_press(ui, .P)

	cfg := e.cfg
	mu.layout_row(ctx, {half, -1})
	mu.checkbox(ctx, "palette", &cfg.quant)
	mu.checkbox(ctx, "hard splats", &cfg.crisp)
	mu.checkbox(ctx, "outline", &cfg.outline)
	ss2 := cfg.ss == 2
	if .CHANGE in mu.checkbox(ctx, "supersample", &ss2) do cfg.ss = 2 if ss2 else 1

	mu.layout_row(ctx, {UI_KEY_W, -1})
	mu.label(ctx, "dither")
	mu.slider(ctx, &cfg.dither, 0, 1, 0.5, "%.1f")
	if e.palette == .Commandos {
		mu.label(ctx, "grade")
		mu.slider(ctx, e.grade, 0, 1, 0.5, "%.1f")
	}
	mu.label(ctx, "alpha cut")
	mu.slider(ctx, e.crisp_alpha, 0.05, 0.95, 0.05, "%.2f")
}

panel_pixel :: proc(ui: ^Ui, e: Ui_Env) {
	ctx := ui.ctx
	if .ACTIVE not_in mu.header(ctx, "Pixel", {.EXPANDED}) do return
	px := e.px
	h := e.win.y
	ws := max(e.world_scale, 1e-9)
	value_row(ctx, "now", fmt.tprintf("%.0f m, %.2f px", e.view_height / ws, e.grid.scale))
	value_row(ctx, "zoomed out", fmt.tprintf("%.0f m, %.1f px", px.out.view, h / px.out.rows))
	value_row(ctx, "zoomed in", fmt.tprintf("%.0f m, %.1f px", px.in_.view, h / px.in_.rows))
	if e.lv.pixel == nil {
		mu.layout_row(ctx, {-1})
		coloured(ctx, "default ends: store one to keep it", COL_DIM)
	}

	half := (UI_RIGHT_W - 2 * ctx.style.padding - ctx.style.spacing - 12) / 2
	mu.layout_row(ctx, {-1})
	if .SUBMIT in mu.button(ctx, "Stop tuning (8)" if e.tune.on else "Tune (8)") do ui_press(ui, .EIGHT)
	if e.tune.on {
		mu.layout_row(ctx, {UI_KEY_W, -1})
		mu.label(ctx, "pixel size")
		lim := scene.PIXEL_ROWS_LIMITS
		mu.slider(ctx, &e.tune.scale, h / lim[1], min(h / lim[0], 24), 0.05, "%.2f px")
		mu.layout_row(ctx, {-1})
		coloured(ctx, "zoom past the ends; set the size, then store", COL_DIM)
	}
	mu.layout_row(ctx, {half, -1})
	if .SUBMIT in mu.button(ctx, "Zoom-out end (9)") do ui_press(ui, .NINE)
	if .SUBMIT in mu.button(ctx, "Zoom-in end (0)") do ui_press(ui, .ZERO)
}

KEYS_HELP := [?][2]string{
	{"ctrl+S / R / E", "save / reload / export"},
	{"drop a file", ".json level, .glb model, .spz capture"},
	{"F1", "hide the panels"},
	{"C", "game / free camera"},
	{"drag, arrows", "turn (game camera)"},
	{"shift+drag", "pan (or right drag)"},
	{"scroll", "zoom"},
	{"R", "reset the view"},
	{"Tab, shift+Z", "terrain view, rebuild"},
	{"Q X E S D", "palette, hard, outline, ss, dither"},
	{"P, G, [ ]", "palette, grade, alpha cut"},
	{"8, - =, 9, 0", "pixel tuning, size, ends"},
	{"A, click", "place"},
	{"click, W", "select, move"},
	{"Del, Esc", "delete, cancel"},
	{"I J K L", "nudge"},
	{"Y H", "offset up / down"},
	{", .", "rotate (shift: 90°)"},
	{"N M", "scale (ctrl: world scale)"},
	{"Z, U", "snap, align to slope"},
	{"T, O", "reset, next model"},
	{"B, V, F", "overlay, hide, print flags"},
	{"ctrl+Z, +shift", "undo, redo"},
}

panel_keys :: proc(ctx: ^mu.Context) {
	if .ACTIVE not_in mu.header(ctx, "Keys") do return
	for k in KEYS_HELP do value_row(ctx, k[0], k[1], key_width = 140)
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

// A label / value row: the label dim, the value bright.
value_row :: proc(ctx: ^mu.Context, label, value: string, key_width: i32 = UI_KEY_W) {
	mu.layout_row(ctx, {key_width, -1})
	coloured(ctx, label, COL_DIM)
	coloured(ctx, value, COL_VALUE)
}

coloured :: proc(ctx: ^mu.Context, text: string, col: mu.Color) {
	old := ctx.style.colors[.TEXT]
	ctx.style.colors[.TEXT] = col
	mu.label(ctx, text)
	ctx.style.colors[.TEXT] = old
}

// The last two parts of a path: enough to tell models apart.
short_path :: proc(path: string) -> string {
	slashes := 0
	for i := len(path) - 1; i >= 0; i -= 1 {
		if path[i] == '/' || path[i] == '\\' {
			slashes += 1
			if slashes == 2 do return path[i + 1:]
		}
	}
	return path
}
