extends "res://scripts/ui/discover/section.gd"
## Wishlist: import from Steam, the alerts inbox (price drops, out now) with
## "Mark all seen", then the list (best price now, lowest ever, countdown for
## games not out yet) beside a details card for the focused game: price
## alert target, alert switches, Game page and Remove.

const ChoiceRow := preload("res://scripts/ui/choice_row.gd")
const Osk := preload("res://scripts/ui/osk.gd")

var import_button: Button
var rows: Array = []
var alert_buttons: Array = []
var seen_button: Button
var detail_focus: Array = []    # controls in the details card, top to bottom
var empty_card: Control
var detail_key := ""
var import_panel: Control
var import_field: Label
var import_status: Label
var import_type: Button
var import_go: Button
var import_cancel: Button
var keyboard: PanelContainer
var importing := false
var views: Array = []
var _detail: VBoxContainer
var _scroll: ScrollContainer
var _remove_armed := ""
var _typed := ""
var _return_focus: Control


func setup(c: RefCounted) -> void:
	super.setup(c)
	name = "Wishlist"


## Keeps the import sheet open (and busy) across rebuilds.
func refresh() -> void:
	var was_open := import_open()
	super.refresh()
	if was_open:
		import_panel.visible = true
		if importing:
			import_go.disabled = true
			import_go.text = T.IMPORT_BUSY


func build() -> void:
	rows.clear()
	alert_buttons.clear()
	detail_focus.clear()
	views.clear()
	seen_button = null
	empty_card = null
	_detail = null
	var items: Array = ctx.discover.wishlist
	var col := Kit.vbox(14)
	col.name = "WishRoot"
	col.set_anchors_preset(Control.PRESET_FULL_RECT)
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(col)

	var bar := Kit.hbox(12)
	bar.name = "Toolbar"
	var has_steam: bool = items.any(func(i): return i.get("source", "") == "steam")
	import_button = Kit.button(T.IMPORT_AGAIN if has_steam else T.IMPORT, "ChipButton")
	import_button.name = "Import"
	import_button.icon = Icons.tex("download", 18)
	import_button.add_theme_constant_override("h_separation", 8)
	import_button.custom_minimum_size = Vector2(0, 44)
	import_button.set_meta("role", "import")
	import_button.pressed.connect(open_import)
	bar.add_child(import_button)
	var count := Kit.label(T.wishlist_count(items.size()) if not items.is_empty() else "", "CaptionLabel")
	count.name = "Count"
	count.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	count.size_flags_vertical = Control.SIZE_FILL
	count.add_theme_font_override("font", ThemeLib.font("medium", true))
	bar.add_child(count)
	bar.add_child(Kit.spacer())
	if not ctx.settings().get("alerts", true):
		var off := W.badge("alerts_off", "Alerts are off in Settings", "warn", "alert")
		off.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		bar.add_child(off)
	col.add_child(bar)

	var inbox: Array = ctx.discover.alerts_inbox
	if not inbox.is_empty():
		col.add_child(_alerts_card(inbox))

	if items.is_empty():
		empty_card = W.info_card("discover", T.WISH_EMPTY_TITLE, T.WISH_EMPTY + " " + T.IMPORT_PUBLIC, [[T.IMPORT, open_import, "download"]])
		empty_card.name = "EmptyCard"
		col.add_child(empty_card)
	else:
		var body := Kit.hbox(20)
		body.name = "Body"
		body.size_flags_vertical = Control.SIZE_EXPAND_FILL
		col.add_child(body)
		_scroll = W.scroller()
		_scroll.follow_focus = false
		_scroll.set_meta("ux_follows", "each row follows with widgets.follow")   # docs/CONTROLLER-UX.md CUX-8
		_scroll.size_flags_stretch_ratio = 1.6
		body.add_child(_scroll)
		var list := Kit.vbox(10)
		list.name = "List"
		list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var pad := Kit.margin(0, 4, 6)
		pad.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		pad.add_child(list)
		_scroll.add_child(pad)
		var now: int = ctx.now()
		var cur: String = ctx.currency()
		for it in items:
			var v := Model.wish_view(it)
			ctx.art.fill(v, ["cover"])
			views.append(v)
			var b := _row(v, it, now, cur)
			list.add_child(b)
			rows.append(b)
			follow(_scroll, b)
		var card := PanelContainer.new()
		card.name = "Details"
		card.theme_type_variation = "CardPanel"
		card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		card.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
		body.add_child(card)
		_detail = Kit.vbox(12)
		_detail.name = "Detail"
		card.add_child(_detail)
		var key := detail_key
		if key == "" or not items.any(func(i): return i["key"] == key):
			key = str(items[0]["key"])
		show_detail(key)
	_build_import()
	_link()


