extends "res://tests/test_case.gd"
## The Controls UI: the model over Controls + Profiles, every widget kind and
## its states (unavailable, blocked, needs root, from profile, pending,
## failed), the "More settings" list, the Keep-this dialog, the colour and
## curve editors. Fake Controls (fixtures/ui_controls/fake_controls.gd) and
## the real Profiles with a temporary file; all synchronous.

const FakeControls := preload("res://tests/fixtures/ui_controls/fake_controls.gd")
const ProfilesScript := preload("res://scripts/controls/profiles.gd")
const Model := preload("res://scripts/ui/controls/model.gd")
const ControlView := preload("res://scripts/ui/controls/control_view.gd")
const ControlList := preload("res://scripts/ui/controls/control_list.gd")
const ColorRow := preload("res://scripts/ui/controls/color_row.gd")
const CurveRow := preload("res://scripts/ui/controls/curve_row.gd")
const KeepDialog := preload("res://scripts/ui/controls/keep_dialog.gd")
const SessionGuard := preload("res://scripts/ui/controls/session_guard.gd")
const Catalog := preload("res://scripts/ui/controls/catalog.gd")
const TC := preload("res://scripts/ui/texts_controls.gd")
const PROFILE_FILE := "user://test_ui_controls_profiles.json"


static func fake() -> Node:
	var c: Node = FakeControls.new()
	c.add({"id": "power.tdp", "title": "TDP", "kind": "slider", "min_value": 4.0, "max_value": 30.0, "step": 1.0, "unit": "W",
		"value": 15, "help": "How much power the chip may use.", "apply_order": 50})
	c.add({"id": "power.profile", "title": "Power profile", "kind": "choice", "per_game": false, "value": "balanced",
		"options": [{"value": "battery", "label": "Battery"}, {"value": "balanced", "label": "Balanced"}, {"value": "performance", "label": "Performance"}]})
	c.add({"id": "power.cpu_boost", "title": "CPU boost", "kind": "toggle", "value": true, "needs_root": true})
	c.add({"id": "power.smt", "title": "SMT", "kind": "toggle", "reason": "This CPU has no SMT"})
	c.add({"id": "power.fan_curve", "title": "Fan curve", "kind": "curve", "points": 6, "min_value": 0.0, "max_value": 100.0,
		"default_value": [0.0, 40.0, 40.0, 45.0, 60.0, 75.0], "value": [0.0, 40.0, 45.0, 50.0, 65.0, 80.0], "per_game": false})
	c.add({"id": "display.fps_limit", "title": "Frame limit", "kind": "choice", "value": 0,
		"options": [{"value": 0, "label": "Off"}, {"value": 30, "label": "30 fps"}, {"value": 60, "label": "60 fps"}]})
	c.add({"id": "display.night_light", "title": "Night light", "kind": "toggle", "value": false, "per_game": false})
	c.add({"id": "display.night_light_strength", "title": "Night light strength", "kind": "slider", "min_value": 10.0,
		"max_value": 100.0, "step": 5.0, "unit": "%", "value": 50, "requires": ["display.night_light"], "per_game": false})
	c.add({"id": "display.refresh_unlock", "title": "Unlock refresh rates", "kind": "toggle", "value": false, "per_game": false})
	c.add({"id": "display.hdr", "title": "HDR", "kind": "toggle", "value": false, "per_game": false})
	c.add({"id": "display.refresh_rate", "title": "Refresh rate", "kind": "slider", "min_value": 40.0, "max_value": 120.0, "unit": "Hz", "value": 120})
	c.add({"id": "controller.led_color", "title": "Light colour", "kind": "color", "value": "#00F0FF"})
	c.add({"id": "controller.rumble_test", "title": "Test rumble", "kind": "action", "per_game": false})
	return c


func _profiles(c: Node) -> Node:
	DirAccess.remove_absolute(ProjectSettings.globalize_path(PROFILE_FILE))
	var p: Node = ProfilesScript.new()
	p.setup(c, "msi-claw-8-ex", PROFILE_FILE)
	return p


func _model(c: Node, p: Node = null) -> Object:
	var m = Model.new()
	m.setup(c, p)
	return m


func _done(nodes: Array) -> void:
	for n in nodes:
		if n is Node and is_instance_valid(n):
			n.free()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(PROFILE_FILE))


# ---- model ----------------------------------------------------------------------

