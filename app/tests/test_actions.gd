extends "res://tests/test_case.gd"
## The one-press actions: the registry (scripts/actions/registry.gd), who may
## run where, the runner with fake backends (nothing real runs), the key
## sender's InputPlumber calls, Force close's plan, the strip's saved list and
## the Shortcuts strip itself inside the quick menu.

const Registry := preload("res://scripts/actions/registry.gd")
const Runner := preload("res://scripts/actions/runner.gd")
const KeySender := preload("res://scripts/actions/key_sender.gd")
const Prefs := preload("res://scripts/actions/shortcut_prefs.gd")
const Closer := preload("res://scripts/ui/games/game_closer.gd")
const Fake := preload("res://tests/fixtures/system/fake_runner.gd")
const QuickMenu := preload("res://scripts/ui/quick_menu.gd")
const Screens := preload("res://tests/test_ui_screens.gd")
const UiPrefs := preload("res://scripts/ui/ui_prefs.gd")
const CIcons := preload("res://scripts/ui/controls/cicons.gd")
const Catalog := preload("res://scripts/ui/controls/catalog.gd")
const T := preload("res://scripts/ui/quick/texts_shortcuts.gd")
const TX := preload("res://scripts/ui/texts_extras.gd")
const Themes := preload("res://theme/themes.gd")
const ThemeLib := preload("res://theme/gamecove_theme.gd")

const IP_SVC := "org.shadowblip.InputPlumber"
const KB := "/org/shadowblip/InputPlumber/devices/target/keyboard0"


class FakeControls extends RefCounted:
	signal control_changed(id: String, value: Variant)
	signal control_failed(id: String, value: Variant)
	signal detected()
	var values := {"audio.mute": false, "audio.mic_mute": false, "controller.desktop_mode": false, "network.wifi": true,
		"network.bluetooth": true, "network.airplane": false, "display.night_light": false, "perf.overlay": "off",
		"system.screenshot": null, "system.sleep": null, "perf.upscaler": "own"}
	var missing: Array = []
	var failing: Array = []
	var sets: Array = []

	func available(id: String) -> bool:
		return values.has(id) and not id in missing

	func value(id: String) -> Variant:
		return values.get(id)

	func describe_cached(id: String) -> Dictionary:
		if id == "perf.overlay":
			return {"options": [{"value": "off"}, {"value": "fps"}, {"value": "compact"}, {"value": "bar"}, {"value": "full"}, {"value": "custom"}]}
		return {}

	func control(_id: String) -> RefCounted:
		return null

	func set_value(id: String, v: Variant) -> void:
		sets.append([id, v])
		if id in failing:
			control_failed.emit(id, v)
			return
		if values[id] != null:
			values[id] = v
		control_changed.emit(id, values[id])


class FakeRec extends RefCounted:
	signal changed
	var state := "idle"
	var st := "record"
	var started: Array = []
	var stopped := 0

	func row_state() -> String:
		return st

	func start(g: Dictionary) -> bool:
		started.append(g)
		st = "stop"
		changed.emit()
		return true

	func stop() -> void:
		stopped += 1
		st = "record"
		changed.emit()

	func elapsed_s() -> int:
		return 75

	static func clock(s: int) -> String:
		return "%d:%02d" % [int(s / 60.0), s % 60]


class FakeSession extends RefCounted:
	var active := true
	var game := {"key": "steam:1145360", "title": "Hades", "store": "steam", "id": "1145360"}
	var app_id := 1145360
	var pid := 0

	func is_active() -> bool:
		return active


class FakeController extends RefCounted:
	var backend := "inputplumber"
	var steam_menus := 0

	func open_steam_menu() -> void:
		steam_menus += 1

	func state() -> Dictionary:
		return {"backend": backend}


class FakeCloser extends RefCounted:
	var forced := 0

	func force(_s: Object) -> bool:
		forced += 1
		return true


func _ip_runner(keyboards := true) -> RefCounted:
	var f := Fake.new()
	var objs := {"/org/shadowblip/InputPlumber/CompositeDevice0": {"org.shadowblip.Input.CompositeDevice": {}}}
	if keyboards:
		objs[KB] = {"org.shadowblip.Input.Keyboard": {"Name": {"type": "s", "data": "Keyboard"}}}
	f.responses["busctl --system call %s /org/shadowblip/InputPlumber org.freedesktop.DBus.ObjectManager GetManagedObjects" % IP_SVC] = \
		{"code": 0, "out": JSON.stringify({"type": "a{oa{sa{sv}}}", "data": [objs]})}
	f.responses["busctl --system call %s /org/shadowblip/InputPlumber/Manager org.shadowblip.InputManager CreateTargetDevice s keyboard" % IP_SVC] = \
		{"code": 0, "out": JSON.stringify({"type": "s", "data": ["/org/shadowblip/InputPlumber/devices/target/keyboard7"]})}
	f.responses["busctl --system call %s *" % IP_SVC] = {"code": 0, "out": ""}
	f.responses["/usr/bin/steam -ifrunning steam://open/keyboard"] = {"code": 0, "out": ""}
	f.responses["systemctl *"] = {"code": 0, "out": ""}
	return f


## A runner on fakes: {"r": Runner, "controls", "rec", "session", "closer", "ctl", "run": fake runner,
## "notes": [[text, tone, icon]], "calls": {"closed": n, "toggled": n, "exited": n, "switched": [], "settings": []}, "front": [bool]}
func _rig(opts := {}) -> Dictionary:
	var out := {"controls": FakeControls.new(), "rec": FakeRec.new(), "session": FakeSession.new(), "closer": FakeCloser.new(),
		"ctl": FakeController.new(), "run": _ip_runner(bool(opts.get("keyboards", true))), "notes": [], "front": [true],
		"calls": {"closed": 0, "toggled": 0, "exited": 0, "switched": [], "settings": []}}
	var r: Node = Runner.new()
	var calls: Dictionary = out["calls"]
	var front: Array = out["front"]
	r.setup({"controls": out["controls"], "recording": out["rec"], "session": out["session"], "closer": out["closer"],
		"controller": out["ctl"], "runner": out["run"], "steam_bin": str(opts.get("steam", "/usr/bin/steam")),
		"game_front": func() -> bool: return front[0],
		"close_menu": func() -> void: calls["closed"] += 1,
		"toggle_menu": func() -> void: calls["toggled"] += 1,
		"exit_game": func() -> void: calls["exited"] += 1,
		"switch_session": func(t: String) -> void: calls["switched"].append(t),
		"open_settings": func(c: String, p: String) -> void: calls["settings"].append([c, p]),
		"current_game": func() -> Dictionary: return out["session"].game if out["session"].active else {}})
	r.keys.wait = func(_ms: int) -> void: pass
	var notes: Array = out["notes"]
	r.notice.connect(func(text, tone, icon): notes.append([text, tone, icon]))
	out["r"] = r
	return out


