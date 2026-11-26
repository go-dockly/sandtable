package artgrid

// The art grid of the game camera: a fixed number of art pixels per world
// unit, whatever the zoom. Zooming changes how many screen pixels an art pixel
// covers (a fraction, e.g. 4.37), not what is rendered, so the picture keeps
// its detail per metre: zoomed out it gets finer on screen, zoomed in
// chunkier.
//
// Two things keep it from shimmering:
//
//   - the camera renders from its target snapped to the art grid in the view
//     plane, so a pan moves the world across the grid only in whole art
//     pixels (no re-sampling, no crawling dither); the remainder moves the
//     finished picture on screen, in screen pixels, so the pan stays smooth
//   - the picture is drawn with an even-pixel upscale (every art pixel the
//     same size on screen; see the main package's UPSCALE_FS), not nearest
//     neighbour, which at 4.37x makes columns 4 and 5 pixels wide
//
// The render target is the window plus a pixel each side, rounded up to
// BUCKET art pixels, so a smooth zoom resizes it every few steps rather than
// every frame. Its sizes are even, so texel corners sit on the grid.
//
// Turning the camera changes the view plane, so a turn still re-samples.
//
// No raylib in here: odin test artgrid.

import "core:math"

BUCKET :: 16

Grid :: struct {
	scale:   f32,    // screen pixels per art pixel
	w, h:    i32,    // render target, art pixels
	snapped: [3]f32, // the camera target to render from
	origin:  [2]f32, // screen position of the target's top-left corner
	size:    [2]f32, // and its size on screen: w, h * scale
}

// win: window size, screen pixels. density: art pixels per world unit.
// view_height: world units the window shows vertically (the zoom).
// right, up: the camera's view-plane axes (unit, orthogonal).
game :: proc(win: [2]f32, density, view_height: f32, target, right, up: [3]f32) -> (g: Grid) {
	g.scale = win.y / max(view_height * density, 1e-6)
	need := [2]f32{win.x / g.scale + 2, win.y / g.scale + 2}
	g.w = bucket(need.x)
	g.h = bucket(need.y)

	// the target in art pixels along the view plane, and on the grid
	r := dot(target, right) * density
	u := dot(target, up) * density
	rs := math.round(r)
	us := math.round(u)
	g.snapped = target + right * ((rs - r) / density) + up * ((us - u) / density)

	// A point at view-plane art coordinate p shows at
	//   x = (p.r - r) * scale + win.x / 2,  y = -(p.u - u) * scale + win.y / 2
	// The target puts it at (p.r - rs) * scale + w * scale / 2 from its left
	// edge: so the left edge goes at win.x/2 - w*scale/2 - (r - rs)*scale,
	// and the top at win.y/2 - h*scale/2 + (u - us)*scale.
	g.size = {f32(g.w) * g.scale, f32(g.h) * g.scale}
	g.origin = {
		win.x * 0.5 - g.size.x * 0.5 - (r - rs) * g.scale,
		win.y * 0.5 - g.size.y * 0.5 + (u - us) * g.scale,
	}
	return
}

// A whole number of screen pixels per art pixel, the picture at the window's
// corner, no snapping: the free camera.
fixed :: proc(win: [2]i32, pixel: i32, target: [3]f32) -> (g: Grid) {
	p := max(pixel, 1)
	g.scale = f32(p)
	g.w = max(1, (win.x + p - 1) / p)
	g.h = max(1, (win.y + p - 1) / p)
	g.snapped = target
	g.size = {f32(g.w * p), f32(g.h * p)}
	return
}

// The view heights a window allows at this density, for scales from
// scale_min (zoomed out) to scale_max (zoomed in).
view_range :: proc(win_h, density, scale_min, scale_max: f32) -> (lo, hi: f32) {
	d := max(density, 1e-6)
	return win_h / (scale_max * d), win_h / (scale_min * d)
}

bucket :: proc(need: f32) -> i32 {
	n := i32(math.ceil(need))
	return max(BUCKET, (n + BUCKET - 1) / BUCKET * BUCKET)
}

dot :: #force_inline proc(a, b: [3]f32) -> f32 {
	return a.x * b.x + a.y * b.y + a.z * b.z
}
