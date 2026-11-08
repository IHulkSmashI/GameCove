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

const HERO_FRACTION := 0.66

var game: Dictionary = {}
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
var _side: TextureRect
var _cue_fade: TextureRect
## "More below" cue, visible while the page can scroll further.
var cue: HBoxContainer


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
	hero_fallback = FallbackArt.new()
	hero_fallback.setup(g, 0, 0.0, false)
	hero_fallback.anchor_right = 1.0
	hero_fallback.anchor_bottom = HERO_FRACTION
	hero_fallback.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(hero_fallback)
	hero = TextureRect.new()
	hero.name = "HeroArt"
	hero.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	hero.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	hero.anchor_right = 1.0
	hero.anchor_bottom = HERO_FRACTION
	hero.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hero.visible = false
	add_child(hero)
	_load_hero()

	_fade = TextureRect.new()
	_fade.name = "HeroFade"
	_fade.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_fade.stretch_mode = TextureRect.STRETCH_SCALE
	_fade.anchor_right = 1.0
	_fade.anchor_bottom = HERO_FRACTION + 0.01
	_fade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_fade)
	_side = TextureRect.new()
	_side.name = "HeroSide"
	_side.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_side.stretch_mode = TextureRect.STRETCH_SCALE
	_side.anchor_right = 0.75
	_side.anchor_bottom = HERO_FRACTION + 0.01
	_side.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_side)
	_restyle()

	scroll = ScrollContainer.new()
	scroll.name = "Scroll"
	scroll.set_anchors_preset(Control.PRESET_FULL_RECT)
	scroll.offset_top = 70
	scroll.offset_bottom = -52
	scroll.follow_focus = true
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_NEVER
	add_child(scroll)
	var pad := Kit.margin(0, 48, 0)
	pad.add_theme_constant_override("margin_bottom", 28)
	pad.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(pad)
	var col := Kit.vbox(18)
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	pad.add_child(col)
	var top := Control.new()
	top.name = "HeroSpace"
	top.custom_minimum_size = Vector2(0, 150)
	col.add_child(top)
	header = GameHeader.new()
	header.max_badges = 6
	header.show_game(g, line)
	col.add_child(header)
	actions_row = Kit.hbox(14)
	actions_row.name = "Actions"
	col.add_child(actions_row)
	var gap := Control.new()
	gap.custom_minimum_size = Vector2(0, 10)
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
	cue = Kit.icon_label("chevron_down", "More below", "CaptionLabel", ThemeLib.color("text_2"), 18, false)
	cue.name = "ScrollCue"
	cue.anchor_left = 0.5
	cue.anchor_right = 0.5
	cue.anchor_top = 1.0
	cue.anchor_bottom = 1.0
	cue.offset_left = -70
	cue.offset_right = 70
	cue.offset_top = -86
	cue.offset_bottom = -62
	cue.alignment = BoxContainer.ALIGNMENT_CENTER
	add_child(cue)
	var bar := scroll.get_v_scroll_bar()
	bar.value_changed.connect(func(_v): _update_cue())
	bar.changed.connect(_update_cue)
	_update_cue()


func _update_cue() -> void:
	if cue == null:
		return
	var bar := scroll.get_v_scroll_bar()
	var more := bar.max_value - bar.page - bar.value > 24.0
	cue.visible = more
	_cue_fade.visible = more


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
	g.offsets = PackedFloat32Array([0.0, 0.35, 0.75, 1.0])
	g.colors = PackedColorArray([Color(bg, 0.35), Color(bg, 0.10), Color(bg, 0.75), Color(bg, 1.0)])
	var t := GradientTexture2D.new()
	t.gradient = g
	t.width = 4
	t.height = 256
	t.fill_to = Vector2(0, 1)
	_fade.texture = t
	var g2 := Gradient.new()
	g2.colors = PackedColorArray([Color(bg, 0.80), Color(bg, 0.0)])
	var t2 := GradientTexture2D.new()
	t2.gradient = g2
	t2.width = 256
	t2.height = 4
	t2.fill_to = Vector2(1, 0)
	_side.texture = t2


func _notification(what: int) -> void:
	if what == NOTIFICATION_THEME_CHANGED and _fade != null:
		_restyle()


## A button in the action row. `primary`: the accent button (Play / Buy).
func add_action(text: String, icon := "", primary := false, node_name := "") -> Button:
	var b := Kit.button(text, "AccentButton" if primary else "")
	if node_name != "":
		b.name = node_name
	b.custom_minimum_size = Vector2(220 if primary else 150, 58)
	if icon != "":
		b.icon = Icons.tex(icon, 22)
		b.add_theme_constant_override("h_separation", 10)
	b.focus_entered.connect(func(): scroll.scroll_vertical = 0)
	actions_row.add_child(b)
	actions.append(b)
	return b


## A tinted content card with an icon heading; returns its body.
func add_card(title: String, icon := "", subtitle := "") -> VBoxContainer:
	var p := PanelContainer.new()
	p.theme_type_variation = "CardPanel"
	p.name = "Card_" + title.validate_node_name()
	var col := Kit.vbox(14)
	p.add_child(col)
	var head := Kit.vbox(4)
	head.add_child(Kit.icon_label(icon, title, "HeaderLabel", ThemeLib.color("accent"), 24) if icon != "" else Kit.label(title, "HeaderLabel"))
	if subtitle != "":
		head.add_child(Kit.label(subtitle, "QuietLabel", true))
	col.add_child(head)
	cards_box.add_child(p)
	return col


## Tint the primary action with the art's colour (from the backdrop).
func set_accent(c: Color) -> void:
	for b in actions:
		if b.theme_type_variation == "AccentButton":
			Kit.accent_button(b, c)


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
