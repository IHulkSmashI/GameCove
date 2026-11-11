extends RefCounted
## How big the interface is drawn: one layout pixel = `scale` screen pixels.
##
## The window keeps `canvas_items` stretch; this picks the layout size
## (Window.content_scale_size) from what the screen really is, so text is
## about as readable everywhere:
##
##   handheld panel   the same angle as on a Claw 8 held at 36 cm (REF_ARC),
##                    from the panel's diagonal. A 7" 1080p panel lays out like
##                    a 7" 800p one (same glass, sharper), an 8" 1920x1200 one
##                    at 1536x960, bigger tablets about the same.
##   TV               the 10-foot size: the layout is 800 px tall whatever the
##                    resolution (1080p, 1440p and 4K TVs all show the same
##                    thing, 4K just sharper), like Game Mode on a docked Deck.
##   desk monitor     in between (read from a metre or so).
##   unknown screen   past 1280x800 the scale grows at half the rate.
##
## The layout is never smaller than 1280x800 (MIN_LAYOUT): the screens are
## built for that. It is never wider than MAX_LAYOUT_W by itself either (a big
## desk monitor gets bigger pixels past that, not ever-longer rows), and its
## shape stays between 5:4 and 2:1: an ultrawide (21:9, 32:9) or an unrotated
## portrait screen shows the interface centred with bars, like a console does. "Interface size" (Settings > System) multiplies the
## automatic scale; sizes that would change nothing on this screen aren't
## offered (sizes_for).
##
## Pure functions plus apply(), which main.gd and the installer call when the
## window's size changes; display_output.gd says what the screen is.

const DisplayOutput := preload("res://scripts/system/display_output.gd")

const MIN_LAYOUT := Vector2(1280.0, 800.0)
## The widest layout the automatic scale picks ("Small" may go past it).
const MAX_LAYOUT_W := 1600.0
## Layout shape limits (width / height); outside them the picture is centred with bars.
const MIN_ASPECT := 1.25
const MAX_ASPECT := 2.0
## Angle of one layout pixel, radians: the Claw 8 (8", 1920x1200 at 1.25x,
## 0.112 mm per layout px) at 36 cm. A 12 px label is 12.8 arc minutes tall.
const REF_ARC := 0.112 / 360.0
## The scale moves in steps of this, so layouts land on round sizes.
const STEP := 0.05
const SIZES: Array[String] = ["small", "default", "large", "largest"]
const FACTOR := {"small": 0.85, "default": 1.0, "large": 1.15, "largest": 1.3}
## The smallest text we accept anywhere, as its em height seen from the usual
## distance, in arc minutes (text_arcmin). The 12 px micro label is 13.9 on a
## Steam Deck, 11.7 on a 55" TV from 3 m and 10.1 on a 5.5" 1080p panel (the
## smallest screen in devices.json, already at its largest layout).
const MIN_TEXT_ARCMIN := 9.0


## The largest scale this window allows (the layout stays >= MIN_LAYOUT).
static func max_scale(win: Vector2i) -> float:
	var a := area(win)
	return minf(a.x / MIN_LAYOUT.x, a.y / MIN_LAYOUT.y)


## The part of the window the interface uses, screen pixels: all of it, or a
## centred MAX_ASPECT / MIN_ASPECT box on an ultrawide or portrait window.
static func area(win: Vector2i) -> Vector2:
	var w := float(win.x)
	var h := float(win.y)
	if h <= 0.0:
		return Vector2(w, h)
	if w / h > MAX_ASPECT:
		w = roundf(h * MAX_ASPECT)
	elif w / h < MIN_ASPECT:
		h = roundf(w / MIN_ASPECT)
	return Vector2(w, h)


## True when area() is smaller than the window (bars show).
static func boxed(win: Vector2i) -> bool:
	return Vector2i(area(win)) != win


## Typical eye-to-screen distance, mm.
static func viewing_mm(kind: String, diagonal_in: float) -> float:
	match kind:
		"tv":
			return maxf(1500.0, diagonal_in * 25.4 * 2.15)   # 55" -> 3 m
		"monitor":
			return 1200.0   # controller in hand, leaning back from the desk
	return clampf(45.0 * diagonal_in, 350.0, 700.0)   # 7" -> 35 cm, 8" -> 36 cm, 14" -> 63 cm


## Millimetres per pixel of a screen `diagonal_in` across showing `pixels`
## (the window's own size when it fills the screen, as in Game Mode).
static func pitch_mm(pixels: Vector2i, diagonal_in: float) -> float:
	var px := Vector2(pixels).length()
	return diagonal_in * 25.4 / px if px > 0.0 and diagonal_in > 0.0 else 0.0


## The pixels the whole screen shows: `screen.pixels` when the window doesn't
## fill it (the installer on the desktop), else the window's.
static func _pixels(win: Vector2i, screen: Dictionary) -> Vector2i:
	var p: Variant = screen.get("pixels")
	return p if p is Vector2i and p.x > 0 and p.y > 0 else win