func test_model_describes_and_labels() -> void:
	var c := fake()
	var m = _model(c)
	var d: Dictionary = m.describe("power.tdp")
	eq(d["value"], 15, "value")
	eq(d["blocked"], "", "not blocked")
	eq(m.describe("display.night_light_strength")["blocked"], TC.NEEDS_FIRST % "Night light", "needs night light first")
	eq(Model.value_label(d), "15 W", "slider label with unit")
	eq(Model.value_label(m.describe("display.night_light_strength")), "50%", "percent sticks to the number")
	eq(Model.value_label(m.describe("display.fps_limit")), "Off", "choice label")
	eq(Model.value_label(m.describe("power.cpu_boost")), "On", "toggle label")
	ok(m.describe("nope").is_empty(), "unknown id")
	ok("power.tdp" in m.ids("power") and not "display.fps_limit" in m.ids("power"), "ids per group")
	_done([c])


func test_model_pending_failed_and_saving() -> void:
	var c := fake()
	var p := _profiles(c)
	p._first_detect_done = true
	var m = _model(c, p)
	var seen := []
	m.pending_changed.connect(func(id, on): seen.append([id, on]))
	c.defer = true
	ok(m.set_value("power.tdp", 12), "accepted")
	ok(m.is_pending("power.tdp") and m.describe("power.tdp")["pending"], "pending until the worker answers")
	c.flush()
	ok(not m.is_pending("power.tdp"), "answered")
	eq(seen, [["power.tdp", true], ["power.tdp", false]], "pending on, off")
	eq(p.layer("", "")["power.tdp"], 12, "a change that worked is saved as everyday")
	c.defer = false
	c.refuse["power.tdp"] = true
	m.set_value("power.tdp", 20)
	ok(m.is_failed("power.tdp"), "failed")
	eq(c.value("power.tdp"), 12.0, "value kept")
	eq(p.layer("", "")["power.tdp"], 12, "a failed change isn't saved")
	ok(not m.set_value("power.smt", true), "unavailable can't be set")
	ok(not m.set_value("display.night_light_strength", 80), "blocked can't be set")
	_done([c, p])


func test_model_auto_tdp_target_follows_the_frame_limit() -> void:
	var c := fake()
	c.add({"id": "power.autotune_target", "title": "Auto TDP target", "kind": "choice", "value": 60,
		"options": [{"value": 0, "label": "Most frames"}, {"value": 30, "label": "30 fps"}, {"value": 45, "label": "45 fps"}, {"value": 60, "label": "60 fps"}]})
	var p := _profiles(c)
	p._first_detect_done = true
	var m = _model(c, p)
	eq(Model.capped_target(60, 45, [0, 30, 45, 60]), 45, "held at the limit")
	eq(Model.capped_target(60, 40, [0, 30, 45, 60]), 30, "the highest choice under it")
	eq(Model.capped_target(60, 0, [0, 30, 45, 60]), 60, "no limit: as picked")
	m.set_value("display.fps_limit", 30)
	eq(c.value("power.autotune_target"), 30, "a 30 fps cap brings a 60 fps target down with it")
	eq(m.follow_note("power.autotune_target"), TC.TARGET_FOLLOWS % 30, "and the row says why")
	m.set_value("power.autotune_target", 60)
	eq(c.value("power.autotune_target"), 30, "can't be set above the cap")
	m.set_value("display.fps_limit", 0)
	eq(m.follow_note("power.autotune_target"), "", "no cap, no note")
	m.set_value("power.autotune_target", 60)
	eq(c.value("power.autotune_target"), 60, "free again without a cap")
	_done([c, p])


func test_model_game_profile_and_layers() -> void:
	var c := fake()
	var p := _profiles(c)
	p._first_detect_done = true
	var m = _model(c, p)
	m.set_game({"key": "steam:1", "title": "Hades"}, false)
	ok(not m.per_game(), "no profile yet")
	m.set_per_game(true)
	ok(m.per_game() and p.has_profile("steam:1"), "own settings saved")
	eq(p.games()[0]["title"], "Hades", "title remembered")
	ok(m.editing_profile(), "not running: edits only the profile")
	var before: Variant = c.value("power.tdp")
	m.set_value("power.tdp", 9)
	eq(c.value("power.tdp"), before, "nothing changes on the handheld")
	eq(p.layer("steam:1", "")["power.tdp"], 9, "saved for the game")
	eq(m.describe("power.tdp")["value"], 9.0, "shows the profile's value")
	eq(m.describe("power.tdp")["layer"], "game", "from this game")
	p.game_started({"key": "steam:1", "title": "Hades"})
	ok(m.running() and not m.editing_profile(), "running: live")
	eq(c.value("power.tdp"), 9.0, "profile applied at start")
	m.set_value("power.tdp", 11)
	eq(c.value("power.tdp"), 11.0, "live change")
	eq(p.layer("steam:1", "")["power.tdp"], 11, "and saved for the game")
	p.set_value("", "battery", "display.fps_limit", 30)
	p.game_ended({"key": "steam:1"})
	m.set_game({}, false)
	eq(m.describe("display.fps_limit")["layer"], "battery", "battery layer explained")
	eq(m.target_layer("display.fps_limit"), ["", "battery"], "a change goes back where it came from")
	m.set_game({"key": "steam:1", "title": "Hades"}, false)
	m.set_per_game(false)
	ok(not p.has_profile("steam:1"), "off forgets the game's settings")
	_done([c, p])