func _done(rig: Dictionary) -> void:
	rig["r"].free()


# ---- registry -----------------------------------------------------------------------------

func test_registry_is_whole() -> void:
	var seen := {}
	for a in Registry.ACTIONS:
		var id: String = a["id"]
		ok(not seen.has(id), "%s listed once" % id)
		seen[id] = true
		var full := Registry.action(id)
		for k in ["title", "short", "icon", "help", "kind"]:
			ok(str(full.get(k, "")) != "", "%s has %s" % [id, k])
		ok(full["kind"] in ["run", "toggle", "cycle", "sheet", "key"], "%s: a known kind" % id)
		ok(CIcons.has(full["icon"]), "%s: icon %s exists" % [id, full["icon"]])
		ok(str(full["short"]).length() <= 11, "%s: '%s' fits under an icon" % [id, full["short"]])
		ok(not str(full["help"]).contains("I ") and str(full["help"]).ends_with("."), "%s: one plain help line" % id)
		ok(bool(full["strip"]) or bool(full["button"]), "%s is offered somewhere" % id)
		if full["kind"] == "key":
			ok(Registry.valid_combo(full["keys"]), "%s: its keys are a valid combination" % id)
		if full["kind"] in ["toggle", "cycle"] and id != "record":
			ok(full["control"] != "", "%s is backed by a Control" % id)
	for id in Registry.STRIP_DEFAULT:
		ok(bool(Registry.action(id).get("strip", false)), "default shortcut %s is a strip action" % id)
	eq(Registry.STRIP_DEFAULT, ["keyboard", "steam_menu", "screenshot", "record", "mouse_mode", "mute", "send_key", "sleep"], "the usual strip")
	for id in Registry.SEND_KEYS:
		eq(Registry.action(id)["kind"], "key", "%s in the Send key sheet presses keys" % id)
	eq(Registry.SEND_KEYS.map(func(i): return Registry.action(i)["title"]), ["Esc", "Enter", "Tab", "Alt + Enter", "Alt + F4"], "the Send key set")
	ok(Registry.action("nope").is_empty(), "unknown id: nothing")
	ok(not "send_key" in Registry.button_ids() and not "power_menu" in Registry.button_ids(), "sheets aren't button actions")
	ok(not "quick_menu" in Registry.strip_ids() and not "exit_game" in Registry.strip_ids(), "the strip never offers the menu itself or Exit game (it has its own row)")


func test_the_strip_repeats_no_quick_menu_row_by_accident() -> void:
	# What the strip shares with a tab is the same Control, so both always agree.
	var in_tabs := {}
	for tab in Catalog.QUICK:
		for id in Catalog.QUICK[tab]:
			in_tabs[id] = true
	for id in Registry.strip_ids():
		var c: String = Registry.action(id)["control"]
		if c != "" and not c in ["system.sleep"]:
			ok(in_tabs.has(c), "%s drives %s, a quick menu Control" % [id, c])


func test_keys_and_combinations() -> void:
	eq(Registry.dbus_key("KeyEsc"), "KEY_ESC", "InputPlumber's SendKey name")
	eq(Registry.dbus_key("KeyLeftAlt"), "KEY_LEFTALT", "modifier name")
	eq(Registry.dbus_key("KeyF4"), "KEY_F4", "function key")
	eq(Registry.combo_label(["KeyLeftAlt", "KeyEnter"]), "Alt + Enter", "label")
	eq(Registry.combo_text(["KeyLeftCtrl", "KeyLeftShift", "KeyEsc"]), "KeyLeftCtrl+KeyLeftShift+KeyEsc", "setting form")
	eq(Registry.combo_keys("KeyLeftAlt+KeyF4"), ["KeyLeftAlt", "KeyF4"], "and back")
	ok(Registry.valid_combo(["KeyEsc"]), "one key")
	ok(Registry.valid_combo(["KeyLeftAlt"]), "a modifier alone (held like a key)")
	ok(Registry.valid_combo(["KeyLeftCtrl", "KeyLeftAlt", "KeyDelete"]), "two modifiers and a key")
	ok(not Registry.valid_combo([]), "nothing")
	ok(not Registry.valid_combo(["KeyEnter", "KeyLeftAlt"]), "modifiers come first")
	ok(not Registry.valid_combo(["KeyA", "KeyB"]), "two plain keys")
	ok(not Registry.valid_combo(["KeyLeftAlt", "KeyLeftAlt", "KeyA"]), "a repeat")
	ok(not Registry.valid_combo(["KeyNope"]), "an unknown key")
	ok(not Registry.valid_combo(["KeyLeftCtrl", "KeyLeftShift", "KeyLeftAlt", "KeyLeftMeta", "KeyA"]), "too long")
	eq(Registry.key_action_for(["KeyLeftAlt", "KeyEnter"]), "key_alt_enter", "a known combination has a name")
	eq(Registry.key_action_for(["KeyF9"]), "", "others don't")
	for k in Registry.KEY_NAMES + Registry.KEY_MODIFIERS:
		ok(str(k).begins_with("Key") and str(k).is_valid_identifier(), "%s is a profile key name" % k)


