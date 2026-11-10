extends VBoxContainer
## The body of the game page's "Steam insights" card (Steam games only):
## players now, review summary and Steam Deck rating as three stat tiles;
## the last update (A reads its notes in a drawer); the price on Steam with
## the lowest price ever; DLC (A lists them with local prices); "Open on
## SteamDB" (a QR code for the phone) and the data credits. Everything comes
## from Steam itself and Discover's price sources (steam_insights.gd); SteamDB
## forbids scraping, so it is only linked.
##
##   var card := InsightsCard.new()
##   card.setup(game, insights_service, page)   # page hosts the drawer
##   card.relinked.connect(page._relink)        # focusables changed
##
## States: "loading" (first fetch), "data", "offline" (nothing cached and
## Steam can't be reached), "off" (Background lookups is off and nothing is
## cached); hidden for non-Steam games (visible_for()).

const Kit := preload("res://scripts/ui/ui_kit.gd")
const ThemeLib := preload("res://theme/gamecove_theme.gd")
const Icons := preload("res://scripts/ui/icons.gd")
const GameIcons := preload("res://scripts/ui/games/game_icons.gd")
const TI := preload("res://scripts/ui/texts_insights.gd")
const Api := preload("res://scripts/steam/insights_api.gd")
const AppId := preload("res://scripts/steam/app_id.gd")
const Overlay := preload("res://scripts/ui/games/insights_overlay.gd")
const W := preload("res://scripts/ui/discover/widgets.gd")

## The focusable rows changed (shown or hidden): the page relinks focus.
signal relinked
## A row took focus: the page can scroll the card into view.
signal row_focused

var appid := ""
var service: Object
## Where the drawer goes (the page); the card's own parent chain otherwise.
var overlay_host: Control
var overlay: Overlay
## The last service.view() shown.
var data: Dictionary = {}
var state := ""

var status_label: Label
var stats: HBoxContainer
var players_value: Label
var reviews_value: Label
var reviews_sub: Label
var deck_value: Label
var update_button: Button
var price_box: VBoxContainer
var price_label: Label
var low_label: Label
var prices_off_label: Label
var dlc_button: Button
var steamdb_button: Button
var source_label: Label
var credits_row: HBoxContainer
var _focus_sig := ""


## Steam games with a real app id get the card.
static func visible_for(game: Dictionary) -> bool:
	return str(game.get("store", "")) == "steam" and AppId.valid(str(game.get("id", "")))


func setup(game: Dictionary, svc: Object, host: Control = null) -> void:
	name = "SteamInsights"
	appid = str(game.get("id", ""))
	service = svc
	overlay_host = host
	add_theme_constant_override("separation", 12)
	status_label = Kit.label("", "QuietLabel", true)
	status_label.name = "Status"
	add_child(status_label)

	stats = Kit.hbox(8)
	stats.name = "Stats"
	var p := _stat(TI.PLAYERS, "Players")
	players_value = p[0]
	var r := _stat(TI.REVIEWS, "Reviews")
	reviews_value = r[0]
	reviews_sub = r[1]
	var d := _stat(TI.DECK, "Deck")
	deck_value = d[0]
	add_child(stats)

	update_button = _row("update", TI.UPDATE, "Update")
	update_button.pressed.connect(open_update)
	add_child(update_button)

	price_box = Kit.vbox(2)
	price_box.name = "Price"
	price_label = Kit.label("", "LeadLabel", true)
	price_label.name = "Now"
	price_label.add_theme_font_override("font", ThemeLib.font("semibold", true))
	price_box.add_child(price_label)
	low_label = Kit.label("", "QuietLabel", true)
	low_label.name = "Lowest"
	price_box.add_child(low_label)
	add_child(price_box)
	prices_off_label = Kit.label(TI.PRICES_OFF, "CaptionLabel", true)
	prices_off_label.name = "PricesOff"
	prices_off_label.add_theme_color_override("font_color", ThemeLib.color("text_3"))
	add_child(prices_off_label)

	dlc_button = _row("layers", TI.DLC, "Dlc")
	dlc_button.pressed.connect(open_dlc)
	add_child(dlc_button)

	steamdb_button = _row("external", TI.STEAMDB, "SteamDB")
	steamdb_button.pressed.connect(open_steamdb)
	_set_row(steamdb_button, TI.STEAMDB, "steamdb.info", "")
	add_child(steamdb_button)

	source_label = Kit.label(TI.SOURCE_STEAM, "CaptionLabel", true)
	source_label.name = "Source"
	source_label.add_theme_color_override("font_color", ThemeLib.color("text_3"))
	add_child(source_label)

	if service != null:
		if service.has_signal("changed"):
			service.changed.connect(_on_changed)
		service.request(appid)
	refresh()


func _on_changed(id: String) -> void:
	if id == appid:
		refresh()


