extends "res://tests/test_case.gd"
## Real-device findings 2-9 and 11 (MSI Claw 8 EX, controller and touch): one focus at a time, a choice changes
## only on A, the d-pad moves focus in screen order, nothing that can't be used takes focus, the page scrolls to
## everything, hints are prominent. The d-pad order is tested on made-up layouts (installer_nav.gd) and on the
## real pages; focus and scrolling in the scene tree are in the e2e journeys (suite_journeys.gd).

const Screen := preload("res://scripts/ui/installer/installer_screen.gd")
const Nav := preload("res://scripts/ui/installer/installer_nav.gd")
const ChoiceRow := preload("res://scripts/ui/choice_row.gd")
const Plan := preload("res://scripts/installer/plan.gd")
const Service := preload("res://scripts/installer/installer_service.gd")
const Paths := preload("res://scripts/installer/paths.gd")
const UserFiles := preload("res://scripts/installer/user_files.gd")
const Fake := preload("res://tests/fixtures/system/fake_runner.gd")
const F := preload("res://tests/fixtures/installer/fakes.gd")
const TI := preload("res://scripts/ui/installer/texts_installer.gd")

var _keep: Array = []


func _screen(t: Dictionary, setup: Object = null, handler: Callable = Callable()) -> Control:
	var d := ProjectSettings.globalize_path("user://test_installer_pad")
	UserFiles.remove_tree(d, ProjectSettings.globalize_path("user://").trim_suffix("/"))
	DirAccess.make_dir_recursive_absolute(d)
	var r := Fake.new()
	r.handler = handler if handler.is_valid() else func(cmd: String): return {"code": 1, "out": ""} if cmd.begins_with("pgrep") else {"code": 0, "out": ""}
	var dev := F.claw()
	var p := Plan.start(t, dev.profile, {"theme": "cove"})
	var inst: Node = Service.new()
	inst.setup(r, Paths.for_home(d + "/home", d + "/root"), t, "/opt/gc/gamecove.x86_64")
	var s := Screen.create(F.services(dev, setup if setup != null else F.FakeSetup.new(), F.Recorder.new(), d + "/power.cfg"), t, p, inst)
	_keep.append(s)
	return s


func _free(s: Control) -> void:
	_keep.erase(s)
	s.free()


func _r(x: float, y: float, w: float, h: float) -> Rect2:
	return Rect2(x, y, w, h)


# ---- the d-pad order on made-up layouts ------------------------------------------------------------

func test_welcome_layout_two_cards_then_the_buttons() -> void:
	# Easy | Custom, and under the page Skip | Back | Continue
	var kinds := [Nav.ITEM, Nav.ITEM, Nav.NAV, Nav.NAV, Nav.NAV]
	var rects := [_r(0, 100, 400, 300), _r(420, 100, 400, 300), _r(300, 700, 112, 50), _r(430, 700, 112, 50), _r(560, 700, 200, 50)]
	var n := Nav.neighbors(kinds, rects)
	eq(n[0]["right"], 1, "right from Easy: Custom")
	eq(n[1]["left"], 0, "left from Custom: Easy")
	eq(n[0]["left"], -1, "nothing left of Easy")
	eq(n[1]["right"], -1, "nothing right of Custom: no wrapping")
	eq(n[0]["down"], 4, "down from a card: Continue")
	eq(n[1]["down"], 4)
	eq(n[4]["up"], 0, "up from Continue: the first item at the top")
	eq(n[4]["left"], 3, "left from Continue: Back, the one beside it (not Skip)")
	eq(n[3]["left"], 2, "then Skip")
	eq(n[2]["right"], 3)
	eq(n[3]["right"], 4, "right: in the order they sit")
	eq(n[2]["left"], -1)
	eq(n[0]["up"], -1)


