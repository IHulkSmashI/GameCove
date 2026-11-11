extends Control
## Settings: a category list on the left in two groups, HANDHELD (Power,
## Display, Sound, Controller, Performance, System, Profiles: generated from
## the Controls registry, scripts/ui/controls/) and GAMECOVE (Appearance,
## Stores, Discover, Device, About GameCove), and that category's tinted cards
## on the right. Moving through the list shows each page; A or right goes in,
## B comes back out to the list (B again goes home, handled by main.gd).
## open_category(id, part) jumps straight to a page (the quick menu's "All
## settings").
##
## Appearance rows are UI prefs: they go out through `changed(key, value)` and
## main.gd applies and saves them (same contract as before). Everything else
## talks to the services passed to set_services() (fakes in tests); without a
## call it falls back to the autoloads once it's in the tree.
##
## Overlays it owns: the store sign-in sheet (QR code + code entry), the credits
## viewer and the on-screen keyboard for keys and codes.

const FocusScroll := preload("res://scripts/ui/focus_scroll.gd")
const FadeMask := preload("res://scripts/ui/fade_mask.gd")
const Kit := preload("res://scripts/ui/ui_kit.gd")
const DKit := preload("res://scripts/ui/device/device_kit.gd")
const TS := preload("res://scripts/ui/texts_settings.gd")
const ThemeLib := preload("res://theme/gamecove_theme.gd")
const Icons := preload("res://scripts/ui/icons.gd")
const Motion := preload("res://scripts/ui/motion.gd")
const Osk := preload("res://scripts/ui/osk.gd")
const Services := preload("res://scripts/ui/settings/services.gd")
const SignIn := preload("res://scripts/ui/settings/sign_in.gd")
const Credits := preload("res://scripts/ui/settings/credits.gd")
const PerformancePage := preload("res://scripts/ui/settings/performance_page.gd")
const SetupFlow := preload("res://scripts/ui/setup/setup_flow.gd")
const TC := preload("res://scripts/ui/texts_controls.gd")
const CIcons := preload("res://scripts/ui/controls/cicons.gd")
const GroupPage := preload("res://scripts/ui/controls/group_page.gd")
const SessionGuard := preload("res://scripts/ui/controls/session_guard.gd")
const Shared := preload("res://scripts/ui/controls/shared.gd")
const PAGES := {
	"power": GroupPage,
	"display": GroupPage,
	"audio": GroupPage,
	"controller": GroupPage,
	"performance": preload("res://scripts/ui/controls/perf_page.gd"),
	"system": GroupPage,
	"profiles": preload("res://scripts/ui/controls/profiles_page.gd"),
	"appearance": preload("res://scripts/ui/settings/appearance_page.gd"),
	"quick_menu": preload("res://scripts/ui/settings/quick_menu_page.gd"),
	"stores": preload("res://scripts/ui/settings/stores_page.gd"),
	"saves": preload("res://scripts/ui/settings/saves_page.gd"),
	"discover": preload("res://scripts/ui/settings/discover_page.gd"),
	"media": preload("res://scripts/ui/settings/media_page.gd"),
	"device": preload("res://scripts/ui/settings/device_page.gd"),
	"about": preload("res://scripts/ui/settings/about_page.gd"),
}

signal changed(key: String, value: Variant)
## Something worth a toast (key saved, sign-in done): main may show it.
signal notice(text: String, tone: String)
## Settings wants first-run setup open at `step` ("" = first unfinished).
## Without a listener the screen opens it itself over its top Control.
signal setup_requested(step: String)
## A page wants the quick menu open for `game` (Profiles > a game > Edit).
signal game_settings_requested(game: Dictionary)
## A page wants an app started like a game (Media > a clip > Watch: its player).
signal app_launch_requested(app: Dictionary)

## UI pref rows (theme, match_art, reduce_motion, menu_side, ui_sounds).
var rows := {}
## Current UI pref values ({"theme", "match_art", ...}).
var values := {}
var version := "Development build"
var services := {}
var pages := {}
var category := "appearance"
var cat_buttons := {}
var swatches: HBoxContainer
var top_target: Control
var status_label: Label
var keyboard: PanelContainer
var sheet: PanelContainer
var sign_in: HBoxContainer
var _layout: Control
var _content: VBoxContainer
var _scroll: ScrollContainer
## "More below" at the foot of the page while it can scroll further.
var more_cue: HBoxContainer
var _dim: ColorRect
var _sheet_body: VBoxContainer
var _ask_done: Callable
var _ask_return: Control
var _sheet_return: Control
var _status_timer: Timer
var _services_set := false


