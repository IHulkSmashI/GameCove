extends VBoxContainer
## A titled horizontal row of game tiles that glides only as far as it must
## to keep one tile of room either side of the focused one, so the row never
## hides a tile on the left while there's room on the right (the "03 / 09"
## counter always matches the third card you can see).
## Tiles size themselves to show Tile.PER_ROW across the screen; while the row
## runs past an edge, that edge fades out over FADE px instead of cutting a
## cover in half. Used by Home, Discover and Stream.

const Kit := preload("res://scripts/ui/ui_kit.gd")
const Tile := preload("res://scripts/ui/game_tile.gd")
const Motion := preload("res://scripts/ui/motion.gd")
const ThemeLib := preload("res://theme/gamecove_theme.gd")
const FadeMask := preload("res://scripts/ui/fade_mask.gd")

signal tile_focused(game: Dictionary, index: int)
signal tile_pressed(game: Dictionary)

const GAP := 16
## Room around the tiles for the focus lift and glow.
const PAD := Vector2(24, 16)
## Below the tiles: room for the focused tile's lift and glow.
const LABEL_ROOM := 16
## Width of the soft edge where the row continues past the screen: wide and
## gone at the very edge, so a peeking cover's bright title is gone before
## the cut (fully hidden for the outer 62 %, so a subtitle never peeks
## through; 30 % at 86 %, whole at the inside).
## It's an alpha mask, not a colour laid over the row, so it fades into
## whatever is behind (art, glow, a light theme) without a dark band.
const FADE := 96.0
## [visible fraction] from the screen edge inwards, in parts of FADE.
const FADE_STOPS := [[0.0, 0.0], [0.62, 0.0], [0.86, 0.3], [1.0, 1.0]]

var id := ""
var title := ""
var tiles: Array = []
var scroll: ScrollContainer
var strip: HBoxContainer
var count_label: Label
var memory := 0          # last focused index (TV-style row memory)
## Games in the shelf's whole list when it shows only the first of them and ends
## with a "See all" tile (Home's cap); 0 = it shows them all.
var total := 0
var tile_size := Vector2.ZERO
## "hero" for a row of wide featured cards (set before setup()); see featured_size().
var art_kind := "cover"
## The row's holder: an alpha mask (clip children) that fades the ends.
var _mask: TextureRect
var _mask_grad: Gradient
var _fades: Array = [false, false]


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
	# The row sits in an alpha mask: each end fades out (shown only while the
	# row runs past that end), so covers dissolve into the backdrop.
	_mask = TextureRect.new()
	_mask.name = "Row"
	_mask.mouse_filter = Control.MOUSE_FILTER_PASS
	_mask.custom_minimum_size = scroll.custom_minimum_size
	_mask.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_mask.stretch_mode = TextureRect.STRETCH_SCALE
	_mask.clip_children = CanvasItem.CLIP_CHILDREN_ONLY
	_mask_grad = Gradient.new()
	var mt := GradientTexture2D.new()
	mt.gradient = _mask_grad
	mt.width = 1024
	mt.height = 1
	mt.fill_to = Vector2(1, 0)
	_mask.texture = mt
	scroll.set_anchors_preset(Control.PRESET_FULL_RECT)
	_mask.add_child(scroll)
	add_child(_mask)
	_style_fades()
	_mask.resized.connect(_style_fades)
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
		tile.art_kind = art_kind
		tile.setup(g, true, tile_size)
		var game: Dictionary = g
		var i := tiles.size()
		tile.pressed.connect(func(): tile_pressed.emit(game))
		tile.focus_entered.connect(_on_focus.bind(i))
		strip.add_child(tile)
		tiles.append(tile)
		# a tile can end up taller than it was made after layout (text wrapping differently with another font, a badge
		# or price added): the row follows its size, not only its minimum, and not only once
		tile.minimum_size_changed.connect(fit_row)
		tile.resized.connect(fit_row)
	Kit.link_horizontal(tiles)


## The row is as tall as its tallest tile needs: a tile that grows past the size it was given (a featured
## giveaway card gets badges and a price under its art) would otherwise be cut off by the row, with its focus ring
## outside it (layout check showcase/discover_free on ultrawide).
func fit_row() -> void:
	if scroll == null:
		return
	var tallest := tile_size.y
	for t in tiles:
		if is_instance_valid(t):
			tallest = maxf(tallest, maxf((t as Control).get_combined_minimum_size().y, (t as Control).size.y))
	var h := ceilf(tallest + PAD.y + LABEL_ROOM)
	if h > scroll.custom_minimum_size.y:
		scroll.custom_minimum_size = Vector2(0, h)
		_mask.custom_minimum_size = scroll.custom_minimum_size


## A row of one or two games as wide featured cards, two to the row (so a
## short row never leaves the screen empty beside one lonely cover; with one
## game the caller puts what it knows about it in the other half): the size
## of a card across `avail_w` px, as tall as the usual covers.
static func featured_size(avail_w: float) -> Vector2:
	var usual := Tile.size_for(Tile.row_width(), GAP)
	return Vector2(maxf(usual.x, floorf((avail_w - GAP) / 2.0)), usual.y)


