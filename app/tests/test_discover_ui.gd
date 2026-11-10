extends "res://tests/test_case.gd"
## The Discover screens with the real Discover service on a fake http
## (fixtures captured 2026-11-08, Canada), a fake Art service and a fake
## library: what ends up on screen, the X / Y / B / LT / RT handling, store
## pages, alerts as toasts, hints, and the empty / offline states. Nodes are
## built outside the scene tree, so everything runs synchronously.

const H := preload("res://tests/fixtures/discover/helpers.gd")
const FakeHttp := preload("res://scripts/discover/fake_http.gd")
const Model := preload("res://scripts/ui/discover/model.gd")
const T := preload("res://scripts/ui/texts_discover.gd")
const W := preload("res://scripts/ui/discover/widgets.gd")
const ArtLink := preload("res://scripts/ui/discover/art_link.gd")
const Root := preload("res://scripts/ui/discover/root.gd")
const DiscoverScreen := preload("res://scripts/ui/discover_screen.gd")
const Kit := preload("res://scripts/ui/ui_kit.gd")


class FakeArt extends RefCounted:
	signal art_ready(key: String, kind: String, path: String)
	var paths := {}
	var asked: Array = []
	func request(key: String, kind: String, hints := {}) -> String:
		asked.append([key, kind, hints])
		return paths.get(key + "|" + kind, "")


class FakeLibrary extends RefCounted:
	var games: Array = []


class Toasts extends RefCounted:
	var log: Array = []
	func add(text: String, icon := "", tone := "", detail := "") -> void:
		log.append([text, icon, tone, detail])
	func texts() -> Array:
		return log.map(func(e): return e[0])


class Host extends Control:
	var hint_bar := HBoxContainer.new()
	var top_bar := TopBarStub.new()
	func _init() -> void:
		add_child(hint_bar)
		add_child(top_bar)


class TopBarStub extends Control:
	var dots := {}
	func set_dot(id: String, on: bool) -> void:
		dots[id] = on


var _free: Array = []


func _discover(http: Variant = null, clock_iso := "") -> Node:
	var d: Node = H.make(http if http != null else H.online_http(), H.temp_dir("disc_ui"))
	if clock_iso != "":
		var t := Time.get_unix_time_from_datetime_string(clock_iso)
		d.clock = func() -> int: return t
	_free.append(d)
	return d


func _root(d: Node, toasts: Toasts = null, lib: FakeLibrary = null, art: FakeArt = null) -> Control:
	var r: Control = Root.new()
	var opened: Array = []
	r.setup({"discover": d, "art": art if art != null else FakeArt.new(), "library": lib if lib != null else FakeLibrary.new(),
		"toast": toasts.add if toasts != null else Callable(), "open_game": func(g): opened.append(g),
		"prefs_path": "", "overlay": null})
	r.set_meta("opened", opened)
	_free.append(r)
	return r


func _cleanup() -> void:
	for n in _free:
		if is_instance_valid(n):
			n.free()
	_free.clear()


static func _action(name: String) -> InputEventAction:
	var e := InputEventAction.new()
	e.action = name
	e.pressed = true
	return e


static func _joy(b: JoyButton) -> InputEventJoypadButton:
	var e := InputEventJoypadButton.new()
	e.button_index = b
	e.pressed = true
	return e


static func _texts(n: Node) -> String:
	var parts: Array[String] = []
	for c in n.find_children("*", "Label", true, false):
		parts.append((c as Label).text)
	for c in n.find_children("*", "Button", true, false):
		parts.append((c as Button).text)
	for c in n.find_children("*", "RichTextLabel", true, false):
		parts.append((c as RichTextLabel).get_parsed_text())
	return " | ".join(parts)


# ---- model and texts ---------------------------------------------------------------

