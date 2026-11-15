extends "res://tests/test_case.gd"
## Controller rules (docs/CONTROLLER-UX.md) that a unit test can hold without a
## live screen: read-only device cards take no focus and their page names the
## right stick (CUX-7), "up" and "down" asked at the press (CUX-5), and the names
## of the per-press pictures tools/ux_walk/sheets.sh lays out. Order on real
## screens is the focus walk's job (tests/layout/focus_walk.gd); what needs focus
## and frames is in tests/e2e/suite_controller_ux.gd.

const Kit := preload("res://scripts/ui/ui_kit.gd")
const DKit := preload("res://scripts/ui/device/device_kit.gd")
const DevicePanel := preload("res://scripts/ui/device/device_panel.gd")
const TD := preload("res://scripts/ui/texts_device.gd")
const Shots := preload("res://tests/e2e/ux_shots.gd")


func test_read_only_device_cards_take_no_focus_until_they_have_a_job() -> void:
	var c: Array = DKit.card("Drive", "download", "info")
	var card: Control = c[0]
	eq(card.focus_mode, Control.FOCUS_NONE, "a read-only card is not a stop for the pad")
	eq(card.mouse_filter, Control.MOUSE_FILTER_IGNORE, "nor for a finger")
	card.set_action("Copy info", func(): pass)
	eq(card.focus_mode, Control.FOCUS_ALL, "a card with a job takes focus")
	ok(bool(card.get_meta("ux_action", false)), "and tells the focus walk A does something")
	card.free()


func test_a_device_page_leaves_read_only_cards_out_and_names_the_right_stick() -> void:
	var panel: HBoxContainer = DevicePanel.new()
	var col: VBoxContainer = panel.main_column()
	var act := Button.new()
	act.focus_mode = Control.FOCUS_ALL
	col.add_child(act)
	var card: Control = DKit.card("Read only", "info")[0]
	col.add_child(card)
	panel.chain([act, card])
	eq(panel.focus_chain(), [act], "the read-only card is left out of the focus chain")
	var sc: ScrollContainer = panel.stick_scroll.scroll
	ok(sc != null and sc.is_ancestor_of(col), "the cards' scroller is the one the right stick moves")
	var bar := sc.get_v_scroll_bar()
	bar.max_value = 400.0
	bar.page = 400.0
	eq(panel.scroll_hints(), [["B", TD.HINT_BACK]], "everything shows: no scroll prompt")
	eq(panel.hints_for(act), panel.scroll_hints(), "a page that names no A for a control shows these")
	# more cards than the page shows
	bar.max_value = 2000.0
	bar.page = 400.0
	eq(panel.scroll_hints(), [["RS", TD.HINT_SCROLL], ["B", TD.HINT_BACK]], "more below: the right stick is named")
	# not on screen: a push starts nothing (suite_controller_ux.gd scrolls a real page with it)
	panel.stick_scroll.push(1.0)
	eq(panel.stick_scroll.is_processing(), false, "a page that isn't shown never ticks")
	panel.free()


## CUX-2: the look in use is a thin edge and a tick; a thick ring in the accent is focus and nothing else.
func test_a_selected_look_is_a_tick_not_a_ring() -> void:
	var Appearance: Script = load("res://scripts/ui/settings/appearance_page.gd")
	var p: Control = Appearance.preview("cove")
	Appearance.mark_one(p, true)
	var sb := p.get_theme_stylebox("panel") as StyleBoxFlat
	ok(sb.border_width_left <= 1, "selected: a thin edge (%d px), never a ring" % sb.border_width_left)
	var tick: Control = p.find_child("Selected", true, false)
	ok(tick != null and tick.visible, "selected: a tick beside the name")
	Appearance.mark_one(p, false)
	ok(not tick.visible, "not selected: no tick")
	ok((p.get_theme_stylebox("panel") as StyleBoxFlat).border_width_left <= 1, "and the same thin edge")
	Appearance.mark_one(p, true)
	eq(p.find_children("Selected", "", true, false).size(), 1, "marking again adds no second tick")
	p.free()


## CUX-1: every card that is one choice among several wears the same focus (ring colour, 3 px, glow).
func test_choice_cards_share_one_focus_look() -> void:
	var ThemeLib: Script = load("res://theme/gamecove_theme.gd")
	var want: StyleBoxFlat = ThemeLib.card_focus(12)
	eq(want.border_color, ThemeLib.color("ring"), "the ring colour")
	eq(want.border_width_left, 3, "3 px")
	ok(want.shadow_size > 0, "with the glow")
	var OptionCard: Script = load("res://scripts/ui/installer/option_card.gd")
	var src := FileAccess.get_file_as_string("res://scripts/ui/installer/option_card.gd") + FileAccess.get_file_as_string("res://scripts/ui/setup/setup_flow.gd")
	ok(OptionCard != null and src.count("ThemeLib.card_focus(") == 2, "the installer's cards and first boot's looks both use it")
	ok(not 'focus_ring(ThemeLib.radius("m") + 4, ThemeLib.color("text")' in src, "no white frame of their own")


func test_up_and_down_leads_share_one_control() -> void:
	var a := Button.new()
	var b := Button.new()
	Kit.lead_up([a], func(): return b)
	Kit.lead_down([a], func(): return b)   # the second one used to fail: "already connected"
	Kit.lead_down([a], func(): return null)
	eq(a.gui_input.get_connections().size(), 1, "one handler, whatever was asked")
	ok(a.has_meta("lead_ui_up") and a.has_meta("lead_ui_down"), "both targets kept")
	a.free()
	b.free()


func test_walkthrough_pictures_are_named_by_test_number_and_press() -> void:
	eq(Shots.button_name(JOY_BUTTON_A), "A")
	eq(Shots.button_name(JOY_BUTTON_DPAD_DOWN), "Down")
	eq(Shots.button_name(JOY_BUTTON_START), "Menu")
	eq(Shots.axis_name(JOY_AXIS_TRIGGER_LEFT, 1.0), "LT")
	eq(Shots.axis_name(JOY_AXIS_LEFT_X, -1.0), "Stick-Left")
	eq(Shots.axis_name(JOY_AXIS_LEFT_Y, 1.0), "Stick-Down")
	eq(Shots.folder("suite_journeys::test_first_boot"), "suite_journeys__test_first_boot", "one folder per journey")
	eq(Shots.file_name(7, "Down"), "0007_Down.png", "numbered in the order pressed")
	eq(Shots.file_name(12, "Hold-B"), "0012_Hold-B.png")
	eq(Shots.on(), false, "off unless E2E_SHOTS names a folder: the e2e suites never pay for it")
