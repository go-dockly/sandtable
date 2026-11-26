package main

// Splat cloud loading, depth sort and the instanced splat shader.
//
// Lifted from ospz/viewer/main.odin (`package main` there, so it cannot be
// imported). Differences from the original:
//   - the cloud's DC colours are kept (view.colors) so a palette can be built
//   - `screen` is the size of the render target the splats go into, not the window
//   - the vertex shader handles orthographic projection: the Jacobian is constant,
//     there is no division by depth
//   - the fragment shader has a hard "crisp" mode: an opaque ellipse out to
//     1.5 sigma (pixlsplat's SPLAT_STD_DEV), depth tested. Splats below
//     `crispAlpha` opacity are dropped. 0.35 is a guess to tune per cloud.
//   - soft splats are depth tested (not written) so GLB objects drawn first
//     occlude what is behind them
//   - blending is ONE / ONE_MINUS_SRC_ALPHA via BeginBlendMode(.ALPHA_PREMULTIPLY),
//     as pixlsplat does, so the target holds premultiplied RGBA that the post pass
//     can read coverage from

import "core:fmt"
import "core:math"
import "core:os"
import "core:slice"

import ospz "../ospz"
import rl "vendor:raylib"
import rlgl "vendor:raylib/rlgl"

import "splatsort"

DATA_W :: 1024
ORDER_W :: 1024
SH_C0 :: f32(0.28209479177387814)

Splat_View :: struct {
	count:     int,
	center:    [3]f32,
	extent:    f32,
	name:      string,
	data_tex:  rl.Texture2D,
	order_tex: rl.Texture2D,
	order_px:  []u8,
	pos:       [][3]f32,
	colors:    [][4]u8, // DC colour per kept splat, for palette extraction
	opacity:   []f32,   // per kept splat, for the terrain (terrain/terrain.odin)
	order:     []u32,
	depth:     []f32,
	radius:    []f32, // per kept splat, world units: its reach, for culling
	sorter:    splatsort.Sorter,
	visible:   int,
	data_w:    i32,
	data_h:    i32,
	order_h:   i32,
}

Splat_Shader :: struct {
	shader:                                       rl.Shader,
	quad:                                         rl.Mesh,
	loc_view, loc_proj, loc_screen:               i32,
	loc_data, loc_order:                          i32,
	loc_ortho, loc_crisp, loc_crisp_alpha:        i32,
}

splat_init :: proc() -> (s: Splat_Shader, ok: bool) {
	s.shader = rl.LoadShaderFromMemory(VS, FS)
	if s.shader.id == 0 do return {}, false

	s.quad = make_quad()
	s.loc_view = rl.GetShaderLocation(s.shader, "view")
	s.loc_proj = rl.GetShaderLocation(s.shader, "proj")
	s.loc_screen = rl.GetShaderLocation(s.shader, "screen")
	s.loc_data = rl.GetShaderLocation(s.shader, "splatData")
	s.loc_order = rl.GetShaderLocation(s.shader, "orderTex")
	s.loc_ortho = rl.GetShaderLocation(s.shader, "ortho")
	s.loc_crisp = rl.GetShaderLocation(s.shader, "crisp")
	s.loc_crisp_alpha = rl.GetShaderLocation(s.shader, "crispAlpha")

	loc_data_w := rl.GetShaderLocation(s.shader, "dataWidth")
	loc_order_w := rl.GetShaderLocation(s.shader, "orderWidth")
	data_w := i32(DATA_W)
	order_w := i32(ORDER_W)
	rl.SetShaderValue(s.shader, loc_data_w, &data_w, .INT)
	rl.SetShaderValue(s.shader, loc_order_w, &order_w, .INT)
	return s, true
}

splat_unload :: proc(s: ^Splat_Shader) {
	rl.UnloadMesh(s.quad)
	rl.UnloadShader(s.shader)
}

// Per-frame uniforms. `target_w/h` is the render target about to be drawn into.
splat_set_frame :: proc(
	s: ^Splat_Shader,
	view_m, proj_m: rl.Matrix,
	target_w, target_h: f32,
	ortho, crisp: bool,
	crisp_alpha: f32,
) {
	screen := [2]f32{target_w, target_h}
	ortho_v := f32(1 if ortho else 0)
	crisp_v := f32(1 if crisp else 0)
	alpha_v := crisp_alpha
	rl.SetShaderValueMatrix(s.shader, s.loc_view, view_m)
	rl.SetShaderValueMatrix(s.shader, s.loc_proj, proj_m)
	rl.SetShaderValue(s.shader, s.loc_screen, &screen[0], .VEC2)
	rl.SetShaderValue(s.shader, s.loc_ortho, &ortho_v, .FLOAT)
	rl.SetShaderValue(s.shader, s.loc_crisp, &crisp_v, .FLOAT)
	rl.SetShaderValue(s.shader, s.loc_crisp_alpha, &alpha_v, .FLOAT)
}