## The automatic scale for a window on `screen`
## ({kind: "handheld" | "monitor" | "tv" | "", diagonal_in: float}).
static func auto_scale(win: Vector2i, screen: Dictionary) -> float:
	var top := max_scale(win)
	var kind := str(screen.get("kind", ""))
	var diag := float(screen.get("diagonal_in", 0.0))
	var s := 1.0
	if kind == "tv":
		s = top
	elif kind in ["handheld", "monitor"] and diag > 0.0:
		s = REF_ARC * viewing_mm(kind, diag) / pitch_mm(_pixels(win, screen), diag)
	else:
		s = 1.0 + (top - 1.0) * 0.5 if top > 1.0 else top
	# never a layout wider than MAX_LAYOUT_W by itself
	s = maxf(s, area(win).x / MAX_LAYOUT_W)
	return _fit(s, top, kind == "tv")


## Snapped to STEP and kept inside what the window allows. `keep_top`: don't
## snap away from the largest scale (a TV sits exactly on it).
static func _fit(s: float, top: float, keep_top := false, low := 1.0) -> float:
	if keep_top or s >= top:
		return top
	var snapped := roundf(s / STEP) * STEP
	return clampf(snapped, minf(low, top), top)


## The scale with the player's "Interface size" applied.
static func scale_for(win: Vector2i, screen: Dictionary, size_id := "default") -> float:
	var auto := auto_scale(win, screen)
	var f: float = FACTOR.get(size_id, 1.0)
	if is_equal_approx(f, 1.0):
		return auto
	return _fit(auto * f, max_scale(win), false, minf(auto, 1.0) * 0.85)


## Window.content_scale_size for this window, screen and size.
static func layout_for(win: Vector2i, screen: Dictionary, size_id := "default") -> Vector2i:
	var s := scale_for(win, screen, size_id)
	if s <= 0.0:
		return Vector2i(MIN_LAYOUT)
	var a := area(win)
	return Vector2i(maxi(roundi(a.x / s), int(MIN_LAYOUT.x)), maxi(roundi(a.y / s), int(MIN_LAYOUT.y)))


## The sizes that look different from each other on this screen, smallest first
## (always has "default"). A Steam Deck is already at its largest layout, so
## Large and Largest aren't offered there.
static func sizes_for(win: Vector2i, screen: Dictionary) -> Array[String]:
	var out: Array[String] = []
	var seen := {}
	# "default" first so it wins a tie, then the rest
	for id in ["default", "small", "large", "largest"]:
		var key := snappedf(scale_for(win, screen, id), 0.001)
		if not seen.has(key):
			seen[key] = true
			out.append(id)
	out.sort_custom(func(a, b): return SIZES.find(a) < SIZES.find(b))
	return out


## Height of `font_px` layout pixels as seen from the usual distance, arc
## minutes; -1 when the screen's size isn't known.
static func text_arcmin(font_px: float, scale: float, win: Vector2i, screen: Dictionary) -> float:
	var diag := float(screen.get("diagonal_in", 0.0))
	if diag <= 0.0:
		return -1.0
	var mm := font_px * scale * pitch_mm(_pixels(win, screen), diag)
	return rad_to_deg(mm / viewing_mm(str(screen.get("kind", "")), diag)) * 60.0


# ---- applying it ---------------------------------------------------------------

## Tests and the screenshot tools say what the screen is ({kind, diagonal_in});
## empty = ask the system.
static var override_screen: Dictionary = {}
## The screen apply() last used and the scale it gave (About, tests).
static var last_screen: Dictionary = {}
static var last_scale := 1.0


## What the window is shown on. `device` is the Device autoload (or null).
static func screen_for(device: Object, window_fills_screen := true) -> Dictionary:
	if not override_screen.is_empty():
		return override_screen
	var root := ""
	var panel: Variant = null
	var boxed := false
	if device != null:
		root = str(device.get("root"))
		var prof: Variant = device.get("profile")
		if prof is Dictionary:
			panel = prof.get("panel")
		if device.has_method("is_handheld"):
			boxed = not device.is_handheld()
	var scr := DisplayOutput.current(root, panel, boxed)
	if not window_fills_screen and DisplayServer.get_name() != "headless":
		scr["pixels"] = DisplayServer.screen_get_size()
	return scr


## Tests say how big the window is (the headless display has no real window
## size); the layout is then exactly layout_for() of it. (0, 0) = the window's own.
static var override_window := Vector2i.ZERO


## The window's size in screen pixels (override_window under tests).
static func window_size(w: Window) -> Vector2i:
	return override_window if override_window != Vector2i.ZERO else w.size


## Sets the window's layout size from its real size, the screen and the
## player's Interface size. Returns true when the layout changed.
static func apply(w: Window, device: Object, size_id := "default", window_fills_screen := true) -> bool:
	if w == null or w.content_scale_mode == Window.CONTENT_SCALE_MODE_DISABLED:
		return false
	var win := window_size(w)
	last_screen = screen_for(device, window_fills_screen)
	last_scale = scale_for(win, last_screen, size_id)
	var next := layout_for(win, last_screen, size_id)
	if override_window != Vector2i.ZERO:
		w.content_scale_aspect = Window.CONTENT_SCALE_ASPECT_IGNORE
	else:
		# "keep" centres the layout and adds the bars; "expand" everywhere else
		w.content_scale_aspect = Window.CONTENT_SCALE_ASPECT_KEEP if boxed(win) else Window.CONTENT_SCALE_ASPECT_EXPAND
	if w.content_scale_size == next:
		return false
	w.content_scale_size = next
	return true
