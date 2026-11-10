extends RefCounted
## InputPlumber intercept: how GameCove gets the Guide / Quick Access buttons
## inside its own gamescope session without fighting Steam. Same approach as
## OpenGamepadUI (core/ui/card_ui/card_ui.gd, GPL-3.0); docs/DEVICES.md, "What
## the Input service must do", has the reasoning.
##
##   1. Every composite device gets SetInterceptActivation([activation], target):
##      the device's home button (Guide on most), else its Quick Access button,
##      else the View + Menu chord (GPD WIN Max 2 has no special buttons).
##   2. InterceptMode 2 (Always) while GameCove's UI has focus: every input goes
##      to InputPlumber's D-Bus target, so a game in the background sees nothing.
##      GameCove turns those InputEvent signals back into Godot joypad events.
##   3. InterceptMode 1 (Pass) while a game has focus: everything reaches the
##      game's virtual pad (and Steam Input) except the activation button. When
##      it is pressed, InputPlumber switches to Always itself and sends the
##      target event, which becomes ui_action("home") (or "quick_menu").
##   4. Quick Access stays Steam's inside a game (InputPlumber's Xbox target turns
##      it into Guide + A, Steam's quick access menu); in our UI it opens ours.
##
## Signals come from one long-running `gdbus monitor --system --dest
## org.shadowblip.InputPlumber` child, read line by line on its own thread
## (OS.execute_with_pipe, blocking reads: no polling). gdbus subscribes with an
## ordinary match rule, which an unprivileged user may do (InputPlumber's bus
## policy still lets everyone receive its signals). `busctl monitor` and
## `dbus-monitor` need root on the system bus (BecomeMonitor), so they're out.
## gdbus (GLib) prints and flushes one line per signal:
##   /org/shadowblip/InputPlumber/devices/target/dbus0: org.shadowblip.Input.DBusDevice.InputEvent ('ui_guide', 1.0)
##   /org/shadowblip/InputPlumber: org.freedesktop.DBus.ObjectManager.InterfacesAdded (objectpath '/org/shadowblip/InputPlumber/CompositeDevice1', {...})
##   The name org.shadowblip.InputPlumber is owned by :1.42     (InputPlumber (re)started)
##   The name org.shadowblip.InputPlumber does not have an owner
##
## Safety: mode 2 is only set while the monitor runs (otherwise nobody would
## turn D-Bus events back into input and the UI would be stuck). When the
## monitor dies, or GameCove quits, every device goes back to mode 0 (None).

const Buttons := preload("res://scripts/device/buttons.gd")

const MODE_NONE := 0
const MODE_PASS := 1
const MODE_ALWAYS := 2

const MONITOR_PROGRAM := "gdbus"
const MONITOR_ARGS := ["monitor", "--system", "--dest", "org.shadowblip.InputPlumber"]
const EVENT_MEMBER := "org.shadowblip.Input.DBusDevice.InputEvent"
const ADDED_MEMBER := "org.freedesktop.DBus.ObjectManager.InterfacesAdded"

## Analog directions (sticks) arrive as 0..1 per direction: press above, release below.
const PRESS_AT := 0.5
const RELEASE_AT := 0.3

## Navigation events -> Godot joypad buttons (the UI reads JoypadButton events).
const NAV_BUTTONS := {
	"ui_accept": JOY_BUTTON_A, "ui_back": JOY_BUTTON_B, "ui_action": JOY_BUTTON_X, "ui_context": JOY_BUTTON_Y,
	"ui_option": JOY_BUTTON_START, "ui_select": JOY_BUTTON_BACK,
	"ui_l1": JOY_BUTTON_LEFT_SHOULDER, "ui_r1": JOY_BUTTON_RIGHT_SHOULDER,
	"ui_l3": JOY_BUTTON_LEFT_STICK, "ui_r3": JOY_BUTTON_RIGHT_STICK,
	"ui_up": JOY_BUTTON_DPAD_UP, "ui_down": JOY_BUTTON_DPAD_DOWN, "ui_left": JOY_BUTTON_DPAD_LEFT, "ui_right": JOY_BUTTON_DPAD_RIGHT,
}
const NAV_AXES := {"ui_l2": JOY_AXIS_TRIGGER_LEFT, "ui_r2": JOY_AXIS_TRIGGER_RIGHT}
## GameCove actions a special button can trigger (Buttons.DEFAULT_ACTIONS and overrides).
const UI_ACTIONS := ["home", "quick_menu", "osk", "screenshot"]


