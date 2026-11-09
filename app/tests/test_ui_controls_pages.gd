extends "res://tests/test_case.gd"
## Pages made from Controls: a generated settings page (cards, More, the
## "Not on this handheld" card, rebuild after detection), Performance with
## and without Controls, Profiles (layers, games, save / copy / reset with a
## second press, export and import), the game page's Game settings card,
## the controller panel's gyro on Controls, Settings' open_category, the
## installer's XeSS driver card and brand logos with text fallback.

const UIC := preload("res://tests/test_ui_controls.gd")
const ProfilesScript := preload("res://scripts/controls/profiles.gd")
const GroupPage := preload("res://scripts/ui/controls/group_page.gd")
const PerfPage := preload("res://scripts/ui/controls/perf_page.gd")
const ProfilesPage := preload("res://scripts/ui/controls/profiles_page.gd")
const GameCard := preload("res://scripts/ui/controls/game_settings_card.gd")
const SettingsScreen := preload("res://scripts/ui/settings_screen.gd")
const ControllerPanel := preload("res://scripts/ui/device/controller_panel.gd")
const BrandMark := preload("res://scripts/ui/brand_mark.gd")
const TC := preload("res://scripts/ui/texts_controls.gd")
const TI := preload("res://scripts/ui/installer/texts_installer.gd")
const Screens := preload("res://tests/test_ui_screens.gd")
const FILE := "user://test_ui_controls_pages.json"
const EXPORT_DIR := "user://test_ui_controls_export"


func _env() -> Array:
	var c: Node = UIC.fake()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(FILE))
	var p: Node = ProfilesScript.new()
	p.setup(c, "msi-claw-8-ex", FILE)
	p._first_detect_done = true
	return [c, p]


func _done(nodes: Array) -> void:
	for n in nodes:
		if n is Node and is_instance_valid(n):
			n.free()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(FILE))


func _keys(page: Node) -> Array:
	var out := []
	for f in page.focusables():
		var n: Node = f
		while n != null and n != page:
			if n.has_method("explanation"):
				out.append(n.key)
				break
			n = n.get_parent()
	return out


func test_group_page_cards_more_and_unavailable() -> void:
	var e := _env()
	var c: Node = e[0]
	var page: VBoxContainer = GroupPage.new()
	page.setup("power", {"controls": c, "profiles": e[1]}, null)
	eq(page.get_child_count(), 0, "built on first show")
	page.on_shown()
	ok(page.find_child("Card_Power limit", true, false) != null, "Power limit card")
	ok(page.find_child("Card_Fan", true, false) != null, "fan card for the curve")
	var keys := _keys(page)
	ok("power.tdp" in keys and "power.profile" in keys and "power.fan_curve" in keys, "usable settings in the chain")
	ok(not "power.smt" in keys, "SMT can't be used here: behind More")
	ok(page.find_child("Card_CPU", true, false) != null, "CPU card (boost works)")
	c.set_available("power.smt", true)
	c.detect_all()
	page.on_shown()
	ok(page.cards.signature().contains("power.smt"), "rebuilt when detection changed what works")
	page.free()
	var none: VBoxContainer = GroupPage.new()
	none.lazy = false
	none.setup("audio", {"controls": c}, null)
	ok(none.find_child("Nothing", true, false) != null, "a group with no controls says so")
	none.free()
	var bare: VBoxContainer = GroupPage.new()
	bare.lazy = false
	bare.setup("power", {}, null)
	ok(bare.find_child("NoControls", true, false) != null, "no Controls: says settings aren't ready")
	bare.free()
	_done(e)


func test_unavailable_topics_gather_at_the_end() -> void:
	var c: Node = load("res://tests/fixtures/ui_controls/fake_controls.gd").new()
	c.load_snapshot("res://tests/fixtures/ui_controls/msi-claw-8-ex.json")
	var page: VBoxContainer = GroupPage.new()
	page.setup("controller", {"controls": c}, null)
	page.on_shown()
	var last: Node = page.get_child(page.get_child_count() - 1)
	eq(String(last.name), "Card_unavailable", "Not on this handheld comes last")
	var total := 0
	for l in page.cards.lists:
		var p: Array = l.placement()
		total += p[0].size() + p[1].size()
	eq(total, c.list("controller").size(), "every controller setting has a place")
	page.free()
	c.free()


func test_every_snapshot_control_renders() -> void:
	for dev in ["msi-claw-8-ex", "lenovo-legion-go-s-z2go"]:
		var c: Node = load("res://tests/fixtures/ui_controls/fake_controls.gd").new()
		c.load_snapshot("res://tests/fixtures/ui_controls/%s.json" % dev)
		for cat in ["power", "display", "audio", "controller", "system"]:
			var page: VBoxContainer = GroupPage.new()
			page.setup(cat, {"controls": c}, null)
			page.on_shown()
			for l in page.cards.lists:
				l.toggle_more()
				for id in l.views:
					ok(l.views[id].row != null, "%s %s renders" % [dev, id])
			page.free()
		c.free()


