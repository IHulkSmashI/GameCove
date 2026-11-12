extends "res://tests/test_case.gd"
## The device pages (About, Controller, Storage, Updates) against fake services.

const Fakes := preload("res://tests/fixtures/device_ui/fakes.gd")
const About := preload("res://scripts/ui/device/about_panel.gd")
const ControllerPage := preload("res://scripts/ui/device/controller_panel.gd")
const StoragePage := preload("res://scripts/ui/device/storage_panel.gd")
const UpdatesPage := preload("res://scripts/ui/device/updates_panel.gd")
const Picture := preload("res://scripts/ui/device/device_picture.gd")
const Texts := preload("res://scripts/ui/texts_device.gd")
const SettingsScreen := preload("res://scripts/ui/settings_screen.gd")
const FadeMask := preload("res://scripts/ui/fade_mask.gd")
const DKit := preload("res://scripts/ui/device/device_kit.gd")


func _texts(n: Node) -> String:
	var out := PackedStringArray()
	if n is Label:
		out.append(n.text)
	elif n is Button:
		out.append(n.text)
	for c in n.get_children():
		out.append(_texts(c))
	return "\n".join(out)


func _done(p: Control, s: Dictionary) -> void:
	p.free()
	Fakes.free_services(s)


func test_about_shows_every_group() -> void:
	var s := Fakes.services()
	var p: Control = About.build(s)
	var t := _texts(p)
	for key in ["device", "chip", "memory", "screen", "battery", "software", "support", "fixes"]:
		ok(p.find_child("Card_" + key, true, false) != null, "card " + key)
	ok(p.find_child("Card_storage", true, false) == null, "no Storage card: the Storage tab and the free-space tile have it")
	for want in ["MSI Claw 8 EX AI+", "Arc B390 (Xe3)", "93% health", "41", "1920 × 1200", "48–120 Hz", "Tested on hardware",
			"Bazzite 44.20261101", "MSI buttons", "Shared (GTT)"]:
		ok(t.contains(want), "shows " + want)
	for gone in ["Maker", "Family", "PCI id", "Serial number", "Name"]:
		ok(not t.contains(gone + "\n") and not (gone in t.split("\n")), "no %s row" % gone)
	eq(s["device"].slow_requested, 1, "asks for slow details once")
	ok(p.picture.texture != null, "picture drawn")
	# Read-only cards don't take focus; the ones with a job do, and say it.
	var chain: Array = p.focus_chain()
	eq(chain.map(func(c): return String(c.name)).filter(func(n): return n.begins_with("Card_")).size(), 5, "five cards with an action")
	var pills: Array = chain.filter(func(c): return c.get("_pill") != null).map(func(c): return c._pill)
	ok(not pills.is_empty() and pills.all(func(pl): return pl.modulate.a == 0.0), "no (A) pill on an unfocused card")
	var keys: Array = []
	for card_name in ["Card_device", "Card_chip", "Card_memory"]:
		var lines: GridContainer = p.find_child(card_name, true, false).find_child("Lines", true, false)
		keys.append(lines.get_child(0).custom_minimum_size.x)
	eq(keys, [float(p.KEY_W), float(p.KEY_W), float(p.KEY_W)], "one fixed key column, so values line up")
	ok(p.find_child("Card_chip", true, false).focus_mode == Control.FOCUS_NONE, "chip card is read-only")
	var dev: Control = p.find_child("Card_device", true, false)
	eq(dev.action_text, Texts.ACT_COPY, "Device card copies its info")
	eq(p.hints_for(dev), [["A", Texts.ACT_COPY], ["B", "Back"]], "hint bar names the action")
	ok(p.info_text().contains("Kernel:"), "copied text has the details")
	var asked := []
	p.part_requested.connect(func(id): asked.append(id))
	p.find_child("Card_fixes", true, false).action.call()
	eq(asked, ["fixes"], "Fixes card opens the Fixes tab")
	eq(p.hints(), [], "no hints until focus")
	var info: Dictionary = Fakes.claw_info()
	info["software"]["steam_version"] = "1762999999"
	s["device"].info_updated.emit(info)
	ok(_texts(p).contains("1762999999"), "live update on info_updated")
	_done(p, s)


