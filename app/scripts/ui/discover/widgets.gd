extends RefCounted
## Builders shared by the Discover screens, all made from design-system parts:
## deal tiles (the library tile plus a price plate), list rows (RowButton with
## a small cover), price blocks, info cards for empty/offline states, and the
## credits row that links to whoever's data is on screen.

const Kit := preload("res://scripts/ui/ui_kit.gd")
const Icons := preload("res://scripts/ui/icons.gd")
const Illustrations := preload("res://scripts/ui/illustrations.gd")
const ThemeLib := preload("res://theme/gamecove_theme.gd")
const Badge := preload("res://scripts/ui/badge.gd")
const Tile := preload("res://scripts/ui/game_tile.gd")
const ArtCache := preload("res://scripts/ui/art_cache.gd")
const FallbackArt := preload("res://scripts/ui/fallback_art.gd")
const ArtShader := preload("res://shaders/rounded_art.gdshader")
const T := preload("res://scripts/ui/texts_discover.gd")
const Model := preload("res://scripts/ui/discover/model.gd")
const ArtLinkScript := preload("res://scripts/ui/discover/art_link.gd")


static func badge(kind: String, text: String, tone: String, icon := "", style := "tile") -> PanelContainer:
	return Badge.make({"kind": kind, "text": text, "short": text, "tone": tone, "icon": icon}, style)


## Extra badges for a Deal (beyond the sale pill the tile draws itself).
static func deal_badges(deal: Dictionary, currency: String, now: int) -> Array:
	var out: Array = []
	if deal.get("is_historical_low", false):
		out.append({"kind": "low", "text": T.HIST_LOW, "tone": "good", "icon": "sparkle"})
	var e := T.ends(deal.get("sale_ends_at"), now)
	if e != "":
		out.append({"kind": "ends", "text": e, "tone": "warn", "icon": "clock"})
	if deal.get("keyshop", false):
		out.append({"kind": "keyshop", "text": T.KEYSHOP, "tone": "warn", "icon": "alert"})
	# Steam's review summary (it comes with the Steam price call, nothing extra is asked)
	var rv = deal.get("reviews")
	if rv is Dictionary and not rv.is_empty():
		var IA := preload("res://scripts/steam/insights_api.gd")
		out.append({"kind": "reviews", "text": IA.review_short(rv), "tone": IA.review_tone(rv), "icon": "star"})
	return out


## A library tile for a Discover view with a price plate along the bottom and
## extra pills under the corner one. `plate` "" hides the plate.
static func tile(view: Dictionary, plate: String, plate_quiet := false, extras: Array = [], size := Tile.SIZE) -> Button:
	var t: Button = Tile.new()
	t.setup(view, true, size)
	decorate(t, plate, plate_quiet, extras)
	return t


## Adds the price plate and extra pills to an existing tile (e.g. a Shelf's):
## stacked at the bottom-left, over the darker end of the cover, away from
## the title most covers carry at the top.
static func decorate(t: Button, plate: String, plate_quiet := false, extras: Array = [], store := "") -> void:
	if plate == "" and extras.is_empty():
		return
	# Library tiles: the price joins the sale pill in the bottom plate and one
	# extra follows the store line, so the cover's top stays clean.
	if t.has_method("set_price"):
		t.set_price(plate, plate_quiet, store_icon(store) if plate_quiet else null)
		if not extras.is_empty():
			t.set_extra(extras[0])
		return
	var box := Kit.vbox(4)
	box.name = "BottomStack"
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.anchor_top = 1.0
	box.anchor_bottom = 1.0
	box.offset_left = 8
	box.offset_top = -8
	box.offset_bottom = -8
	box.grow_vertical = Control.GROW_DIRECTION_BEGIN
	for e in extras.slice(0, 2):
		box.add_child(Badge.make({"kind": e.get("kind", "x"), "text": e["text"], "short": e["text"], "tone": e.get("tone", ""), "icon": e.get("icon", "")},
			"solid" if e.get("solid", false) else "tile"))
	if plate != "":
		var p := PanelContainer.new()
		p.name = "PricePlate"
		p.mouse_filter = Control.MOUSE_FILTER_IGNORE
		p.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
		p.add_theme_stylebox_override("panel", ThemeLib.box(Color(0.03, 0.05, 0.08, 0.82), 8, 9, 4))
		var l := Kit.label(plate)
		l.name = "Text"
		l.add_theme_font_override("font", ThemeLib.font("semibold", true))
		l.add_theme_font_size_override("font_size", ThemeLib.SIZE_CAPTION)
		l.add_theme_color_override("font_color", Color(1, 1, 1, 0.72) if plate_quiet else Color.WHITE)
		p.add_child(l)
		box.add_child(p)
	# Tiles with a title block: the pills and price sit above the title.
	var info: Control = t.get("info_box")
	if info != null:
		box.anchor_top = 0.0
		box.anchor_bottom = 0.0
		box.offset_left = 0
		box.offset_top = 0
		box.offset_bottom = 0
		box.add_theme_constant_override("separation", 3)
		info.add_child(box)
		info.move_child(box, 0)
		return
	t.card.add_child(box)