// Call between BeginMode3D / EndMode3D on the splat render target.
// crisp: opaque, depth tested and written. Soft: blended back to front, depth
// tested but not written, so splats behind an opaque mesh drawn first (a GLB
// object, model.odin) are hidden and the ones in front blend over it. With
// nothing drawn first the depth buffer is clear and every splat passes, as before.
splat_draw :: proc(s: ^Splat_Shader, v: Splat_View, crisp: bool) {
	rlgl.DrawRenderBatchActive()
	rlgl.DisableBackfaceCulling()
	rlgl.EnableDepthTest()
	if crisp {
		rlgl.EnableDepthMask()
	} else {
		rlgl.DisableDepthMask()
	}
	rl.BeginBlendMode(.ALPHA_PREMULTIPLY)

	bind_sampler(s.shader.id, s.loc_data, v.data_tex.id, 1)
	bind_sampler(s.shader.id, s.loc_order, v.order_tex.id, 2)
	rlgl.EnableShader(s.shader.id)
	rlgl.EnableVertexArray(s.quad.vaoId)
	rlgl.DrawVertexArrayElementsInstanced(0, 6, nil, i32(v.visible))
	rlgl.DisableVertexArray()
	rlgl.DisableShader()
	rlgl.ActiveTextureSlot(0)

	rl.EndBlendMode()
	rlgl.EnableDepthTest()
	rlgl.EnableDepthMask()
	rlgl.EnableBackfaceCulling()
}

bind_sampler :: proc(shader_id: u32, loc: i32, tex: u32, slot: i32) {
	if loc < 0 || tex == 0 do return
	rlgl.EnableShader(shader_id)
	rlgl.ActiveTextureSlot(slot)
	rlgl.EnableTexture(tex)

	slot_val := slot
	rlgl.SetUniform(loc, &slot_val, i32(rl.ShaderUniformDataType.INT), 1)
}

// Loads a splat cloud from either an .spz or a 3DGS .ply file. The format is
// detected from the file contents rather than the extension. Both paths hand
// back a cloud in the same coordinate frame (SPZ's native RUB).
load_cloud :: proc(path: string) -> (cloud: ospz.Gaussian_Cloud, err: ospz.Spz_Error) {
	data, read_err := os.read_entire_file(path, context.allocator)
	if read_err != nil {
		return {}, .Io_Failed
	}
	defer delete(data)

	if is_ply(data) {
		// 3DGS PLY exports are RDF; convert to RUB to match what SPZ decodes to.
		return ospz.load_splat_from_ply_bytes(data, {to = .RUB})
	}
	return ospz.load_spz_from_bytes(data, ospz.unpack_options_default())
}

is_ply :: proc(data: []u8) -> bool {
	return len(data) >= 3 && data[0] == 'p' && data[1] == 'l' && data[2] == 'y'
}

