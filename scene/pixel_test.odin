package scene

import "core:encoding/json"
import "core:strings"
import "core:testing"

LEVEL_WITH_PIXEL :: `{"format": "sandtable-level", "version": 1, "worldScale": 0.005,
  "pixel": {"metres": 0.08, "scaleMin": 3.5, "scaleMax": 5}, "assets": [], "objects": []}`

@(test)
pixel_round_trip :: proc(t: ^testing.T) {
	l, warn, err := decode(transmute([]byte)string(LEVEL_WITH_PIXEL), context.temp_allocator)
	testing.expect_value(t, err, Decode_Error.None)
	testing.expect_value(t, len(warn), 0)
	p, ok := l.pixel.?
	testing.expect(t, ok)
	testing.expect_value(t, p, Pixel{0.08, 3.5, 5})

	text := encode(l, context.temp_allocator)
	testing.expect(t, strings.contains(text, `"pixel": { "metres": 0.08, "scaleMin": 3.5, "scaleMax": 5 },`), text)
	back, _, berr := decode(transmute([]byte)text, context.temp_allocator)
	testing.expect_value(t, berr, Decode_Error.None)
	testing.expect_value(t, back.pixel, l.pixel)

	// no section: none written
	l.pixel = nil
	testing.expect(t, !strings.contains(encode(l, context.temp_allocator), "pixel"))
}

@(test)
pixel_repairs :: proc(t: ^testing.T) {
	p := Pixel{metres = 0.1}
	testing.expect(t, fix_pixel(&p))
	testing.expect_value(t, p, Pixel{0.1, PIXEL_SCALE_DEFAULT[0], PIXEL_SCALE_DEFAULT[1]})

	p = Pixel{0.1, 8, 3} // reversed
	testing.expect(t, fix_pixel(&p))
	testing.expect_value(t, p, Pixel{0.1, 3, 8})

	p = Pixel{0.1, 4, 4} // no band
	testing.expect(t, fix_pixel(&p))
	testing.expect(t, p.scale_max >= p.scale_min * PIXEL_BAND_MIN - 1e-6)

	p = Pixel{0.1, 0.2, 99} // out of the limits
	testing.expect(t, fix_pixel(&p))
	testing.expect_value(t, p, Pixel{0.1, PIXEL_SCALE_LIMITS[0], PIXEL_SCALE_LIMITS[1]})

	p = Pixel{0, 3, 6}
	testing.expect(t, !fix_pixel(&p))

	bad := `{"format": "sandtable-level", "version": 1, "worldScale": 1, "pixel": {"scaleMin": 3}, "assets": [], "objects": []}`
	l, warn, _ := decode(transmute([]byte)string(bad), context.temp_allocator)
	testing.expect(t, l.pixel == nil)
	testing.expect_value(t, len(warn), 1)
}

@(test)
pixel_goes_into_the_mission :: proc(t: ^testing.T) {
	base_text := `{"id": "m", "pixel": {"metres": 9}, "guards": []}`
	base, _ := parse_mission(transmute([]byte)string(base_text), context.temp_allocator)
	in_ := Export_Input{game = {size = {20, 20}}, world_scale = 1, base = base, id = "m", pixel = Pixel{0.1, 3, 6}}
	text, _ := export_mission(in_, context.temp_allocator)
	m: json.Value
	testing.expect(t, json.unmarshal_string(text, &m, allocator = context.temp_allocator) == nil, text)
	px := m.(json.Object)["pixel"].(json.Object)
	testing.expect_value(t, px["metres"].(json.Float), 0.1)
	testing.expect_value(t, px["scaleMax"].(json.Integer), 6) // written as "6"
	testing.expect_value(t, strings.count(text, `"pixel"`), 1) // the level's, not the base's too

	in_.pixel = nil // no section: the base's own stays
	text, _ = export_mission(in_, context.temp_allocator)
	testing.expect(t, strings.contains(text, `"pixel": {"metres":9}`), text)
}