## A stat tile: mono caption over a value; returns [value, sub-line].
func _stat(caption: String, node: String) -> Array:
	var p := PanelContainer.new()
	p.name = "Stat_" + node
	p.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	p.add_theme_stylebox_override("panel", ThemeLib.box(ThemeLib.soft(0.06), ThemeLib.radius("m"), 12, 8))
	var c := Kit.vbox(2)
	c.add_child(Kit.micro(caption))
	var v := Kit.label(TI.DASH, "LeadLabel")
	v.name = "Value"
	v.add_theme_font_override("font", ThemeLib.font("semibold", true))
	v.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	c.add_child(v)
	var sub := Kit.label("", "CaptionLabel")
	sub.name = "Sub"
	sub.add_theme_color_override("font_color", ThemeLib.color("text_3"))
	sub.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	sub.visible = false
	c.add_child(sub)
	p.add_child(c)
	stats.add_child(p)
	return [v, sub]


## A focusable row: icon, a title over a detail line, a value on the right.
func _row(icon: String, title: String, node: String) -> Button:
	var b := Kit.button("", "RowButton")
	b.name = node
	b.custom_minimum_size = Vector2(0, 62)
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var row := Kit.hbox(12)
	row.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	row.offset_left = 14
	row.offset_right = -12
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	b.add_child(row)
	row.add_child(GameIcons.rect(icon, 22, ThemeLib.color("text_2")))
	var texts := Kit.vbox(0)
	texts.alignment = BoxContainer.ALIGNMENT_CENTER
	texts.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	texts.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var l := Kit.label(title)
	l.name = "Text"
	l.add_theme_font_override("font", ThemeLib.font("medium"))
	l.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	texts.add_child(l)
	var dl := Kit.label("", "QuietLabel")
	dl.name = "Detail"
	dl.add_theme_font_size_override("font_size", ThemeLib.SIZE_CAPTION)
	dl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	texts.add_child(dl)
	row.add_child(texts)
	var v := Kit.label("", "CaptionLabel")
	v.name = "Value"
	v.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(v)
	row.add_child(Icons.rect("chevron_right", 18, ThemeLib.color("text_3")))
	b.focus_entered.connect(func(): row_focused.emit())
	return b


static func _set_row(b: Button, title: String, detail: String, value: String) -> void:
	var texts: Node = b.get_child(0).get_child(1)
	texts.get_node("Text").text = title
	var dl: Label = texts.get_node("Detail")
	dl.text = detail
	dl.visible = detail != ""
	b.get_child(0).get_node("Value").text = value


## Shows the service's current view.
func refresh() -> void:
	if service == null:
		return
	data = service.view(appid)
	state = str(data.get("summary", "loading"))
	var st: Dictionary = data.get("state", {})
	var has_data := state == "data"
	match state:
		"loading":
			status_label.text = TI.LOADING
		"off":
			status_label.text = TI.OFF
		"offline":
			status_label.text = TI.OFFLINE_EMPTY
		_:
			var stale := false
			for part in ["players", "store", "news"]:
				if st.get(part, "") in ["offline", "error"]:
					stale = true
			status_label.text = TI.OFFLINE if stale else ""
	status_label.visible = status_label.text != ""
	stats.visible = state in ["loading", "data"]

	# stat tiles
	var n := int(data.get("players", -1))
	players_value.text = TI.players(n) if st.get("players", "") == "ok" else TI.DASH
	var rv: Dictionary = data.get("reviews", {})
	if not rv.is_empty():
		reviews_value.text = str(rv.get("label", "")) if str(rv.get("label", "")) != "" else "%d%%" % int(rv.get("percent", 0))
		reviews_value.add_theme_color_override("font_color", ThemeLib.tone(Api.review_tone(rv)) if Api.review_tone(rv) != "" else ThemeLib.color("text"))
		reviews_sub.text = "%d%% of %s" % [int(rv.get("percent", 0)), Api.group(int(rv.get("count", 0)))]
		reviews_sub.visible = true
		reviews_value.tooltip_text = Api.review_line(rv)
	else:
		reviews_value.text = TI.NO_REVIEWS if st.get("store", "") == "ok" else TI.DASH
		reviews_value.remove_theme_color_override("font_color")
		reviews_sub.visible = false
	var deck := int(data.get("deck", -1))
	if deck >= 0:
		var di := Api.deck_info(deck)
		deck_value.text = di["text"]
		if di["tone"] != "":
			deck_value.add_theme_color_override("font_color", ThemeLib.tone(di["tone"]))
		else:
			deck_value.remove_theme_color_override("font_color")
	else:
		deck_value.text = TI.DASH
		deck_value.remove_theme_color_override("font_color")

	# last update
	var news: Array = data.get("news", [])
	update_button.visible = has_data and st.get("news", "") != "off"
	if not news.is_empty():
		var top: Dictionary = news[0]
		_set_row(update_button, TI.UPDATE + " · " + TI.date(int(top.get("date", 0))), str(top.get("title", "")), "")
	else:
		_set_row(update_button, TI.UPDATE, TI.NO_UPDATE if st.get("news", "") == "ok" else TI.DASH, "")
	update_button.set_meta("has_notes", not news.is_empty())

	# price
	var on: bool = data.get("prices_on", false)
	var price: Dictionary = data.get("price", {})
	var low: Dictionary = data.get("low", {})
	price_box.visible = on and (not price.is_empty() or not low.is_empty())
	price_label.text = TI.PRICE + ": " + TI.price_line(price) if not price.is_empty() else ""
	price_label.visible = not price.is_empty()
	low_label.text = TI.LOWEST + ": " + TI.low_line(low)
	low_label.visible = not low.is_empty() or not price.is_empty()
	prices_off_label.visible = not on and has_data

	# DLC
	var count := int(data.get("dlc_count", 0))
	dlc_button.visible = has_data and count > 0
	var priced: bool = data.get("dlc_priced", false)
	_set_row(dlc_button, TI.DLC_COUNT % count, TI.DLC_SEE, _dlc_from(data.get("dlc", [])) if priced else "")

	steamdb_button.visible = str(data.get("steamdb", "")) != ""
	source_label.visible = has_data

	# credits (an active link wherever their prices show)
	var attrs: Array = data.get("attributions", []) if price_box.visible else []
	var sig := JSON.stringify(attrs)
	if credits_row == null or credits_row.get_meta("sig", "") != sig:
		if credits_row != null:
			Kit.drop(self, credits_row)
			credits_row = null
		if not attrs.is_empty():
			credits_row = W.credits(attrs, _open_link)
			credits_row.set_meta("sig", sig)
			add_child(credits_row)
	_maybe_relink()