load_view :: proc(path: string) -> (view: Splat_View, err: ospz.Spz_Error) {
	cloud, e := load_cloud(path)
	if e != .None {
		return {}, e
	}
	defer ospz.release_gaussian_cloud(&cloud)

	n := int(cloud.num_points)
	if n <= 0 {
		return {}, .Invalid_Data
	}

	pos := make([][3]f32, n)
	rad := make([]f32, n)
	cols := make([][4]u8, n)
	ops := make([]f32, n)
	texels := n * 4
	data_h := (texels + DATA_W - 1) / DATA_W
	floats := make([]f32, DATA_W * data_h * 4)

	kept := 0

	for i in 0 ..< n {
		px := cloud.positions[i * 3 + 0]
		py := cloud.positions[i * 3 + 1]
		pz := cloud.positions[i * 3 + 2]
		if !is_finite(px) || !is_finite(py) || !is_finite(pz) do continue

		sx := math.exp(clamp(cloud.scales[i * 3 + 0], -12, 8))
		sy := math.exp(clamp(cloud.scales[i * 3 + 1], -12, 8))
		sz := math.exp(clamp(cloud.scales[i * 3 + 2], -12, 8))

		// Raw 3DGS PLY quaternions are not unit length (SPZ decodes to unit
		// quaternions already); the shader's quat_mat needs them normalised.
		qx := cloud.rotations[i * 4 + 0]
		qy := cloud.rotations[i * 4 + 1]
		qz := cloud.rotations[i * 4 + 2]
		qw := cloud.rotations[i * 4 + 3]
		qn := math.sqrt(qx * qx + qy * qy + qz * qz + qw * qw)
		if is_finite(qn) && qn > 1e-8 {
			inv := 1 / qn
			qx *= inv; qy *= inv; qz *= inv; qw *= inv
		} else {
			qx, qy, qz, qw = 0, 0, 0, 1
		}
		qy = -qy // conjugate for the Y flip
		qw = -qw

		cr := clamp(0.5 + SH_C0 * cloud.colors[i * 3 + 0], 0, 1)
		cg := clamp(0.5 + SH_C0 * cloud.colors[i * 3 + 1], 0, 1)
		cb := clamp(0.5 + SH_C0 * cloud.colors[i * 3 + 2], 0, 1)
		a := sigmoid(cloud.alphas[i])
		if a < 1.0 / 255.0 do continue

		base := kept * 16
		floats[base + 0] = px
		floats[base + 1] = py
		floats[base + 2] = pz
		floats[base + 3] = a
		floats[base + 4] = sx
		floats[base + 5] = sy
		floats[base + 6] = sz
		floats[base + 7] = 0
		floats[base + 8] = qx
		floats[base + 9] = qy
		floats[base + 10] = qz
		floats[base + 11] = qw
		floats[base + 12] = cr
		floats[base + 13] = cg
		floats[base + 14] = cb
		floats[base + 15] = 1

		pos[kept] = {px, py, pz}
		cols[kept] = {to_u8(cr), to_u8(cg), to_u8(cb), 255}
		ops[kept] = a
		rad[kept] = splatsort.radius_of(sx, sy, sz)
		kept += 1
	}
	if kept == 0 {
		delete(pos)
		delete(cols)
		delete(ops)
		delete(rad)
		delete(floats)
		return {}, .Invalid_Data
	}

	view.count = kept
	view.pos = pos[:kept]
	view.colors = cols[:kept]
	view.opacity = ops[:kept]
	view.radius = rad[:kept]
	splatsort.sorter_init(&view.sorter)
	view.center, view.extent = robust_bounds(view.pos, 0.02, 0.98)
	if view.extent < 1e-4 do view.extent = 1
	view.name = fmt.aprintf("%s", path)

	view.data_w = DATA_W
	view.data_h = i32(data_h)
	data_img := rl.Image{
		data    = raw_data(floats),
		width   = view.data_w,
		height  = view.data_h,
		mipmaps = 1,
		format  = .UNCOMPRESSED_R32G32B32A32,
	}
	view.data_tex = rl.LoadTextureFromImage(data_img)
	delete(floats)
	rl.SetTextureFilter(view.data_tex, .POINT)
	rl.SetTextureWrap(view.data_tex, .CLAMP)

	view.order = make([]u32, kept)
	for i in 0 ..< kept do view.order[i] = u32(i)
	view.depth = make([]f32, kept)
	view.visible = kept

	view.order_h = i32((kept + ORDER_W - 1) / ORDER_W)
	view.order_px = make([]u8, ORDER_W * int(view.order_h) * 4)
	for i in 0 ..< kept {
		id := u32(i)
		view.order_px[i * 4 + 0] = u8(id)
		view.order_px[i * 4 + 1] = u8(id >> 8)
		view.order_px[i * 4 + 2] = u8(id >> 16)
		view.order_px[i * 4 + 3] = 255
	}
	order_img := rl.Image{
		data    = raw_data(view.order_px),
		width   = ORDER_W,
		height  = view.order_h,
		mipmaps = 1,
		format  = .UNCOMPRESSED_R8G8B8A8,
	}
	view.order_tex = rl.LoadTextureFromImage(order_img)
	rl.SetTextureFilter(view.order_tex, .POINT)
	rl.SetTextureWrap(view.order_tex, .CLAMP)
	return view, .None
}

