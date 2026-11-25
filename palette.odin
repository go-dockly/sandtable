package main

// Palettes for the post pass.
//
//   .Extracted  k-means over the cloud's own colours. Port of extract_palette
//               from pixlsplat/src/palette.odin, minus the lighting-level
//               expansion: a capture's colours are already lit, nothing is
//               re-shaded here.
//   .Commandos  a fixed colour script (greys, olive, khaki, brick, slate, one warm
//               accent). This is a first guess to tune by eye on a real cloud, not
//               a sample of the original game.
//
// The background is always entry 0, so solid pixels never snap to it
// (see nearest() in post.odin).

import "core:slice"

PALETTE_COLOURS :: 31 // + background = 32 entries; MAX_COLOURS in post.odin is 64

Palette_Mode :: enum {
	Extracted,
	Commandos,
}

COMMANDOS_PALETTE :: [?][4]u8{
	// greys: concrete, stone, steel
	{0x1b, 0x1d, 0x1f, 255}, {0x2e, 0x31, 0x33, 255}, {0x47, 0x4b, 0x4d, 255},
	{0x65, 0x69, 0x6a, 255}, {0x8a, 0x8d, 0x8b, 255}, {0xb3, 0xb4, 0xad, 255},
	{0xd6, 0xd4, 0xc8, 255},
	// olive and muted greens: uniforms, foliage
	{0x2b, 0x33, 0x20, 255}, {0x3e, 0x4a, 0x2c, 255}, {0x56, 0x63, 0x39, 255},
	{0x74, 0x81, 0x4a, 255}, {0x96, 0xa0, 0x63, 255},
	// khaki and earth: dirt, sand, timber
	{0x5a, 0x4a, 0x32, 255}, {0x7b, 0x66, 0x43, 255}, {0xa0, 0x8a, 0x5b, 255},
	{0xc4, 0xb0, 0x78, 255},
	// brick and rust: roofs, walls
	{0x4a, 0x26, 0x20, 255}, {0x70, 0x2f, 0x26, 255}, {0x96, 0x43, 0x2f, 255},
	{0xb8, 0x61, 0x3f, 255},
	// slate: shadow, water, sky
	{0x2c, 0x38, 0x44, 255}, {0x4a, 0x5b, 0x69, 255}, {0x7a, 0x8a, 0x94, 255},
	// warm accent: windows, fire, lanterns
	{0xd9, 0x8c, 0x3a, 255}, {0xf0, 0xc0, 0x60, 255},
}

to_u8 :: proc(x: f32) -> u8 {
	return u8(clamp(x, 0, 1) * 255 + 0.5)
}

// colors: DC colour of every splat · k: palette size
extract_palette :: proc(colors: [][4]u8, k: int) -> [dynamic][4]u8 {
	out := make([dynamic][4]u8)
	count := len(colors)
	if count == 0 || k <= 0 do return out

	step := max(1, count / 9000)
	samples := make([dynamic][3]f32, 0, count / step + 1)
	defer delete(samples)
	for i := 0; i < count; i += step {
		c := colors[i]
		append(&samples, [3]f32{f32(c[0]) / 255, f32(c[1]) / 255, f32(c[2]) / 255})
	}
	if len(samples) == 0 do return out

	// start the centres evenly along brightness, then 10 rounds of k-means
	slice.sort_by(samples[:], proc(a, b: [3]f32) -> bool {
		return a[0] + a[1] * 2 + a[2] < b[0] + b[1] * 2 + b[2]
	})

	n := len(samples)
	centres := make([][3]f32, k)
	defer delete(centres)
	for i in 0 ..< k {
		centres[i] = samples[min(n - 1, int((f32(i) + 0.5) / f32(k) * f32(n)))]
	}

	sums := make([][3]f32, k)
	counts := make([]int, k)
	defer delete(sums)
	defer delete(counts)
	for _ in 0 ..< 10 {
		for i in 0 ..< k {
			sums[i] = {}
			counts[i] = 0
		}
		for s in samples {
			best := 0
			best_d: f32 = 1e9
			for c, ci in centres {
				dx, dy, dz := s[0] - c[0], s[1] - c[1], s[2] - c[2]
				d := dx * dx + dy * dy + dz * dz
				if d < best_d {
					best_d = d
					best = ci
				}
			}
			sums[best] += s
			counts[best] += 1
		}
		for i in 0 ..< k {
			if counts[i] > 0 do centres[i] = sums[i] / f32(counts[i])
		}
	}

	for c in centres {
		append(&out, [4]u8{to_u8(c[0]), to_u8(c[1]), to_u8(c[2]), 255})
	}
	return out
}

// Background first, then the colours for solid surfaces.
build_palette :: proc(mode: Palette_Mode, colors: [][4]u8, background: [4]u8) -> [dynamic][4]u8 {
	pal := make([dynamic][4]u8)
	append(&pal, background)
	switch mode {
	case .Extracted:
		ex := extract_palette(colors, PALETTE_COLOURS)
		defer delete(ex)
		for c in ex do append(&pal, c)
	case .Commandos:
		script := COMMANDOS_PALETTE
		for c in script do append(&pal, c)
	}
	return pal
}
