extends "res://tests/test_case.gd"
## Settings screen, its pages, QR sign-in, first-run setup and the quick menu
## additions, all with fake services. Nothing touches the real system.

const SettingsScreen := preload("res://scripts/ui/settings_screen.gd")
const SetupFlow := preload("res://scripts/ui/setup/setup_flow.gd")
const QR := preload("res://scripts/ui/settings/qr.gd")
const Credits := preload("res://scripts/ui/settings/credits.gd")
const SignIn := preload("res://scripts/ui/settings/sign_in.gd")
const DevicePage := preload("res://scripts/ui/settings/device_page.gd")
const PerformancePage := preload("res://scripts/ui/settings/performance_page.gd")
const QuickMenu := preload("res://scripts/ui/quick_menu.gd")
const TS := preload("res://scripts/ui/texts_settings.gd")
const Screens := preload("res://tests/test_ui_screens.gd")
const Osk := preload("res://scripts/ui/osk.gd")


class FakeSetup extends RefCounted:
	signal changed(steps: Array)
	signal login_started(store: String, info: Dictionary)
	signal login_finished(store: String, ok: bool, message: String)
	signal fixes_checked(fixes: Array)
	var done := {}
	var skipped := {}
	var key := ""
	var status := {
		"steam": {"signed_in": true, "account": "hulk", "how": "steam"},
		"epic": {"signed_in": false, "account": "", "how": "code"},
		"gog": {"signed_in": false, "account": "", "how": "heroic"},
		"amazon": {"signed_in": false, "account": "", "how": "redirect_url"},
	}
	var fixes := ["claw8ex-buttons", "claw8ex-vrr"]
	var calls: Array = []
	func steps() -> Array:
		var out: Array = []
		for s in ["welcome", "theme", "stores", "device_fixes", "steamgriddb", "done"]:
			out.append({"id": s, "optional": s in ["theme", "stores", "device_fixes", "steamgriddb"], "done": done.has(s), "skipped": skipped.has(s), "status": {}})
		return out
	func is_first_run() -> bool: return not done.has("done")
	func next_step() -> String:
		for s in steps():
			if not s["done"] and not s["skipped"]:
				return s["id"]
		return "done"
	func complete(s: String) -> bool:
		done[s] = true
		skipped.erase(s)
		changed.emit(steps())
		return true
	func skip(s: String) -> bool:
		skipped[s] = true
		changed.emit(steps())
		return true
	func store_status() -> Dictionary: return status.duplicate(true)
	func start_login(store: String) -> bool:
		calls.append(["start", store])
		login_started.emit(store, {"store": store, "url": "https://legendary.gl/epiclogin", "needs": status[store]["how"], "param": "authorizationCode"})
		return true
	func finish_login(store: String, text: String) -> bool:
		calls.append(["finish", store, text])
		var ok := text == "good"
		if ok:
			status[store]["signed_in"] = true
		login_finished.emit(store, ok, "" if ok else "sign-in failed")
		return true
	func cancel_login(store: String) -> void: calls.append(["cancel", store])
	func suggested_fixes() -> Array: return fixes.duplicate()
	func check_fixes() -> void:
		var out: Array = []
		for f in fixes:
			out.append({"name": f, "applies": true, "installed": f == "claw8ex-buttons", "state": "on" if f == "claw8ex-buttons" else "off", "status": {}})
		fixes_checked.emit(out)
	func steamgriddb_key() -> String: return key
	func set_steamgriddb_key(k: String) -> bool:
		if k != "" and not (k.length() == 32 and k.is_valid_hex_number()):
			return false
		key = k
		return true


