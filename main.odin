package main

// sandtable: real 3DGS captures through a pixel-art pipeline, Commandos style.
//
//   dev/
//     ospz/
//     sandtable/    <- this directory
//
//   cd sandtable
//   odin run . -- ../ospz/models/tree.ply
//   odin run . -- ../ospz/models/krakow.spz --model assets/models/car/volkswagen_typ-82.glb
//
// Pass 1 draws the splat cloud into an off-screen target at ss x the art
// resolution (premultiplied RGBA, transparent where nothing was drawn).
// Pass 2 (post.odin, from pixlsplat) resolves it to palette-snapped, outlined
// pixel art at the art resolution. The result is scaled up with nearest-neighbour.
//
// GLB objects (model.odin, placement.odin) are drawn into the pass 1 target
// before the splats, with the same view & projection, so they are depth tested
// against the cloud and resolved by the same pixel-art pass. They are placed
// and picked with the mouse (editor/): the cursor's ray is unprojected through
// that same view & projection.
//
// The terrain proxy (terrain/, terrain_view.odin) is built from the cloud at
// load: the objects stand on it, the cursor finds the ground on it, and its
// grey-box can be drawn in the same place as the objects, instead of or under
// the splats.

import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:os"
import "core:strings"
import "core:time"

import rl "vendor:raylib"
import rlgl "vendor:raylib/rlgl"

import "editor"
import "scene"
import "splatsort"

BACKGROUND :: [4]u8{16, 14, 20, 255}

frame_views :: proc(free_cam: ^rl.Camera3D, iso: ^Iso, v: Splat_View) {
	frame_camera(free_cam, v)
	iso_frame(iso, v.center, v.extent)
}

// Share of the extracted palette's samples that come from the GLB object.
MODEL_PALETTE_SHARE :: f32(0.12)

apply_palette :: proc(post: ^Post, mode: Palette_Mode, v: Splat_View, model_colors: [][4]u8 = nil) {
	cols := v.colors
	mixed := mix_palette_colors(v.colors, model_colors, MODEL_PALETTE_SHARE)
	defer delete(mixed)
	if mixed != nil do cols = mixed
	pal := build_palette(mode, cols, BACKGROUND)
	defer delete(pal)
	post_set_palette(post, pal[:], nil, BACKGROUND)
}

