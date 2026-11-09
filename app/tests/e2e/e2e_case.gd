extends "res://tests/test_case.gd"
## Base for end-to-end suites (tests/e2e/suite_*.gd): eq()/ok() from
## test_case.gd plus a player's hands on the real app. Tests may await.
##
## UI is addressed by stable names only: Control ids (a ControlView's `key`),
## node names the quick menu documents (UseGame, ResetGame, ExitGame,
## DesktopMode, SteamMode, AllSettings), tab ids (TC.TAB_IDS), Settings
## category ids and the Controls / Profiles APIs. Never positions or layout.

const TC := preload("res://scripts/ui/texts_controls.gd")
const Matrix := preload("res://tests/devicematrix/matrix.gd")
const Buttons := preload("res://scripts/device/buttons.gd")

var w: RefCounted   # world.gd


# ---- services ------------------------------------------------------------------

func main() -> Control:
	return w.main


func qm() -> Control:
	return w.main.quick_menu


func controls() -> Node:
	return w.autoload("Controls")


func profiles() -> Node:
	return w.autoload("Profiles")


func power() -> Node:
	return w.autoload("Power")


func ctl(id: String) -> RefCounted:
	return controls().control(id)


func available(id: String) -> bool:
	var c := ctl(id)
	return c != null and c.available


func device_id() -> String:
	return str(w.info["expect_row"])


func setup_name() -> String:
	return w.setup_name


# ---- input --------------------------------------------------------------------

func _send(e: InputEvent) -> void:
	# Input.parse_input_event() drops events on the headless display server (it has
	# no window to dispatch to); the root viewport takes them the same way a window
	# would hand them over, and Input's action state follows.
	Input.parse_input_event(e)
	w.tree.root.push_input(e)


## One press and release of a pad button (JOY_BUTTON_*), as the pad sends it.
func press(button: JoyButton, frames_down := 1) -> void:
	var e := InputEventJoypadButton.new()
	e.device = 0
	e.button_index = button
	e.pressed = true
	e.pressure = 1.0
	_send(e)
	await w.frames(frames_down)
	var u := InputEventJoypadButton.new()
	u.device = 0
	u.button_index = button
	u.pressed = false
	_send(u)
	await w.frames(1)


func a() -> void:
	await press(JOY_BUTTON_A)


func b() -> void:
	await press(JOY_BUTTON_B)


func up() -> void:
	await press(JOY_BUTTON_DPAD_UP)


func down() -> void:
	await press(JOY_BUTTON_DPAD_DOWN)


func left() -> void:
	await press(JOY_BUTTON_DPAD_LEFT)


func right() -> void:
	await press(JOY_BUTTON_DPAD_RIGHT)


func lb() -> void:
	await press(JOY_BUTTON_LEFT_SHOULDER)


func rb() -> void:
	await press(JOY_BUTTON_RIGHT_SHOULDER)


## A stick push past the threshold and back (JOY_AXIS_*), like a flick.
func stick(axis: JoyAxis, value: float) -> void:
	var e := InputEventJoypadMotion.new()
	e.device = 0
	e.axis = axis
	e.axis_value = value
	_send(e)
	await w.frames(1)
	var z := InputEventJoypadMotion.new()
	z.device = 0
	z.axis = axis
	z.axis_value = 0.0
	_send(z)
	await w.frames(1)


## The handheld's own button for a GameCove action ("home" | "quick_menu"),
## the way InputPlumber's intercept delivers it: a D-Bus InputEvent line into
## Controller -> intercept.gd -> Controller.ui_action -> main.on_ui_action.
func special(action: String) -> void:
	var ev := dbus_event_for(action)
	var path := "/org/shadowblip/InputPlumber/CompositeDevice0"
	var c: Node = w.autoload("Controller")
	c.monitor_line({"kind": "event", "path": path, "event": ev, "value": 1.0})
	await w.frames(1)
	c.monitor_line({"kind": "event", "path": path, "event": ev, "value": 0.0})
	await w.frames(2)


func guide() -> void:
	await special("home")


func qam() -> void:
	await special("quick_menu")


## The D-Bus event name this handheld sends for `action` (Buttons tables).
func dbus_event_for(action: String) -> String:
	for ev in Buttons.DBUS_EVENTS:
		if Buttons.action_for_dbus(device_id(), ev) == action:
			return ev
	return "ui_guide" if action == "home" else "ui_quick"


func focus() -> Control:
	return w.tree.root.gui_get_focus_owner()


# ---- the quick menu -------------------------------------------------------------

## The quick menu open on tab `tab` (TC.TAB_IDS id), reached with LB / RB.
func open_menu_tab(tab: String) -> bool:
	if not qm().visible:
		await qam()
	if not qm().visible:
		return false
	var want := TC.TAB_IDS.find(tab)
	var guard := 0
	while qm().section != want and guard < 12:
		await rb()
		guard += 1
	await w.frames(2)
	return qm().section == want


