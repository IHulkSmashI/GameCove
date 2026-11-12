extends "res://scripts/ui/discover/section.gd"
## Deals browser: store filter and sort at the top, then one row per deal
## (cover, title, store and sale end, badges, price). A price only shows when
## it's the store's real price in the user's currency; otherwise the row shows
## the discount and "See price". X cycles the sort, Y wishlists, A opens the
## store page. Credits for whoever's data is shown sit at the end.

const ChoiceRow := preload("res://scripts/ui/choice_row.gd")

var store_row: VBoxContainer
var sort_row: VBoxContainer
var rows: Array = []            # deal row Buttons, in order
var credits_buttons: Array = []
var count_label: Label
var tip: Control
var _scroll: ScrollContainer
var _list: VBoxContainer
var _deals: Array = []


func setup(c: RefCounted) -> void:
	super.setup(c)
	name = "Deals"


func current_store() -> String:
	return str(ctx.prefs.get_value("deals_store"))


func current_sort() -> String:
	return str(ctx.prefs.get_value("deals_sort"))


func build() -> void:
	rows.clear()
	credits_buttons.clear()
	_deals = Model.visible_deals(ctx.discover.deals, ctx.keyshops())
	var col := Kit.vbox(14)
	col.name = "DealsRoot"
	col.set_anchors_preset(Control.PRESET_FULL_RECT)
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(col)

	var bar := Kit.hbox(14)
	bar.name = "Toolbar"
	var stores := Model.stores_of(_deals)
	var store := current_store()
	if not stores.any(func(s): return s[0] == store):
		store = ""
	store_row = ChoiceRow.new()
	store_row.setup("deals_store", T.STORE_LABEL, stores.map(func(s): return s[0]), stores.map(func(s): return s[1]), store, "store")
	store_row.collapse_hint = true
	store_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	store_row.changed.connect(func(v): _set_pref("deals_store", v))
	bar.add_child(store_row)
	var sorts := Model.sorts_for(_deals)
	var sort := current_sort()
	if not sort in sorts:
		sort = "best"
	sort_row = ChoiceRow.new()
	sort_row.setup("deals_sort", T.SORT_LABEL, sorts, sorts.map(func(s): return T.SORT_LABELS[s]), sort, "sort")
	sort_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sort_row.changed.connect(func(v): _set_pref("deals_sort", v))
	bar.add_child(sort_row)
	store_row.button.set_meta("role", "store_filter")
	sort_row.button.set_meta("role", "sort")
	col.add_child(bar)

	var shown := Model.sort_deals(Model.filter_store(_deals, store), sort)
	var info := Kit.hbox(12)
	info.name = "Info"
	count_label = Kit.label("%d deals" % shown.size() if shown.size() != 1 else "1 deal", "CaptionLabel")
	count_label.name = "Count"
	count_label.add_theme_font_override("font", ThemeLib.font("medium", true))
	info.add_child(count_label)
	if ctx.status("cheapshark") == "offline" and not _deals.is_empty():
		info.add_child(W.badge("offline", T.OFFLINE_PILL, "warn", "cloud_off"))
	if not ctx.has_gg_key() and shown.any(func(x): return x.get("see_price", false)):
		var why := Kit.label("\"%s\": %s" % [T.SEE_PRICE, T.SEE_PRICE_WHY], "CaptionLabel")
		why.add_theme_color_override("font_color", ThemeLib.color("text_3"))
		info.add_child(why)
	col.add_child(info)

	_scroll = W.scroller()
	_scroll.follow_focus = false
	_scroll.set_meta("ux_follows", "each row follows with widgets.follow")   # docs/CONTROLLER-UX.md CUX-8
	col.add_child(_scroll)
	_list = Kit.vbox(10)
	_list.name = "List"
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var pad := Kit.margin(0, 4, 6)
	pad.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	pad.add_child(_list)
	_scroll.add_child(pad)

	if _deals.is_empty():
		var cs: String = ctx.status("cheapshark")
		var card: Control
		if cs == "offline":
			card = W.info_card("discover", T.OFFLINE_TITLE, T.OFFLINE, [[T.RETRY, func(): ctx.discover.refresh(true), "update"]])
		else:
			card = W.info_card("discover", T.LOADING_TITLE, T.RATE_LIMITED if cs == "rate_limited" else T.LOADING, [[T.RETRY, func(): ctx.discover.refresh(true), "update"]])
		card.name = "EmptyCard"
		_list.add_child(card)
		rows.append_array(card.get_meta("buttons"))
	elif shown.is_empty():
		var l := Kit.label(T.NO_DEALS_STORE, "QuietLabel")
		_list.add_child(l)

	var now: int = ctx.now()
	var cur: String = ctx.currency()
	for d in shown:
		var v := Model.deal_view(d)
		ctx.art.fill(v, ["cover"])
		var b := _row(v, d, now, cur)
		_list.add_child(b)
		rows.append(b)
		follow(_scroll, b)

	if not _deals.is_empty():
		var cr := W.credits(ctx.discover.attributions(), func(l): ctx.open_link(l))
		var cpad := Kit.margin(0, 0, 8)
		cpad.add_child(cr)
		_list.add_child(cpad)
		credits_buttons = cr.get_meta("buttons")
		for cb in credits_buttons:
			follow(_scroll, cb)
	_link()