func _alerts_card(inbox: Array) -> Control:
	var card := PanelContainer.new()
	card.name = "Alerts"
	card.theme_type_variation = "CardPanel"
	var c := Kit.vbox(10)
	card.add_child(c)
	var head := Kit.hbox(12)
	head.add_child(Kit.icon_label("sparkle", T.ALERTS_TITLE, "LeadLabel", ThemeLib.color("accent"), 22, false))
	var n := Kit.label(str(inbox.size()), "CaptionLabel")
	n.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	n.size_flags_vertical = Control.SIZE_FILL
	head.add_child(n)
	head.add_child(Kit.spacer())
	seen_button = Kit.button(T.MARK_SEEN, "ChipButton")
	seen_button.name = "MarkSeen"
	seen_button.icon = Icons.tex("check", 18)
	seen_button.add_theme_constant_override("h_separation", 8)
	seen_button.custom_minimum_size = Vector2(0, 40)
	seen_button.set_meta("role", "mark_seen")
	seen_button.pressed.connect(func(): ctx.discover.mark_seen(""))
	head.add_child(seen_button)
	c.add_child(head)
	var row := Kit.hbox(10)
	var now: int = ctx.now()
	for a in inbox.slice(0, 3):
		var b := Kit.button("", "RowButton")
		b.name = "Alert_" + str(a.get("id", "")).validate_node_name()
		b.custom_minimum_size = Vector2(0, 58)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.set_meta("role", "alert_" + str(a.get("id", "")))
		b.set_meta("alert", a)
		var h := Kit.hbox(10)
		h.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		h.offset_left = 14
		h.offset_right = -12
		h.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var release: bool = a.get("kind", "") == "release"
		h.add_child(Icons.rect("calendar" if release else "tag", 20, ThemeLib.tone("new" if release else "sale")))
		var tc := Kit.vbox(0)
		tc.alignment = BoxContainer.ALIGNMENT_CENTER
		tc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		tc.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var l := Kit.label(T.alert_line(a))
		l.add_theme_font_override("font", ThemeLib.font("medium"))
		l.add_theme_font_size_override("font_size", ThemeLib.SIZE_SMALL)
		l.clip_text = true
		l.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		tc.add_child(l)
		tc.add_child(Kit.label(T.ago(int(a.get("at", now)), now), "CaptionLabel"))
		h.add_child(tc)
		b.add_child(h)
		var alert: Dictionary = a
		b.pressed.connect(func(): _open_alert(alert))
		row.add_child(b)
		alert_buttons.append(b)
	c.add_child(row)
	return card


func _open_alert(a: Dictionary) -> void:
	var it: Dictionary = ctx.discover.get_item(str(a.get("key", "")))
	ctx.discover.mark_seen(str(a.get("id", "")))
	if not it.is_empty():
		var full: Array = ctx.discover.wishlist.filter(func(i): return i["key"] == it["key"])
		var v := Model.wish_view(full[0] if not full.is_empty() else it)
		ctx.art.fill(v, ["cover"])
		ctx.open_page(v)