// Ortho depth is linear, so wide planes cost no precision. The perspective path
// keeps the original viewer's near/far, with a near plane that scales with the
// cloud so crisp depth testing has some precision to work with.
// How far past the game camera's view the splats are still sorted and
// drawn, as a share of its half width and height: room to pan before the
// next sort.
CULL_MARGIN :: f32(0.3)

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
	rl.SetExitKey(.KEY_NULL) // Esc cancels placing; close the window to quit
	rl.SetTargetFPS(60)

	opts, opts_ok := parse_options(os.args[1:])
	if !opts_ok {
		fmt.eprintln(
			"usage: sandtable <cloud.spz|.ply> [--model file.glb] [--world-scale u] [--pos x,y,z] [--yaw deg] [--scale s] [--ground y]\n" +
			"                 [--snap ground|surface|plane] [--offset y] [--align] [--max-tilt deg] [--cell m] [--terrain-export prefix]\n" +
			"                 [--level file.json] [--bench seconds] [--bench-out stats.json]\n" +
			"       sandtable <level.json> [--model file.glb]",
		)
		return
	}
	// a level: its capture, unless one is given, and its scale and terrain cell,
	// so the terrain is built once, as the level was made. A level that exists
	// but cannot be read stops here: nothing may be saved over it.
	if opts.level_arg && !os.exists(opts.level) {
		fmt.eprintf("level %s: no such file\n", opts.level)
		return
	}
	open_at_start := len(opts.level) > 0 && os.exists(opts.level)
	cloud_given := len(opts.cloud) > 0
	if open_at_start {
		l, ok := level_read(opts.level)
		if !ok do return
		if !cloud_given do opts.cloud = scene.resolve(opts.level, l.terrain)
		opts.world_scale = l.world_scale
		opts.cell_m = l.terrain_cell
		opts.max_tilt = l.max_tilt
		scene.destroy(&l)
	}
	cloud_path := strings.clone(opts.cloud if len(opts.cloud) > 0 else "tree.ply")
	defer delete(cloud_path)
	path := cloud_path

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

	model_shader, model_shader_ok := model_shader_init()
	if !model_shader_ok {
		fmt.eprintln("model shader failed to compile")
		return
	}
	defer model_shader_unload(&model_shader)

	placement := Placement{overlay = true, visible = true}
	defer placement_destroy(&placement)
	// path of a model that failed to load; a copy, as dropped paths die with
	// UnloadDroppedFiles
	model_err_buf: [512]u8
	model_err := ""
	if len(opts.model) > 0 {
		if _, ok := placement_load_asset(&placement, opts.model, model_shader.shader); !ok {
			model_err = fmt.bprint(model_err_buf[:], opts.model)
		}
	}
	placement_reset(&placement, opts, view)

	ground_proxy := World_Terrain{cell_m = opts.cell_m, export = opts.export}
	defer world_terrain_destroy(&ground_proxy)
	world_terrain_build(&ground_proxy, view, placement.world_scale, model_shader.shader)
	game_map: World_Map
	defer world_map_destroy(&game_map)

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

	lv: Level_State
	defer level_destroy(&lv)
	if !open_at_start { // open_level sets it
		level_set_path(&lv, opts.level if len(opts.level) > 0 else scene.default_level_path(cloud_path, context.temp_allocator))
	}
	missing := 0
	if open_at_start {
		m, ok := open_level(opts.level, &view, &cloud_path, &free_cam, &iso, &placement, &ground_proxy, &lv, model_shader.shader, keep_cloud = cloud_given)
		if !ok do return
		missing = m
		// --model with a level: the model A places
		if len(opts.model) > 0 {
			if idx, found := placement_load_asset(&placement, opts.model, model_shader.shader); found && len(placement.ed.instances) == 0 {
				placement.template.asset = idx
			}
		}
	}
	apply_palette(&post, palette_mode, view, placement_colors(&placement))

	last_fwd: [3]f32
	last_pos: [3]f32
	last_target: [3]f32
	last_fovy: f32

	// the speed test: uncapped, on the gameplay map
	bench := Bench{seconds = opts.bench, out = opts.bench_out}
	defer bench_destroy(&bench)
	if bench.seconds > 0 {
		rl.ClearWindowState({.VSYNC_HINT})
		rl.SetTargetFPS(0)
		game_cam = true
		world_map_build(&game_map, &lv, &placement, ground_proxy, model_shader.shader)
		bench_start(&bench, &game_map, iso, int(cfg.ss), int(view.count))
		fmt.printfln("bench: %d phases of %.0f s, each after %.0f s of warm-up%s", len(BENCH_PHASES), bench_phase_seconds(&bench), BENCH_WARMUP,
			"" if bench.ok else fmt.tprintf(": cannot start, %s", bench.note))
	}

	for !rl.WindowShouldClose() {
		if bench.seconds > 0 && bench_frame(&bench, &game_map, &iso, placement.world_scale) do break
		if bench.ok do cfg.ss = type_of(cfg.ss)(bench_ss(&bench))
		// ---- input ---------------------------------------------------------
		if rl.IsFileDropped() {
			files := rl.LoadDroppedFiles()
			if files.count > 0 {
				p := string(files.paths[0])
				if strings.has_suffix(strings.to_lower(p, context.temp_allocator), ".json") {
					if m, ok := open_level(p, &view, &cloud_path, &free_cam, &iso, &placement, &ground_proxy, &lv, model_shader.shader); ok {
						missing = m
						load_err = .None
						last_fwd = {}
						apply_palette(&post, palette_mode, view, placement_colors(&placement))
					}
				} else if is_model_path(p) {
					// load it (once) and start placing it
					if idx, ok := placement_load_asset(&placement, p, model_shader.shader); ok {
						template := placement.template
						template.asset = idx
						placement_begin_place(&placement, template)
						model_err = ""
						apply_palette(&post, palette_mode, view, placement_colors(&placement))
					} else {
						model_err = fmt.bprint(model_err_buf[:], p)
					}
				} else {
					next, e := load_view(p)
					if e == .None {
						release_view(&view)
						view = next
						load_err = .None
						delete(cloud_path)
						cloud_path = strings.clone(p)
						frame_views(&free_cam, &iso, view)
						placement_reset(&placement, opts, view)
						level_new(&lv, cloud_path)
						missing = 0
						world_terrain_build(&ground_proxy, view, placement.world_scale, model_shader.shader)
						apply_palette(&post, palette_mode, view, placement_colors(&placement))
						last_fwd = {}
					} else {
						load_err = e
						fmt.eprintf("load %s: %v\n", p, e)
					}
				}
			}
			rl.UnloadDroppedFiles(files)
		}

		cmd := rl.IsKeyDown(.LEFT_CONTROL) || rl.IsKeyDown(.RIGHT_CONTROL) || rl.IsKeyDown(.LEFT_SUPER) || rl.IsKeyDown(.RIGHT_SUPER)
		if rl.IsKeyPressed(.R) && !cmd {
			frame_views(&free_cam, &iso, view)
			last_fwd = {}
		}
		// ---- level -----------------------------------------------------------
		if cmd && rl.IsKeyPressed(.S) {
			level_save(&lv, &placement, cloud_path, ground_proxy.cell_m, iso)
		}
		if cmd && rl.IsKeyPressed(.E) {
			level_export(&lv, &placement, cloud_path, ground_proxy, &game_map, model_shader.shader)
		}
		if cmd && rl.IsKeyPressed(.R) {
			switch {
			case !os.exists(lv.path):
				level_say(&lv, true, "%s: nothing saved yet", lv.path)
			case level_dirty(&lv, &placement, cloud_path, ground_proxy.cell_m) && !level_confirmed(&lv, .Discard):
				level_say(&lv, true, "unsaved changes: ctrl+R again to drop them and reload %s", lv.path)
			case:
				reload := strings.clone(lv.path, context.temp_allocator)
				if m, ok := open_level(reload, &view, &cloud_path, &free_cam, &iso, &placement, &ground_proxy, &lv, model_shader.shader); ok {
					missing = m
					last_fwd = {}
					apply_palette(&post, palette_mode, view, placement_colors(&placement))
				}
			}
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
			apply_palette(&post, palette_mode, view, placement_colors(&placement))
		}
		shift := rl.IsKeyDown(.LEFT_SHIFT) || rl.IsKeyDown(.RIGHT_SHIFT)
		if rl.IsKeyPressed(.Z) && shift && !cmd {
			world_terrain_build(&ground_proxy, view, placement.world_scale, model_shader.shader)
			if ground_proxy.view == .Map do world_map_build(&game_map, &lv, &placement, ground_proxy, model_shader.shader)
		}
		if rl.IsKeyPressed(.TAB) {
			ground_proxy.view = Terrain_View((int(ground_proxy.view) + 1) % len(Terrain_View))
			if ground_proxy.view == .Map do world_map_build(&game_map, &lv, &placement, ground_proxy, model_shader.shader)
		}
		// toggles, same letters as pixlsplat
		if rl.IsKeyPressed(.Q) do cfg.quant = !cfg.quant
		if rl.IsKeyPressed(.X) do cfg.crisp = !cfg.crisp
		if rl.IsKeyPressed(.E) && !cmd do cfg.outline = !cfg.outline
		if rl.IsKeyPressed(.S) && !cmd do cfg.ss = 3 - cfg.ss // 1 <-> 2
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
		bench.art = {art_w, art_h}

		// ---- camera ----------------------------------------------------------
		// a left press only turns the camera once it is a drag, so a click
		// can place or select (editor.Click)
		left_drag := placement.click.dragged
		camera: rl.Camera3D
		if game_cam {
			// the bench drives the camera itself: input would skew its phases
			if !bench.ok do iso_update(&iso, f32(art_h * pixel_size), left_drag)
			camera = iso_camera(iso)
		} else {
			update_orbit(&free_cam, left_drag)
			camera = free_cam
		}
		near, far := clip_planes(view.extent, game_cam, iso.distance)

		// the scene pass's view & projection, also for the cursor's ray
		rt := targets.scene[cfg.ss]
		rw, rh := f32(rt.texture.width), f32(rt.texture.height)
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
		// the picture is drawn at (0, 0), art size * pixel size
		pic_w, pic_h := f32(targets.w * pixel_size), f32(targets.h * pixel_size)

		// ---- objects: keyboard, then mouse, then onto the terrain --------------
		placement_keys(&placement, camera, max(view.extent, 1e-4) if view.count > 0 else 1, rl.GetFrameTime(), ground_proxy.ok)
		mouse := rl.GetMousePosition()
		on_picture := mouse.x >= 0 && mouse.y >= 0 && mouse.x < min(pic_w, f32(rl.GetScreenWidth())) && mouse.y < min(pic_h, f32(rl.GetScreenHeight()))
		ray, ray_ok := editor.screen_ray(linalg.inverse(proj_m * view_m), editor.ndc_from_screen(mouse, pic_w, pic_h))
		placement_mouse(&placement, ray, ray_ok && on_picture, mouse, ground_proxy.t, ground_proxy.ok)
		placement_settle(&placement, ground_proxy.t, ground_proxy.ok)
		if lv.baseline { // just opened: what "saved" looks like, once settled
			delete(lv.saved)
			lv.saved = strings.clone(level_text(&lv, &placement, cloud_path, ground_proxy.cell_m, nil))
			lv.baseline = false
		}
		dirty := level_dirty(&lv, &placement, cloud_path, ground_proxy.cell_m)

		// Re-sort when the view turns. A move only changes the order through
		// perspective: in the orthographic game camera every splat's depth
		// shifts by the same amount. But the game camera sorts only the
		// splats that reach its view and a margin around it (CULL_MARGIN), so
		// it re-sorts when it has panned through half that margin, or zoomed.
		fwd := linalg.normalize(camera.target - camera.position)
		cull: splatsort.Cull
		resort_move := 0.01 * view.extent
		if game_cam {
			half_h := camera.fovy * 0.5
			half := [2]f32{half_h * aspect, half_h}
			right := linalg.normalize(linalg.cross(fwd, [3]f32{0, 1, 0}))
			up := linalg.cross(right, fwd)
			cull = {enabled = true, centre = camera.target, right = right, up = up, half = half * (1 + CULL_MARGIN)}
			resort_move = 0.5 * CULL_MARGIN * min(half.x, half.y)
		}
		zoomed := game_cam && abs(camera.fovy - last_fovy) > 0.02 * camera.fovy
		if view.count > 0 &&
		   (linalg.dot(fwd, last_fwd) < 0.9995 || zoomed ||
			linalg.vector_length(camera.target - last_target) > resort_move ||
			linalg.vector_length(camera.position - last_pos) > (resort_move if game_cam else 0.01 * view.extent)) {
			t_sort := time.tick_now()
			sort_order(&view, camera.position, fwd, far, cull)
			rl.UpdateTexture(view.order_tex, raw_data(view.order_px))
			bench_sorted(&bench, time.duration_milliseconds(time.tick_since(t_sort)))
			last_fwd, last_pos, last_target, last_fovy = fwd, camera.position, camera.target, camera.fovy
		}

		// ---- pass 1: objects + splats into a transparent, premultiplied target
		show_model := placement.visible && placement_has_objects(&placement)
		show_box := ground_proxy.ok && (ground_proxy.view == .Greybox || ground_proxy.view == .Both)
		show_map := ground_proxy.view == .Map && game_map.ok
		show_splats := view.count > 0 && (ground_proxy.view == .Splats || ground_proxy.view == .Both)
		if show_map do world_map_guard(&game_map, placement.cursor, placement.cursor_ok, camera.target - camera.position)

		rl.BeginTextureMode(rt)
		rl.ClearBackground(rl.BLANK)
		if show_splats || show_model || show_box || show_map || bench.ok {
			rl.BeginMode3D(camera)
			// BeginMode3D builds its projection from raylib's default cull
			// distances; the splat shader uses proj_m. Meshes must use the same
			// one or their depth does not line up with the splats'.
			rlgl.SetMatrixProjection(proj_m)
			// opaque objects first: they write depth, the splats test against them
			if show_model do placement_draw(&placement)
			if show_box do greybox_draw(ground_proxy.box)
			if show_map do world_map_draw(&game_map)
			if bench.ok do bench_draw(&bench, &game_map)
			if show_splats {
				splat_set_frame(&splat, view_m, proj_m, rw, rh, game_cam, cfg.crisp, crisp_alpha)
				drawn := view
				if bench.ok do drawn.visible = bench_visible(&bench, view.visible)
				splat_draw(&splat, drawn, cfg.crisp)
			}
			rl.EndMode3D()
		}
		rl.EndTextureMode()

		// ---- pass 2: resolve to pixel art on the GPU -------------------------
		post_apply(&post, rt.texture, targets.art, targets.w, targets.h, cfg)

		rl.BeginDrawing()
		rl.ClearBackground(rl.BLACK)
		src := rl.Rectangle{0, 0, f32(targets.w), -f32(targets.h)} // render textures are upside down
		dst := rl.Rectangle{0, 0, pic_w, pic_h}
		rl.DrawTexturePro(targets.art.texture, src, dst, {0, 0}, 0, rl.WHITE)
		draw_placement_overlay(&placement, view_m, proj_m, dst.width, dst.height, ground_proxy.t, ground_proxy.ok)

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
		px_per_unit := f32(targets.h) / camera.fovy if game_cam else 0
		draw_model_hud(&placement, model_err, px_per_unit, 10, 98)
		draw_terrain_hud(ground_proxy, &placement, 10, 178)
		draw_level_hud(&lv, dirty, missing, level_cursor_game(&lv, &placement, ground_proxy), 10, 218)
		if ground_proxy.view == .Map do draw_map_hud(&game_map, &lv, 10, 238)
		rl.EndDrawing()
		free_all(context.temp_allocator)
	}

	if bench.seconds > 0 do bench_report(&bench, &game_map)

	// closing with unsaved changes: keep them next to the level
	level_autosave(&lv, &placement, cloud_path, ground_proxy.cell_m, iso)
}