func test_model_set_game_redetects_once() -> void:
	var c := fake()
	var m = _model(c)
	m.set_game({"key": "steam:1"})
	m.set_game({"key": "steam:1"})
	eq(c.detect_calls, 1, "per-game controls re-detected only when the game changes")
	eq(c.ctx.get("game_key", ""), "steam:1", "perf provider context follows the game")
	_done([c])


# ---- views ----------------------------------------------------------------------

func test_view_kinds() -> void:
	var c := fake()
	var m = _model(c)
	var kinds := {"power.tdp": "SliderRow", "power.profile": "ChoiceRow", "power.cpu_boost": "ChoiceRow",
		"power.fan_curve": "CurveRow", "controller.led_color": "ColorRow", "controller.rumble_test": "ActionRow", "power.smt": "ActionRow"}
	for id in kinds:
		var v: Control = ControlView.make(m, id)
		ok(v != null and v.row != null and v.button != null, id + " built")
		ok(v.button in v.focusables(), id + " focusable")
		v.free()
	ok(ControlView.make(m, "nope") == null, "unknown id gives null")
	_done([c])


func test_view_unavailable_blocked_root_badges() -> void:
	var c := fake()
	var m = _model(c)
	var smt: Control = ControlView.make(m, "power.smt")
	eq(smt.row.hint_text(), "This CPU has no SMT", "reason under it")
	ok(not smt.row.collapse_hint, "reason always shows")
	var st: Control = ControlView.make(m, "display.night_light_strength")
	ok(not st.row.slider.editable, "blocked slider locked")
	eq(st.row.hint_text(), TC.NEEDS_FIRST % "Night light", "says what to turn on")
	m.set_value("display.night_light", true)
	ok(st.row.slider.editable, "unlocks when the dependency turns on")
	var boost: Control = ControlView.make(m, "power.cpu_boost")
	ok(boost.row.badge_slot().get_node_or_null("Lock") != null, "lock chip for root controls")
	ok(TC.ROOT_HELP in boost.explanation(), "root explained")
	for v in [smt, st, boost]:
		v.free()
	_done([c])


func test_view_changes_pending_and_failure() -> void:
	var c := fake()
	var m = _model(c)
	var v: Control = ControlView.make(m, "power.profile")
	c.defer = true
	v.row.step(1)
	ok(v.row.badge_slot().get_node_or_null("Pending") != null, "pending chip while applying")
	c.flush()
	ok(v.row.badge_slot().get_node_or_null("Pending") == null, "chip gone")
	eq(c.value("power.profile"), "performance", "written")
	c.defer = false
	c.refuse["power.profile"] = true
	v.row.step(1)
	eq(v.row.value(), "performance", "failed change rolls back")
	ok(v.status_label.visible and "Performance" in v.status_label.text, "failure explained with the kept value")
	c.refuse.clear()
	v.row.step(-1)
	ok(not v.status_label.visible, "failure line clears")
	var s: Control = ControlView.make(m, "power.tdp")
	s.row.slider.value = 20
	s.row._on_value_changed(20.0)   # Range only signals inside the tree
	eq(c.value("power.tdp"), 20.0, "slider writes (settles at once outside the tree)")
	eq(s.row.value_text(), "20 W", "value text")
	c.set_available("power.tdp", false, "No TDP service")
	c.detect_all()
	eq(s.row.hint_text(), "No TDP service", "goes unavailable after detection")
	v.free()
	s.free()
	_done([c])