## The store's logo (single colour, light, for dark plates), else the store icon.
static func store_icon(store: String, px := 14) -> Texture2D:
	var tex: Texture2D = load("res://scripts/ui/brand_mark.gd").texture(store, px, Color(1, 1, 1, 0.82)) if store != "" else null
	return tex if tex != null else Icons.tex("store", px, Color(1, 1, 1, 0.82))


## A small rounded cover that loads its art off the main thread.
class Thumb extends Control:
	var view: Dictionary
	var art: TextureRect
	var fallback: Control

	func setup(v: Dictionary, sz: Vector2) -> void:
		view = v
		name = "Thumb"
		custom_minimum_size = sz
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		size_flags_vertical = Control.SIZE_SHRINK_CENTER
		var r := float(ThemeLib.radius("s"))
		fallback = FallbackArt.new()
		fallback.setup(v, 0, r, false)
		Kit.fill(fallback)
		add_child(fallback)
		art = TextureRect.new()
		art.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		art.stretch_mode = TextureRect.STRETCH_SCALE
		art.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
		Kit.fill(art)
		var m := ShaderMaterial.new()
		m.shader = ArtShader
		m.set_shader_parameter("size", sz)
		m.set_shader_parameter("radius", r)
		art.material = m
		art.visible = false
		add_child(art)
		refresh()

	func refresh() -> void:
		var p := str(view.get("art", {}).get("cover", ""))
		if not ArtCache.usable(p):
			return
		var tex := ArtCache.request("cover", p, func(t): _show(t), self)
		if tex != null:
			_show(tex)

	func _show(tex: Texture2D) -> void:
		if not is_instance_valid(art):
			return
		art.texture = tex
		art.visible = true
		fallback.visible = false


static func thumb(view: Dictionary, sz := Vector2(52, 78)) -> Control:
	var t := Thumb.new()
	t.setup(view, sz)
	return t


## A focusable list row: [cover] title / sub line ...... right column.
## Returns the Button; `parts` = {"title", "sub", "right": Control, "badges": [specs]}.
static func row(view: Dictionary, parts: Dictionary, height := 96) -> Button:
	var b := Kit.button("", "RowButton")
	b.name = "Row_" + str(view.get("key", "x")).validate_node_name()
	b.custom_minimum_size = Vector2(0, height)
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.set_meta("view", view)
	var h := Kit.hbox(16)
	h.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	h.offset_left = 10
	h.offset_right = -18
	h.mouse_filter = Control.MOUSE_FILTER_IGNORE
	b.add_child(h)
	if parts.get("thumb", true):
		h.add_child(thumb(view, Vector2(height * 0.54, height * 0.81)))
	var col := Kit.vbox(4)
	col.alignment = BoxContainer.ALIGNMENT_CENTER
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var title := Kit.label(str(parts.get("title", view.get("title", ""))), "HeaderLabel")
	title.name = "Title"
	title.add_theme_font_size_override("font_size", ThemeLib.SIZE_BODY)
	title.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	title.clip_text = true
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.add_child(title)
	if str(parts.get("sub", "")) != "":
		var sub := Kit.label(str(parts["sub"]), "QuietLabel")
		sub.name = "Sub"
		sub.add_theme_font_override("font", ThemeLib.mono(false, 1))
		sub.add_theme_font_size_override("font_size", ThemeLib.SIZE_CAPTION - 1)
		sub.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		sub.clip_text = true
		sub.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		col.add_child(sub)
	var specs: Array = parts.get("badges", [])
	if not specs.is_empty():
		var bb := Kit.hbox(6)
		bb.name = "Badges"
		bb.mouse_filter = Control.MOUSE_FILTER_IGNORE
		for s in specs.slice(0, 4):
			bb.add_child(Badge.make({"kind": s.get("kind", "x"), "text": s["text"], "short": s["text"], "tone": s.get("tone", ""), "icon": s.get("icon", "")}, "tile"))
		col.add_child(bb)
	h.add_child(col)
	var right: Variant = parts.get("right")
	if right is Control:
		(right as Control).size_flags_vertical = Control.SIZE_SHRINK_CENTER
		h.add_child(right)
	return b