release_view :: proc(v: ^Splat_View) {
	if v == nil do return
	if v.data_tex.id != 0 do rl.UnloadTexture(v.data_tex)
	if v.order_tex.id != 0 do rl.UnloadTexture(v.order_tex)
	delete(v.pos)
	delete(v.colors)
	delete(v.opacity)
	delete(v.order)
	delete(v.order_px)
	delete(v.depth)
	delete(v.radius)
	splatsort.sorter_destroy(&v.sorter)
	if len(v.name) > 0 do delete(v.name)
	v^ = {}
}

// Center/size from the 2nd-98th percentile of a subsample, so stray splats don't blow up the framing.
robust_bounds :: proc(pos: [][3]f32, lo_q, hi_q: f32) -> (center: [3]f32, extent: f32) {
	STEP :: 8
	m := (len(pos) + STEP - 1) / STEP
	tmp := make([]f32, m)
	defer delete(tmp)

	lo, hi: [3]f32
	for axis in 0 ..< 3 {
		for i in 0 ..< m do tmp[i] = pos[i * STEP][axis]
		slice.sort(tmp)
		lo[axis] = tmp[int(f32(m - 1) * lo_q)]
		hi[axis] = tmp[int(f32(m - 1) * hi_q)]
	}
	center = (lo + hi) * 0.5
	e := hi - lo
	extent = max(e.x, max(e.y, e.z))
	return
}

// Back to front for a view (splatsort/: on every core). With `cull`, the
// splats that cannot reach the orthographic view's box are left out: neither
// sorted nor drawn, so the order must be redone before the view moves out of
// the box's margin (main.odin).
sort_order :: proc(v: ^Splat_View, cam, fwd: [3]f32, far: f32, cull := splatsort.Cull{}) {
	v.visible = splatsort.sort(&v.sorter,
		{pos = v.pos, radius = v.radius, cam = cam, fwd = fwd, far = far, cull = cull},
		{depth = v.depth, order = v.order, order_px = v.order_px},
	)
}

make_quad :: proc() -> rl.Mesh {
	verts   := ([^]f32)(rl.MemAlloc(12 * size_of(f32)))
	uvs     := ([^]f32)(rl.MemAlloc(8 * size_of(f32)))
	indices := ([^]u16)(rl.MemAlloc(6 * size_of(u16)))

	copy(verts[:12], []f32{-1, -1, 0, 1, -1, 0, 1, 1, 0, -1, 1, 0})
	copy(uvs[:8], []f32{0, 0, 1, 0, 1, 1, 0, 1})
	copy(indices[:6], []u16{0, 1, 2, 0, 2, 3})

	mesh: rl.Mesh
	mesh.vertexCount = 4
	mesh.triangleCount = 2
	mesh.vertices = verts
	mesh.texcoords = uvs
	mesh.indices = indices
	rl.UploadMesh(&mesh, false)
	return mesh
}

sigmoid :: proc(x: f32) -> f32 {
	if x >= 12 do return 1
	if x <= -12 do return 0
	return 1 / (1 + math.exp(-x))
}

is_finite :: proc(x: f32) -> bool {
	u := transmute(u32)x
	return (u & 0x7fffffff) < 0x7f800000
}

