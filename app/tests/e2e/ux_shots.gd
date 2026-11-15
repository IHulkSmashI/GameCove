extends RefCounted
## One picture per press (tools/ux_walk/sheets.sh): when E2E_SHOTS names a
## folder, every input a journey sends (pad button, stick, the handheld's own
## buttons, touch, a held button) is followed by a picture of the screen as the
## player sees it after that press, saved as
## E2E_SHOTS/<suite>__<test>/<number>_<what was pressed>.png. Needs a real
## renderer (sheets.sh starts the run under Xvfb); off, and free, everywhere
## else: the e2e suites run headless and never set it.

## How long the screen is left to settle after a press before its picture
## (focus glides, sheets slide in): our UI animations are 0.18 s at most.
const SETTLE_S := 0.3

const BUTTONS := {
	JOY_BUTTON_A: "A", JOY_BUTTON_B: "B", JOY_BUTTON_X: "X", JOY_BUTTON_Y: "Y",
	JOY_BUTTON_DPAD_UP: "Up", JOY_BUTTON_DPAD_DOWN: "Down", JOY_BUTTON_DPAD_LEFT: "Left", JOY_BUTTON_DPAD_RIGHT: "Right",
	JOY_BUTTON_LEFT_SHOULDER: "LB", JOY_BUTTON_RIGHT_SHOULDER: "RB", JOY_BUTTON_START: "Menu", JOY_BUTTON_BACK: "View",
	JOY_BUTTON_GUIDE: "Guide", JOY_BUTTON_LEFT_STICK: "L3", JOY_BUTTON_RIGHT_STICK: "R3",
}
const AXES := {
	JOY_AXIS_LEFT_X: "Stick", JOY_AXIS_LEFT_Y: "Stick", JOY_AXIS_RIGHT_X: "RStick", JOY_AXIS_RIGHT_Y: "RStick",
	JOY_AXIS_TRIGGER_LEFT: "LT", JOY_AXIS_TRIGGER_RIGHT: "RT",
}

static var dir := OS.get_environment("E2E_SHOTS")
static var _count := {}


static func on() -> bool:
	return dir != ""


## The name a pad button's picture carries ("A", "Down", "LB").
static func button_name(b: int) -> String:
	return BUTTONS.get(b, "Button%d" % b)


## The name a stick push or trigger pull carries ("Stick-Left", "LT").
static func axis_name(axis: int, value: float) -> String:
	var n: String = AXES.get(axis, "Axis%d" % axis)
	if axis == JOY_AXIS_TRIGGER_LEFT or axis == JOY_AXIS_TRIGGER_RIGHT:
		return n
	var horizontal := axis == JOY_AXIS_LEFT_X or axis == JOY_AXIS_RIGHT_X
	return n + "-" + (("Right" if value > 0.0 else "Left") if horizontal else ("Down" if value > 0.0 else "Up"))


## The folder a test's pictures go in: "suite_journeys::test_x" -> "suite_journeys__test_x".
static func folder(test: String) -> String:
	return test.replace("::", "__").validate_filename()


## The file name of picture number `n` of a test, after `what` was pressed.
static func file_name(n: int, what: String) -> String:
	return "%04d_%s.png" % [n, what.validate_filename().replace(" ", "-")]


## Saves the screen after `what` was pressed in `test`. Does nothing unless
## E2E_SHOTS is set.
static func take(tree: SceneTree, test: String, what: String) -> void:
	if not on() or tree == null:
		return
	await tree.create_timer(SETTLE_S).timeout
	# drawn now, not "after the next frame": the app only draws when something changed (low-processor
	# mode), so a press that changes nothing on screen would wait for a frame that never comes
	RenderingServer.force_draw()
	var img := tree.root.get_texture().get_image()
	if img == null or img.is_empty():
		return
	var d := dir.path_join(folder(test))
	DirAccess.make_dir_recursive_absolute(d)
	var n := int(_count.get(test, 0)) + 1
	_count[test] = n
	img.save_png(d.path_join(file_name(n, what)))
