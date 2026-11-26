package main

// The editor's UI: microui panels (panels.odin) drawn with raylib in
// JetBrains Mono. The adapter follows algo-boyz/odins-raylib's rlmu
// (2D/gui/microui/rlmu): raylib's input into microui, microui's commands out
// to raylib. Text is a TTF font, not microui's built-in atlas font; the atlas
// is still used for microui's icons (close, check, expand).
//
//   F1   hide / show the UI (screenshots, the bench)
//
// While the mouse is over a panel, or a slider is being dragged, the scene
// leaves the mouse alone (ui_has_mouse): no placing, picking, panning or
// zooming through a panel.
//
// Buttons press the same shortcuts as the keys (ui_press, ui_key), so an
// action has one code path whichever way it was asked for.

import "core:math"
import "core:strings"
import "core:unicode/utf8"

import mu "vendor:microui"
import rl "vendor:raylib"

UI_FONT_TTF :: #load("assets/fonts/JetBrainsMono-Regular.ttf") // OFL, assets/fonts/OFL.txt
UI_TEXT     :: 15 // text size, screen pixels
UI_RASTER   :: 2  // the font is rasterised this many times larger and drawn down, so it stays crisp when scaled

// The characters loaded from the font: ASCII and what the panels print.
UI_EXTRA_RUNES :: "°²×·–—…→←↑↓±≈"

Ui_Press :: struct {
	key: rl.KeyboardKey,
	cmd: bool,
}

Ui :: struct {
	ctx:     ^mu.Context,
	atlas:   rl.Texture2D, // microui's icons
	font:    rl.Font,
	visible: bool,
	mouse:   bool,         // the mouse is on a panel (set at the end of the last frame)
	scene_drag: bool,      // a button went down off the panels and is still down: the scene keeps it
	now:     [8]Ui_Press,  // pressed by a button last frame, read this frame
	n_now:   int,
	next:    [8]Ui_Press,  // pressed this frame
	n_next:  int,
}

ui_init :: proc(ui: ^Ui) {
	ui.ctx = new(mu.Context)
	mu.init(ui.ctx, ui_set_clipboard, ui_get_clipboard)

	// the icons from microui's atlas, as white with alpha
	pixels := make([][4]u8, mu.DEFAULT_ATLAS_WIDTH * mu.DEFAULT_ATLAS_HEIGHT)
	defer delete(pixels)
	for alpha, i in mu.default_atlas_alpha do pixels[i] = {255, 255, 255, alpha}
	image := rl.Image{
		data = raw_data(pixels), width = mu.DEFAULT_ATLAS_WIDTH, height = mu.DEFAULT_ATLAS_HEIGHT,
		format = .UNCOMPRESSED_R8G8B8A8, mipmaps = 1,
	}
	ui.atlas = rl.LoadTextureFromImage(image)

	runes := make([dynamic]rune, context.temp_allocator)
	for r in 32 ..= 126 do append(&runes, rune(r))
	for r in UI_EXTRA_RUNES do append(&runes, r)
	data := UI_FONT_TTF
	ui.font = rl.LoadFontFromMemory(".ttf", raw_data(data), i32(len(data)), UI_TEXT * UI_RASTER, raw_data(runes), i32(len(runes)))
	rl.GenTextureMipmaps(&ui.font.texture)
	rl.SetTextureFilter(ui.font.texture, .TRILINEAR)

	ui.ctx.text_width = ui_text_width
	ui.ctx.text_height = ui_text_height
	ui.ctx.style.font = mu.Font(&ui.font)
	ui_style(ui.ctx.style)
	ui.visible = true
}

ui_destroy :: proc(ui: ^Ui) {
	rl.UnloadFont(ui.font)
	rl.UnloadTexture(ui.atlas)
	free(ui.ctx)
	ui^ = {}
}