func test_sorting_and_filters() -> void:
	var a := {"title": "A", "store": "steam", "store_name": "Steam", "savings_pct": 50, "price": {"amount": 9.0, "regular": 18.0}, "sale_ends_at": 300, "rating": 7.0}
	var b := {"title": "B", "store": "cs:1", "store_name": "GMG", "savings_pct": 80, "price": null, "sale_ends_at": null, "rating": 9.0}
	var c := {"title": "C", "store": "steam", "store_name": "Steam", "savings_pct": 20, "price": {"amount": 3.0, "regular": 3.75}, "sale_ends_at": 100, "rating": null}
	var list := [a, b, c]
	eq(Model.sort_deals(list, "best").map(func(x): return x.title), ["A", "B", "C"], "best keeps service order")
	eq(Model.sort_deals(list, "discount").map(func(x): return x.title), ["B", "A", "C"], "biggest discount first")
	eq(Model.sort_deals(list, "price").map(func(x): return x.title), ["C", "A", "B"], "cheapest first, See price last")
	eq(Model.sort_deals(list, "ending").map(func(x): return x.title), ["C", "A", "B"], "ending soon, no end last")
	eq(Model.sort_deals(list, "rating").map(func(x): return x.title), ["B", "A", "C"], "top rated")
	eq(Model.stores_of(list), [["", "All stores"], ["steam", "Steam"], ["cs:1", "GMG"]], "store choices")
	eq(Model.filter_store(list, "steam").size(), 2, "store filter")
	ok(not "rating" in Model.sorts_for([c]), "no Top rated without ratings")
	var free := {"savings_pct": 100, "price": null}
	ok(Model.is_free(free) and not Model.is_free(a), "100% off is free")
	ok(Model.is_free({"price": {"amount": 0.0, "regular": 19.99}}), "zero price is free")
	eq(Model.visible_deals([a, {"keyshop": true}], false).size(), 1, "key shops hidden by default")
	eq(Model.visible_deals([a, {"keyshop": true}], true).size(), 2, "key shops when on")


func test_calendar_grouping_and_month() -> void:
	var now := Time.get_unix_time_from_datetime_string("2026-11-08T12:00:00")
	var day := func(iso: String, du: int) -> Dictionary:
		return {"precision": "day", "date": iso, "date_unix": Time.get_unix_time_from_datetime_string(iso + "T00:00:00"), "days_until": du, "released": du < 0}
	var out: Dictionary = day.call("2026-11-01", -7)
	var today: Dictionary = day.call("2026-11-08", 0)
	var soon: Dictionary = day.call("2026-11-12", 4)
	var month: Dictionary = day.call("2026-11-28", 20)
	var later: Dictionary = day.call("2026-12-25", 47)
	var dec := {"precision": "month", "date": "2026-12", "date_unix": Time.get_unix_time_from_datetime_string("2026-12-01T00:00:00"), "days_until": null, "released": false}
	var tba := {"precision": "tba", "date": "", "date_unix": null, "days_until": null, "released": false}
	var groups := Model.group_calendar([out, today, soon, month, later, dec, tba], now)
	eq(groups.map(func(g): return [g[0], g[1].size()]), [["out", 1], ["week", 2], ["month", 1], ["later", 2], ["tba", 1]], "list groups")
	var cells := Model.month_cells(2026, 11)
	eq(cells.slice(0, 7), [0, 0, 0, 0, 0, 0, 1], "Nov 2026 starts on a Sunday (Monday-first grid)")
	eq(cells.size() % 7, 0, "whole weeks")
	eq(cells.max(), 30, "30 days")
	var m := Model.month_map([today, soon, dec], 2026, 11)
	eq(m["days"].keys(), [8, 12], "days with releases")
	eq(Model.month_map([dec], 2026, 12)["undated"].size(), 1, "month-only dates go to undated")
	eq(Model.shift_month(2026, 12, 1), Vector2i(2027, 1), "next month wraps the year")
	eq(Model.shift_month(2026, 1, -1), Vector2i(2025, 12), "previous month wraps back")


