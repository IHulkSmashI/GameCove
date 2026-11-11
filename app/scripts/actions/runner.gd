extends "res://scripts/system/service.gd"
## Runs the actions of scripts/actions/registry.gd, whoever asks: the quick
## menu's Shortcuts strip, a back button, a hold on an extra button.
##
## Nothing here runs by itself and nothing polls. What an action needs is read
## from memory (the Controls cache, the Recording and GameSession nodes); every
## program goes through the runner on this service's worker thread
## (exec_safe.gd), so the main thread never waits.
##
## How each action works:
##   keyboard     `steam -ifrunning steam://open/keyboard`: Steam's own keyboard for
##                the game in focus (the call Handheld Daemon's keyboard shortcut
##                makes). The menu closes first so the game has the keyboard.
##   key_*        InputPlumber's virtual keyboard (key_sender.gd), after the menu
##                closed and only with a game on screen: never typed at GameCove.
##   screenshot, sleep, mouse_mode, mute, mic_mute, wifi, bluetooth, airplane,
##   night_light, perf_overlay
##                the Control behind it (Controls worker), like its settings row.
##   record       the Recording service's start / stop.
##   force_close  GameCloser.force(): SIGKILL at once, no grace.
##   exit_game    the host's exit (GameCloser.close(): TERM, KILL after the grace).
##   quick_menu   the host opens or closes the menu.
##   power        `systemctl reboot` / `poweroff` (logind lets the seat's user),
##                or the host's session switch (gamecove-session-select).

## An action finished with something worth telling: text, tone ("good" / "bad" /
## ""), icon.
signal notice(text: String, tone: String, icon: String)
## Something a button shows changed (a toggle flipped, recording started).
signal state_changed

const Registry := preload("res://scripts/actions/registry.gd")
const KeySender := preload("res://scripts/actions/key_sender.gd")
const T := preload("res://scripts/ui/quick/texts_shortcuts.gd")
const TX := preload("res://scripts/ui/texts_extras.gd")

## After the menu closed, how long the game gets to have the keyboard again
## before keys are pressed (waited on the worker, not with a Timer).
const FOCUS_BACK_MS := 250
## Overlay presets the cycle steps through (a custom pick is left alone).
const OVERLAY_CYCLE := ["off", "fps", "bar", "full"]

var controls: Object
## The quick menu's model (per-game aware) when there is one, else Controls.
var model: Object
var recording: Object
var closer: Object
var session: Object
var controller: Object
## Host hooks (main.gd): each a Callable, all optional.
var game_front: Callable        # () -> bool: a game is on screen (under the menu counts)
var close_menu: Callable        # () -> void
var toggle_menu: Callable       # () -> void
var exit_game: Callable         # () -> void
var switch_session: Callable    # (target: "steam" | "desktop") -> void
var open_settings: Callable     # (category, part) -> void
var current_game: Callable      # () -> Dictionary
## Full path of `steam`, "" when it isn't installed (looked up once in setup()).
var steam_bin := ""
var keys: RefCounted

var _toggling := {}   # control id -> the action a change of it reports


## services: "controls", "model", "recording", "closer", "session", "controller",
## "runner" (tests), "steam_bin" (tests) and the host hooks above by name.
func setup(services: Dictionary) -> void:
	name = "Actions"
	controls = services.get("controls")
	model = services.get("model")
	recording = services.get("recording")
	closer = services.get("closer")
	session = services.get("session")
	controller = services.get("controller")
	if services.get("runner") != null:
		runner = services["runner"]
	for hook in ["game_front", "close_menu", "toggle_menu", "exit_game", "switch_session", "open_settings", "current_game"]:
		if services.get(hook) is Callable:
			set(hook, services[hook])
	steam_bin = str(services["steam_bin"]) if services.has("steam_bin") else find_steam(OS.get_environment("PATH"))
	keys = KeySender.new(runner)
	if controls != null:
		if controls.has_signal("control_changed") and not controls.control_changed.is_connected(_on_control_changed):
			controls.control_changed.connect(_on_control_changed)
		if controls.has_signal("control_failed") and not controls.control_failed.is_connected(_on_control_failed):
			controls.control_failed.connect(_on_control_failed)
		if controls.has_signal("detected") and not controls.detected.is_connected(_on_detected):
			controls.detected.connect(_on_detected)
	if recording != null and recording.has_signal("changed") and not recording.changed.is_connected(_on_recording_changed):
		recording.changed.connect(_on_recording_changed)