class FakeLibrary extends RefCounted:
	signal store_settings_changed
	var s := {"install_root": "/home/deck/Games", "steam_cef": false, "auto_resume": true, "max_parallel": 1,
		"focus_steam_dialogs": true, "steam_cef_status": "off", "steam_pending_count": 0}
	var sets: Array = []
	var applied: Array = []
	func store_settings() -> Dictionary: return s.duplicate()
	func set_store_setting(k: String, v: Variant) -> bool:
		sets.append([k, v])
		s[k] = v
		store_settings_changed.emit()
		return true
	func install_locations() -> Array:
		return [{"path": "/home/deck/Games", "label": "Internal", "free": 200000000000, "removable": false},
			{"path": "/run/media/deck/SD/Games", "label": "SD card", "free": 400000000000, "removable": true}]
	func apply_pending_steam_changes(restart := false) -> Dictionary:
		applied.append(restart)
		return {"ok": true, "via": "steam-restart", "why": ""}


class FakeDiscover extends RefCounted:
	signal settings_changed
	const SETTINGS_INFO := {
		"country": {"label": "Store country", "help": "Prices as stores charge them here.", "setup": true},
		"steam_id": {"label": "Steam profile", "help": "To import your wishlist.", "setup": true},
		"ggdeals_key": {"label": "gg.deals key (optional)", "help": "Real local prices.", "setup": true},
		"ggdeals_keyshops": {"label": "Show key-shop prices", "help": "Grey market resellers.", "setup": false},
		"steamgriddb_key": {"label": "SteamGridDB key (optional)", "help": "Artwork.", "setup": false},
		"alerts": {"label": "Price and release alerts", "help": "Price drops.", "setup": false},
		"affiliate_links": {"label": "Affiliate links", "help": "Supports GameCove.", "setup": false},
	}
	var s := {"country": "", "steam_id": "", "steamgriddb_key": "", "ggdeals_key": "", "ggdeals_keyshops": false, "alerts": true, "affiliate_links": true}
	var links: Array = []
	func get_settings() -> Dictionary:
		var out := s.duplicate()
		out["country_effective"] = "CA" if s["country"] == "" else s["country"]
		out["country_source"] = "timezone" if s["country"] == "" else "settings"
		return out
	func set_settings(patch: Dictionary) -> void:
		s.merge(patch, true)
		settings_changed.emit()
	func open_link(l: Dictionary) -> bool:
		links.append(l)
		return true


class FakePerf extends RefCounted:
	signal overlay_changed(level: int)
	var level := 0
	var supported := true
	var needs_overlay := false
	func overlay_supported() -> bool: return supported
	func overlay_level() -> int: return level
	func overlay_levels() -> Array: return ["off", "fps", "compact", "full"]
	func set_overlay_level(l: int) -> bool:
		if not supported:
			return false
		level = l
		overlay_changed.emit(l)
		return true
	func capabilities() -> Dictionary:
		return {"fps": true, "overlay": supported, "fps_needs_overlay": needs_overlay, "sources": {"fps": "mangohud", "package_w": "rapl", "cpu_load": "proc"}}


## Device with a picture, for the setup screenshots.
class FakeDevicePic extends "res://tests/test_ui_screens.gd".FakeDevice:
	func picture() -> String:
		return load("res://scripts/device/device.gd").picture_for("msi-claw-8-ex")


class FakeAchievements extends RefCounted:
	var fetch_rarity := true


class FakeSession extends Node:
	signal started(game: Dictionary)
	signal ended(game: Dictionary)
	var game := {}
	func is_active() -> bool: return not game.is_empty()


class FakeAutoPower extends "res://tests/test_ui_screens.gd".FakePower:
	signal autotune_limit(cant_reach: bool, info: Dictionary)
	signal autotune_changed(on: bool)
	var auto := true
	func autotune_active() -> bool: return auto
	func autotune_limit_info() -> Dictionary: return {"cant_reach": false}


func _svc() -> Dictionary:
	return {"setup": FakeSetup.new(), "library": FakeLibrary.new(), "discover": FakeDiscover.new(),
		"perf": FakePerf.new(), "achievements": FakeAchievements.new(), "device": Screens.FakeDevice.new()}


func _screen(svc := _svc()) -> Control:
	var s: Control = SettingsScreen.new()
	s.set_services(svc)
	s.setup({"theme": "cove", "match_art": true, "reduce_motion": false, "menu_side": "right", "ui_sounds": "low"}, [["GameCove", "0.3.0"]])
	return s


