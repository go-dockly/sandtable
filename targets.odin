package main

// Art grid and render targets. From pixlsplat/src/view.odin (Targets).
//
// The game camera keeps a fixed number of art pixels per world unit
// (artgrid/): the wheel zooms smoothly and an art pixel covers a fraction of
// screen pixels, within the level's band (its "pixel" section, scene/pixel.odin;
// tuned with the keys in pixel_keys). The art is drawn with UPSCALE_FS so every
// art pixel is the same size on screen at any fraction. The free camera keeps
// whole PIXEL_SIZE_FREE pixels.

import rl "vendor:raylib"

import "scene"

PIXEL_SIZE_FREE :: 4 // screen pixels per art pixel, free camera
// Without a "pixel" section, framing a capture shows it at 4 screen pixels
// per art pixel in a window FRAMED_ROWS * 4 tall (720), in the default band.
FRAMED_ROWS     :: f32(180)
PIXEL_STEP      :: f32(1.1) // - / = change the art pixel's size by this factor

// The level's pixel section, or the one framing implies.
level_pixel :: proc(lv: ^Level_State, iso: Iso, world_scale: f32) -> scene.Pixel {
	if p, ok := lv.pixel.?; ok do return p
	d := max(iso.px_per_unit * world_scale, 1e-9) // art pixels per metre
	return scene.Pixel{metres = 1 / d, scale_min = scene.PIXEL_SCALE_DEFAULT[0], scale_max = scene.PIXEL_SCALE_DEFAULT[1]}
}

// Tuning the look by eye, game camera:
//   -  =     art pixels a size coarser / finer (the art's detail)
//   alt+scroll  zoom past the band, to find where it stops looking right
//   9        the zoom-out end of the band here (the finest on screen)
//   0        the zoom-in end here (the chunkiest)
// Each writes the level's pixel section; ctrl+S saves it. scale: the current
// screen pixels per art pixel.
pixel_keys :: proc(lv: ^Level_State, iso: Iso, world_scale, scale: f32) {
	p := level_pixel(lv, iso, world_scale)
	changed := true
	switch {
	case rl.IsKeyPressed(.MINUS) || rl.IsKeyPressed(.KP_SUBTRACT):
		p.metres *= PIXEL_STEP
	case rl.IsKeyPressed(.EQUAL) || rl.IsKeyPressed(.KP_ADD):
		p.metres /= PIXEL_STEP
	case rl.IsKeyPressed(.NINE):
		p.scale_min = scale
	case rl.IsKeyPressed(.ZERO):
		p.scale_max = scale
	case:
		changed = false
	}
	if !changed do return
	if p.scale_min > p.scale_max do p.scale_min, p.scale_max = p.scale_max, p.scale_min
	scene.fix_pixel(&p)
	lv.pixel = p
	level_say(lv, false, "pixel %.1f cm, zoom %.2fx..%.2fx (ctrl+S saves)", p.metres * 100, p.scale_min, p.scale_max)
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
