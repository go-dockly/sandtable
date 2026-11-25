package main

// Pixel-art post pass: a GPU port of src/render/post.js from
// https://github.com/cobanov/pixelart-gaussiansplat
//
// The scene is rendered at `ss` times the art resolution into an RGBA target
// with premultiplied alpha (transparent where nothing was drawn). This pass
// is one fragment shader that resolves it into pixel art:
//
//   1. Supersample: each art pixel reads 2x2 source texels (ss = 2).
//   2. Coverage: a texel is solid at alpha >= 0.95; an art pixel belongs to
//      the object when at least 2 of its 4 texels are solid.
//   3. Palette vote: every solid texel snaps to its nearest palette colour and
//      the pixel takes the majority. Solid pixels never take the background.
//   4. Outline ("ink"): solid pixels with 1-3 solid neighbours take a darker
//      shade of their own colour. The screen edge is not an outline.
//   5. Haze: translucent light over the background is blended and matched in
//      OKLab with a hue penalty; below 30% opacity it is dropped.
//
// With dither > 0 colours are averaged and dithered between the two nearest
// palette colours (Bayer). With crisp off, splats are soft Gaussians that were
// blended in the scene pass and the result is simply snapped to the palette.

import rl "vendor:raylib"

MAX_COLOURS :: 64

Post_Settings :: struct {
    quant:   bool,   // snap to the palette
    crisp:   bool,   // hard-edged splats; off = soft Gaussians
    outline: bool,   // darker ink on silhouette pixels
    ss:      i32,    // 1 or 2 source texels per art pixel, per side
    dither:  f32,    // 0 = off
    grade:   f32,    // Commandos colour grade strength, 0 = off
}

Post :: struct {
    shader: rl.Shader,
    loc_low_res, loc_ss, loc_outline, loc_quantise, loc_dither, loc_crisp: i32,
    loc_palette, loc_palette_size, loc_surface_size, loc_background:       i32,
    loc_grade:                                                             i32,
}