func test_about_cards_in_two_columns_when_wide() -> void:
	var s := Fakes.services()
	var p: Control = About.build(s)
	eq(p._stacks.size(), 1, "narrow (not laid out): one column")
	p.size = Vector2(1700, 900)
	p._grid.set_meta("dealt", -1)
	p._deal()
	eq(p._stacks.size(), 2, "wide: two columns")
	var a: Array = p._stacks[0].get_children()
	var b: Array = p._stacks[1].get_children()
	ok(not a.is_empty() and not b.is_empty(), "cards in both")
	ok(absi(a.size() - b.size()) <= 2, "balanced")
	var fa: Array = a.filter(func(c): return c.focus_mode != Control.FOCUS_NONE)
	var fb: Array = b.filter(func(c): return c.focus_mode != Control.FOCUS_NONE)
	eq(fa[0].get_node(fa[0].focus_neighbor_right), fb[0], "right crosses to the next column")
	eq(p.focus_chain().size(), fa.size() + fb.size(), "every card with an action in the chain")
	_done(p, s)


func test_about_generic_device() -> void:
	var s := Fakes.services()
	s["device"].device_id = "unknown"
	s["device"].data = {"device": {"id": "unknown", "name": "Unknown handheld", "picture": ""},
		"support": {"level": "generic", "verified": false, "unverified": ["all"], "features": {}, "fixes": [], "quirks": []}}
	var p: Control = About.build(s)
	var t := _texts(p)
	ok(t.contains("Basic support"), "generic level")
	ok(t.contains(Texts.NO_FIXES), "no fixes card says so")
	ok(t.contains("everything"), "unverified explained")
	ok(p.find_child("Card_battery", true, false) == null, "no battery card without a battery")
	_done(p, s)


func test_picture_highlight() -> void:
	var svg := "<svg><g id=\"btn-South\"><circle cx=\"1\" fill=\"#1F2630\" stroke=\"#9AA4B0\" stroke-width=\"1.5\"/></g><rect id=\"btn-LeftPaddle1\" fill=\"none\" stroke=\"#9AA4B0\"/></svg>"
	var out := Picture.highlight(svg, "btn-South", "#ABCDEF", "#FFFFFF")
	ok(out.contains("<circle cx=\"1\" fill=\"#ABCDEF\" stroke=\"#FFFFFF\""), "group: first shape recoloured")
	out = Picture.highlight(out, "btn-LeftPaddle1", "#123456", "#FFFFFF")
	ok(out.contains("id=\"btn-LeftPaddle1\" fill=\"#123456\""), "paddle filled")
	eq(Picture.highlight(svg, "btn-Nope", "#000000", "#000000"), svg, "unknown id leaves it alone")
	var pic: TextureRect = Picture.new()
	pic.setup(load("res://scripts/device/device.gd").picture_for("msi-claw-8-ex"))
	ok(pic.has_part("LeftPaddle1") and pic.has_part("Guide"), "Claw picture has paddles and Guide")
	pic.press("South", true)
	eq(pic.lit, ["South"])
	pic.press("South", false)
	eq(pic.lit, [])
	pic.free()


func test_controller_rows_drive_the_service() -> void:
	var s := Fakes.services()
	var p: Control = ControllerPage.build(s)
	var ctl = s["controller"]
	ok(ctl.calls.has("refresh"), "refresh on open")
	ok(not p.rows.has("paddle_LeftPaddle1"), "back buttons live on the Button shortcuts card now (test_button_shortcuts.gd)")
	ok(not p.rows.has("gyro"), "no legacy gyro modes (current InputPlumber ignores them)")
	ok(_texts(p).contains("Gyro aiming lives in Steam"), "says aiming is Steam Input's")
	p.rows["rumble"].step(1)
	ok(ctl.calls.has("rumble false"), "rumble off")
	p.rumble_button.pressed.emit()
	ok(ctl.calls.has("test_rumble"), "test buzz")
	p.rows["game_profile"].step(1)
	ok(ctl.calls.has("game_profile steam:976730 true"), "per-game layout")
	ok(p.find_child("Card_lights", true, false) != null, "lights card, read-only")
	ok(_texts(p).contains(Texts.LED_LINE), "says lights can't be changed")
	eq(p.hints_for(p.rows["rumble"].button), [["A", "Change"], ["B", "Back"]], "a switch row: A changes it (docs/CONTROLLER-UX.md CUX-3)")
	_done(p, s)