func _row(v: Dictionary, it: Dictionary, now: int, cur: String) -> Button:
	var bd: Dictionary = it.get("best_deal", {}) if it.get("best_deal") is Dictionary else {}
	var rel: Dictionary = it.get("release", {}) if it.get("release") is Dictionary else {}
	var sub := ""
	var unreleased: bool = not rel.is_empty() and not rel.get("released", false)
	if not bd.is_empty():
		sub = "Best price on " + str(bd.get("store_name", ""))
		var e := T.ends(it.get("sale_ends_at"), now)
		if e != "":
			sub += "  ·  " + e
	elif unreleased:
		sub = "Out " + T.release_when(rel, now)
	else:
		sub = T.NO_PRICE_YET
	var badges: Array = []
	if it.get("is_historical_low", false):
		badges.append({"kind": "low", "text": T.HIST_LOW_LONG, "tone": "good", "icon": "sparkle"})
	else:
		var hl := T.hist_low(it, cur)
		if hl != "":
			badges.append({"kind": "hl", "text": hl, "tone": "", "icon": "clock"})
	if it.get("target_price") != null:
		var hit: bool = bd.get("price") is Dictionary and float(bd["price"].get("amount", INF)) <= float(it["target_price"])
		badges.append({"kind": "target", "text": ("Target hit: " if hit else "Target: ") + T.money(float(it["target_price"]), cur), "tone": "good" if hit else "info", "icon": "tag"})
	if unreleased:
		var cd := T.countdown(rel, now)
		if cd != "":
			badges.append({"kind": "countdown", "text": cd, "tone": T.countdown_tone(rel), "icon": "calendar"})
	if not ctx.owned(v).is_empty():
		badges.append({"kind": "owned", "text": T.OWNED, "tone": "info", "icon": "library"})
	var right: Control
	if not bd.is_empty():
		right = W.price_column(bd)
		right.custom_minimum_size = Vector2(160, 0)
	else:
		var l := Kit.label("—" if not unreleased else T.release_when(rel, now), "LeadLabel")
		l.add_theme_color_override("font_color", ThemeLib.color("text_3"))
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		l.custom_minimum_size = Vector2(120, 0)
		right = l
	var b := W.row(v, {"title": v["title"], "sub": sub, "badges": badges, "right": right}, 92)
	b.set_meta("role", "wish")
	b.set_meta("ux_tab", true)   # the detail beside follows the focused row: a master list (CUX-3)
	b.pressed.connect(func(): ctx.open_page(v))
	b.focus_entered.connect(func():
		ctx.focus(v)
		if detail_key != v["key"]:
			show_detail(v["key"]))
	return b


func item_for(key: String) -> Dictionary:
	for it in ctx.discover.wishlist:
		if it["key"] == key:
			return it
	return {}


func view_for(key: String) -> Dictionary:
	for v in views:
		if v["key"] == key or v["data"].get("key", "") == key:
			return v
	return {}


