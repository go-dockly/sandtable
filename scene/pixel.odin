package scene

// The level's "pixel" section: how the game camera's pixel art looks at each
// zoom. Two ends, and the pixel size runs linearly between them:
//
//   "pixel": { "out": { "view": 120, "rows": 240 }, "in": { "view": 20, "rows": 120 } }
//
//   out   zoomed all the way out: `view` metres of the world fill the window
//         vertically, drawn with `rows` art pixels from top to bottom
//   in    zoomed all the way in, the same
//
// The zoom stops at the two views. In between, the size of an art pixel on
// screen (window height / rows) goes linearly from one end's to the other's,
// along the zoom as the wheel moves it (each step zooms by the same factor,
// so t is linear in log(view)). Rows rather than screen pixels, so a level
// looks the same in a bigger window, only sharper.
//
// Missing: the editor makes one from the capture's size (level_pixel). The
// mission export copies it, for the game's camera.

import "core:fmt"
import "core:math"
import "core:strings"

Pixel_End :: struct {
	view: f32 `json:"view"`, // metres in view, vertically
	rows: f32 `json:"rows"`, // art pixels across that height
}

Pixel :: struct {
	out: Pixel_End `json:"out"`,
	in_: Pixel_End `json:"in"`,
}

PIXEL_ROWS_LIMITS :: [2]f32{8, 4096}
PIXEL_ZOOM_MIN    :: f32(1.1) // out.view / in.view at least: some zoom

// A usable section: ends in order (out the wider view), rows within the
// limits, some zoom between them. false when a view or a row count is
// missing: drop the section.
fix_pixel :: proc(p: ^Pixel) -> bool {
	if !(p.out.view > 0 && p.in_.view > 0 && p.out.rows > 0 && p.in_.rows > 0) do return false
	if p.out.view < p.in_.view do p.out, p.in_ = p.in_, p.out
	p.out.view = max(p.out.view, p.in_.view * PIXEL_ZOOM_MIN)
	lim := PIXEL_ROWS_LIMITS
	p.out.rows = clamp(p.out.rows, lim[0], lim[1])
	p.in_.rows = clamp(p.in_.rows, lim[0], lim[1])
	return true
}

// Where view metres sit between the ends: 0 zoomed in, 1 zoomed out, in log
// zoom; clamped.
pixel_t :: proc(p: Pixel, view: f32) -> f32 {
	lo, hi := math.ln(max(p.in_.view, 1e-9)), math.ln(max(p.out.view, 1e-9))
	if hi - lo < 1e-9 do return 0
	return clamp((math.ln(max(view, 1e-9)) - lo) / (hi - lo), 0, 1)
}

// Art rows across the window at this view (metres): the pixel size (1 / rows
// of the window) linear between the ends.
pixel_rows :: proc(p: Pixel, view: f32) -> f32 {
	t := pixel_t(p, view)
	size := (1 - t) / p.in_.rows + t / p.out.rows
	return 1 / size
}

@(private)
check_pixel :: proc(l: ^Level, warn: ^[dynamic]string) {
	p, ok := &l.pixel.?
	if !ok do return
	before := p^
	if !fix_pixel(p) {
		append(warn, "pixel: an end without view or rows, section dropped")
		l.pixel = nil
		return
	}
	if p^ != before do append(warn, fmt.tprintf("pixel: repaired to %s", pixel_json(p^)))
}

@(private)
pixel_json :: proc(p: Pixel) -> string {
	return fmt.tprintf(`{{ "out": {{ "view": %s, "rows": %s }}, "in": {{ "view": %s, "rows": %s }} }}`,
		num(p.out.view), num(p.out.rows), num(p.in_.view), num(p.in_.rows))
}

@(private)
encode_pixel :: proc(b: ^strings.Builder, p: Pixel) {
	fmt.sbprintf(b, "  \"pixel\": %s,\n", pixel_json(p))
}