VS :: `#version 330
in vec3 vertexPosition;
in vec2 vertexTexCoord;
uniform mat4 view;
uniform mat4 proj;
uniform vec2 screen;       // size of the render target the splats are drawn into
uniform float ortho;       // 1 = orthographic projection
uniform int dataWidth;
uniform int orderWidth;
uniform sampler2D splatData;
uniform sampler2D orderTex;
flat out vec4 vColor;
flat out vec3 vConic;
out vec2 vPix;

mat3 quat_mat(vec4 q) {
    float x = q.x, y = q.y, z = q.z, w = q.w;
    float xx = x*x, yy = y*y, zz = z*z;
    float xy = x*y, xz = x*z, yz = y*z;
    float wx = w*x, wy = w*y, wz = w*z;
    return mat3(
        1.0-2.0*(yy+zz), 2.0*(xy+wz), 2.0*(xz-wy),
        2.0*(xy-wz),     1.0-2.0*(xx+zz), 2.0*(yz+wx),
        2.0*(xz+wy),     2.0*(yz-wx), 1.0-2.0*(xx+yy)
    );
}

ivec2 at1(int texel, int width) {
    return ivec2(texel - (texel / width) * width, texel / width);
}

void main() {
    vec4 ob = texelFetch(orderTex, at1(gl_InstanceID, orderWidth), 0);
    int id = int(ob.r * 255.0 + 0.5)
           | (int(ob.g * 255.0 + 0.5) << 8)
           | (int(ob.b * 255.0 + 0.5) << 16);
    int base = id * 4;
    vec4 p0 = texelFetch(splatData, at1(base + 0, dataWidth), 0);
    vec4 p1 = texelFetch(splatData, at1(base + 1, dataWidth), 0);
    vec4 p2 = texelFetch(splatData, at1(base + 2, dataWidth), 0);
    vec4 p3 = texelFetch(splatData, at1(base + 3, dataWidth), 0);

    vec3 mean = p0.xyz;
    float opacity = p0.w;
    vec3 scale = max(p1.xyz, vec3(1e-6));
    mat3 R = quat_mat(p2);
    mat3 S = mat3(scale.x, 0.0, 0.0,  0.0, scale.y, 0.0,  0.0, 0.0, scale.z);
    mat3 M = R * S;
    mat3 Sigma = M * transpose(M);

    vec4 tv = view * vec4(mean, 1.0);
    mat3 W = mat3(view);
    mat3 Sv = W * Sigma * transpose(W);

    float fx = proj[0][0] * screen.x * 0.5;
    float fy = proj[1][1] * screen.y * 0.5;
    float tz = tv.z;
    float J00, J02, J11, J12;
    if (ortho > 0.5) {
        // x_px = fx * x_view: no division by depth, no depth-dependent terms
        J00 = fx;  J02 = 0.0;
        J11 = fy;  J12 = 0.0;
    } else {
        J00 = fx / tz;  J02 = -fx * tv.x / (tz * tz);
        J11 = fy / tz;  J12 = -fy * tv.y / (tz * tz);
    }

    float a = Sv[0][0], b = Sv[0][1], c = Sv[0][2];
    float d = Sv[1][0], e = Sv[1][1], f = Sv[1][2];
    float g = Sv[2][0], h = Sv[2][1], i = Sv[2][2];
    float r0c0 = J00*a + J02*g;
    float r0c1 = J00*b + J02*h;
    float r0c2 = J00*c + J02*i;
    float r1c0 = J11*d + J12*g;
    float r1c1 = J11*e + J12*h;
    float r1c2 = J11*f + J12*i;
    float c00 = r0c0*J00 + r0c2*J02;
    float c01 = r0c1*J11 + r0c2*J12;
    float c11 = r1c1*J11 + r1c2*J12;
    c00 += 0.3;
    c11 += 0.3;
    float det = c00*c11 - c01*c01;
    if (det < 1e-6) det = 1e-6;
    float invDet = 1.0 / det;
    vConic = vec3(c11 * invDet, -c01 * invDet, c00 * invDet);

    float mid = 0.5 * (c00 + c11);
    float disc = max(0.0, mid*mid - det);
    float radius = 3.0 * sqrt(mid + sqrt(disc));
    radius = clamp(radius, 0.5, 1024.0);

    vec2 corner = vertexTexCoord * 2.0 - 1.0;
    vec2 pix = corner * radius;
    vec4 clip = proj * tv;
    if (tz >= -1e-4 || clip.w <= 0.0 || opacity < 1.0/255.0) {
        gl_Position = vec4(0.0, 0.0, 2.0, 1.0);
        vColor = vec4(0.0);
        vPix = vec2(0.0);
        return;
    }
    clip.xy += (pix / (screen * 0.5)) * clip.w;
    gl_Position = clip;
    vPix = pix;
    vColor = vec4(p3.rgb, opacity);
}
`

FS :: `#version 330
flat in vec4 vColor;
flat in vec3 vConic;
in vec2 vPix;
uniform float crisp;       // 1 = hard opaque ellipse, 0 = soft Gaussian
uniform float crispAlpha;  // crisp: splats with less opacity than this are dropped
out vec4 fragColor;

void main() {
    float power = -0.5 * (vConic.x * vPix.x * vPix.x + vConic.z * vPix.y * vPix.y)
                  - vConic.y * vPix.x * vPix.y;
    if (crisp > 0.5) {
        // hard edge at 1.5 sigma: -0.5 * 1.5^2
        if (power < -1.125 || vColor.a < crispAlpha) discard;
        fragColor = vec4(vColor.rgb, 1.0);
        return;
    }
    if (power > 0.0) discard;
    float alpha = exp(power) * vColor.a;
    if (alpha < 1.0/255.0) discard;
    fragColor = vec4(vColor.rgb * alpha, alpha);
}
`
