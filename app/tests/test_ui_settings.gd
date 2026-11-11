extends "res://tests/test_case.gd"
## Settings screen, its pages, QR sign-in, first-run setup and the quick menu
## additions, all with fake services. Nothing touches the real system.

const TL := preload("res://scripts/ui/texts_library.gd")
const SettingsScreen := preload("res://scripts/ui/settings_screen.gd")
const SetupFlow := preload("res://scripts/ui/setup/setup_flow.gd")
const QR := preload("res://scripts/ui/settings/qr.gd")
const Credits := preload("res://scripts/ui/settings/credits.gd")
const Privacy := preload("res://scripts/system/privacy.gd")
const SignIn := preload("res://scripts/ui/settings/sign_in.gd")
const DevicePage := preload("res://scripts/ui/settings/device_page.gd")
const PerformancePage := preload("res://scripts/ui/settings/performance_page.gd")
const QuickMenu := preload("res://scripts/ui/quick_menu.gd")
const TS := preload("res://scripts/ui/texts_settings.gd")
const Screens := preload("res://tests/test_ui_screens.gd")
const Osk := preload("res://scripts/ui/osk.gd")
const FakeHttp := preload("res://scripts/discover/fake_http.gd")
const Sgdb := preload("res://scripts/library/art/sgdb.gd")
const ArtKeyStep := preload("res://scripts/ui/setup/art_key_step.gd")
const KeyDropTests := preload("res://tests/test_key_drop.gd")
const KEY_OK := "0123456789abcdef0123456789abcdef"
const Kit := preload("res://scripts/ui/ui_kit.gd")


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
		for s in ["welcome", "theme", "stores", "steamgriddb", "keys", "device_fixes", "done"]:
			out.append({"id": s, "optional": s in ["theme", "stores", "steamgriddb", "keys", "device_fixes"], "done": done.has(s), "skipped": skipped.has(s), "status": {}})
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


class FakeArtwork extends RefCounted:
	var filled: Array = []
	func auto_fill(games: Array) -> int:
		filled.append(games.size())
		return games.size() * 2


class FakeLibrary extends RefCounted:
	signal store_settings_changed
	var artwork := FakeArtwork.new()
	## Favourites and collections (scripts/library/collections.gd); null: no Collections card.
	var collections: RefCounted
	var games: Array = [{"key": "gog:1", "title": "Hades"}, {"key": "epic:2", "title": "Control"}]
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
		"price_lookups": {"label": "Look up deals and prices", "help": "Sends wishlist ids to CheapShark.", "setup": false},
	}
	var s := {"country": "", "steam_id": "", "steamgriddb_key": "", "ggdeals_key": "", "ggdeals_keyshops": false, "alerts": true, "affiliate_links": true, "price_lookups": true}
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
	# Game art step: no LAN page by default, and a fake SteamGridDB that accepts KEY_OK and refuses the rest.
	var http := FakeHttp.new()
	http.route(Sgdb.check_url(), {"code": 401, "text": '{"success":false,"errors":["Invalid API key"]}'})
	return {"setup": FakeSetup.new(), "library": FakeLibrary.new(), "discover": FakeDiscover.new(),
		"perf": FakePerf.new(), "achievements": FakeAchievements.new(), "device": Screens.FakeDevice.new(),
		"http": http, "lan": func() -> Array: return []}