## `steam` on PATH ("" when there is none: Flatpak Steam has no keyboard call we can make).
static func find_steam(path_env: String) -> String:
	for dir in path_env.split(":", false):
		if FileAccess.file_exists(dir.path_join("steam")):
			return dir.path_join("steam")
	return ""


func _on_detected() -> void:
	state_changed.emit()


func _on_recording_changed() -> void:
	state_changed.emit()


# ---- what can run ---------------------------------------------------------------------

func _game_running() -> bool:
	return session != null and session.has_method("is_active") and bool(session.is_active())


func _game_front() -> bool:
	return _game_running() and game_front.is_valid() and bool(game_front.call())


func _game() -> Dictionary:
	if current_game.is_valid():
		return current_game.call()
	return session.game if session != null and "game" in session else {}


## The words Registry.why_not() reads: all from memory, no program runs.
func context() -> Dictionary:
	var backend := ""
	if controller != null and controller.has_method("state"):
		backend = str(controller.state().get("backend", ""))
	var upscaler: Variant = controls.value("perf.upscaler") if controls != null and controls.has_method("value") else null
	return {
		"available": _control_available,
		"game_running": _game_running(),
		"game_front": _game_front(),
		"steam": steam_bin != "",
		"keys": backend == "inputplumber",
		"recording": recording != null and recording.has_method("row_state"),
		"closer": closer != null,
		"optiscaler": upscaler is String and not upscaler in ["", "own", "off"],
	}


## The Controls cache's answer (the registry's committed copy; a registry
## without one, as in previews, is asked for the control itself).
func _control_available(id: String) -> bool:
	if controls == null:
		return false
	if controls.has_method("available"):
		return bool(controls.available(id))
	var c: Variant = controls.control(id) if controls.has_method("control") else null
	return c != null and bool(c.available)


## "" when `id` can run right now, else why not (plain words).
func why_not(id: String) -> String:
	var w := Registry.why_not(id, context())
	return "" if w == "" else Registry.why_text(w)


func can_run(id: String) -> bool:
	return Registry.why_not(id, context()) == ""


## What a button for `id` shows: {"on": bool (toggles), "busy": bool, "label": String
## (a word under the icon when it differs from the action's short name)}.
func state_of(id: String) -> Dictionary:
	var a := Registry.action(id)
	if a.is_empty():
		return {"on": false, "busy": false, "label": ""}
	if id == "record":
		var st: String = recording.row_state() if recording != null and recording.has_method("row_state") else "set_up"
		return {"on": st == "stop", "busy": st == "busy",
			"label": T.REC_LABELS.get(st, "") if st != "stop" else recording.clock(recording.elapsed_s())}
	if a["control"] != "" and controls != null:
		var v: Variant = controls.value(a["control"])
		if a["kind"] == "toggle":
			return {"on": v == true, "busy": false, "label": ""}
		if a["kind"] == "cycle":
			return {"on": v is String and v != "off", "busy": false, "label": T.OVERLAY_LABELS.get(v, "") if v is String else ""}
	return {"on": false, "busy": false, "label": ""}


# ---- running ----------------------------------------------------------------------------

## Runs `id`. `source`: "strip" (the menu shows the result itself) or "button"
## (a toast says what happened). `confirmed`: the user already said yes to an
## action that asks. Returns true when it started.
func run(id: String, source := "strip", confirmed := false) -> bool:
	var a := Registry.action(id)
	if a.is_empty():
		return false
	var why := why_not(id)
	if why != "":
		if source == "button":
			notice.emit(T.CANT % [a["title"], why], "", "info")
		return false
	if bool(a["confirm"]) and not confirmed:
		return false
	var loud := source == "button"
	match a["kind"]:
		"key":
			return _press_keys(a)
		"toggle":
			if id == "record":
				return _record()
			return _set_control(a, not (controls.value(a["control"]) == true), loud)
		"cycle":
			return _set_control(a, _next_overlay(), loud)
	match id:
		"keyboard":
			return _steam_keyboard()
		"screenshot":
			return _set_control(a, true, true)
		"sleep":
			_close_menu()
			return _set_control(a, true, false)
		"force_close":
			_close_menu()
			var g := _game()
			if closer.force(session):
				notice.emit(T.FORCE_CLOSED % str(g.get("title", T.THE_GAME)), "", "x")
				return true
			return false
		"exit_game":
			if exit_game.is_valid():
				exit_game.call()
				return true
			return false
		"quick_menu":
			if toggle_menu.is_valid():
				toggle_menu.call()
				return true
			return false
	return false