func test_texts() -> void:
	var now := Time.get_unix_time_from_datetime_string("2026-11-08T12:00:00")
	eq(T.release_when({"date": "2026-11-10", "precision": "day"}, now), "Nov 10", "same year day")
	eq(T.release_when({"date": "2027-02-03", "precision": "day"}, now), "Feb 3, 2027", "next year day")
	eq(T.release_when({"date": "2026-12", "precision": "month"}, now), "December 2026", "month")
	eq(T.release_when({"date": "2027-Q1", "precision": "quarter"}, now), "Q1 2027", "quarter")
	eq(T.release_when({"date": "", "precision": "tba"}, now), "Date not announced", "tba")
	eq(T.countdown({"days_until": 0, "released": false}, now), "Out today", "today")
	eq(T.countdown({"days_until": 1, "released": false}, now), "Tomorrow", "tomorrow")
	eq(T.countdown({"days_until": 5, "released": false}, now), "In 5 days", "days")
	eq(T.countdown({"days_until": -3, "released": true}, now), "Out now", "out")
	eq(T.ends(now + 3 * 86400 + 60, now), "Ends in 3 days", "sale end")
	eq(T.ends(now + 5 * 3600, now), "Ends in 5 h", "sale end hours")
	eq(T.ends(null, now), "", "no end")
	eq(T.price({"price": null}), "", "no local price")
	eq(T.price({"price": {"amount": 0.0, "text": "C$ 0.00"}}), "Free", "free")
	eq(T.price({"price": {"amount": 4.39, "text": "C$ 4.39"}}), "C$ 4.39", "store's own label")
	eq(T.hist_low({"historical_low": {"amount": 1.99, "currency": "USD"}}, "CAD"), "", "low in another currency is hidden")
	eq(T.target_label(null, "CAD"), "Any sale", "no target")


func test_target_choices_and_hero() -> void:
	var item := {"best_deal": {"price": {"amount": 4.39, "regular": 21.99}}, "target_price": 7.5, "historical_low": {"amount": 3.0, "currency": "CAD"}}
	var ch := Model.target_choices(item, "CAD")
	eq(ch[0], null, "any sale first")
	ok(7.5 in ch and 3.0 in ch, "current target and lowest ever offered")
	ok(ch.slice(1) == ch.slice(1).duplicate().map(func(x): return x), "values")
	var sorted := ch.slice(1).duplicate()
	sorted.sort()
	eq(ch.slice(1), sorted, "ascending")
	var deal := {"title": "D", "appid": "1", "price": {"amount": 5.0, "regular": 10.0}, "savings_pct": 50}
	var big := {"title": "E", "appid": "2", "price": {"amount": 5.0, "regular": 50.0}, "savings_pct": 90}
	eq(Model.pick_hero([deal, big], [], [])["data"]["title"], "E", "biggest real-price deal")
	var ws := {"title": "W", "on_sale": true, "savings_pct": 10, "best_deal": deal}
	eq(Model.pick_hero([deal, big], [ws], [])["kind"], "wish", "wishlisted sale beats deals")
	var today := {"title": "R", "days_until": 0}
	eq(Model.pick_hero([deal], [], [today])["kind"], "release", "a release out today beats deals")
	eq(Model.pick_hero([], [], [{"title": "S", "days_until": 5}])["line"], "release", "upcoming release when there are no deals")
	eq(Model.pick_hero([], [], []), {}, "nothing")
	var cal := [{"title": "Out today", "days_until": 0, "released": true}, {"title": "Out last week", "days_until": -7, "released": true},
		{"title": "Old date", "days_until": -8000, "released": true}, {"title": "Q1", "days_until": null, "released": false},
		{"title": "Tomorrow", "days_until": 1, "released": false}, {"title": "Today, not flagged", "days_until": 0, "released": false}]
	eq(Model.coming_soon(cal).map(func(r): return r["title"]), ["Q1", "Tomorrow"], "Coming soon: nothing already out, nothing out today")
	var lib := [{"key": "steam:49520", "title": "Borderlands 2"}, {"key": "gog:9", "title": "Witcher 3"}]
	eq(Model.owned_game({"appid": "49520", "title": "x"}, lib)["key"], "steam:49520", "owned by appid")
	eq(Model.owned_game({"appid": "", "title": "The Witcher 3"}, lib), {}, "different title isn't owned")
	eq(Model.owned_game({"appid": "", "title": "Witcher 3!"}, lib)["key"], "gog:9", "owned by normalised title")


# ---- screens from real Discover data --------------------------------------------------

