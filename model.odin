package main

// GLB objects: conventional meshes drawn into the same scene target as the
// splats, so they share the camera, the depth buffer and the pixel-art post pass.
//
// pixlsplat bakes its models (toad.glb & co.) into surfels offline. sandtable
// keeps them as meshes instead, because objects are the editable part of a level
// and the terrain is not. What carries over from pixlsplat:
//   - the pivot sits at the bottom centre of the bounds, so a model stands on
//     the ground at its position (stand_on_ground there)
//   - one fixed sun with a high ambient, so the form survives palette
//     quantisation without real lighting
//   - the model's colours go into the extracted palette (model_scene_palette
//     there), otherwise a red car snaps to the nearest brick or roof colour
//   - opaque output (alpha 1) into the premultiplied target, so the post pass
//     counts the model as solid coverage and draws its ink outline

import "core:fmt"
import "core:os"
import "core:strings"

import rl "vendor:raylib"
import rlgl "vendor:raylib/rlgl"

Model_Asset :: struct {
	path:   string,
	model:  rl.Model,
	pivot:  [3]f32,  // bottom centre of the bounds, model space
	size:   [3]f32,  // bounds size, model space
	colors: [][4]u8, // albedo samples, for palette extraction
}

Model_Shader :: struct {
	shader:    rl.Shader,
	loc_light: i32,
	loc_amb:   i32,
}

// Sun from the upper left of the default 45 degree game view, as in the
// Commandos art: lit roofs, darker south-east faces.
MODEL_LIGHT_DIR :: [3]f32{-0.45, -0.8, -0.4}
MODEL_AMBIENT   :: f32(0.55)

model_shader_init :: proc() -> (s: Model_Shader, ok: bool) {
	s.shader = rl.LoadShaderFromMemory(MODEL_VS, MODEL_FS)
	if s.shader.id == 0 do return {}, false
	s.loc_light = rl.GetShaderLocation(s.shader, "lightDir")
	s.loc_amb = rl.GetShaderLocation(s.shader, "ambient")
	light := MODEL_LIGHT_DIR
	amb := MODEL_AMBIENT
	rl.SetShaderValue(s.shader, s.loc_light, &light, .VEC3)
	rl.SetShaderValue(s.shader, s.loc_amb, &amb, .FLOAT)
	return s, true
}

model_shader_unload :: proc(s: ^Model_Shader) {
	if s.shader.id != 0 do rl.UnloadShader(s.shader)
	s^ = {}
}

is_model_path :: proc(path: string) -> bool {
	lower := strings.to_lower(path, context.temp_allocator)
	return strings.has_suffix(lower, ".glb") || strings.has_suffix(lower, ".gltf")
}

load_model_asset :: proc(path: string, shader: rl.Shader) -> (a: Model_Asset, ok: bool) {
	// raylib only logs a warning for a file it cannot read, so check up front
	if !os.is_file(path) || !is_model_path(path) {
		fmt.eprintf("model %s: not a .glb / .gltf file\n", path)
		return {}, false
	}
	m := rl.LoadModel(strings.clone_to_cstring(path, context.temp_allocator))
	if m.meshCount <= 0 || m.meshes == nil {
		rl.UnloadModel(m)
		fmt.eprintf("model %s: no meshes\n", path)
		return {}, false
	}
	for i in 0 ..< m.materialCount {
		m.materials[i].shader = shader
	}

	box := rl.GetModelBoundingBox(m)
	a.model = m
	a.size = box.max - box.min
	a.pivot = {(box.min.x + box.max.x) * 0.5, box.min.y, (box.min.z + box.max.z) * 0.5}
	a.colors = model_colors(m)
	a.path = strings.clone(path)
	return a, true
}

release_model_asset :: proc(a: ^Model_Asset) {
	if a == nil do return
	if a.model.meshCount > 0 {
		// UnloadModel frees the material maps but leaves shaders and textures to
		// the caller; the shader is shared, the textures are freed here.
		default_tex := rlgl.GetTextureIdDefault()
		freed := make([dynamic]u32, context.temp_allocator)
		outer: for i in 0 ..< a.model.materialCount {
			a.model.materials[i].shader = {} // shared, not ours to unload
			tex := a.model.materials[i].maps[int(rl.MaterialMapIndex.ALBEDO)].texture
			if tex.id == 0 || tex.id == default_tex do continue
			for id in freed {
				if id == tex.id do continue outer
			}
			append(&freed, tex.id)
			rl.UnloadTexture(tex)
		}
		rl.UnloadModel(a.model)
	}
	delete(a.colors)
	delete(a.path)
	a^ = {}
}

