extends Control
## The Discover area: a header (title, section chips with LT / RT, an offline
## pill), the four sections (For you, Deals, Coming soon, Wishlist) and store
## pages on top. Talks to the Discover and Art services, turns their signals
## into rebuilds (coalesced to one per frame), shows price / release alerts
## as toasts, and owns Discover's X / Y / LT / RT / B handling and hints.
##
## Services (DiscoverScreen passes main's, plus layers it made):
##   {"library", "open_game": Callable(game), "toast": Callable(text, icon, tone, detail),
##    "discover"?, "art"?  (default: the autoloads), "stage": Control, "overlay": Control,
##    "prefs_path"?: String, "clock"?: Callable}

const Kit := preload("res://scripts/ui/ui_kit.gd")
const Icons := preload("res://scripts/ui/icons.gd")
const ThemeLib := preload("res://theme/gamecove_theme.gd")
const Motion := preload("res://scripts/ui/motion.gd")
const T := preload("res://scripts/ui/texts_discover.gd")
const W := preload("res://scripts/ui/discover/widgets.gd")
const Ctx := preload("res://scripts/ui/discover/ctx.gd")
const ArtLink := preload("res://scripts/ui/discover/art_link.gd")
const Prefs := preload("res://scripts/ui/discover/prefs.gd")
const HomeView := preload("res://scripts/ui/discover/home_view.gd")
const DealsView := preload("res://scripts/ui/discover/deals_view.gd")
const CalendarView := preload("res://scripts/ui/discover/calendar_view.gd")
const WishlistView := preload("res://scripts/ui/discover/wishlist_view.gd")
const StorePage := preload("res://scripts/ui/discover/store_page.gd")

signal game_focused(game: Dictionary)
signal open_requested(game: Dictionary)
## Hints or page state changed: DiscoverScreen redraws the hint bar.
signal hints_changed
## A store page opened (true) or closed (false): the top bar hides meanwhile.
signal page_toggled(open: bool)
## Alerts waiting in the inbox (for a dot on the Discover tab).
signal alerts_changed(count: int)

const ORDER := ["home", "deals", "calendar", "wishlist"]

var ctx: Ctx
var sections := {}
var chips := {}
var current := "home"
var page: Control = null
var top_target: Control
var header: HBoxContainer
var offline_pill: Control
var _overlay: Control
var _body: Control
var _wish_dot: Panel
var _queued := {}
var _flush_pending := false
var _page_return: Control
var _last_focus := {}
var _trigger_held := {}


func setup(services: Dictionary) -> void:
	name = "DiscoverRoot"
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	ctx = Ctx.new()
	ctx.discover = services.get("discover", _autoload("Discover"))
	ctx.library = services.get("library")
	ctx.art = ArtLink.new(services.get("art", _autoload("Art")))
	ctx.prefs = Prefs.new(services.get("prefs_path", "user://discover_ui.cfg"))
	if services.get("clock") is Callable:
		ctx.clock = services["clock"]
	elif ctx.discover != null and ctx.discover.get("clock") is Callable:
		ctx.clock = ctx.discover.clock
	ctx.toast_fn = services.get("toast", Callable())
	ctx.open_game_fn = func(g):
		close_page()
		var f: Variant = services.get("open_game")
		if f is Callable and f.is_valid():
			f.call(g)
	ctx.open_page_fn = open_page
	ctx.focus_fn = func(v): game_focused.emit(v)
	ctx.hints_changed_fn = func(): hints_changed.emit()
	_overlay = services.get("overlay")

	var col := Kit.vbox(16)
	col.name = "Column"
	col.set_anchors_preset(Control.PRESET_FULL_RECT)
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(col)
	header = _build_header()
	col.add_child(header)
	_body = Control.new()
	_body.name = "Body"
	_body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_body.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(_body)

	for id in ORDER:
		var s: Control
		match id:
			"home": s = HomeView.new()
			"deals": s = DealsView.new()
			"calendar": s = CalendarView.new()
			"wishlist": s = WishlistView.new()
		s.setup(ctx)
		s.visible = id == current
		s.set_top_target(chips[id])
		_body.add_child(s)
		sections[id] = s
	if services.get("stage") is Control:
		sections["home"].attach_stage(services["stage"])

	if ctx.discover != null:
		var d: Object = ctx.discover
		d.deals_changed.connect(func(): _queue(["home", "deals"]))
		d.calendar_changed.connect(func(): _queue(["home", "calendar"]))
		d.wishlist_changed.connect(_on_wishlist_changed)
		d.settings_changed.connect(func(): _queue(ORDER))
		d.status_changed.connect(_on_status)
		d.import_done.connect(func(ok, added, err): sections["wishlist"].on_import_done(ok, added, err))
		d.price_alert.connect(_on_price_alert)
		d.release_alert.connect(_on_release_alert)
	ctx.art.arrived.connect(_on_art)
	for id in ORDER:
		sections[id].refresh()
	_update_header()