func _texts(n: Node, out: Array = []) -> Array:
	if n is Label or n is Button:
		out.append(n.text)
	if n is RichTextLabel:
		out.append(n.text)
	for c in n.get_children():
		_texts(c, out)
	return out


func _has_text(n: Node, needle: String) -> bool:
	for t in _texts(n):
		if needle in t:
			return true
	return false


# ------------------------------------------------------------ settings screen

func test_categories_and_focus_chain() -> void:
	var s := _screen()
	eq(s.cat_buttons.keys(), TS.CATEGORIES, "six categories in order")
	eq(s.rows.keys(), ["theme", "match_art", "reduce_motion", "menu_side", "ui_sounds"], "UI pref rows kept for main.gd")
	eq(s.version, "0.3.0", "version from the about lines")
	ok(s.pages["appearance"].visible and not s.pages["stores"].visible, "Appearance shows first")
	var cat: Button = s.cat_buttons["appearance"]
	var first: Control = s.pages["appearance"].focusables()[0]
	eq(cat.get_node(cat.focus_neighbor_right), first, "right from the list enters the page")
	eq(first.get_node(first.focus_neighbor_left), cat, "left from the page returns to its category")
	s.show_category("stores")
	ok(s.pages["stores"].visible and not s.pages["appearance"].visible, "stores page shown")
	var sc: Button = s.cat_buttons["stores"]
	eq(sc.get_node(sc.focus_neighbor_right), s.pages["stores"].focusables()[0], "chain follows the category")
	eq(s.default_focus(), sc, "default focus is the current category")
	s.setup({"theme": "light"}, [])
	eq(s.category, "stores", "rebuild (theme change) keeps the category")
	s.free()


func test_appearance_changes_go_to_main() -> void:
	var s := _screen()
	var got: Array = []
	s.changed.connect(func(k, v): got.append([k, v]))
	s.rows["theme"].step(1)
	s.rows["ui_sounds"].step(1)
	eq(got, [["theme", "midnight"], ["ui_sounds", "medium"]], "changes reported")
	ok(_has_text(s.pages["appearance"], "audio driver"), "sounds note explains why they're silent")
	ok(s.swatches.get_child_count() == 4, "four theme previews")
	s.free()


func test_stores_page() -> void:
	var svc := _svc()
	var s := _screen(svc)
	var p: VBoxContainer = s.pages["stores"]
	for store in ["steam", "epic", "gog", "amazon"]:
		ok(p.rows.has("store_" + store), "row for " + store)
	eq(p.rows["store_steam"].value_label.text, TS.SIGNED_IN, "steam signed in")
	eq(p.rows["store_epic"].value_label.text, TS.SIGN_IN, "epic offers sign-in")
	ok(TS.SIGN_IN_HEROIC in p.rows["store_gog"].hint_text(), "gog explains Heroic")
	ok(_has_text(p, TS.STEAM_CONTROL_WARNING), "Steam control warning shown, word for word")
	eq(p.rows["install_root"].values, ["/home/deck/Games", "/run/media/deck/SD/Games"], "install folders")
	ok("SD card" in str(p.rows["install_root"].labels[1]), "folder label")
	p.rows["steam_cef"].step(1)
	eq(svc["library"].sets[0], ["steam_cef", true], "Steam control turned on through Library")
	p.rebuild()
	ok(_has_text(p, TS.STEAM_CEF_STATUS["off"]), "status line while on")
	p.rows["max_parallel"].step(1)
	eq(svc["library"].s["max_parallel"], 2, "parallel downloads")
	ok(p.find_child("RestartSteam", true, false) == null, "no restart button without pending changes")
	svc["library"].s["steam_pending_count"] = 2
	p.rebuild()
	var b: Button = p.find_child("RestartSteam", true, false)
	ok(b != null and b in p.focusables(), "restart button in the focus chain")
	ok(_has_text(p, "2 Steam changes waiting"), "pending count")
	b.pressed.emit()
	eq(svc["library"].applied, [true], "restarts Steam to apply")
	s.free()