func test_home_shelves_from_fixtures() -> void:
	var d := _discover()
	d.refresh(true)
	var r := _root(d)
	var home: Control = r.sections["home"]
	ok(home.shelves.size() >= 2, "shelves built")
	eq(home.shelves[0].id, "deals", "Top deals first")
	ok(home.shelves.any(func(s): return s.id == "soon"), "Coming soon shelf")
	ok(home.shelves.any(func(s): return s.id == "free"), "Free right now (Flotsam is 100% off)")
	ok(not home.spot_view.is_empty(), "spotlight picked")
	var tile: Control = home.shelves[0].tiles[0]
	ok(tile.price_label.get_parent() == tile.pill_row, "price lives in the deal tile's bottom plate")
	var tiles: Array = home.shelves[0].tiles
	ok(tiles.all(func(t): return t.price_label.visible and t.price_label.text != "" and t.sub_label.text != ""),
		"every deal tile: the same two-line plate (price or See price, then the store)")
	var quiet: Array = tiles.filter(func(t): return t.price_label.text == T.SEE_PRICE)
	ok(not quiet.is_empty(), "no local price: See price, never a guessed price (CheapShark rows in Canada)")
	ok(quiet.all(func(t): return t.sub_label.autowrap_mode == TextServer.AUTOWRAP_OFF and not t.sub_label.text.begins_with("Price on")),
		"the store on one line that never wraps")
	ok(quiet.all(func(t): return t.price_icon != null and t.price_icon.visible and t.price_icon.custom_minimum_size.y == t.SUB_PX),
		"the store's logo at the line's height, not a big white block")
	var cards := _texts(home)
	ok(cards.contains(T.GG_TITLE), "gg.deals card while there's no key and See-price rows show")
	ok(cards.contains("Price data by CheapShark"), "credits shown")
	var credit: Button = home.find_child("Credit_*", true, false)
	eq(credit.get_meta("url"), "https://www.cheapshark.com/", "credit links to CheapShark")
	_cleanup()


func test_gg_card_dismiss_and_key() -> void:
	var d := _discover()
	d.refresh(true)
	var r := _root(d)
	var home: Control = r.sections["home"]
	var gg: Control = home.find_child("GgCard", true, false)
	ok(gg != null, "card shown")
	gg.get_meta("buttons")[1].pressed.emit()
	ok(home.find_child("GgCard", true, false) == null or home.find_child("GgCard", true, false).is_queued_for_deletion(), "Not now hides it")
	eq(r.ctx.prefs.get_value("gg_dismissed"), true, "remembered")
	_cleanup()


func test_deals_browser_filter_sort_and_y() -> void:
	var d := _discover()
	d.refresh(true)
	var toasts := Toasts.new()
	var r := _root(d, toasts)
	r.show_section("deals", false)
	var deals: Control = r.sections["deals"]
	eq(deals.rows.size(), d.deals.size(), "a row per deal")
	var all := _texts(deals)
	ok(all.contains(T.SEE_PRICE), "See price rows")
	ok(all.contains("C$ 4.39"), "Steam's own Canadian price")
	ok(all.contains("Price data by CheapShark"), "credits")
	# Store filter.
	var steam_rows: int = d.deals.filter(func(x): return x["store"] == "steam").size()
	deals.store_row.set_value_quiet("steam")
	deals._set_pref("deals_store", "steam")
	deals = r.sections["deals"]
	eq(deals.rows.size(), steam_rows, "store filter")
	deals._set_pref("deals_store", "")
	# X cycles the sort and toasts it.
	eq(r.handle_input(_joy(JOY_BUTTON_X), r.sections["deals"].rows[0]), true, "X used")
	eq(r.ctx.prefs.get_value("deals_sort"), "discount", "next sort")
	ok(toasts.texts().has("Sorted by biggest discount"), "sort toast")
	# Y wishlists the focused deal.
	var row: Button = r.sections["deals"].rows[0]
	var v: Dictionary = row.get_meta("view")
	ok(not d.is_wishlisted(v["data"]), "not yet")
	r.handle_input(_joy(JOY_BUTTON_Y), row)
	ok(d.is_wishlisted(v["data"]), "Y adds to the wishlist")
	ok(toasts.texts().has(T.TOAST_ADDED), "toast")
	_cleanup()


func test_keyshop_and_affiliate_rows() -> void:
	var d := _discover()
	d.refresh(true)
	var r := _root(d)
	var deal: Dictionary = d.deals[0].duplicate(true)
	deal["link"] = {"kind": "url", "uri": "https://store.example/x", "affiliate": true, "note": "Supports GameCove"}
	var row: Button = r.sections["deals"]._row(Model.deal_view(deal), deal, H.now(), "CAD")
	_free.append(row)
	ok(_texts(row).contains("Supports GameCove"), "affiliate note on the row")
	ok(Model.visible_deals([{"keyshop": true}], r.ctx.keyshops()).is_empty(), "key shops hidden while the setting is off")
	d.set_settings({"ggdeals_keyshops": true})
	ok(r.ctx.keyshops(), "setting read")
	_cleanup()