func test_availability_rules() -> void:
	var all_ok := {"available": func(_id): return true, "game_running": true, "game_front": true, "steam": true, "keys": true,
		"recording": true, "closer": true, "optiscaler": true}
	for id in Registry.ids():
		eq(Registry.why_not(id, all_ok), "", "%s runs when everything is there" % id)
	var home := all_ok.duplicate()
	home["game_running"] = false
	home["game_front"] = false
	for id in ["keyboard", "send_key", "key_esc", "key_alt_f4"]:
		eq(Registry.why_not(id, home), "no_game_front", "%s needs a game on screen (never GameCove itself)" % id)
	for id in ["force_close", "exit_game"]:
		eq(Registry.why_not(id, home), "no_game", "%s needs a running game" % id)
	for id in ["screenshot", "record", "mouse_mode", "mute", "sleep", "power_menu", "wifi"]:
		eq(Registry.why_not(id, home), "", "%s works without a game" % id)
	var behind := all_ok.duplicate()
	behind["game_front"] = false   # the game runs, GameCove's home is in front
	eq(Registry.why_not("key_enter", behind), "no_game_front", "a game behind GameCove's home gets no keys")
	eq(Registry.why_not("force_close", behind), "", "but it can be force closed")
	var hhd := all_ok.duplicate()
	hhd["keys"] = false
	eq(Registry.why_not("send_key", hhd), "no_keys", "no InputPlumber: no Send key")
	eq(Registry.why_not("key_tab", hhd), "no_keys", "nor its keys")
	eq(Registry.why_not("keyboard", hhd), "", "Steam's keyboard doesn't need it")
	var no_steam := all_ok.duplicate()
	no_steam["steam"] = false
	eq(Registry.why_not("keyboard", no_steam), "no_steam", "no Steam: no Steam keyboard")
	var bare := all_ok.duplicate()
	bare["available"] = func(id): return id != "controller.desktop_mode" and id != "network.bluetooth"
	eq(Registry.why_not("mouse_mode", bare), "no_control", "mouse mode hidden where its Control isn't available")
	eq(Registry.why_not("bluetooth", bare), "no_control", "Bluetooth too")
	eq(Registry.why_not("mute", bare), "", "others stay")
	var no_opti := all_ok.duplicate()
	no_opti["optiscaler"] = false
	eq(Registry.why_not("key_optiscaler", no_opti), "no_optiscaler", "OptiScaler's menu only for games that use it")
	for w in Registry.WHY:
		ok(str(Registry.WHY[w]).ends_with("."), "%s reason is a sentence" % w)
	ok(Registry.why_text("no_control") != "", "an unlisted reason still reads")


# ---- saved strip ----------------------------------------------------------------------------

func _prefs_file() -> String:
	DirAccess.make_dir_recursive_absolute(OS.get_cache_dir())   # a fresh HOME has no ~/.cache yet
	var p := OS.get_cache_dir().path_join("gamecove_strip_%d.cfg" % Time.get_ticks_usec())
	UiPrefs.path = p
	Prefs.load_prefs()
	return p


func _prefs_done(p: String) -> void:
	if FileAccess.file_exists(p):
		DirAccess.remove_absolute(p)
	UiPrefs.path = UiPrefs.PATH
	Prefs.order = []
	Prefs.hidden = []


func test_strip_prefs() -> void:
	var p := _prefs_file()
	eq(Prefs.shown(), Registry.STRIP_DEFAULT, "defaults: Keyboard, Steam menu, Screenshot, Record, Mouse mode, Mute, Send key, Sleep")
	eq(Prefs.all().size(), Registry.strip_ids().size(), "every strip action is in the list")
	ok(not Prefs.is_shown("wifi") and Prefs.is_shown("mute"), "the rest start hidden")
	Prefs.set_shown("wifi", true)
	Prefs.set_shown("sleep", false)
	ok(Prefs.is_shown("wifi") and not Prefs.is_shown("sleep"), "on / off")
	ok(Prefs.move("steam_menu", -1), "move up")
	eq(Prefs.shown().slice(0, 2), ["steam_menu", "keyboard"], "Steam menu is first now")
	ok(not Prefs.move("steam_menu", -1), "the first can't go higher")
	ok(not Prefs.move(Prefs.all()[-1], 1), "the last can't go lower")
	ok(Prefs.move("steam_menu", 1), "move down")
	eq(Prefs.shown()[0], "keyboard", "back in place")
	# what was saved is what loads
	var before_order := Prefs.all()
	var before_shown := Prefs.shown()
	Prefs.order = []
	Prefs.hidden = []
	Prefs.load_prefs()
	eq(Prefs.all(), before_order, "order saved")
	eq(Prefs.shown(), before_shown, "on / off saved")
	Prefs.reset()
	eq(Prefs.shown(), Registry.STRIP_DEFAULT, "reset: the usual strip")
	_prefs_done(p)


func test_strip_prefs_survive_odd_files() -> void:
	var c := Prefs.clean(["mute", "nope", "mute", "keyboard", 7], ["keyboard", "ghost"])
	eq(c["order"].slice(0, 2), ["mute", "keyboard"], "unknown ids and doubles dropped, order kept")
	eq(c["order"].size(), Registry.strip_ids().size(), "missing actions join at the end")
	ok("keyboard" in c["hidden"] and not "ghost" in c["hidden"], "hidden keeps real ids")
	ok("wifi" in c["hidden"], "an action the file didn't know starts hidden")
	eq(Prefs.clean("junk", null), Prefs.defaults(), "junk: defaults")
	eq(Prefs.clean([], []), Prefs.defaults(), "empty: defaults")


# ---- key sender ------------------------------------------------------------------------------

func _sent(f: RefCounted) -> Array:
	var out := []
	for c in f.calls:
		if c.contains(" SendKey "):
			out.append(c.get_slice(" SendKey sb ", 1))
	return out


func test_key_sender_uses_the_running_keyboard() -> void:
	var f := _ip_runner(true)
	var k := KeySender.new(f)
	var waits: Array = []
	k.wait = func(ms: int) -> void: waits.append(ms)
	ok(k.press(["KeyLeftAlt", "KeyEnter"], 250), "Alt+Enter sent")
	eq(_sent(f), ["KEY_LEFTALT true", "KEY_ENTER true", "KEY_ENTER false", "KEY_LEFTALT false"], "down in order, up in reverse")
	ok(f.calls.any(func(c): return c.contains(KB + " org.shadowblip.Input.Keyboard SendKey")), "on InputPlumber's own keyboard")
	ok(not f.calls.any(func(c): return c.contains("CreateTargetDevice")), "no new device when one runs")
	eq(waits[0], 250, "waits for the game to have the keyboard first")
	ok(not KeySender.NEW_DEVICE_MS in waits, "no new-device wait")