## Price column for a Deal: big price + struck-through regular, or the
## discount and "See price" (with the store) when there's no local price.
static func price_column(deal: Dictionary, big := false, align_right := true) -> VBoxContainer:
	var col := Kit.vbox(0 if not big else 2)
	col.name = "Price"
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.alignment = BoxContainer.ALIGNMENT_CENTER
	var top := Kit.hbox(10)
	top.mouse_filter = Control.MOUSE_FILTER_IGNORE
	top.alignment = BoxContainer.ALIGNMENT_END if align_right else BoxContainer.ALIGNMENT_BEGIN
	var pct := int(deal.get("savings_pct", 0))
	if pct > 0:
		var b := badge("sale", T.cut(pct), "sale", "", "solid")
		b.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		top.add_child(b)
	var p := T.price(deal)
	var main := Kit.label(p if p != "" else T.SEE_PRICE, "NumberLabel")
	main.name = "Amount"
	# Prices are mono in the accent ("$19.99 CAD").
	main.add_theme_font_override("font", ThemeLib.mono(true, 1))
	main.add_theme_font_size_override("font_size", ThemeLib.SIZE_HEADLINE - 4 if big else ThemeLib.SIZE_BODY)
	main.add_theme_color_override("font_color", ThemeLib.color("accent"))
	if p == "":
		main.add_theme_font_override("font", ThemeLib.font("semibold"))
		main.add_theme_color_override("font_color", ThemeLib.color("text_2"))
		main.add_theme_font_size_override("font_size", ThemeLib.SIZE_TITLE if big else ThemeLib.SIZE_BODY)
	top.add_child(main)
	col.add_child(top)
	var reg := T.regular(deal)
	if reg != "":
		col.add_child(strike(reg, align_right))
	return col


static func strike(text: String, align_right := true) -> RichTextLabel:
	var r := RichTextLabel.new()
	r.name = "Regular"
	r.bbcode_enabled = true
	r.fit_content = true
	r.scroll_active = false
	r.autowrap_mode = TextServer.AUTOWRAP_OFF
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	r.focus_mode = Control.FOCUS_NONE
	r.add_theme_font_override("normal_font", ThemeLib.mono(false, 1))
	r.add_theme_font_size_override("normal_font_size", ThemeLib.SIZE_CAPTION)
	r.add_theme_color_override("default_color", ThemeLib.color("text_3"))
	r.text = ("[right][s]%s[/s][/right]" if align_right else "[s]%s[/s]") % text
	r.custom_minimum_size = Vector2(90, 0)
	return r


## A card for empty, offline and "optional key" states: picture or icon,
## heading, a plain explanation and up to two buttons. Returns the panel;
## its buttons are in meta "buttons".
static func info_card(picture: String, title: String, body: String, buttons: Array = [], icon := "", glass := true) -> PanelContainer:
	var card := PanelContainer.new()
	card.name = "Info_" + title.validate_node_name().left(24)
	card.theme_type_variation = "GlassPanel" if glass else "CardPanel"
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var row := Kit.hbox(28)
	card.add_child(row)
	if picture != "":
		row.add_child(Illustrations.rect(picture, 170))
	elif icon != "":
		var ic := PanelContainer.new()
		ic.add_theme_stylebox_override("panel", ThemeLib.box(Color(ThemeLib.color("accent"), 0.16), 999, 14, 14))
		ic.add_child(Icons.rect(icon, 30, ThemeLib.color("accent")))
		ic.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
		ic.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(ic)
	var col := Kit.vbox(10)
	col.alignment = BoxContainer.ALIGNMENT_CENTER
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var head := Kit.label(title, "HeaderLabel" if picture == "" else "TitleLabel", true)
	head.name = "Heading"
	col.add_child(head)
	var text := Kit.label(body, "QuietLabel", true)
	text.name = "Body"
	col.add_child(text)
	var made: Array = []
	if not buttons.is_empty():
		var br := Kit.hbox(12)
		br.name = "Buttons"
		for i in buttons.size():
			var spec: Array = buttons[i]
			var b := Kit.button(spec[0], "AccentButton" if i == 0 else "")
			b.name = str(spec[0]).validate_node_name()
			b.custom_minimum_size = Vector2(180 if i == 0 else 140, 52)
			if spec.size() > 2 and spec[2] != "":
				b.icon = Icons.tex(spec[2], 20)
				b.add_theme_constant_override("h_separation", 10)
			if spec[1] is Callable and (spec[1] as Callable).is_valid():
				b.pressed.connect(spec[1])
			br.add_child(b)
			made.append(b)
		Kit.link_horizontal(made)
		var gap := Control.new()
		gap.custom_minimum_size = Vector2(0, 4)
		col.add_child(gap)
		col.add_child(br)
	row.add_child(col)
	card.set_meta("buttons", made)
	return card