// Dark, a little see-through, so the level shows behind.
ui_style :: proc(s: ^mu.Style) {
	s.size = {64, UI_TEXT + 6}
	s.padding = 6
	s.spacing = 4
	s.indent = 14
	s.title_height = UI_TEXT + 10
	s.footer_height = 0
	s.scrollbar_size = 10
	s.thumb_size = 8
	c := &s.colors
	c[.TEXT]         = {222, 224, 228, 255}
	c[.SELECTION_BG] = {90, 110, 150, 255}
	c[.BORDER]       = {18, 19, 22, 255}
	c[.WINDOW_BG]    = {26, 27, 32, 225}
	c[.TITLE_BG]     = {38, 41, 50, 245}
	c[.TITLE_TEXT]   = {240, 241, 244, 255}
	c[.PANEL_BG]     = {0, 0, 0, 0}
	c[.BUTTON]       = {52, 56, 68, 255}
	c[.BUTTON_HOVER] = {70, 76, 94, 255}
	c[.BUTTON_FOCUS] = {92, 100, 124, 255}
	c[.BASE]         = {36, 38, 46, 255}
	c[.BASE_HOVER]   = {44, 47, 57, 255}
	c[.BASE_FOCUS]   = {50, 54, 66, 255}
	c[.SCROLL_BASE]  = {36, 38, 46, 255}
	c[.SCROLL_THUMB] = {72, 76, 92, 255}
}

ui_text_width :: proc(font: mu.Font, str: string) -> i32 {
	f := (^rl.Font)(rawptr(font))
	if f == nil || len(str) == 0 do return 0
	cs := strings.clone_to_cstring(str, context.temp_allocator)
	return i32(math.ceil(rl.MeasureTextEx(f^, cs, UI_TEXT, 0).x))
}

ui_text_height :: proc(font: mu.Font) -> i32 {
	return UI_TEXT
}

// Frame start: the presses buttons made last frame become this frame's, the
// input goes to microui, and microui starts collecting the panels.
ui_begin :: proc(ui: ^Ui) {
	ui.now, ui.n_now = ui.next, ui.n_next
	ui.n_next = 0
	if rl.IsKeyPressed(.F1) do ui.visible = !ui.visible
	pressed := rl.IsMouseButtonPressed(.LEFT) || rl.IsMouseButtonPressed(.RIGHT) || rl.IsMouseButtonPressed(.MIDDLE)
	down := rl.IsMouseButtonDown(.LEFT) || rl.IsMouseButtonDown(.RIGHT) || rl.IsMouseButtonDown(.MIDDLE)
	if pressed do ui.scene_drag = !ui.mouse
	if !down do ui.scene_drag = false
	ui_forward_input(ui)
	mu.begin(ui.ctx)
}

// Frame end, between EndMode3D and EndDrawing: draws what the panels made
// and notes whether the UI has the mouse for next frame.
ui_end :: proc(ui: ^Ui) {
	mu.end(ui.ctx)
	ctx := ui.ctx
	ui.mouse = ui.visible && (ctx.hover_root != nil || (ctx.focus_id != 0 && ctx.mouse_down_bits != {}))

	cmd: ^mu.Command
	for variant in mu.next_command_iterator(ctx, &cmd) {
		switch c in variant {
		case ^mu.Command_Text:
			cs := strings.clone_to_cstring(c.str, context.temp_allocator)
			rl.DrawTextEx(ui.font, cs, {f32(c.pos.x), f32(c.pos.y)}, UI_TEXT, 0, transmute(rl.Color)c.color)
		case ^mu.Command_Rect:
			rl.DrawRectangle(c.rect.x, c.rect.y, c.rect.w, c.rect.h, transmute(rl.Color)c.color)
		case ^mu.Command_Icon:
			r := mu.default_atlas[c.id]
			x := c.rect.x + (c.rect.w - r.w) / 2
			y := c.rect.y + (c.rect.h - r.h) / 2
			rl.DrawTextureRec(ui.atlas, {f32(r.x), f32(r.y), f32(r.w), f32(r.h)}, {f32(x), f32(y)}, transmute(rl.Color)c.color)
		case ^mu.Command_Clip:
			rl.EndScissorMode()
			rl.BeginScissorMode(c.rect.x, c.rect.y, c.rect.w, c.rect.h)
		case ^mu.Command_Jump:
		}
	}
	rl.EndScissorMode()
}

// The scene may use the mouse.
ui_has_mouse :: proc(ui: ^Ui) -> bool {
	return ui.mouse && !ui.scene_drag
}

