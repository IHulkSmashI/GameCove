extends "res://scripts/ui/discover/section.gd"
## "For you": a spotlight over the focused game's art (the biggest deal or a
## big release to start with), then shelves: Top deals, From your wishlist on
## sale, Coming soon, Free to keep (games a store gives away right now). Moving through the shelves changes the
## spotlight, like Home. Under the shelves: the optional gg.deals card, the
## offline / loading card when there's nothing to show, and the credits.

const Shelf := preload("res://scripts/ui/shelf.gd")
const GameHeader := preload("res://scripts/ui/game_header.gd")
const HeroStage := preload("res://scripts/ui/hero_stage.gd")
const HeroInk := preload("res://scripts/ui/hero_ink.gd")
const FadeMask := preload("res://scripts/ui/fade_mask.gd")

## The spotlight card: about 26 px shorter than Home's, so the shelves get the room.
const SPOT_H := 206

var stage: Control              # HeroStage, lives on root's stage layer
var header: Control             # GameHeader
var price_box: HBoxContainer
var primary: Button
var secondary: Button
var spot_view: Dictionary = {}
var spot_line := ""
var shelves: Array = []
var views: Array = []           # every view on screen (for art arrivals)
var cards_focus: Array = []     # buttons under the shelves, top to bottom
var empty_card: Control
var _scroll: ScrollContainer
var _rows: VBoxContainer
var _spot: VBoxContainer
var _hero: Dictionary = {}
var _cards_pad: Control


## Kept for callers: Top deals now leaves out every game the spotlight or the
## wishlist shelf shows.
const TOP_UNIQUE := 8
## Free to keep with this many games or fewer shows them as wide featured cards.
const FEATURED_MAX := 2
## Discover's side margin (discover_screen.gd), for sizes worked out before layout.
const SIDE := 48.0


func setup(c: RefCounted) -> void:
	super.setup(c)
	name = "Home"


## Stage layer (full screen, behind the content) for the crisp hero art.
func attach_stage(layer: Control) -> void:
	stage = HeroStage.new()
	stage.name = "DiscoverHero"
	stage.frame_radius = float(ThemeLib.radius("xl"))
	layer.add_child(stage)
	stage.pause_motion()      # no slow drift here: nothing moves when nothing happens
	stage.visible = visible
	visibility_changed.connect(func(): stage.visible = is_visible_in_tree())
	stage.art_changed.connect(_sync_ink)


## Keep the hero art (on root's stage layer) inside the spotlight's frame.
var _spot_frame: Control


func _sync_current_stage() -> void:
	if is_instance_valid(_spot_frame):
		_sync_stage(_spot_frame)


func _sync_stage(frame: Control) -> void:
	if stage == null or not is_instance_valid(frame) or not frame.is_inside_tree():
		return
	stage.frame_radius = float(ThemeLib.radius("xl"))
	stage.set_anchors_preset(Control.PRESET_TOP_LEFT)
	stage.global_position = frame.global_position
	stage.size = frame.size
	stage._apply_fade()
	stage.visible = is_visible_in_tree() and frame.visible
	_sync_ink()


## The spotlight's text follows what's behind it (light on art in every
## theme, see hero_ink.gd), and the stage's scrim follows the title's width.
func _sync_ink() -> void:
	if stage == null or not is_instance_valid(header):
		return
	header.on_art = stage.text_on_art()
	# Light: the frame's glass would lie over the art as a white veil (the
	# stage is on the layer behind): clear while there's art, the border stays.
	if is_instance_valid(_spot_frame):
		var fsb := _spot_frame.get_theme_stylebox("panel") as StyleBoxFlat
		if fsb != null:
			fsb.bg_color.a = 0.0 if header.light_ink() else 0.45
	if is_inside_tree() and stage.is_inside_tree() and header.is_inside_tree():
		stage.set_text_extent(header.global_position.x + header.title_right() - stage.global_position.x)
	_ink_price()


## The price beside the chips is built in the hero's light ink while it sits
## on art: build it again when that changes (the art arrived, or left).
var _price_ink := false


