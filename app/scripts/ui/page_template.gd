extends Control
## The one page layout for anything with art: full-bleed hero art at the top,
## logo or title over it, an action row (Play / Install, ...), then content
## cards. Used by the game page; meant for store/deal pages and future
## profile pages too, so every page is learned once.
##
##   var p := PageTemplate.new()
##   p.setup_page(game, "On sale")              # hero, logo/title, meta, badges
##   var play := p.add_action("Play", "play", true)
##   var body := p.add_card("About this game", "info")   # -> VBoxContainer
##   p.finish()                                  # wires focus: actions -> cards

const Kit := preload("res://scripts/ui/ui_kit.gd")
const ThemeLib := preload("res://theme/gamecove_theme.gd")
const ArtCache := preload("res://scripts/ui/art_cache.gd")
const GameHeader := preload("res://scripts/ui/game_header.gd")
const FallbackArt := preload("res://scripts/ui/fallback_art.gd")
const Icons := preload("res://scripts/ui/icons.gd")
const Motion := preload("res://scripts/ui/motion.gd")
const Backdrop := preload("res://scripts/ui/backdrop.gd")
const UiPrefs := preload("res://scripts/ui/ui_prefs.gd")

const HERO_FRACTION := 0.66
## The hero card: EDGE from the sides, FRAME_TOP from the top, FRAME_H tall.
const FRAME_TOP := 20
const FRAME_H := 336
const FadeShader := preload("res://shaders/hero_fade.gdshader")

var game: Dictionary = {}
## Extra space above the hero card, set before setup_page(): the game page
## leaves room for the top bar (Home's hero card starts at the same height).
var top_inset := 0
## What d-pad up from the action row goes to (the top bar tab); null: nothing.
var top_target: Control
var hero: TextureRect
var hero_fallback: Control
var header: VBoxContainer
var actions_row: HBoxContainer
var actions: Array = []
var cards_box: VBoxContainer
var scroll: ScrollContainer
## Focusable controls inside cards, top to bottom (add_focusable / finish).
var focusables: Array = []
var _fade: TextureRect
var glow: TextureRect
var frame: Control
var _frame_edge: Panel
var _side: TextureRect
var _cue_fade: TextureRect
## "More below" cue, visible while the page can scroll further.
var cue: HBoxContainer
var _cue_pill: PanelContainer


func setup_page(g: Dictionary, line := "") -> void:
	game = g
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE

	var base := ColorRect.new()
	base.name = "Base"
	base.set_anchors_preset(Control.PRESET_FULL_RECT)
	base.mouse_filter = Control.MOUSE_FILTER_IGNORE
	base.color = ThemeLib.color("scrim")
	add_child(base)
	# The game's colour as a soft light behind the cards (see backdrop.gd).
	glow = TextureRect.new()
	glow.name = "AmbientGlow"
	glow.set_anchors_preset(Control.PRESET_FULL_RECT)
	glow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	glow.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	glow.stretch_mode = TextureRect.STRETCH_SCALE
	glow.texture = Backdrop.glow_texture()
	glow.modulate = Color(1, 1, 1, 0)
	add_child(glow)
	# The hero sits in a rounded glass card at the top, art on the right.
	frame = Control.new()
	frame.name = "HeroFrame"
	frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	frame.anchor_right = 1.0
	frame.offset_left = ThemeLib.EDGE
	frame.offset_right = -ThemeLib.EDGE
	frame.offset_top = FRAME_TOP + top_inset
	frame.offset_bottom = FRAME_TOP + top_inset + FRAME_H
	add_child(frame)
	hero_fallback = FallbackArt.new()
	hero_fallback.setup(g, 0, float(ThemeLib.radius("xl")), false)
	hero_fallback.set_anchors_preset(Control.PRESET_FULL_RECT)
	hero_fallback.mouse_filter = Control.MOUSE_FILTER_IGNORE
	frame.add_child(hero_fallback)
	hero = TextureRect.new()
	hero.name = "HeroArt"
	hero.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	hero.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	hero.set_anchors_preset(Control.PRESET_FULL_RECT)
	hero.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hero.visible = false
	frame.add_child(hero)
	_load_hero()

	_fade = TextureRect.new()
	_fade.name = "HeroFade"
	_fade.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_fade.stretch_mode = TextureRect.STRETCH_SCALE
	_fade.set_anchors_preset(Control.PRESET_FULL_RECT)
	_fade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	frame.add_child(_fade)
	_side = TextureRect.new()
	_side.name = "HeroSide"
	_side.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_side.stretch_mode = TextureRect.STRETCH_SCALE
	_side.set_anchors_preset(Control.PRESET_FULL_RECT)
	_side.mouse_filter = Control.MOUSE_FILTER_IGNORE
	frame.add_child(_side)
	for t in [hero, _fade, _side]:
		var m := ShaderMaterial.new()
		m.shader = FadeShader
		m.set_shader_parameter("fade_left_from", -1.0)
		m.set_shader_parameter("fade_left_to", 0.0)
		m.set_shader_parameter("fade_bottom_from", 0.999)
		m.set_shader_parameter("fade_top", 0.0001)
		m.set_shader_parameter("frame_radius", float(ThemeLib.radius("xl")))
		t.material = m
	frame.resized.connect(func():
		for t in [hero, _fade, _side]:
			(t.material as ShaderMaterial).set_shader_parameter("rect_size", frame.size))
	_frame_edge = Panel.new()
	_frame_edge.name = "HeroFrameEdge"
	_frame_edge.set_anchors_preset(Control.PRESET_FULL_RECT)
	_frame_edge.mouse_filter = Control.MOUSE_FILTER_IGNORE
	frame.add_child(_frame_edge)
	_restyle()

	scroll = ScrollContainer.new()
	scroll.name = "Scroll"
	scroll.set_anchors_preset(Control.PRESET_FULL_RECT)
	scroll.offset_top = FRAME_TOP + top_inset
	scroll.offset_bottom = -52
	# Follows focus once the layout settles, keeping rows clear of the
	# "More below" fade at the bottom.
	load("res://scripts/ui/focus_scroll.gd").attach(scroll, 64.0)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_NEVER
	add_child(scroll)
	var pad := Kit.margin(0, ThemeLib.EDGE + 32, 0)
	pad.add_theme_constant_override("margin_bottom", 28)
	pad.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(pad)
	var col := Kit.vbox(18)
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	pad.add_child(col)
	var top := Control.new()
	top.name = "HeroSpace"
	top.custom_minimum_size = Vector2(0, 52)
	col.add_child(top)
	header = GameHeader.new()
	header.max_badges = 6
	header.show_game(g, line)
	col.add_child(header)
	actions_row = Kit.hbox(14)
	actions_row.name = "Actions"
	col.add_child(actions_row)
	var gap := Control.new()
	gap.custom_minimum_size = Vector2(0, 30)
	col.add_child(gap)
	cards_box = Kit.vbox(18)
	cards_box.name = "Cards"
	col.add_child(cards_box)
	_build_scroll_cue()