func test_calendar_list_notify_and_today() -> void:
	# Football Manager 27 comes out 2026-11-10: make that today.
	var d := _discover(null, "2026-11-10T12:00:00")
	d.refresh(true)
	var toasts := Toasts.new()
	var r := _root(d, toasts)
	r.show_section("calendar", false)
	var cal: Control = r.sections["calendar"]
	cal.set_layout("list")
	cal = r.sections["calendar"]
	ok(cal.rows.size() > 0, "rows")
	var text := _texts(cal)
	ok(text.contains(T.GROUP_LABELS["week"]) or text.contains(T.GROUP_LABELS["month"]), "group headings: " + text.left(300))
	var fm: Array = cal.rows.filter(func(p): return p[0].get_meta("view")["title"] == "Football Manager 27")
	eq(fm.size(), 1, "FM27 listed")
	ok(fm[0][0].has_meta("today"), "released-today highlight")
	ok(_texts(fm[0][0]).contains(T.HERO_OUT_TODAY), "Out today badge")
	# Notify me on a future entry.
	var future: Array = cal.rows.filter(func(p): return p[1].focus_mode != Control.FOCUS_NONE and p[0].get_meta("view")["data"].get("days_until") != null and int(p[0].get_meta("view")["data"]["days_until"]) > 0)
	ok(not future.is_empty(), "a future entry")
	var v: Dictionary = future[0][0].get_meta("view")
	future[0][1].pressed.emit()
	ok(d.get_item(v["data"]["key"]).get("notify_release", false), "Notify me sets a release alert")
	ok(toasts.texts().has(T.TOAST_NOTIFY), "toast")
	cal = r.sections["calendar"]
	var again: Array = cal.rows.filter(func(p): return p[0].get_meta("view")["key"] == v["key"])
	eq(again[0][1].text, T.NOTIFY_ON, "button shows it's on after the rebuild")
	r.handle_input(_joy(JOY_BUTTON_Y), again[0][0])
	ok(not d.get_item(v["data"]["key"]).get("notify_release", true), "Y turns it off")
	# review M24: IGDB's release dates fill the calendar, so its credit (with a link) shows here
	cal = r.sections["calendar"]
	ok(cal.credit_button != null and cal.credit_button.text == T.IGDB_CREDIT, "Game data from IGDB")
	eq(cal.credit_button.get_meta("url"), "https://www.igdb.com", "links to igdb.com")
	ok(cal.credit_button in cal._toolbar(), "reachable with the controller")
	_cleanup()


func test_calendar_month_layout() -> void:
	var d := _discover()
	d.refresh(true)
	var r := _root(d)
	r.show_section("calendar", false)
	var cal: Control = r.sections["calendar"]
	r.handle_input(_joy(JOY_BUTTON_X), cal.list_button)
	cal = r.sections["calendar"]
	eq(cal.layout, "month", "X switches to month")
	eq(r.ctx.prefs.get_value("calendar_layout"), "month", "remembered")
	ok(cal.day_buttons.has(10), "Nov 10 has a release")
	eq(cal.day_buttons[10].focus_mode, Control.FOCUS_ALL, "days with releases are focusable")
	ok(_texts(cal.day_buttons[10]).contains("Football Manager 27"), "title in the cell")
	cal._show_panel(10)
	ok(_texts(cal._panel).contains("Football Manager 27"), "panel lists the day")
	var day: Button = cal.day_buttons[10]
	ok(day.find_child("Dot", true, false) != null, "dot on a release day")
	day.size = Vector2(70, 64)
	day.resized.emit()   # outside the tree the signal doesn't fire by itself
	ok(day.find_child("Covers", true, false) == null, "small cell: titles, no covers")
	day.size = Vector2(130, 112)
	day.resized.emit()
	ok(day.find_child("Covers", true, false) != null, "big cell: small covers")
	ok(not day.find_child("Titles", true, false).visible, "titles hidden behind the covers")
	cal.shift_month(1)
	cal = r.sections["calendar"]
	eq(cal.ym, Vector2i(2026, 12), "next month")
	ok(cal.day_buttons.has(25), "Christmas Day Game")
	ok(cal.undated_button != null, "December Thing has no day")
	_cleanup()