func test_controller_button_test_and_lighting() -> void:
	var s := Fakes.services()
	var p: Control = ControllerPage.build(s)
	var ctl = s["controller"]
	p.light("South", true)
	eq(p.picture.lit, ["South"], "pressed button lit")
	p.light("South", false)
	ctl.button_event.emit("Guide", true)
	p.start_test()
	ok(p.testing, "test mode")
	ok(ctl.calls.has("button_test true"), "Controller lets paddles through")
	eq(p.hints(), [["B", Texts.TEST_HOLD]], "hint bar says how to leave")
	p.stop_test()
	ok(not p.testing and ctl.calls.has("button_test false"), "test ends")
	_done(p, s)


func test_controller_without_inputplumber() -> void:
	var s := Fakes.services()
	s["controller"].st = {"available": false, "supported": {}}
	var p: Control = ControllerPage.build(s)
	ok(_texts(p).contains(Texts.CHECKING), "checking until the first answer")
	s["controller"].changed.emit({"available": false, "supported": {}})
	ok(_texts(p).contains(Texts.NO_INPUTPLUMBER), "explains InputPlumber is missing")
	ok(p.rows.is_empty(), "no settings rows")
	ok(p.test_button != null, "button test still offered")
	_done(p, s)


func test_storage_bars_watch_and_measure() -> void:
	var s := Fakes.services()
	var p: Control = StoragePage.build(s)
	var st = s["storage"]
	p.opened()
	ok(st.calls.has("watch true"), "watch while open")
	var t := _texts(p)
	ok(t.contains("Games SD") and t.contains("SD card"), "SD card listed")
	ok(t.contains("41 GB free of 512 GB"), "free of size")
	ok(t.contains("23 games") and t.contains("Heroic"), "game folders")
	var sd_bar = p.find_child("Drive_1", true, false).find_child("Usage", true, false)
	ok(sd_bar != null and sd_bar.bar_color() == load("res://theme/gamecove_theme.gd").color("warn"), "a nearly full card is amber")
	ok(p.measure_buttons.size() == 1, "measure offered where the size is unknown")
	p.measure_buttons.values()[0].pressed.emit()
	ok(st.calls.has("measure /home/deck/Games/Heroic"), "measure through Storage")
	p.closed()
	ok(st.calls.has("watch false"), "stop watching when closed")
	_done(p, s)


func test_storage_watches_only_while_it_shows() -> void:
	# inside Settings > Device every panel is in the tree; a hidden Storage tab must not watch (behind a game)
	var root: Window = (Engine.get_main_loop() as SceneTree).root
	var s := Fakes.services()
	var host := Control.new()
	host.visible = false
	root.add_child(host)
	var p: Control = StoragePage.build(s)
	host.add_child(p)
	p._open_if_shown()
	ok(not s["storage"].calls.has("watch true"), "a hidden panel doesn't watch")
	host.visible = true
	p._open_if_shown()
	ok(s["storage"].calls.has("watch true"), "a shown one does")
	p.closed()
	host.free()


func test_storage_loading_and_empty() -> void:
	var s := Fakes.services()
	s["storage"].st = {"ready": false, "error": "", "drives": [], "libraries": []}
	var p: Control = StoragePage.build(s)
	ok(s["storage"].calls.has("refresh"), "refresh when not ready")
	ok(_texts(p).contains(Texts.STORAGE_LOADING), "loading state")
	s["storage"].changed.emit({"ready": true, "error": "", "drives": [], "libraries": []})
	ok(_texts(p).contains(Texts.STORAGE_EMPTY), "empty state")
	_done(p, s)