## A fade and a "More below" cue at the bottom while there's more to scroll.
## Updated from the scroll bar's signals, never per frame.
func _build_scroll_cue() -> void:
	_cue_fade = TextureRect.new()
	_cue_fade.name = "ScrollFade"
	_cue_fade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_cue_fade.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_cue_fade.stretch_mode = TextureRect.STRETCH_SCALE
	_cue_fade.anchor_top = 1.0
	_cue_fade.anchor_right = 1.0
	_cue_fade.anchor_bottom = 1.0
	_cue_fade.offset_top = -150
	_cue_fade.offset_bottom = -52
	var g := Gradient.new()
	var sc: Color = ThemeLib.color("scrim")
	g.colors = PackedColorArray([Color(sc, 0.0), Color(sc, 0.95)])
	var t := GradientTexture2D.new()
	t.gradient = g
	t.width = 4
	t.height = 64
	t.fill_to = Vector2(0, 1)
	_cue_fade.texture = t
	add_child(_cue_fade)
	# The cue on its own glass pill, so a card peeking up from below never
	# prints its header through the words.
	_cue_pill = PanelContainer.new()
	_cue_pill.name = "ScrollCuePill"
	_cue_pill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var ps := ThemeLib.pill(ThemeLib.color("surface_2"), ThemeLib.color("line_2"), 14, 4)
	_cue_pill.add_theme_stylebox_override("panel", ps)
	# In the middle of the hint band (raised over it), not over the content:
	# a pill floating on the cards covered whatever sat at their foot
	# (the game page's screenshots).
	_cue_pill.anchor_top = 1.0
	_cue_pill.anchor_bottom = 1.0
	_cue_pill.offset_top = -ThemeLib.HINT_BAR_H * 0.5 - 16
	_cue_pill.offset_bottom = -ThemeLib.HINT_BAR_H * 0.5 + 16
	_cue_pill.z_index = 5
	add_child(_cue_pill)
	cue = Kit.icon_label("chevron_down", "More below", "CaptionLabel", ThemeLib.color("text_2"), 18, false)
	cue.name = "ScrollCue"
	cue.alignment = BoxContainer.ALIGNMENT_CENTER
	_cue_pill.add_child(cue)
	var bar := scroll.get_v_scroll_bar()
	bar.value_changed.connect(func(_v): _update_cue())
	bar.changed.connect(_update_cue)
	_update_cue()