static func _autoload(n: String) -> Object:
	var ml := Engine.get_main_loop()
	if ml is SceneTree and (ml as SceneTree).root != null:
		return (ml as SceneTree).root.get_node_or_null(n)
	return null


func _build_header() -> HBoxContainer:
	var h := Kit.hbox(12)
	h.name = "Header"
	var t := Kit.label(T.TITLE, "TitleLabel")
	t.name = "Title"
	h.add_child(t)
	var gap := Control.new()
	gap.custom_minimum_size = Vector2(16, 0)
	h.add_child(gap)
	var lt := Kit.glyph("LT", false, true)
	h.add_child(lt)
	var order: Array = []
	for id in ORDER:
		var b := Kit.button(T.SECTIONS[id], "ChipButton")
		b.name = "Section_" + id
		b.toggle_mode = true
		b.button_pressed = id == current
		b.custom_minimum_size = Vector2(0, 44)
		b.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		b.set_meta("role", "section_" + id)
		var sid: String = id
		b.pressed.connect(func(): show_section(sid))
		h.add_child(b)
		chips[id] = b
		order.append(b)
	_wish_dot = Panel.new()
	_wish_dot.name = "Dot"
	_wish_dot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_wish_dot.anchor_left = 1.0
	_wish_dot.anchor_right = 1.0
	_wish_dot.offset_left = -12
	_wish_dot.offset_right = -4
	_wish_dot.offset_top = 4
	_wish_dot.offset_bottom = 12
	_wish_dot.visible = false
	chips["wishlist"].add_child(_wish_dot)
	h.add_child(Kit.glyph("RT", false, true))
	h.add_child(Kit.spacer())
	offline_pill = W.badge("offline", T.OFFLINE_PILL, "warn", "cloud_off", "chip")
	offline_pill.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	offline_pill.visible = false
	h.add_child(offline_pill)
	return h


func _update_header() -> void:
	for id in chips:
		chips[id].button_pressed = id == current
	var n: int = ctx.discover.alerts_inbox.size() if ctx.discover != null else 0
	_wish_dot.add_theme_stylebox_override("panel", ThemeLib.box(ThemeLib.color("accent"), 999, 0, 0))
	_wish_dot.visible = n > 0
	offline_pill.visible = ctx.status("cheapshark") == "offline"
	alerts_changed.emit(n)
	_link_chips()


func _link_chips() -> void:
	var list: Array = ORDER.map(func(id): return chips[id])
	Kit.link_horizontal(list)
	var below: Control = sections[current].default_focus()
	for c in list:
		c.focus_neighbor_top = c.get_path_to(top_target if top_target != null else c)
		c.focus_neighbor_bottom = c.get_path_to(below if below != null else c)


## The top-bar tab "up" leads to from the section chips.
func set_top_target(c: Control) -> void:
	top_target = c
	_link_chips()


# ---- sections ------------------------------------------------------------------