func test_updates_rows() -> void:
	var s := Fakes.services()
	var p: Control = UpdatesPage.build(s)
	var up = s["updates"]
	var t := _texts(p)
	ok(t.contains("New: 44.20261107"), "new OS version")
	ok(t.contains("2 apps to update"), "pending apps")
	ok(p.find_child("Progress_flatpak", true, false) != null, "progress bar while installing")
	up.progress.emit("flatpak", 40.0, "Installing Firefox")
	ok(_texts(p).contains("40% · Installing Firefox"), "progress line updates in place")
	p.buttons["apply:os"].pressed.emit()
	ok(up.calls.has("apply os"), "apply")
	p.buttons["check_all"].pressed.emit()
	ok(up.calls.has("check_updates"), "check all")
	ok(p.buttons["check_all"].disabled, "no second check while one installs")
	ok(p.default_focus() is Button, "focus starts on a button")
	var st: Dictionary = Fakes.updates_state()
	st["phase"]["os"] = "staged"
	st["game_running"] = true
	up.changed.emit(st)
	ok(p.buttons.has("reboot") and p.buttons["reboot"].disabled, "restart offered but not during a game")
	ok(_texts(p).contains(Texts.GAME_RUNNING), "says why")
	_done(p, s)


func test_updates_unsupported_and_password() -> void:
	var s := Fakes.services()
	var st: Dictionary = Fakes.updates_state()
	st["phase"] = {"os": "unsupported", "firmware": "available", "flatpak": "error"}
	st["firmware"] = {"available": true, "devices": [{"id": "x", "name": "Controller", "current": "1.0", "version": "1.2", "trusted": false, "needs_reboot": false}], "error": ""}
	st["flatpak"]["error"] = "error: Not authorized"
	s["updates"].st = st
	var p: Control = UpdatesPage.build(s)
	var t := _texts(p)
	ok(t.contains(Texts.UNSUPPORTED_WHY["os"]), "unsupported explained")
	ok(t.contains(Texts.FIRMWARE_UNTRUSTED), "untrusted firmware needs Desktop Mode")
	ok(t.contains(Texts.NEEDS_PASSWORD), "auth error explained")
	s["updates"].finished.emit("firmware", false, "game_running")
	ok(_texts(p).contains(Texts.GAME_RUNNING), "finished reason shown")
	_done(p, s)


func test_every_page_builds_in_every_theme() -> void:
	var ThemeLib = load("res://theme/gamecove_theme.gd")
	for id in load("res://theme/themes.gd").ORDER:
		ThemeLib.use(id)
		var s := Fakes.services()
		for page in [About, ControllerPage, StoragePage, UpdatesPage]:
			var p: Control = page.build(s)
			ok(p.default_focus() != null, "%s has a focus target in %s" % [p.name, id])
			p.free()
		Fakes.free_services(s)
	ThemeLib.use("cove")


## Everything under `n` that would draw as a plain white block: a clip-children
## mask inside another one (Godot draws the inner mask's own white texture and
## none of its children), or a stood-down mask whose white texture still shows.
func _white_blocks(n: Node) -> Array:
	var out: Array = []
	if n is CanvasItem and not (n as CanvasItem).visible:
		return out   # hidden, with everything under it
	if n is TextureRect:
		var t := n as TextureRect
		if t.clip_children != CanvasItem.CLIP_CHILDREN_DISABLED and _under_clip(t):
			out.append("%s: mask inside a mask" % t.name)
		elif t.clip_children == CanvasItem.CLIP_CHILDREN_DISABLED and t.texture is GradientTexture2D \
				and t.self_modulate.a > 0.0 and t.modulate.a > 0.0 and t.get_child_count() > 0:
			out.append("%s: white mask texture drawn over its children" % t.name)
	for k in n.get_children():
		out.append_array(_white_blocks(k))
	return out