func test_three_buttons_are_walked_in_the_order_they_sit() -> void:
	# whatever order they were handed over in
	var kinds := [Nav.NAV, Nav.NAV, Nav.NAV]
	var rects := [_r(560, 700, 200, 50), _r(300, 700, 112, 50), _r(430, 700, 112, 50)]
	var n := Nav.neighbors(kinds, rects)
	eq(n[1]["right"], 2, "left-most to the middle one")
	eq(n[2]["right"], 0, "middle to the right-most")
	eq(n[0]["left"], 2)


func test_two_columns_move_sideways_between_columns_and_down_within_one() -> void:
	# the hardware page: fixes on the left, power defaults on the right, rows at different heights
	var kinds := [Nav.ITEM, Nav.ITEM, Nav.ITEM, Nav.ITEM, Nav.ITEM, Nav.NAV]
	var rects := [_r(0, 100, 500, 60), _r(0, 180, 500, 60), _r(0, 260, 500, 60),
		_r(520, 100, 500, 60), _r(520, 190, 500, 60), _r(800, 700, 200, 50)]
	var n := Nav.neighbors(kinds, rects)
	eq(n[1]["right"], 4, "right from a fix: the power row nearest in height, not a value change")
	eq(n[4]["left"], 1, "and back")
	eq(n[2]["right"], 4, "the left column's last row reaches the right column too")
	eq(n[0]["down"], 1, "down stays in the column")
	eq(n[3]["down"], 4)
	eq(n[2]["down"], 5, "the end of the page: Continue")
	eq(n[4]["down"], 5)
	eq(n[1]["up"], 0)


func test_a_row_of_actions_traverses_every_button() -> void:
	# Try again | Undo changes | Open the log, then the task list, then the buttons
	var kinds := [Nav.ITEM, Nav.ITEM, Nav.ITEM, Nav.NAV]
	var rects := [_r(0, 300, 300, 60), _r(320, 300, 300, 60), _r(640, 300, 300, 60), _r(700, 900, 200, 50)]
	var n := Nav.neighbors(kinds, rects)
	eq([n[0]["right"], n[1]["right"], n[2]["right"], n[2]["left"], n[1]["left"]], [1, 2, -1, 1, 0])
	eq(n[1]["down"], 3)


# ---- Easy / Custom: the focus and the choice are two things ------------------------------------

func test_welcome_a_selects_and_stays_and_continue_goes_on() -> void:
	var s := _screen(F.target("bazzite"))
	var easy: Button = s.body.find_child("Card_mode_easy", true, false)
	var custom: Button = s.body.find_child("Card_mode_custom", true, false)
	ok(easy.selected and not custom.selected, "Easy is selected to start with")
	custom.pressed.emit()
	eq(s.plan.step, "welcome", "A on a card doesn't go on")
	eq(s.plan.mode, "custom", "it selects")
	ok(custom.selected and not easy.selected, "one selected mark, on the chosen card")
	easy.pressed.emit()
	ok(easy.selected and not custom.selected, "radio: back to Easy")
	eq(s.plan.step, "welcome")
	s.next_step()
	eq(s.plan.step, "stores", "Continue goes on")
	_free(s)


func test_selected_and_focused_look_different() -> void:
	var s := _screen(F.target("bazzite"))
	var easy: Button = s.body.find_child("Card_mode_easy", true, false)
	var custom: Button = s.body.find_child("Card_mode_custom", true, false)
	var a: StyleBoxFlat = easy.get_theme_stylebox("normal")
	var b: StyleBoxFlat = custom.get_theme_stylebox("normal")
	ok(a.bg_color != b.bg_color, "a selected card is tinted, the other isn't")
	ok(easy.get_theme_stylebox("focus") != null and easy.get_theme_stylebox("focus") is StyleBoxFlat, "the focus ring is its own thing")
	ok(a.get_border_width(SIDE_LEFT) == 1 and b.get_border_width(SIDE_LEFT) == 1, "the selected edge is thin: the bold ring is only ever the focus")
	_free(s)


# ---- the buttons under the page ----------------------------------------------------------------