## "from C$ 6.99" over the DLC with a price.
static func _dlc_from(rows: Array) -> String:
	var best := ""
	var best_cents := -1
	for r in rows:
		var t := str(r.get("price_text", ""))
		if t == "":
			continue
		var digits := t.replace(",", "").replace(".", "")
		var cents := int("0" + RegEx.create_from_string("[^0-9]").sub(digits, "", true))
		if best_cents < 0 or cents < best_cents:
			best_cents = cents
			best = t
	return "from " + best if best != "" else ""


func _open_link(link: Dictionary) -> void:
	var d: Object = service.discover_node() if service != null and service.has_method("discover_node") else null
	if d != null and d.has_method("open_link"):
		d.open_link(link)


## The focusable controls, top to bottom, as shown now.
func focusables() -> Array:
	var out: Array = []
	for b in [update_button, dlc_button, steamdb_button]:
		if b != null and b.visible:
			out.append(b)
	if credits_row != null:
		out.append_array(credits_row.get_meta("buttons", []))
	return out


func _maybe_relink() -> void:
	var sig := ""
	for c in focusables():
		sig += str(c.get_instance_id()) + ","
	if sig != _focus_sig:
		_focus_sig = sig
		relinked.emit()


# ---- drawers ---------------------------------------------------------------------

func _overlay() -> Overlay:
	if overlay == null or not is_instance_valid(overlay):
		overlay = Overlay.new()
		var host: Node = overlay_host if overlay_host != null else (get_tree().root if is_inside_tree() else self)
		host.add_child(overlay)
	return overlay


## The latest update's notes, readable in place.
func open_update() -> void:
	var news: Array = data.get("news", [])
	if news.is_empty():
		return
	var top: Dictionary = news[0]
	var body := Api.bbcode_to_rich(str(top.get("body", "")))
	var sub := str(top.get("title", "")) + " · " + TI.date(int(top.get("date", 0)))
	var foot := "\n\n[color=#%s][font_size=14]%s[/font_size][/color]" % [ThemeLib.color("text_3").to_html(false), TI.NOTES_SOURCE]
	_overlay().open_text(TI.UPDATE, sub, body + foot)


## Every DLC (the first 50) with its local Steam price when prices are on.
func open_dlc() -> void:
	var rows: Array = data.get("dlc", [])
	var count := int(data.get("dlc_count", 0))
	var priced: bool = data.get("dlc_priced", false)
	var lines: Array[String] = []
	for r in rows:
		var t := Api._text(str(r.get("title", "")))
		var p := ""
		if priced:
			p = TI.FREE if bool(r.get("free", false)) and str(r.get("price_text", "")) == "" else Api._text(str(r.get("price_text", "")))
			if int(r.get("savings_pct", 0)) > 0:
				p += "  [color=#%s]−%d%%[/color]" % [ThemeLib.tone("good").to_html(false), int(r["savings_pct"])]
		lines.append("[b]%s[/b]%s" % [t, ("\n" + p) if p != "" else ""])
	var foot := ""
	if count > rows.size() and not rows.is_empty():
		foot += "\n\n" + TI.DLC_MORE % [rows.size(), count]
	if not priced and data.get("prices_on", false) == false:
		foot += "\n\n" + TI.DLC_PRICES_OFF
	var text := "\n\n".join(lines) if not lines.is_empty() else TI.LOADING
	_overlay().open_text(TI.DLC, TI.DLC_COUNT % count, text + foot)


## A QR code for the game's SteamDB page (a phone handoff) and the address.
func open_steamdb() -> void:
	var url := str(data.get("steamdb", Api.steamdb_url(appid)))
	if url == "":
		return
	_overlay().open_qr(TI.STEAMDB, url, TI.STEAMDB_LINE, TI.STEAMDB_NOTE)


func _exit_tree() -> void:
	if overlay != null and is_instance_valid(overlay) and overlay.get_parent() != self:
		overlay.queue_free()