func _under_clip(n: Node) -> bool:
	var p := n.get_parent()
	while p != null:
		if p is CanvasItem and (p as CanvasItem).clip_children != CanvasItem.CLIP_CHILDREN_DISABLED:
			return true
		p = p.get_parent()
	return false


## The About tab inside Settings sits in Settings' own fade mask: its card
## column's mask must stand down there (it drew as a big white rectangle in
## place of the first cards), and the first card on the right is a real card.
func test_about_inside_settings_has_no_white_block() -> void:
	var root: Window = (Engine.get_main_loop() as SceneTree).root
	var s := Fakes.services()
	var st: Control = SettingsScreen.new()
	st.set_services(s)
	st.setup({"theme": "cove", "match_art": true, "reduce_motion": false, "menu_side": "right", "ui_sounds": "low"}, [])
	st.size = Vector2(1536, 960)
	root.add_child(st)
	st.open_category("device", "about")
	# Unit tests run outside a live tree, so enter_tree never comes: do what
	# it does (outer masks first). The e2e suite checks the live app.
	for m in st.find_children("*", "TextureRect", true, false):
		if m.get_script() == FadeMask and m.has_method("fit_nesting"):
			m.fit_nesting()
	var panel: Control = null
	for c in st.find_children("*", "Control", true, false):
		if c.get_script() == About:
			panel = c
			break
	ok(panel != null, "About panel built in Settings")
	if panel != null:
		var masks: Array = panel.find_children("*", "TextureRect", true, false).filter(func(m): return m.get_script() == FadeMask)
		ok(not masks.is_empty(), "the card column has its fade mask")
		ok(masks.all(func(m): return m.get("nested") == true), "inside Settings' mask it stands down")
		eq(_white_blocks(st), [], "nothing in Settings draws as a white block")
		var first: Control = panel._stacks[0].get_child(0)
		eq(String(first.name), "Card_device", "first card on the right is the Device card")
		ok(first is DKit.FocusCard, "a real card")
		var title: Label = first.find_child("Title", true, false)
		ok(title != null and title.text.to_upper().contains("DEVICE"), "with its title")
	# The same mask on its own (no outer mask) still clips: the fade works.
	var p: Control = About.build(s)
	root.add_child(p)
	for m in p.find_children("*", "TextureRect", true, false):
		if m.get_script() == FadeMask and m.has_method("fit_nesting"):
			m.fit_nesting()
	var own: Array = p.find_children("*", "TextureRect", true, false).filter(func(m): return m.get_script() == FadeMask)
	ok(own.size() == 1 and own[0].get("nested") != true and own[0].clip_children == CanvasItem.CLIP_CHILDREN_ONLY, "alone, the mask clips")
	eq(_white_blocks(p), [], "and draws no white block")
	root.remove_child(p)
	p.free()
	root.remove_child(st)
	st.free()
	Fakes.free_services(s)


## A mask wrapped around content that already holds a mask: the inner one
## stands down at once.
func test_fade_mask_wrapping_a_mask_later() -> void:
	var root: Window = (Engine.get_main_loop() as SceneTree).root
	var host := Control.new()
	root.add_child(host)
	var outer_scroll := ScrollContainer.new()
	host.add_child(outer_scroll)
	var box := VBoxContainer.new()
	outer_scroll.add_child(box)
	var inner_scroll := ScrollContainer.new()
	box.add_child(inner_scroll)
	var inner: TextureRect = FadeMask.wrap(inner_scroll, 20.0)
	ok(inner.get("nested") != true and inner.clip_children == CanvasItem.CLIP_CHILDREN_ONLY, "on its own it clips")
	var outer: TextureRect = FadeMask.wrap(outer_scroll, 20.0)
	ok(outer.get("nested") != true and outer.clip_children == CanvasItem.CLIP_CHILDREN_ONLY, "the outer one clips")
	ok(inner.get("nested") == true and inner.clip_children == CanvasItem.CLIP_CHILDREN_DISABLED and inner.self_modulate.a == 0.0,
		"the inner one stands down, texture hidden")
	eq(_white_blocks(host), [], "no white block")
	root.remove_child(host)
	host.free()