func _ink_price() -> void:
	if not is_instance_valid(price_box) or spot_view.is_empty() or header.light_ink() == _price_ink:
		return
	for c in price_box.get_children():
		W.detach(price_box, c)
	_fill_price(spot_view)


func build() -> void:
	shelves.clear()
	views.clear()
	cards_focus.clear()
	var d: Object = ctx.discover
	var deals: Array = Model.visible_deals(d.deals, ctx.keyshops())
	var wish: Array = d.wishlist
	var cal: Array = d.calendar
	var root := Kit.vbox(18)
	root.name = "HomeRoot"
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)

	_spot = Kit.vbox(9)
	_spot.name = "Spotlight"
	_spot.custom_minimum_size = Vector2(0, SPOT_H)
	_spot.alignment = BoxContainer.ALIGNMENT_CENTER
	_spot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# The spotlight sits in a rounded glass card; the hero art fills it.
	var frame := PanelContainer.new()
	frame.name = "SpotFrame"
	frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var fsb := ThemeLib.box(Color(ThemeLib.color("glass"), 0.45), ThemeLib.radius("xl"), 32, 15)
	fsb.border_color = ThemeLib.color("line_2")
	fsb.set_border_width_all(1)
	frame.add_theme_stylebox_override("panel", fsb)
	frame.add_child(_spot)
	root.add_child(frame)
	frame.item_rect_changed.connect(_sync_stage.bind(frame))
	# The spotlight is rebuilt on refresh; connect to our own visibility once
	# and always sync the current frame.
	_spot_frame = frame
	if not visibility_changed.is_connected(_sync_current_stage):
		visibility_changed.connect(_sync_current_stage)
	header = GameHeader.new()
	# Wordmarks land at about 260-340 px wide (SteamGridDB's horizontal ones
	# come first, art.gd); the height keeps the shelves below in view.
	header.max_logo = Vector2(340, 110)
	header.max_badges = 0
	header.meta.visible = false
	header.extent_changed.connect(_sync_ink)
	_spot.add_child(header)
	price_box = Kit.hbox(18)
	price_box.name = "SpotPrice"
	price_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_spot.add_child(price_box)
	var buttons := Kit.hbox(14)
	buttons.name = "SpotButtons"
	primary = Kit.primary(T.VIEW_DEAL, "A")
	primary.name = "SpotPrimary"
	primary.custom_minimum_size = Vector2(196, 56)
	primary.add_theme_constant_override("h_separation", 10)
	primary.pressed.connect(func(): ctx.open_page(spot_view))
	secondary = Kit.button(T.WISHLIST_ADD)
	secondary.name = "SpotSecondary"
	secondary.custom_minimum_size = Vector2(176, 56)
	secondary.add_theme_constant_override("h_separation", 10)
	secondary.pressed.connect(_on_secondary)
	buttons.add_child(primary)
	buttons.add_child(secondary)
	_spot.add_child(buttons)
	for b in [primary, secondary]:
		b.focus_entered.connect(func(): _scroll_rows(0.0))

	_scroll = W.scroller()
	_scroll.follow_focus = false
	root.add_child(_scroll)
	# A 48 px alpha fade at the foot: the next row peeking in looks masked,
	# not sliced off under the hint bar.
	var foot: TextureRect = FadeMask.wrap(_scroll, 48.0)
	# The page's margin is SIDE, but a shelf keeps PAD of room around its tiles for the focus
	# ring and glow; a scroller starting at the margin cut the first tile's ring and glow on
	# its left edge. This one starts PAD earlier (the tiles stay where they were), so the
	# room is inside it.
	var bleed := Control.new()
	bleed.name = "ShelfBleed"
	bleed.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bleed.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bleed.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.remove_child(foot)
	root.add_child(bleed)
	bleed.add_child(foot)
	foot.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	foot.offset_left = -Shelf.PAD.x
	# A card under the shelves (the gg.deals note, the credits) that the foot
	# would slice isn't drawn until it fits: its text never sits half in the fade.
	foot.cut_fn = func(): return foot_items()
	var pad := Kit.margin(0)
	pad.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll.add_child(pad)
	_rows = Kit.vbox(4)
	_rows.name = "Rows"
	_rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	pad.add_child(_rows)

	var now: int = ctx.now()
	var cur: String = ctx.currency()
	var ws := Model.on_sale_wishlist(wish)
	var soon := Model.coming_soon(cal)
	var free := Model.free_to_keep(deals, Model.visible_deals(d.free_deals if "free_deals" in d else [], ctx.keyshops()))
	var top := deals.filter(func(x): return not Model.is_free(x))
	# No game twice: the spotlight's game leaves the shelves, and Top deals
	# leaves out what the wishlist shelf shows.
	_hero = Model.pick_hero(deals, wish, cal)
	var hero_key := Model.art_key(_hero.get("data", {})) if not _hero.is_empty() else ""
	var wish_views: Array = ws.map(func(x): return Model.wish_view(x)).filter(func(v): return v["key"] != hero_key)
	var shown := {hero_key: true}
	for v in wish_views:
		shown[v["key"]] = true
	# Filtered, not pushed back: a game the wishlist shelf shows right below
	# never repeats in Top deals.
	var top_views: Array = top.map(func(x): return Model.deal_view(x)).filter(func(v): return not shown.has(v["key"]))
	var specs := [
		["deals", T.SHELF_DEALS, top_views],
		["wish_sale", T.SHELF_WISH_SALE, wish_views],
		["soon", T.SHELF_SOON, soon.slice(0, 20).map(func(x): return Model.release_view(x))],
		["free", T.SHELF_FREE, free.map(func(x): return Model.deal_view(x))],
	]
	for s in specs:
		if s[2].is_empty():
			continue
		for v in s[2]:
			v["line"] = s[1]
			v["store"] = _store_of(v)
			ctx.art.fill(v, ["cover"])
			views.append(v)
		var shelf: VBoxContainer = Shelf.new()
		# One or two giveaways are shown as wide featured cards that fill the
		# row (a single cover left most of the screen empty).
		if s[0] == "free" and s[2].size() <= FEATURED_MAX:
			for v in s[2]:
				ctx.art.fill(v, ["hero"])
			shelf.art_kind = "hero"
			# the row is as wide as the spotlight: the screen less Discover's margins
			var row_w: float = Shelf.Tile.row_width() + 2.0 * ThemeLib.EDGE - 2.0 * SIDE
			var fsize := Shelf.featured_size(row_w)
			shelf.setup(s[0], s[1], s[2], fsize)
			if s[2].size() == 1:
				shelf.strip.add_child(_free_note(s[2][0], fsize, now, cur))
		else:
			shelf.setup(s[0], s[1], s[2])
		for t in shelf.tiles:
			_decorate(t, now, cur)
		shelf.fit_row()
		shelf.tile_focused.connect(_on_tile_focus.bind(shelf))
		shelf.tile_pressed.connect(func(v): ctx.open_page(v))
		_rows.add_child(shelf)
		shelves.append(shelf)

	var nothing := shelves.is_empty()
	_build_cards(deals, nothing)
	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0, 200 if not nothing else 0)
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_rows.add_child(spacer)

	_spot.get_parent().visible = not nothing
	if nothing:
		_spot.custom_minimum_size = Vector2.ZERO
		if stage != null:
			stage.show_welcome()
		ctx.focus({})
	else:
		var hv: Dictionary = _hero_view()
		_set_spot(hv, _hero_line(), false)
	_link()


