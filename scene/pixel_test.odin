package scene

import "core:encoding/json"
import "core:math"
import "core:strings"
import "core:testing"

LEVEL_WITH_PIXEL :: `{"format": "sandtable-level", "version": 1, "worldScale": 0.005,
  "pixel": {"out": {"view": 120, "rows": 240}, "in": {"view": 20, "rows": 120}}, "assets": [], "objects": []}`

@(test)
pixel_round_trip :: proc(t: ^testing.T) {
	l, warn, err := decode(transmute([]byte)string(LEVEL_WITH_PIXEL), context.temp_allocator)
	testing.expect_value(t, err, Decode_Error.None)
	testing.expect_value(t, len(warn), 0)
	p, ok := l.pixel.?
	testing.expect(t, ok)
	testing.expect_value(t, p, Pixel{out = {120, 240}, in_ = {20, 120}})

	text := encode(l, context.temp_allocator)
	testing.expect(t, strings.contains(text, `"pixel": { "out": { "view": 120, "rows": 240 }, "in": { "view": 20, "rows": 120 } },`), text)
	back, _, berr := decode(transmute([]byte)text, context.temp_allocator)
	testing.expect_value(t, berr, Decode_Error.None)
	testing.expect_value(t, back.pixel, l.pixel)

	l.pixel = nil
	testing.expect(t, !strings.contains(encode(l, context.temp_allocator), "pixel"))
}

// At each end its own rows; between, the pixel size (1 / rows) linear in log
// zoom; past the ends, the end's.
@(test)
pixel_interpolates :: proc(t: ^testing.T) {
	p := Pixel{out = {120, 240}, in_ = {20, 120}}
	near :: proc(a, b: f32) -> bool {return abs(a - b) < 1e-3 * max(abs(b), 1)}
	testing.expect(t, near(pixel_rows(p, 20), 120))
	testing.expect(t, near(pixel_rows(p, 120), 240))
	testing.expect(t, near(pixel_rows(p, 5), 120))
	testing.expect(t, near(pixel_rows(p, 500), 240))
	mid := math.sqrt(f32(20 * 120)) // halfway in log zoom
	testing.expect(t, near(pixel_t(p, mid), 0.5))
	testing.expectf(t, near(1 / pixel_rows(p, mid), 0.5 / 120 + 0.5 / 240), "rows %v", pixel_rows(p, mid))
	// monotonic: zooming out never makes pixels bigger here (rows grow)
	last := f32(0)
	for v := f32(20); v <= 120; v *= 1.05 {
		r := pixel_rows(p, v)
		testing.expect(t, r >= last - 1e-3)
		last = r
	}
}

@(test)
pixel_repairs :: proc(t: ^testing.T) {
	p := Pixel{out = {20, 120}, in_ = {120, 240}} // ends swapped
	testing.expect(t, fix_pixel(&p))
	testing.expect_value(t, p, Pixel{out = {120, 240}, in_ = {20, 120}})

	p = Pixel{out = {50, 200}, in_ = {50, 100}} // no zoom
	testing.expect(t, fix_pixel(&p))
	testing.expect(t, p.out.view >= p.in_.view * PIXEL_ZOOM_MIN - 1e-4)

	p = Pixel{out = {120, 1e6}, in_ = {20, 1}} // rows out of the limits
	testing.expect(t, fix_pixel(&p))
	testing.expect_value(t, p.out.rows, PIXEL_ROWS_LIMITS[1])
	testing.expect_value(t, p.in_.rows, PIXEL_ROWS_LIMITS[0])

	p = Pixel{out = {120, 240}}
	testing.expect(t, !fix_pixel(&p))

	bad := `{"format": "sandtable-level", "version": 1, "worldScale": 1, "pixel": {"out": {"view": 100, "rows": 200}}, "assets": [], "objects": []}`
	l, warn, _ := decode(transmute([]byte)string(bad), context.temp_allocator)
	testing.expect(t, l.pixel == nil)
	testing.expect_value(t, len(warn), 1)
}

@(test)
pixel_goes_into_the_mission :: proc(t: ^testing.T) {
	base_text := `{"id": "m", "pixel": {"old": 1}, "guards": []}`
	base, _ := parse_mission(transmute([]byte)string(base_text), context.temp_allocator)
	in_ := Export_Input{game = {size = {20, 20}}, world_scale = 1, base = base, id = "m", pixel = Pixel{out = {120, 240}, in_ = {20, 120}}}
	text, _ := export_mission(in_, context.temp_allocator)
	m: json.Value
	testing.expect(t, json.unmarshal_string(text, &m, allocator = context.temp_allocator) == nil, text)
	px := m.(json.Object)["pixel"].(json.Object)
	testing.expect_value(t, px["in"].(json.Object)["view"].(json.Integer), 20)
	testing.expect_value(t, px["out"].(json.Object)["rows"].(json.Integer), 240)
	testing.expect_value(t, strings.count(text, `"pixel"`), 1) // the level's, not the base's too

	in_.pixel = nil // no section: the base's own stays
	text, _ = export_mission(in_, context.temp_allocator)
	testing.expect(t, strings.contains(text, `"pixel": {"old":1}`), text)
}