## SteamGridDB (fake) accepts a key from now on.
static func _accept_keys(svc: Dictionary) -> void:
	svc["http"].route(Sgdb.check_url(), {"text": '{"success":true,"data":{"id":5247}}'})


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
	eq(s.cat_buttons.keys(), SettingsScreen.categories(), "categories in order, handheld first")
	for id in TS.CATEGORIES:
		ok(s.cat_buttons.has(id), "keeps " + id)
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
	k.shift_button.pressed.emit()
	k.type("b")
	k.type("c")
	eq(k.text, "aBc", "Shift types one capital")
	ok(k.paste_button.visible, "codes can be pasted")
	for i in 60:
		k.type("x")
	eq(k.text.length(), 63, "codes can be longer than search")
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
	var asked: Array = []
	s.setup_requested.connect(func(step): asked.append(step))
	p.rows["steamgriddb_key"].button.pressed.emit()
	eq(asked, ["art"], "the SteamGridDB row opens the guided Game art step")
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
	ok(_has_text(p, "MSI Claw 8 EX AI+"), "about panel (or its placeholder) names the device")
	s.free()
	var d: VBoxContainer = DevicePage.new()
	d.panel_dir = "res://tests/fixtures/settings/device/"
	d.setup("device", {"storage": "fake"}, null)
	d.on_shown()
	var panel: Control = d.panels.get("storage")
	ok(panel != null, "storage panel loaded from its build()")
	eq(panel.got, {"storage": "fake"}, "panel got the services")
	eq(panel.opened_count, 0, "only the open section is opened (About first)")
	ok(d.find_child("DeviceTabs", true, false) != null, "section tabs on top")
	eq(d.part, "about", "About first")
	eq(d.focusables().size(), 1, "About placeholder: just its tab")
	ok(not panel.visible, "other sections hidden")
	var first: Control = d.focus_part("storage")
	eq(d.part, "storage", "focus_part opens that section")
	ok(panel.visible, "storage shown")
	eq(panel.opened_count, 1, "opened() when its section shows")
	eq(d.focusables().size(), 2, "tab, then the panel's buttons")
	eq(first, d.focusables()[1], "lands on the panel's first control")
	d.select_part("about")
	eq(panel.closed_count, 1, "closed() when another section shows")
	d.select_part("storage")
	d.on_hidden()
	eq(panel.closed_count, 2, "closed() on hide")
	ok(d.find_child("Placeholder_about", true, false) != null, "missing panels still get placeholders")
	# LT / RT switch the sub-tabs (LB / RB stay on the top sections), and the
	# Controller section has no tab: Controller is its own category.
	eq(d.tabs.keys(), ["about", "storage", "updates"], "no Controller tab under Device")
	ok(d.sections.has("controller"), "the controller section still exists (linked from Controller)")
	ok(d.tab_row.get_node_or_null("TabsLT") != null and d.tab_row.get_node_or_null("TabsRT") != null, "LT / RT glyphs beside the tabs")
	d.select_part("about")
	eq(d.cycle_tabs(1), d.tabs["storage"], "RT: next tab")
	eq(d.part, "storage", "storage open")
	d.cycle_tabs(-1)
	d.cycle_tabs(-1)
	eq(d.part, "updates", "LT wraps around")
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