func test_calendar_missing_state() -> void:
	var http := H.online_http()
	http.route(H.UPCOMING, {"code": 404, "text": "Not Found"})
	var d := _discover(http)
	d.refresh(true)
	eq(d.status.get("calendar"), "missing", "calendar not published yet")
	var r := _root(d)
	var cal: Control = r.sections["calendar"]
	ok(cal.empty_card != null, "friendly empty card")
	ok(_texts(cal).contains(T.CAL_EMPTY_TITLE), "explains it")
	_cleanup()


func test_offline_and_empty_states() -> void:
	var http := FakeHttp.new()
	http.offline = true
	var d := _discover(http)
	d.refresh(true)
	var r := _root(d)
	var home: Control = r.sections["home"]
	ok(home.shelves.is_empty(), "nothing to shelve")
	ok(_texts(home).contains(T.OFFLINE_TITLE), "offline card")
	ok(home.default_focus() is Button, "focus lands on Try again")
	ok(r.offline_pill.visible, "offline pill in the header")
	ok(_texts(r.sections["deals"]).contains(T.OFFLINE_TITLE), "deals say offline too")
	var wish: Control = r.sections["wishlist"]
	ok(wish.empty_card != null and _texts(wish).contains(T.WISH_EMPTY_TITLE), "empty wishlist card")
	ok(_texts(wish).contains("Public"), "explains the public profile")
	_cleanup()


func test_wishlist_import_and_detail() -> void:
	var d := _discover()
	d.refresh(true)
	var toasts := Toasts.new()
	var r := _root(d, toasts)
	r.show_section("wishlist", false)
	var w: Control = r.sections["wishlist"]
	w.open_import()
	ok(w.import_open(), "import sheet open")
	eq(w.keyboard.placeholder, T.IMPORT_FIELD_EMPTY, "keyboard placeholder")
	var underscore := false
	for row in w.keyboard.keys:
		for b in row:
			underscore = underscore or b.text == "_"
	ok(underscore, "underscore key for custom names")
	ok(r.hints_for(w.import_go).all(func(h): return h[1] != T.HINT_VIEWS), "no section switching hints while importing")
	eq(r.handle_input(_joy(JOY_BUTTON_RIGHT_SHOULDER), w.import_go), false, "shoulders aren't Discover's")
	w._set_typed("robinwalker")
	w._start_import()
	w = r.sections["wishlist"]
	ok(not w.import_open(), "closed after a good import")
	ok(toasts.texts().any(func(t): return t.begins_with("Imported")), "import toast")
	eq(w.rows.size(), d.wishlist.size(), "rows for every item")
	ok(d.wishlist.size() >= 2, "items imported")
	# Detail: target price.
	var civ: Array = w.rows.filter(func(b): return b.get_meta("view")["key"] == "steam:3900")
	eq(civ.size(), 1, "Civ IV on the wishlist")
	w.show_detail("steam:3900")
	var target: Button = w.detail_focus[0]
	eq(target.get_meta("role"), "target", "target row first")
	var row: VBoxContainer = target.get_parent()
	row.step(1)
	ok(d.get_item("steam:3900")["target_price"] != null, "target saved")
	ok(row.hint_text() == T.TARGET_LINE, "line under the row explains it")
	_cleanup()


func test_wishlist_import_error_and_remove() -> void:
	var http := H.online_http()
	http.route(H.STEAM_WISHLIST, {"file": H.fx("steam_wishlist_private.json")})
	var d := _discover(http)
	d.refresh(true)
	var toasts := Toasts.new()
	var r := _root(d, toasts)
	r.show_section("wishlist", false)
	var w: Control = r.sections["wishlist"]
	w.open_import()
	w._set_typed("robinwalker")
	w._start_import()
	w = r.sections["wishlist"]
	ok(w.import_open(), "stays open on an empty/private wishlist")
	ok(w.import_status.visible and w.import_status.text.contains("private"), "says why")
	eq(r.handle_input(_action("ui_cancel"), w.import_go), true, "B closes the sheet")
	ok(not w.import_open(), "closed")
	d.add_to_wishlist({"title": "Borderlands 2", "appid": "49520"})
	w = r.sections["wishlist"]
	eq(w.rows.size(), 1, "one item")
	r.handle_input(_joy(JOY_BUTTON_Y), w.rows[0])
	eq(d.wishlist.size(), 0, "Y removes")
	_cleanup()