func test_view_from_profile_badge() -> void:
	var c := fake()
	var p := _profiles(c)
	var m = _model(c, p)
	var v: Control = ControlView.make(m, "display.fps_limit")
	ok(v.row.badge_slot().get_node_or_null("From") == null, "no chip for a live value")
	p.set_value("", "battery", "display.fps_limit", 30)
	var chip: Node = v.row.badge_slot().get_node_or_null("From")
	ok(chip != null, "chip names the battery layer")
	ok(TC.LAYER_HELP["battery"] in v.explanation(), "layer explained")
	m.set_game({"key": "steam:1", "title": "Hades"}, false)
	p.set_value("steam:1", "", "display.fps_limit", 60)
	eq(v.row.value(), 60, "profile value shown while editing")
	ok(v.row.badge_slot().get_node_or_null("From") == null, "no chip per row when the whole game has its own settings")
	v.free()
	_done([c, p])


func test_keep_dialog_reverts_by_itself() -> void:
	var c := fake()
	var m = _model(c)
	var host := Control.new()
	var v: Control = ControlView.make(m, "display.hdr", {"dialog_host": host})
	v.row.step(1)
	eq(c.value("display.hdr"), true, "applied")
	var dlg: Control = host.get_node_or_null("KeepDialog")
	ok(dlg != null, "asks to keep it")
	eq(dlg.count_label.text, TC.KEEP_REVERT % 15, "15 s countdown")
	for i in 15:
		dlg.tick()
	eq(c.value("display.hdr"), false, "went back by itself")
	# refresh rate gets the check only once rates were unlocked by us
	var r: Control = ControlView.make(m, "display.refresh_rate", {"dialog_host": host})
	ok(not r._needs_confirm(), "no check on stock rates")
	c.control("display.refresh_unlock").write(true)
	ok(r._needs_confirm(), "check after unlocking")
	var n := host.get_child_count()
	r.row.slider.value = 60
	r.row._on_value_changed(60.0)
	ok(host.get_child_count() > n, "dialog for the new rate")
	var d2: Control = host.get_child(host.get_child_count() - 1)
	d2.finish(true)
	eq(c.value("display.refresh_rate"), 60.0, "kept")
	v.free()
	r.free()
	host.free()
	_done([c])


func test_unlock_asks_in_the_next_session() -> void:
	SessionGuard.path = "user://test_controls_confirm.json"
	SessionGuard.clear()
	var c := fake()
	var m = _model(c)
	var v: Control = ControlView.make(m, "display.refresh_unlock")
	v.row.step(1)
	eq(c.value("display.refresh_unlock"), true, "applied (for the next session)")
	eq(v.status_label.text, TC.NEXT_SESSION, "says it waits for a restart")
	var p: Dictionary = SessionGuard.pending()
	eq(p.get("id"), "display.refresh_unlock", "remembered")
	var host := Control.new()
	ok(SessionGuard.check(host, c) == null, "same session: nothing to ask yet")
	var dlg: Control = SessionGuard.check(host, c, null, OS.get_process_id() + 1)
	ok(dlg != null, "next session asks")
	ok(SessionGuard.pending().is_empty(), "asked once")
	for i in 15:
		dlg.tick()
	eq(c.value("display.refresh_unlock"), false, "nobody kept it: back off")
	v.free()
	host.free()
	SessionGuard.clear()
	SessionGuard.path = "user://controls_confirm.json"
	_done([c])


func test_color_row() -> void:
	var r: VBoxContainer = ColorRow.new()
	r.setup("Light colour", "#00f0ff")
	eq(r.index, 0, "matches a swatch")
	eq(r.value_text(), "#00F0FF", "upper-case hex")
	var got := []
	r.changed.connect(func(v): got.append(v))
	var right := InputEventAction.new()
	right.action = "ui_right"
	right.pressed = true
	r._on_strip_input(right)
	eq(got[-1], ColorRow.SWATCHES[1], "right picks the next swatch")
	r.hue.value = 120
	r._on_hue(120.0)   # Range only signals inside the tree
	eq(got[-1], "#00FF00", "hue slider gives a full colour")
	eq(r.index, -1, "custom colour")
	r.set_locked(true)
	r._pick(3)
	eq(got.size(), 2, "locked: no change")
	eq(r.focusables().size(), 2, "swatches and hue")
	r.free()