// A button pressing a shortcut, for next frame.
ui_press :: proc(ui: ^Ui, key: rl.KeyboardKey, cmd := false) {
	if ui.n_next < len(ui.next) {
		ui.next[ui.n_next] = {key, cmd}
		ui.n_next += 1
	}
}

cmd_down :: proc() -> bool {
	return rl.IsKeyDown(.LEFT_CONTROL) || rl.IsKeyDown(.RIGHT_CONTROL) || rl.IsKeyDown(.LEFT_SUPER) || rl.IsKeyDown(.RIGHT_SUPER)
}

// The shortcut was pressed, on the keyboard (with ctrl / cmd held or not, as
// `cmd` says) or by a button.
ui_key :: proc(ui: ^Ui, key: rl.KeyboardKey, cmd := false) -> bool {
	if rl.IsKeyPressed(key) && cmd_down() == cmd do return true
	for p in ui.now[:ui.n_now] do if p.key == key && p.cmd == cmd do return true
	return false
}

// Text drawn outside the panels (labels in the scene, the message line).
ui_text :: proc(ui: ^Ui, text: string, x, y: f32, color: rl.Color, shadow := true) {
	cs := strings.clone_to_cstring(text, context.temp_allocator)
	if shadow do rl.DrawTextEx(ui.font, cs, {x + 1, y + 1}, UI_TEXT, 0, {0, 0, 0, 160})
	rl.DrawTextEx(ui.font, cs, {x, y}, UI_TEXT, 0, color)
}

ui_measure :: proc(ui: ^Ui, text: string) -> f32 {
	cs := strings.clone_to_cstring(text, context.temp_allocator)
	return rl.MeasureTextEx(ui.font, cs, UI_TEXT, 0).x
}

@(private = "file")
ui_forward_input :: proc(ui: ^Ui) {
	ctx := ui.ctx
	// typed text (no text fields yet, but microui wants it)
	buf: [128]u8
	n := 0
	for n < len(buf) - 4 {
		r := rl.GetCharPressed()
		if r == 0 do break
		b, k := utf8.encode_rune(r)
		copy(buf[n:], b[:k])
		n += k
	}
	mu.input_text(ctx, string(buf[:n]))

	pos := rl.GetMousePosition()
	x, y := i32(pos.x), i32(pos.y)
	mu.input_mouse_move(ctx, x, y)
	wheel := rl.GetMouseWheelMoveV()
	mu.input_scroll(ctx, i32(wheel.x * -30), i32(wheel.y * -30))
	Button :: struct {
		rl: rl.MouseButton,
		mu: mu.Mouse,
	}
	for b in ([?]Button{{.LEFT, .LEFT}, {.RIGHT, .RIGHT}, {.MIDDLE, .MIDDLE}}) {
		if rl.IsMouseButtonPressed(b.rl) do mu.input_mouse_down(ctx, x, y, b.mu)
		if rl.IsMouseButtonReleased(b.rl) do mu.input_mouse_up(ctx, x, y, b.mu)
	}
	Key :: struct {
		rl: rl.KeyboardKey,
		mu: mu.Key,
	}
	for k in ([?]Key{
		{.LEFT_SHIFT, .SHIFT}, {.RIGHT_SHIFT, .SHIFT}, {.LEFT_CONTROL, .CTRL}, {.RIGHT_CONTROL, .CTRL},
		{.LEFT_ALT, .ALT}, {.RIGHT_ALT, .ALT}, {.ENTER, .RETURN}, {.BACKSPACE, .BACKSPACE},
	}) {
		if rl.IsKeyPressed(k.rl) do mu.input_key_down(ctx, k.mu)
		if rl.IsKeyReleased(k.rl) do mu.input_key_up(ctx, k.mu)
	}
}

@(private = "file")
ui_set_clipboard :: proc(user_data: rawptr, text: string) -> bool {
	rl.SetClipboardText(strings.clone_to_cstring(text, context.temp_allocator))
	return true
}

@(private = "file")
ui_get_clipboard :: proc(user_data: rawptr) -> (string, bool) {
	cs := rl.GetClipboardText()
	if cs == nil do return "", false
	return strings.clone_from_cstring(cs, context.temp_allocator), true
}
