extends VBoxContainer
## A titled horizontal row of game tiles that glides to keep the focused tile
## in view (one tile of lead on the left, so you see where you came from).
## Tiles size themselves to show Tile.PER_ROW across the screen; while the row
## runs past an edge, that edge fades out over FADE px instead of cutting a
## cover in half. Used by Home, Discover and Stream.

const Kit := preload("res://scripts/ui/ui_kit.gd")
const Tile := preload("res://scripts/ui/game_tile.gd")
const Motion := preload("res://scripts/ui/motion.gd")
const ThemeLib := preload("res://theme/gamecove_theme.gd")

signal tile_focused(game: Dictionary, index: int)
signal tile_pressed(game: Dictionary)

const GAP := 16
## Room around the tiles for the focus lift and glow.
const PAD := Vector2(24, 16)
## Below the tiles: room for the focused tile's lift and glow.
const LABEL_ROOM := 16
## Width of the soft edge where the row continues past the screen.
const FADE := 64.0

var id := ""
var title := ""
var tiles: Array = []
var scroll: ScrollContainer
var strip: HBoxContainer
var count_label: Label
var memory := 0          # last focused index (TV-style row memory)
var tile_size := Vector2.ZERO
var _fades: Array = []


## `size`: tile size; Vector2.ZERO sizes them for the screen (Tile.size_for).
func setup(shelf_id: String, shelf_title: String, games: Array, size := Vector2.ZERO) -> void:
	tile_size = size if size != Vector2.ZERO else Tile.size_for(Tile.row_width(), GAP)
	id = shelf_id
	title = shelf_title
	name = "Row_" + shelf_id
	add_theme_constant_override("separation", 0)
	var head := Kit.hbox(10)
	head.name = "Head"
	var lead := Control.new()
	lead.custom_minimum_size = Vector2(PAD.x - 10, 0)
	head.add_child(lead)
	# Section title in uppercase Outfit, the count in mono on the right.
	var t := Kit.label(shelf_title, "LeadLabel")
	t.name = "Title"
	t.uppercase = true
	t.add_theme_font_override("font", ThemeLib.font("heading_bold", false, 1))
	t.add_theme_font_size_override("font_size", 19)
	head.add_child(t)
	head.add_child(Kit.spacer())
	count_label = Kit.micro("%d %s" % [games.size(), "game" if games.size() == 1 else "games"])
	count_label.name = "Count"
	count_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	count_label.size_flags_vertical = Control.SIZE_FILL
	head.add_child(count_label)
	var tail := Control.new()
	tail.custom_minimum_size = Vector2(PAD.x, 0)
	head.add_child(tail)
	add_child(head)

	scroll = ScrollContainer.new()
	scroll.name = "Scroll"
	scroll.follow_focus = false
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_NEVER
	scroll.custom_minimum_size = Vector2(0, tile_size.y + PAD.y + LABEL_ROOM)
	scroll.mouse_filter = Control.MOUSE_FILTER_PASS
	# The row and its edge fades share a plain holder (a VBox would stack them).
	var holder := Control.new()
	holder.name = "Row"
	holder.mouse_filter = Control.MOUSE_FILTER_PASS
	holder.custom_minimum_size = scroll.custom_minimum_size
	scroll.set_anchors_preset(Control.PRESET_FULL_RECT)
	holder.add_child(scroll)
	add_child(holder)
	# Soft edges: a gradient of the screen's scrim colour over each end of the
	# row, shown only while the row runs past that end. The backdrop is darkest
	# at the screen edges, so covers fade into it instead of being cut.
	for side in ["left", "right"]:
		var f := TextureRect.new()
		f.name = "Fade_" + side
		f.mouse_filter = Control.MOUSE_FILTER_IGNORE
		f.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		f.stretch_mode = TextureRect.STRETCH_SCALE
		f.anchor_bottom = 1.0
		if side == "left":
			f.offset_right = FADE
		else:
			f.anchor_left = 1.0
			f.anchor_right = 1.0
			f.offset_left = -FADE
		f.visible = false
		holder.add_child(f)
		_fades.append(f)
	_style_fades()
	scroll.resized.connect(_update_fade)
	scroll.get_h_scroll_bar().value_changed.connect(func(_v): _update_fade())
	scroll.get_h_scroll_bar().changed.connect(_update_fade)
	var pad := Kit.margin(0, int(PAD.x), int(PAD.y))
	pad.add_theme_constant_override("margin_bottom", LABEL_ROOM)
	pad.mouse_filter = Control.MOUSE_FILTER_PASS
	scroll.add_child(pad)
	strip = Kit.hbox(GAP)
	strip.name = "Tiles"
	pad.add_child(strip)

	for g in games:
		var tile: Button = Tile.new()
		tile.setup(g, true, tile_size)
		var game: Dictionary = g
		var i := tiles.size()
		tile.pressed.connect(func(): tile_pressed.emit(game))
		tile.focus_entered.connect(_on_focus.bind(i))
		strip.add_child(tile)
		tiles.append(tile)
	Kit.link_horizontal(tiles)


## Fade the left edge while scrolled past the start, the right one while
## more tiles wait beyond it.
func _update_fade() -> void:
	if _fades.is_empty() or scroll == null:
		return
	var bar := scroll.get_h_scroll_bar()
	_fades[0].visible = bar.value > 1.0
	_fades[1].visible = bar.max_value - bar.page - bar.value > 1.0


## [left faded, right faded].
func faded_edges() -> Array:
	return [_fades[0].visible, _fades[1].visible]


func _style_fades() -> void:
	var sc: Color = ThemeLib.color("scrim")
	for i in _fades.size():
		var g := Gradient.new()
		var a := Color(sc, 0.92)
		var b := Color(sc, 0.0)
		g.colors = PackedColorArray([a, b] if i == 0 else [b, a])
		var t := GradientTexture2D.new()
		t.gradient = g
		t.width = 64
		t.height = 4
		t.fill_to = Vector2(1, 0)
		_fades[i].texture = t


func _notification(what: int) -> void:
	if what == NOTIFICATION_THEME_CHANGED and not _fades.is_empty():
		_style_fades()


func remembered() -> Control:
	return tiles[clampi(memory, 0, tiles.size() - 1)] if not tiles.is_empty() else null


func _on_focus(i: int) -> void:
	memory = i
	count_label.text = "%02d / %02d" % [i + 1, tiles.size()]
	scroll_to(i)
	tile_focused.emit(tiles[i].game, i)


## Glide so tile `i` sits one tile in from the left edge.
func scroll_to(i: int, animate := true) -> void:
	if tiles.is_empty() or not is_inside_tree():
		return
	var pitch: float = tiles[0].custom_minimum_size.x + GAP
	var target := maxf(0.0, (i - 1) * pitch)
	var max_scroll := maxf(0.0, strip.size.x + PAD.x * 2 - scroll.size.x)
	target = minf(target, max_scroll)
	if not animate:
		scroll.scroll_horizontal = int(target)
		return
	Motion.method(scroll, "hscroll", func(v: float): scroll.scroll_horizontal = int(v),
		float(scroll.scroll_horizontal), target, Motion.BASE)