## "Price data by CheapShark · Prices by GG.deals": focusable link chips.
## `open` gets {"kind": "url", "uri": url}. Returns the row; its buttons are
## in meta "buttons".
static func credits(attrs: Array, open: Callable) -> HBoxContainer:
	var row := Kit.hbox(10)
	row.name = "Credits"
	var made: Array = []
	var lead := Kit.label(T.CREDITS_LEAD, "CaptionLabel")
	lead.add_theme_color_override("font_color", ThemeLib.color("text_3"))
	lead.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	lead.size_flags_vertical = Control.SIZE_FILL
	row.add_child(lead)
	for a in attrs:
		if not a is Dictionary or str(a.get("url", "")) == "":
			continue
		var b := Kit.button(str(a.get("text", "")), "SectionTab")
		b.name = "Credit_" + str(a.get("text", "")).validate_node_name()
		b.icon = Icons.tex("chevron_right", 16)
		b.icon_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		b.custom_minimum_size = Vector2(0, 36)
		b.set_meta("url", str(a["url"]))
		b.set_meta("link", true)
		var url := str(a["url"])
		b.pressed.connect(func(): open.call({"kind": "url", "uri": url}))
		row.add_child(b)
		made.append(b)
	Kit.link_horizontal(made)
	row.set_meta("buttons", made)
	return row


## A section heading inside a scrolling list: "This week  3".
static func heading(text: String, count := -1) -> HBoxContainer:
	var h := Kit.hbox(10)
	h.name = "Head_" + text.validate_node_name()
	h.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var l := Kit.label(text, "LeadLabel")
	l.add_theme_font_override("font", ThemeLib.font("semibold"))
	h.add_child(l)
	if count >= 0:
		var c := Kit.label(str(count), "CaptionLabel")
		c.add_theme_font_override("font", ThemeLib.font("medium", true))
		c.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		c.size_flags_vertical = Control.SIZE_FILL
		h.add_child(c)
	return h


## Vertical scroll area with a fade and "More below" cue, like the library.
static func scroller() -> ScrollContainer:
	var s := ScrollContainer.new()
	s.name = "Scroll"
	s.follow_focus = true
	s.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	s.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_NEVER
	s.size_flags_vertical = Control.SIZE_EXPAND_FILL
	s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	s.mouse_filter = Control.MOUSE_FILTER_PASS
	return s


## Keep `c` in view inside scroll `s` when it gets focus (smooth; Motion
## respects Reduce motion).
static func follow(s: ScrollContainer, c: Control, margin := 24.0) -> void:
	c.focus_entered.connect(func():
		if not s.is_inside_tree() or not c.is_inside_tree():
			return
		var top := c.global_position.y - s.global_position.y + s.scroll_vertical
		var bottom := top + c.size.y
		var target := float(s.scroll_vertical)
		if top - margin < target:
			target = top - margin
		elif bottom + margin > target + s.size.y:
			target = bottom + margin - s.size.y
		target = maxf(0.0, target)
		var Motion = load("res://scripts/ui/motion.gd")
		Motion.method(s, "vscroll", func(v: float): s.scroll_vertical = int(v), float(s.scroll_vertical), target, Motion.BASE))


## Focus every control in `list` top to bottom; left/right stay put unless set.
static func chain(list: Array, top: Control = null) -> void:
	var clean := list.filter(func(c): return c != null and is_instance_valid(c))
	for i in clean.size():
		var c: Control = clean[i]
		var up: Control = clean[i - 1] if i > 0 else (top if top != null else c)
		var down: Control = clean[i + 1] if i + 1 < clean.size() else c
		c.focus_neighbor_top = c.get_path_to(up)
		c.focus_neighbor_bottom = c.get_path_to(down)


## Take `c` out of `parent` now and free it later: safe while one of its
## own signals (a pressed button) is still running.
static func detach(parent: Node, c: Node) -> void:
	if c.get_parent() == parent:
		parent.remove_child(c)
	c.queue_free()


## Every focusable Button under `n`, in tree order.
static func buttons_in(n: Node) -> Array:
	var out: Array = []
	for c in n.find_children("*", "BaseButton", true, false):
		if (c as Control).focus_mode != Control.FOCUS_NONE:
			out.append(c)
	return out