// px_per_unit: art pixels per world unit in the game camera, 0 in the free one
draw_model_hud :: proc(p: ^Placement, err: string, px_per_unit: f32, x, y: i32) {
	info := rl.Color{220, 200, 140, 255}
	keys := rl.Color{160, 160, 160, 255}
	if len(err) > 0 {
		rl.DrawText(fmt.ctprintf("model load failed: %s", err), x, y, 18, {230, 90, 80, 255})
		return
	}
	if len(p.assets) == 0 {
		rl.DrawText("no object: --model file.glb, or drop a .glb", x, y, 16, keys)
		return
	}

	// mode line
	ed := &p.ed
	n := len(ed.instances)
	plural := "" if n == 1 else "s"
	mode: string
	switch ed.mode {
	case .Place:
		a := asset_of(p, ed.preview)
		mode = fmt.tprintf(
			"PLACE %s | click: put one down  Esc: stop | %d object%s%s",
			a.path if a != nil else "?", n, plural, "" if p.cursor_ok else " | cursor off the ground",
		)
	case .Move:
		mode = fmt.tprintf("MOVE #%d | click: put it down  Esc: undo the move | %d object%s", ed.selected, n, plural)
	case .Select:
		sel := fmt.tprintf("#%d selected", ed.selected) if ed.selected != 0 else "nothing selected"
		hover := fmt.tprintf(" | under the cursor: #%d", p.hover) if p.hover != 0 && p.hover != ed.selected else ""
		mode = fmt.tprintf("SELECT | %d object%s, %s%s", n, plural, sel, hover)
	}
	history := fmt.tprintf(" | [ctrl+Z] undo %d  [ctrl+shift+Z] redo %d", editor.can_undo(ed), editor.can_redo(ed))
	rl.DrawText(fmt.ctprintf("%s%s%s", mode, "" if p.visible else " | hidden", history), x, y, 16, {140, 220, 255, 255})

	act := editor.active(ed)
	a: ^Model_Asset
	if act != nil do a = asset_of(p, act^)
	if act == nil || a == nil {
		rl.DrawText(
			fmt.ctprintf("click an object to select it | world %.6f units/m", p.world_scale),
			x, y + 20, 16, info,
		)
	} else {
		t := act.transform
		yaw := editor.wrap_yaw(t.rotation.y) * math.DEG_PER_RAD
		sz := object_size_m(a^, t)
		px := ""
		if px_per_unit > 0 {
			long_px := max(sz.x, sz.z) * p.world_scale * px_per_unit
			px = fmt.tprintf(" | ~%.0f art px long, 1 m = %.1f px", long_px, p.world_scale * px_per_unit)
		}
		other := fmt.tprintf("  [O] next of %d models", len(p.assets)) if len(p.assets) > 1 else ""
		rl.DrawText(
			fmt.ctprintf(
				"%s | %.2f x %.2f x %.2f m (x y z) | scale %.3f | yaw %.0f%s%s",
				a.path, sz.x, sz.y, sz.z, t.scale.x, yaw, px, other,
			),
			x, y + 20, 16, info,
		)
		f := world_fmt(p.world_scale)
		foot_m := max(sz.x, sz.z)
		rl.DrawText(
			fmt.ctprintf(
				"world %.6f units/m | pos %s %s %s | ground %s | grid %v m",
				p.world_scale,
				fmt.tprintf(f, t.position.x), fmt.tprintf(f, t.position.y), fmt.tprintf(f, t.position.z),
				fmt.tprintf(f, act.ground), grid_cell_m(max(foot_m, 1e-3) * 2),
			),
			x, y + 40, 16, info,
		)
	}
	rl.DrawText(
		"click select / place  [A] place  [W] move  [Del] delete  [Esc] cancel | [IJKL] nudge  [Y/H] offset  [,/.] rotate (shift 90)  [N/M] scale  [ctrl+N/M] world  [T] reset  [B] overlay  [V] hide  [F] flags",
		x, y + 60, 16, keys,
	)
}