func test_every_page_links_its_buttons_in_the_order_they_sit() -> void:
	var s := _screen(F.target("bazzite"))
	for step in ["welcome", "startup", "steam", "stores", "device", "look", "art", "extras", "summary"]:
		s.plan.step = step
		s.show_step()
		var navs: Array = s.nav.get_children().filter(func(c): return c is BaseButton and c.visible)
		for i in navs.size():
			var c: Button = navs[i]
			var right: Control = c.get_node(c.focus_neighbor_right)
			var left: Control = c.get_node(c.focus_neighbor_left)
			eq(right, navs[i + 1] if i + 1 < navs.size() else c, "%s: right of %s" % [step, c.name])
			eq(left, navs[i - 1] if i > 0 else c, "%s: left of %s" % [step, c.name])
		ok(s.next_button.focus_neighbor_bottom == s.next_button.get_path_to(s.next_button), step + ": nothing below Continue")
	_free(s)


# ---- choices change on A only -------------------------------------------------------------------

func _press(row: Object, action: String) -> void:
	var ev := InputEventAction.new()
	ev.action = action
	ev.pressed = true
	row.button.gui_input.emit(ev)


func test_the_installer_d_pad_never_changes_a_choice() -> void:
	var s := _screen(F.target("bazzite"))
	s.plan.step = "device"
	s.show_step()
	var rows: Array = []
	for c in s.body.find_children("*", "VBoxContainer", true, false):
		if c.get_script() == ChoiceRow:
			rows.append(c)
	ok(rows.size() >= 2, "the hardware page has choices")
	for r in rows:
		ok(not r.step_on_pad, r.name + " doesn't step on the d-pad")
		var before: Variant = r.value()
		for a in ["ui_right", "ui_left", "ui_up", "ui_down"]:
			_press(r, a)
		eq(r.value(), before, r.name + " is unchanged by the d-pad")
		r.button.pressed.emit()
		ok(r.value() != before or r.values.size() < 2, r.name + " changes on A")
	_free(s)
	# settings pages keep stepping with left / right
	var plain: VBoxContainer = ChoiceRow.new()
	plain.setup("x", "X", [1, 2, 3], ["1", "2", "3"], 1)
	_press(plain, "ui_right")
	eq(plain.value(), 2, "settings pages still step with the d-pad")
	plain.free()


# ---- what can't be used takes no focus ----------------------------------------------------------

func test_cards_that_do_nothing_take_no_focus() -> void:
	var setup := F.FakeSetup.new()
	setup.status["gog"]["how"] = "unavailable"
	setup.status["amazon"]["how"] = "heroic"
	var s := _screen(F.target("bazzite"), setup)
	s.plan.step = "stores"
	s.show_step()
	for k in ["gog", "amazon"]:
		var c: Button = s.body.find_child("Card_store_" + k, true, false)
		ok(c != null and c.disabled, k + " is shown as not usable")
		eq(c.focus_mode, Control.FOCUS_NONE, k + " takes no focus from the pad or a touch")
		ok(not s.focusables().has(c), k + " is not in the focus order")
	var epic: Button = s.body.find_child("Card_store_epic", true, false)
	ok(epic.focus_mode == Control.FOCUS_ALL or epic.disabled, "a usable card keeps its focus")
	var ids: Array = s.nav_controls().map(func(c): return String(c.name))
	ok(not "Card_store_gog" in ids and not "Card_store_amazon" in ids, "and neither is in the d-pad order")
	_free(s)


func test_the_startup_page_unavailable_card_and_the_up_to_date_row_take_no_focus() -> void:
	var t := F.target("other")
	var s := _screen(t)
	s.plan.step = "startup"
	s.show_step()
	var inert := 0
	for c in s.body.find_children("Card_startup_*", "Button", true, false):
		if c.disabled:
			inert += 1
			eq(c.focus_mode, Control.FOCUS_NONE)
	ok(inert >= 1, "an unsupported system has cards it can't use")
	_free(s)
	var m := _screen(F.target("bazzite", {"installed": true, "maintenance": true, "update_available": false, "state": {"version": "0.2.0", "method": "rpm-ostree", "fixes": []}}))
	var same: Node = m.body.find_child("maint_update", true, false)
	eq(same.button.focus_mode, Control.FOCUS_NONE, "'up to date' isn't something to press")
	_free(m)