POST_FS :: `#version 330
in vec2 fragTexCoord;
in vec4 fragColor;
uniform sampler2D texture0;     // supersampled splat render, premultiplied alpha
uniform vec2 lowRes;            // art pixels
uniform float ss;               // source texels per art pixel, per side (1 or 2)
uniform float outline;
uniform float quantise;
uniform float dither;
uniform float crisp;
uniform float grade;            // Commandos colour grade strength, 0 = off
uniform vec3 palette[64];
uniform int paletteSize;
uniform int surfaceSize;        // entries before this may colour surfaces; the rest only translucent light
uniform vec3 background;
out vec4 finalColor;

const float SOLID_ALPHA = 0.95;

const float BAYER[16] = float[16](
    0., 8., 2., 10.,
    12., 4., 14., 6.,
    3., 11., 1., 9.,
    15., 7., 13., 5.);

// 4x4 ordered dither threshold in (0, 1)
float bayer(vec2 p) {
    int i = int(mod(p.x, 4.0)) + int(mod(p.y, 4.0)) * 4;
    return (BAYER[i] + 0.5) / 16.0;
}

// Commandos grade: muted, cool shadows, warm highlights, olive-khaki mid-tones
vec3 gradeCol(vec3 c) {
    float l = dot(c, vec3(0.30, 0.59, 0.11));
    vec3 x = l + (c - l) * 0.55;
    x *= mix(vec3(0.90, 0.97, 1.08), vec3(1.08, 1.00, 0.84), smoothstep(0.15, 0.75, l));
    float m = clamp(1.0 - abs(l - 0.45) * 2.5, 0.0, 1.0);
    x = mix(x, x * vec3(1.0, 1.05, 0.78), m * 0.35);
    x = (x - 0.5) * 1.1 + 0.5;
    return mix(c, clamp(x, 0.0, 1.0), grade);
}

// one source texel, premultiplied. The scene target already holds display-space colours.
// Every read goes through here, so the grade reaches the vote, ink, dither and haze alike.
vec4 texel(vec2 t) {
    vec4 s = texelFetch(texture0, ivec2(t), 0);
    if (grade > 0.0 && s.a > 1e-4) s.rgb = gradeCol(s.rgb / s.a) * s.a;
    return s;
}

// share of an art pixel's samples covered by something opaque
float coverage(vec2 cell) {
    if (cell.x < 0.0 || cell.y < 0.0 || cell.x >= lowRes.x || cell.y >= lowRes.y) return 1.0; // the screen edge is not an outline
    if (ss < 1.5) return step(SOLID_ALPHA, texel(cell).a);
    vec2 t = cell * 2.0;
    return 0.25 * (step(SOLID_ALPHA, texel(t).a) + step(SOLID_ALPHA, texel(t + vec2(1.0, 0.0)).a)
                 + step(SOLID_ALPHA, texel(t + vec2(0.0, 1.0)).a) + step(SOLID_ALPHA, texel(t + vec2(1.0, 1.0)).a));
}

// nearest palette entry; solid pixels never take the background colour
int nearest(vec3 c, bool solid) {
    int best = 0; float bd = 1e9;
    for (int i = 0; i < 64; i++) {
        if (i >= surfaceSize) break;
        if (solid && paletteSize > 1 && distance(palette[i], background) < 0.004) continue;
        vec3 e = c - palette[i];
        vec3 w = e * vec3(0.30, 0.59, 0.11); // weigh by how bright each channel looks
        float d = dot(w, w) + 0.25 * dot(e, e);
        if (d < bd) { bd = d; best = i; }
    }
    return best;
}

// translucent light over the background: the palette colour nearest the
// blend in OKLab, kept in the light's own hue
vec3 oklab(vec3 c) {
    c = pow(max(c, 0.0), vec3(2.2));
    vec3 lms = pow(vec3(0.4122214708 * c.r + 0.5363325363 * c.g + 0.0514459929 * c.b,
                        0.2119034982 * c.r + 0.6806995451 * c.g + 0.1073969566 * c.b,
                        0.0883024619 * c.r + 0.2817188376 * c.g + 0.6299787005 * c.b) + 1e-9, vec3(1.0 / 3.0));
    return vec3(0.2104542553 * lms.x + 0.793617785 * lms.y - 0.0040720468 * lms.z,
                1.9779984951 * lms.x - 2.428592205 * lms.y + 0.4505937099 * lms.z,
                0.0259040371 * lms.x + 0.7827717662 * lms.y - 0.808675766 * lms.z);
}
vec2 hueDir(vec3 lab) { return lab.yz / (length(lab.yz) + 0.035); }
vec3 haze(vec3 light, float a) {
    if (a < 0.3) return background;
    vec3 t = oklab(mix(background, light, min(1.0, a * 1.6)));
    vec2 h = hueDir(oklab(light));
    vec3 best = background; float bd = 1e9;
    for (int i = 0; i < 64; i++) {
        if (i >= paletteSize) break;
        vec3 p = oklab(palette[i]), e = t - p;
        vec2 dh = hueDir(p) - h;
        bool bg = distance(palette[i], background) < 0.004;
        float d = 1.4 * e.x * e.x + dot(e.yz, e.yz) + (bg ? 0.0 : 0.12 * dot(dh, dh));
        if (d < bd) { bd = d; best = palette[i]; }
    }
    return best;
}

vec3 snapDither(vec3 col, vec2 cell, bool solid) {
    vec3 c1 = col, c2 = col; float d1 = 1e9, d2 = 1e9;
    for (int i = 0; i < 64; i++) {
        if (i >= surfaceSize) break;
        if (solid && paletteSize > 1 && distance(palette[i], background) < 0.004) continue;
        vec3 e = col - palette[i];
        vec3 w = e * vec3(0.30, 0.59, 0.11);
        float d = dot(w, w) + 0.25 * dot(e, e);
        if (d < d1) { d2 = d1; c2 = c1; d1 = d; c1 = palette[i]; }
        else if (d < d2) { d2 = d; c2 = palette[i]; }
    }
    vec3 axis = c2 - c1;
    float t = clamp(dot(col - c1, axis) / max(dot(axis, axis), 1e-5), 0.0, 0.5);
    return bayer(cell) < t * dither ? c2 : c1;
}

// a darker shade of a colour, never so dark that it vanishes into the background
vec3 ink(vec3 body) {
    vec3 tone = body * 0.64;
    tone = min(vec3(1.0), tone * max(1.0, 0.12 / max(dot(tone, vec3(0.30, 0.55, 0.15)), 0.001)));
    return mix(body, tone, 0.65);
}

void main() {
    vec2 cell = floor(gl_FragCoord.xy); // which art pixel (this pass renders 1:1 into the art target)
    int N = ss < 1.5 ? 1 : 4;
    vec4 smp[4];
    vec4 sum = vec4(0.0), solidSum = vec4(0.0);
    for (int i = 0; i < 4; i++) {
        if (i >= N) break;
        smp[i] = texel(N == 1 ? cell : cell * 2.0 + vec2(float(i - (i / 2) * 2), float(i / 2)));
        sum += smp[i];
        if (smp[i].a > SOLID_ALPHA) solidSum += vec4(smp[i].rgb / smp[i].a, 1.0);
    }
    sum /= float(N);
    float cov = solidSum.a / float(N);
    vec3 col;

    if (crisp < 0.5) {
        // soft Gaussians: plain blending over the background
        col = sum.rgb + background * (1.0 - clamp(sum.a, 0.0, 1.0));
        if (quantise > 0.5) col = dither > 0.0 ? snapDither(col, cell, false) : palette[nearest(col, false)];
    } else if (cov >= 0.5) {
        // the object. Its colour: the palette colour most samples snap to
        col = solidSum.rgb / solidSum.a;
        bool edge = false;
        if (outline > 0.5) {
            int n = int(coverage(cell + vec2(1.0, 0.0)) >= 0.5) + int(coverage(cell - vec2(1.0, 0.0)) >= 0.5)
                  + int(coverage(cell + vec2(0.0, 1.0)) >= 0.5) + int(coverage(cell - vec2(0.0, 1.0)) >= 0.5);
            edge = n > 0 && n < 4; // isolated dots keep their colour
        }
        if (quantise > 0.5 && dither <= 0.0) {
            int lab[4];
            for (int i = 0; i < 4; i++) { lab[i] = -1; if (i < N && smp[i].a > SOLID_ALPHA) lab[i] = nearest(smp[i].rgb / smp[i].a, true); }
            int best = -1, score = 0;
            for (int i = 0; i < 4; i++) {
                if (lab[i] < 0) continue;
                int n = 0;
                for (int j = 0; j < 4; j++) if (lab[j] == lab[i]) n++;
                if (n > score) { score = n; best = lab[i]; }
            }
            col = palette[best];
            if (edge) col = palette[nearest(ink(col), true)];
        } else {
            if (edge) col = ink(col);
            if (quantise > 0.5) col = edge ? palette[nearest(col, true)] : snapDither(col, cell, true);
        }
    } else {
        // background, with whatever translucent light lies over it
        float a = clamp(sum.a, 0.0, 1.0);
        col = background * (1.0 - a) + sum.rgb;
        if (quantise > 0.5) col = dither > 0.0 ? snapDither(col, cell, false) : haze(sum.rgb / max(a, 1e-4), a);
    }
    finalColor = vec4(col, 1.0);
}
`