func test_credits_bundled_in_the_app() -> void:
	# review H8: the page must read the copy exported into the pck (res://), not the checkout's ../CREDITS.md
	eq(Credits.find(), "res://CREDITS.md", "CREDITS.md is part of the app (app/CREDITS.md, exported)")
	var md := Credits.load_text()
	ok(md.length() > 1000 and "## People" in md, "the real CREDITS.md")
	var full := Credits.full_text()
	ok("## Godot Engine" in full and "Permission is hereby granted" in full, "Godot's licence shown")
	ok("### Components in Godot Engine" in full and "FreeType" in full, "the engine's third-party components listed")
	for lf in Credits.LICENSE_FILES:
		ok(FileAccess.file_exists(lf[1]), "bundled licence text exists: " + lf[1])
	ok("SIL OPEN FONT LICENSE" in full and "Iceflower S" in full, "font and addon licence texts shown")
	var bb := Credits.to_bbcode(full)
	ok(bb.length() > 5000 and "[b][color=#ffffff]Godot Engine[/color][/b]" in bb, "renders with the Godot section")
	var preset := FileAccess.get_file_as_string("res://export_presets.cfg")
	for pat in ["CREDITS.md", "fonts/OFL-*.txt", "addons/kenyoni/qr_code/LICENSE.md"]:
		ok(pat in preset, "export include_filter carries " + pat)


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
	var sl := HSlider.new()
	eq(s.hints(sl)[0], ["LR", "Change"], "slider: left / right change it (the TDP slider)")
	sl.editable = false
	eq(s.hints(sl)[0], ["A", "Select"], "a locked slider doesn't")
	sl.free()
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
	eq(f.step, "art", "Game art next")
	ok(_has_text(f, ArtKeyStep.TITLE) and _has_text(f, "free"), "says why: free art for every game")
	eq(f.skip_button.text, "Skip, use Steam art only", "skip says what it means")
	var art: Control = f.art_step
	ok(art != null and art.buttons.all(func(b): return b in f.focusables()), "every button reachable with the controller")
	eq(art.mode, "direct", "no LAN here: the QR opens SteamGridDB's API page")
	art.submit("nope")
	eq(art.state, "direct", "not a key: nothing sent")
	eq(svc["http"].requests.size(), 0, "no request for a malformed key")
	art.submit("fedcba9876543210fedcba9876543210")
	eq(art.state, "wrong", "SteamGridDB refused it")
	eq(svc["setup"].key, "", "a wrong key isn't saved")
	ok(not svc["setup"].done.has("steamgriddb"), "step not done")
	_accept_keys(svc)
	art.submit(" " + KEY_OK + " ")
	eq(art.state, "ok", "works")
	eq([svc["setup"].key, svc["discover"].s["steamgriddb_key"]], [KEY_OK, KEY_OK], "saved in Setup and Discover")
	ok(svc["setup"].done.has("steamgriddb"), "step done")
	eq(svc["library"].artwork.filled, [2], "the missing-art fill ran for the library")
	ok("Finding art for 4 games" in art.status.text, "and says so")
	f.next_step()
	eq(f.step, "keys", "keys next")
	ok(not f.save_key("steamgriddb_key", "nope"), "bad key refused")
	ok(f.save_key("ggdeals_key", "AbCdEf123456"), "gg.deals key saved")
	eq(svc["discover"].s["ggdeals_key"], "AbCdEf123456", "into Discover")
	f.skip_step()
	ok(svc["setup"].skipped.has("keys"), "keys skipped")
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
	ok(svc["setup"].skipped.has("stores") and svc["setup"].skipped.has("steamgriddb") and svc["setup"].skipped.has("keys"), "optional steps marked skipped")
	ok(SetupFlow.instance == null, "closed")
	var f2: Control = SetupFlow.open(host, svc, "keys")
	eq(f2.step, "keys", "reopens at a given step")
	f2.finish()
	host.free()
	ok(SetupFlow.open_if_first_run(Control.new(), svc) == null, "no flow once setup is done")


func test_art_step_skip_path() -> void:
	var svc := _svc()
	var host := Control.new()
	var f: Control = SetupFlow.open(host, svc, "art")
	eq(f.step, "art", "opens at Game art (Settings > Discover > SteamGridDB key)")
	ok(not f.next_button.visible, "no Next until a key is in (Skip moves on)")
	var accents: Array = f.find_children("*", "Button", true, false).filter(func(b): return b.is_visible_in_tree() and b.theme_type_variation == "AccentButton")
	ok(accents.size() <= 1, "never two primary buttons at once")
	ok(f.art_step.type_button.theme_type_variation != "AccentButton", "Type the key is a secondary pill")
	ok(f.art_step.find_child("Actions", true, false) is HFlowContainer and f.art_step.buttons.all(func(b): return b.get_parent().name == "Actions"), "the fallbacks in one row (wrapping only when narrow)")
	eq(f.art_step.type_button.focus_neighbor_right, f.art_step.type_button.get_path_to(f.art_step.buttons[1]), "linked left / right")
	ok(not Kit.prompts_text(f.find_child("Prompts", true, false)).contains("Back"), "Back once: the B prompt is the button")
	eq((f.find_child("Shade", true, false) as ColorRect).color.a, 1.0, "the shell's bars don't show behind setup")
	f.skip_step()
	ok(svc["setup"].skipped.has("steamgriddb"), "skipped: Steam art only")
	eq(f.step, "keys", "moves on")
	eq(svc["http"].requests.size(), 0, "nothing sent")
	f.finish()
	host.free()


func test_art_step_next_after_a_key() -> void:
	var svc := _svc()
	var host := Control.new()
	var f: Control = SetupFlow.open(host, svc, "art")
	ok(not f.next_button.visible, "no key yet: no Next")
	eq(f.skip_button.focus_neighbor_right, f.skip_button.get_path_to(f.back_button), "Skip, then Back")
	_accept_keys(svc)
	f.art_step.submit(KEY_OK)
	ok(f.next_button.visible, "a key in: Next shows")
	f.go("art")
	ok(f.next_button.visible, "and stays for a saved key")
	f.finish()
	host.free()