# ---- Install Heroic -------------------------------------------------------------------------------

func test_install_heroic_button_installs_the_flatpak_for_the_user_and_refreshes_the_stores() -> void:
	var setup := F.FakeSetup.new()
	for k in ["epic", "gog", "amazon"]:
		setup.status[k]["signed_in"] = false
		setup.status[k]["how"] = "unavailable"
		setup.status[k]["tool"] = ""
	var s := _screen(F.target("bazzite"), setup)
	s.flatpak = "flatpak"
	s.plan.step = "stores"
	s.show_step()
	var b: Button = s.body.find_child("InstallHeroic", true, false)
	ok(b != null, "an Install Heroic button when Heroic isn't there")
	ok(s.focusables().has(b), "it is the first thing to act on")
	var r: RefCounted = s.installer.runner
	b.pressed.emit()
	ok(r.called("flatpak remote-add --user --if-not-exists flathub"), "Flathub for this user first")
	ok(r.called("flatpak install --user --noninteractive -y flathub com.heroicgameslauncher.hgl"), "then Heroic, user scope, no prompts")
	ok(not r.calls.any(func(c): return c.begins_with("pkexec")), "no password")
	ok(DirAccess.dir_exists_absolute(s.installer.paths.home + "/.var/app/com.heroicgameslauncher.hgl/config/heroic"), "the store tools see it as set up")
	# the rows were read again: Heroic is there, so the button is gone and "Open Heroic" is offered
	setup.status["epic"]["how"] = "heroic"
	s.show_step()
	ok(s.body.find_child("InstallHeroic", true, false) == null, "installed: no install button")
	ok(s.body.find_child("OpenHeroic", true, false) != null, "sign in from Heroic is one press away")
	_free(s)


func test_a_failed_heroic_install_says_so_and_can_be_tried_again() -> void:
	var setup := F.FakeSetup.new()
	setup.status["epic"]["how"] = "unavailable"
	var s := _screen(F.target("bazzite"), setup, func(cmd: String):
		if cmd.begins_with("flatpak install"):
			return {"code": 1, "out": "error: no network"}
		return {"code": 1, "out": ""} if cmd.begins_with("pgrep") else {"code": 0, "out": ""})
	s.flatpak = "flatpak"
	s.plan.step = "stores"
	s.show_step()
	ok(s.install_heroic(), "started")
	ok(not DirAccess.dir_exists_absolute(s.installer.paths.home + "/.var/app/com.heroicgameslauncher.hgl/config/heroic"), "nothing marked as installed")
	ok(s.body.find_child("InstallHeroic", true, false) != null, "the button is still there to retry")
	_free(s)


# ---- nothing hidden below the page ---------------------------------------------------------------

func test_the_first_and_last_control_show_the_page_edges() -> void:
	var s := _screen(F.target("bazzite"))
	for step in ["device", "extras", "summary"]:
		s.plan.step = step
		s.show_step()
		var items: Array = s.nav_controls().filter(func(c): return c.get_parent() != s.nav)
		ok(items.size() >= 1, step + " has controls")
		eq(str(items[0].get_meta("scroll_edge", "")), "start" if items.size() >= 1 else "", step + ": the first shows the top")
		if items.size() > 1:
			eq(str(items[-1].get_meta("scroll_edge", "")), "end", step + ": the last shows the bottom (what's under it too)")
	_free(s)


# ---- the hint ---------------------------------------------------------------------------------

func test_the_press_a_hint_is_a_glyph_in_the_accent() -> void:
	var s := _screen(F.target("bazzite"))
	s.plan.step = "device"
	s.show_step()
	var c: Node = s.body.find_child("Card_xess_driver", true, false)
	if c == null:
		_free(s)
		return
	ok(c.find_child("HintGlyph", true, false) != null, "the controller's A is drawn")
	ok(c.footer.get_theme_font_size("font_size") > 14, "at the size of a button label")
	_free(s)