func test_alerts_inbox_and_toasts() -> void:
	var d := _discover()
	d.refresh(true)
	var toasts := Toasts.new()
	var r := _root(d, toasts)
	var alerts: Array = []
	r.alerts_changed.connect(func(n): alerts.append(n))
	d.price_alert.emit({"title": "Hades", "target_price": 10.0}, {"title": "Hades", "savings_pct": 60, "store_name": "Steam", "price": {"amount": 9.99, "text": "C$ 9.99"}})
	eq(toasts.log[-1][0], "Hades is 60% off", "price toast")
	eq(toasts.log[-1][3], "C$ 9.99 on Steam, under your target.", "detail")
	eq(toasts.log[-1][2], "sale", "sale tone")
	d.release_alert.emit({"title": "Football Manager 27"})
	eq(toasts.log[-1][0], "Football Manager 27 is out now", "release toast")
	# Inbox: card with Mark all seen.
	d.add_to_wishlist({"title": "Civ", "appid": "3900"})
	d.alerts_inbox.append({"id": "x1", "kind": "price", "key": "steam:3900", "title": "Civ IV", "at": H.now() - 7200, "amount": 4.39, "currency": "CAD"})
	r.show_section("wishlist", false)
	d.wishlist_changed.emit()
	var w: Control = r.sections["wishlist"]
	eq(w.alert_buttons.size(), 1, "alert row")
	ok(_texts(w).contains("Civ IV dropped to C$4.39"), "alert line")
	ok(r._wish_dot.visible, "dot on the Wishlist chip")
	ok(alerts.has(1), "alerts count for the tab dot")
	w.seen_button.pressed.emit()
	eq(d.alerts_inbox.size(), 0, "marked seen")
	_cleanup()


func test_store_page_prices_buy_and_back() -> void:
	var d := _discover()
	d.refresh(true)
	var opened: Array = []
	d.set_meta("x", 1)
	var lib := FakeLibrary.new()
	var r := _root(d, Toasts.new(), lib)
	var civ: Dictionary = d.deals.filter(func(x): return x["appid"] == "3900")[0]
	r.open_page(Model.deal_view(civ))
	var p: Control = r.page
	ok(p != null, "page open")
	ok(not r.visible, "sections hidden behind the page")
	ok(p.buy_button.text.contains("C$ 4.39"), "Buy shows the best local price")
	ok(not p.price_rows.is_empty(), "price rows")
	ok(_texts(p).contains("Price data by CheapShark"), "credits on the page")
	ok(p.library_button == null, "not owned: no Open in library")
	var hints: Array = r.hints_for(p.buy_button)
	eq(hints[0], ["A", T.HINT_BUY], "A buys")
	ok(hints.has(["B", T.HINT_BACK]), "B goes back")
	# Y wishlists from the page.
	r.handle_input(_joy(JOY_BUTTON_Y), p.buy_button)
	ok(d.is_wishlisted(civ), "wishlisted from the page")
	eq(p.wish_button.text, T.WISHLISTED, "button follows")
	eq(r.handle_input(_joy(JOY_BUTTON_LEFT_SHOULDER), p.buy_button), true, "LB swallowed on a page")
	eq(r.handle_input(_action("ui_cancel"), p.buy_button), true, "B closes")
	ok(r.page == null and r.visible, "back to the sections")
	# Owned game: Open in library leads.
	lib.games = [{"key": "steam:3900", "title": "Civilization IV", "store": "steam"}]
	r.open_page(Model.deal_view(civ))
	ok(r.page.library_button != null, "Open in library")
	eq(r.page.actions[0], r.page.library_button, "first action")
	r.page.library_button.pressed.emit()
	eq(r.get_meta("opened").size(), 1, "opened in the library")
	ok(r.page == null, "store page closed first")
	_cleanup()


func test_store_page_upcoming_release() -> void:
	var d := _discover()
	d.refresh(true)
	var r := _root(d, Toasts.new())
	var fm: Dictionary = d.calendar.filter(func(x): return x["title"] == "Football Manager 27")[0]
	r.open_page(Model.release_view(fm))
	var p: Control = r.page
	ok(p.notify_button != null, "Notify me on an upcoming game")
	p.notify_button.pressed.emit()
	ok(d.get_item(fm["key"]).get("notify_release", false), "release alert on")
	eq(p.notify_button.text, T.NOTIFY_ON, "button follows")
	ok(_texts(p).contains(T.RELEASE_CARD), "release card")
	ok(_texts(p).contains("In 2 days"), "countdown")
	_cleanup()