func test_art_step_phone_page_end_to_end() -> void:
	var svc := _svc()
	_accept_keys(svc)
	var a: Control = ArtKeyStep.new()
	a.configure({"setup": svc["setup"], "discover": svc["discover"], "library": svc["library"], "http": svc["http"], "ask_text": func(_p, _s, _d): pass})
	a._ensure_drop()
	a.drop.bind_address = "127.0.0.1"
	a.start()
	eq(a.mode, "phone", "phone page open")
	ok(a.drop.is_running() and a.drop.url.begins_with("http://127.0.0.1:"), "listening on the chosen address only")
	ok(a.qr_rect.texture != null and a.url_label.text.ends_with(" · one-time page") and a.url_label.autowrap_mode == TextServer.AUTOWRAP_OFF, "QR of the one-time page, on one line")
	var t := KeyDropTests.new()
	var body := "key=" + KEY_OK
	var ans: String = t._ask(a.drop, "POST /k/%s HTTP/1.1\r\nContent-Length: %d\r\n\r\n%s" % [a.drop.token, body.length(), body])
	ok("Key sent" in ans, "phone told")
	eq(a.state, "ok", "checked and saved")
	eq(svc["setup"].key, KEY_OK, "saved")
	ok(not a.drop.is_running(), "page closed after the key")
	a.free()


func test_art_step_wrong_key_reopens_page_and_times_out() -> void:
	var svc := _svc()
	var a: Control = ArtKeyStep.new()
	a.configure({"setup": svc["setup"], "discover": svc["discover"], "http": svc["http"]})
	a._ensure_drop()
	a.drop.bind_address = "127.0.0.1"
	a.start()
	var first: String = a.drop.token
	a.drop.stop()      # what the page does once a key arrives, before handing it over
	a.submit(KEY_OK)   # SteamGridDB (fake) refuses every key here
	eq(a.state, "wrong", "refused")
	ok(a.drop.is_running() and a.drop.token != first, "a new one-time code to send it again")
	a.drop.poll(601.0)
	eq([a.mode, a.state], ["direct", "direct"], "after 10 minutes the page closes")
	ok("closed after 10 minutes" in a.status.text, "and says so")
	a.toggle_mode()
	ok(a.drop.is_running() and a.mode == "phone", "Send from my phone opens a new page")
	a.stop()
	ok(not a.drop.is_running(), "leaving the step closes it")
	a.free()


func test_art_step_respects_look_up_game_details() -> void:
	var svc := _svc()
	_accept_keys(svc)
	var d := ProjectSettings.globalize_path("user://tests/art_privacy_%d" % randi())
	DirAccess.make_dir_recursive_absolute(d)
	var prefs := d.path_join("settings.cfg")
	Privacy.set_metadata_allowed(false, prefs)
	var a: Control = ArtKeyStep.new()
	a.configure({"setup": svc["setup"], "discover": svc["discover"], "http": svc["http"], "prefs_path": prefs, "lan": func() -> Array: return []})
	a.start()
	a.submit(KEY_OK)
	eq(a.state, "privacy", "switch off: not checked")
	eq(svc["http"].requests.size(), 0, "nothing sent to SteamGridDB")
	eq(svc["setup"].key, "", "not saved")
	ok("Look up game details" in a.status.text, "says which switch")
	a.free()
	DirAccess.remove_absolute(prefs)
	DirAccess.remove_absolute(d)


func test_art_step_offline_and_remove() -> void:
	var svc := _svc()
	svc["http"].route(Sgdb.check_url(), {"error": "offline"})
	svc["setup"].key = KEY_OK
	var a: Control = ArtKeyStep.new()
	a.configure({"setup": svc["setup"], "discover": svc["discover"], "http": svc["http"], "lan": func() -> Array: return []})
	a.start()
	ok(a.remove_button != null, "Remove key offered when one is set")
	a.submit("fedcba9876543210fedcba9876543210")
	eq(a.state, "offline", "no network")
	ok("No internet" in a.status.text, "says so")
	eq(svc["setup"].key, KEY_OK, "old key kept")
	a.remove_key()
	eq([svc["setup"].key, svc["discover"].s["steamgriddb_key"]], ["", ""], "removed everywhere")
	a.free()


