package main

// sandtable: real 3DGS captures through a pixel-art pipeline, Commandos style.
//
//   dev/
//     ospz/
//     sandtable/    <- this directory
//
//   cd sandtable
//   odin run . -- ../ospz/models/tree.ply
//
// Pass 1 draws the splat cloud into an off-screen target at ss x the art
// resolution (premultiplied RGBA, transparent where nothing was drawn).
// Pass 2 (post.odin, from pixlsplat) resolves it to palette-snapped, outlined
// pixel art at the art resolution. The result is scaled up with nearest-neighbour.

import "core:fmt"
import "core:math/linalg"
import "core:os"

import rl "vendor:raylib"

BACKGROUND :: [4]u8{16, 14, 20, 255}

frame_views :: proc(free_cam: ^rl.Camera3D, iso: ^Iso, v: Splat_View) {
	frame_camera(free_cam, v)
	iso_frame(iso, v.center, v.extent)
}

apply_palette :: proc(post: ^Post, mode: Palette_Mode, v: Splat_View) {
	pal := build_palette(mode, v.colors, BACKGROUND)
	defer delete(pal)
	post_set_palette(post, pal[:], nil, BACKGROUND)
}

// Ortho depth is linear, so wide planes cost no precision. The perspective path
// keeps the original viewer's near/far, with a near plane that scales with the
// cloud so crisp depth testing has some precision to work with.
clip_planes :: proc(extent: f32, ortho: bool, iso_distance: f32) -> (near, far: f32) {
	if ortho {
		return max(iso_distance - extent * 4, extent * 0.01), iso_distance + extent * 4
	}
	return max(extent * 0.005, 0.01), max(extent * 40, 100)
}