// Model space (metres) -> world: scale by object scale x world units per metre,
// rotate about the pivot, then move the pivot to `t.position`. Euler XYZ in
// radians; only yaw is driven for now.
model_matrix :: proc(a: Model_Asset, t: Transform, world_scale: f32) -> rl.Matrix {
	s := t.scale * world_scale
	return rl.MatrixTranslate(t.position.x, t.position.y, t.position.z) *
		rl.MatrixRotateXYZ(t.rotation) *
		rl.MatrixScale(s.x, s.y, s.z) *
		rl.MatrixTranslate(-a.pivot.x, -a.pivot.y, -a.pivot.z)
}

// Call between BeginMode3D / EndMode3D, after the projection has been set to
// the splat pass's (see main.odin), and before splat_draw: the model writes
// depth, the splats test against it.
model_draw :: proc(a: Model_Asset, t: Transform, world_scale: f32) {
	if a.model.meshCount <= 0 do return
	world := model_matrix(a, t, world_scale)
	rlgl.EnableDepthTest()
	rlgl.EnableDepthMask()
	for i in 0 ..< a.model.meshCount {
		mat := a.model.materials[a.model.meshMaterial[i]]
		rl.DrawMesh(a.model.meshes[i], mat, world)
	}
	rlgl.DrawRenderBatchActive()
}

// A few thousand albedo samples: each material's base colour times its texture.
MODEL_COLOUR_SAMPLES :: 4096

model_colors :: proc(m: rl.Model) -> [][4]u8 {
	out := make([dynamic][4]u8, 0, MODEL_COLOUR_SAMPLES)
	default_tex := rlgl.GetTextureIdDefault()
	n := max(int(m.materialCount), 1)
	per := MODEL_COLOUR_SAMPLES / n

	for i in 0 ..< m.materialCount {
		mp := m.materials[i].maps[int(rl.MaterialMapIndex.ALBEDO)]
		tint := mp.color
		if mp.texture.id == 0 || mp.texture.id == default_tex {
			for _ in 0 ..< per / 16 do append(&out, [4]u8{tint.r, tint.g, tint.b, 255})
			continue
		}
		img := rl.LoadImageFromTexture(mp.texture)
		defer rl.UnloadImage(img)
		if img.data == nil || img.width <= 0 || img.height <= 0 do continue
		px := rl.LoadImageColors(img)
		defer rl.UnloadImageColors(px)
		count := int(img.width) * int(img.height)
		step := max(1, count / per)
		for k := 0; k < count; k += step {
			c := px[k]
			if c.a < 128 do continue
			append(&out, [4]u8{
				u8(u32(c.r) * u32(tint.r) / 255),
				u8(u32(c.g) * u32(tint.g) / 255),
				u8(u32(c.b) * u32(tint.b) / 255),
				255,
			})
		}
	}
	return out[:]
}

// Cloud colours plus the model's, the model taking about `share` of the samples
// extract_palette sees. The model samples are spread with a stride that is
// coprime to typical lengths so extract_palette's own stride does not alias.
mix_palette_colors :: proc(cloud, model: [][4]u8, share: f32) -> [][4]u8 {
	if len(model) == 0 || len(cloud) == 0 do return nil
	extra := int(f32(len(cloud)) * share / (1 - share))
	out := make([][4]u8, len(cloud) + extra)
	copy(out, cloud)
	for j in 0 ..< extra {
		out[len(cloud) + j] = model[(j * 7919) % len(model)]
	}
	return out
}

MODEL_VS :: `#version 330
in vec3 vertexPosition;
in vec2 vertexTexCoord;
in vec3 vertexNormal;
in vec4 vertexColor;
uniform mat4 mvp;
uniform mat4 matNormal;
out vec2 fragTexCoord;
out vec4 fragColor;
out vec3 fragNormal;

void main() {
    fragTexCoord = vertexTexCoord;
    fragColor = vertexColor;
    fragNormal = normalize(vec3(matNormal * vec4(vertexNormal, 0.0)));
    gl_Position = mvp * vec4(vertexPosition, 1.0);
}
`

// Opaque output: alpha 1, so the premultiplied scene target reads it as solid.
// Alpha-cut textures (grilles, foliage cards) are discarded below 0.5.
MODEL_FS :: `#version 330
in vec2 fragTexCoord;
in vec4 fragColor;
in vec3 fragNormal;
uniform sampler2D texture0;
uniform vec4 colDiffuse;
uniform vec3 lightDir;
uniform float ambient;
out vec4 finalColor;

void main() {
    vec4 albedo = texture(texture0, fragTexCoord) * colDiffuse * fragColor;
    if (albedo.a < 0.5) discard;
    vec3 n = normalize(fragNormal);
    if (!gl_FrontFacing) n = -n;
    float d = max(dot(n, -normalize(lightDir)), 0.0);
    finalColor = vec4(albedo.rgb * (ambient + (1.0 - ambient) * d), 1.0);
}
`