func _close_menu() -> void:
	if close_menu.is_valid():
		close_menu.call()


func _setter() -> Object:
	return model if model != null and model.has_method("set_value") else controls


func _set_control(a: Dictionary, v: Variant, loud: bool) -> bool:
	var id: String = a["control"]
	if loud or a["id"] == "screenshot":
		_toggling[id] = a["id"]
	var s := _setter()
	if s == model:
		if not model.set_value(id, v):
			_toggling.erase(id)
			return false
		return true
	controls.set_value(id, v)
	return true


func _next_overlay() -> String:
	var d: Dictionary = controls.describe_cached("perf.overlay") if controls.has_method("describe_cached") else {}
	var have: Array = []
	for o in d.get("options", []):
		if o is Dictionary and str(o.get("value", "")) in OVERLAY_CYCLE:
			have.append(str(o["value"]))
	if have.is_empty():
		return "off"
	var order: Array = OVERLAY_CYCLE.filter(func(p): return p in have)
	var cur := str(controls.value("perf.overlay"))
	return order[(order.find(cur) + 1) % order.size()]


func _on_control_changed(id: String, v: Variant) -> void:
	state_changed.emit()
	if not _toggling.has(id):
		return
	var action_id: String = _toggling[id]
	_toggling.erase(id)
	var a := Registry.action(action_id)
	match action_id:
		"screenshot":
			var c: Variant = controls.control(id) if controls.has_method("control") else null
			var path: String = str(c.get_meta("last_path")) if c != null and c.has_meta("last_path") else ""
			notice.emit(T.SHOT_SAVED, "good", "camera")
			if path != "":
				last_screenshot = path
		"perf_overlay":
			notice.emit(T.OVERLAY_NOW % str(T.OVERLAY_LABELS.get(v, v)), "", a["icon"])
		_:
			if a["kind"] == "toggle":
				notice.emit((T.TURNED_ON if v == true else T.TURNED_OFF) % a["title"], "", a["icon"])


## The last screenshot's file (for whoever wants to show it).
var last_screenshot := ""


func _on_control_failed(id: String, _v: Variant) -> void:
	if not _toggling.has(id):
		return
	var a := Registry.action(_toggling[id])
	_toggling.erase(id)
	notice.emit((T.SHOT_FAILED if a["id"] == "screenshot" else T.FAILED % a["title"]), "bad", "alert")


func _record() -> bool:
	match recording.row_state():
		"record":
			var g := _game() if _game_running() else {}
			if recording.start(g):
				notice.emit(TX.REC_STARTED, "good", "record")
				_close_menu()
				return true
			return false
		"stop":
			recording.stop()
			return true
		"set_up":
			if open_settings.is_valid():
				open_settings.call("media", "")
				return true
	return false


## Steam's keyboard for the game in focus. The menu closes first: Steam shows
## the keyboard for whoever has the keyboard, and that must be the game.
func _steam_keyboard() -> bool:
	if steam_bin == "":
		return false
	_close_menu()
	var bin := steam_bin
	var rn := runner
	_queue("keyboard", func():
		var r: Dictionary = rn.run(bin, PackedStringArray(["-ifrunning", "steam://open/keyboard"]))
		if int(r.get("code", -1)) != 0:
			_main(func(): notice.emit(T.KEYBOARD_FAILED, "bad", "alert")))
	return true


## Keys at the game: only with a game on screen, and only once the menu is gone.
func _press_keys(a: Dictionary) -> bool:
	if not _game_front():
		return false
	_close_menu()
	var combo: Array = a["keys"]
	var title: String = a["title"]
	var sender := keys
	_queue("keys", func():
		var ok: bool = sender.press(combo, FOCUS_BACK_MS)
		_main(func():
			if not ok:
				notice.emit(T.KEY_FAILED % title, "bad", "alert")))
	return true


## A row of the Power sheet, already confirmed: "restart", "shutdown", "desktop", "steam".
func power(what: String) -> bool:
	match what:
		"restart", "shutdown":
			_close_menu()
			var verb := "reboot" if what == "restart" else "poweroff"
			var rn := runner
			_queue("power", func():
				var r: Dictionary = rn.run("systemctl", PackedStringArray([verb]))
				if int(r.get("code", -1)) != 0:
					_main(func(): notice.emit(T.POWER_FAILED, "bad", "alert")))
			return true
		"desktop", "steam":
			if switch_session.is_valid():
				switch_session.call(what)
				return true
	return false
