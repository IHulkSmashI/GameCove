extends "res://scripts/ui/page_template.gd"
## A store page for a game you don't own (or do: then "Open in library"
## leads), on the shared page template: hero art, logo or title, badges, an
## action row (Buy / Wishlist / Notify me / Back), then cards: every store's
## price (each row opens that store), your price alert when it's wishlisted,
## the release date, and the credits for whoever's prices are shown.

const T := preload("res://scripts/ui/texts_discover.gd")
const W := preload("res://scripts/ui/discover/widgets.gd")
const Model := preload("res://scripts/ui/discover/model.gd")
const ChoiceRow := preload("res://scripts/ui/choice_row.gd")
const Badge := preload("res://scripts/ui/badge.gd")

signal back_requested

var ctx: RefCounted
var view: Dictionary = {}
var shown: Dictionary = {}
var deals: Array = []
var buy_button: Button
var wish_button: Button
var notify_button: Button
var library_button: Button
var back_button: Button
var price_rows: Array = []
var prices_box: VBoxContainer
var credits_box: VBoxContainer
var extras: HBoxContainer
var checking := false
var _line := ""


func setup_store(v: Dictionary, c: RefCounted) -> void:
	ctx = c
	view = v
	name = "StorePage"
	ctx.art.fill(view, ["cover", "hero", "logo"])
	deals = _known_deals()
	shown = view
	var rel := release()
	var best := best_deal()
	_line = _eyebrow(best, rel)
	setup_page(shown, _line)
	# Our own chip row replaces the header's meta line and badges.
	header.meta.visible = false
	header.max_badges = 0
	header.show_game(shown, _line)
	extras = Kit.hbox(8)
	extras.name = "Extras"
	extras.mouse_filter = Control.MOUSE_FILTER_IGNORE
	header.get_parent().add_child(extras)
	header.get_parent().move_child(extras, header.get_index() + 1)
	_fill_extras()

	var owned: Dictionary = ctx.owned(view)
	if not owned.is_empty():
		library_button = add_action(T.OPEN_LIBRARY, "library", true, "OpenLibrary")
		library_button.pressed.connect(func(): ctx.open_game(owned))
	buy_button = add_action(_buy_text(best), "tag", owned.is_empty(), "Buy")
	buy_button.pressed.connect(func(): buy())
	if not rel.is_empty() and not rel.get("released", false):
		notify_button = add_action(T.NOTIFY_ON if ctx.is_notifying(view) else T.NOTIFY_OFF, "calendar", false, "Notify")
		notify_button.pressed.connect(func(): toggle_notify())
	wish_button = add_action(T.WISHLISTED if ctx.is_wishlisted(view) else T.WISHLIST_ADD, "star", false, "Wishlist")
	wish_button.pressed.connect(func(): toggle_wishlist())
	back_button = add_action(T.BACK, "chevron_left", false, "Back")
	back_button.pressed.connect(func(): back_requested.emit())
	if buy_button.text.length() > 16:
		buy_button.custom_minimum_size.x = 280

	var pc := add_card(T.PRICES_CARD, "tag", T.PRICES_SUB)
	prices_box = Kit.vbox(10)
	prices_box.name = "PriceRows"
	pc.add_child(prices_box)
	_fill_prices()
	var item := wish_item()
	if not item.is_empty():
		_alert_card(item)
	if not rel.is_empty():
		_release_card(rel)
	credits_box = add_card(T.CREDITS_LEAD, "info")
	_fill_credits()
	finish()
	_request()


## Deals we already know for this game: the cached store list, else the deal
## or wishlist best price that brought us here.
func _known_deals() -> Array:
	var d: Dictionary = view.get("data", {})
	var list: Array = []
	if ctx.discover != null:
		list = ctx.discover.prices_for(_query())
	if list.is_empty():
		if view["kind"] == "deal":
			list = [d]
		elif view["kind"] == "wish" and d.get("best_deal") is Dictionary and not d["best_deal"].is_empty():
			list = [d["best_deal"]]
	return Model.visible_deals(list, ctx.keyshops())


