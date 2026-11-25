package main

// Art grid and render targets. From pixlsplat/src/view.odin (Targets), with one
// change: view_art_size rounded to the nearest art pixel and the result was
// stretched over the window, so a few columns ended up a screen pixel wider than
// the rest. art_size rounds up and the caller draws the art at exactly
// `pixel` screen pixels per art pixel, cropping the last row/column instead.

import rl "vendor:raylib"

PIXEL_SIZE_DEFAULT :: 4
PIXEL_SIZE_MIN     :: 1
PIXEL_SIZE_MAX     :: 12

art_size :: proc(win_w, win_h, pixel: i32) -> (w, h: i32) {
	p := max(1, pixel)
	return max(1, (win_w + p - 1) / p), max(1, (win_h + p - 1) / p)
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
	rl.SetTextureFilter(t.art.texture, .POINT)
	t.w, t.h = w, h
}