func _init() -> void:
	name = "Settings"
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func _ready() -> void:
	_late_start.call_deferred()


## Leaving Settings for another screen hides it without changing the category:
## the page on show stops what it watches (the Device page's Storage tab polls
## the mounts while open) and starts again when Settings comes back.
var _page_hidden := false


func _notification(what: int) -> void:
	if what != NOTIFICATION_VISIBILITY_CHANGED or not pages.has(category):
		return
	if not is_visible_in_tree() and not _page_hidden:
		_page_hidden = true
		if pages[category].has_method("on_hidden"):
			pages[category].on_hidden()
	elif is_visible_in_tree() and _page_hidden:
		_page_hidden = false
		if pages[category].has_method("on_shown"):
			pages[category].on_shown()


## No host passed services: use the autoloads (never under the test runner),
## and on a first run open setup if nobody else did.
func _late_start() -> void:
	if not _services_set:
		var found := Services.from_tree(self)
		if not found.is_empty():
			set_services(found)
	if setup_requested.get_connections().is_empty() and SetupFlow.instance == null \
			and SetupFlow.should_show(services.get("setup")):
		open_setup("")
	# A refresh-rate unlock from the last session waits for "Keep this?".
	if not Services.under_tests(self):
		SessionGuard.check(self, services.get("controls"), services.get("profiles"))


## Every category id, in list order (both groups).
static func categories() -> Array:
	var out := []
	for g in TC.CATEGORY_GROUPS:
		out.append_array(g[1])
	return out


static func category_name(id: String) -> String:
	return str(TC.CATEGORY_NAMES.get(id, TS.CATEGORY_NAMES.get(id, id.capitalize())))


static func category_icon(id: String) -> String:
	return str(TC.CATEGORY_ICONS.get(id, TS.CATEGORY_ICONS.get(id, "settings")))


## values: {"theme", "match_art", "reduce_motion", "menu_side", "ui_sounds"};
## about: [[label, value], ...] (its "GameCove" line is the version).
## Called again after a theme change: rebuilds, keeping the category.
func setup(ui_values: Dictionary, about: Array = []) -> void:
	values = ui_values.duplicate()
	for l in about:
		if l.size() >= 2 and str(l[0]) == "GameCove":
			version = str(l[1])
	_build()


## The services the pages use: {"setup", "library", "discover", "perf",
## "achievements", "device", plus anything the Device panels want}.
func set_services(svc: Dictionary) -> void:
	services = svc
	# main.gd doesn't pass Controls / Profiles: the autoloads (none under tests)
	for k in [["controls", "Controls"], ["profiles", "Profiles"]]:
		if not services.has(k[0]):
			var n := Shared.autoload(k[1])
			if n != null:
				services = services.duplicate()
				services[k[0]] = n
	_services_set = true
	PerformancePage.restore_rarity(services.get("achievements"))
	if _content != null:
		_build()