func _query() -> Dictionary:
	var d: Dictionary = view.get("data", {})
	var q := {"title": view.get("title", ""), "ids": view.get("ids", {}).duplicate()}
	if str(view.get("appid", "")) != "":
		q["appid"] = view["appid"]
	if view["kind"] != "deal" and str(d.get("key", "")).begins_with("steam:"):
		q["appid"] = str(d["key"]).substr(6)
	return q


func _request() -> void:
	if ctx.discover == null or not ctx.discover.has_method("request_prices"):
		return
	checking = true
	if not ctx.discover.prices_ready.is_connected(_on_prices):
		ctx.discover.prices_ready.connect(_on_prices)
	_fill_prices()
	ctx.discover.request_prices(_query())


func _on_prices(key: String, list: Array) -> void:
	if not is_instance_valid(self) or (key != view.get("key", "") and key != ctx.wish_key(view)):
		return
	checking = false
	var fresh := Model.visible_deals(list, ctx.keyshops())
	if not fresh.is_empty():
		deals = fresh
	var had_focus := _price_focus_index()
	_fill_prices()
	buy_button.text = _buy_text(best_deal())
	_fill_extras()
	_fill_credits()
	_relink()
	if had_focus >= 0 and not price_rows.is_empty():
		price_rows[mini(had_focus, price_rows.size() - 1)].grab_focus()


func _exit_tree() -> void:
	if ctx != null and ctx.discover != null and ctx.discover.prices_ready.is_connected(_on_prices):
		ctx.discover.prices_ready.disconnect(_on_prices)


func release() -> Dictionary:
	var d: Dictionary = view.get("data", {})
	if view["kind"] == "release":
		return d
	if d.get("release") is Dictionary and not d["release"].is_empty():
		return d["release"]
	var item := wish_item()
	if item.get("release") is Dictionary:
		return item["release"]
	return {}


func wish_item() -> Dictionary:
	if ctx.discover == null:
		return {}
	var key: String = ctx.wish_key(view)
	for it in ctx.discover.wishlist:
		if it["key"] == key:
			return it
	return {}


## Cheapest row with a real price, else the first See-price row.
func best_deal() -> Dictionary:
	for d in deals:
		if d.get("price") is Dictionary:
			return d
	return deals[0] if not deals.is_empty() else {}


func _eyebrow(best: Dictionary, rel: Dictionary) -> String:
	if not best.is_empty() and Model.is_free(best):
		return T.SHELF_FREE
	if not rel.is_empty() and rel.get("days_until") != null and int(rel["days_until"]) == 0:
		return T.HERO_OUT_TODAY
	if not rel.is_empty() and not rel.get("released", false):
		return "Coming " + T.release_when(rel, ctx.now())
	if not best.is_empty() and int(best.get("savings_pct", 0)) > 0:
		return "On sale on " + str(best.get("store_name", ""))
	return ""


func _buy_text(best: Dictionary) -> String:
	if best.is_empty():
		var rel := release()
		return "Store page" if not rel.is_empty() else T.BUY
	var p := T.price(best)
	if p == "":
		return "%s on %s" % [T.SEE_PRICE, best.get("store_name", "")]
	return "%s  %s" % [T.BUY, p]


func buy() -> void:
	var best := best_deal()
	if not best.is_empty():
		ctx.open_link(best.get("link", {}))
		return
	var rel := release()
	if rel.get("link") is Dictionary:
		ctx.open_link(rel["link"])


func toggle_wishlist() -> void:
	var on: bool = ctx.toggle_wishlist(view)
	wish_button.text = T.WISHLISTED if on else T.WISHLIST_ADD
	_fill_extras()
	ctx.hints_changed()


func toggle_notify() -> void:
	var on: bool = ctx.toggle_notify(view)
	if notify_button != null:
		notify_button.text = T.NOTIFY_ON if on else T.NOTIFY_OFF
	wish_button.text = T.WISHLISTED if ctx.is_wishlisted(view) else T.WISHLIST_ADD
	_fill_extras()
	ctx.hints_changed()