func test_key_sender_makes_and_removes_a_keyboard() -> void:
	var f := _ip_runner(false)
	var k := KeySender.new(f)
	var waits: Array = []
	k.wait = func(ms: int) -> void: waits.append(ms)
	ok(k.press(["KeyEsc"]), "Esc sent")
	var made := "/org/shadowblip/InputPlumber/devices/target/keyboard7"
	ok(f.calls.any(func(c): return c.ends_with("CreateTargetDevice s keyboard")), "asks InputPlumber for a keyboard")
	ok(f.calls.any(func(c): return c.contains(made + " org.shadowblip.Input.Keyboard SendKey sb KEY_ESC true")), "presses on it")
	eq(f.calls[-1], "busctl --system call %s /org/shadowblip/InputPlumber/Manager org.shadowblip.InputManager StopTargetDevice s %s" % [IP_SVC, made],
		"and stops it again: nothing of ours stays behind the game")
	ok(KeySender.NEW_DEVICE_MS in waits, "gives the compositor a moment to see the new device")


func test_key_sender_lets_go_when_a_call_fails() -> void:
	var f := _ip_runner(true)
	f.handler = func(cmd: String) -> Variant:
		return {"code": 1, "out": "refused"} if cmd.ends_with("KEY_F4 true") else null
	var k := KeySender.new(f)
	k.wait = func(_ms: int) -> void: pass
	ok(not k.press(["KeyLeftAlt", "KeyF4"]), "a refused key: false")
	eq(_sent(f), ["KEY_LEFTALT true", "KEY_F4 true", "KEY_LEFTALT false"], "Alt is released all the same")
	ok(not k.press(["KeyA", "KeyB"]), "an invalid combination is never sent")
	var none := Fake.new()
	var k2 := KeySender.new(none)
	k2.wait = func(_ms: int) -> void: pass
	ok(not k2.press(["KeyEsc"]), "no InputPlumber: false")
	ok(not k2.present(), "and present() says so")
	eq(KeySender.keyboards({"a": {"org.shadowblip.Input.Keyboard": {}}, "b": {"x": {}}, "c": 3}), ["a"], "keyboards() reads the object tree")


# ---- force close -------------------------------------------------------------------------------

func test_force_close_plan() -> void:
	var steam := Closer.force_plan({"store": "steam", "id": "1145360"}, 1145360, 0)
	eq(steam.size(), 1, "a Steam game: one command")
	eq(steam[0].slice(0, 2), ["sh", "-c"], "the closer's own script")
	eq(steam[0].slice(-3), ["KILL", "steam", "1145360"], "KILL for that app id's launch wrapper, at once")
	eq(Closer.force_plan({"store": "steam", "id": "12; rm -rf /"}, 0, 0), [], "a bad app id runs nothing")
	var srm := Closer.force_plan({"store": "emu", "shortcut": true, "id": "3000000001"}, 0, 555)
	eq(srm.size(), 1, "a Steam ROM Manager shortcut: Steam started it, so through Steam's launch wrapper")
	eq(srm[0].slice(-3), ["KILL", "steam", "3000000001"], "KILL for the shortcut's app id")
	var other := Closer.force_plan({"store": "gog", "id": "x"}, 42, 777)
	eq(other[0], ["systemctl", "--user", "kill", "--signal=KILL", "app-steam-app42-*.scope"], "a scoped game: its scope, killed")
	eq(other[1].slice(-3), ["KILL", "pid", "777"], "and its process tree")
	var c: Node = Closer.new()
	var ran: Array = []
	c.run = func(cmd: Array) -> int:
		ran.append(cmd)
		return 1
	ok(c.force(FakeSession.new()), "force() runs it")
	eq(ran.size(), 1, "one command, no grace timer")
	var idle := FakeSession.new()
	idle.active = false
	ok(not c.force(idle), "nothing runs: false")
	ok(not c.force(null), "no session: false")
	c.free()


# ---- runner ------------------------------------------------------------------------------------

func test_runner_toggles_through_controls() -> void:
	var rig := _rig()
	var r: Node = rig["r"]
	var changes := [0]
	r.state_changed.connect(func(): changes[0] += 1)
	ok(r.run("mute"), "Mute runs")
	eq(rig["controls"].sets[-1], ["audio.mute", true], "through the audio.mute Control")
	ok(r.state_of("mute")["on"], "and reads on")
	ok(changes[0] > 0, "buttons hear of it")
	eq(rig["notes"].size(), 0, "from the strip: no toast (the button shows it)")
	ok(r.run("mute", "button"), "from a button")
	eq(rig["controls"].sets[-1], ["audio.mute", false], "off again")
	eq(rig["notes"][-1][0], "Mute sound off", "a button says what happened")
	for pair in [["mic_mute", "audio.mic_mute"], ["mouse_mode", "controller.desktop_mode"], ["night_light", "display.night_light"],
			["wifi", "network.wifi"], ["bluetooth", "network.bluetooth"], ["airplane", "network.airplane"]]:
		var before: bool = rig["controls"].values[pair[1]]
		ok(r.run(pair[0]), "%s runs" % pair[0])
		eq(rig["controls"].sets[-1], [pair[1], not before], "%s flips %s" % pair)
	eq(rig["calls"]["closed"], 0, "toggles leave the menu open")
	_done(rig)