func _build() -> void:
	var keep_cat := category
	for c in get_children():
		if c != _status_timer:
			Kit.drop(self, c)
	rows.clear()
	pages.clear()
	cat_buttons.clear()
	keyboard = null
	sheet = null
	sign_in = null

	var margin := Kit.margin(0)
	margin.name = "Layout"
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 48)
	margin.add_theme_constant_override("margin_right", 48)
	margin.add_theme_constant_override("margin_top", 88)
	# 16 px clear of the hint band: no card runs flush into it.
	margin.add_theme_constant_override("margin_bottom", ThemeLib.HINT_BAR_H + 16)
	add_child(margin)
	_layout = margin
	var root := Kit.vbox(16)
	margin.add_child(root)
	var head := Kit.hbox(16)
	head.add_child(Kit.label("Settings", "TitleLabel"))
	head.add_child(Kit.spacer())
	status_label = Kit.label("", "AccentLabel")
	status_label.name = "Status"
	status_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	status_label.size_flags_vertical = Control.SIZE_FILL
	head.add_child(status_label)
	root.add_child(head)

	var cols := Kit.hbox(28)
	cols.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(cols)
	var list_scroll := ScrollContainer.new()
	list_scroll.name = "CategoryScroll"
	FocusScroll.attach(list_scroll)   # not follow_focus: it left the row above half cut at the top
	list_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	list_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_NEVER
	list_scroll.custom_minimum_size = Vector2(280, 0)
	cols.add_child(list_scroll)
	var list := Kit.vbox(3)
	list.name = "Categories"
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list_scroll.add_child(list)
	# On a small screen the category list is longer than the screen: the same
	# rule, no half button at its foot.
	var list_mask: TextureRect = FadeMask.wrap(list_scroll, 24.0)
	list_mask.cut_fn = func(): return list.get_children()
	for g in TC.CATEGORY_GROUPS:
		var gl := Kit.micro(g[0])
		gl.name = "Group_" + str(g[0])
		gl.add_theme_color_override("font_color", ThemeLib.color("text_3"))
		var gpad := Kit.margin(0)
		gpad.add_theme_constant_override("margin_left", 16)
		gpad.add_theme_constant_override("margin_top", 0 if list.get_child_count() == 0 else 10)
		gpad.add_theme_constant_override("margin_bottom", 2)
		gpad.add_child(gl)
		list.add_child(gpad)
		for id in g[1]:
			var b := _category_button(id)
			list.add_child(b)
			cat_buttons[id] = b
	# A little room under the last category, so the list can stop on a whole row at its top
	# when the last one is focused (without it the list ends flush and the row above the top
	# edge stays half cut).
	var tail := Control.new()
	tail.name = "Tail"
	tail.custom_minimum_size = Vector2(0, 96)
	tail.mouse_filter = Control.MOUSE_FILTER_IGNORE
	list.add_child(tail)

	_scroll = ScrollContainer.new()
	_scroll.name = "Scroll"
	FocusScroll.attach(_scroll)
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_NEVER
	_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	# The same rule as the device pages: a card or a row the foot would slice
	# isn't drawn at all (the mask ends under the last whole one, so no header
	# sliver and no half row), what you're reading fades out instead, and
	# "More below" says there's more.
	var holder := Control.new()
	holder.name = "PageColumn"
	holder.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	holder.size_flags_vertical = Control.SIZE_EXPAND_FILL
	holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	cols.add_child(holder)
	_scroll.set_anchors_preset(Control.PRESET_FULL_RECT)
	holder.add_child(_scroll)
	var mask: TextureRect = FadeMask.wrap(_scroll, 28.0)
	mask.cut_fn = func(): return cut_items()
	more_cue = DKit.more_cue(holder, _scroll)
	var pad := Kit.margin(6, 6, 6)
	pad.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll.add_child(pad)
	_content = Kit.vbox(0)
	_content.name = "Content"
	_content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	pad.add_child(_content)

	for id in categories():
		var p: VBoxContainer = PAGES[id].new()
		p.visible = false
		_content.add_child(p)
		p.setup(id, services, self)
		p.rebuilt.connect(_link)
		if p.has_signal("edit_game_requested"):
			p.edit_game_requested.connect(func(g): game_settings_requested.emit(g))
		pages[id] = p
	for k in pages["appearance"].rows:
		rows[k] = pages["appearance"].rows[k]
	swatches = pages["appearance"].swatches
	_build_overlays()
	show_category(keep_cat if pages.has(keep_cat) else "appearance")


## What the page's foot may never slice: the cards of the page showing, and
## inside a long card that runs past the view (a list), its rows. A long card
## that's whole in view stays one piece, so its own foot shows.
func cut_items() -> Array:
	var out: Array = []
	if _content == null or _scroll == null:
		return out
	var tall := maxf(_scroll.size.y * 0.45, 200.0)
	var view := _scroll.get_global_rect() if _scroll.is_inside_tree() else Rect2()
	for p in _content.get_children():
		if p is Control and (p as Control).visible:
			_cut_items_in(p, tall, out, 0, view)
	return out


static func _cut_items_in(n: Control, tall: float, out: Array, depth: int, view := Rect2()) -> void:
	for c in n.get_children():
		if not (c is Control) or not (c as Control).visible:
			continue
		var k := c as Control
		var whole := view.size.y > 0.0 and k.is_inside_tree() and view.grow(1.0).encloses(k.get_global_rect())
		if k.size.y > tall and not whole and depth < 5 and k is Container and not k is ScrollContainer and k.get_child_count() > 0:
			_cut_items_in(k, tall, out, depth + 1, view)
		elif k.size.y > 0.0:
			out.append(k)


