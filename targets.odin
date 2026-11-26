package main

// Art grid and render targets. From pixlsplat/src/view.odin (Targets).
//
// The game camera keeps a fixed number of art pixels per world unit
// (artgrid/): the wheel zooms smoothly and an art pixel covers a fraction of
// screen pixels, its size running between the level's two ends (its "pixel"
// section, scene/pixel.odin; tuned with the keys in pixel_keys). The art is drawn with UPSCALE_FS so every
// art pixel is the same size on screen at any fraction. The free camera keeps
// whole PIXEL_SIZE_FREE pixels.

import rl "vendor:raylib"

import "scene"

PIXEL_SIZE_FREE :: 4 // screen pixels per art pixel, free camera

// Without a pixel section: zoomed out to 1.5x the framed view at 240 rows,
// in to a quarter of it at 120 (3 and 6 screen pixels per art pixel in a
// 720-row window).
DEFAULT_OUT :: scene.Pixel_End{view = 1.5, rows = 240}
DEFAULT_IN  :: scene.Pixel_End{view = 0.25, rows = 120}
PIXEL_STEP  :: f32(1.1) // - / = while tuning
TUNE_REACH  :: f32(8)   // while tuning, the zoom goes this far past either end

// The level's pixel section, or the one framing implies.
level_pixel :: proc(lv: ^Level_State, iso: Iso, world_scale: f32) -> scene.Pixel {
	if p, ok := lv.pixel.?; ok do return p
	v := iso.framed_height / max(world_scale, 1e-9) // metres
	return scene.Pixel{
		out = {view = v * DEFAULT_OUT.view, rows = DEFAULT_OUT.rows},
		in_ = {view = v * DEFAULT_IN.view, rows = DEFAULT_IN.rows},
	}
}

// Tuning: the zoom goes past the ends and the pixel size holds still, set by
// hand, until it is stored as an end.
Pixel_Tune :: struct {
	on:    bool,
	scale: f32, // screen pixels per art pixel
}

// Game camera:
//   8      tuning on / off
//   - =    (tuning) art pixels smaller / bigger on screen
//   9      the zoom-out end: this view, this pixel size
//   0      the zoom-in end: this view, this pixel size
// 9 and 0 write the level's pixel section; ctrl+S saves it. scale: the
// current screen pixels per art pixel.
pixel_keys :: proc(lv: ^Level_State, tune: ^Pixel_Tune, iso: Iso, world_scale, win_h, scale: f32) {
	if rl.IsKeyPressed(.EIGHT) {
		tune.on = !tune.on
		tune.scale = scale
		level_say(lv, false, "pixel tuning %s", "on: zoom anywhere, -/= pixel size, 9 / 0 store an end" if tune.on else "off")
	}
	if tune.on {
		if rl.IsKeyPressed(.MINUS) || rl.IsKeyPressed(.KP_SUBTRACT) do tune.scale /= PIXEL_STEP
		if rl.IsKeyPressed(.EQUAL) || rl.IsKeyPressed(.KP_ADD) do tune.scale *= PIXEL_STEP
		lim := scene.PIXEL_ROWS_LIMITS
		tune.scale = clamp(tune.scale, win_h / lim[1], win_h / lim[0])
	}
	nine, zero := rl.IsKeyPressed(.NINE), rl.IsKeyPressed(.ZERO)
	if !nine && !zero do return
	p := level_pixel(lv, iso, world_scale)
	end := scene.Pixel_End{view = iso.view_height / max(world_scale, 1e-9), rows = win_h / max(scale, 1e-6)}
	if nine do p.out = end
	else do p.in_ = end
	if !scene.fix_pixel(&p) do return
	lv.pixel = p
	level_say(lv, false, "pixel: out %.0f m at %.1fx, in %.0f m at %.1fx (ctrl+S saves)",
		p.out.view, win_h / p.out.rows, p.in_.view, win_h / p.in_.rows)
}

// Draws the art at a fractional scale with every art pixel the same size:
// nearest inside a pixel, a one-screen-pixel blend across its edges (the
// texture is filtered bilinear for that). At a whole scale it is nearest.
UPSCALE_FS :: `#version 330
in vec2 fragTexCoord;
in vec4 fragColor;
uniform sampler2D texture0;
uniform vec4 colDiffuse;
uniform vec2 texSize;
out vec4 finalColor;
void main() {
	vec2 pix = fragTexCoord * texSize;
	vec2 seam = floor(pix + 0.5);
	vec2 per_screen = max(fwidth(pix), vec2(1e-5)); // texels per screen pixel
	pix = seam + clamp((pix - seam) / per_screen, -0.5, 0.5);
	finalColor = texture(texture0, pix / texSize) * colDiffuse * fragColor;
}
`

Upscale :: struct {
	shader:   rl.Shader,
	loc_size: i32,
}

upscale_init :: proc(u: ^Upscale) {
	u.shader = rl.LoadShaderFromMemory(nil, UPSCALE_FS)
	u.loc_size = rl.GetShaderLocation(u.shader, "texSize")
}

upscale_destroy :: proc(u: ^Upscale) {
	rl.UnloadShader(u.shader)
}

// The art target at dst (screen pixels), right side up.
upscale_draw :: proc(u: ^Upscale, art: rl.Texture2D, w, h: i32, dst: rl.Rectangle) {
	size := [2]f32{f32(w), f32(h)}
	rl.BeginShaderMode(u.shader)
	rl.SetShaderValue(u.shader, u.loc_size, &size[0], .VEC2)
	src := rl.Rectangle{0, 0, f32(w), -f32(h)} // render textures are upside down
	rl.DrawTexturePro(art, src, dst, {0, 0}, 0, rl.WHITE)
	rl.EndShaderMode()
}

// scene: the splat pass at 1x and 2x the art resolution (index = ss, [0] unused)
// art:   the art-resolution target the post pass resolves into
Targets :: struct {
	scene: [3]rl.RenderTexture2D,
	art:   rl.RenderTexture2D,
	w, h:  i32,
}

targets_destroy :: proc(t: ^Targets) {
	if t.w == 0 do return
	for k in 1 ..= 2 do rl.UnloadRenderTexture(t.scene[k])
	rl.UnloadRenderTexture(t.art)
	t.w, t.h = 0, 0
}

targets_resize :: proc(t: ^Targets, w, h: i32) {
	if t.w == w && t.h == h do return
	targets_destroy(t)
	for k in 1 ..= 2 {
		t.scene[k] = rl.LoadRenderTexture(w * i32(k), h * i32(k))
		rl.SetTextureFilter(t.scene[k].texture, .POINT)
	}
	t.art = rl.LoadRenderTexture(w, h)
	rl.SetTextureFilter(t.art.texture, .BILINEAR) // for UPSCALE_FS
	t.w, t.h = w, h
}