func test_runner_overlay_cycle_screenshot_and_sleep() -> void:
	var rig := _rig()
	var r: Node = rig["r"]
	var seen := []
	for i in 5:
		r.run("perf_overlay")
		seen.append(rig["controls"].values["perf.overlay"])
	eq(seen, ["fps", "bar", "full", "off", "fps"], "the overlay steps off, frame rate, bar, full and around")
	eq(r.state_of("perf_overlay")["label"], "Frame rate", "the button names the level")
	rig["controls"].values["perf.overlay"] = "custom"
	r.run("perf_overlay", "button")
	eq(rig["controls"].values["perf.overlay"], "off", "from a custom pick: off first")
	eq(rig["notes"][-1][0], "Performance overlay: Off", "a button names the new level")
	ok(r.run("screenshot"), "Screenshot runs")
	eq(rig["controls"].sets[-1], ["system.screenshot", true], "gamescope's screenshot, through its Control")
	eq(rig["notes"][-1], [T.SHOT_SAVED, "good", "camera"], "always a toast: there's nothing else to see")
	eq(rig["calls"]["closed"], 0, "the menu stays (gamescope shoots the game's own plane)")
	rig["controls"].failing = ["system.screenshot"]
	r.run("screenshot")
	eq(rig["notes"][-1][0], T.SHOT_FAILED, "a failed screenshot says so")
	ok(r.run("sleep"), "Sleep runs")
	eq(rig["controls"].sets[-1], ["system.sleep", true], "systemctl suspend, through its Control")
	eq(rig["calls"]["closed"], 1, "the menu closes first, so it isn't there on wake")
	rig["controls"].failing = ["audio.mute"]
	r.run("mute", "button")
	eq(rig["notes"][-1][0], "Mute sound didn't change.", "a failed toggle says so")
	_done(rig)


func test_runner_record() -> void:
	var rig := _rig()
	var r: Node = rig["r"]
	eq(r.state_of("record"), {"on": false, "busy": false, "label": ""}, "idle: Record")
	ok(r.run("record"), "Record starts")
	eq(rig["rec"].started, [rig["session"].game], "for the running game")
	eq(rig["notes"][-1][0], TX.REC_STARTED, "the same toast as the Record row")
	eq(rig["calls"]["closed"], 1, "back to the game")
	eq(r.state_of("record"), {"on": true, "busy": false, "label": "1:15"}, "recording: the clock")
	ok(r.run("record"), "the same button stops")
	eq(rig["rec"].stopped, 1, "stop")
	rig["rec"].st = "set_up"
	eq(r.state_of("record")["label"], "Set up", "not set up yet: says so")
	ok(r.run("record"), "and A goes to")
	eq(rig["calls"]["settings"], [["media", ""]], "Settings > Media")
	rig["rec"].st = "busy"
	ok(r.state_of("record")["busy"], "busy while it starts or saves")
	ok(not r.run("record"), "and does nothing then")
	_done(rig)


func test_runner_steam_keyboard() -> void:
	var rig := _rig()
	var r: Node = rig["r"]
	ok(r.run("keyboard"), "Keyboard runs over a game")
	eq(rig["run"].calls, ["/usr/bin/steam -ifrunning steam://open/keyboard"], "Steam opens its own keyboard; nothing else runs")
	eq(rig["calls"]["closed"], 1, "the menu closes so the game has the keyboard")
	rig["run"].calls.clear()
	rig["front"][0] = false
	ok(not r.run("keyboard"), "not with GameCove in front")
	ok(r.why_not("keyboard") != "", "and it says why")
	eq(rig["run"].calls, [], "nothing ran")
	rig["front"][0] = true
	rig["run"].responses["/usr/bin/steam -ifrunning steam://open/keyboard"] = {"code": 1, "out": ""}
	r.run("keyboard")
	eq(rig["notes"][-1][0], T.KEYBOARD_FAILED, "Steam not answering: a toast")
	_done(rig)
	var none := _rig({"steam": ""})
	ok(not none["r"].can_run("keyboard"), "no steam binary: no Keyboard shortcut")
	eq(none["r"].why_not("keyboard"), "Needs Steam running.", "with the reason")
	_done(none)
	var dir := OS.get_cache_dir().path_join("gamecove_steam_%d" % Time.get_ticks_usec())
	DirAccess.make_dir_recursive_absolute(dir)
	FileAccess.open(dir.path_join("steam"), FileAccess.WRITE).close()
	eq(Runner.find_steam("/nope:" + dir), dir.path_join("steam"), "steam found on PATH")
	eq(Runner.find_steam("/nope"), "", "or not")
	DirAccess.remove_absolute(dir.path_join("steam"))
	DirAccess.remove_absolute(dir)


func test_runner_steam_menu() -> void:
	var rig := _rig()
	var r: Node = rig["r"]
	ok(r.run("steam_menu"), "Steam menu runs over a game")
	eq(rig["ctl"].steam_menus, 1, "the Controller service hands Steam its menu button")
	eq(rig["calls"]["closed"], 1, "our menu closes first, so Steam's opens over the game")
	eq(rig["run"].calls, [], "no program of ours runs for it")
	rig["front"][0] = false
	ok(not r.run("steam_menu"), "not with GameCove in front")
	rig["front"][0] = true
	rig["ctl"].backend = "hhd"
	ok(not r.can_run("steam_menu"), "Handheld Daemon: no way to hand Steam the button")
	eq(r.why_not("steam_menu"), "Needs InputPlumber, which hands the button to Steam.", "with the reason")
	eq(rig["ctl"].steam_menus, 1, "nothing more was sent")
	ok(Registry.action("steam_menu")["button"], "a back button can open Steam's menu too")
	_done(rig)


func test_runner_sends_keys_only_to_a_game() -> void:
	var rig := _rig()
	var r: Node = rig["r"]
	for id in Registry.SEND_KEYS:
		rig["run"].calls.clear()
		ok(r.run(id), "%s runs" % id)
		var want: Array = Registry.action(id)["keys"].map(func(k): return Registry.dbus_key(k) + " true")
		eq(_sent(rig["run"]).slice(0, want.size()), want, "%s presses %s" % [id, Registry.combo_label(Registry.action(id)["keys"])])
	eq(rig["calls"]["closed"], Registry.SEND_KEYS.size(), "the menu closes before every press")
	eq(rig["notes"], [], "a key that went out says nothing")
	rig["run"].calls.clear()
	rig["front"][0] = false
	ok(not r.run("key_alt_f4"), "GameCove in front: Alt+F4 is refused")
	eq(rig["run"].calls, [], "not a single call: GameCove never gets keys")
	ok(not r.can_run("send_key"), "and the Send key shortcut is gone")
	rig["front"][0] = true
	rig["session"].active = false
	ok(not r.run("key_esc"), "no game at all: refused")
	rig["session"].active = true
	rig["ctl"].backend = "hhd"
	ok(not r.can_run("send_key") and not r.run("key_esc"), "Handheld Daemon can't press keys: not offered")
	eq(r.why_not("send_key"), "Needs InputPlumber, which presses the keys.", "with the reason")
	rig["ctl"].backend = "inputplumber"
	rig["run"].handler = func(cmd: String) -> Variant:
		return {"code": 1, "out": ""} if cmd.contains("SendKey") else null
	r.run("key_enter")
	eq(rig["notes"][-1][0], "Enter didn't reach the game.", "a failed press: a toast")
	_done(rig)