## Fade the left edge while scrolled past the start, the right one while
## more tiles wait beyond it.
func _update_fade() -> void:
	if _fades.is_empty() or scroll == null:
		return
	var bar := scroll.get_h_scroll_bar()
	var was := _fades.duplicate()
	_fades = [bar.value > 1.0, bar.max_value - bar.page - bar.value > 1.0]
	if _fades != was:
		_style_fades()
	# A cover the edge cuts into fades with it, so the cut never reads as a
	# hard edge (a tile's own dimming, e.g. an asleep PC, is kept in meta).
	var x0 := float(bar.value)
	var x1 := x0 + scroll.size.x
	var pitch := tile_size.x + GAP
	for i in tiles.size():
		var t: Control = tiles[i]
		var left := PAD.x + i * pitch
		var right := left + tile_size.x
		var seen := clampf((minf(right, x1) - maxf(left, x0)) / tile_size.x, 0.0, 1.0)
		var a := 1.0 if seen >= 0.98 else lerpf(0.2, 0.85, seen)
		t.modulate.a = float(t.get_meta("base_alpha", 1.0)) * a


## [left faded, right faded].
func faded_edges() -> Array:
	return _fades.duplicate()


## The mask's gradient for the faded ends: opaque in the middle, each faded
## end over FADE px from the edge.
func _style_fades() -> void:
	if _mask_grad == null:
		return
	var w := maxf(_mask.size.x, FADE * 2.0 + 2.0)
	var offs := PackedFloat32Array()
	var cols := PackedColorArray()
	if _fades[0]:
		for st in FADE_STOPS:
			offs.append(st[0] * FADE / w)
			cols.append(Color(1, 1, 1, st[1]))
	else:
		offs.append(0.0)
		cols.append(Color.WHITE)
	if _fades[1]:
		for k in range(FADE_STOPS.size() - 1, -1, -1):
			offs.append(1.0 - FADE_STOPS[k][0] * FADE / w)
			cols.append(Color(1, 1, 1, FADE_STOPS[k][1]))
	else:
		offs.append(1.0)
		cols.append(Color.WHITE)
	_mask_grad.offsets = offs
	_mask_grad.colors = cols


func _notification(what: int) -> void:
	if what == NOTIFICATION_THEME_CHANGED:
		_style_fades()
	elif what == NOTIFICATION_ENTER_TREE:
		_check_nested_mask()


## Godot can't nest clip-children masks (the inner one draws as a white
## block): inside one (Discover's page sits in a FadeMask) the row drops its
## own mask and its edge covers fade by their alpha alone (_update_fade).
func _check_nested_mask() -> void:
	if _mask == null:
		return
	var nested := FadeMask.inside_mask(_mask)
	_mask.clip_children = CanvasItem.CLIP_CHILDREN_DISABLED if nested else CanvasItem.CLIP_CHILDREN_ONLY
	_mask.self_modulate.a = 0.0 if nested else 1.0


## Covers that rise in on reveal (the ones on screen, and one more).
const REVEAL_TILES := 7
const REVEAL_RISE_PX := 24.0
const REVEAL_S := 0.22
const REVEAL_STAGGER_S := 0.03
## Each shelf after the first starts this much later (home.gd).
const REVEAL_SHELF_STAGGER_S := 0.04


## First show: the row fades in and its covers rise into place one after
## another. Instant under reduce motion; a focus lift takes over cleanly.
func reveal(delay := 0.0) -> void:
	Motion.enter(self, "modulate:a", 0.0, 1.0, REVEAL_S * 0.6, delay)
	for i in mini(tiles.size(), REVEAL_TILES):
		var card: Variant = tiles[i].get("card")
		if card is Control:
			Motion.enter(card, "position:y", REVEAL_RISE_PX, 0.0, REVEAL_S, delay + i * REVEAL_STAGGER_S,
				Tween.TRANS_QUART, Tween.EASE_OUT)


func remembered() -> Control:
	return tiles[clampi(memory, 0, tiles.size() - 1)] if not tiles.is_empty() else null


func _on_focus(i: int) -> void:
	memory = i
	if total > 0:
		# a capped shelf: the place in the whole list; on its last tile ("See all") how many there are
		count_label.text = ("%d games" % total) if i == tiles.size() - 1 else "%02d / %02d" % [i + 1, total]
	else:
		count_label.text = "%02d / %02d" % [i + 1, tiles.size()]
	scroll_to(i)
	tile_focused.emit(tiles[i].game, i)


## The scroll that shows tile `i` with one tile of room either side, moving
## as little as possible from `from`.
func target_for(i: int, from: float) -> float:
	if tiles.is_empty():
		return 0.0
	var pitch: float = tiles[0].custom_minimum_size.x + GAP
	var view := scroll.size.x if scroll.size.x > 0.0 else Tile.row_width()
	var left := PAD.x + (i - 1) * pitch                       # the tile before it
	var right := PAD.x + (i + 2) * pitch - GAP + PAD.x        # the tile after it, and its margin
	var target := from
	if right - target > view:
		target = right - view
	if left - PAD.x < target:
		target = left - PAD.x
	var max_scroll := maxf(0.0, strip.size.x + PAD.x * 2 - view)
	return clampf(target, 0.0, max_scroll)


## Glide so tile `i` shows with a tile of room either side.
func scroll_to(i: int, animate := true) -> void:
	if tiles.is_empty() or not is_inside_tree():
		return
	var target := target_for(i, float(scroll.scroll_horizontal))
	if not animate:
		scroll.scroll_horizontal = int(target)
		return
	Motion.method(scroll, "hscroll", func(v: float): scroll.scroll_horizontal = int(v),
		float(scroll.scroll_horizontal), target, Motion.BASE)