post_init :: proc(p: ^Post) {
    p.shader = rl.LoadShaderFromMemory(nil, POST_FS)
    p.loc_low_res      = rl.GetShaderLocation(p.shader, "lowRes")
    p.loc_ss           = rl.GetShaderLocation(p.shader, "ss")
    p.loc_outline      = rl.GetShaderLocation(p.shader, "outline")
    p.loc_quantise     = rl.GetShaderLocation(p.shader, "quantise")
    p.loc_dither       = rl.GetShaderLocation(p.shader, "dither")
    p.loc_crisp        = rl.GetShaderLocation(p.shader, "crisp")
    p.loc_palette      = rl.GetShaderLocation(p.shader, "palette")
    p.loc_palette_size = rl.GetShaderLocation(p.shader, "paletteSize")
    p.loc_surface_size = rl.GetShaderLocation(p.shader, "surfaceSize")
    p.loc_background   = rl.GetShaderLocation(p.shader, "background")
    p.loc_grade        = rl.GetShaderLocation(p.shader, "grade")
}

post_unload :: proc(p: ^Post) {
    rl.UnloadShader(p.shader)
}

// `surface` colours may colour solid objects; `glow` colours are appended after
// them and may only be taken by translucent light (surfaceSize vs paletteSize).
// Duplicates are dropped and the list is capped at MAX_COLOURS, like setPalette
// in the original.
post_set_palette :: proc(p: ^Post, surface, glow: [][4]u8, background: [4]u8) {
    uniq: [MAX_COLOURS][4]u8
    n := 0

    add :: proc(uniq: ^[MAX_COLOURS][4]u8, n: ^int, c: [4]u8) {
        if n^ >= MAX_COLOURS do return
        for i in 0..<n^ {
            if uniq[i][0] == c[0] && uniq[i][1] == c[1] && uniq[i][2] == c[2] do return
        }
        uniq[n^] = c
        n^ += 1
    }

    for c in surface do add(&uniq, &n, c)
    surface_n := i32(n)
    for c in glow do add(&uniq, &n, c)

    pal: [MAX_COLOURS][3]f32
    for i in 0..<n {
        pal[i] = {f32(uniq[i][0]) / 255, f32(uniq[i][1]) / 255, f32(uniq[i][2]) / 255}
    }
    count := i32(n)
    bg := [3]f32{f32(background[0]) / 255, f32(background[1]) / 255, f32(background[2]) / 255}

    rl.SetShaderValueV(p.shader, p.loc_palette, &pal[0], .VEC3, MAX_COLOURS)
    rl.SetShaderValue(p.shader, p.loc_palette_size, &count, .INT)
    rl.SetShaderValue(p.shader, p.loc_surface_size, &surface_n, .INT)
    rl.SetShaderValue(p.shader, p.loc_background, &bg, .VEC3)
}

