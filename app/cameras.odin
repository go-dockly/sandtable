package main

import "core:math"
import "core:math/linalg"
import rl "vendor:raylib"

// ---------------------------------------------------------------------------
// Game camera: isometric and orthographic, the Commandos view.
//
// Starts at the azimuth/elevation of algo-boyz/commandos camera/isometric.odin.
// The 38 degree tilt is fixed; the view turns around the vertical axis (left-drag,
// sideways swipe, arrow keys for 90 degree steps). Pan: shift+left, right or
// middle drag. R snaps back to 45 degrees.
// It is a separate implementation on purpose: that camera's rebuild() has a
// 30-unit minimum distance and a 10-70 view-height clamp tuned for game metres,
// which would clip a splat capture of arbitrary scale. Here everything scales
// with the cloud's extent.
//
// Two things differ from the commandos pan code, both by my reading of it (not
// run): it scales horizontal pan by the aspect ratio, and it does not divide
// vertical pan by sin(elevation). Either makes the ground drift away from the
// cursor while dragging, so the pan below uses 1 world-unit-per-pixel on screen
// and corrects the vertical term for the tilt.
// ---------------------------------------------------------------------------

ISO_AZIMUTH   :: f32(45)
ISO_ELEVATION :: f32(38)

Iso :: struct {
	target:      [3]f32,
	azimuth:     f32, // degrees
	elevation:   f32, // degrees
	view_height: f32, // world units the window shows vertically: the zoom
	min_height:  f32, // set every frame: the level's zoom-in end
	max_height:  f32,
	framed_height: f32, // view_height when framed: the default pixel section's scale
	distance:    f32, // camera to target; only sets where the near/far planes sit
	dragging:    bool,
	prev_mouse:  rl.Vector2,
}

// Fit a cloud: `extent` is its largest robust dimension (see robust_bounds).
iso_frame :: proc(c: ^Iso, center: [3]f32, extent: f32) {
	e := extent if extent > 1e-4 else 1
	c.target = center
	c.azimuth, c.elevation = ISO_AZIMUTH, ISO_ELEVATION
	// a cube of side e projects to about 1.66 e tall at 38 degrees elevation
	c.view_height = e * 1.7
	c.min_height = e * 0.15
	c.max_height = e * 4
	c.framed_height = c.view_height
	c.distance = e * 6
}

iso_camera :: proc(c: Iso) -> rl.Camera3D {
	az := c.azimuth * math.RAD_PER_DEG
	el := c.elevation * math.RAD_PER_DEG
	horizontal := c.distance * math.cos(el)
	return rl.Camera3D{
		position = c.target + {horizontal * math.sin(az), c.distance * math.sin(el), horizontal * math.cos(az)},
		target = c.target,
		up = {0, 1, 0},
		fovy = c.view_height, // main replaces it with the art target's height
		projection = .ORTHOGRAPHIC,
	}
}

ISO_DEG_PER_PX    :: f32(0.3) // drag rotation, ~0.005 rad/px like update_orbit
ISO_DEG_PER_WHEEL :: f32(6)   // horizontal two-finger swipe rotation

// screen_h: height of the window in screen pixels
// left_drag: the left press has become a drag (editor.Click). Until then it
// may be a click that places or selects, and the view must not jiggle.
//
// Elevation stays at the Commandos tilt; only the azimuth turns.
//   left-drag                       rotate around the vertical axis
//   shift+left / right / middle-drag pan
//   vertical scroll                 zoom
//   horizontal two-finger swipe     rotate
//   Left / Right arrow              rotate by 90 degrees
// use_mouse: false while the mouse is on the UI's panels.
iso_update :: proc(c: ^Iso, screen_h: f32, left_drag: bool, use_mouse := true) {
	// raylib's GetMouseWheelMove returns whichever axis is larger, so on a
	// trackpad a sideways swipe used to zoom. Split the axes.
	wheel := rl.GetMouseWheelMoveV() if use_mouse else {}
	if wheel.y != 0 {
		c.view_height = clamp(c.view_height * (1 - wheel.y * 0.1), c.min_height, c.max_height)
	}
	if wheel.x != 0 {
		c.azimuth += wheel.x * ISO_DEG_PER_WHEEL
	}
	if rl.IsKeyPressed(.LEFT) do c.azimuth -= 90
	if rl.IsKeyPressed(.RIGHT) do c.azimuth += 90

	shift := rl.IsKeyDown(.LEFT_SHIFT) || rl.IsKeyDown(.RIGHT_SHIFT)
	left := rl.IsMouseButtonDown(.LEFT)
	pan := use_mouse && ((shift && left) || rl.IsMouseButtonDown(.RIGHT) || rl.IsMouseButtonDown(.MIDDLE))
	rotate := use_mouse && left && !shift && left_drag

	if pan || rotate {
		mouse := rl.GetMousePosition()
		if c.dragging {
			delta := mouse - c.prev_mouse
			if pan {
				per_px := c.view_height / max(screen_h, 1)
				az := c.azimuth * math.RAD_PER_DEG
				el := c.elevation * math.RAD_PER_DEG
				right := [3]f32{math.cos(az), 0, -math.sin(az)}
				forward := [3]f32{-math.sin(az), 0, -math.cos(az)}
				c.target += right * (-delta.x * per_px) + forward * (delta.y * per_px / math.sin(el))
			} else {
				c.azimuth -= delta.x * ISO_DEG_PER_PX
			}
		}
		c.prev_mouse = mouse
		c.dragging = true
	} else {
		c.dragging = false
	}

	c.azimuth = math.mod(c.azimuth, 360)
}

// ---------------------------------------------------------------------------
// Free orbit camera (perspective), for inspecting a cloud. Unchanged from
// ospz/viewer/main.odin.
// ---------------------------------------------------------------------------

frame_camera :: proc(camera: ^rl.Camera3D, v: Splat_View) {
	dist := v.extent * 1.6
	if dist < 0.5 do dist = 2
	camera^ = {
		position   = v.center + {dist, dist * 0.45, dist},
		target     = v.center,
		up         = {0, 1, 0},
		fovy       = 40,
		projection = .PERSPECTIVE,
	}
}

// left_drag: as iso_update, orbit only once a left press is a drag
update_orbit :: proc(c: ^rl.Camera3D, left_drag: bool, use_mouse := true) {
	if !use_mouse do return
	d := c.position - c.target
	dist := linalg.vector_length(d)
	yaw := math.atan2(d.x, d.z)
	pitch := math.asin(clamp(d.y / dist, -1, 1))

	if rl.IsMouseButtonDown(.LEFT) && left_drag {
		m := rl.GetMouseDelta()
		yaw -= m.x * 0.005
		pitch = clamp(pitch + m.y * 0.005, -1.5, 1.5)
	}
	dist = max(dist * (1 - rl.GetMouseWheelMoveV().y * 0.1), 0.01) // y only: sideways trackpad swipes must not zoom

	c.position = c.target + dist * [3]f32{
		math.cos(pitch) * math.sin(yaw),
		math.sin(pitch),
		math.cos(pitch) * math.cos(yaw),
	}
}