func _hero_view() -> Dictionary:
	if _hero.is_empty():
		return shelves[0].tiles[0].game
	var key := Model.art_key(_hero["data"])
	for v in views:
		if v["key"] == key:
			return v
	var v: Dictionary
	match _hero["kind"]:
		"wish": v = Model.wish_view(_hero["data"])
		"release": v = Model.release_view(_hero["data"])
		_: v = Model.deal_view(_hero["data"])
	v["store"] = _store_of(v)
	views.append(v)
	return v


func _hero_line() -> String:
	match _hero.get("line", ""):
		"wish_sale": return T.HERO_WISH_SALE
		"out_today": return T.HERO_OUT_TODAY
		"release": return T.HERO_RELEASE
	return T.HERO_DEAL


static func _store_of(v: Dictionary) -> String:
	var d: Dictionary = v.get("data", {})
	if v["kind"] == "wish":
		var bd: Variant = d.get("best_deal", {})
		return str(bd.get("store_name", "")) if bd is Dictionary else ""
	return str(d.get("store_name", ""))


## Beside a lone giveaway's featured card: what it is, where, what it
## usually costs and when the giveaway ends (all from the deal itself).
func _free_note(v: Dictionary, card: Vector2, now: int, cur: String) -> Control:
	var d: Dictionary = v["data"]
	var p := PanelContainer.new()
	p.name = "FreeNote"
	p.theme_type_variation = "CardPanel"
	p.custom_minimum_size = card
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var col := Kit.vbox(10)
	col.alignment = BoxContainer.ALIGNMENT_CENTER
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	p.add_child(col)
	var store := str(v.get("store", ""))
	var eyebrow := Kit.micro(T.FREE_ON % store if store != "" else T.SHELF_FREE, "EyebrowLabel")
	col.add_child(eyebrow)
	var title := Kit.label(str(v.get("title", "")), "HeaderLabel", true)
	title.name = "Title"
	title.max_lines_visible = 2
	title.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	col.add_child(title)
	var price := W.price_column(d, true, false)
	price.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	col.add_child(price)
	var chips := Kit.hbox(8)
	chips.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for b in W.deal_badges(d, cur, now):
		chips.add_child(W.badge(b["kind"], b["text"], b["tone"], b["icon"], "chip"))
	if chips.get_child_count() > 0:
		col.add_child(chips)
	else:
		chips.free()
	var how := Kit.label(T.FREE_HOW, "QuietLabel", true)
	how.name = "How"
	col.add_child(how)
	return p