func test_runner_force_close_exit_menu_and_power() -> void:
	var rig := _rig()
	var r: Node = rig["r"]
	ok(not r.run("force_close"), "Force close never runs unconfirmed")
	eq(rig["closer"].forced, 0, "nothing was closed")
	ok(r.run("force_close", "strip", true), "confirmed: runs")
	eq(rig["closer"].forced, 1, "GameCloser.force()")
	eq(rig["notes"][-1][0], "Closed Hades", "says what it closed")
	ok(not r.run("exit_game", "button"), "Exit game from a button needs its hold")
	ok(r.run("exit_game", "button", true), "held: exits")
	eq(rig["calls"]["exited"], 1, "the host's Exit game")
	ok(r.run("quick_menu", "button"), "Open the quick menu")
	eq(rig["calls"]["toggled"], 1, "the host toggles it")
	rig["session"].active = false
	ok(not r.run("force_close", "strip", true), "no game: nothing to force close")
	eq(rig["notes"][-1][0].begins_with("Closed"), true, "no new toast from the strip")
	ok(not r.run("force_close", "button", true), "from a button")
	ok(str(rig["notes"][-1][0]).begins_with("Force close game: "), "a button says why not")
	rig["run"].calls.clear()
	ok(r.power("restart"), "Restart")
	eq(rig["run"].calls[-1], "systemctl reboot", "systemctl reboot")
	ok(r.power("shutdown"), "Shut down")
	eq(rig["run"].calls[-1], "systemctl poweroff", "systemctl poweroff")
	ok(r.power("desktop") and r.power("steam"), "session switches")
	eq(rig["calls"]["switched"], ["desktop", "steam"], "go to the host's switch (gamecove-session-select)")
	ok(not r.power("format"), "unknown: nothing")
	ok(not r.run("nope"), "unknown action: nothing")
	_done(rig)


func test_runner_context_reads_memory_only() -> void:
	var rig := _rig()
	var r: Node = rig["r"]
	rig["run"].calls.clear()
	for i in 3:
		r.context()
		for id in Registry.ids():
			r.why_not(id)
			r.state_of(id)
	eq(rig["run"].calls, [], "asking what can run and how it looks runs no program")
	ok(not r.context()["optiscaler"], "the game's own upscaler: no OptiScaler menu")
	rig["controls"].values["perf.upscaler"] = "xess"
	ok(r.context()["optiscaler"], "OptiScaler in the game: its menu key is offered")
	rig["controls"].missing = ["audio.mute"]
	ok(not r.can_run("mute"), "a Control that isn't available hides its shortcut")
	_done(rig)


# ---- the strip in the quick menu ----------------------------------------------------------------

func _menu(rig: Dictionary) -> Control:
	var qm: Control = QuickMenu.new()
	qm.setup({"device": Screens.FakeDevice.new(), "power": Screens.FakePower.new(), "launcher": Screens.FakeLauncher.new(),
		"gamescope": Screens.FakeGamescope.new(), "actions": rig["r"], "recording": rig["rec"]})
	rig["r"].close_menu = func() -> void:
		rig["calls"]["closed"] += 1
		qm.close()
	return qm


func test_strip_shows_what_works_here() -> void:
	var p := _prefs_file()
	var rig := _rig()
	var qm := _menu(rig)
	qm.open(rig["session"].game)
	var strip: Control = qm.strip
	ok(strip != null and strip.visible, "the strip is in the menu")
	eq(strip.visible_ids(), Registry.STRIP_DEFAULT, "over a game: the usual eight, in order")
	for id in strip.visible_ids():
		var b: Button = strip.buttons[id]
		eq(str(b.name), "Shortcut_" + id, "%s button is named after it" % id)
		ok((b.get_node("Col/Icon") as TextureRect).texture != null, "%s has its icon" % id)
		ok(b.custom_minimum_size.x >= 56 and b.custom_minimum_size.y >= 56, "%s is a large target" % id)
		ok(b.tooltip_text != "", "%s explains itself" % id)
	# in front of the panel's rows, behind nothing: it sits between the tabs and the scroll
	var col: Node = strip.get_parent()
	ok(strip.get_index() < col.get_node("Rule").get_index(), "above the rows, outside their scroll")
	ok(not qm.find_child("Scroll", true, false).is_ancestor_of(strip) or strip.find_parent("Shortcuts") == null, "never scrolls away with them")
	rig["front"][0] = false
	strip.refresh()
	eq(strip.visible_ids(), ["screenshot", "record", "mouse_mode", "mute", "sleep"], "GameCove in front: no Keyboard, no Steam menu, no Send key")
	rig["front"][0] = true
	rig["ctl"].backend = "hhd"
	rig["controls"].missing = ["controller.desktop_mode"]
	strip.refresh()
	eq(strip.visible_ids(), ["keyboard", "screenshot", "record", "mute", "sleep"], "Handheld Daemon: no Steam menu, no Send key, no mouse mode")
	rig["controls"].missing = ["controller.desktop_mode", "system.screenshot", "audio.mute", "system.sleep"]
	rig["front"][0] = false
	rig["r"].recording = null
	strip.refresh()
	ok(not strip.visible and strip.entry() == null, "nothing works: the strip takes no room")
	qm.free()
	_done(rig)
	_prefs_done(p)