func show_section(id: String, focus := true) -> void:
	if not sections.has(id):
		return
	var old: Control = sections[current]
	var dir := signf(ORDER.find(id) - ORDER.find(current))
	if id != current:
		_last_focus[current] = old.focused_key()
		old.visible = false
		current = id
	var s: Control = sections[id]
	s.visible = true
	s.on_shown()
	if dir != 0.0:
		s.modulate.a = 0.0
		s.position.x = Motion.slide(28.0) * dir
		Motion.to(s, "modulate:a", 1.0, Motion.BASE)
		Motion.to(s, "position:x", 0.0, Motion.BASE)
	_update_header()
	if id != "home":
		game_focused.emit({})
	elif not sections["home"].spot_view.is_empty():
		game_focused.emit(sections["home"].spot_view)
	if focus and is_inside_tree():
		var k: String = _last_focus.get(id, "")
		if k != "":
			s.restore_focus(k)
		else:
			s._focus_later(s.default_focus())
	hints_changed.emit()


func cycle_section(d: int) -> void:
	show_section(ORDER[posmod(ORDER.find(current) + d, ORDER.size())])


func default_focus() -> Control:
	if page != null:
		return page.default_focus()
	var f: Control = sections[current].default_focus()
	return f if f != null else chips[current]


# ---- data changes ----------------------------------------------------------------

func _queue(names: Array) -> void:
	for n in names:
		_queued[n] = true
	if not is_inside_tree():
		_flush()
		return
	if not _flush_pending:
		_flush_pending = true
		_flush.call_deferred()


func _flush() -> void:
	_flush_pending = false
	var names := _queued.keys()
	_queued.clear()
	for n in names:
		sections[n].refresh()
	_update_header()
	hints_changed.emit()


func _on_wishlist_changed() -> void:
	_queue(ORDER)
	if page != null and is_instance_valid(page):
		page.wish_button.text = T.WISHLISTED if ctx.is_wishlisted(page.view) else T.WISHLIST_ADD


func _on_status(source: String, _status: String) -> void:
	match source:
		"cheapshark", "ggdeals":
			_queue(["home", "deals"])
		"calendar":
			_queue(["calendar"])
		_:
			_update_header()


func _on_price_alert(item: Dictionary, deal: Dictionary) -> void:
	var t := T.price_toast(item, deal)
	ctx.toast(t[0], "tag", "sale", t[1])
	_update_header()


func _on_release_alert(item: Dictionary) -> void:
	var t := T.release_toast(item)
	ctx.toast(t[0], "rocket", "new", t[1])
	_update_header()


func _on_art(key: String, kind: String, path: String) -> void:
	for id in sections:
		sections[id].on_art(key, kind, path)
	if page != null and is_instance_valid(page) and page.view.get("key", "") == key:
		page.view["art"][kind] = path
		if kind == "hero":
			page._load_hero()
		elif kind == "logo":
			page.header.show_game(page.shown, page._line)
		game_focused.emit(page.view)


# ---- store page ------------------------------------------------------------------

func open_page(view: Dictionary) -> void:
	if view.is_empty():
		return
	if page != null:
		close_page(false)
	_page_return = get_viewport().gui_get_focus_owner() if is_inside_tree() else null
	page = StorePage.new()
	page.setup_store(view, ctx)
	page.back_requested.connect(func(): close_page())
	var host: Control = _overlay if _overlay != null else self
	host.add_child(page)
	page.modulate.a = 0.0
	Motion.to(page, "modulate:a", 1.0, Motion.BASE)
	visible = false
	game_focused.emit(view)
	page_toggled.emit(true)
	page.focus_first()
	hints_changed.emit()


func close_page(restore := true) -> void:
	if page == null:
		return
	var p := page
	page = null
	if p.get_parent() != null:
		p.get_parent().remove_child(p)
	p.queue_free()
	visible = true
	page_toggled.emit(false)
	if not restore:
		return
	modulate.a = 0.0
	Motion.to(self, "modulate:a", 1.0, Motion.FAST)
	var s: Control = sections[current]
	if current == "home" and not s.spot_view.is_empty():
		game_focused.emit(s.spot_view)
	if _page_return != null and is_instance_valid(_page_return) and _page_return.is_inside_tree():
		_page_return.grab_focus()
	else:
		var f := default_focus()
		if f != null and is_inside_tree():
			f.grab_focus()
	hints_changed.emit()