## Price plate and extra pills on a shelf tile.
func _decorate(t: Button, now: int, cur: String) -> void:
	var v: Dictionary = t.game
	var d: Dictionary = v["data"]
	var plate := ""
	var quiet := false
	var extras: Array = []
	var store_line := ""
	match v["kind"]:
		"deal":
			plate = T.price(d)
			if plate == "":
				var gg: Variant = d.get("ggdeals")
				var ggp: Variant = gg.get("price") if gg is Dictionary else null
				if ggp is Dictionary and bool(ggp.get("is_local", false)):
					# The user's GG.deals key gives the game's real local price
					# (its best across official stores): show it, say whose it
					# is, and drop the store's own discount it may not match.
					plate = str(ggp.get("text", ""))
					store_line = T.GG_BEST
					t.set_status_pill({})
				else:
					# No real local price: never convert or estimate one. Same
					# plate as a priced deal: discount and "See price", then the store.
					plate = T.SEE_PRICE
					quiet = true
					store_line = T.store_short(str(d.get("store_name", "")))
			extras = W.deal_badges(d, cur, now).slice(0, 1)
		"wish":
			var bd: Dictionary = d.get("best_deal", {})
			plate = T.price(bd)
			if d.get("is_historical_low", false):
				extras = [{"kind": "low", "text": T.HIST_LOW, "tone": "good", "icon": "sparkle"}]
		"release":
			plate = T.countdown(d, now)
			if d.get("days_until") != null and int(d["days_until"]) == 0:
				extras = [{"kind": "today", "text": T.HERO_OUT_TODAY, "tone": "good", "icon": "sparkle", "solid": true}]
				plate = T.release_when(d, now)
			if ctx.is_notifying(v):
				extras.append({"kind": "notify", "text": "Notify", "tone": "new", "icon": "check"})
	W.decorate(t, plate, quiet, extras, str(v.get("store", "")), store_line)


# ---- spotlight -----------------------------------------------------------------