## The details card for one item.
func show_detail(key: String) -> void:
	if _detail == null:
		return
	detail_key = key
	_remove_armed = ""
	for c in _detail.get_children():
		W.detach(_detail, c)
	detail_focus.clear()
	var it := item_for(key)
	if it.is_empty():
		return
	var v := view_for(key)
	var cur: String = ctx.currency()
	var now: int = ctx.now()
	var title := Kit.label(v.get("title", it.get("title", "")), "HeaderLabel", true)
	title.name = "DetailTitle"
	title.max_lines_visible = 2
	_detail.add_child(title)
	var bd: Dictionary = it.get("best_deal", {}) if it.get("best_deal") is Dictionary else {}
	if not bd.is_empty():
		var pr := Kit.hbox(14)
		pr.add_child(W.price_column(bd, false, false))
		var side := Kit.vbox(2)
		side.alignment = BoxContainer.ALIGNMENT_CENTER
		side.add_child(Kit.label("on " + str(bd.get("store_name", "")), "QuietLabel"))
		var e := T.ends(it.get("sale_ends_at"), now)
		if e != "":
			side.add_child(Kit.label(e, "CaptionLabel"))
		pr.add_child(side)
		_detail.add_child(pr)
	var hl := T.hist_low(it, cur)
	if hl != "":
		_detail.add_child(Kit.icon_label("clock", hl, "QuietLabel", Color(0, 0, 0, 0), 18))
	var rel: Dictionary = it.get("release", {}) if it.get("release") is Dictionary else {}
	var unreleased: bool = not rel.is_empty() and not rel.get("released", false)
	if unreleased:
		_detail.add_child(Kit.icon_label("calendar", "Out %s (%s)" % [T.release_when(rel, now), T.countdown(rel, now)], "QuietLabel", Color(0, 0, 0, 0), 18))

	var choices := Model.target_choices(it, cur)
	var tr := ChoiceRow.new()
	tr.explainer = func(val): return T.TARGET_ANY_LINE if val == null else T.TARGET_LINE
	tr.setup("wish_target", T.TARGET, choices, choices.map(func(x): return T.target_label(x, cur)), it.get("target_price"), "tag")
	tr.collapse_hint = false
	tr.button.set_meta("view", v)
	tr.button.set_meta("role", "target")
	tr.changed.connect(func(val): ctx.discover.set_target_price(key, val))
	_detail.add_child(tr)
	detail_focus.append(tr.button)
	var pa: VBoxContainer = ChoiceRow.bool_row("wish_alerts", T.ALERTS_TOGGLE, bool(it.get("notify_price", true)), "sparkle")
	pa.button.set_meta("view", v)
	pa.button.set_meta("role", "notify_price")
	pa.changed.connect(func(val): ctx.discover.set_notify(key, val, null))
	_detail.add_child(pa)
	detail_focus.append(pa.button)
	if unreleased:
		var ra: VBoxContainer = ChoiceRow.bool_row("wish_release", T.RELEASE_TOGGLE, bool(it.get("notify_release", false)), "calendar")
		ra.button.set_meta("view", v)
		ra.button.set_meta("role", "notify_release")
		ra.changed.connect(func(val): ctx.discover.set_notify(key, null, val))
		_detail.add_child(ra)
		detail_focus.append(ra.button)
	var br := Kit.hbox(12)
	var page := Kit.button(T.VIEW_GAME, "AccentButton")
	page.name = "DetailPage"
	page.custom_minimum_size = Vector2(170, 50)
	page.add_theme_font_size_override("font_size", ThemeLib.SIZE_BODY)
	page.set_meta("view", v)
	page.set_meta("role", "page")
	page.pressed.connect(func(): ctx.open_page(v))
	var rm := Kit.button(T.REMOVE)
	rm.name = "DetailRemove"
	rm.custom_minimum_size = Vector2(150, 50)
	rm.icon = Icons.tex("x", 18)
	rm.add_theme_constant_override("h_separation", 8)
	rm.set_meta("view", v)
	rm.set_meta("role", "remove")
	rm.pressed.connect(func(): _remove(rm, key))
	rm.focus_exited.connect(func():
		if is_instance_valid(rm):
			rm.text = T.REMOVE
			_remove_armed = "")
	br.add_child(page)
	br.add_child(rm)
	_detail.add_child(br)
	detail_focus.append(page)
	_link_detail(rm)


func _remove(b: Button, key: String) -> void:
	if _remove_armed != key:
		_remove_armed = key
		b.text = T.REMOVE_CONFIRM
		ctx.hints_changed()
		return
	_remove_armed = ""
	var i := -1
	for j in rows.size():
		if rows[j].get_meta("view")["key"] == key:
			i = j
	detail_key = ""
	ctx.discover.remove_from_wishlist(key)
	ctx.toast(T.TOAST_REMOVED, "star", "")
	# Land on the next game in the list.
	var next: Control = null
	if i >= 0 and rows.size() > 1:
		var nk: String = rows[mini(i + 1, rows.size() - 1) if i + 1 < rows.size() else i - 1].get_meta("view")["key"]
		for r in rows:
			if is_instance_valid(r) and r.get_meta("view")["key"] == nk:
				next = r
	if next != null:
		_focus_later_key(next.get_meta("view")["key"] + "|wish")
	else:
		_focus_later(default_focus())


func _focus_later_key(k: String) -> void:
	# A deferred method, not a lambda: dropped safely if the view is freed first.
	call_deferred("_focus_key_now", k)