func test_sign_in_sheet_qr_and_code() -> void:
	var svc := _svc()
	var s := _screen(svc)
	s.open_sign_in("epic")
	var si: HBoxContainer = s.sign_in
	eq(si.state, "ready", "login url arrived")
	ok(si.qr_rect.texture != null and si.qr_rect.texture.get_width() > 100, "QR code drawn")
	ok(not si.type_button.disabled, "Type code available")
	si.submit("bad")
	eq(si.state, "ready", "bad code: try again")
	ok("didn't work" in si.status.text, "failure explained")
	si.submit("good")
	eq(si.state, "done", "signed in")
	eq(svc["setup"].calls.filter(func(c): return c[0] == "finish").size(), 2, "both codes sent")
	s.close_sheet()
	ok(not svc["setup"].calls.any(func(c): return c[0] == "cancel"), "a finished sign-in isn't cancelled")
	s.open_sign_in("amazon")
	ok(s.sign_in.steps_box.get_child_count() == 3, "three steps")
	ok("address" in _texts(s.sign_in.steps_box)[3], "amazon asks for the whole address")
	s.close_sheet()
	ok(svc["setup"].calls.has(["cancel", "amazon"]), "backing out cancels the open sign-in")
	s.free()


func test_keyboard_for_codes() -> void:
	var k: PanelContainer = Osk.new()
	k.use_for_codes("Code")
	k.open("")
	eq(k.field.text, "Code", "placeholder")
	k.type("a")
	k.shift_button.button_pressed = true
	k.type("b")
	eq(k.text, "aB", "shift types capitals")
	for i in 60:
		k.type("x")
	eq(k.text.length(), 62, "codes can be longer than search")
	ok(k.field.text.begins_with("…"), "long text shows its end")
	var search: PanelContainer = Osk.new()
	search.open("")
	for i in 60:
		search.type("x")
	eq(search.text.length(), Osk.MAX_LEN, "search keyboard unchanged")
	k.free()
	search.free()


func test_discover_page_keys() -> void:
	var svc := _svc()
	var s := _screen(svc)
	var p: VBoxContainer = s.pages["discover"]
	eq(p.rows["country"].labels[0], "Auto (CA)", "auto country names the detected one")
	ok("time zone" in p.rows["country"].hint_text(), "and where it came from")
	p.rows["country"].step(2)
	eq(svc["discover"].s["country"], "CA", "country override saved")
	ok(not p.save_key("steamgriddb_key", "nothex", "SteamGridDB key", func(t): return t.length() == 32), "bad SteamGridDB key refused")
	ok(_has_text(s, "doesn't look like"), "and explained")
	var k := "0123456789abcdef0123456789abcdef"
	ok(p.save_key("steamgriddb_key", k, "SteamGridDB key", func(t): return t.length() == 32), "good key saved")
	eq(svc["setup"].key, k, "Setup keeps the SteamGridDB key")
	eq(svc["discover"].s["steamgriddb_key"], k, "Discover too, for art")
	p.rebuild()
	eq(p.rows["steamgriddb_key"].value_label.text, "••••cdef", "key shown masked")
	ok(_has_text(p, TS.AFFILIATE_NOTE), "affiliate note")
	p.rows["affiliate_links"].step(1)
	eq(svc["discover"].s["affiliate_links"], false, "affiliate links off")
	s.free()


func test_performance_page() -> void:
	var svc := _svc()
	svc["perf"].needs_overlay = true
	var s := _screen(svc)
	var p: VBoxContainer = s.pages["performance"]
	eq(p.rows["overlay"].labels, TS.OVERLAY_LABELS, "overlay levels")
	p.rows["overlay"].step(1)
	eq(svc["perf"].level, 1, "overlay level set through PerfMonitor")
	ok(p.find_child("FpsNeedsOverlay", true, false) != null, "fps_needs_overlay explained")
	ok(_has_text(p, "Measured here: frame rate, power, CPU load"), "what's measured")
	var path := "user://test_settings_prefs.cfg"
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	var a := FakeAchievements.new()
	PerformancePage.set_rarity(a, false, path)
	eq(a.fetch_rarity, false, "rarity off")
	var b := FakeAchievements.new()
	PerformancePage.restore_rarity(b, path)
	eq(b.fetch_rarity, false, "remembered across starts")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	svc["perf"].supported = false
	p.rebuild()
	ok(p.find_child("OverlayMissing", true, false) != null and not p.rows.has("overlay"), "no overlay: explained, no row")
	s.free()


