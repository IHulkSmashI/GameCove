extends VBoxContainer
## A titled horizontal row of game tiles that glides to keep the focused tile
## in view (one tile of lead on the left, so you see where you came from).
## Reused by Home and, later, Discover.

const Kit := preload("res://scripts/ui/ui_kit.gd")
const Tile := preload("res://scripts/ui/game_tile.gd")
const Motion := preload("res://scripts/ui/motion.gd")
const ThemeLib := preload("res://theme/gamecove_theme.gd")

signal tile_focused(game: Dictionary, index: int)
signal tile_pressed(game: Dictionary)

const GAP := 16
## Room around the tiles for the focus lift and glow.
const PAD := Vector2(24, 16)
## Below the tiles: room for the focused tile's title.
const LABEL_ROOM := 40

var id := ""
var title := ""
var tiles: Array = []
var scroll: ScrollContainer
var strip: HBoxContainer
var count_label: Label
var memory := 0          # last focused index (TV-style row memory)


func setup(shelf_id: String, shelf_title: String, games: Array, tile_size := Tile.SIZE) -> void:
	id = shelf_id
	title = shelf_title
	name = "Row_" + shelf_id
	add_theme_constant_override("separation", 0)
	var head := Kit.hbox(10)
	head.name = "Head"
	var lead := Control.new()
	lead.custom_minimum_size = Vector2(PAD.x - 10, 0)
	head.add_child(lead)
	var t := Kit.label(shelf_title, "LeadLabel")
	t.name = "Title"
	t.add_theme_font_override("font", ThemeLib.font("semibold"))
	head.add_child(t)
	count_label = Kit.label(str(games.size()), "CaptionLabel")
	count_label.name = "Count"
	count_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	count_label.size_flags_vertical = Control.SIZE_FILL
	count_label.add_theme_font_override("font", ThemeLib.font("medium", true))
	head.add_child(count_label)
	add_child(head)

	scroll = ScrollContainer.new()
	scroll.name = "Scroll"
	scroll.follow_focus = false
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_NEVER
	scroll.custom_minimum_size = Vector2(0, tile_size.y + PAD.y + LABEL_ROOM)
	scroll.mouse_filter = Control.MOUSE_FILTER_PASS
	add_child(scroll)
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


func remembered() -> Control:
	return tiles[clampi(memory, 0, tiles.size() - 1)] if not tiles.is_empty() else null


func _on_focus(i: int) -> void:
	memory = i
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