func test_perf_page_with_and_without_controls() -> void:
	var e := _env()
	var c: Node = e[0]
	c.add({"id": "perf.overlay", "title": "Performance overlay", "kind": "choice", "value": "fps",
		"options": [{"value": "off", "label": "Off"}, {"value": "fps", "label": "Frame rate"}]})
	var p: VBoxContainer = PerfPage.new()
	p.setup("performance", {"controls": c, "achievements": load("res://tests/test_ui_settings.gd").FakeAchievements.new()}, null)
	p.on_shown()
	ok("perf.overlay" in _keys(p), "overlay from Controls")
	ok(p.rows.has("fetch_rarity"), "achievements card kept")
	p.free()
	var old: VBoxContainer = PerfPage.new()
	old.setup("performance", {"perf": load("res://tests/test_ui_settings.gd").FakePerf.new()}, null)
	ok(old.rows.has("overlay"), "without Controls: the PerfMonitor overlay row")
	old.free()
	_done(e)


func test_profiles_page_actions_export_import() -> void:
	var e := _env()
	var c: Node = e[0]
	var prof: Node = e[1]
	prof.set_layer("steam:1", "", {"power.tdp": 12})
	prof._remember_title("steam:1", "Hades")
	var page: VBoxContainer = ProfilesPage.new()
	page.setup("profiles", {"controls": c, "profiles": prof, "profiles_dir": ProjectSettings.globalize_path(EXPORT_DIR)}, null)
	ok(page.rows.has("layer_global") and page.rows.has("layer_battery") and page.rows.has("layer_ac"), "three base layers")
	ok(page.rows.has("game_steam_1"), "a row per game")
	ok(page.rows["game_steam_1"].hint_text().contains("TDP 12 W"), "what's saved, in words")
	page.act("", "battery", "On battery", "save")
	ok(prof.layer("", "battery").has("power.tdp"), "save current into battery")
	page.act("steam:1", "*", "Hades", "reset")
	ok(prof.has_profile("steam:1"), "first reset only asks")
	page.act("steam:1", "*", "Hades", "reset")
	ok(not prof.has_profile("steam:1"), "second reset forgets the game")
	var edits := []
	page.edit_game_requested.connect(func(g): edits.append(g["key"]))
	page.act("epic:2", "*", "Fortnite", "edit")
	eq(edits, ["epic:2"], "edit asks for the quick menu")
	page.export_all()
	ok(FileAccess.file_exists(page._path("")), "exported")
	prof.reset_all()
	page.import_all()
	ok(prof.layer("", "battery").has("power.tdp"), "imported back")
	DirAccess.remove_absolute(page._path(""))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(EXPORT_DIR))
	page.free()
	_done(e)


func test_game_settings_card() -> void:
	var e := _env()
	var card: VBoxContainer = GameCard.new()
	var g := {"key": "steam:1", "title": "Hades", "store": "steam", "id": "1"}
	card.setup(g, e[0], e[1])
	ok(not card.custom(), "everyday settings")
	eq(card.toggle.value(), false, "the switch row says Off")
	eq(card.toggle.title_label.text, TC.GAME_CARD_TOGGLE, "inline switch, no extra button")
	ok(card.get_node_or_null("Everyday") != null, "a read-only summary of the everyday profile")
	ok(card.edit_button == null and card.reset_button == null, "nothing to edit while off")
	eq(card.focusables(), [card.toggle.button, card.steam_button], "switch, and Steam's controller settings")
	var opened := []
	card.open_uri = func(u): opened.append(u); return true
	card.steam_button.pressed.emit()
	eq(opened, ["steam://controllerconfig/1"], "opens Steam's controller settings for the game")
	eq(card.steam_button.text, TC.GYRO_STEAM_OPENING, "says it's opening")
	card.toggle.step(1)
	ok(e[1].has_profile("steam:1"), "own settings made")
	eq(card.focusables().size(), 3, "switch, Edit, Steam controller settings")
	ok(card.get_node_or_null("Everyday") == null, "summary gone while on")
	var asked := []
	card.edit_requested.connect(func(x): asked.append(x["key"]))
	card.edit_button.pressed.emit()
	eq(asked, ["steam:1"], "Edit asks for the quick menu")
	card.toggle.step(1)
	ok(e[1].has_profile("steam:1"), "first Off only asks")
	eq(card.toggle.value(), true, "and the switch stays on")
	eq(card.toggle.hint_text(), TC.GAME_CARD_OFF_CONFIRM, "saying what a second press does")
	card.toggle.step(1)
	ok(not e[1].has_profile("steam:1"), "second press forgets them")
	eq(e[0].detect_calls, 0, "the card never moves Controls' game")
	card.free()
	var epic: VBoxContainer = GameCard.new()
	epic.setup({"key": "epic:x", "title": "Fortnite", "store": "epic", "id": "x"}, e[0], e[1])
	ok(epic.steam_button == null, "no Steam button for other stores")
	epic.free()
	_done(e)