func test_device_page_loader() -> void:
	var s := _screen()
	var p: VBoxContainer = s.pages["device"]
	eq(p.get_child_count(), 0, "nothing built until shown")
	s.show_category("device")
	for id in ["about", "controller", "storage", "updates"]:
		if DevicePage.panel_script(id) == "":
			ok(p.find_child("Placeholder_" + id, true, false) != null, "placeholder for " + id)
	ok(_has_text(p, "MSI Claw 8 EX AI+"), "about placeholder still names the device")
	s.free()
	var d: VBoxContainer = DevicePage.new()
	d.panel_dir = "res://tests/fixtures/settings/device/"
	d.setup("device", {"storage": "fake"}, null)
	d.on_shown()
	var panel: Control = d.panels.get("storage")
	ok(panel != null, "storage panel loaded from its build()")
	eq(panel.got, {"storage": "fake"}, "panel got the services")
	eq(panel.opened_count, 1, "opened() on show")
	eq(d.focusables().size(), 1, "panel's buttons join the focus chain")
	d.on_hidden()
	eq(panel.closed_count, 1, "closed() on hide")
	ok(d.find_child("Placeholder_about", true, false) != null, "missing panels still get placeholders")
	d.free()


func test_about_page_checklist_and_links() -> void:
	var svc := _svc()
	svc["setup"].done["theme"] = true
	svc["setup"].skipped["stores"] = true
	var s := _screen(svc)
	var p: VBoxContainer = s.pages["about"]
	eq(p.rows["setup_theme"].value_label.text, "Done", "theme done")
	eq(p.rows["setup_stores"].value_label.text, "Skipped", "stores skipped")
	eq(p.rows["setup_keys"].value_label.text, "To do", "keys to do")
	ok(_has_text(p, "0.3.0"), "version shown")
	p.rows["source"].button.pressed.emit()
	eq(svc["discover"].links[0]["uri"], TS.REPO_URL, "links open through Discover (Steam's browser)")
	var asked: Array = []
	s.setup_requested.connect(func(step): asked.append(step))
	p.rows["setup_keys"].button.pressed.emit()
	eq(asked, ["keys"], "checklist row reopens that step")
	s.open_credits()
	var r: RichTextLabel = s.sheet.find_child("Credits", true, false)
	ok(r != null and r.text.length() > 100, "credits text loaded")
	s.free()


func test_credits_markdown() -> void:
	var md := "# Credits\n\n## People\n\n- **Kisenir**: gyro.\n\n| Project | What for | License |\n| --- | --- | --- |\n| gamescope | Display | BSD-2-Clause |\n\nSee [CREDITS](x.md) and `code`."
	var bb := Credits.to_bbcode(md)
	ok("[b]Kisenir[/b]" in bb, "bold")
	ok("gamescope[/b]" in bb and "BSD-2-Clause" in bb, "table row kept")
	ok(not "| ---" in bb and not "What for" in bb, "table header and rule dropped")
	ok("See CREDITS and code." in bb, "links and code become plain text")


func test_qr_encoder() -> void:
	var m := QR.modules("HELLO WORLD")
	eq(m["size"], 21, "short text fits version 1")
	var d: PackedByteArray = m["data"]
	var n: int = m["size"]
	# Finder pattern: dark border, light ring, dark centre (top-left corner).
	eq([d[0], d[6], d[n + 1], d[2 * n + 2], d[3 * n + 3]], [1, 1, 0, 1, 1], "finder pattern")
	eq(d[n - 1], 1, "top-right finder")
	eq(d[(n - 1) * n], 1, "bottom-left finder")
	var long := QR.modules(TS.REPO_URL + "/a/very/long/path?with=a&query=string&and=more&stuff=here&x=" + "y".repeat(100))
	ok(long["size"] > 21 and (long["size"] - 17) % 4 == 0, "longer text grows the version")
	ok(QR.texture("") == null, "nothing for empty text")