## One gdbus monitor line -> {"kind": "event", "path", "event", "value"} |
## {"kind": "added", "path"} | {"kind": "owner", "owner": ":1.42" or ""} |
## {"kind": "started"} | {} (anything else).
static func parse_line(line: String) -> Dictionary:
	var l := line.strip_edges()
	if l.begins_with("Monitoring signals"):
		return {"kind": "started"}
	if l.begins_with("The name "):
		if l.contains(" is owned by "):
			return {"kind": "owner", "owner": l.get_slice(" is owned by ", 1).strip_edges()}
		if l.ends_with("does not have an owner"):
			return {"kind": "owner", "owner": ""}
		return {}
	var colon := l.find(": ")
	if colon <= 0 or not l.begins_with("/"):
		return {}
	var path := l.substr(0, colon)
	var rest := l.substr(colon + 2)
	if rest.begins_with(EVENT_MEMBER + " "):
		var re := RegEx.create_from_string("^\\('((?:[^'\\\\]|\\\\.)*)', ([-+0-9.eE]+|nan|inf)\\)$")
		var m := re.search(rest.substr(EVENT_MEMBER.length() + 1).strip_edges())
		if m == null:
			return {}
		return {"kind": "event", "path": path, "event": m.get_string(1), "value": m.get_string(2).to_float()}
	if rest.begins_with(ADDED_MEMBER + " "):
		var re2 := RegEx.create_from_string("^\\(objectpath '([^']+)'")
		var m2 := re2.search(rest.substr(ADDED_MEMBER.length() + 1).strip_edges())
		if m2 == null:
			return {}
		return {"kind": "added", "path": m2.get_string(1)}
	return {}


## What to intercept on this device: {"events": [capability strings], "target": capability}.
static func activation_for(device: Variant) -> Dictionary:
	var home := Buttons.buttons_for(device, "home")
	if not home.is_empty():
		var cap := "Gamepad:Button:" + str(home[0])
		return {"events": [cap], "target": cap}
	var quick := Buttons.buttons_for(device, "quick_menu")
	if not quick.is_empty():
		var qcap := "Gamepad:Button:" + str(quick[0])
		return {"events": [qcap], "target": qcap}
	# no special button at all: View + Menu, delivered as Guide (= home)
	return {"events": ["Gamepad:Button:Select", "Gamepad:Button:Start"], "target": "Gamepad:Button:Guide"}


## Chords GameCove offers on this device: {action: [modifier, button]} for every
## action in Buttons.FALLBACK_CHORDS the device has no button for, when it has
## the modifier.
static func chords_for(device: Variant) -> Dictionary:
	var out := {}
	var caps := Buttons.capabilities(device)
	for action in Buttons.FALLBACK_CHORDS:
		var chord: Array = Buttons.FALLBACK_CHORDS[action]
		if not Buttons.buttons_for(device, action).is_empty():
			continue
		if chord[0] in caps:
			out[action] = chord
	return out


# ---- turning D-Bus events into actions and Godot input ------------------------

## Device id (or row) for Buttons lookups.
var device: Variant = ""
## Called with (InputEvent) for navigation; Controller wires Input.parse_input_event.
var inject: Callable
## Called with (action: String) for home / quick_menu / osk / screenshot.
var on_action: Callable
## Called with (capability: String, pressed: bool) for every button (button test).
var on_button: Callable
## Joypad device index the injected events claim to come from.
var joy_device := 0

var _held := {}          # event name -> true while pressed
var _chord_used := {}    # modifier capability -> a chord fired while it was held