func test_texts_helpers() -> void:
	eq(TS.session_time(30), "Just started", "under a minute")
	eq(TS.session_time(75 * 60), "1 h 15 min", "hours and minutes")
	eq(TS.session_time(120 * 60), "2 h", "whole hours")
	eq(TS.masked(""), TS.KEY_NONE, "unset key")
	eq(TS.masked("abcdef1234"), "••••1234", "masked key")
	eq(TS.store_line({"signed_in": true, "account": "x"}), "Signed in as x", "account")
	ok(TS.can_sign_in({"signed_in": false, "how": "code"}) and not TS.can_sign_in({"signed_in": false, "how": "heroic"}), "who can sign in here")


class FakePhoto extends RefCounted:
	var enabled := true
	var maker_enabled := true
	func set_enabled(on: bool) -> void:
		enabled = on
	func set_maker_enabled(on: bool) -> void:
		maker_enabled = on


func test_about_page_network_and_privacy() -> void:
	var svc := _svc()
	var ph := FakePhoto.new()
	svc["photo"] = ph
	var s := _screen(svc)
	var p: VBoxContainer = s.pages["about"]
	var cfg := OS.get_user_data_dir().path_join("test_privacy_%d.cfg" % Time.get_ticks_usec())
	p.privacy_path = cfg
	ok(p.find_child("Card_privacy", true, false) != null, "Network and privacy card")
	for k in ["background_lookups", "price_lookups", "privacy_maker_photo"]:
		ok(p.rows.has(k), "switch: " + k)
	ok(_has_text(p, "CheapShark") and _has_text(p, "maker") and _has_text(p, "GameStream"), "every network call is listed")
	p.rows["background_lookups"].step(1)
	eq(Privacy.background_allowed(cfg), false, "Background lookups saved off")
	p.rows["price_lookups"].step(1)
	eq(svc["discover"].s["price_lookups"], false, "deals switch goes to Discover")
	p.rows["privacy_maker_photo"].step(1)
	eq(ph.maker_enabled, false, "maker photo switch goes to DevicePhoto")
	DirAccess.remove_absolute(cfg)
	s.free()


func test_device_page_photo_settings() -> void:
	var ph := FakePhoto.new()
	var d: VBoxContainer = DevicePage.new()
	d.panel_dir = "res://tests/fixtures/settings/device/"
	d.setup("device", {"photo": ph}, null)
	d.on_shown()
	ok(d.rows.has("real_photo"), "real photo switch")
	ok(d.rows.has("maker_photo"), "Show maker photos switch")
	d.rows["maker_photo"].step(1)
	eq(ph.maker_enabled, false, "turned off through DevicePhoto.set_maker_enabled")
	ok(d.find_child("Card_photo", true, false).visible, "shown under About")
	d.select_part("storage")
	ok(not d.find_child("Card_photo", true, false).visible, "hidden on other sections")
	d.free()


func test_stores_page_collections_card() -> void:
	load("res://scripts/system/settings_file.gd").reset_for_tests()
	var file := ProjectSettings.globalize_path("user://test_settings_collections.json")
	DirAccess.remove_absolute(file)
	var cols: RefCounted = load("res://scripts/library/collections.gd").new(file)
	cols.set_favourite("gog:1", true)
	cols.set_hidden("epic:2", true)
	cols.create("Backlog")
	cols.set_imported({"collections": [{"id": "steam-x", "name": "RPGs", "games": [], "source": "steam"}], "dynamic": 2})
	var svc := _svc()
	var plain := _screen(_svc())
	ok(not plain.pages["stores"].rows.has("steam_collections"), "no collections service: no card")
	plain.free()
	svc["library"].collections = cols
	var s := _screen(svc)
	var p: VBoxContainer = s.pages["stores"]
	ok(p.rows.has("steam_collections"), "Show Steam's collections")
	ok(p.rows["steam_collections"].hint_text().length() > 20, "with a plain line")
	eq(p.find_child("CollectionsFact", true, false).text, TL.collections_fact(1, 1, 1), "counts: favourites, hidden, ours")
	ok(_has_text(p, TL.STEAM_DYNAMIC % [2, "s"]), "dynamic collections stay in Steam, said plainly")
	p.rows["steam_collections"].step(-1)
	ok(not cols.steam_enabled(), "switched off")
	s.free()
	DirAccess.remove_absolute(file)