func test_curve_row() -> void:
	var r: VBoxContainer = CurveRow.new()
	r.setup("Fan curve", {"min": 0.0, "max": 100.0, "default": [0.0, 40.0, 40.0, 45.0, 60.0, 75.0], "value": [0.0, 40.0, 45.0, 50.0, 65.0, 80.0]})
	var got := []
	r.changed.connect(func(v): got.append(v))
	r.toggle_edit()
	ok(r.editing, "A starts editing")
	r.selected = 2
	r.nudge(2, 30.0)
	eq(r.points.slice(2), [75.0, 75.0, 75.0, 80.0], "later points rise with it")
	r.nudge(2, -60.0)
	eq(r.points[2], 40.0, "never under the quiet floor")
	ok(r.points[1] <= r.points[2], "never falls")
	r.cancel()
	eq(r.points, [0.0, 40.0, 45.0, 50.0, 65.0, 80.0], "B puts it back")
	eq(got, [], "nothing saved")
	r.toggle_edit()
	r.nudge(5, 20.0)
	r.toggle_edit()
	eq(got[-1][5], 100.0, "A saves")
	r.free()


# ---- list ----------------------------------------------------------------------

func test_list_more_and_hidden() -> void:
	var c := fake()
	var m = _model(c)
	var l: VBoxContainer = ControlList.new()
	l.setup(m, ["power.tdp", "power.smt"], ["power.cpu_boost"])
	eq(l.placement(), [["power.tdp"], ["power.cpu_boost", "power.smt"]], "unavailable moves behind More, after advanced")
	eq(l.focusables().size(), 2, "TDP and the More row")
	l.toggle_more()
	eq(l.focusables().size(), 4, "More opens")
	var q: VBoxContainer = ControlList.new()
	q.setup(m, ["power.tdp", "power.smt"], [], {"hide_unavailable": true})
	eq(q.placement(), [["power.tdp"], []], "quick menu hides what can't be used")
	eq(q.more_row, null, "no More row")
	c.set_available("power.smt", true)
	c.detect_all()
	eq(q.placement()[0], ["power.tdp", "power.smt"], "re-laid out when it becomes available")
	l.free()
	q.free()
	_done([c])


## Each layout took the old "More settings" row out and dropped it without
## freeing it: every More / Less press (and every re-layout after detection)
## leaked a row of nodes. Found by the end-to-end suite (orphan node count).
func test_list_frees_its_old_more_rows() -> void:
	var c := fake()
	var m = _model(c)
	var l: VBoxContainer = ControlList.new()
	l.setup(m, ["power.tdp", "power.smt"], ["power.cpu_boost"])
	var olds: Array = []
	for i in 4:
		olds.append(l.more_row)
		l.toggle_more()
	for o in olds:
		ok(not is_instance_valid(o) or o.is_queued_for_deletion(), "an old More row is freed, not orphaned")
	ok(is_instance_valid(l.more_row) and l.more_row.get_parent() == l, "the current one is in the list")
	l.free()
	_done([c])


func test_low_latency_is_only_an_override() -> void:
	for tab in Catalog.QUICK:
		ok(not "perf.low_latency" in Catalog.QUICK[tab], "not in the quick menu's %s tab" % tab)
	var cards := Catalog.cards_for(["perf"], ["perf.proton", "perf.low_latency"])
	var card: Array = cards.filter(func(cd): return "perf.low_latency" in cd[2] + cd[3])[0]
	ok("troubleshooting" in str(card[0]).to_lower(), "under troubleshooting")
	ok("perf.low_latency" in card[3], "behind More settings, not in the main list")


## The screen's scaling filter (gamescope) and the game's upscaler (XeSS / FSR)
## sit in the same quick menu tab: they must never read alike.
func test_scaling_filter_is_not_called_an_upscaler() -> void:
	var TD = load("res://scripts/controls/display/texts_display.gd")
	eq(Catalog.SHORT_TITLES["display.upscale_filter"], "Scaling filter", "quick menu title")
	eq(TD.TEXT["display.upscale_filter"][0], "Scaling filter", "full title")
	for t in [Catalog.SHORT_TITLES["display.upscale_filter"], TD.TEXT["display.upscale_filter"][0]]:
		ok(not t.to_lower().contains("upscaler"), t)


func test_catalog_covers_everything() -> void:
	var all := ["power.tdp", "power.new_thing", "controller.paddle.LeftPaddle1", "controller.paddle.RightPaddle1"]
	var cards := Catalog.cards_for(["power", "controller"], all)
	var ids := []
	for card in cards:
		ids.append_array(card[2] + card[3])
	for id in all:
		ok(id in ids, id + " has a place")
	eq(cards[-1][0], "Other", "unknown ids go to Other")
	var paddles: Array = cards.filter(func(cd): return cd[0] == "Back buttons")
	eq(paddles[0][2], ["controller.paddle.LeftPaddle1", "controller.paddle.RightPaddle1"], "prefix ids expand")