func _focus_key_now(k: String) -> void:
	if not is_inside_tree():
		return
	for b in W.buttons_in(self):
		if key_of(b) == k:
			b.grab_focus()
			return
	var d := default_focus()
	if d != null:
		d.grab_focus()


func _row_for(key: String) -> Control:
	for r in rows:
		if r.get_meta("view")["key"] == key:
			return r
	return rows[0] if not rows.is_empty() else null


func _link_detail(remove_button: Button) -> void:
	var back := _row_for(detail_key)
	var chain := detail_focus.duplicate()
	for i in chain.size():
		var c: Control = chain[i]
		c.focus_neighbor_top = c.get_path_to(chain[i - 1] if i > 0 else c)
		c.focus_neighbor_bottom = c.get_path_to(chain[i + 1] if i + 1 < chain.size() else c)
		c.focus_neighbor_left = c.get_path_to(back if back != null else c)
		c.focus_neighbor_right = c.get_path_to(c)
	var page: Control = chain[-1]
	page.focus_neighbor_right = page.get_path_to(remove_button)
	remove_button.focus_neighbor_left = remove_button.get_path_to(page)
	remove_button.focus_neighbor_right = remove_button.get_path_to(remove_button)
	remove_button.focus_neighbor_top = remove_button.get_path_to(chain[-2] if chain.size() > 1 else remove_button)
	remove_button.focus_neighbor_bottom = remove_button.get_path_to(remove_button)
	for r in rows:
		r.focus_neighbor_right = r.get_path_to(chain[0])


func _link() -> void:
	var top: Array = [import_button]
	if seen_button != null:
		top.append(seen_button)
	Kit.link_horizontal(top)
	var after_bar: Control
	if not alert_buttons.is_empty():
		after_bar = alert_buttons[0]
	elif not rows.is_empty():
		after_bar = rows[0]
	elif empty_card != null:
		after_bar = empty_card.get_meta("buttons")[0]
	for b in top:
		b.focus_neighbor_top = b.get_path_to(top_target if top_target != null else b)
		b.focus_neighbor_bottom = b.get_path_to(after_bar if after_bar != null else b)
	if not alert_buttons.is_empty():
		Kit.link_horizontal(alert_buttons)
		var below: Control = rows[0] if not rows.is_empty() else (empty_card.get_meta("buttons")[0] if empty_card != null else null)
		# "Mark all seen" heads the alerts card: up from an alert reaches it, then the toolbar
		var head: Control = seen_button if seen_button != null and is_instance_valid(seen_button) and seen_button.visible else import_button
		for a in alert_buttons:
			a.focus_neighbor_top = a.get_path_to(head)
			a.focus_neighbor_bottom = a.get_path_to(below if below != null else a)
		if head == seen_button:
			seen_button.focus_neighbor_top = seen_button.get_path_to(import_button)
			seen_button.focus_neighbor_bottom = seen_button.get_path_to(alert_buttons[-1])
			seen_button.focus_neighbor_left = seen_button.get_path_to(seen_button)
			seen_button.focus_neighbor_right = seen_button.get_path_to(seen_button)
	var above_rows: Control = alert_buttons[0] if not alert_buttons.is_empty() else import_button
	W.chain(rows, above_rows)
	for r in rows:
		r.focus_neighbor_left = r.get_path_to(r)
	if empty_card != null:
		for b in empty_card.get_meta("buttons"):
			b.focus_neighbor_top = b.get_path_to(above_rows)
			b.focus_neighbor_bottom = b.get_path_to(b)
	if not detail_focus.is_empty():
		# Up from the first detail row goes to the toolbar.
		detail_focus[0].focus_neighbor_top = detail_focus[0].get_path_to(above_rows)
		for r in rows:
			r.focus_neighbor_right = r.get_path_to(detail_focus[0])


func set_top_target(c: Control) -> void:
	super.set_top_target(c)
	if import_button != null and is_instance_valid(import_button):
		import_button.focus_neighbor_top = import_button.get_path_to(c)
		if seen_button != null:
			seen_button.focus_neighbor_top = seen_button.get_path_to(c)