func page_open() -> bool:
	return page != null


# ---- input -------------------------------------------------------------------------

## True when focus is somewhere Discover owns (content or store page).
func owns(f: Control) -> bool:
	if f == null:
		return false
	return is_ancestor_of(f) or (page != null and is_instance_valid(page) and page.is_ancestor_of(f))


func _unhandled_input(event: InputEvent) -> void:
	var f: Control = get_viewport().gui_get_focus_owner()
	if not owns(f):
		return
	if handle_input(event, f):
		get_viewport().set_input_as_handled()


## Discover's buttons; true if the event was used. Split out for tests.
func handle_input(event: InputEvent, f: Control) -> bool:
	if page != null:
		if event.is_action_pressed("ui_cancel"):
			close_page()
			return true
		if _pressed(event, JOY_BUTTON_Y, KEY_W):
			page.toggle_wishlist()
			return true
		# Shoulders and triggers do nothing on a page (like the game page).
		if _pressed(event, JOY_BUTTON_LEFT_SHOULDER, KEY_Q) or _pressed(event, JOY_BUTTON_RIGHT_SHOULDER, KEY_E) or trigger(event) != 0:
			return true
		return false
	var s: Control = sections[current]
	var modal: bool = current == "wishlist" and s.import_open()
	if modal and not event.is_action_pressed("ui_cancel"):
		return false
	if event.is_action_pressed("ui_cancel"):
		if s.back(f):
			hints_changed.emit()
			return true
		if current != "home":
			show_section("home")
			return true
		return false
	var tr := trigger(event)
	if tr != 0:
		cycle_section(tr)
		return true
	if _pressed(event, JOY_BUTTON_X, KEY_S):
		var used: bool = s.on_button("x", f)
		hints_changed.emit()
		return used
	if _pressed(event, JOY_BUTTON_Y, KEY_W):
		var used: bool = s.on_button("y", f)
		hints_changed.emit()
		return used
	return false


static func _pressed(event: InputEvent, button: JoyButton, key: Key) -> bool:
	if event is InputEventJoypadButton:
		return event.pressed and event.button_index == button
	if event is InputEventKey:
		return event.pressed and not event.echo and event.keycode == key
	return false


## -1 for LT (or Page Up), +1 for RT (or Page Down), on the press only.
func trigger(event: InputEvent) -> int:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_PAGEUP:
			return -1
		if event.keycode == KEY_PAGEDOWN:
			return 1
	if event is InputEventJoypadMotion and event.axis in [JOY_AXIS_TRIGGER_LEFT, JOY_AXIS_TRIGGER_RIGHT]:
		var down: bool = event.axis_value > 0.6
		var was: bool = _trigger_held.get(event.axis, false)
		_trigger_held[event.axis] = down if (down or event.axis_value < 0.3) else was
		if down and not was:
			return -1 if event.axis == JOY_AXIS_TRIGGER_LEFT else 1
	return 0


# ---- hints -------------------------------------------------------------------------

## The whole hint bar for the focused control: [[button(s), text], ...].
func hints_for(f: Control) -> Array:
	var out: Array = []
	if page != null:
		out.append_array(page.hints(f))
		out.append(["B", T.HINT_BACK])
		out.append(["GUIDE", "Quick menu"])
		return out
	var s: Control = sections[current]
	if f in chips.values():
		out.append(["A", T.HINT_OPEN])
	else:
		out.append_array(s.hints(f))
	if out.is_empty():
		out.append(["A", T.HINT_SELECT])
	var in_panel: bool = current == "wishlist" and s.import_open()
	if not in_panel:
		out.append([["LT", "RT"], T.HINT_VIEWS])
		out.append(["B", T.HINT_HOME if current == "home" else T.HINT_BACK])
		out.append([["LB", "RB"], "Sections"])
	out.append(["GUIDE", "Quick menu"])
	return out