func _set_spot(v: Dictionary, line: String, animate: bool) -> void:
	spot_view = v
	spot_line = line
	# cover too: the stage falls back to it, and the spotlight game is in no shelf to load it
	ctx.art.fill(v, ["hero", "logo", "cover"])
	header.show_game(v, line, animate)
	for c in price_box.get_children():
		W.detach(price_box, c)
	_fill_price(v)
	var owned: Dictionary = ctx.owned(v)
	if v["kind"] == "release":
		primary.text = T.VIEW_GAME
		primary.icon = Icons.tex("info", 20)
		secondary.text = T.NOTIFY_ON if ctx.is_notifying(v) else T.NOTIFY_OFF
		secondary.icon = Icons.tex("check" if ctx.is_notifying(v) else "calendar", 20)
	else:
		primary.text = T.VIEW_DEAL
		primary.icon = Icons.tex("tag", 20)
		var w: bool = ctx.is_wishlisted(v)
		secondary.text = T.WISHLISTED if w else T.WISHLIST_ADD
		secondary.icon = Icons.tex("star", 20)
	if not owned.is_empty():
		secondary.text = T.OPEN_LIBRARY
		secondary.icon = Icons.tex("library", 20)
	if stage != null:
		stage.show_game(v)
	ctx.focus(v)


func _fill_price(v: Dictionary) -> void:
	var ink: bool = header.light_ink()
	_price_ink = ink
	var d: Dictionary = v["data"]
	var now: int = ctx.now()
	var cur: String = ctx.currency()
	var deal: Dictionary = d
	if v["kind"] == "wish":
		deal = d.get("best_deal", {})
	if v["kind"] == "release":
		var cd := T.countdown(d, now)
		if cd != "":
			price_box.add_child(W.badge("countdown", cd, T.countdown_tone(d), "calendar", "chip"))
		if T.release_when(d, now) != cd:
			price_box.add_child(W.badge("when", T.release_when(d, now), "", "calendar", "chip"))
		if ctx.is_notifying(v):
			price_box.add_child(W.badge("notify", T.NOTIFY_ON, "new", "check", "chip"))
		if not ctx.owned(v).is_empty():
			price_box.add_child(W.badge("owned", T.OWNED, "info", "library", "chip"))
		return
	if deal.is_empty():
		return
	var col := W.price_column(deal, true, false)
	if ink:
		var amount := col.find_child("Amount", true, false) as Label
		amount.add_theme_color_override("font_color", HeroInk.accent(Color(0, 0, 0, 0)) if amount.get_meta("accent", false) else HeroInk.meta())
		GameHeader._shade(amount, true)
		var reg := col.find_child("Regular", true, false) as RichTextLabel
		if reg != null:
			reg.add_theme_color_override("default_color", HeroInk.meta())
	price_box.add_child(col)
	var side := Kit.vbox(6)
	side.alignment = BoxContainer.ALIGNMENT_CENTER
	side.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# The header's meta line already names the store; say it here only when
	# the deal is on a different one.
	var store := str(deal.get("store_name", ""))
	if store != "" and store != str(v.get("store", "")):
		var where := Kit.icon_label("store", "on " + store, "QuietLabel", HeroInk.meta() if ink else Color(0, 0, 0, 0), 18, false)
		if ink:
			(where.get_child(1) as Label).add_theme_color_override("font_color", HeroInk.meta())
			GameHeader._shade(where.get_child(1) as Label, true)
		side.add_child(where)
	var chips := Kit.hbox(8)
	chips.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for b in W.deal_badges(deal, cur, now):
		chips.add_child(W.badge(b["kind"], b["text"], b["tone"], b["icon"], "chip"))
	# Wishlisted / owned are said by the second button, not a chip as well.
	if chips.get_child_count() > 0:
		side.add_child(chips)
	price_box.add_child(side)


func _on_secondary() -> void:
	var v := spot_view
	var owned: Dictionary = ctx.owned(v)
	if not owned.is_empty():
		ctx.open_game(owned)
		return
	if v["kind"] == "release":
		ctx.toggle_notify(v)
	else:
		ctx.toggle_wishlist(v)


## A Discover change (wishlist / notify) touched the spotlight game: refresh it.
func refresh_spot() -> void:
	if not spot_view.is_empty() and header != null:
		_set_spot(spot_view, spot_line, false)