func test_controller_panel_gyro_uses_controls() -> void:
	var e := _env()
	var c: Node = e[0]
	c.add({"id": "controller.gyro", "title": "Gyro", "kind": "toggle", "value": true})
	c.add({"id": "controller.emulation", "title": "Controller type", "kind": "choice", "value": "deck",
		"options": [{"value": "default", "label": "Handheld default"}, {"value": "deck", "label": "Steam Deck"}]})
	var p := ControllerPanel.build({"controls": c, "device": Screens.FakeDevice.new()})
	var gy: Node = p.find_child("controller_gyro", true, false)
	ok(gy != null, "gyro on/off from controller.gyro")
	ok(p.find_child("controller_emulation", true, false) != null, "controller type from controller.emulation")
	gy.row.step(1)
	eq(c.value("controller.gyro"), false, "written through Controls")
	p.free()
	_done(e)


func test_settings_open_category() -> void:
	var e := _env()
	var s: Control = SettingsScreen.new()
	s.set_services({"controls": e[0], "profiles": e[1], "device": Screens.FakeDevice.new()})
	s.setup({"theme": "cove", "match_art": true, "reduce_motion": false, "menu_side": "right", "ui_sounds": "low"}, [])
	s.open_category("power")
	eq(s.category, "power", "Power shown")
	ok(s.pages["power"].focusables().size() > 0, "and built")
	s.open_category("nope")
	eq(s.category, "power", "unknown ids ignored")
	s.free()
	_done(e)


func test_brand_mark_falls_back_to_text() -> void:
	ok(BrandMark.rect("Some Unknown Maker", 22) == null, "a maker without a logo: callers keep the name")
	var aya := BrandMark.rect("AYANEO", 22)
	ok(aya != null and aya.texture != null, "every listed maker has a logo now")
	if aya != null:
		aya.free()
	ok(BrandMark.rect("", 22) == null, "no name, no logo")
	ok(BrandMark.rect("Some Unknown Store", 22) == null, "unknown brand: text")
	var msi := BrandMark.rect("Micro-Star International Co., Ltd.", 22)
	ok(msi != null and msi.texture != null, "DMI vendor string finds the maker's logo")
	if msi != null:
		ok(msi.custom_minimum_size.y == 22 and msi.custom_minimum_size.x >= 22, "sized to the row, width from the logo")
		msi.free()
	var heroic := BrandMark.rect("heroic", 22)
	ok(heroic != null and heroic.texture != null, "a bundled logo the owner allows")
	if heroic != null:
		heroic.free()


func test_installer_xess_card() -> void:
	var T = load("res://tests/test_installer_ui.gd").new()
	var s: Control = T._screen(load("res://tests/fixtures/installer/fakes.gd").target("bazzite"))
	s.plan.xess_offered = true
	s.plan.step = "device"
	s.show_step()
	var card: Button = s.body.find_child("Card_xess_driver", true, false)
	ok(card != null, "offered on Intel Arc with XMX")
	card.pressed.emit()
	eq(s.plan.choices["xess_driver"], true, "A turns it on")
	card = s.body.find_child("Card_xess_driver", true, false)
	ok(card.selected, "shown as chosen")
	s.plan.xess_offered = false
	s.show_step()
	ok(s.body.find_child("Card_xess_driver", true, false) == null, "not offered elsewhere")
	eq(TI.task_title({"id": "xess_install"}), "Install the XeSS XMX driver", "task title")
	eq(TI.task_title({"id": "xess_remove"}), "Remove the XeSS XMX driver", "undo title")
	T._free(s)


func test_installer_store_cards_show_logos() -> void:
	var T = load("res://tests/test_installer_ui.gd").new()
	var s: Control = T._screen(load("res://tests/fixtures/installer/fakes.gd").target("bazzite"))
	s.plan.step = "stores"
	s.show_step()
	var epic: Node = s.body.find_child("Card_store_epic", true, false)
	ok(epic != null and epic.find_child("BrandLogo", true, false) != null, "Epic card carries the Epic logo")
	var amazon: Node = s.body.find_child("Card_store_amazon", true, false)
	ok(amazon != null and amazon.find_child("BrandLogo", true, false) != null, "Amazon card carries the Amazon Games logo")
	T._free(s)


func test_game_header_store_logo_keeps_the_name() -> void:
	var H: GDScript = load("res://scripts/ui/game_header.gd")
	var h: Node = H.new()
	h.show_game({"key": "steam:1", "title": "Hades", "store": "steam"})
	ok(h.meta.find_child("StoreLogo", true, false) != null, "Steam logo leads the meta line")
	ok(h.meta_text().contains("Steam"), "the store's name stays in the text")
	h.show_game({"key": "amazon:1", "title": "Hades", "store": "amazon"})
	ok(h.meta.find_child("StoreLogo", true, false) != null, "Amazon Games logo leads the meta line")
	ok(h.meta_text().contains("Amazon"), "name shown")
	h.free()


func test_about_panel_maker_logo() -> void:
	var Fakes: GDScript = load("res://tests/fixtures/device_ui/fakes.gd")
	var s: Dictionary = Fakes.services()
	var p: Control = load("res://scripts/ui/device/about_panel.gd").build(s)
	ok(p.find_child("MakerLogo", true, false) != null, "MSI logo over the device name")
	ok(p.find_child("DeviceName", true, false) != null, "name kept")
	p.free()
	Fakes.free_services(s)