func _category_button(id: String) -> Button:
	var b := Kit.button("", "RowButton")
	b.name = "Cat_" + id
	b.toggle_mode = true
	b.custom_minimum_size = Vector2(0, 40)
	b.tooltip_text = str(TC.CATEGORY_LINES.get(id, TS.CATEGORY_LINES.get(id, "")))
	# The chosen category is active, not focused: a quiet surface fill and the
	# accent bar on its left (no accent edge: focus wears the only ring).
	var chosen := ThemeLib.active_box(ThemeLib.radius("m"), 18, 6)
	b.add_theme_stylebox_override("pressed", chosen)
	b.add_theme_stylebox_override("hover_pressed", chosen)
	b.focus_entered.connect(func(): show_category(id))
	b.pressed.connect(func():
		b.set_pressed_no_signal(true)
		enter_page())
	var row := Kit.hbox(12)
	row.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	row.offset_left = 12
	row.offset_right = -12
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var bar := Panel.new()
	bar.name = "Bar"
	bar.custom_minimum_size = Vector2(4, 22)
	bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bar.add_theme_stylebox_override("panel", ThemeLib.box(ThemeLib.color("accent"), 999, 0, 0))
	row.add_child(bar)
	var ic := CIcons.rect(category_icon(id), 22, ThemeLib.color("text_2"))
	ic.name = "Icon"
	row.add_child(ic)
	var t := Kit.label(category_name(id))
	t.name = "Title"
	t.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	t.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	t.size_flags_vertical = Control.SIZE_FILL
	t.add_theme_font_override("font", ThemeLib.font("semibold"))
	row.add_child(t)
	b.add_child(row)
	return b


## Shows a category's page (focus stays where it is).
func show_category(id: String) -> void:
	if not pages.has(id):
		return
	var old := category
	category = id
	for k in pages:
		var on: bool = k == id
		if pages[k].visible != on:
			if on:
				pages[k].visible = true
				pages[k].modulate.a = 0.0
				Motion.to(pages[k], "modulate:a", 1.0, Motion.FAST)
			else:
				pages[k].visible = false
		var b: Button = cat_buttons[k]
		b.set_pressed_no_signal(on)
		b.find_child("Bar", true, false).modulate.a = 1.0 if on else 0.0
		var col := ThemeLib.color("accent") if on else ThemeLib.color("text_2")
		(b.find_child("Icon", true, false) as TextureRect).texture = CIcons.tex(category_icon(k), 22, col)
	if old != id and pages.has(old) and pages[old].has_method("on_hidden"):
		pages[old].on_hidden()
	if pages[id].has_method("on_shown"):
		pages[id].on_shown()
	if _scroll != null:
		_scroll.scroll_vertical = 0
	_link()


## Focus into the current page's first control.
func enter_page() -> void:
	var f: Array = pages[category].focusables()
	if not f.is_empty() and is_inside_tree():
		f[0].grab_focus()


## Shows category `id` and goes into it, at `part` when the page knows it
## (Device: "fixes"). The quick menu's "All settings" lands here.
func open_category(id: String, part := "") -> void:
	if not pages.has(id):
		return
	if is_inside_tree() and cat_buttons.has(id):
		cat_buttons[id].grab_focus()
	show_category(id)
	var target: Control = null
	if part != "" and pages[id].has_method("focus_part"):
		target = pages[id].focus_part(part)
	if target == null:
		var f: Array = pages[id].focusables()
		target = f[0] if not f.is_empty() else null
	if target != null and is_inside_tree():
		_focus_later_in(id, part, target)


## Focus `target` once the frame settles; if the page rebuilt it in between (the Fixes page does
## when its status answers come in), the same part's new first control instead.
func _focus_later_in(id: String, part: String, target: Control) -> void:
	var ref: WeakRef = weakref(target)
	(func():
		var n: Control = ref.get_ref()
		if (n == null or not n.is_inside_tree()) and category == id and pages.has(id):
			n = pages[id].focus_part(part) if part != "" and pages[id].has_method("focus_part") else null
			if n == null:
				var f: Array = pages[id].focusables()
				n = f[0] if not f.is_empty() else null
		if n != null and n.is_inside_tree() and n.is_visible_in_tree():
			n.grab_focus()
	).call_deferred()