// Resolve `src` (the supersampled scene, premultiplied alpha) into `dst`, which
// is art_w x art_h. Everything happens on the GPU in one draw call.
post_apply :: proc(p: ^Post, src: rl.Texture2D, dst: rl.RenderTexture2D, art_w, art_h: i32, s: Post_Settings) {
    low_res := [2]f32{f32(art_w), f32(art_h)}
    ss      := f32(s.ss)
    outline := f32(1 if s.outline else 0)
    quant   := f32(1 if s.quant   else 0)
    crisp   := f32(1 if s.crisp   else 0)
    dither  := s.dither
    grade   := s.grade

    rl.SetShaderValue(p.shader, p.loc_low_res,  &low_res, .VEC2)
    rl.SetShaderValue(p.shader, p.loc_ss,       &ss,      .FLOAT)
    rl.SetShaderValue(p.shader, p.loc_outline,  &outline, .FLOAT)
    rl.SetShaderValue(p.shader, p.loc_quantise, &quant,   .FLOAT)
    rl.SetShaderValue(p.shader, p.loc_dither,   &dither,  .FLOAT)
    rl.SetShaderValue(p.shader, p.loc_crisp,    &crisp,   .FLOAT)
    rl.SetShaderValue(p.shader, p.loc_grade,    &grade,   .FLOAT)

    rl.BeginTextureMode(dst)
    rl.BeginShaderMode(p.shader)
    // negative source height: render textures are stored upside down. The
    // shader reads texels by gl_FragCoord, so this only has to cover the target.
    rl.DrawTexturePro(src,
        {0, 0, f32(src.width), -f32(src.height)},
        {0, 0, f32(art_w), f32(art_h)},
        {0, 0}, 0, rl.WHITE)
    rl.EndShaderMode()
    rl.EndTextureMode()
}