func test_hints() -> void:
	var s := _screen()
	var h: Array = s.hints(s.cat_buttons["stores"])
	eq(h[0], ["A", "Open"], "category: A opens")
	eq(h[1], ["B", "Home"], "category: B home")
	var row: Button = s.rows["theme"].button
	h = s.hints(row)
	eq(h[0], ["LR", "Change"], "choice row: change")
	eq(h[1], ["B", "Categories"], "in a page B goes back to the list")
	s.free()


# ------------------------------------------------------------ first-run setup

func test_setup_flow_steps() -> void:
	var svc := _svc()
	ok(SetupFlow.should_show(svc["setup"]), "first run")
	var host := Control.new()
	var f: Control = SetupFlow.open(host, svc, "")
	eq(f.step, "welcome", "starts at welcome")
	eq(SetupFlow.instance, f, "one flow")
	eq(SetupFlow.open(host, svc, ""), f, "opening again returns the open one")
	ok(_has_text(f, "MSI Claw 8 EX AI+"), "welcome names the device")
	f.next_step()
	eq(f.step, "theme", "theme next")
	ok(svc["setup"].done.has("welcome"), "welcome completed")
	var got: Array = []
	f.setting_changed.connect(func(k, v): got.append([k, v]))
	f.pick_theme("sunset")
	eq(got, [["theme", "sunset"]], "theme pick goes to the host")
	eq(f.focusables().size(), 4, "four theme choices")
	f.next_step()
	eq(f.step, "stores", "stores next")
	f.open_sign_in("epic")
	ok(f.sign_in != null and f.sign_in.state == "ready", "QR sign-in inline")
	f.sign_in.submit("good")
	ok(svc["setup"].done.has("stores"), "signing in completes the step")
	f.go("stores")
	f.skip_step()
	eq(f.step, "keys", "keys next")
	ok(not f.save_key("steamgriddb_key", "nope"), "bad key refused")
	ok(f.save_key("ggdeals_key", "AbCdEf123456"), "gg.deals key saved")
	eq(svc["discover"].s["ggdeals_key"], "AbCdEf123456", "into Discover")
	f.skip_step()
	ok(svc["setup"].skipped.has("steamgriddb"), "keys skipped")
	eq(f.step, "fixes", "fixes next")
	ok(f.find_child("Fix_claw8ex-vrr", true, false) != null, "suggested fixes listed")
	ok(_has_text(f, "Desktop Mode"), "installs need Desktop Mode")
	f.go_back()
	eq(f.step, "keys", "back works")
	f.go("done")
	ok(_has_text(f, TS.DONE_LATER), "skipped steps mentioned")
	var closed := [false]
	f.closed.connect(func(): closed[0] = true)
	f.next_step()
	ok(closed[0] and SetupFlow.instance == null, "finished and closed")
	ok(not svc["setup"].is_first_run(), "not a first run any more")
	host.free()


func test_setup_skip_all() -> void:
	var svc := _svc()
	var host := Control.new()
	var f: Control = SetupFlow.open(host, svc, "")
	f.skip_step()
	ok(not svc["setup"].is_first_run(), "Skip setup ends the first run")
	ok(svc["setup"].skipped.has("stores") and svc["setup"].skipped.has("steamgriddb"), "optional steps marked skipped")
	ok(SetupFlow.instance == null, "closed")
	var f2: Control = SetupFlow.open(host, svc, "keys")
	eq(f2.step, "keys", "reopens at a given step")
	f2.finish()
	host.free()
	ok(SetupFlow.open_if_first_run(Control.new(), svc) == null, "no flow once setup is done")


# ------------------------------------------------------------ quick menu