func default_focus() -> Control:
	if import_open():
		return import_go if not importing else import_cancel
	if not rows.is_empty():
		return rows[0]
	if empty_card != null:
		return empty_card.get_meta("buttons")[0]
	return import_button


# ---- import ------------------------------------------------------------------

func _build_import() -> void:
	import_panel = Control.new()
	import_panel.name = "ImportLayer"
	import_panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	import_panel.visible = false
	import_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(import_panel)
	var dim := ColorRect.new()
	dim.color = Color(ThemeLib.color("scrim"), 0.55)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.offset_top = -160
	dim.offset_left = -48
	dim.offset_right = 48
	dim.offset_bottom = 60
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	import_panel.add_child(dim)
	var card := PanelContainer.new()
	card.name = "ImportCard"
	card.theme_type_variation = "GlassPanel"
	card.anchor_left = 0.5
	card.anchor_right = 0.5
	card.offset_left = -380
	card.offset_right = 380
	card.offset_top = 0
	import_panel.add_child(card)
	var c := Kit.vbox(12)
	card.add_child(c)
	c.add_child(Kit.icon_label("download", T.IMPORT_TITLE, "HeaderLabel", ThemeLib.color("accent"), 26, false))
	c.add_child(Kit.label(T.IMPORT_WHY, "QuietLabel", true))
	var pub := Kit.icon_label("info", T.IMPORT_PUBLIC, "QuietLabel", ThemeLib.color("warn"), 20)
	c.add_child(pub)
	var fieldbox := PanelContainer.new()
	fieldbox.add_theme_stylebox_override("panel", ThemeLib.box(ThemeLib.soft(0.08), ThemeLib.radius("m"), 16, 12))
	import_field = Kit.label("", "LeadLabel")
	import_field.name = "Field"
	fieldbox.add_child(import_field)
	c.add_child(fieldbox)
	import_status = Kit.label("", "QuietLabel", true)
	import_status.name = "ImportStatus"
	import_status.visible = false
	c.add_child(import_status)
	var br := Kit.hbox(12)
	import_type = Kit.button(T.IMPORT_TYPE)
	import_type.name = "TypeIt"
	import_type.icon = Icons.tex("search", 18)
	import_type.add_theme_constant_override("h_separation", 8)
	import_type.custom_minimum_size = Vector2(150, 52)
	import_type.pressed.connect(_open_keyboard)
	import_go = Kit.button(T.IMPORT_GO, "AccentButton")
	import_go.name = "ImportGo"
	import_go.custom_minimum_size = Vector2(170, 52)
	import_go.pressed.connect(_start_import)
	import_cancel = Kit.button(T.CANCEL)
	import_cancel.name = "ImportCancel"
	import_cancel.custom_minimum_size = Vector2(130, 52)
	import_cancel.pressed.connect(close_import)
	br.add_child(import_go)
	br.add_child(import_type)
	br.add_child(import_cancel)
	c.add_child(br)
	Kit.link_horizontal([import_go, import_type, import_cancel])
	for b in [import_go, import_type, import_cancel]:
		b.focus_neighbor_top = b.get_path_to(b)
		b.focus_neighbor_bottom = b.get_path_to(b)
		b.set_meta("role", "import_" + str(b.name))
	keyboard = Osk.new()
	keyboard.placeholder = T.IMPORT_FIELD_EMPTY
	keyboard.anchor_left = 0.5
	keyboard.anchor_right = 0.5
	keyboard.anchor_top = 1.0
	keyboard.anchor_bottom = 1.0
	keyboard.offset_left = -400
	keyboard.offset_right = 400
	keyboard.offset_top = -372
	keyboard.offset_bottom = 30
	# Steam custom names use underscores; there's no ':' in them.
	_swap_key(":", "_")
	keyboard.text_changed.connect(func(t): _set_typed(t))
	keyboard.closed.connect(func(_t): _focus_later(import_go))
	import_panel.add_child(keyboard)
	_set_typed(str(ctx.settings().get("steam_id", "")) if _typed == "" else _typed)


