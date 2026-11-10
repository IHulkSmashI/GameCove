extends "res://tests/test_case.gd"
## Review 3, low 7: full-screen overlays that say they never block input must
## let taps through: the wake fade (it swallowed the first tap for 0.6 s), toasts,
## the boot splash on its way out and the launch overlay on its way out.

const Main := preload("res://scripts/main.gd")
const Toast := preload("res://scripts/ui/toast.gd")
const LaunchOverlay := preload("res://scripts/ui/launch_overlay.gd")
const BootSplash := preload("res://scripts/ui/boot_splash.gd")


## Controls under `n` (and `n`) that would take a mouse event.
static func blocking(n: Node) -> Array:
	var out := []
	if n is Control and (n as Control).mouse_filter != Control.MOUSE_FILTER_IGNORE:
		out.append(String(n.name) + " (" + n.get_class() + ")")
	for k in n.get_children():
		out.append_array(blocking(k))
	return out


func test_wake_shade_lets_taps_through() -> void:
	var src := FileAccess.get_file_as_string("res://scripts/main.gd")
	var at := src.find("_wake_shade = ColorRect.new()")
	ok(at > 0, "the wake shade is built in main.gd")
	var block := src.substr(at, src.find("add_child(_wake_shade)", at) - at)
	ok("_wake_shade.mouse_filter = Control.MOUSE_FILTER_IGNORE" in block, "WakeShade ignores the mouse")


func test_toasts_never_take_a_tap() -> void:
	var t: VBoxContainer = Toast.new()
	t.show_toast("Freed 2 GB", "check", "good", "two leftovers")
	eq(blocking(t), [], "toast stack, panel, icon, labels: all let taps through")
	t.free()


func test_launch_overlay_lets_taps_through_on_its_way_out() -> void:
	var o: Control = LaunchOverlay.new()
	eq(o.mouse_filter, Control.MOUSE_FILTER_STOP, "while it's up it takes the taps itself")
	var parts := []
	for k in o.get_children():
		parts.append_array(blocking(k))
	eq(parts, [], "its pieces never do (so IGNORE on the way out means taps go through)")
	o.free()


func test_boot_splash_pieces_never_take_a_tap() -> void:
	var s: Control = BootSplash.new()
	eq(blocking(s), [], "the splash and everything in it let taps through (a press skips it through _input)")
	s.free()