func _link() -> void:
	if cat_buttons.is_empty():
		return
	var list: Array = categories().map(func(k): return cat_buttons[k])
	Kit.link_vertical(list, top_target)
	var chain: Array = pages[category].focusables() if pages.has(category) else []
	chain = chain.filter(func(c): return c != null and is_instance_valid(c))
	var cat: Button = cat_buttons[category]
	for b in list:
		b.focus_neighbor_right = b.get_path_to(chain[0] if not chain.is_empty() else b)
	if chain.is_empty():
		return
	Kit.link_vertical(chain, top_target)
	for c in chain:
		# panels with columns (About this device) keep their own left move
		if c.focus_neighbor_left.is_empty() or c.get_node_or_null(c.focus_neighbor_left) in cat_buttons.values() \
				or c.get_node_or_null(c.focus_neighbor_left) == c:
			c.focus_neighbor_left = c.get_path_to(cat)


func set_top_target(c: Control) -> void:
	top_target = c
	_link()


func default_focus() -> Control:
	return cat_buttons.get(category)


## True while focus is inside the page (not the category list).
func in_page() -> bool:
	if not is_inside_tree() or _content == null:
		return false
	var f := get_viewport().gui_get_focus_owner()
	return f != null and _content.is_ancestor_of(f)


## True when left / right change the focused control's value: a slider, or a
## choice row's stepper (its parent lists the values).
static func changes_with_lr(f: Control) -> bool:
	if f is Slider:
		return f.editable
	return f is Button and f.theme_type_variation == "RowButton" and f.get_parent() != null and "values" in f.get_parent()


## Hint bar for whatever has focus here, for main.gd's hint bar
## (see docs: main uses it when the screen has `hints`). [] = main's default.
func hints(f: Control) -> Array:
	if keyboard != null and keyboard.is_open():
		return [["A", "Type"], ["Y", "Space"], ["X", "Delete"], ["B", "Cancel"], ["MENU", "Done"]]
	if sheet != null and sheet.visible:
		return [["A", "Select"], ["B", TS.CLOSE]]
	var pg_m: Control = pages.get(category)
	if pg_m != null and pg_m.has_method("modal_hints") and not pg_m.modal_hints().is_empty():
		return pg_m.modal_hints()
	if f == null:
		return []
	var cat := cat_buttons.values().has(f)
	var out: Array = []
	if cat:
		out.append(["A", "Open"])
		out.append(["B", "Home"])
	else:
		var pg_a: Control = pages.get(category)
		var named: String = pg_a.a_hint(f) if pg_a != null and pg_a.has_method("a_hint") else ""
		if changes_with_lr(f):
			out.append(["LR", "Change"])
		elif named != "":
			out.append(["A", named])
		else:
			out.append(["A", "Select"])
		if pg_a != null and pg_a.has_method("extra_hints"):
			out.append_array(pg_a.extra_hints(f))
		out.append(["B", "Categories"])
	# LB / RB always switch the top sections; LT / RT the page's own tabs.
	var pg: Control = pages.get(category)
	if pg != null and pg.has_method("cycle_tabs"):
		out.append([["LT", "RT"], "Tabs"])
	out.append([["LB", "RB"], "Sections"])
	out.append(["GUIDE", "Quick menu"])
	return out


func _unhandled_input(event: InputEvent) -> void:
	if not is_visible_in_tree():
		return
	var overlay: bool = (sheet != null and sheet.visible) or (keyboard != null and keyboard.is_open())
	if overlay:
		if event.is_action_pressed("ui_cancel") and sheet.visible and not keyboard.is_open():
			close_sheet()
			get_viewport().set_input_as_handled()
		elif _swallow(event):
			get_viewport().set_input_as_handled()
		return
	if event.is_action_pressed("ui_cancel") and in_page():
		cat_buttons[category].grab_focus()
		get_viewport().set_input_as_handled()


## Shoulder and trigger presses would switch screens behind an overlay.
static func _swallow(event: InputEvent) -> bool:
	if event is InputEventJoypadButton:
		return event.button_index in [JOY_BUTTON_LEFT_SHOULDER, JOY_BUTTON_RIGHT_SHOULDER]
	if event is InputEventKey:
		return event.keycode in [KEY_Q, KEY_E, KEY_PAGEUP, KEY_PAGEDOWN]
	return event is InputEventJoypadMotion and event.axis in [JOY_AXIS_TRIGGER_LEFT, JOY_AXIS_TRIGGER_RIGHT]