func _fill_extras() -> void:
	if extras == null:
		return
	for c in extras.get_children():
		W.detach(extras, c)
	var best := best_deal()
	var cur: String = ctx.currency()
	var now: int = ctx.now()
	if not best.is_empty() and int(best.get("savings_pct", 0)) > 0 and not Model.is_free(best):
		extras.add_child(W.badge("sale", "On sale %s" % T.cut(int(best["savings_pct"])), "sale", "tag", "chip"))
	for b in W.deal_badges(best, cur, now):
		extras.add_child(W.badge(b["kind"], b["text"], b["tone"], b["icon"], "chip"))
	if ctx.is_wishlisted(view):
		extras.add_child(W.badge("wish", T.WISHLISTED, "wish", "star", "chip"))
	var rel := release()
	if not rel.is_empty() and not rel.get("released", false):
		var cd := T.countdown(rel, now)
		if cd != "":
			extras.add_child(W.badge("countdown", cd, T.countdown_tone(rel), "calendar", "chip"))
	if not ctx.owned(view).is_empty():
		extras.add_child(W.badge("owned", T.OWNED, "info", "library", "chip"))
	extras.visible = extras.get_child_count() > 0


func _fill_prices() -> void:
	for c in prices_box.get_children():
		W.detach(prices_box, c)
	price_rows.clear()
	if deals.is_empty():
		var rel := release()
		var none := T.NO_PRICES_SOON if not rel.is_empty() and not rel.get("released", false) else T.NO_PRICES
		var l := Kit.label(T.CHECKING if checking else none, "QuietLabel")
		l.name = "PricesState"
		prices_box.add_child(l)
		return
	var now: int = ctx.now()
	var cur: String = ctx.currency()
	for d in deals:
		var badges: Array = W.deal_badges(d, cur, now)
		var hl := T.hist_low(d, cur)
		if hl != "" and not d.get("is_historical_low", false):
			badges.append({"kind": "hl", "text": hl, "tone": "", "icon": "clock"})
		var link: Dictionary = d.get("link", {}) if d.get("link") is Dictionary else {}
		if link.get("affiliate", false):
			badges.append({"kind": "affiliate", "text": str(link.get("note", "")) if str(link.get("note", "")) != "" else T.SUPPORTS, "tone": "accent", "icon": "sparkle"})
		var sub := ""
		if d.get("keyshop", false):
			sub = str(d.get("keyshop_note", "Sold by a key reseller, not the publisher's store."))
		elif d.get("attribution") is Dictionary:
			sub = str(d["attribution"].get("text", ""))
		elif T.price(d) == "":
			sub = T.SEE_PRICE_WHY
		var right := W.price_column(d)
		right.custom_minimum_size = Vector2(170, 0)
		var store_view := {"key": "store:" + str(d.get("key", "")), "title": str(d.get("store_name", "")), "art": {}}
		var b := W.row(store_view, {"title": str(d.get("store_name", "")), "sub": sub, "badges": badges, "right": right, "thumb": false}, 78 if sub == "" and badges.is_empty() else 88)
		b.set_meta("role", "price")
		b.set_meta("deal", d)
		var deal: Dictionary = d
		b.pressed.connect(func(): ctx.open_link(deal.get("link", {})))
		prices_box.add_child(b)
		price_rows.append(b)
	if checking:
		var l := Kit.label(T.CHECKING, "CaptionLabel")
		l.name = "PricesState"
		prices_box.add_child(l)


func _alert_card(item: Dictionary) -> void:
	var cur: String = ctx.currency()
	var body := add_card(T.TARGET, "sparkle", T.TARGET_LINE)
	var choices := Model.target_choices(item, cur)
	var tr := ChoiceRow.new()
	tr.explainer = func(val): return T.TARGET_ANY_LINE if val == null else T.TARGET_LINE
	tr.setup("page_target", T.TARGET, choices, choices.map(func(x): return T.target_label(x, cur)), item.get("target_price"), "tag")
	tr.button.set_meta("role", "target")
	var key: String = item["key"]
	tr.changed.connect(func(val): ctx.discover.set_target_price(key, val))
	body.add_child(tr)
	var pa: VBoxContainer = ChoiceRow.bool_row("page_alerts", T.ALERTS_TOGGLE, bool(item.get("notify_price", true)), "sparkle")
	pa.button.set_meta("role", "notify_price")
	pa.changed.connect(func(val): ctx.discover.set_notify(key, val, null))
	body.add_child(pa)
	set_meta("alert_rows", [tr.button, pa.button])