func _update_cue() -> void:
	if cue == null:
		return
	var bar := scroll.get_v_scroll_bar()
	# Only for real content below (a few px of padding or a ring's glow
	# isn't any): never a cue pointing at nothing.
	var more := bar.max_value - bar.page - bar.value > 48.0
	cue.visible = more
	_cue_pill.visible = more
	_cue_fade.visible = more
	if more:
		_place_cue()
	# The hero art stays put while the cards scroll up over it: fade it out
	# so text never sits on a busy picture (only on scroll, never per frame).
	if frame != null:
		frame.modulate.a = clampf(1.0 - bar.value / 260.0, 0.0, 1.0)


## Centred in the hint band, between its status text and its prompts.
func _place_cue() -> void:
	var cx := size.x * 0.5
	var w := _cue_pill.get_combined_minimum_size().x
	_cue_pill.anchor_left = 0.0
	_cue_pill.anchor_right = 0.0
	_cue_pill.offset_left = cx - w * 0.5
	_cue_pill.offset_right = cx + w * 0.5


func can_scroll_down() -> bool:
	return cue != null and cue.visible


func _load_hero() -> void:
	var a: Variant = game.get("art", {})
	var p := ""
	if a is Dictionary:
		for k in ["hero", "cover"]:
			if ArtCache.usable(a.get(k, "")):
				p = a[k]
				break
	if p == "":
		return
	var tex := ArtCache.request("hero", p, func(t): _show_hero(t), self)
	if tex != null:
		_show_hero(tex)


func _show_hero(tex: Texture2D) -> void:
	if not is_instance_valid(hero):
		return
	hero.texture = tex
	hero.visible = true
	hero_fallback.visible = false


func _restyle() -> void:
	var bg: Color = ThemeLib.color("scrim")
	var g := Gradient.new()
	# Key art at full brightness: a short fade at the foot only, and a shade
	# behind the title on the left (Light keeps its stronger wash).
	var dark := ThemeLib.is_dark()
	g.offsets = PackedFloat32Array([0.0, 0.72, 1.0])
	g.colors = PackedColorArray([Color(bg, 0.0), Color(bg, 0.0), Color(bg, 0.55 if dark else 0.70)])
	var t := GradientTexture2D.new()
	t.gradient = g
	t.width = 4
	t.height = 256
	t.fill_to = Vector2(0, 1)
	_fade.texture = t
	var g2 := Gradient.new()
	g2.offsets = PackedFloat32Array([0.0, 0.30, 0.58] if dark else [0.0, 0.40, 0.75])
	g2.colors = PackedColorArray([Color(bg, 0.86 if dark else 0.92), Color(bg, 0.55 if dark else 0.70), Color(bg, 0.0)])
	var t2 := GradientTexture2D.new()
	t2.gradient = g2
	t2.width = 256
	t2.height = 4
	t2.fill_to = Vector2(1, 0)
	_side.texture = t2
	var edge := StyleBoxFlat.new()
	edge.draw_center = false
	edge.border_color = ThemeLib.color("line_2")
	edge.set_border_width_all(1)
	edge.set_corner_radius_all(ThemeLib.radius("xl"))
	edge.anti_aliasing = true
	_frame_edge.add_theme_stylebox_override("panel", edge)


func _notification(what: int) -> void:
	if what == NOTIFICATION_THEME_CHANGED and _fade != null:
		_restyle()


## A button in the action row. `primary`: the accent button (Play / Buy).
func add_action(text: String, icon := "", primary := false, node_name := "") -> Button:
	var b := Kit.primary(text, "A") if primary else Kit.button(text, "")
	if node_name != "":
		b.name = node_name
	b.custom_minimum_size = Vector2(176 if primary else 0, 50)
	if icon != "":
		b.icon = Icons.tex(icon, 20)
	b.focus_entered.connect(func(): scroll.scroll_vertical = 0)
	actions_row.add_child(b)
	actions.append(b)
	return b


## Cards added with `column = true` sit side by side under the hero, as a
## bento: three columns (two below COLUMNS_3_W). A card can ask for its column
## (`col`: About | Achievements | Game settings on the game page), so no
## column stands empty while another runs off the screen.
const COLUMNS_3_W := 1080.0
## After the column cards are dealt: how many columns, and each one's inner
## width (inside the card's padding), so content can fit itself.
signal columns_laid_out(count: int, inner_width: float)
var columns: HBoxContainer
var _column_cards: Array = []