## One InputEvent signal (event name, value).
func handle(event: String, value: float) -> void:
	var was: bool = _held.get(event, false)
	var down := value >= PRESS_AT if not was else value > RELEASE_AT
	if NAV_AXES.has(event):
		var m := InputEventJoypadMotion.new()
		m.device = joy_device
		m.axis = NAV_AXES[event]
		m.axis_value = clampf(value, 0.0, 1.0)
		_inject(m)
		_set_held(event, down, was)
		return
	if down == was:
		return
	_set_held(event, down, was)
	var cap: String = Buttons.DBUS_EVENTS.get(event, "")
	var chords := chords_for(device)
	if down:
		# a chord's second button while its modifier is held: the chord, not the button
		for action in chords:
			var chord: Array = chords[action]
			if cap == chord[1] and _cap_held(chord[0]):
				_chord_used[chord[0]] = true
				_swallowed[event] = true
				_action(action)
				return
	elif _swallowed.has(event):
		_swallowed.erase(event)  # its release must not reach the UI either
		return
	if NAV_BUTTONS.has(event):
		var b := InputEventJoypadButton.new()
		b.device = joy_device
		b.button_index = NAV_BUTTONS[event]
		b.pressed = down
		b.pressure = 1.0 if down else 0.0
		_inject(b)
		return
	var action := Buttons.action_for_dbus(device, event)
	if not action in UI_ACTIONS:
		return
	if chords.values().any(func(c): return c[0] == cap):
		# a chord modifier acts on release, unless a chord used it meanwhile
		if down:
			_chord_used[cap] = false
		elif not _chord_used.get(cap, false):
			_action(action)
		return
	if down:
		_action(action)


var _swallowed := {}


func _set_held(event: String, down: bool, was: bool) -> void:
	if down:
		_held[event] = true
	else:
		_held.erase(event)
	var cap: String = Buttons.DBUS_EVENTS.get(event, "")
	if cap != "" and down != was and on_button.is_valid():
		on_button.call(cap, down)


func _cap_held(cap: String) -> bool:
	for e in _held:
		if Buttons.DBUS_EVENTS.get(e, "") == cap:
			return true
	return false


func _action(action: String) -> void:
	if on_action.is_valid():
		on_action.call(action)


func _inject(e: InputEvent) -> void:
	if inject.is_valid():
		inject.call(e)


## Forget held buttons (mode change, monitor restart).
func reset() -> void:
	_held.clear()
	_chord_used.clear()
	_swallowed.clear()


# ---- the monitor process ------------------------------------------------------

var _pid := 0
var _pipe: FileAccess
var _err_pipe: FileAccess
var _thread: Thread
## Called on the main thread with each parsed line (Dictionary), and with
## {"kind": "exited"} when the monitor stops.
var on_line: Callable
## Tests: how the monitor is stopped.
var kill_fn: Callable = func(pid: int) -> void: OS.kill(pid)


## True while the monitor process is alive (review M11: not just "was started": a gdbus that
## died by itself left _pid set, so Controller never restarted it).
func running() -> bool:
	return _pid > 0 and OS.is_process_running(_pid)


## Starts gdbus monitor. False when it can't run (no gdbus).
func start_monitor(program := MONITOR_PROGRAM, args: Array = MONITOR_ARGS) -> bool:
	if running():
		return true
	if _pid > 0:
		stop_monitor()   # the last one exited by itself: reap its reader first
	var r: Dictionary = OS.execute_with_pipe(program, PackedStringArray(args), true)
	if r.is_empty() or int(r.get("pid", 0)) <= 0:
		return false
	_pid = int(r["pid"])
	_pipe = r["stdio"]
	_err_pipe = r.get("stderr")
	_thread = Thread.new()
	_thread.start(_read_loop)
	return true


func stop_monitor() -> void:
	# only a monitor that is still ours and alive: once it exited and was reaped
	# (is_process_running reaps it), its pid may already belong to another process
	# (review 2, low 23). Until we reap it, an exited child stays a zombie, so the pid
	# can't be reused between this check and the kill.
	if _pid > 0 and OS.is_process_running(_pid):
		kill_fn.call(_pid)
	if _thread != null:
		_thread.wait_to_finish()
		_thread = null
	_pid = 0
	_pipe = null
	_err_pipe = null


func _read_loop() -> void:
	var pipe := _pipe
	while pipe != null and pipe.is_open():
		var line := pipe.get_line()
		if line == "" and (pipe.eof_reached() or pipe.get_error() != OK):
			break
		var parsed := parse_line(line)
		if not parsed.is_empty() and on_line.is_valid():
			on_line.call_deferred(parsed)
	if on_line.is_valid():
		on_line.call_deferred({"kind": "exited"})