## LT / RT: the open page's tabs (Settings > Device: About, Fixes, Storage,
## Updates). Focus follows to the new tab when it was inside the page.
func cycle_tabs(d: int) -> bool:
	var pg: Control = pages.get(category)
	if pg == null or not pg.has_method("cycle_tabs") or not pg.is_visible_in_tree():
		return false
	var was_in := in_page()
	var t: Control = pg.cycle_tabs(d)
	if was_in and t != null:
		t.grab_focus()
	return true


# ------------------------------------------------------------ host API for pages

func notify(text: String, tone := "") -> void:
	if status_label == null:
		return
	status_label.text = text
	status_label.add_theme_color_override("font_color", ThemeLib.tone(tone) if tone in ["bad", "warn", "good"] else ThemeLib.color("accent"))
	notice.emit(text, tone)
	if _status_timer == null:
		_status_timer = Timer.new()
		_status_timer.one_shot = true
		_status_timer.timeout.connect(func(): status_label.text = "")
		add_child(_status_timer)
	if _status_timer.is_inside_tree():
		_status_timer.start(5.0)


## Starts `app` like a game (main.gd listens and launches it).
func request_app_launch(app: Dictionary) -> void:
	app_launch_requested.emit(app)


## Opens the keyboard for a key or code; `done(text)` gets what was typed.
## `secret`: an API key or password, drawn as dots (Show reveals it).
func ask_text(placeholder: String, start: String, done: Callable, secret := false) -> void:
	_ask_done = done
	_ask_return = get_viewport().gui_get_focus_owner() if is_inside_tree() else null
	keyboard.use_for_codes(placeholder, 600, secret)
	_set_layout_focus(false)
	keyboard.open(start)


func _on_keyboard_closed(text: String) -> void:
	var cb := _ask_done
	_ask_done = Callable()
	if sheet == null or not sheet.visible:
		_set_layout_focus(true)
	if _ask_return != null and is_instance_valid(_ask_return) and _ask_return.is_visible_in_tree():
		_ask_return.grab_focus()
	if cb.is_valid() and not keyboard.cancelled:   # B / Esc: nothing typed is kept, so nothing is saved or checked
		cb.call(text)


## The sign-in sheet for one store: QR code, steps, Type code.
func open_sign_in(store: String) -> void:
	_open_sheet()
	for c in _sheet_body.get_children():
		Kit.drop(_sheet_body, c)
	sign_in = SignIn.new()
	sign_in.finished.connect(func(s, ok, _m):
		if ok:
			notify(TS.SIGN_IN_DONE % TS.STORE_NAMES.get(s, s), "good"))
	_sheet_body.add_child(sign_in)
	var pr := Kit.prompts([["A", TS.SIGN_IN_TYPE], ["B", TS.CLOSE]])
	pr.alignment = BoxContainer.ALIGNMENT_END
	_sheet_body.add_child(pr)
	sign_in.start(services.get("setup"), store, ask_text)
	if is_inside_tree():
		sign_in.first_focus().grab_focus()


func open_credits() -> void:
	_open_sheet()
	for c in _sheet_body.get_children():
		Kit.drop(_sheet_body, c)
	_sheet_body.add_child(Kit.label(TS.ABOUT_CREDITS, "HeaderLabel"))
	var text := Credits.full_text()
	var r := RichTextLabel.new()
	r.name = "Credits"
	r.bbcode_enabled = true
	r.focus_mode = Control.FOCUS_ALL
	r.scroll_active = true
	r.selection_enabled = false
	r.custom_minimum_size = Vector2(0, 470)
	r.add_theme_font_override("normal_font", ThemeLib.font("regular"))
	r.add_theme_font_override("bold_font", ThemeLib.font("semibold"))
	r.add_theme_font_size_override("normal_font_size", ThemeLib.SIZE_SMALL)
	r.add_theme_font_size_override("bold_font_size", ThemeLib.SIZE_SMALL)
	r.add_theme_color_override("default_color", ThemeLib.color("text"))
	r.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	r.text = Credits.to_bbcode(text, "#" + ThemeLib.color("text").to_html(false), "#" + ThemeLib.color("text_2").to_html(false)) if text != "" else TS.CREDITS_MISSING
	_sheet_body.add_child(r)
	_sheet_body.add_child(Kit.prompts([["DPAD", "Scroll"], ["B", TS.CLOSE]]))
	if is_inside_tree():
		r.grab_focus()


