package scene

// The level's "pixel" section: how the game camera's pixel art looks.
//
//   "pixel": { "metres": 0.1, "scaleMin": 3, "scaleMax": 6 }
//
//   metres    metres of the world per art pixel, at every zoom: the art's
//             detail. Smaller is finer.
//   scaleMin  screen pixels per art pixel zoomed all the way out (the
//             finest the art gets on screen)
//   scaleMax  and zoomed all the way in (the chunkiest)
//
// The band is the zoom: from window height / (scaleMax * px per metre) to
// window height / (scaleMin * px per metre) metres in view. Missing: the editor
// picks one from the capture's size and PIXEL_SCALE_DEFAULT. The mission
// export copies it, for the game's camera.

import "core:fmt"
import "core:strings"

Pixel :: struct {
	metres:    f32 `json:"metres"`,
	scale_min: f32 `json:"scaleMin"`,
	scale_max: f32 `json:"scaleMax"`,
}

PIXEL_SCALE_DEFAULT :: [2]f32{3, 6}
PIXEL_SCALE_LIMITS  :: [2]f32{1, 24} // what a level may ask for
PIXEL_BAND_MIN      :: f32(1.1)      // scaleMax / scaleMin at least: some zoom

// A usable section: missing scales take the default, scales go into the
// limits and in order, the band is at least PIXEL_BAND_MIN wide. false when
// there is no usable size (metres <= 0): drop the section.
fix_pixel :: proc(p: ^Pixel) -> bool {
	if !(p.metres > 0) do return false
	lim := PIXEL_SCALE_LIMITS
	if !(p.scale_min > 0) do p.scale_min = PIXEL_SCALE_DEFAULT[0]
	if !(p.scale_max > 0) do p.scale_max = PIXEL_SCALE_DEFAULT[1]
	if p.scale_min > p.scale_max do p.scale_min, p.scale_max = p.scale_max, p.scale_min
	p.scale_min = clamp(p.scale_min, lim[0], lim[1] / PIXEL_BAND_MIN)
	p.scale_max = clamp(p.scale_max, p.scale_min * PIXEL_BAND_MIN, lim[1])
	return true
}

@(private)
check_pixel :: proc(l: ^Level, warn: ^[dynamic]string) {
	p, ok := &l.pixel.?
	if !ok do return
	before := p^
	if !fix_pixel(p) {
		append(warn, "pixel: metres missing or not above 0, section dropped")
		l.pixel = nil
		return
	}
	if p^ != before {
		append(warn, fmt.tprintf("pixel: scales %v..%v, now %v..%v", before.scale_min, before.scale_max, p.scale_min, p.scale_max))
	}
}

@(private)
pixel_json :: proc(p: Pixel) -> string {
	return fmt.tprintf(`{{ "metres": %s, "scaleMin": %s, "scaleMax": %s }}`, num(p.metres), num(p.scale_min), num(p.scale_max))
}

@(private)
encode_pixel :: proc(b: ^strings.Builder, p: Pixel) {
	fmt.sbprintf(b, "  \"pixel\": %s,\n", pixel_json(p))
}