func _on_tile_focus(v: Dictionary, i: int, shelf: Control) -> void:
	var r := shelves.find(shelf)
	var t: Control = shelf.tiles[i]
	var up: Control = shelves[r - 1].remembered() if r > 0 else primary
	var down: Control = shelves[r + 1].remembered() if r + 1 < shelves.size() else (cards_focus[0] if not cards_focus.is_empty() else t)
	t.focus_neighbor_top = t.get_path_to(up)
	t.focus_neighbor_bottom = t.get_path_to(down)
	for b in [primary, secondary]:
		b.focus_neighbor_bottom = b.get_path_to(t)
	if not cards_focus.is_empty():
		cards_focus[0].focus_neighbor_top = cards_focus[0].get_path_to(t)
	_scroll_rows(shelf.position.y)
	_set_spot(v, v.get("line", ""), true)


func _scroll_rows(y: float) -> void:
	if not is_inside_tree() or _scroll == null:
		return
	Motion.method(_scroll, "vscroll", func(val: float): _scroll.scroll_vertical = int(val),
		float(_scroll.scroll_vertical), y, Motion.BASE)


# ---- cards under the shelves -------------------------------------------------------

## What the foot never slices: the shelves and the cards under them.
func foot_items() -> Array:
	var out: Array = []
	for s in shelves:
		if is_instance_valid(s):
			out.append(s)
	if is_instance_valid(_cards_pad) and _cards_pad.get_child_count() > 0:
		for c in _cards_pad.get_child(0).get_children():
			if c is Control and (c as Control).visible:
				out.append(c)
	return out


func _build_cards(deals: Array, nothing: bool) -> void:
	var box := Kit.vbox(16)
	box.name = "Cards"
	var pad := Kit.margin(0)
	pad.add_theme_constant_override("margin_left", int(Shelf.PAD.x))
	pad.add_theme_constant_override("margin_right", 4)
	pad.add_theme_constant_override("margin_top", 6 if not nothing else 0)
	pad.add_child(box)
	_rows.add_child(pad)
	_cards_pad = pad
	var cs: String = ctx.status("cheapshark")
	empty_card = null
	if nothing:
		if cs == "offline":
			empty_card = W.info_card("discover", T.OFFLINE_TITLE, T.OFFLINE, [[T.RETRY, func(): ctx.discover.refresh(true), "update"]])
		elif cs.begins_with("error") or cs == "rate_limited":
			empty_card = W.info_card("discover", T.LOADING_TITLE, T.RATE_LIMITED if cs == "rate_limited" else T.LOADING, [[T.RETRY, func(): ctx.discover.refresh(true), "update"]])
		else:
			empty_card = W.info_card("discover", T.LOADING_TITLE, T.LOADING, [[T.RETRY, func(): ctx.discover.refresh(true), "update"]])
		empty_card.name = "EmptyCard"
		box.add_child(empty_card)
		cards_focus.append_array(empty_card.get_meta("buttons"))
	elif not ctx.has_gg_key() and not ctx.prefs.get_value("gg_dismissed") and deals.any(func(x): return x.get("see_price", false)):
		var gg := W.info_card("", T.GG_TITLE, T.GG_BODY, [[T.GG_GET, func(): ctx.open_link({"kind": "url", "uri": T.GG_URL}), "chevron_right"], [T.GG_LATER, _dismiss_gg, ""]], "tag", false)
		gg.name = "GgCard"
		box.add_child(gg)
		cards_focus.append_array(gg.get_meta("buttons"))
	if ctx.status("ggdeals") == "error: key not accepted":
		var bad := W.info_card("", T.GG_BAD, "", [], "alert", false)
		bad.name = "GgBad"
		box.add_child(bad)
	if not deals.is_empty() or nothing:
		var cr := W.credits(ctx.discover.attributions(), func(l): ctx.open_link(l))
		box.add_child(cr)
		var cb: Array = cr.get_meta("buttons")
		if not cb.is_empty():
			cards_focus.append(cb[0])


func _dismiss_gg() -> void:
	ctx.prefs.set_value("gg_dismissed", true)
	refresh()