## The ControlView for `id` inside `under` (quick menu body or a Settings page), or null.
func view(id: String, under: Node = null) -> Node:
	var start: Node = under if under != null else qm().body
	return _find_view(start, id)


static func _find_view(n: Node, id: String) -> Node:
	if n.has_method("explanation") and "key" in n and str(n.get("key")) == id:
		return n
	for c in n.get_children():
		var r := _find_view(c, id)
		if r != null:
			return r
	return null


## Moves focus with D-pad down until it is inside `node` (max `limit` presses).
func focus_on(node: Node, limit := 60) -> bool:
	for i in limit:
		var f := focus()
		if f != null and (f == node or node.is_ancestor_of(f)):
			return true
		await down()
	var f2 := focus()
	return f2 != null and (f2 == node or node.is_ancestor_of(f2))


## Ids of every ControlView reachable by D-pad in the open tab, in focus order.
func reachable_ids(limit := 80) -> Array:
	var out := []
	var seen := {}
	for i in limit:
		var f := focus()
		if f == null:
			break
		if seen.has(f):
			break
		seen[f] = true
		var n: Node = f
		while n != null and n != w.main:
			if n.has_method("explanation") and "key" in n:
				if not out.has(str(n.get("key"))):
					out.append(str(n.get("key")))
				break
			n = n.get_parent()
		await down()
	return out


## Waits until `cond` is true (frames), up to `ms`.
func until(cond: Callable, ms := 5000) -> bool:
	var deadline := Time.get_ticks_msec() + ms
	while Time.get_ticks_msec() < deadline:
		if bool(cond.call()):
			return true
		await w.frames(1)
	return bool(cond.call())


# ---- games ------------------------------------------------------------------------

const GAME_A := {"key": "steam:1145360", "title": "Hades", "store": "steam", "id": "1145360", "installed": true}
const GAME_B := {"key": "steam:1091500", "title": "Cyberpunk 2077", "store": "steam", "id": "1091500", "installed": true}
const GAME_C := {"key": "steam:367520", "title": "Hollow Knight", "store": "steam", "id": "367520", "installed": true}


## A Steam game starts the way main._play() hands it to GameSession after
## Library.launch(): app id known, its window shows up in gamescope's list.
func start_game(g: Dictionary) -> void:
	var app := int(g["id"])
	w.fake_apps[app] = true
	_set_focusable(app, true)
	w.main.playing = g
	w.main.session.begin(g, {"ok": true, "app_id": app, "pid": 0})
	await until(func(): return w.main.session.phase == "running", 4000)
	await w.idle()


## The game quits: its window leaves gamescope's list, Steam's reaper ends.
func end_game() -> void:
	var g: Dictionary = w.main.session.game
	if g.is_empty():
		return
	var app := int(g["id"])
	w.fake_apps.erase(app)
	_set_focusable(app, false)
	await until(func(): return not w.main.session.is_active(), 12000)
	await w.idle()


func _set_focusable(app: int, on: bool) -> void:
	var f: RefCounted = w.fake
	f._mutex.lock()
	var ids: Array = Array(str(f.xroot.get("GAMESCOPE_FOCUSABLE_APPS", "769")).split(",", false)).map(func(x): return x.strip_edges())
	if on and not str(app) in ids:
		ids.append(str(app))
	elif not on:
		ids.erase(str(app))
	f.xroot["GAMESCOPE_FOCUSABLE_APPS"] = ", ".join(PackedStringArray(ids))
	f._mutex.unlock()


# ---- the system --------------------------------------------------------------------

## Root-helper runs [args, code, out] since the test's reset.
func helper_runs() -> Array:
	w.fake._log_mutex.lock()
	var out: Array = w.fake.helper_runs.duplicate(true)
	w.fake._log_mutex.unlock()
	return out


## Every argv the fake system saw that starts with `prefix` (Array of words).
func calls_with(prefix: Array) -> Array:
	var out := []
	for e in w.fake.log_copy():
		var argv: Array = e["argv"]
		if argv.size() < prefix.size():
			continue
		var hit := true
		for i in prefix.size():
			if str(prefix[i]) != "*" and str(argv[i]) != str(prefix[i]):
				hit = false
				break
		if hit:
			out.append(argv)
	return out


## The last value set on a D-Bus property ("" when it was never set).
func last_set(svc: String, iface: String, prop: String) -> String:
	var out := ""
	for argv in calls_with(["busctl"]):
		var a: Array = argv.filter(func(x): return not str(x).begins_with("--timeout") and not str(x).begins_with("--json"))
		if a.size() >= 9 and a[2] == "set-property" and a[3] == svc and a[5] == iface and a[6] == prop:
			out = str(a[8])
	return out


func atom(name: String) -> String:
	w.fake._mutex.lock()
	var v := str(w.fake.xroot.get(name, ""))
	w.fake._mutex.unlock()
	return v