func test_input_sections_and_back() -> void:
	var d := _discover()
	d.refresh(true)
	var r := _root(d)
	var f: Control = r.sections["home"].primary
	eq(r.trigger(_trigger_event(JOY_AXIS_TRIGGER_RIGHT, 1.0)), 1, "RT")
	r.handle_input(_trigger_event(JOY_AXIS_TRIGGER_RIGHT, 0.0), f)
	r.handle_input(_trigger_event(JOY_AXIS_TRIGGER_RIGHT, 1.0), f)
	eq(r.current, "deals", "RT goes to the next section")
	var k := InputEventKey.new()
	k.keycode = KEY_PAGEUP
	k.pressed = true
	r.handle_input(k, f)
	eq(r.current, "home", "Page Up (LT) goes back")
	r.show_section("wishlist", false)
	eq(r.handle_input(_action("ui_cancel"), r.sections["wishlist"].import_button), true, "B in a section")
	eq(r.current, "home", "goes to For you")
	eq(r.handle_input(_action("ui_cancel"), f), false, "B on For you is main's (Home)")
	var hints: Array = r.hints_for(f)
	ok(hints.has([["LT", "RT"], T.HINT_VIEWS]), "LT / RT hint")
	ok(hints.has(["B", T.HINT_HOME]), "B Home on For you")
	ok(hints.any(func(h): return h[0] == "Y"), "Y hint on the spotlight")
	_cleanup()


func _trigger_event(axis: JoyAxis, v: float) -> InputEventJoypadMotion:
	var e := InputEventJoypadMotion.new()
	e.axis = axis
	e.axis_value = v
	return e


func test_art_arrives_later() -> void:
	var d := _discover()
	d.refresh(true)
	var art := FakeArt.new()
	var r := _root(d, null, null, art)
	ok(art.asked.any(func(a): return a[1] == "cover" and str(a[2].get("url", "")).begins_with("https://")), "asks Art with the store's URL as a hint")
	var img := Image.create(60, 90, false, Image.FORMAT_RGB8)
	img.fill(Color(0.2, 0.5, 0.7))
	var path := ProjectSettings.globalize_path(H.temp_dir("disc_art") + "/c.png")
	img.save_png(path)
	var tile: Control = r.sections["home"].shelves[0].tiles[0]
	var key: String = tile.game["key"]
	art.art_ready.emit(key, "cover", path)
	eq(tile.game["art"]["cover"], path, "tile's view updated")
	ok(tile.has_cover(), "cover shown without a rebuild")
	_cleanup()


func test_discover_screen_hook_and_host() -> void:
	var d := _discover()
	d.refresh(true)
	var host := Host.new()
	var screen: Control = DiscoverScreen.new()
	host.add_child(screen)
	screen.setup({"discover": d, "art": FakeArt.new(), "library": FakeLibrary.new(), "toast": Callable(), "open_game": Callable(), "prefs_path": ""})
	ok(screen.content.get_script() == Root, "Discover area built")
	eq(screen.host(), host, "host found by its hint bar")
	ok(screen.default_focus() != null, "default focus")
	screen.content.open_page(Model.deal_view(d.deals[0]))
	ok(not host.top_bar.visible, "top bar hidden while a store page is open")
	ok(screen.overlay.get_child_count() == 1, "page on the overlay layer")
	screen.content.close_page()
	ok(host.top_bar.visible, "top bar back")
	screen.visible = false
	screen.content.alerts_changed.emit(2)
	eq(host.top_bar.dots.get("discover"), true, "dot on the Discover tab while alerts wait")
	host.free()
	_cleanup()


func test_every_theme_builds() -> void:
	var ThemeLib = load("res://theme/gamecove_theme.gd")
	var d := _discover()
	d.refresh(true)
	for id in ["cove", "midnight", "sunset", "light"]:
		ThemeLib.use(id)
		var r := _root(d)
		for s in r.ORDER:
			r.show_section(s, false)
		r.open_page(Model.deal_view(d.deals[0]))
		ok(r.page != null, "page in " + id)
		r.close_page()
	ThemeLib.use("cove")
	_cleanup()