func test_strip_follows_the_saved_list() -> void:
	var p := _prefs_file()
	Prefs.set_shown("keyboard", false)
	Prefs.set_shown("wifi", true)
	Prefs.set_shown("force_close", true)
	Prefs.set_shown("power_menu", true)
	Prefs.move("mute", -1)
	var rig := _rig()
	var qm := _menu(rig)
	qm.open(rig["session"].game)
	eq(qm.strip.visible_ids(), ["steam_menu", "screenshot", "record", "mute", "mouse_mode", "send_key", "sleep", "wifi", "force_close", "power_menu"],
		"the user's shortcuts in the user's order")
	qm.close()
	Prefs.reset()
	qm.open(rig["session"].game)
	eq(qm.strip.visible_ids(), Registry.STRIP_DEFAULT, "a changed list is picked up the next time the menu opens")
	qm.free()
	_done(rig)
	_prefs_done(p)


func test_strip_buttons_act_and_show_state() -> void:
	var p := _prefs_file()
	var rig := _rig()
	var qm := _menu(rig)
	qm.open(rig["session"].game)
	var strip: Control = qm.strip
	var mute: Button = strip.buttons["mute"]
	ok(not mute.has_theme_stylebox_override("normal"), "off: the plain button")
	mute.pressed.emit()
	eq(rig["controls"].sets[-1], ["audio.mute", true], "A on Mute mutes")
	ok(mute.has_theme_stylebox_override("normal"), "on: tinted")
	ok(qm.visible, "the menu stays for a toggle")
	strip.buttons["record"].pressed.emit()
	ok(not qm.visible, "Record hands the screen back")
	qm.open(rig["session"].game)
	eq((strip.buttons["record"].get_node("Col/Name") as Label).text, "1:15", "while recording the button shows the clock")
	strip.buttons["record"].pressed.emit()
	eq((strip.buttons["record"].get_node("Col/Name") as Label).text, "Record", "stopped: Record again")
	strip.buttons["keyboard"].pressed.emit()
	ok(not qm.visible, "Keyboard closes the menu: typing lands in the game")
	ok("/usr/bin/steam -ifrunning steam://open/keyboard" in rig["run"].calls, "and Steam opens its keyboard")
	qm.free()
	_done(rig)
	_prefs_done(p)


func test_strip_sheets() -> void:
	var p := _prefs_file()
	Prefs.set_shown("force_close", true)
	Prefs.set_shown("power_menu", true)
	var rig := _rig()
	var qm := _menu(rig)
	qm.open(rig["session"].game)
	var strip: Control = qm.strip
	ok(strip.sheet == null, "no sheet is built until one is needed")
	strip.press("send_key")
	ok(strip.sheet_open(), "Send key opens its sheet")
	eq(strip.sheet.items.map(func(i): return i["text"]), ["Esc", "Enter", "Tab", "Alt + Enter", "Alt + F4"], "the five keys")
	strip.sheet.pick("key_alt_enter")
	eq(_sent(rig["run"]).slice(0, 2), ["KEY_LEFTALT true", "KEY_ENTER true"], "picking one presses it in the game")
	ok(not qm.visible, "with the menu out of the way")
	qm.open(rig["session"].game)
	strip.press("force_close")
	eq(strip.sheet.title_label.text, "Force close Hades?", "Force close asks first")
	eq(strip.sheet.items[0]["id"], "no", "Keep playing comes first")
	strip.sheet.pick("no")
	eq(rig["closer"].forced, 0, "no: nothing happens")
	strip.press("force_close")
	strip.sheet.pick("yes")
	eq(rig["closer"].forced, 1, "yes: closed")
	qm.open(rig["session"].game)
	strip.press("power_menu")
	eq(strip.sheet.items.map(func(i): return i["id"]), ["restart", "shutdown", "desktop", "steam"], "Power: restart, shut down, desktop, Steam")
	strip._open_power_confirm("restart", "")
	eq(strip.sheet.title_label.text, "Restart now?", "each asks again")
	strip.sheet.pick("no")
	ok(not rig["run"].calls.has("systemctl reboot"), "no: nothing")
	strip._open_power_confirm("restart", "")
	strip.sheet.pick("yes")
	ok(rig["run"].calls.has("systemctl reboot"), "yes: restarts")
	qm.open(rig["session"].game)
	strip.press("send_key")
	qm.close()
	ok(not strip.sheet_open(), "closing the menu closes an open sheet")
	qm.free()
	_done(rig)
	_prefs_done(p)


func test_strip_focus_chain() -> void:
	var p := _prefs_file()
	var rig := _rig()
	var qm := _menu(rig)
	qm.open(rig["session"].game)
	var strip: Control = qm.strip
	var first: Control = qm.focusables()[0]
	var entry: Button = strip.entry()
	eq(entry, strip.buttons["keyboard"], "the strip is entered at its first shortcut")
	eq(first.get_node(first.focus_neighbor_top), entry, "one Up from the first row reaches the strip")
	eq(entry.get_node(entry.focus_neighbor_bottom), first, "Down goes back to the rows")
	eq(entry.get_node(entry.focus_neighbor_top), qm.tabs[qm.section], "Up again reaches the open tab")
	eq(qm.tabs[0].get_node(qm.tabs[0].focus_neighbor_bottom), entry, "and the tabs lead down into it")
	var ids: Array = strip.visible_ids()
	for i in range(1, ids.size()):
		var b: Button = strip.buttons[ids[i]]
		eq(b.get_node(b.focus_neighbor_left), strip.buttons[ids[i - 1]], "%s: Left goes to %s" % [ids[i], ids[i - 1]])
	qm.switch_tab(1)
	eq(qm.tabs[1].get_node(qm.tabs[1].focus_neighbor_bottom), strip.entry(), "on every tab")
	var e2: Button = strip.entry()
	eq(e2.get_node(e2.focus_neighbor_top), qm.tabs[1], "under the tab that's open")
	qm.free()
	_done(rig)
	_prefs_done(p)


func test_strip_without_a_runner_is_absent() -> void:
	var qm: Control = QuickMenu.new()
	qm.setup({"device": Screens.FakeDevice.new(), "power": Screens.FakePower.new(), "launcher": Screens.FakeLauncher.new(),
		"gamescope": Screens.FakeGamescope.new()})
	qm.open({})
	ok(qm.strip == null, "no action runner passed: the menu is as it was")
	qm.free()