func _row(v: Dictionary, d: Dictionary, now: int, cur: String) -> Button:
	var store := str(d.get("store_name", ""))
	var sub := store
	var e := T.ends(d.get("sale_ends_at"), now)
	if e != "":
		sub += "  ·  " + e
	if d.get("rating") != null and current_sort() == "rating":
		sub += "  ·  Deal rating %.1f" % float(d["rating"])
	var badges: Array = []
	if d.get("is_historical_low", false):
		badges.append({"kind": "low", "text": T.HIST_LOW_LONG, "tone": "good", "icon": "sparkle"})
	var hl := T.hist_low(d, cur)
	if hl != "" and not d.get("is_historical_low", false):
		badges.append({"kind": "hl", "text": hl, "tone": "", "icon": "clock"})
	if d.get("keyshop", false):
		badges.append({"kind": "keyshop", "text": T.KEYSHOP, "tone": "warn", "icon": "alert"})
	if ctx.is_wishlisted(v):
		badges.append({"kind": "wish", "text": T.WISHLISTED, "tone": "wish", "icon": "star"})
	if not ctx.owned(v).is_empty():
		badges.append({"kind": "owned", "text": T.OWNED, "tone": "info", "icon": "library"})
	var link: Dictionary = d.get("link", {}) if d.get("link") is Dictionary else {}
	if link.get("affiliate", false):
		badges.append({"kind": "affiliate", "text": str(link.get("note", T.SUPPORTS)) if str(link.get("note", "")) != "" else T.SUPPORTS, "tone": "accent", "icon": "sparkle"})
	var right := W.price_column(d)
	if T.price(d) == "":
		var see := Kit.label("on " + store, "CaptionLabel")
		see.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		right.add_child(see)
	right.custom_minimum_size = Vector2(170, 0)
	var b := W.row(v, {"title": v["title"], "sub": sub, "badges": badges, "right": right}, 96)
	b.set_meta("role", "deal")
	b.pressed.connect(func(): ctx.open_page(v))
	b.focus_entered.connect(func(): ctx.focus(v))
	return b


func _set_pref(k: String, v: Variant) -> void:
	ctx.prefs.set_value(k, v)
	refresh()
	_refocus_row(k)


func _refocus_row(k: String) -> void:
	var r: VBoxContainer = store_row if k == "deals_store" else sort_row
	if r != null and is_inside_tree():
		_focus_later(r.button)


## X: next sort (keeps focus where it is).
func cycle_sort() -> void:
	var sorts := Model.sorts_for(_deals)
	var i := sorts.find(current_sort())
	var next: String = sorts[posmod(i + 1, sorts.size())]
	ctx.prefs.set_value("deals_sort", next)
	var keep := focused_key()
	refresh()
	if keep == "":
		_focus_later(sort_row.button)
	ctx.toast("Sorted by %s" % T.SORT_LABELS[next].to_lower(), "sort", "")


func _link() -> void:
	var top_row: Array = [store_row.button, sort_row.button]
	Kit.link_horizontal(top_row)
	var below: Control = rows[0] if not rows.is_empty() else (credits_buttons[0] if not credits_buttons.is_empty() else null)
	for b in top_row:
		b.focus_neighbor_top = b.get_path_to(top_target if top_target != null else b)
		b.focus_neighbor_bottom = b.get_path_to(below if below != null else b)
	var chain: Array = rows.duplicate()
	if not credits_buttons.is_empty():
		chain.append(credits_buttons[0])
	W.chain(chain, store_row.button)
	for r in rows:
		r.focus_neighbor_left = r.get_path_to(r)
		r.focus_neighbor_right = r.get_path_to(r)
	if not credits_buttons.is_empty():
		var up: Control = rows[-1] if not rows.is_empty() else store_row.button
		for cb in credits_buttons:
			cb.focus_neighbor_top = cb.get_path_to(up)
			cb.focus_neighbor_bottom = cb.get_path_to(cb)


func set_top_target(c: Control) -> void:
	super.set_top_target(c)
	if store_row != null and is_instance_valid(store_row):
		for b in [store_row.button, sort_row.button]:
			b.focus_neighbor_top = b.get_path_to(c)


func default_focus() -> Control:
	if not rows.is_empty():
		return rows[0]
	return store_row.button if store_row != null else null


func hints(f: Control) -> Array:
	if store_row != null and (f == store_row.button or f == sort_row.button):
		return [["LR", T.HINT_CHANGE], ["X", T.HINT_SORT]]
	if f.has_meta("link"):
		return [["A", T.HINT_LINK], ["X", T.HINT_SORT]]
	var v := view_of(f)
	if v.is_empty():
		return [["A", T.HINT_SELECT]]
	return [["A", T.HINT_OPEN], ["Y", T.HINT_UNWISH if ctx.is_wishlisted(v) else T.HINT_WISH], ["X", T.HINT_SORT]]


func on_button(b: String, f: Control) -> bool:
	if b == "x":
		cycle_sort()
		return true
	if b == "y":
		var v := view_of(f)
		if v.is_empty():
			return false
		ctx.toggle_wishlist(v)
		return true
	return false


func on_art(key: String, kind: String, _path: String) -> void:
	if kind != "cover":
		return
	for r in rows:
		if r.has_meta("view") and r.get_meta("view").get("key", "") == key:
			r.get_meta("view")["art"]["cover"] = _path
			var th: Node = r.find_child("Thumb", true, false)
			if th != null:
				th.refresh()