func _link() -> void:
	var first_shelf: Control = shelves[0].remembered() if not shelves.is_empty() else null
	var after_spot: Control = first_shelf if first_shelf != null else (cards_focus[0] if not cards_focus.is_empty() else null)
	Kit.link_horizontal([primary, secondary])
	for b in [primary, secondary]:
		b.focus_neighbor_top = b.get_path_to(top_target if top_target != null else b)
		b.focus_neighbor_bottom = b.get_path_to(after_spot if after_spot != null else b)
	for s in shelves:
		for t in s.tiles:
			t.focus_neighbor_top = t.get_path_to(primary)
	if not cards_focus.is_empty():
		var above: Control = shelves[-1].remembered() if not shelves.is_empty() else top_target
		# Each card's buttons sit on one row; up/down move between rows.
		var rows: Array = []
		for b in cards_focus:
			rows.append(b)
		for i in rows.size():
			var b: Control = rows[i]
			var up: Control = rows[i - 1] if i > 0 else above
			b.focus_neighbor_top = b.get_path_to(up if up != null else b)
			b.focus_neighbor_bottom = b.get_path_to(rows[i + 1] if i + 1 < rows.size() else b)
			# Buttons beside the first one in a card share its up/down.
			for sib in b.get_parent().get_children():
				if sib is Button and sib != b and not sib in rows:
					sib.focus_neighbor_top = sib.get_path_to(up if up != null else sib)
					sib.focus_neighbor_bottom = sib.get_path_to(rows[i + 1] if i + 1 < rows.size() else sib)
			b.focus_entered.connect(func(): _scroll_rows(maxf(0.0, _cards_pad.position.y - 40.0)))


func set_top_target(c: Control) -> void:
	super.set_top_target(c)
	if primary != null and is_instance_valid(primary):
		for b in [primary, secondary]:
			b.focus_neighbor_top = b.get_path_to(c)
	if empty_card != null and is_instance_valid(empty_card) and shelves.is_empty() and not cards_focus.is_empty():
		cards_focus[0].focus_neighbor_top = cards_focus[0].get_path_to(c)


func default_focus() -> Control:
	# the Spotlight's button only when it shows: while deals load (or offline)
	# its buttons are hidden and focus goes to the card's Try again
	if _spot != null and _shown(primary):
		return primary
	for c in cards_focus:
		if _shown(c):
			return c
	return null


## `c` and everything between it and this view are shown (the screen itself
## may be off while it slides in).
func _shown(c: Control) -> bool:
	var n: Node = c
	while n != null and is_instance_valid(n) and n != self:
		if n is CanvasItem and not (n as CanvasItem).visible:
			return false
		n = n.get_parent()
	return n == self


func hints(f: Control) -> Array:
	var v := view_of(f)
	if f == primary or f == secondary:
		v = spot_view
	if v.is_empty():
		return [["A", T.HINT_SELECT]] if f is BaseButton else []
	var out: Array = [["A", T.HINT_OPEN if f != secondary else T.HINT_SELECT]]
	if v["kind"] == "release":
		out.append(["Y", T.HINT_UNNOTIFY if ctx.is_notifying(v) else T.HINT_NOTIFY])
	else:
		out.append(["Y", T.HINT_UNWISH if ctx.is_wishlisted(v) else T.HINT_WISH])
	return out


func on_button(b: String, f: Control) -> bool:
	if b != "y":
		return false
	var v := view_of(f)
	if f == primary or f == secondary:
		v = spot_view
	if v.is_empty():
		return false
	if v["kind"] == "release":
		ctx.toggle_notify(v)
	else:
		ctx.toggle_wishlist(v)
	return true


func on_art(key: String, kind: String, path: String) -> void:
	if not W.ArtLinkScript.apply(views, key, kind, path):
		return
	if kind == "cover" or kind == "hero":
		for s in shelves:
			for t in s.tiles:
				if t.game.get("key", "") == key and (kind == "cover" or t.art_kind == "hero"):
					t.ensure_art()
	if spot_view.get("key", "") == key:
		if (kind == "hero" or kind == "cover") and stage != null:
			stage.show_game(spot_view)
		if kind == "logo" or kind == "hero":
			header.show_game(header.game, spot_line)
		ctx.focus(spot_view)