func _release_card(rel: Dictionary) -> void:
	var now: int = ctx.now()
	var body := add_card(T.RELEASE_CARD, "calendar")
	var when := T.release_when(rel, now)
	var cd := T.countdown(rel, now)
	var line := when if cd == "" or cd == when else "%s  ·  %s" % [when, cd]
	body.add_child(Kit.icon_label("calendar", line, "LeadLabel", ThemeLib.color("text_2"), 22))
	if not rel.get("released", false):
		body.add_child(Kit.label(T.NOTIFY_LINE, "QuietLabel", true))


func _fill_credits() -> void:
	if credits_box == null:
		return
	for c in credits_box.get_children().slice(1):
		W.detach(credits_box, c)
	var attrs: Array = ctx.discover.attributions().duplicate() if ctx.discover != null else []
	for d in deals:
		var a: Variant = d.get("attribution")
		if a is Dictionary and not attrs.any(func(x): return x.get("url", "") == a.get("url", "")):
			attrs.append(a)
	var cr := W.credits(attrs, func(l): ctx.open_link(l))
	credits_box.add_child(cr)
	credits_box.set_meta("buttons", cr.get_meta("buttons"))


func _price_focus_index() -> int:
	if not is_inside_tree():
		return -1
	var f := get_viewport().gui_get_focus_owner()
	return price_rows.find(f)


func _all_focusables() -> Array:
	var list: Array = price_rows.duplicate()
	if has_meta("alert_rows"):
		list.append_array(get_meta("alert_rows"))
	if credits_box != null and credits_box.has_meta("buttons"):
		var cb: Array = credits_box.get_meta("buttons")
		if not cb.is_empty():
			list.append(cb[0])
	return list


func finish() -> void:
	focusables = _all_focusables()
	super.finish()
	_link_credits()
	for f in focusables:
		W.follow(scroll, f, 90.0)


func _relink() -> void:
	focusables = _all_focusables()
	super.finish()
	_link_credits()
	for f in price_rows:
		W.follow(scroll, f, 90.0)


## Credit chips sit on one row: left/right between them, up to the row above.
func _link_credits() -> void:
	if credits_box == null or not credits_box.has_meta("buttons"):
		return
	var cb: Array = credits_box.get_meta("buttons")
	if cb.size() < 2:
		return
	Kit.link_horizontal(cb)
	for i in range(1, cb.size()):
		cb[i].focus_neighbor_top = cb[i].get_path_to(cb[0].get_node(cb[0].focus_neighbor_top) if cb[0].focus_neighbor_top != NodePath() else cb[i])
		cb[i].focus_neighbor_bottom = cb[i].get_path_to(cb[i])


func default_focus() -> Control:
	return actions[0] if not actions.is_empty() else null


func focus_first() -> void:
	var f := default_focus()
	if f != null and is_inside_tree():
		f.grab_focus()


func hints(f: Control) -> Array:
	var out: Array = []
	if f == buy_button:
		out.append(["A", T.HINT_BUY if not best_deal().is_empty() else T.HINT_OPEN])
	elif f in price_rows:
		out.append(["A", T.HINT_BUY])
	elif f.get_meta("role", "") in ["target", "notify_price"]:
		out.append(["LR", T.HINT_CHANGE])
	elif f.has_meta("link"):
		out.append(["A", T.HINT_LINK])
	else:
		out.append(["A", T.HINT_SELECT])
	out.append(["Y", T.HINT_UNWISH if ctx.is_wishlisted(view) else T.HINT_WISH])
	return out