func test_quick_menu_partial_support() -> void:
	var m: Control = QuickMenu.new()
	var svc: Dictionary = Screens.new()._services()
	svc["device"].profile["support"] = "partial"
	svc["device"].profile["unverified"] = ["tdp", "panel.vrr"]
	m.setup(svc)
	m.open({})
	m.show_section(4)
	ok(_has_text(m.body, TS.QM_SUPPORT_PARTIAL), "partial support explained")
	ok(_has_text(m.body, "Not confirmed yet: power limits, VRR range."), "unverified fields named")
	m.free()


func test_quick_menu_performance_and_autotdp() -> void:
	var m: Control = QuickMenu.new()
	var power := FakeAutoPower.new()
	var perf := FakePerf.new()
	perf.needs_overlay = true
	var svc: Dictionary = Screens.new()._services(power)
	svc["perf"] = perf
	m.setup(svc)
	m.open({})
	m.show_section(1)
	ok(m.body.get_node_or_null("AutoTdp") != null, "Auto TDP state shown")
	var overlay: Control = m.body.get_node_or_null("overlay")
	ok(overlay != null and overlay.button in m.focusables(), "overlay row in Power")
	overlay.step(1)
	eq(perf.level, 1, "overlay level set")
	ok(m.body.get_node_or_null("FpsNeedsOverlay") != null, "fps needs overlay note")
	power.autotune_limit.emit(true, {"cant_reach": true, "target_fps": 60, "ceiling_w": 15.0, "tdp_max": 30.0})
	var l: Label = m.body.get_node("AutoTdp/AutoTdpLimit")
	eq(l.text, TS.QM_RAISE_TDP % [60, 15, 30], "raise TDP message")
	power.autotune_limit.emit(true, {"cant_reach": true, "target_fps": 60, "ceiling_w": 30.0, "tdp_max": 30.0})
	eq(l.text, TS.QM_CANT_HOLD % 60, "can't hold message at the ceiling")
	power.autotune_limit.emit(false, {})
	ok(not l.visible, "clears")
	m.free()


func test_quick_menu_session_and_exit() -> void:
	var m: Control = QuickMenu.new()
	var sess := FakeSession.new()
	var svc: Dictionary = Screens.new()._services()
	svc["session"] = sess
	m.setup(svc)
	var g: Dictionary = {"key": "epic:2", "title": "Fortnite", "store": "epic"}
	m.open(g)
	ok(m.body.get_node_or_null("SessionTime") == null, "no time before the game starts")
	sess.started.emit(g)
	m.show_section(0)
	ok(m.body.get_node_or_null("SessionTime") != null, "session time shown")
	ok(m.body.get_node_or_null("ExitGame") == null, "no exit button without a host listening")
	var exits: Array = []
	m.exit_game_requested.connect(func(x): exits.append(x["key"]))
	m.show_section(0)
	var b: Button = m.body.get_node("ExitGame/Button")
	ok(b in m.focusables(), "exit in focus chain")
	b.pressed.emit()
	eq(exits, [], "first press only arms")
	eq(b.text, TS.QM_EXIT_CONFIRM, "asks to press again")
	b.pressed.emit()
	eq(exits, ["epic:2"], "second press exits")
	ok(not m.visible, "menu closes")
	sess.ended.emit(g)
	m.open(g)
	ok(m.body.get_node_or_null("SessionTime") == null, "time gone after the game ends")
	m.free()
	sess.free()


func test_texts_helpers() -> void:
	eq(TS.session_time(30), "Just started", "under a minute")
	eq(TS.session_time(75 * 60), "1 h 15 min", "hours and minutes")
	eq(TS.session_time(120 * 60), "2 h", "whole hours")
	eq(TS.masked(""), TS.KEY_NONE, "unset key")
	eq(TS.masked("abcdef1234"), "••••1234", "masked key")
	eq(TS.store_line({"signed_in": true, "account": "x"}), "Signed in as x", "account")
	ok(TS.can_sign_in({"signed_in": false, "how": "code"}) and not TS.can_sign_in({"signed_in": false, "how": "heroic"}), "who can sign in here")