func _swap_key(from: String, to: String) -> void:
	for row in keyboard.keys:
		for b in row:
			if b.text == from:
				for conn in b.pressed.get_connections():
					b.pressed.disconnect(conn["callable"])
				b.text = to
				b.pressed.connect(keyboard.type.bind(to))


func _set_typed(t: String) -> void:
	_typed = t.strip_edges()
	if import_field == null:
		return
	import_field.text = _typed if _typed != "" else T.IMPORT_FIELD_EMPTY
	import_field.add_theme_color_override("font_color", ThemeLib.color("text") if _typed != "" else ThemeLib.color("text_3"))
	import_go.disabled = _typed == "" or importing


func import_open() -> bool:
	return import_panel != null and is_instance_valid(import_panel) and import_panel.visible


func open_import() -> void:
	_return_focus = _focus_owner()
	import_panel.visible = true
	import_status.visible = false
	_set_typed(_typed if _typed != "" else str(ctx.settings().get("steam_id", "")))
	_focus_later(import_type if _typed == "" else import_go)
	ctx.hints_changed()


func close_import() -> void:
	if keyboard.is_open():
		keyboard.close()
	import_panel.visible = false
	var back: Control = _return_focus if _return_focus != null and is_instance_valid(_return_focus) and is_ancestor_of(_return_focus) else import_button
	_focus_later(back)
	ctx.hints_changed()


func _open_keyboard() -> void:
	keyboard.open(_typed)


func _start_import() -> void:
	if _typed == "" or importing:
		return
	importing = true
	import_go.disabled = true
	import_go.text = T.IMPORT_BUSY
	import_status.visible = false
	_focus_later(import_cancel)
	ctx.discover.import_steam_wishlist(_typed)


## Discover answered import_steam_wishlist().
func on_import_done(ok: bool, added: int, error: String) -> void:
	importing = false
	if import_go == null or not is_instance_valid(import_go):
		return
	import_go.text = T.IMPORT_GO
	import_go.disabled = _typed == ""
	if ok and error == "":
		ctx.toast(T.TOAST_IMPORTED % added if added > 0 else T.TOAST_IMPORTED_NONE, "download", "good")
		import_panel.visible = false
		_focus_later(default_focus())
		ctx.hints_changed()
		return
	import_status.text = error if error != "" else "That didn't work. Check the name and try again."
	import_status.add_theme_color_override("font_color", ThemeLib.color("warn"))
	import_status.visible = true
	if is_inside_tree():
		_focus_later(import_type)


func back(_f: Control) -> bool:
	if import_open():
		close_import()
		return true
	if _detail != null and is_instance_valid(_detail) and _detail.get_parent().is_ancestor_of(_f):
		var r := _row_for(detail_key)
		if r != null:
			r.grab_focus()
			return true
	return false


func hints(f: Control) -> Array:
	if import_open():
		return [["A", T.HINT_SELECT], ["B", T.CANCEL]]
	if f in alert_buttons:
		return [["A", T.HINT_OPEN]]
	var role := str(f.get_meta("role", ""))
	if role in ["target", "notify_price", "notify_release"]:
		return [["LR", T.HINT_CHANGE], ["Y", T.HINT_UNWISH]]
	if role == "remove":
		return [["A", T.REMOVE if _remove_armed == "" else T.REMOVE_CONFIRM]]
	var v := view_of(f)
	if v.is_empty():
		return [["A", T.HINT_SELECT]]
	return [["A", T.HINT_OPEN], ["Y", T.HINT_UNWISH]]


func on_button(b: String, f: Control) -> bool:
	if import_open():
		return false
	if b == "y":
		var v := view_of(f)
		if v.is_empty():
			return false
		var key: String = v["data"].get("key", v["key"])
		ctx.discover.remove_from_wishlist(key)
		ctx.toast(T.TOAST_REMOVED, "star", "", str(v.get("title", "")))
		return true
	return false


func on_art(key: String, kind: String, path: String) -> void:
	if kind != "cover":
		return
	W.ArtLinkScript.apply(views, key, kind, path)
	for c in find_children("Thumb", "", true, false):
		if c.view.get("key", "") == key:
			c.view["art"]["cover"] = path
			c.refresh()