main :: proc() {
	rl.SetConfigFlags({.WINDOW_RESIZABLE, .VSYNC_HINT})
	rl.InitWindow(1280, 720, "sandtable")
	defer rl.CloseWindow()
	rl.SetTargetFPS(60)

	path := "tree.ply"
	if len(os.args) > 1 {
		path = os.args[1]
	}

	view, load_err := load_view(path)
	defer release_view(&view)

	splat, splat_ok := splat_init()
	if !splat_ok {
		fmt.eprintln("splat shader failed to compile")
		return
	}
	defer splat_unload(&splat)

	post: Post
	post_init(&post)
	defer post_unload(&post)
	if post.shader.id == 0 {
		fmt.eprintln("post shader failed to compile")
		return
	}

	targets: Targets
	defer targets_destroy(&targets)

	// pixlsplat's defaults: quant + outline + crisp on, 2x supersampling, no dither
	cfg := Post_Settings{quant = true, crisp = true, outline = true, ss = 2, dither = 0}
	pixel_size := i32(PIXEL_SIZE_DEFAULT)
	crisp_alpha := f32(0.35)
	palette_mode := Palette_Mode.Extracted
	game_cam := true
	grade_strength := f32(1) // Commandos grade; only applied with the Commandos palette

	free_cam: rl.Camera3D
	iso: Iso
	frame_views(&free_cam, &iso, view)
	apply_palette(&post, palette_mode, view)

	last_fwd: [3]f32
	last_pos: [3]f32

	for !rl.WindowShouldClose() {
		// ---- input ---------------------------------------------------------
		if rl.IsFileDropped() {
			files := rl.LoadDroppedFiles()
			if files.count > 0 {
				p := string(files.paths[0])
				next, e := load_view(p)
				if e == .None {
					release_view(&view)
					view = next
					load_err = .None
					frame_views(&free_cam, &iso, view)
					apply_palette(&post, palette_mode, view)
					last_fwd = {}
				} else {
					load_err = e
					fmt.eprintf("load %s: %v\n", p, e)
				}
			}
			rl.UnloadDroppedFiles(files)
		}

		if rl.IsKeyPressed(.R) {
			frame_views(&free_cam, &iso, view)
			last_fwd = {}
		}
		if rl.IsKeyPressed(.C) {
			game_cam = !game_cam
			last_fwd = {}
		}
		if rl.IsKeyPressed(.P) {
			if palette_mode == .Extracted {
				palette_mode = .Commandos
			} else {
				palette_mode = .Extracted
			}
			apply_palette(&post, palette_mode, view)
		}
		// toggles, same letters as pixlsplat
		if rl.IsKeyPressed(.Q) do cfg.quant = !cfg.quant
		if rl.IsKeyPressed(.X) do cfg.crisp = !cfg.crisp
		if rl.IsKeyPressed(.E) do cfg.outline = !cfg.outline
		if rl.IsKeyPressed(.S) do cfg.ss = 3 - cfg.ss // 1 <-> 2
		if rl.IsKeyPressed(.D) do cfg.dither = 0 if cfg.dither >= 1 else cfg.dither + 0.5
		if rl.IsKeyPressed(.G) do grade_strength = 1 if grade_strength <= 0 else grade_strength - 0.5 // 1 -> 0.5 -> 0
		// The extracted palette is built from the ungraded cloud, so the grade only
		// goes with the fixed Commandos palette.
		cfg.grade = grade_strength if palette_mode == .Commandos else 0
		if rl.IsKeyPressed(.EQUAL) || rl.IsKeyPressed(.KP_ADD) do pixel_size += 1
		if rl.IsKeyPressed(.MINUS) || rl.IsKeyPressed(.KP_SUBTRACT) do pixel_size -= 1
		if rl.IsKeyPressed(.LEFT_BRACKET) do crisp_alpha = clamp(crisp_alpha - 0.05, 0.05, 0.95)
		if rl.IsKeyPressed(.RIGHT_BRACKET) do crisp_alpha = clamp(crisp_alpha + 0.05, 0.05, 0.95)

		// ---- art grid follows the window -------------------------------------
		pixel_size = clamp(pixel_size, PIXEL_SIZE_MIN, PIXEL_SIZE_MAX)
		art_w, art_h := art_size(rl.GetScreenWidth(), rl.GetScreenHeight(), pixel_size)
		targets_resize(&targets, art_w, art_h)

		// ---- camera ----------------------------------------------------------
		camera: rl.Camera3D
		if game_cam {
			iso_update(&iso, f32(art_h * pixel_size))
			camera = iso_camera(iso)
		} else {
			update_orbit(&free_cam)
			camera = free_cam
		}
		near, far := clip_planes(view.extent, game_cam, iso.distance)

		fwd := linalg.normalize(camera.target - camera.position)
		if view.count > 0 &&
		   (linalg.dot(fwd, last_fwd) < 0.9995 ||
			linalg.vector_length(camera.position - last_pos) > 0.01 * view.extent) {
			sort_order(&view, camera.position, fwd, far)
			rl.UpdateTexture(view.order_tex, raw_data(view.order_px))
			last_fwd, last_pos = fwd, camera.position
		}

		// ---- pass 1: splats into a transparent, premultiplied target ---------
		rt := targets.scene[cfg.ss]
		rw, rh := f32(rt.texture.width), f32(rt.texture.height)

		rl.BeginTextureMode(rt)
		rl.ClearBackground(rl.BLANK)
		if view.count > 0 {
			aspect := rw / rh
			view_m := rl.GetCameraMatrix(camera)
			proj_m: rl.Matrix
			if game_cam {
				half_h := camera.fovy * 0.5
				half_w := half_h * aspect
				proj_m = rl.MatrixOrtho(-half_w, half_w, -half_h, half_h, near, far)
			} else {
				proj_m = rl.MatrixPerspective(camera.fovy, aspect, near, far)
			}
			splat_set_frame(&splat, view_m, proj_m, rw, rh, game_cam, cfg.crisp, crisp_alpha)

			rl.BeginMode3D(camera)
			splat_draw(&splat, view, cfg.crisp)
			rl.EndMode3D()
		}
		rl.EndTextureMode()

		// ---- pass 2: resolve to pixel art on the GPU -------------------------
		post_apply(&post, rt.texture, targets.art, targets.w, targets.h, cfg)

		rl.BeginDrawing()
		rl.ClearBackground(rl.BLACK)
		src := rl.Rectangle{0, 0, f32(targets.w), -f32(targets.h)} // render textures are upside down
		dst := rl.Rectangle{0, 0, f32(targets.w * pixel_size), f32(targets.h * pixel_size)}
		rl.DrawTexturePro(targets.art.texture, src, dst, {0, 0}, 0, rl.WHITE)

		title := view.name if len(view.name) > 0 else path
		rl.DrawText(fmt.ctprintf("%s", title), 10, 10, 20, rl.RAYWHITE)
		if load_err != .None {
			rl.DrawText(fmt.ctprintf("load failed: %v", load_err), 10, 35, 18, {230, 90, 80, 255})
		} else {
			rl.DrawText(
				fmt.ctprintf(
					"%d splats | %s camera | pixel %dpx (%dx%d art, ss %d) | %d fps",
					view.count,
					"game" if game_cam else "free",
					pixel_size,
					targets.w,
					targets.h,
					cfg.ss,
					rl.GetFPS(),
				),
				10, 35, 18, {180, 180, 180, 255},
			)
		}
		rl.DrawText(
			fmt.ctprintf(
				"[Q] palette %s  [X] hard %s  [E] outline %s  [D] dither %.1f  [P] colours %v  [G] grade %.1f  [ [ ] ] alpha cut %.2f",
				"on" if cfg.quant else "off",
				"on" if cfg.crisp else "off",
				"on" if cfg.outline else "off",
				cfg.dither,
				palette_mode,
				cfg.grade,
				crisp_alpha,
			),
			10, 58, 16, {180, 180, 180, 255},
		)
		rl.DrawText(
			"[C] camera  [-/+] pixel size  [S] ss  [R] reset | game: drag/arrows rotate, shift/right-drag pan, scroll zoom | free: drag orbit | drop a .spz or .ply",
			10, 78, 16, {160, 160, 160, 255},
		)
		rl.EndDrawing()
	}
}