## A tinted content card with an icon heading; returns its body. `column`:
## put it in the side-by-side row instead of the full-width stack.
func add_card(title: String, icon := "", subtitle := "", column := false, column_index := -1) -> VBoxContainer:
	var p := PanelContainer.new()
	p.theme_type_variation = "CardPanel"
	p.name = "Card_" + title.validate_node_name()
	var col := Kit.vbox(14)
	p.add_child(col)
	var head := Kit.vbox(4)
	var ht: Control = Kit.icon_label(icon, title, "HeaderLabel", ThemeLib.color("accent"), 22) if icon != "" else Kit.label(title, "HeaderLabel")
	var hl: Label = ht if ht is Label else ht.get_child(ht.get_child_count() - 1)
	hl.uppercase = true
	hl.add_theme_font_size_override("font_size", 20)
	head.add_child(ht)
	if subtitle != "":
		head.add_child(Kit.label(subtitle, "QuietLabel", true))
	col.add_child(head)
	if column:
		p.set_meta("col", column_index)
		_add_column_card(p)
	else:
		cards_box.add_child(p)
	return col


func _add_column_card(card: PanelContainer) -> void:
	if columns == null:
		columns = Kit.hbox(18)
		columns.name = "Columns"
		columns.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		cards_box.add_child(columns)
		columns.resized.connect(_layout_columns)
	_column_cards.append(card)
	_layout_columns()


## (Re)deals the column cards into stacks for the current width.
func _layout_columns() -> void:
	if columns == null:
		return
	var w := columns.size.x if columns.size.x > 0.0 else size.x
	if w <= 0.0:
		w = size.x - 2.0 * (ThemeLib.EDGE + 32)
	var n := 3 if w >= COLUMNS_3_W else 2
	n = mini(n, _column_cards.size())
	if n > 0:
		columns_laid_out.emit(n, (w - 18.0 * (n - 1)) / n - 40.0)
	if columns.get_child_count() == n and columns.get_meta("dealt", 0) == _column_cards.size():
		return
	columns.set_meta("dealt", _column_cards.size())
	for c in _column_cards:
		if c.get_parent() != null:
			c.get_parent().remove_child(c)
	for s in columns.get_children():
		columns.remove_child(s)
		s.queue_free()
	var stacks: Array = []
	for i in n:
		var st := Kit.vbox(18)
		st.name = "Column%d" % i
		st.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		columns.add_child(st)
		stacks.append(st)
	var asked := _column_cards.any(func(c): return int(c.get_meta("col", -1)) >= 0)
	for i in _column_cards.size():
		var card: PanelContainer = _column_cards[i]
		var k: int
		if asked:
			# The column the card asked for (the last one when there are fewer).
			k = clampi(int(card.get_meta("col", i)) if int(card.get_meta("col", -1)) >= 0 else i, 0, n - 1)
		else:
			# Two columns: everything but the last card stacks on the left.
			k = i if n >= _column_cards.size() else (0 if i < _column_cards.size() - 1 else n - 1)
		stacks[k].add_child(card)
	# A card alone in its column fills it, so the bento's bottoms line up.
	for st in stacks:
		for c in st.get_children():
			c.size_flags_vertical = Control.SIZE_EXPAND_FILL if st.get_child_count() == 1 else Control.SIZE_FILL


## Tint the primary action with the art's colour (from the backdrop), and
## the ambient glow behind the cards ("Match game art colours" only).
func set_accent(c: Color) -> void:
	for b in actions:
		if b.theme_type_variation == "AccentButton":
			Kit.accent_button(b, c)
	if glow != null:
		var on: bool = UiPrefs.match_art and c.a > 0.0
		Motion.to(glow, "modulate", Backdrop.glow_color(c) if on else Color(1, 1, 1, 0), Motion.SLOW)


func add_focusables(list: Array) -> void:
	focusables.append_array(list)


## Focus: left/right along the actions, down from any action into the cards,
## up and down through the cards' controls.
func finish() -> void:
	Kit.link_horizontal(actions)
	var chain: Array = [actions[0]] if not actions.is_empty() else []
	chain.append_array(focusables)
	Kit.link_vertical(chain)
	if not actions.is_empty():
		actions[0].focus_neighbor_right = actions[0].get_path_to(actions[1] if actions.size() > 1 else actions[0])
	for i in range(1, actions.size()):
		var a: Control = actions[i]
		a.focus_neighbor_top = a.get_path_to(a)
		a.focus_neighbor_bottom = a.get_path_to(focusables[0] if not focusables.is_empty() else a)
		a.focus_neighbor_left = a.get_path_to(actions[i - 1])
		a.focus_neighbor_right = a.get_path_to(actions[i + 1] if i + 1 < actions.size() else a)
	_link_top_target()


## D-pad up from the action row goes to `c` (main passes the top bar's tab).
func set_top_target(c: Control) -> void:
	top_target = c
	_link_top_target()


func _link_top_target() -> void:
	if not is_instance_valid(top_target) or not is_inside_tree() or not top_target.is_inside_tree():
		return
	for a in actions:
		a.focus_neighbor_top = a.get_path_to(top_target)