func open_url(url: String) -> void:
	var d: Object = services.get("discover")
	if d != null and d.has_method("open_link") and d.open_link({"kind": "url", "uri": url}):
		notify("Opening in Steam…")
	else:
		notify(url)


## Opens first-run setup at `step` (a TS.SETUP_STEPS id, "" = first unfinished).
func open_setup(step: String) -> void:
	if not setup_requested.get_connections().is_empty():
		setup_requested.emit(step)
		return
	var host := _top_control()
	if host == null:
		return
	var flow: Control = SetupFlow.open(host, services, step)
	if flow != null and not flow.setting_changed.is_connected(_relay_setting):
		flow.setting_changed.connect(_relay_setting)


func _relay_setting(key: String, value: Variant) -> void:
	changed.emit(key, value)


func _top_control() -> Control:
	var c: Node = self
	while c.get_parent() is Control:
		c = c.get_parent()
	return c as Control if c is Control and c.is_inside_tree() else null


# ------------------------------------------------------------ overlays

func _build_overlays() -> void:
	_dim = ColorRect.new()
	_dim.name = "Dim"
	_dim.color = Color(ThemeLib.color("scrim"), 0.78)
	_dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	_dim.visible = false
	add_child(_dim)
	# Over the top bar and hint bar too (same canvas, higher z), so nothing
	# behind the sheet looks pressable and the sheet's own prompts are the hints.
	_dim.z_index = 10
	sheet = PanelContainer.new()
	sheet.name = "Sheet"
	sheet.z_index = 10
	var ssb := ThemeLib.box(Color(ThemeLib.color("surface"), 0.98), ThemeLib.radius("xl"), 32, 28)
	ssb.border_color = ThemeLib.color("line")
	ssb.set_border_width_all(1)
	ssb.shadow_color = Color(0, 0, 0, 0.4 if ThemeLib.is_dark() else 0.12)
	ssb.shadow_size = 28
	sheet.add_theme_stylebox_override("panel", ssb)
	sheet.visible = false
	sheet.set_anchors_preset(Control.PRESET_CENTER)
	sheet.grow_horizontal = Control.GROW_DIRECTION_BOTH
	sheet.grow_vertical = Control.GROW_DIRECTION_BOTH
	sheet.custom_minimum_size = Vector2(900, 0)
	_sheet_body = Kit.vbox(18)
	sheet.add_child(_sheet_body)
	add_child(sheet)
	keyboard = Osk.new()
	keyboard.z_index = 11
	keyboard.anchor_left = 0.5
	keyboard.anchor_right = 0.5
	keyboard.anchor_top = 1.0
	keyboard.anchor_bottom = 1.0
	keyboard.offset_left = -400
	keyboard.offset_right = 400
	keyboard.offset_top = -424
	keyboard.offset_bottom = -64
	keyboard.closed.connect(_on_keyboard_closed)
	add_child(keyboard)


func _open_sheet() -> void:
	_sheet_return = get_viewport().gui_get_focus_owner() if is_inside_tree() else null
	_set_layout_focus(false)
	_dim.visible = true
	Motion.fade(sheet, true)
	sheet.pivot_offset = sheet.size / 2.0
	sheet.scale = Vector2.ONE * (1.0 if Motion.reduce else 0.97)
	Motion.to(sheet, "scale", Vector2.ONE, Motion.BASE)


func close_sheet() -> void:
	if sheet == null or not sheet.visible:
		return
	if sign_in != null and is_instance_valid(sign_in):
		sign_in.stop()
	sheet.visible = false
	_dim.visible = false
	_set_layout_focus(true)
	if _sheet_return != null and is_instance_valid(_sheet_return) and _sheet_return.is_visible_in_tree():
		_sheet_return.grab_focus()


func _set_layout_focus(on: bool) -> void:
	if _layout != null:
		_layout.focus_behavior_recursive = Control.FOCUS_BEHAVIOR_INHERITED if on else Control.FOCUS_BEHAVIOR_DISABLED