func test_strip_reads_in_every_theme() -> void:
	# the label under an icon is 12 px: it must hold AA (4.5:1) on the button, off and on
	for id in Themes.ORDER:
		var t: Dictionary = Themes.get_theme(id)
		ThemeLib.use(id)
		var base: Color = ThemeLib.color("glass")
		base.a = 1.0
		var row: Color = (Color(ThemeLib.color("glass_2"), ThemeLib.color("glass_2").a * 0.8) if ThemeLib.is_dark() else ThemeLib.color("surface"))
		var off := base.blend(row)
		var acc: Color = ThemeLib.color("accent")
		var on := base.blend(Color(acc, 0.12 if ThemeLib.is_dark() else 0.10))
		var text: Color = ThemeLib.color("text")
		ok(Themes.contrast(text, off) >= 4.5, "%s: label on a shortcut (%.2f)" % [id, Themes.contrast(text, off)])
		ok(Themes.contrast(text, on) >= 4.5, "%s: label on a shortcut that's on (%.2f)" % [id, Themes.contrast(text, on)])
		ok(Themes.contrast(acc, on) >= 3.0, "%s: the on icon stands out (%.2f)" % [id, Themes.contrast(acc, on)])
		ok(Themes.contrast(t["ring"], base) >= 3.0, "%s: the focus ring shows on the sheet" % id)
	ThemeLib.use("cove")


# ---- Settings > Quick menu and Settings > Media -------------------------------------------------

func test_settings_page_lists_and_moves_shortcuts() -> void:
	var p := _prefs_file()
	var rig := _rig()
	var Page = load("res://scripts/ui/settings/quick_menu_page.gd")
	var page: VBoxContainer = Page.new()
	page.setup("quick_menu", {"actions": rig["r"]}, null)
	eq(page.focusables().size(), Registry.strip_ids().size() + 1, "a row per shortcut and the reset row")
	eq(page.rows.keys().slice(0, 8), Registry.STRIP_DEFAULT, "in the strip's order")
	ok(page.rows["keyboard"].value() == true and page.rows["wifi"].value() == false, "on / off as saved")
	for id in Registry.strip_ids():
		ok(page.rows[id].hint_text().contains(Registry.action(id)["help"]), "%s: its one help line" % id)
		ok(page.rows[id].hint_text().contains(T.MOVE_HINT), "%s: says how to move it" % id)
	page.rows["wifi"].step(1)
	ok(Prefs.is_shown("wifi"), "a row's switch saves at once")
	ok(page.move("mute", -1), "move up")
	eq(page.rows.keys().slice(0, 6), ["keyboard", "steam_menu", "screenshot", "record", "mute", "mouse_mode"], "the list shows the new order")
	ok(not page.move("keyboard", -1), "the first stays first")
	ok(not page.move("", 1), "no row in focus: nothing moves")
	rig["ctl"].backend = "hhd"
	page.rebuild()
	ok(page.rows["send_key"].hint_text().contains("Needs InputPlumber"), "a shortcut that can't work here says why")
	ok(not page.rows["keyboard"].hint_text().contains("Not on this handheld"), "one that only waits for a game doesn't")
	page.reset_all()
	eq(Prefs.shown(), Registry.STRIP_DEFAULT, "reset")
	ok(page.rows["wifi"].value() == false, "and the list shows it")
	page.free()
	_done(rig)
	_prefs_done(p)


func test_screenshots_list() -> void:
	var Shots = load("res://scripts/system/screenshots.gd")
	var home := OS.get_cache_dir().path_join("gamecove_shots_%d" % Time.get_ticks_usec())
	var dir: String = Shots.root(home)
	eq(Shots.list(dir), [], "no folder: nothing")
	DirAccess.make_dir_recursive_absolute(dir)
	var img := Image.create(640, 400, false, Image.FORMAT_RGB8)
	img.save_png(dir.path_join("GameCove_20261110_101500.png"))
	img.save_png(dir.path_join("GameCove_20261110_101500_1.png"))
	img.save_png(dir.path_join("holiday.png"))
	FileAccess.open(dir.path_join("GameCove_empty.png"), FileAccess.WRITE).close()
	var list: Array = Shots.list(dir)
	eq(list.size(), 2, "GameCove's own pictures only, empty files left out")
	ok(list.all(func(s): return s.has("path") and s.has("mtime") and int(s["size"]) > 0 and s["game"] == ""), "in the shape a clip row reads")
	var small: Image = Shots.thumb(list[0]["path"])
	ok(small != null and small.get_width() == Shots.THUMB_W and small.get_height() == 160, "a small copy for the row")
	ok(Shots.thumb(dir.path_join("nope.png")) == null, "a missing file: no picture")
	ok(not Shots.delete(dir, dir.path_join("holiday.png")), "someone else's picture is never deleted")
	ok(not Shots.delete(dir, home.path_join("GameCove_x.png")), "nor anything outside the folder")
	ok(Shots.delete(dir, list[0]["path"]), "ours is")
	eq(Shots.list(dir).size(), 1, "and it's gone")
	for f in DirAccess.get_files_at(dir):
		DirAccess.remove_absolute(dir.path_join(f))
	DirAccess.remove_absolute(dir)
	DirAccess.remove_absolute(home.path_join("Pictures"))
	DirAccess.remove_absolute(home)


## feat/upscaling's "Open the upscaler's menu" reaches the registry through the
## Controls context: the key is there from setup on (never added while the worker
## runs) and the action itself runs on the main thread, through main's runner.
func test_controls_context_runs_a_shared_action() -> void:
	var src := FileAccess.get_file_as_string("res://scripts/controls/controls.gd")
	ok(src.contains("\"open_uri\": open_uri, \"run_action\": run_action})"), "run_action is in the context Controls sets up with")
	var c: Node = load("res://scripts/controls/controls.gd").new()
	var got: Array = []
	ok(c.run_action("key_optiscaler"), "handed over")
	c._run_action("key_optiscaler")
	eq(got, [], "no runner yet: nothing happens")
	c.action_handler = func(id: String) -> void: got.append(id)
	c._run_action("key_optiscaler")
	eq(got, ["key_optiscaler"], "the runner gets it on the main thread")
	var main_src := FileAccess.get_file_as_string("res://scripts/main.gd")
	ok(main_src.contains("ctls.action_handler = func(id: String) -> void: actions.run(id, \"button\", true)"), "main points it at its action runner")
	c.free()
